import Foundation

enum KeyboardHIDTarget {
    static let vendorID: UInt32 = 0x1189
    static let productID: UInt32 = 0x8890
    static let genericDesktopUsagePage: UInt32 = 0x01
    static let keyboardApplicationUsage: UInt32 = 0x06
    static let keyboardUsagePage: UInt32 = 0x07
    static let observedUsages: Set<UInt32> = Set(0x6b...0x73)
    static let rawReportDescriptor = Data([
        0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x01,
        0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00,
        0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x03,
        0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x03,
        0x91, 0x02, 0x95, 0x05, 0x75, 0x01, 0x91, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x26, 0xff, 0x00, 0x05,
        0x07, 0x19, 0x00, 0x29, 0x91, 0x81, 0x00, 0xc0,
    ])
}

struct KeyboardHIDUsagePair: Equatable, Hashable, Comparable, Sendable {
    let usagePage: UInt32
    let usage: UInt32

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.usagePage != rhs.usagePage {
            return lhs.usagePage < rhs.usagePage
        }
        return lhs.usage < rhs.usage
    }
}

struct KeyboardHIDElementDescriptor: Equatable, Sendable {
    enum Representation: Equatable, Sendable {
        case variable(usage: UInt32)
        case array(minimumUsage: UInt32?, maximumUsage: UInt32?)
    }

    let cookie: UInt64
    let usagePage: UInt32
    let representation: Representation
    let reportID: UInt32
    let reportCount: UInt32
    let logicalMinimum: Int64
    let logicalMaximum: Int64
}

struct KeyboardHIDDescriptorFingerprint: Equatable, Sendable {
    /// Canonical keyboard-page input descriptor fields; IOHID cookies are only element IDs within a device.
    let canonicalElements: [String]

    init(descriptors: [KeyboardHIDElementDescriptor]) {
        canonicalElements = descriptors.map { descriptor in
            let representation: String
            switch descriptor.representation {
            case .variable(let usage):
                representation = "variable:\(usage)"
            case .array(let minimum, let maximum):
                representation = "array:\(minimum.map { String($0) } ?? "?"):\(maximum.map { String($0) } ?? "?")"
            }
            return [
                String(descriptor.usagePage),
                representation,
                String(descriptor.reportID),
                String(descriptor.reportCount),
                String(descriptor.logicalMinimum),
                String(descriptor.logicalMaximum),
            ].joined(separator: "|")
        }.sorted()
    }
}

struct KeyboardHIDElementPlan: Equatable, Sendable {
    enum Input: Equatable, Sendable {
        case variable(usage: UInt32)
    }

    let inputsByCookie: [UInt64: Input]

    static let observedArrayControlPlan = KeyboardHIDElementPlan(
        inputsByCookie: Dictionary(
            uniqueKeysWithValues: KeyboardHIDTarget.observedUsages.map {
                (UInt64($0), .variable(usage: $0))
            }
        )
    )

    private init(inputsByCookie: [UInt64: Input]) {
        self.inputsByCookie = inputsByCookie
    }

    init(validating descriptors: [KeyboardHIDElementDescriptor]) throws {
        let pageSeven = descriptors.filter { $0.usagePage == KeyboardHIDTarget.keyboardUsagePage }
        var candidates: [UInt64: Input] = [:]
        var variableUsages: [UInt32: Int] = [:]

        for descriptor in pageSeven {
            switch descriptor.representation {
            case .variable(let usage) where KeyboardHIDTarget.observedUsages.contains(usage):
                guard descriptor.logicalMinimum <= 0, descriptor.logicalMaximum >= 1 else {
                    throw KeyboardHIDCaptureError.interfaceMismatch
                }
                guard candidates[descriptor.cookie] == nil else {
                    throw KeyboardHIDCaptureError.ambiguousInterface
                }
                variableUsages[usage, default: 0] += 1
                candidates[descriptor.cookie] = .variable(usage: usage)
            case .array(let minimum?, let maximum?) where minimum <= maximum:
                guard !KeyboardHIDTarget.observedUsages.contains(where: { minimum <= $0 && $0 <= maximum }) else {
                    // Value callbacks do not expose a report boundary. Without the
                    // full report, a usage moving between array slots can look like
                    // an up/down pair in either callback order. Fail closed until
                    // the transport can validate and decode complete array reports.
                    throw KeyboardHIDCaptureError.ambiguousInterface
                }
            case .array:
                // Value callbacks do not expose a report boundary. Without the
                // usage bounds, the array could overlap the target usages.
                throw KeyboardHIDCaptureError.ambiguousInterface
            default:
                continue
            }
        }

        for usage in KeyboardHIDTarget.observedUsages {
            guard variableUsages[usage] == 1 else {
                throw KeyboardHIDCaptureError.interfaceMismatch
            }
        }

        guard KeyboardHIDTarget.observedUsages.allSatisfy({ usage in
            candidates.values.contains(.variable(usage: usage))
        }) else {
            throw KeyboardHIDCaptureError.interfaceMismatch
        }
        inputsByCookie = candidates
    }
}

