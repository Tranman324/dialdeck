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
    case timedOut(Value?)
    case cancelled(Value?)
    case skipped
}

private enum RaceEvent<Value: Sendable>: Sendable {
    case operation(Value)
    case skipped
    case timedOut
    case cancelled
}

/// Bridges task cancellation into a task-group child without creating an
/// unstructured task or relying on a long-duration sleeper.
private final class TaskCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var didSignal = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didSignal {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        didSignal = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

/// Structured race: every child is canceled and drained before this returns.
/// A late operation value is retained because it may describe an already
/// committed mode write that the caller must report accurately.
private func race<Value: Sendable>(
    timeout: Duration,
    operation: @escaping @Sendable () async -> Value
) async -> TimedValue<Value> {
    let cancellationSignal = TaskCancellationSignal()
    return await withTaskGroup(of: RaceEvent<Value>.self, returning: TimedValue<Value>.self) { group in
        group.addTask {
            guard !Task.isCancelled else { return .skipped }
            return .operation(await operation())
        }
        group.addTask {
            do {
                try await Task.sleep(for: timeout)
                return .timedOut
            } catch {
                return .cancelled
            }
        }
        group.addTask {
            await withTaskCancellationHandler {
                await cancellationSignal.wait()
            } onCancel: {
                cancellationSignal.signal()
            }
            return .cancelled
        }

        guard let first = await group.next() else { return .cancelled(nil) }
        let parentWasCancelled = Task.isCancelled
        var lateValue: Value?
        if case .operation(let value) = first { lateValue = value }
        group.cancelAll()
        while let event = await group.next() {
            if case .operation(let value) = event { lateValue = value }
        }

        switch first {
        case .operation(let value):
            return parentWasCancelled ? .cancelled(lateValue ?? value) : .value(value)
        case .timedOut:
            return .timedOut(lateValue)
        case .cancelled:
            return .cancelled(lateValue)
        case .skipped:
            return .cancelled(lateValue)
        }
    }
}

enum SequenceStopClassifier {
    static func failure(
        deadline: ContinuousClock.Instant?,
        isCancelled: Bool = Task.isCancelled,
        now: ContinuousClock.Instant = .now
    ) -> ActionExecutionFailure? {
        if let deadline, now >= deadline { return .sequenceDeadlineExceeded }
        if isCancelled { return .cancelled }
        return nil
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
    private let beforeServiceInvocation: (@Sendable () async -> Void)?
    private let gate = AsyncActionGate()
    private var activeOperations: [UUID: Task<ActionExecutionResult, Never>] = [:]
    private var admissionFloor: UInt64 = 0
    private var presses: [PhysicalControlID: PressState] = [:]
    private var modifierOwners: [KeyboardModifier: Set<ActionOwner>] = [:]
    private var keyOwners: [MacVirtualKeyCode: Set<ActionOwner>] = [:]

    public init(service: any HostActionServicing, limits: ActionExecutionLimits = .init()) {
        self.service = service
        self.limits = limits
        self.beforeServiceInvocation = nil
    }

    init(
        service: any HostActionServicing,
        limits: ActionExecutionLimits = .init(),
        beforeServiceInvocation: @escaping @Sendable () async -> Void
    ) {
        self.service = service
        self.limits = limits
        self.beforeServiceInvocation = beforeServiceInvocation
    }

    public func keyDown(
        control: PhysicalControlID,
        generation: SessionGeneration,
        action: ConfiguredAction,
        profileID: ProfileID,
        application: ApplicationBundleIdentifier? = nil,
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult,
        sequenceAdvanceMode: (@Sendable (ProfileID, ContinuousClock.Instant) async -> DialModeAdvanceResult)? = nil,
        admissionRevision: UInt64
    ) async -> ActionExecutionResult {
        await submit(admissionRevision: admissionRevision) { executor in
            await executor.performKeyDown(
                control: control,
                generation: generation,
                action: action,
                profileID: profileID,
                application: application,
                advanceMode: advanceMode,
                sequenceAdvanceMode: sequenceAdvanceMode,
                admissionRevision: admissionRevision
            )
        }
    }

    public func keyUp(
        control: PhysicalControlID,
        generation: SessionGeneration,
        admissionRevision: UInt64
    ) async -> ActionExecutionResult {
        await submit(admissionRevision: admissionRevision) { executor in
            await executor.performKeyUp(
                control: control,
                generation: generation,
                admissionRevision: admissionRevision
            )
        }
    }

    public func executeDialAction(
        _ action: ConfiguredAction,
        profileID: ProfileID,
        dialMagnitude: Int,
        application: ApplicationBundleIdentifier? = nil,
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult,
        sequenceAdvanceMode: (@Sendable (ProfileID, ContinuousClock.Instant) async -> DialModeAdvanceResult)? = nil,
        admissionRevision: UInt64
    ) async -> ActionExecutionResult {
        await submit(admissionRevision: admissionRevision) { executor in
            await executor.performConfiguredAction(
                action,
                profileID: profileID,
                dialMagnitude: dialMagnitude,
                application: application,
                advanceMode: advanceMode,
                sequenceAdvanceMode: sequenceAdvanceMode,
                admissionRevision: admissionRevision
            )
        }
    }

    /// Cancels queued/in-flight work, then releases all remaining owned inputs.
    /// Cleanup is best effort and its typed failures are returned to the caller.
    @discardableResult
    public func cancelAndRelease(floor: UInt64) async -> [ActionExecutionFailure] {
        admissionFloor = max(admissionFloor, floor)
        for task in activeOperations.values { task.cancel() }
        await gate.acquire()
        let failures = await releaseAllOwnedInputs()
        presses.removeAll()
        await gate.release()
        return failures
    }

    private func submit(
        admissionRevision: UInt64,
        operation: @escaping @Sendable (HostActionExecutor) async -> ActionExecutionResult
    ) async -> ActionExecutionResult {
        guard admissionRevision >= admissionFloor else {
            return ActionExecutionResult(outcome: .ignored)
        }
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
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult,
        sequenceAdvanceMode: (@Sendable (ProfileID, ContinuousClock.Instant) async -> DialModeAdvanceResult)?,
        admissionRevision: UInt64
    ) async -> ActionExecutionResult {
        await gate.acquire()
        guard admissionRevision >= admissionFloor else {
            await gate.release()
            return ActionExecutionResult(outcome: .ignored)
        }
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
                if let failure = await acquire(chord, owner: owner, sequenceDeadline: nil) {
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
                    sequenceAdvanceMode: sequenceAdvanceMode,
                    advanceMode: advanceMode
                ) {
                case .success: outcome = .acceptedUnverified
                case .modeChanged(let modeID): outcome = .modeChanged(profileID: profileID, modeID: modeID)
                case .ignored: outcome = .ignored
                case .failure(let failure, let completed):
                    if failure == .sequenceDeadlineExceeded {
                        if completed > 0 {
                            outcome = .partialFailure(completedSteps: completed, failure: failure)
                        } else {
                            outcome = .failed(failure)
                        }
                    } else if Task.isCancelled || failure == .cancelled {
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
        generation: SessionGeneration,
        admissionRevision: UInt64
    ) async -> ActionExecutionResult {
        await gate.acquire()
        guard admissionRevision >= admissionFloor else {
            await gate.release()
            return ActionExecutionResult(outcome: .ignored)
        }
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
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult,
        sequenceAdvanceMode: (@Sendable (ProfileID, ContinuousClock.Instant) async -> DialModeAdvanceResult)?,
        admissionRevision: UInt64
    ) async -> ActionExecutionResult {
        let magnitudeLimit = limits.maximumDialMagnitude
        await gate.acquire()
        guard admissionRevision >= admissionFloor else {
            await gate.release()
            return ActionExecutionResult(outcome: .ignored)
        }
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
                sequenceAdvanceMode: sequenceAdvanceMode,
                advanceMode: advanceMode
            ) {
            case .success: outcome = .acceptedUnverified
            case .modeChanged(let modeID): outcome = .modeChanged(profileID: profileID, modeID: modeID)
            case .ignored: outcome = .ignored
            case .failure(let failure, let completed):
                if failure == .sequenceDeadlineExceeded {
                    if completed > 0 {
                        outcome = .partialFailure(completedSteps: completed, failure: failure)
                    } else {
                        outcome = .failed(failure)
                    }
                } else if Task.isCancelled || failure == .cancelled {
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
        sequenceAdvanceMode: (@Sendable (ProfileID, ContinuousClock.Instant) async -> DialModeAdvanceResult)?,
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
                sequenceDeadline: nil,
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
                sequenceAdvanceMode: sequenceAdvanceMode,
                advanceMode: advanceMode
            )
        }
    }

    private func runSequence(
        _ sequence: ActionSequence,
        profileID: ProfileID,
        dialMagnitude: Int,
        application: ApplicationBundleIdentifier?,
        sequenceAdvanceMode: (@Sendable (ProfileID, ContinuousClock.Instant) async -> DialModeAdvanceResult)?,
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult
    ) async -> RunResult {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: limits.sequenceDeadline)
        let owner = ActionOwner.sequence(UUID())
        var completedSteps = 0
        var failure: ActionExecutionFailure?
        var changedModeID: DialModeID?
        var executedHostAction = false
        for step in sequence.steps {
            if let stop = SequenceStopClassifier.failure(deadline: deadline) {
                failure = stop
                break
            }
            switch step {
            case .pause(let milliseconds):
                let remaining = ContinuousClock.now.duration(to: deadline)
                if let stop = SequenceStopClassifier.failure(deadline: deadline) {
                    failure = stop
                    break
                }
                guard remaining > .zero else { failure = .sequenceDeadlineExceeded; break }
                do {
                    try await Task.sleep(for: min(.milliseconds(milliseconds), remaining))
                    if let stop = SequenceStopClassifier.failure(deadline: deadline) {
                        failure = stop
                    } else {
                        completedSteps += 1
                    }
                } catch {
                    failure = SequenceStopClassifier.failure(deadline: deadline) ?? .cancelled
                }
            case .action(let primitive):
                if case .doNothing = primitive {
                    completedSteps += 1
                    continue
                }
                if case .nextDialMode = primitive {
                    switch await boundedModeAdvance(
                        profileID,
                        deadline: deadline,
                        advanceMode: advanceMode,
                        sequenceAdvanceMode: sequenceAdvanceMode
                    ) {
                    case .timedOut(let lateResult):
                        if case .advanced(let modeID)? = lateResult {
                            changedModeID = modeID
                            completedSteps += 1
                            continue
                        }
                        failure = .sequenceDeadlineExceeded
                    case .cancelled(let lateResult):
                        if case .advanced(let modeID)? = lateResult {
                            changedModeID = modeID
                            completedSteps += 1
                            continue
                        }
                        failure = SequenceStopClassifier.failure(deadline: deadline) ?? .cancelled
                    case .skipped:
                        failure = SequenceStopClassifier.failure(deadline: deadline) ?? .cancelled
                    case .value(.advanced(let modeID)):
                        changedModeID = modeID
                        completedSteps += 1
                    case .value(.failed(let advanceFailure)):
                        failure = SequenceStopClassifier.failure(deadline: deadline) ?? advanceFailure
                    }
                    if failure != nil { break }
                    // A joined synchronous store commit is authoritative even
                    // when it completes after the deadline. Any following step
                    // is rejected by the loop's deadline guard.
                    continue
                }
                if case .holdKeys = primitive {
                    // Held inputs are temporary executor-owned state. If the
                    // sequence ends with a committed mode change, their
                    // cancellation-only release can remain pending in the
                    // executor cleanup path without masking that result.
                } else {
                    executedHostAction = true
                }
                failure = await performPrimitive(
                    primitive,
                    owner: owner,
                    inSequence: true,
                    profileID: profileID,
                    dialMagnitude: dialMagnitude,
                    application: application,
                    sequenceDeadline: deadline,
                    advanceMode: advanceMode
                )
                if failure != nil { break }
                completedSteps += 1
            }
            if failure != nil { break }
            if let stop = SequenceStopClassifier.failure(deadline: deadline) {
                failure = stop
                break
            }
        }

        let cleanup = await release(owner)
        let terminalModeWithPendingCancellationCleanup = changedModeID != nil
            && !executedHostAction
            && cleanup.allSatisfy { $0 == .cancelled }
        if failure == nil,
           !terminalModeWithPendingCancellationCleanup,
           let cleanupFailure = cleanup.first {
            failure = cleanupFailure
        }
        if failure != nil, let stop = SequenceStopClassifier.failure(deadline: deadline) {
            failure = stop
        }
        if let failure { return .failure(failure, completed: completedSteps) }
        if let changedModeID, !executedHostAction { return .modeChanged(changedModeID) }
        return .success
    }

    private func boundedModeAdvance(
        _ profileID: ProfileID,
        deadline: ContinuousClock.Instant,
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult,
        sequenceAdvanceMode: (@Sendable (ProfileID, ContinuousClock.Instant) async -> DialModeAdvanceResult)?
    ) async -> TimedValue<DialModeAdvanceResult> {
        if let stop = SequenceStopClassifier.failure(deadline: deadline) {
            return stop == .sequenceDeadlineExceeded ? .timedOut(nil) : .cancelled(nil)
        }
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return .timedOut(nil) }
        return await race(timeout: remaining) {
            if let sequenceAdvanceMode {
                return await sequenceAdvanceMode(profileID, deadline)
            }
            return await advanceMode(profileID)
        }
    }

