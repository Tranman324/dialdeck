import Foundation

public protocol ForegroundApplicationProviding: Sendable {
    /// Implementations validate bundle identifiers before returning them.
    func foregroundBundleIdentifier() async -> ApplicationBundleIdentifier?
}

public protocol PhysicalActionMappingProviding: Sendable {
    /// A nil result means the control has no configured button assignment.
    func actionTarget(for control: PhysicalControlID) async -> ActionAssignmentTarget?
}

public struct ActionRuntimeSnapshot: Equatable, Sendable {
    public let status: RuntimeStatus
    public let isEditing: Bool
    public let foregroundBundleIdentifier: ApplicationBundleIdentifier?
    public let activeProfileID: ProfileID?
    public let selectedDialModeID: DialModeID?
    public let lastActionResult: ActionExecutionResult?

    public init(
        status: RuntimeStatus,
        isEditing: Bool,
        foregroundBundleIdentifier: ApplicationBundleIdentifier?,
        activeProfileID: ProfileID?,
        selectedDialModeID: DialModeID?,
        lastActionResult: ActionExecutionResult?
    ) {
        self.status = status
        self.isEditing = isEditing
        self.foregroundBundleIdentifier = foregroundBundleIdentifier
        self.activeProfileID = activeProfileID
        self.selectedDialModeID = selectedDialModeID
        self.lastActionResult = lastActionResult
    }
}