struct KeyboardHIDChildIdentity: Equatable, Sendable {
    let descriptorFingerprint: KeyboardHIDDescriptorFingerprint
    let usagePairs: [KeyboardHIDUsagePair]?
    let keyboardApplicationCollectionCount: Int?
    let registryEntryID: UInt64?
    let elementPlan: KeyboardHIDElementPlan?

    var isEligible: Bool {
        guard !descriptorFingerprint.canonicalElements.isEmpty,
              keyboardApplicationCollectionCount == 1,
              let usagePairs,
              usagePairs.filter({
                  $0.usagePage == KeyboardHIDTarget.genericDesktopUsagePage
                      && $0.usage == KeyboardHIDTarget.keyboardApplicationUsage
              }).count == 1,
              let registryEntryID,
              registryEntryID != 0,
              elementPlan != nil else {
            return false
        }
        return true
    }
}

enum KeyboardHIDChildSelection {
    static func uniqueEligibleIndex(in candidates: [KeyboardHIDChildIdentity]) throws -> Int {
        let eligibleIndices = candidates.indices.filter { candidates[$0].isEligible }
        guard eligibleIndices.count == 1 else {
            if eligibleIndices.isEmpty {
                throw KeyboardHIDCaptureError.interfaceMismatch
            }
            throw KeyboardHIDCaptureError.ambiguousTarget
        }
        return eligibleIndices[0]
    }
}

enum KeyboardHIDRawReportInterfaceSelection {
    static func uniqueMatchingIndex(in descriptors: [Data?]) throws -> Int {
        let matches = descriptors.indices.filter {
            descriptors[$0] == KeyboardHIDTarget.rawReportDescriptor
        }
        guard matches.count == 1 else {
            if matches.isEmpty {
                throw KeyboardHIDCaptureError.interfaceMismatch
            }
            throw KeyboardHIDCaptureError.ambiguousTarget
        }
        return matches[0]
    }
}

struct KeyboardHIDRawValue: Equatable, Sendable {
    let cookie: UInt64
    let usagePage: UInt32
    let elementUsage: UInt32
    let isArray: Bool
    let integerValue: Int64
    let focusEpoch: FocusEpoch

    init(
        cookie: UInt64,
        usagePage: UInt32,
        elementUsage: UInt32,
        isArray: Bool,
        integerValue: Int64,
        focusEpoch: FocusEpoch = .initial
    ) {
        self.cookie = cookie
        self.usagePage = usagePage
        self.elementUsage = elementUsage
        self.isArray = isArray
        self.integerValue = integerValue
        self.focusEpoch = focusEpoch
    }
}

struct KeyboardHIDRawReportDecoder: Sendable {
    static let expectedReportID: UInt32 = 0x01
    static let expectedReportLength = 9
    static let keyArrayRange = 3..<9
    static let errorRollOverUsage: UInt8 = 0x01

    private(set) var activeUsages: Set<UInt32> = []

