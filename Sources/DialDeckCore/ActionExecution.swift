import Foundation

public enum KeyboardTransition: Equatable, Sendable {
    case down
    case up
}

public enum HostKeyboardTarget: Equatable, Sendable {
    case key(MacVirtualKeyCode)
    case modifier(KeyboardModifier)
}

/// Structured, sanitized host intents. Acceptance by a service does not prove
/// that macOS or the target application performed the requested behavior.
public enum HostActionIntent: Equatable, Sendable {
    case keyboard(KeyboardTransition, HostKeyboardTarget)
    case launchOrActivateApplication(ApplicationBundleIdentifier)
    case runAppleShortcut(AppleShortcutName)
    case clipboardManagerShortcut(KeyboardChord)
    case scroll(axis: ScrollAxis, detents: Int, speed: ScrollSpeed)
    case zoom(ZoomDirection, steps: Int, application: ApplicationBundleIdentifier?)
}

public enum HostActionTarget: Equatable, Sendable {
    case application(ApplicationBundleIdentifier)
    case appleShortcut(AppleShortcutName)
    case clipboardManager
    case keyboard
    case scrolling
    case zoom
}

public enum HostActionServiceResult: Equatable, Sendable {
    case acceptedUnverified
    case missingTarget(HostActionTarget)
    case unsupported(reason: String)
    case failed(reason: String)
}

/// Implementations receive structured intents and must cooperate with Task
/// cancellation. Tests use recording doubles; production adapters are separate.
public protocol HostActionServicing: Sendable {
    func perform(_ intent: HostActionIntent) async -> HostActionServiceResult
}

enum RuntimeFailureText {
    static func sanitize(_ message: String) -> String {
        let safeScalars = message.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(safeScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The service reported an unspecified failure" }
        return String(trimmed.prefix(240))
    }
}

public struct ActionExecutionLimits: Equatable, Sendable {
    public let perActionTimeout: Duration
    public let sequenceDeadline: Duration
    public let maximumDialMagnitude: Int

    public init(
        perActionTimeout: Duration = .seconds(5),
        sequenceDeadline: Duration = .seconds(180),
        maximumDialMagnitude: Int = 100
    ) {
        self.perActionTimeout = perActionTimeout
        self.sequenceDeadline = sequenceDeadline
        self.maximumDialMagnitude = max(1, maximumDialMagnitude)
    }
}

public enum ActionExecutionFailure: Equatable, Sendable {
    case unsupportedAction(String)
    case missingTarget(HostActionTarget)
    case serviceFailed(String)
    case actionTimedOut
    case sequenceDeadlineExceeded
    case cancelled
    case invalidInput
    case cleanupFailed(String)
    case modePersistenceFailed(String)
}

public enum DialModeAdvanceResult: Equatable, Sendable {
    case advanced(DialModeID)
    case failed(ActionExecutionFailure)
}

public enum ActionExecutionOutcome: Equatable, Sendable {
    /// The injected service accepted an intent; resulting OS behavior remains
    /// unverified until separately observed.
    case acceptedUnverified
    case modeChanged(profileID: ProfileID, modeID: DialModeID)
    case ignored
    case failed(ActionExecutionFailure)
    case partialFailure(completedSteps: Int, failure: ActionExecutionFailure)
    case cancelled
}

public struct ActionExecutionResult: Equatable, Sendable {
    public let requestID: UUID
    public let outcome: ActionExecutionOutcome

    public init(requestID: UUID = UUID(), outcome: ActionExecutionOutcome) {
        self.requestID = requestID
        self.outcome = outcome
    }
}

private enum ActionOwner: Hashable, Sendable {
    case physical(PhysicalControlID, SessionGeneration)
    case sequence(UUID)
    case chord(UUID)
}

private enum TimedValue<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
    case cancelled
}