/// Host-side action router. All input and OS-facing behavior is injected, and
/// configuration changes are persisted through the accepted store actor.
public actor ActionRuntime: NormalizedInputConsumer, RuntimeCommandHandling, RuntimeStatusProviding {
    private struct RoutePermit: Sendable {
        let generation: SessionGeneration
        let revision: UInt64
    }

    private let inputProducer: any InputEventProducing
    private let capabilities: any DeviceCapabilityProviding
    private let programmer: any DeviceProgramming
    private let keyAssignmentProgrammer: (any DeviceKeyAssignmentProgramming)?
    private let lightingProgrammer: (any DeviceLightingProgramming)?
    private let foregroundApplication: any ForegroundApplicationProviding
    private let controlMapping: any PhysicalActionMappingProviding
    private let configurationStore: ConfigurationStore
    private let executor: HostActionExecutor
    private var configuration: Configuration?
    private var session: (any InputSessionHandle)?
    private var generation: SessionGeneration?
    private var nextGeneration: UInt64 = 1
    private var status: RuntimeStatus = .idle
    private var isEditing = false
    private var foregroundBundleIdentifier: ApplicationBundleIdentifier?
    private var activeProfileID: ProfileID?
    private var selectedDialModeID: DialModeID?
    private var lastActionResult: ActionExecutionResult?
    private let inputGate = AsyncActionGate()
    private let configurationMutationGate = AsyncActionGate()
    private var routingRevision: UInt64 = 0
    private var configurationMutationsInProgress = 0
    private var modeAdvanceStartGateForTesting: (@Sendable () async -> Void)?

    public init(
        inputProducer: any InputEventProducing,
        capabilities: any DeviceCapabilityProviding,
        programmer: any DeviceProgramming,
        foregroundApplication: any ForegroundApplicationProviding,
        controlMapping: any PhysicalActionMappingProviding,
        configurationStore: ConfigurationStore,
        actionService: any HostActionServicing,
        executionLimits: ActionExecutionLimits = .init(),
        lightingProgrammer: (any DeviceLightingProgramming)? = nil,
        keyAssignmentProgrammer: (any DeviceKeyAssignmentProgramming)? = nil
    ) {
        self.inputProducer = inputProducer
        self.capabilities = capabilities
        self.programmer = programmer
        self.keyAssignmentProgrammer = keyAssignmentProgrammer
        self.lightingProgrammer = lightingProgrammer
        self.foregroundApplication = foregroundApplication
        self.controlMapping = controlMapping
        self.configurationStore = configurationStore
        self.executor = HostActionExecutor(service: actionService, limits: executionLimits)
    }

    public func submit(_ command: RuntimeCommand) async -> RuntimeCommandCompletion {
        switch command {
        case .start:
            await startSession()
            return .noProgrammingResult
        case .stop:
            await stopSession()
            return .noProgrammingResult
        case .refreshCapabilities:
            await refreshCapabilities()
            return .noProgrammingResult
        case .program(let request):
            let result = await programmer.program(request)
            guard result.requestID == request.requestID else {
                return .programming(ProgrammingResult(
                    requestID: request.requestID,
                    outcome: .failed(.init(reason: "Programming service returned a mismatched request ID"))
                ))
            }
            return .programming(result)
        case .programKeyAssignment(let request):
            guard request.acceptsPersistentOverwrite else {
                return .keyAssignmentProgramming(.init(
                    requestID: request.requestID,
                    outcome: .failed(reason: "Persistent overwrite was not accepted", reportsAccepted: 0)
                ))
            }
            guard let keyAssignmentProgrammer else {
                return .keyAssignmentProgramming(.init(
                    requestID: request.requestID,
                    outcome: .failed(reason: "No supported key assignment programmer is configured", reportsAccepted: 0)
                ))
            }
            let result = await keyAssignmentProgrammer.programKeyAssignment(request)
            guard result.requestID == request.requestID else {
                let accepted: Int
                switch result.outcome {
                case .sentUnverified(let reportsAccepted),
                     .failed(_, let reportsAccepted),
                     .cancelled(let reportsAccepted):
                    accepted = reportsAccepted
                }
                return .keyAssignmentProgramming(.init(
                    requestID: request.requestID,
                    outcome: .failed(
                        reason: "Key assignment service returned a mismatched request ID",
                        reportsAccepted: accepted
                    )
                ))
            }
            return .keyAssignmentProgramming(result)
        case .programLighting(let request):
            guard request.acceptsPersistentOverwrite else {
                return .lightingProgramming(.init(
                    requestID: request.requestID,
                    outcome: .failed(reason: "Persistent overwrite was not accepted", reportsAccepted: 0)
                ))
            }
            guard let lightingProgrammer else {
                return .lightingProgramming(.init(
                    requestID: request.requestID,
                    outcome: .failed(reason: "No supported device lighting programmer is configured", reportsAccepted: 0)
                ))
            }
            let result = await lightingProgrammer.programLighting(request)
            guard result.requestID == request.requestID else {
                let accepted: Int
                switch result.outcome {
                case .sentUnverified(let reportsAccepted),
                     .failed(_, let reportsAccepted),
                     .cancelled(let reportsAccepted):
                    accepted = reportsAccepted
                }
                return .lightingProgramming(.init(
                    requestID: request.requestID,
                    outcome: .failed(
                        reason: "Lighting service returned a mismatched request ID",
                        reportsAccepted: accepted
                    )
                ))
            }
            return .lightingProgramming(result)
        }
    }

    public func currentStatus() async -> RuntimeStatus { status }

    public func currentSnapshot() -> ActionRuntimeSnapshot {
        ActionRuntimeSnapshot(
            status: status,
            isEditing: isEditing,
            foregroundBundleIdentifier: foregroundBundleIdentifier,
            activeProfileID: activeProfileID,
            selectedDialModeID: selectedDialModeID,
            lastActionResult: lastActionResult
        )
    }

    func setModeAdvanceStartGateForTesting(_ gate: (@Sendable () async -> Void)?) {
        modeAdvanceStartGateForTesting = gate
    }

    /// Configuration editors should save through this method so a newly
    /// installed snapshot and its remembered modes become active together.
    public func installConfiguration(_ newConfiguration: Configuration) async throws {
        beginConfigurationMutation()
        await cancelExecutorAndRecordCleanupFailure()
        await configurationMutationGate.acquire()
        do {
            try await configurationStore.save(newConfiguration)
            configuration = newConfiguration
            refreshSelectedModeSnapshot()
            await finishConfigurationMutation()
        } catch {
            await finishConfigurationMutation()
            throw error
        }
    }

    /// Loads the current stored snapshot. Reconstructing ActionRuntime after an
    /// app restart also restores each profile's remembered mode from the store.
    public func reloadConfiguration() async throws {
        beginConfigurationMutation()
        await cancelExecutorAndRecordCleanupFailure()
        await configurationMutationGate.acquire()
        do {
            configuration = try await configurationStore.load()
            refreshSelectedModeSnapshot()
            await finishConfigurationMutation()
        } catch {
            await finishConfigurationMutation()
            throw error
        }
    }

    public func setConfigurationEditing(_ editing: Bool) async {
        if isEditing != editing { routingRevision &+= 1 }
        isEditing = editing
        if editing {
            await cancelExecutorAndRecordCleanupFailure()
        }
    }

    /// The accepted normalized event contract has no dial-button payload yet.
    /// Device adapters may call this explicit entry point when they have a
    /// validated dial-press event; it does not infer a physical mapping.
    @discardableResult
    public func dialPressed(
        control: PhysicalControlID,
        generation eventGeneration: SessionGeneration
    ) async -> ActionExecutionResult {
        await inputGate.acquire()
        let result = await performDialPressed(control: control, generation: eventGeneration)
        await inputGate.release()
        return record(result)
    }

    private func performDialPressed(
        control: PhysicalControlID,
        generation eventGeneration: SessionGeneration
    ) async -> ActionExecutionResult {
        guard control.kind == .dial else {
            return ActionExecutionResult(outcome: .failed(.invalidInput))
        }
        guard let permit = routePermit(for: eventGeneration) else {
            return ActionExecutionResult(outcome: .ignored)
        }
        do {
            let config = try await loadConfigurationIfNeeded()
            guard routeIsCurrent(permit) else { return ActionExecutionResult(outcome: .ignored) }
            let bundleID = await foregroundApplication.foregroundBundleIdentifier()
            guard routeIsCurrent(permit) else { return ActionExecutionResult(outcome: .ignored) }
            let profile = ProfileActionResolver.profileForRouting(
                bundleIdentifier: bundleID,
                in: config
            )
            updateRoute(bundleID: bundleID, profile: profile)
            guard routeIsCurrent(permit) else { return ActionExecutionResult(outcome: .ignored) }
            let result = await executor.executeDialAction(
                profile.selectedDialMode.press,
                profileID: profile.id,
                dialMagnitude: 1,
                application: bundleID,
                advanceMode: modeAdvanceHandler(for: permit),
                sequenceAdvanceMode: sequenceModeAdvanceHandler(for: permit),
                admissionRevision: permit.revision
            )
            return routeIsCurrent(permit) ? result : ActionExecutionResult(requestID: result.requestID, outcome: .ignored)
        } catch {
            guard routeIsCurrent(permit) else { return ActionExecutionResult(outcome: .ignored) }
            return ActionExecutionResult(outcome: .failed(.modePersistenceFailed(RuntimeFailureText.sanitize(String(describing: error)))))
        }
    }

    public func consume(_ event: NormalizedInputEvent) async {
        await inputGate.acquire()
        guard event.generation == generation,
              case .running(let runningGeneration) = status,
              runningGeneration == event.generation,
              !isEditing else {
            await inputGate.release()
            return
        }

        switch event.payload {
        case .keyDown:
            await routeKeyDown(event)
        case .keyUp:
            let result = await executor.keyUp(
                control: event.control,
                generation: event.generation,
                admissionRevision: routingRevision
            )
            setActionResult(result)
        case .dialRotation(let delta):
            await routeDialRotation(event, delta: delta)
        }
        await inputGate.release()
    }

    public func sessionLifecycleChanged(_ event: SessionLifecycleEvent) async {
        switch event {
        case .started(let eventGeneration):
            guard generation == eventGeneration else { return }
            status = .running(generation: eventGeneration)
        case .stopping(let eventGeneration):
            guard generation == eventGeneration else { return }
            routingRevision &+= 1
            status = .stopping(generation: eventGeneration)
            let failures = await executor.cancelAndRelease(floor: routingRevision)
            if let failure = failures.first {
                status = .failed(.operationFailed(reason: RuntimeFailureText.sanitize("Input cleanup failed: \(failure)")))
            }
        case .stopped(let eventGeneration):
            guard generation == eventGeneration else { return }
            routingRevision &+= 1
            generation = nil
            session = nil
            let failures = await executor.cancelAndRelease(floor: routingRevision)
            status = failures.first.map {
                .failed(.operationFailed(reason: RuntimeFailureText.sanitize("Input cleanup failed: \($0)")))
            } ?? .idle
        case .failed(let eventGeneration, let reason):
            guard generation == eventGeneration else { return }
            routingRevision &+= 1
            generation = nil
            session = nil
            let failures = await executor.cancelAndRelease(floor: routingRevision)
            let suffix = failures.first.map { "; input cleanup failed: \($0)" } ?? ""
            status = .failed(.operationFailed(reason: RuntimeFailureText.sanitize(reason + suffix)))
        }
    }

    private func startSession() async {
        if generation != nil || session != nil {
            await stopSession()
        }
        do {
            _ = try await loadConfigurationIfNeeded()
        } catch {
            status = .failed(.operationFailed(reason: RuntimeFailureText.sanitize("Configuration unavailable: \(error)")))
            return
        }

        let capability = await capabilities.currentCapabilities()
        if case .denied(let reason) = capability.access {
            status = .failed(.inputAccessDenied)
            lastActionResult = ActionExecutionResult(outcome: .failed(.serviceFailed(RuntimeFailureText.sanitize(reason))))
            return
        }
        if case .unavailable(let reason) = capability.access {
            status = .failed(.operationFailed(reason: RuntimeFailureText.sanitize(reason)))
            return
        }
        if case .unavailable(let reason) = capability.detection {
            status = .failed(.operationFailed(reason: RuntimeFailureText.sanitize(reason)))
            return
        }
        if case .notDetected = capability.detection {
            status = .failed(.deviceUnavailable)
            return
        }

        let newGeneration = SessionGeneration(nextGeneration)
        nextGeneration &+= 1
        generation = newGeneration
        status = .starting
        do {
            let newSession = try await inputProducer.start(generation: newGeneration, consumer: self)
            guard generation == newGeneration else {
                await newSession.cancel()
                return
            }
            session = newSession
            status = .running(generation: newGeneration)
        } catch {
            guard generation == newGeneration else { return }
            generation = nil
            status = .failed(.operationFailed(reason: RuntimeFailureText.sanitize(String(describing: error))))
        }
    }

    private func stopSession() async {
        let stoppingGeneration = generation
        let oldSession = session
        routingRevision &+= 1
        if let stoppingGeneration { status = .stopping(generation: stoppingGeneration) }
        generation = nil
        session = nil
        let failures = await executor.cancelAndRelease(floor: routingRevision)
        if let oldSession { await oldSession.cancel() }
        if generation == nil {
            status = failures.first.map {
                .failed(.operationFailed(reason: RuntimeFailureText.sanitize("Input cleanup failed: \($0)")))
            } ?? .idle
        }
    }

    private func refreshCapabilities() async {
        let current = await capabilities.currentCapabilities()
        if case .denied = current.access {
            await stopSession()
            status = .failed(.inputAccessDenied)
        } else if case .unavailable(let reason) = current.access {
            await stopSession()
            status = .failed(.operationFailed(reason: RuntimeFailureText.sanitize(reason)))
        } else if case .notDetected = current.detection {
            await stopSession()
            status = .failed(.deviceUnavailable)
        } else if case .unavailable(let reason) = current.detection {
            await stopSession()
            status = .failed(.operationFailed(reason: RuntimeFailureText.sanitize(reason)))
        }
    }

    private func routeKeyDown(_ event: NormalizedInputEvent) async {
        guard let permit = routePermit(for: event.generation) else { return }
        guard let target = await controlMapping.actionTarget(for: event.control) else {
            guard routeIsCurrent(permit) else { return }
            setActionResult(ActionExecutionResult(outcome: .ignored))
            return
        }
        guard routeIsCurrent(permit) else { return }
        do {
            let config = try await loadConfigurationIfNeeded()
            guard routeIsCurrent(permit) else { return }
            let bundleID = await foregroundApplication.foregroundBundleIdentifier()
            guard routeIsCurrent(permit) else { return }
            let resolved = ProfileActionResolver.resolve(
                bundleIdentifier: bundleID,
                target: target,
                in: config
            )
            let profileID: ProfileID
            switch resolved.source {
            case .applicationOverride(let id), .inheritedDefault(let id), .defaultProfile(let id):
                profileID = id
            }
            let profile = config.profile(id: profileID) ?? config.defaultProfile
            updateRoute(bundleID: bundleID, profile: profile)
            guard routeIsCurrent(permit) else { return }
            let result = await executor.keyDown(
                control: event.control,
                generation: event.generation,
                action: resolved.action,
                profileID: profileID,
                application: bundleID,
                advanceMode: modeAdvanceHandler(for: permit),
                sequenceAdvanceMode: sequenceModeAdvanceHandler(for: permit),
                admissionRevision: permit.revision
            )
            setActionResult(result)
        } catch {
            guard routeIsCurrent(permit) else { return }
            setActionResult(ActionExecutionResult(outcome: .failed(
                .modePersistenceFailed(RuntimeFailureText.sanitize("Configuration unavailable: \(error)"))
            )))
        }
    }

    private func routeDialRotation(_ event: NormalizedInputEvent, delta: Int) async {
        guard let permit = routePermit(for: event.generation) else { return }
        guard delta != 0, absSafely(delta) <= 100 else {
            if delta != 0 { setActionResult(ActionExecutionResult(outcome: .failed(.invalidInput))) }
            return
        }
        do {
            let config = try await loadConfigurationIfNeeded()
            guard routeIsCurrent(permit) else { return }
            let bundleID = await foregroundApplication.foregroundBundleIdentifier()
            guard routeIsCurrent(permit) else { return }
            let target: DialModeActionTarget = delta < 0 ? .counterclockwise : .clockwise
            let resolved = ProfileActionResolver.resolveDialModeAction(
                bundleIdentifier: bundleID,
                target: target,
                in: config
            )
            guard let profile = config.profile(id: resolved.profileID) else { return }
            updateRoute(bundleID: bundleID, profile: profile)
            guard routeIsCurrent(permit) else { return }
            let result = await executor.executeDialAction(
                resolved.action,
                profileID: resolved.profileID,
                dialMagnitude: delta,
                application: bundleID,
                advanceMode: modeAdvanceHandler(for: permit),
                sequenceAdvanceMode: sequenceModeAdvanceHandler(for: permit),
                admissionRevision: permit.revision
            )
            setActionResult(result)
        } catch {
            guard routeIsCurrent(permit) else { return }
            setActionResult(ActionExecutionResult(outcome: .failed(
                .modePersistenceFailed(RuntimeFailureText.sanitize("Configuration unavailable: \(error)"))
            )))
        }
        _ = event
    }

    private func advanceDialMode(
        for profileID: ProfileID,
        permit: RoutePermit,
        deadline: ContinuousClock.Instant? = nil
    ) async -> DialModeAdvanceResult {
        if let modeAdvanceStartGateForTesting { await modeAdvanceStartGateForTesting() }
        if let stop = SequenceStopClassifier.failure(deadline: deadline) {
            return .failed(stop)
        }
        guard routeIsCurrent(permit) else { return .failed(.cancelled) }
        do {
            let config = try await loadConfigurationIfNeeded()
            if let stop = SequenceStopClassifier.failure(deadline: deadline) {
                return .failed(stop)
            }
            guard routeIsCurrent(permit) else { return .failed(.cancelled) }
            guard let profile = config.profile(id: profileID), !profile.dialModes.isEmpty else {
                if let stop = SequenceStopClassifier.failure(deadline: deadline) {
                    return .failed(stop)
                }
                return .failed(.modePersistenceFailed("The routed profile no longer exists"))
            }
            let currentID = profile.selectedDialMode.id
            let currentIndex = profile.dialModes.firstIndex { $0.id == currentID } ?? 0
            let nextMode = profile.dialModes[(currentIndex + 1) % profile.dialModes.count]
            let updated = try config.rememberingDialMode(nextMode.id, for: profileID)
            await configurationMutationGate.acquire()
            do {
                if let stop = SequenceStopClassifier.failure(deadline: deadline) {
                    await configurationMutationGate.release()
                    return .failed(stop)
                }
                guard routeIsCurrent(permit) else {
                    await configurationMutationGate.release()
                    return .failed(.cancelled)
                }
                try await configurationStore.save(updated)
                // A successful save is the commit point. The store's atomic
                // primary replacement is synchronous, so it may return after
                // the sequence deadline or cancellation arrived. Reflect that
                // committed state before releasing the mutation gate.
                configuration = updated
                if activeProfileID == profileID { selectedDialModeID = nextMode.id }
                await configurationMutationGate.release()
                return .advanced(nextMode.id)
            } catch {
                await configurationMutationGate.release()
                throw error
            }
        } catch is CancellationError {
            return .failed(SequenceStopClassifier.failure(deadline: deadline) ?? .cancelled)
        } catch {
            if let stop = SequenceStopClassifier.failure(deadline: deadline) {
                return .failed(stop)
            }
            return .failed(.modePersistenceFailed(RuntimeFailureText.sanitize(String(describing: error))))
        }
    }

    private func modeAdvanceHandler(
        for permit: RoutePermit
    ) -> @Sendable (ProfileID) async -> DialModeAdvanceResult {
        { [weak self] profileID in
            guard let self else {
                return .failed(.modePersistenceFailed("Runtime is no longer available"))
            }
            return await self.advanceDialMode(for: profileID, permit: permit)
        }
    }

    private func sequenceModeAdvanceHandler(
        for permit: RoutePermit
    ) -> @Sendable (ProfileID, ContinuousClock.Instant) async -> DialModeAdvanceResult {
        { [weak self] profileID, deadline in
            guard let self else {
                return .failed(.modePersistenceFailed("Runtime is no longer available"))
            }
            return await self.advanceDialMode(for: profileID, permit: permit, deadline: deadline)
        }
    }

    private func beginConfigurationMutation() {
        routingRevision &+= 1
        configurationMutationsInProgress += 1
    }

    private func finishConfigurationMutation() async {
        configurationMutationsInProgress = max(0, configurationMutationsInProgress - 1)
        await configurationMutationGate.release()
    }

    private func cancelExecutorAndRecordCleanupFailure() async {
        let failures = await executor.cancelAndRelease(floor: routingRevision)
        if let failure = failures.first {
            setActionResult(ActionExecutionResult(outcome: .failed(failure)))
        }
    }

    private func routePermit(for eventGeneration: SessionGeneration) -> RoutePermit? {
        guard generation == eventGeneration,
              case .running(let runningGeneration) = status,
              runningGeneration == eventGeneration,
              !isEditing,
              configurationMutationsInProgress == 0 else { return nil }
        return RoutePermit(generation: eventGeneration, revision: routingRevision)
    }

    private func routeIsCurrent(_ permit: RoutePermit) -> Bool {
        routingRevision == permit.revision
            && generation == permit.generation
            && !isEditing
            && configurationMutationsInProgress == 0
            && status == .running(generation: permit.generation)
    }

    private func loadConfigurationIfNeeded() async throws -> Configuration {
        if let configuration { return configuration }
        let loaded = try await configurationStore.load()
        configuration = loaded
        refreshSelectedModeSnapshot()
        return loaded
    }

    private func updateRoute(bundleID: ApplicationBundleIdentifier?, profile: Profile) {
        foregroundBundleIdentifier = bundleID
        activeProfileID = profile.id
        selectedDialModeID = profile.selectedDialMode.id
    }

    private func refreshSelectedModeSnapshot() {
        guard let configuration, let activeProfileID,
              let profile = configuration.profile(id: activeProfileID) else {
            selectedDialModeID = nil
            return
        }
        selectedDialModeID = profile.selectedDialMode.id
    }

    private func setActionResult(_ result: ActionExecutionResult) {
        lastActionResult = result
    }

    private func record(_ result: ActionExecutionResult) -> ActionExecutionResult {
        lastActionResult = result
        return result
    }

    private func absSafely(_ value: Int) -> Int {
        value == Int.min ? Int.max : abs(value)
    }
}

private extension ProfileActionResolver {
    static func profileForRouting(
        bundleIdentifier: ApplicationBundleIdentifier?,
        in configuration: Configuration
    ) -> Profile {
        if let bundleIdentifier,
           let profile = configuration.profiles.first(where: { $0.scope == .application(bundleIdentifier) }) {
            return profile
        }
        return configuration.defaultProfile
    }
}