    mutating func consume(
        reportID: UInt32,
        bytes: [UInt8],
        focusEpoch: FocusEpoch = .initial
    ) -> [KeyboardHIDRawValue] {
        guard reportID == Self.expectedReportID,
              bytes.count == Self.expectedReportLength,
              bytes[0] == UInt8(Self.expectedReportID) else {
            return []
        }

        let keyArray = bytes[Self.keyArrayRange]
        guard !keyArray.allSatisfy({ $0 == Self.errorRollOverUsage }) else {
            return []
        }

        let nextUsages = Set(keyArray.compactMap { usage -> UInt32? in
            guard usage != 0,
                  KeyboardHIDTarget.observedUsages.contains(UInt32(usage)) else {
                return nil
            }
            return UInt32(usage)
        })
        let released = activeUsages.subtracting(nextUsages).sorted()
        let pressed = nextUsages.subtracting(activeUsages).sorted()
        activeUsages = nextUsages
        return released.map { rawValue(for: $0, pressed: false, focusEpoch: focusEpoch) }
            + pressed.map { rawValue(for: $0, pressed: true, focusEpoch: focusEpoch) }
    }

    mutating func releaseHeldInputs(focusEpoch: FocusEpoch = .initial) -> [KeyboardHIDRawValue] {
        let released = activeUsages.sorted().map {
            rawValue(for: $0, pressed: false, focusEpoch: focusEpoch)
        }
        activeUsages.removeAll()
        return released
    }

    private func rawValue(
        for usage: UInt32,
        pressed: Bool,
        focusEpoch: FocusEpoch
    ) -> KeyboardHIDRawValue {
        KeyboardHIDRawValue(
            cookie: UInt64(usage),
            usagePage: KeyboardHIDTarget.keyboardUsagePage,
            elementUsage: usage,
            isArray: false,
            integerValue: pressed ? 1 : 0,
            focusEpoch: focusEpoch
        )
    }
}

enum KeyboardHIDTransportEvent: Sendable {
    case value(KeyboardHIDRawValue)
    case disconnected
    case permissionLost
}

protocol KeyboardHIDCaptureConnection: Sendable {
    var elementPlan: KeyboardHIDElementPlan { get }
    var events: AsyncStream<KeyboardHIDTransportEvent> { get }
    func cancel() async -> KeyboardHIDCaptureError?
}

protocol KeyboardHIDCaptureTransport: Sendable {
    func connectToUniqueTarget(
        focusEpochClock: FocusEpochClock
    ) async throws -> any KeyboardHIDCaptureConnection
}

enum KeyboardHIDCaptureError: Error, Equatable, Sendable, LocalizedError {
    case permissionUnavailable
    case targetUnavailable
    case ambiguousTarget
    case ambiguousInterface
    case interfaceMismatch
    case openFailed
    case managerCloseFailed(Int32)
    case deviceCloseFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .permissionUnavailable:
            "Input Monitoring access is not already granted"
        case .targetUnavailable:
            "The expected keyboard collection is not currently available"
        case .ambiguousTarget:
            "More than one matching keyboard collection is currently available"
        case .ambiguousInterface:
            "The matching keyboard collection has an ambiguous input layout"
        case .interfaceMismatch:
            "The matching keyboard collection does not expose the complete observed input set"
        case .openFailed:
            "The matching keyboard collection could not be opened read-only"
        case .managerCloseFailed(let result):
            "The temporary HID manager failed to close with IOReturn \(String(format: "0x%08X", UInt32(bitPattern: result)))"
        case .deviceCloseFailed(let result):
            "The keyboard HID device failed to close with IOReturn \(String(format: "0x%08X", UInt32(bitPattern: result)))"
        }
    }

    var canRetry: Bool {
        switch self {
        case .targetUnavailable, .ambiguousTarget:
            true
        case .permissionUnavailable, .ambiguousInterface, .interfaceMismatch, .openFailed:
            false
        case .managerCloseFailed, .deviceCloseFailed:
            false
        }
    }
}

enum KeyboardHIDDelivery: Equatable, Sendable {
    case event(NormalizedInputEvent)
    case dialPress(PhysicalControlID, focusEpoch: FocusEpoch)
}

struct KeyboardHIDUsageDecoder {
    private let generation: SessionGeneration
    private let plan: KeyboardHIDElementPlan
    private var activeUsageByCookie: [UInt64: UInt32] = [:]
    private var sourceCountByUsage: [UInt32: Int] = [:]