    private func performPrimitive(
        _ action: PrimitiveAction,
        owner: ActionOwner,
        inSequence: Bool,
        profileID: ProfileID,
        dialMagnitude: Int,
        application: ApplicationBundleIdentifier?,
        sequenceDeadline: ContinuousClock.Instant?,
        advanceMode: @escaping @Sendable (ProfileID) async -> DialModeAdvanceResult
    ) async -> ActionExecutionFailure? {
        switch action {
        case .doNothing:
            return nil
        case .keyboardShortcut(let chord):
            return await tap(chord, owner: ActionOwner.chord(UUID()), sequenceDeadline: sequenceDeadline)
        case .holdKeys(let chord):
            guard inSequence else { return .unsupportedAction("Hold Keys requires a physical key press") }
            return await acquire(chord, owner: owner, sequenceDeadline: sequenceDeadline)
        case .openApplication(let bundleID):
            return await perform(.launchOrActivateApplication(bundleID), sequenceDeadline: sequenceDeadline)
        case .runAppleShortcut(let name):
            return await perform(.runAppleShortcut(name), sequenceDeadline: sequenceDeadline)
        case .clipboardManagerShortcut(let chord):
            return await perform(.clipboardManagerShortcut(chord), sequenceDeadline: sequenceDeadline)
        case .scroll(let axis, let speed):
            return await perform(
                .scroll(axis: axis, detents: dialMagnitude, speed: speed),
                sequenceDeadline: sequenceDeadline
            )
        case .zoom(let direction):
            return await perform(.zoom(
                direction,
                steps: max(1, abs(dialMagnitude)),
                application: application
            ), sequenceDeadline: sequenceDeadline)
        case .nextDialMode:
            if case .failed(let failure) = await advanceMode(profileID) { return failure }
            return .unsupportedAction("Mode advance must be handled by the router")
        }
    }