/// One-shot race that lets a timeout return even if a service fails to honor
/// cancellation. The service contract still requires cancellation cooperation
/// so it cannot perform a late side effect after the caller has timed out.
private final class TimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TimedValue<Value>, Never>?
    private var result: TimedValue<Value>?
    private var operationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    func begin(_ continuation: CheckedContinuation<TimedValue<Value>, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func start(
        timeout: Duration,
        operation: @escaping @Sendable () async -> Value
    ) {
        lock.lock()
        let alreadyFinished = result != nil
        lock.unlock()
        guard !alreadyFinished else { return }

        let operation = Task { self.finish(.value(await operation())) }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                self.finish(.timedOut)
            } catch {
                // A competing result ended this race.
            }
        }

        lock.lock()
        let finishedDuringInstall = result != nil
        if !finishedDuringInstall {
            operationTask = operation
            timerTask = timer
        }
        lock.unlock()
        if finishedDuringInstall {
            operation.cancel()
            timer.cancel()
        }
    }

    func cancel() {
        finish(.cancelled)
    }

    private func finish(_ result: TimedValue<Value>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let operation = operationTask
        operationTask = nil
        let timer = timerTask
        timerTask = nil
        lock.unlock()

        switch result {
        case .value, .timedOut:
            operation?.cancel()
        case .cancelled:
            operation?.cancel()
        }
        timer?.cancel()
        continuation?.resume(returning: result)
    }
}