    init(generation: SessionGeneration, plan: KeyboardHIDElementPlan) {
        self.generation = generation
        self.plan = plan
    }

    mutating func consume(_ input: KeyboardHIDRawValue) -> [KeyboardHIDDelivery] {
        guard input.usagePage == KeyboardHIDTarget.keyboardUsagePage,
              let descriptor = plan.inputsByCookie[input.cookie] else {
            return []
        }

        let newUsage: UInt32?
        switch descriptor {
        case .variable(let expectedUsage):
            guard !input.isArray, input.elementUsage == expectedUsage else { return [] }
            switch input.integerValue {
            case 0:
                newUsage = nil
            case 1:
                newUsage = expectedUsage
            default:
                return []
            }
        }

        let priorUsage = activeUsageByCookie[input.cookie]
        guard priorUsage != newUsage else { return [] }
        if let priorUsage {
            activeUsageByCookie.removeValue(forKey: input.cookie)
            let remaining = (sourceCountByUsage[priorUsage] ?? 1) - 1
            if remaining <= 0 {
                sourceCountByUsage.removeValue(forKey: priorUsage)
            } else {
                sourceCountByUsage[priorUsage] = remaining
            }
        }

        var deliveries: [KeyboardHIDDelivery] = []
        if let priorUsage, sourceCountByUsage[priorUsage] == nil {
            deliveries.append(contentsOf: releaseDelivery(for: priorUsage, focusEpoch: input.focusEpoch))
        }

        if let newUsage {
            let priorCount = sourceCountByUsage[newUsage, default: 0]
            sourceCountByUsage[newUsage] = priorCount + 1
            activeUsageByCookie[input.cookie] = newUsage
            if priorCount == 0 {
                deliveries.append(contentsOf: pressDelivery(for: newUsage, focusEpoch: input.focusEpoch))
            }
        }
        return deliveries
    }

    mutating func releaseHeldInputs(focusEpoch: FocusEpoch = .initial) -> [KeyboardHIDDelivery] {
        let heldUsages = sourceCountByUsage.keys.sorted()
        activeUsageByCookie.removeAll()
        sourceCountByUsage.removeAll()
        return heldUsages.flatMap { releaseDelivery(for: $0, focusEpoch: focusEpoch) }
    }

    private func pressDelivery(for usage: UInt32, focusEpoch: FocusEpoch) -> [KeyboardHIDDelivery] {
        if let key = Self.keyControl(for: usage),
           let event = NormalizedInputEvent.keyDown(
            control: key,
            generation: generation,
            focusEpoch: focusEpoch
           ) {
            return [.event(event)]
        }
        if usage == 0x72 {
            return [.dialPress(Self.knobControl, focusEpoch: focusEpoch)]
        }
        if let direction = Self.rotation(for: usage),
           let event = NormalizedInputEvent.dialRotation(
               control: Self.knobControl,
               delta: direction,
               generation: generation,
               focusEpoch: focusEpoch
           ) {
            return [.event(event)]
        }
        return []
    }

    private func releaseDelivery(for usage: UInt32, focusEpoch: FocusEpoch) -> [KeyboardHIDDelivery] {
        guard let key = Self.keyControl(for: usage),
              let event = NormalizedInputEvent.keyUp(
                control: key,
                generation: generation,
                focusEpoch: focusEpoch
              ) else {
            return []
        }
        return [.event(event)]
    }

    private static let knobControl = PhysicalControlID(rawValue: "knob", kind: .dial)!

    private static func keyControl(for usage: UInt32) -> PhysicalControlID? {
        let name: String
        switch usage {
        case 0x6b: name = "bottom-left"
        case 0x6c: name = "middle-left"
        case 0x6d: name = "top-left"
        case 0x6e: name = "bottom-right"
        case 0x6f: name = "middle-right"
        case 0x70: name = "top-right"
        default: return nil
        }
        return PhysicalControlID(rawValue: name, kind: .key)
    }

    private static func rotation(for usage: UInt32) -> Int? {
        switch usage {
        case 0x71: -1
        case 0x73: 1
        default: nil
        }
    }
}