    private func tap(
        _ chord: KeyboardChord,
        owner: ActionOwner,
        sequenceDeadline: ContinuousClock.Instant?
    ) async -> ActionExecutionFailure? {
        if let failure = await acquireModifiers(chord.modifiers, owner: owner, sequenceDeadline: sequenceDeadline) {
            let cleanup = await release(owner)
            return cleanup.first ?? failure
        }
        if let failure = await acquireKey(chord.key, owner: owner, sequenceDeadline: sequenceDeadline) {
            let cleanup = await release(owner)
            return cleanup.first ?? failure
        }
        let release = await releaseKey(chord.key, owner: owner)
        let modifierRelease = await releaseModifiers(chord.modifiers, owner: owner)
        return release ?? modifierRelease
    }

    private func acquire(
        _ chord: KeyboardChord,
        owner: ActionOwner,
        sequenceDeadline: ContinuousClock.Instant?
    ) async -> ActionExecutionFailure? {
        if let failure = await acquireModifiers(chord.modifiers, owner: owner, sequenceDeadline: sequenceDeadline) {
            return failure
        }
        return await acquireKey(chord.key, owner: owner, sequenceDeadline: sequenceDeadline)
    }

    private func acquireModifiers(
        _ modifiers: Set<KeyboardModifier>,
        owner: ActionOwner,
        sequenceDeadline: ContinuousClock.Instant?
    ) async -> ActionExecutionFailure? {
        for modifier in modifiers.sorted(by: { $0.rawValue < $1.rawValue }) {
            var owners = modifierOwners[modifier, default: []]
            if owners.contains(owner) { continue }
            if owners.isEmpty {
                if let failure = await perform(
                    .keyboard(.down, .modifier(modifier)),
                    sequenceDeadline: sequenceDeadline,
                    acceptedDownOwner: owner
                ) { return failure }
            }
            owners.insert(owner)
            modifierOwners[modifier] = owners
        }
        return nil
    }