actor AsyncActionGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Serializes host actions and owns every synthetic key/modifier it presses.
/// It never inspects or releases modifiers held by the user's physical keyboard.
public actor HostActionExecutor {
    private struct PressState: Sendable {
        let owner: ActionOwner
    }

    private let service: any HostActionServicing
    private let limits: ActionExecutionLimits
    private let gate = AsyncActionGate()
    private var activeOperations: [UUID: Task<ActionExecutionResult, Never>] = [:]
    private var presses: [PhysicalControlID: PressState] = [:]
    private var modifierOwners: [KeyboardModifier: Set<ActionOwner>] = [:]
    private var keyOwners: [MacVirtualKeyCode: Set<ActionOwner>] = [:]

    public init(service: any HostActionServicing, limits: ActionExecutionLimits = .init()) {
        self.service = service
        self.limits = limits
    }

    public func keyDown(
        control: PhysicalControlID,
        generation: SessionGeneration,
        action: ConfiguredAction,
        profileID: ProfileID,
        application: ApplicationBundleIdentifier? = nil,
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult
    ) async -> ActionExecutionResult {
        await submit { executor in
            await executor.performKeyDown(
                control: control,
                generation: generation,
                action: action,
                profileID: profileID,
                application: application,
                advanceMode: advanceMode
            )
        }
    }

    public func keyUp(
        control: PhysicalControlID,
        generation: SessionGeneration
    ) async -> ActionExecutionResult {
        await submit { executor in
            await executor.performKeyUp(control: control, generation: generation)
        }
    }

    public func executeDialAction(
        _ action: ConfiguredAction,
        profileID: ProfileID,
        dialMagnitude: Int,
        application: ApplicationBundleIdentifier? = nil,
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult
    ) async -> ActionExecutionResult {
        await submit { executor in
            await executor.performConfiguredAction(
                action,
                profileID: profileID,
                dialMagnitude: dialMagnitude,
                application: application,
                advanceMode: advanceMode
            )
        }
    }

    /// Cancels queued/in-flight work, then releases all remaining owned inputs.
    /// Cleanup is best effort and its typed failures are returned to the caller.
    @discardableResult
    public func cancelAndRelease() async -> [ActionExecutionFailure] {
        for task in activeOperations.values { task.cancel() }
        await gate.acquire()
        let failures = await releaseAllOwnedInputs()
        presses.removeAll()
        await gate.release()
        return failures
    }

    private func submit(
        operation: @escaping @Sendable (HostActionExecutor) async -> ActionExecutionResult
    ) async -> ActionExecutionResult {
        let requestID = UUID()
        let task = Task { await operation(self) }
        activeOperations[requestID] = task
        let result = await task.value
        activeOperations[requestID] = nil
        return ActionExecutionResult(requestID: requestID, outcome: result.outcome)
    }

    private func performKeyDown(
        control: PhysicalControlID,
        generation: SessionGeneration,
        action: ConfiguredAction,
        profileID: ProfileID,
        application: ApplicationBundleIdentifier?,
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult
    ) async -> ActionExecutionResult {
        await gate.acquire()
        let outcome: ActionExecutionOutcome
        if Task.isCancelled {
            outcome = .cancelled
        } else if control.kind != .key {
            outcome = .failed(.invalidInput)
        } else if presses[control] != nil {
            outcome = .ignored
        } else {

            let owner = ActionOwner.physical(control, generation)
            presses[control] = PressState(owner: owner)
            if case let .primitive(.holdKeys(chord)) = action {
                if let failure = await acquire(chord, owner: owner) {
                    let cleanup = await release(owner)
                    outcome = cleanup.first.map(ActionExecutionOutcome.failed) ?? .failed(failure)
                } else {
                    outcome = .acceptedUnverified
                }
            } else {
                switch await runConfigured(
                    action,
                    profileID: profileID,
                    dialMagnitude: 1,
                    application: application,
                    advanceMode: advanceMode
                ) {
                case .success: outcome = .acceptedUnverified
                case .modeChanged(let modeID): outcome = .modeChanged(profileID: profileID, modeID: modeID)
                case .ignored: outcome = .ignored
                case .failure(let failure, let completed):
                    if Task.isCancelled || failure == .cancelled {
                        outcome = .cancelled
                    } else if completed > 0 {
                        outcome = .partialFailure(completedSteps: completed, failure: failure)
                    } else {
                        outcome = .failed(failure)
                    }
                }
            }
        }
        await gate.release()
        return ActionExecutionResult(requestID: UUID(), outcome: outcome)
    }

    private func performKeyUp(
        control: PhysicalControlID,
        generation: SessionGeneration
    ) async -> ActionExecutionResult {
        await gate.acquire()
        let outcome: ActionExecutionOutcome
        if Task.isCancelled {
            outcome = .cancelled
        } else if control.kind != .key {
            outcome = .failed(.invalidInput)
        } else if let state = presses[control],
                  case let .physical(_, pressGeneration) = state.owner,
                  pressGeneration == generation {
            let failures = await release(state.owner)
            if failures.isEmpty {
                presses[control] = nil
                outcome = .acceptedUnverified
            } else {
                outcome = .failed(failures[0])
            }
        } else {
            outcome = .ignored
        }
        await gate.release()
        return ActionExecutionResult(requestID: UUID(), outcome: outcome)
    }

    private func performConfiguredAction(
        _ action: ConfiguredAction,
        profileID: ProfileID,
        dialMagnitude: Int,
        application: ApplicationBundleIdentifier?,
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult
    ) async -> ActionExecutionResult {
        let magnitudeLimit = limits.maximumDialMagnitude
        await gate.acquire()
        let outcome: ActionExecutionOutcome
        if Task.isCancelled {
            outcome = .cancelled
        } else if !Self.validMagnitude(dialMagnitude, limit: magnitudeLimit) {
            outcome = .failed(.invalidInput)
        } else {
            switch await runConfigured(
                action,
                profileID: profileID,
                dialMagnitude: dialMagnitude,
                application: application,
                advanceMode: advanceMode
            ) {
            case .success: outcome = .acceptedUnverified
            case .modeChanged(let modeID): outcome = .modeChanged(profileID: profileID, modeID: modeID)
            case .ignored: outcome = .ignored
            case .failure(let failure, let completed):
                if Task.isCancelled || failure == .cancelled {
                    outcome = .cancelled
                } else if completed > 0 {
                    outcome = .partialFailure(completedSteps: completed, failure: failure)
                } else {
                    outcome = .failed(failure)
                }
            }
        }
        await gate.release()
        return ActionExecutionResult(requestID: UUID(), outcome: outcome)
    }

    private enum RunResult {
        case success
        case modeChanged(DialModeID)
        case ignored
        case failure(ActionExecutionFailure, completed: Int)
    }

    private func runConfigured(
        _ action: ConfiguredAction,
        profileID: ProfileID,
        dialMagnitude: Int,
        application: ApplicationBundleIdentifier?,
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult
    ) async -> RunResult {
        switch action {
        case .primitive(let primitive):
            if case .doNothing = primitive { return .ignored }
            if case .nextDialMode = primitive {
                switch await advanceMode(profileID) {
                case .advanced(let modeID): return .modeChanged(modeID)
                case .failed(let failure): return .failure(failure, completed: 0)
                }
            }
            let owner = ActionOwner.chord(UUID())
            let failure = await performPrimitive(
                primitive,
                owner: owner,
                inSequence: false,
                profileID: profileID,
                dialMagnitude: dialMagnitude,
                application: application,
                advanceMode: advanceMode
            )
            if let failure {
                let cleanup = await release(owner)
                return .failure(cleanup.first ?? failure, completed: 0)
            }
            return .success
        case .sequence(let sequence):
            return await runSequence(
                sequence,
                profileID: profileID,
                dialMagnitude: dialMagnitude,
                application: application,
                advanceMode: advanceMode
            )
        }
    }

    private func runSequence(
        _ sequence: ActionSequence,
        profileID: ProfileID,
        dialMagnitude: Int,
        application: ApplicationBundleIdentifier?,
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult
    ) async -> RunResult {
        let start = ContinuousClock.now
        let owner = ActionOwner.sequence(UUID())
        var completedSteps = 0
        var failure: ActionExecutionFailure?
        var changedModeID: DialModeID?
        var executedHostAction = false
        for step in sequence.steps {
            guard !Task.isCancelled else {
                failure = .cancelled
                break
            }
            guard start.duration(to: .now) < limits.sequenceDeadline else {
                failure = .sequenceDeadlineExceeded
                break
            }
            switch step {
            case .pause(let milliseconds):
                do {
                    try await Task.sleep(for: .milliseconds(milliseconds))
                    completedSteps += 1
                } catch {
                    failure = .cancelled
                }
            case .action(let primitive):
                if case .doNothing = primitive {
                    completedSteps += 1
                    continue
                }
                if case .nextDialMode = primitive {
                    switch await advanceMode(profileID) {
                    case .advanced(let modeID):
                        changedModeID = modeID
                        completedSteps += 1
                    case .failed(let advanceFailure):
                        failure = advanceFailure
                    }
                    if failure != nil { break }
                    if start.duration(to: .now) >= limits.sequenceDeadline {
                        failure = .sequenceDeadlineExceeded
                        break
                    }
                    continue
                }
                executedHostAction = true
                failure = await performPrimitive(
                    primitive,
                    owner: owner,
                    inSequence: true,
                    profileID: profileID,
                    dialMagnitude: dialMagnitude,
                    application: application,
                    advanceMode: advanceMode
                )
                if failure != nil { break }
                completedSteps += 1
            }
            if failure != nil { break }
            if start.duration(to: .now) >= limits.sequenceDeadline {
                failure = .sequenceDeadlineExceeded
                break
            }
        }

        let cleanup = await release(owner)
        if failure == nil, let cleanupFailure = cleanup.first { failure = cleanupFailure }
        if let failure { return .failure(failure, completed: completedSteps) }
        if let changedModeID, !executedHostAction { return .modeChanged(changedModeID) }
        return .success
    }

    private func performPrimitive(
        _ action: PrimitiveAction,
        owner: ActionOwner,
        inSequence: Bool,
        profileID: ProfileID,
        dialMagnitude: Int,
        application: ApplicationBundleIdentifier?,
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult
    ) async -> ActionExecutionFailure? {
        switch action {
        case .doNothing:
            return nil
        case .keyboardShortcut(let chord):
            return await tap(chord, owner: ActionOwner.chord(UUID()))
        case .holdKeys(let chord):
            guard inSequence else { return .unsupportedAction("Hold Keys requires a physical key press") }
            return await acquire(chord, owner: owner)
        case .openApplication(let bundleID):
            return await perform(.launchOrActivateApplication(bundleID))
        case .runAppleShortcut(let name):
            return await perform(.runAppleShortcut(name))
        case .clipboardManagerShortcut(let chord):
            return await perform(.clipboardManagerShortcut(chord))
        case .scroll(let axis, let speed):
            return await perform(.scroll(axis: axis, detents: dialMagnitude, speed: speed))
        case .zoom(let direction):
            return await perform(.zoom(
                direction,
                steps: max(1, abs(dialMagnitude)),
                application: application
            ))
        case .nextDialMode:
            if case .failed(let failure) = await advanceMode(profileID) { return failure }
            return .unsupportedAction("Mode advance must be handled by the router")
        }
    }

    private func tap(_ chord: KeyboardChord, owner: ActionOwner) async -> ActionExecutionFailure? {
        if let failure = await acquireModifiers(chord.modifiers, owner: owner) {
            let cleanup = await release(owner)
            return cleanup.first ?? failure
        }
        if let failure = await acquireKey(chord.key, owner: owner) {
            let cleanup = await release(owner)
            return cleanup.first ?? failure
        }
        let release = await releaseKey(chord.key, owner: owner)
        let modifierRelease = await releaseModifiers(chord.modifiers, owner: owner)
        return release ?? modifierRelease
    }

    private func acquire(_ chord: KeyboardChord, owner: ActionOwner) async -> ActionExecutionFailure? {
        if let failure = await acquireModifiers(chord.modifiers, owner: owner) { return failure }
        return await acquireKey(chord.key, owner: owner)
    }

    private func acquireModifiers(
        _ modifiers: Set<KeyboardModifier>,
        owner: ActionOwner
    ) async -> ActionExecutionFailure? {
        for modifier in modifiers.sorted(by: { $0.rawValue < $1.rawValue }) {
            var owners = modifierOwners[modifier, default: []]
            if owners.contains(owner) { continue }
            if owners.isEmpty {
                if let failure = await perform(.keyboard(.down, .modifier(modifier))) { return failure }
            }
            owners.insert(owner)
            modifierOwners[modifier] = owners
        }
        return nil
    }

    private func acquireKey(_ key: MacVirtualKeyCode, owner: ActionOwner) async -> ActionExecutionFailure? {
        var owners = keyOwners[key, default: []]
        if owners.contains(owner) { return nil }
        if owners.isEmpty {
            if let failure = await perform(.keyboard(.down, .key(key))) { return failure }
        }
        owners.insert(owner)
        keyOwners[key] = owners
        return nil
    }

    private func release(_ owner: ActionOwner) async -> [ActionExecutionFailure] {
        var failures: [ActionExecutionFailure] = []
        for (key, owners) in Array(keyOwners) where owners.contains(owner) {
            if let failure = await releaseKey(key, owner: owner) { failures.append(failure) }
        }
        for (modifier, owners) in Array(modifierOwners) where owners.contains(owner) {
            if let failure = await releaseModifier(modifier, owner: owner) { failures.append(failure) }
        }
        return failures
    }

    private func releaseKey(
        _ key: MacVirtualKeyCode,
        owner: ActionOwner
    ) async -> ActionExecutionFailure? {
        guard var owners = keyOwners[key], owners.contains(owner) else { return nil }
        if owners.count == 1 {
            if let failure = await perform(.keyboard(.up, .key(key))) { return failure }
        }
        owners.remove(owner)
        if owners.isEmpty { keyOwners[key] = nil } else { keyOwners[key] = owners }
        return nil
    }

    private func releaseModifier(
        _ modifier: KeyboardModifier,
        owner: ActionOwner
    ) async -> ActionExecutionFailure? {
        guard var owners = modifierOwners[modifier], owners.contains(owner) else { return nil }
        if owners.count == 1 {
            if let failure = await perform(.keyboard(.up, .modifier(modifier))) { return failure }
        }
        owners.remove(owner)
        if owners.isEmpty { modifierOwners[modifier] = nil } else { modifierOwners[modifier] = owners }
        return nil
    }

    private func releaseModifiers(
        _ modifiers: Set<KeyboardModifier>,
        owner: ActionOwner
    ) async -> ActionExecutionFailure? {
        var firstFailure: ActionExecutionFailure?
        for modifier in modifiers.sorted(by: { $0.rawValue < $1.rawValue }).reversed() {
            if let failure = await releaseModifier(modifier, owner: owner), firstFailure == nil {
                firstFailure = failure
            }
        }
        return firstFailure
    }

    private func releaseAllOwnedInputs() async -> [ActionExecutionFailure] {
        let owners = Set(keyOwners.values.flatMap { $0 } + modifierOwners.values.flatMap { $0 })
        var failures: [ActionExecutionFailure] = []
        for owner in owners {
            failures.append(contentsOf: await release(owner))
        }
        return failures
    }

    private func perform(_ intent: HostActionIntent) async -> ActionExecutionFailure? {
        let race = TimeoutRace<HostActionServiceResult>()
        let timed: TimedValue<HostActionServiceResult> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.begin(continuation)
                race.start(timeout: limits.perActionTimeout) { await self.service.perform(intent) }
            }
        } onCancel: {
            race.cancel()
        }
        switch timed {
        case .timedOut:
            return .actionTimedOut
        case .cancelled:
            return .cancelled
        case .value(.acceptedUnverified):
            return nil
        case .value(.missingTarget(let target)):
            return .missingTarget(target)
        case .value(.unsupported(let reason)):
            return .unsupportedAction(RuntimeFailureText.sanitize(reason))
        case .value(.failed(let reason)):
            return .serviceFailed(RuntimeFailureText.sanitize(reason))
        }
    }

    private static func validMagnitude(_ value: Int, limit: Int) -> Bool {
        (-limit...limit).contains(value)
    }
}