/// Owns one generation-scoped capture session. The transport is intentionally
/// injected so session, reconnect, and decoder behavior can be replay-tested
/// without touching a physical device.
public actor KeyboardHIDInputEventProducer: InputEventProducing {
    private let transport: any KeyboardHIDCaptureTransport
    private let startGate = AsyncActionGate()
    private var activeSession: KeyboardHIDInputSession?

    public init() {
        transport = MacOSKeyboardHIDCaptureTransport()
    }

    init(transport: any KeyboardHIDCaptureTransport) {
        self.transport = transport
    }

    public func start(
        generation: SessionGeneration,
        consumer: any NormalizedInputConsumer,
        focusEpochClock: FocusEpochClock
    ) async throws -> any InputSessionHandle {
        await startGate.acquire()
        do {
            try Task.checkCancellation()
            if let activeSession {
                await activeSession.cancel()
            }
            let newSession = KeyboardHIDInputSession(
                generation: generation,
                consumer: consumer,
                transport: transport,
                focusEpochClock: focusEpochClock
            )
            try await newSession.start()
            activeSession = newSession
            await startGate.release()
            return newSession
        } catch {
            await startGate.release()
            throw error
        }
    }

    /// Pausing releases held keys and closes the current listener. Resume
    /// revalidates the exact target before attempting a new connection.
    public func setPaused(_ paused: Bool) async {
        await activeSession?.setPaused(paused)
    }
}