    private func acquireKey(
        _ key: MacVirtualKeyCode,
        owner: ActionOwner,
        sequenceDeadline: ContinuousClock.Instant?
    ) async -> ActionExecutionFailure? {
        var owners = keyOwners[key, default: []]
        if owners.contains(owner) { return nil }
        if owners.isEmpty {
            if let failure = await perform(
                .keyboard(.down, .key(key)),
                sequenceDeadline: sequenceDeadline,
                acceptedDownOwner: owner
            ) { return failure }
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

    private func perform(
        _ intent: HostActionIntent,
        sequenceDeadline: ContinuousClock.Instant? = nil,
        acceptedDownOwner: ActionOwner? = nil
    ) async -> ActionExecutionFailure? {
        var timeout = limits.perActionTimeout
        var timeoutFailure: ActionExecutionFailure = .actionTimedOut
        if let sequenceDeadline {
            if let stop = SequenceStopClassifier.failure(deadline: sequenceDeadline) {
                return stop
            }
            let remaining = ContinuousClock.now.duration(to: sequenceDeadline)
            guard remaining > .zero else { return .sequenceDeadlineExceeded }
            if remaining <= timeout {
                timeout = remaining
                timeoutFailure = .sequenceDeadlineExceeded
            }
        }
        let timed = await race(timeout: timeout) { [service, beforeServiceInvocation] in
            if let beforeServiceInvocation { await beforeServiceInvocation() }
            guard !Task.isCancelled else { return nil as HostActionServiceResult? }
            return await service.perform(intent)
        }
        switch timed {
        case .timedOut(let lateResult):
            recordLateAcceptedDown(lateResult.flatMap { $0 }, intent: intent, owner: acceptedDownOwner)
            return SequenceStopClassifier.failure(deadline: sequenceDeadline) ?? timeoutFailure
        case .cancelled(let lateResult):
            recordLateAcceptedDown(lateResult.flatMap { $0 }, intent: intent, owner: acceptedDownOwner)
            return SequenceStopClassifier.failure(deadline: sequenceDeadline) ?? .cancelled
        case .skipped:
            return SequenceStopClassifier.failure(deadline: sequenceDeadline) ?? .cancelled
        case .value(nil):
            return SequenceStopClassifier.failure(deadline: sequenceDeadline) ?? .cancelled
        case .value(.some(.acceptedUnverified)):
            return nil
        case .value(.some(.missingTarget(let target))):
            return SequenceStopClassifier.failure(deadline: sequenceDeadline) ?? .missingTarget(target)
        case .value(.some(.unsupported(let reason))):
            return SequenceStopClassifier.failure(deadline: sequenceDeadline)
                ?? .unsupportedAction(RuntimeFailureText.sanitize(reason))
        case .value(.some(.failed(let reason))):
            return SequenceStopClassifier.failure(deadline: sequenceDeadline)
                ?? .serviceFailed(RuntimeFailureText.sanitize(reason))
        }
    }

    /// A timed-out or canceled adapter call may still report that its down
    /// intent was accepted. Preserve ownership before returning the typed
    /// failure so executor cleanup can issue the balancing up transition.
    private func recordLateAcceptedDown(
        _ result: HostActionServiceResult?,
        intent: HostActionIntent,
        owner: ActionOwner?
    ) {
        guard result == .acceptedUnverified, let owner else { return }
        switch intent {
        case .keyboard(.down, .key(let key)):
            keyOwners[key, default: []].insert(owner)
        case .keyboard(.down, .modifier(let modifier)):
            modifierOwners[modifier, default: []].insert(owner)
        default:
            break
        }
    }

    private static func validMagnitude(_ value: Int, limit: Int) -> Bool {
        (-limit...limit).contains(value)
    }
}