private actor KeyboardHIDInputSession: InputSessionHandle {
    private struct ActiveConnection {
        let id: UUID
        let connection: any KeyboardHIDCaptureConnection
        let reader: Task<Void, Never>
    }

    nonisolated let generation: SessionGeneration
    private let consumer: any NormalizedInputConsumer
    private let transport: any KeyboardHIDCaptureTransport
    private let focusEpochClock: FocusEpochClock
    private var decoder: KeyboardHIDUsageDecoder?
    private var activeConnection: ActiveConnection?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectTaskID: UUID?
    private var isPaused = false
    private var isClosed = false
    private var terminationStarted = false
    private var terminationFinished = false
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingConnectionTeardowns = 0
    private var connectionTeardownWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasAnnouncedStopping = false
    private var queuedDeliveries: [KeyboardHIDDelivery] = []
    private var isDrainingDeliveries = false
    private var deliveryWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        generation: SessionGeneration,
        consumer: any NormalizedInputConsumer,
        transport: any KeyboardHIDCaptureTransport,
        focusEpochClock: FocusEpochClock
    ) {
        self.generation = generation
        self.consumer = consumer
        self.transport = transport
        self.focusEpochClock = focusEpochClock
    }

    func start() async throws {
        let connection = try await transport.connectToUniqueTarget(focusEpochClock: focusEpochClock)
        guard !isClosed else {
            if let closeError = await connection.cancel() { throw closeError }
            throw CancellationError()
        }
        await consumer.sessionLifecycleChanged(.started(generation))
        guard !isClosed else {
            if let closeError = await connection.cancel() { throw closeError }
            throw CancellationError()
        }
        install(connection)
        hasAnnouncedStopping = false
    }

    func setPaused(_ paused: Bool) async {
        guard !isClosed, isPaused != paused else { return }
        isPaused = paused
        if paused {
            let pendingReconnect = reconnectTask
            reconnectTask = nil
            reconnectTaskID = nil
            pendingReconnect?.cancel()
            if let pendingReconnect { await pendingReconnect.value }
            await detachActiveConnection(announceStopping: true)
        } else {
            scheduleReconnect(immediately: true)
        }
    }

    func cancel() async {
        await terminate(with: .cancelled)
    }

    private func install(_ connection: any KeyboardHIDCaptureConnection) {
        let id = UUID()
        decoder = KeyboardHIDUsageDecoder(generation: generation, plan: connection.elementPlan)
        let stream = connection.events
        let reader = Task { [weak self] in
            for await event in stream {
                await self?.receive(event, connectionID: id)
            }
            if !Task.isCancelled {
                await self?.connectionEnded(connectionID: id)
            }
        }
        activeConnection = ActiveConnection(id: id, connection: connection, reader: reader)
    }

    private func receive(_ event: KeyboardHIDTransportEvent, connectionID: UUID) async {
        guard !isClosed, !isPaused, activeConnection?.id == connectionID else { return }
        switch event {
        case .value(let value):
            guard var decoder else { return }
            let outputs = decoder.consume(value)
            self.decoder = decoder
            guard !isClosed, activeConnection?.id == connectionID else { return }
            await deliver(outputs)
        case .disconnected:
            await transportInterrupted(connectionID: connectionID, permissionLost: false)
        case .permissionLost:
            await transportInterrupted(connectionID: connectionID, permissionLost: true)
        }
    }

    private func connectionEnded(connectionID: UUID) async {
        guard !Task.isCancelled, !isClosed, activeConnection?.id == connectionID else { return }
        await transportInterrupted(connectionID: connectionID, permissionLost: false)
    }

    private func transportInterrupted(connectionID: UUID, permissionLost: Bool) async {
        guard !isClosed, activeConnection?.id == connectionID else { return }
        if permissionLost {
            await terminate(
                with: .failed(KeyboardHIDCaptureError.permissionUnavailable.localizedDescription),
                readerConnectionID: connectionID
            )
            return
        }

        guard let oldConnection = activeConnection, oldConnection.id == connectionID else { return }
        activeConnection = nil
        pendingConnectionTeardowns += 1
        await releaseHeldInputs()
        await announceStoppingIfNeeded()
        decoder = nil
        let closeError = await oldConnection.connection.cancel()
        finishConnectionTeardown()
        if let closeError {
            await terminate(with: .failed(closeError.localizedDescription))
            return
        }
        if !isClosed, !isPaused {
            scheduleReconnect(immediately: false)
        }
    }

    private enum TerminationOutcome {
        case cancelled
        case failed(String)
    }

    /// Closes input immediately, then makes every later cancellation caller
    /// join the same release and transport teardown. Permission loss uses this
    /// path too, so it cannot strand waiters in a half-closed session.
    private func terminate(
        with outcome: TerminationOutcome,
        readerConnectionID: UUID? = nil,
        currentReconnectID: UUID? = nil
    ) async {
        if terminationFinished { return }
        if terminationStarted {
            await waitForTerminationCompletion()
            return
        }

        terminationStarted = true
        isClosed = true
        let pendingReconnect = reconnectTask
        let pendingReconnectID = reconnectTaskID
        reconnectTask = nil
        reconnectTaskID = nil
        let isCurrentReconnectTask = currentReconnectID != nil
            && currentReconnectID == pendingReconnectID
        if !isCurrentReconnectTask { pendingReconnect?.cancel() }

        await releaseHeldInputs()
        await announceStoppingIfNeeded()

        let connectionToClose = activeConnection
        activeConnection = nil
        decoder = nil
        var finalOutcome = outcome
        if let connectionToClose {
            if let closeError = await connectionToClose.connection.cancel() {
                finalOutcome = .failed(closeError.localizedDescription)
            }
            if connectionToClose.id != readerConnectionID {
                connectionToClose.reader.cancel()
                await connectionToClose.reader.value
            }
        }
        if let pendingReconnect, !isCurrentReconnectTask {
            await pendingReconnect.value
        }
        await waitForConnectionTeardowns()

        switch finalOutcome {
        case .cancelled:
            await consumer.sessionLifecycleChanged(.stopped(generation))
        case .failed(let reason):
            await consumer.sessionLifecycleChanged(.failed(generation, reason: reason))
        }

        terminationFinished = true
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForTerminationCompletion() async {
        guard !terminationFinished else { return }
        await withCheckedContinuation { terminationWaiters.append($0) }
    }

    private func waitForConnectionTeardowns() async {
        while pendingConnectionTeardowns > 0 {
            await withCheckedContinuation { connectionTeardownWaiters.append($0) }
        }
    }

    private func finishConnectionTeardown() {
        precondition(pendingConnectionTeardowns > 0)
        pendingConnectionTeardowns -= 1
        guard pendingConnectionTeardowns == 0 else { return }
        let waiters = connectionTeardownWaiters
        connectionTeardownWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func detachActiveConnection(announceStopping: Bool) async {
        await releaseHeldInputs()
        if announceStopping { await announceStoppingIfNeeded() }
        guard let oldConnection = activeConnection else { return }
        activeConnection = nil
        decoder = nil
        pendingConnectionTeardowns += 1
        let closeError = await oldConnection.connection.cancel()
        oldConnection.reader.cancel()
        await oldConnection.reader.value
        finishConnectionTeardown()
        if let closeError {
            await terminate(with: .failed(closeError.localizedDescription))
        }
    }

    private func announceStoppingIfNeeded() async {
        guard !hasAnnouncedStopping else { return }
        hasAnnouncedStopping = true
        await consumer.sessionLifecycleChanged(.stopping(generation))
    }

    private func scheduleReconnect(immediately: Bool) {
        guard !isClosed, !isPaused, activeConnection == nil, reconnectTask == nil else { return }
        let taskID = UUID()
        reconnectTaskID = taskID
        reconnectTask = Task { [weak self] in
            if !immediately {
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
            }
            await self?.runReconnect(taskID: taskID)
        }
    }

    private func runReconnect(taskID: UUID) async {
        guard reconnectTaskID == taskID else { return }
        let shouldRetry = await attemptReconnect(taskID: taskID)
        guard reconnectTaskID == taskID else { return }
        reconnectTask = nil
        reconnectTaskID = nil
        if shouldRetry { scheduleReconnect(immediately: false) }
    }

    private func attemptReconnect(taskID: UUID) async -> Bool {
        guard !isClosed, !isPaused, activeConnection == nil else { return false }
        do {
            let connection = try await transport.connectToUniqueTarget(focusEpochClock: focusEpochClock)
            guard reconnectTaskID == taskID, !isClosed, !isPaused, activeConnection == nil else {
                if let closeError = await connection.cancel() {
                    await terminate(
                        with: .failed(closeError.localizedDescription),
                        currentReconnectID: taskID
                    )
                }
                return false
            }
            await consumer.sessionLifecycleChanged(.started(generation))
            guard reconnectTaskID == taskID, !isClosed, !isPaused, activeConnection == nil else {
                if let closeError = await connection.cancel() {
                    await terminate(
                        with: .failed(closeError.localizedDescription),
                        currentReconnectID: taskID
                    )
                }
                return false
            }
            install(connection)
            hasAnnouncedStopping = false
            return false
        } catch let error as KeyboardHIDCaptureError where error.canRetry {
            return true
        } catch let error as KeyboardHIDCaptureError where error == .permissionUnavailable {
            guard !isClosed, reconnectTaskID == taskID else { return false }
            await terminate(
                with: .failed(error.localizedDescription),
                currentReconnectID: taskID
            )
            return false
        } catch is CancellationError {
            return false
        } catch {
            guard !isClosed, !isPaused else { return false }
            await terminate(with: .failed(
                "The target keyboard collection could not be safely reconnected"
            ), currentReconnectID: taskID)
            return false
        }
    }

    private func releaseHeldInputs() async {
        guard var decoder else { return }
        let outputs = decoder.releaseHeldInputs(focusEpoch: focusEpochClock.snapshot())
        self.decoder = decoder
        await deliver(outputs)
    }

    private func deliver(_ outputs: [KeyboardHIDDelivery]) async {
        queuedDeliveries.append(contentsOf: outputs)
        guard !isDrainingDeliveries else {
            await withCheckedContinuation { deliveryWaiters.append($0) }
            return
        }

        isDrainingDeliveries = true
        while !queuedDeliveries.isEmpty {
            let output = queuedDeliveries.removeFirst()
            switch output {
            case .event(let event):
                await consumer.consume(event)
            case .dialPress(let control, let focusEpoch):
                _ = await consumer.dialPressed(
                    control: control,
                    generation: generation,
                    focusEpoch: focusEpoch
                )
            }
        }
        isDrainingDeliveries = false
        let waiters = deliveryWaiters
        deliveryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
