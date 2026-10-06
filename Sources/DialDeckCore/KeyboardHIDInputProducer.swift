import Foundation

enum KeyboardHIDTarget {
    static let vendorID: UInt32 = 0x1189
    static let productID: UInt32 = 0x8890
    static let genericDesktopUsagePage: UInt32 = 0x01
    static let keyboardApplicationUsage: UInt32 = 0x06
    static let keyboardUsagePage: UInt32 = 0x07
    static let observedUsages: Set<UInt32> = Set(0x6b...0x73)
}

struct KeyboardHIDElementDescriptor: Equatable, Sendable {
    enum Representation: Equatable, Sendable {
        case variable(usage: UInt32)
        case array(minimumUsage: UInt32, maximumUsage: UInt32)
    }

    let cookie: UInt64
    let usagePage: UInt32
    let representation: Representation
    let reportID: UInt32
    let reportCount: UInt32
    let logicalMinimum: Int64
    let logicalMaximum: Int64
}

struct KeyboardHIDElementPlan: Equatable, Sendable {
    enum Input: Equatable, Sendable {
        case variable(usage: UInt32)
        case array
    }

    let inputsByCookie: [UInt64: Input]

    init(validating descriptors: [KeyboardHIDElementDescriptor]) throws {
        let pageSeven = descriptors.filter { $0.usagePage == KeyboardHIDTarget.keyboardUsagePage }
        var candidates: [UInt64: Input] = [:]
        var arrayGroups = Set<ArrayGroup>()
        var variableUsages: [UInt32: Int] = [:]

        for descriptor in pageSeven {
            guard descriptor.logicalMinimum <= 0,
                  descriptor.logicalMaximum >= 1 else {
                continue
            }

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
            case .array(let minimum, let maximum)
                where KeyboardHIDTarget.observedUsages.contains(where: { minimum <= $0 && $0 <= maximum }):
                guard descriptor.logicalMinimum <= 0,
                      descriptor.logicalMaximum >= Int64(maximum),
                      descriptor.reportCount > 0 else {
                    throw KeyboardHIDCaptureError.interfaceMismatch
                }
                guard candidates[descriptor.cookie] == nil else {
                    throw KeyboardHIDCaptureError.ambiguousInterface
                }
                arrayGroups.insert(ArrayGroup(
                    reportID: descriptor.reportID,
                    reportCount: descriptor.reportCount,
                    minimumUsage: minimum,
                    maximumUsage: maximum,
                    logicalMinimum: descriptor.logicalMinimum,
                    logicalMaximum: descriptor.logicalMaximum
                ))
                candidates[descriptor.cookie] = .array
            default:
                continue
            }
        }

        guard arrayGroups.count <= 1 else {
            throw KeyboardHIDCaptureError.ambiguousInterface
        }

        if let arrayGroup = arrayGroups.first {
            guard KeyboardHIDTarget.observedUsages.allSatisfy({
                arrayGroup.minimumUsage <= $0 && $0 <= arrayGroup.maximumUsage
            }) else {
                throw KeyboardHIDCaptureError.interfaceMismatch
            }
            let arrayCookies = descriptors.compactMap { descriptor -> UInt64? in
                guard descriptor.usagePage == KeyboardHIDTarget.keyboardUsagePage,
                      case .array(let minimum, let maximum) = descriptor.representation,
                      minimum == arrayGroup.minimumUsage,
                      maximum == arrayGroup.maximumUsage,
                      descriptor.reportID == arrayGroup.reportID,
                      descriptor.reportCount == arrayGroup.reportCount,
                      descriptor.logicalMinimum == arrayGroup.logicalMinimum,
                      descriptor.logicalMaximum == arrayGroup.logicalMaximum else {
                    return nil
                }
                return descriptor.cookie
            }
            guard Set(arrayCookies).count == arrayCookies.count else {
                throw KeyboardHIDCaptureError.ambiguousInterface
            }
            guard variableUsages.isEmpty, !arrayCookies.isEmpty else {
                throw KeyboardHIDCaptureError.ambiguousInterface
            }
            candidates = Dictionary(uniqueKeysWithValues: arrayCookies.map { ($0, .array) })
        } else {
            for usage in KeyboardHIDTarget.observedUsages {
                guard variableUsages[usage] == 1 else {
                    throw KeyboardHIDCaptureError.interfaceMismatch
                }
            }
        }

        guard candidates.values.contains(where: { if case .array = $0 { true } else { false } })
                || KeyboardHIDTarget.observedUsages.allSatisfy({ usage in
                    candidates.values.contains(.variable(usage: usage))
                }) else {
            throw KeyboardHIDCaptureError.interfaceMismatch
        }
        inputsByCookie = candidates
    }

    private struct ArrayGroup: Hashable {
        let reportID: UInt32
        let reportCount: UInt32
        let minimumUsage: UInt32
        let maximumUsage: UInt32
        let logicalMinimum: Int64
        let logicalMaximum: Int64
    }
}

struct KeyboardHIDRawValue: Equatable, Sendable {
    let cookie: UInt64
    let usagePage: UInt32
    let elementUsage: UInt32
    let isArray: Bool
    let integerValue: Int64
}

enum KeyboardHIDTransportEvent: Sendable {
    case value(KeyboardHIDRawValue)
    case disconnected
    case permissionLost
}

protocol KeyboardHIDCaptureConnection: Sendable {
    var elementPlan: KeyboardHIDElementPlan { get }
    var events: AsyncStream<KeyboardHIDTransportEvent> { get }
    func cancel() async
}

protocol KeyboardHIDCaptureTransport: Sendable {
    func connectToUniqueTarget() async throws -> any KeyboardHIDCaptureConnection
}

enum KeyboardHIDCaptureError: Error, Equatable, Sendable, LocalizedError {
    case permissionUnavailable
    case targetUnavailable
    case ambiguousTarget
    case ambiguousInterface
    case interfaceMismatch
    case openFailed

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
        }
    }

    var canRetry: Bool {
        switch self {
        case .targetUnavailable, .ambiguousTarget:
            true
        case .permissionUnavailable, .ambiguousInterface, .interfaceMismatch, .openFailed:
            false
        }
    }
}

enum KeyboardHIDDelivery: Equatable, Sendable {
    case event(NormalizedInputEvent)
    case dialPress(PhysicalControlID)
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
        case .array:
            // IOHID array elements retain the descriptor's usage (often the
            // first usage in the range); the value itself carries the active
            // usage. The validated cookie and page pin the selected slot.
            guard input.isArray else { return [] }
            if input.integerValue >= 0,
               KeyboardHIDTarget.observedUsages.contains(UInt32(input.integerValue)) {
                newUsage = UInt32(input.integerValue)
            } else {
                // Non-target values are inspected only to recognize the selected
                // array slot's transition. They are not retained or delivered.
                newUsage = nil
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
            deliveries.append(contentsOf: releaseDelivery(for: priorUsage))
        }

        if let newUsage {
            let priorCount = sourceCountByUsage[newUsage, default: 0]
            sourceCountByUsage[newUsage] = priorCount + 1
            activeUsageByCookie[input.cookie] = newUsage
            if priorCount == 0 {
                deliveries.append(contentsOf: pressDelivery(for: newUsage))
            }
        }
        return deliveries
    }

    mutating func releaseHeldInputs() -> [KeyboardHIDDelivery] {
        let heldUsages = sourceCountByUsage.keys.sorted()
        activeUsageByCookie.removeAll()
        sourceCountByUsage.removeAll()
        return heldUsages.flatMap(releaseDelivery(for:))
    }

    private func pressDelivery(for usage: UInt32) -> [KeyboardHIDDelivery] {
        if let key = Self.keyControl(for: usage),
           let event = NormalizedInputEvent.keyDown(control: key, generation: generation) {
            return [.event(event)]
        }
        if usage == 0x72 {
            return [.dialPress(Self.knobControl)]
        }
        if let direction = Self.rotation(for: usage),
           let event = NormalizedInputEvent.dialRotation(
               control: Self.knobControl,
               delta: direction,
               generation: generation
           ) {
            return [.event(event)]
        }
        return []
    }

    private func releaseDelivery(for usage: UInt32) -> [KeyboardHIDDelivery] {
        guard let key = Self.keyControl(for: usage),
              let event = NormalizedInputEvent.keyUp(control: key, generation: generation) else {
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
        consumer: any NormalizedInputConsumer
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
                transport: transport
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
    private var decoder: KeyboardHIDUsageDecoder?
    private var activeConnection: ActiveConnection?
    private var reconnectTask: Task<Void, Never>?
    private var isPaused = false
    private var isClosed = false
    private var hasAnnouncedStopping = false
    private var queuedDeliveries: [KeyboardHIDDelivery] = []
    private var isDrainingDeliveries = false
    private var deliveryWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        generation: SessionGeneration,
        consumer: any NormalizedInputConsumer,
        transport: any KeyboardHIDCaptureTransport
    ) {
        self.generation = generation
        self.consumer = consumer
        self.transport = transport
    }

    func start() async throws {
        let connection = try await transport.connectToUniqueTarget()
        guard !isClosed else {
            await connection.cancel()
            throw CancellationError()
        }
        await consumer.sessionLifecycleChanged(.started(generation))
        guard !isClosed else {
            await connection.cancel()
            throw CancellationError()
        }
        install(connection)
        hasAnnouncedStopping = false
    }

    func setPaused(_ paused: Bool) async {
        guard !isClosed, isPaused != paused else { return }
        isPaused = paused
        if paused {
            reconnectTask?.cancel()
            reconnectTask = nil
            await detachActiveConnection(announceStopping: true)
        } else {
            scheduleReconnect(immediately: true)
        }
    }

    func cancel() async {
        guard !isClosed else { return }
        isClosed = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await releaseHeldInputs()
        await consumer.sessionLifecycleChanged(.stopping(generation))
        if let activeConnection {
            self.activeConnection = nil
            await activeConnection.connection.cancel()
            activeConnection.reader.cancel()
            await activeConnection.reader.value
        }
        await consumer.sessionLifecycleChanged(.stopped(generation))
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
        await releaseHeldInputs()
        await announceStoppingIfNeeded()
        guard let oldConnection = activeConnection, oldConnection.id == connectionID else { return }
        activeConnection = nil
        decoder = nil
        await oldConnection.connection.cancel()
        if permissionLost {
            isClosed = true
            reconnectTask?.cancel()
            reconnectTask = nil
            await consumer.sessionLifecycleChanged(.failed(
                generation,
                reason: KeyboardHIDCaptureError.permissionUnavailable.localizedDescription
            ))
        } else if !isPaused {
            scheduleReconnect(immediately: false)
        }
    }

    private func detachActiveConnection(announceStopping: Bool) async {
        await releaseHeldInputs()
        if announceStopping { await announceStoppingIfNeeded() }
        guard let oldConnection = activeConnection else { return }
        activeConnection = nil
        decoder = nil
        await oldConnection.connection.cancel()
        oldConnection.reader.cancel()
        await oldConnection.reader.value
    }

    private func announceStoppingIfNeeded() async {
        guard !hasAnnouncedStopping else { return }
        hasAnnouncedStopping = true
        await consumer.sessionLifecycleChanged(.stopping(generation))
    }

    private func scheduleReconnect(immediately: Bool) {
        guard !isClosed, !isPaused, activeConnection == nil, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            if !immediately {
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
            }
            await self?.attemptReconnect()
        }
    }

    private func attemptReconnect() async {
        reconnectTask = nil
        guard !isClosed, !isPaused, activeConnection == nil else { return }
        do {
            let connection = try await transport.connectToUniqueTarget()
            guard !isClosed, !isPaused, activeConnection == nil else {
                await connection.cancel()
                return
            }
            await consumer.sessionLifecycleChanged(.started(generation))
            guard !isClosed, !isPaused, activeConnection == nil else {
                await connection.cancel()
                return
            }
            install(connection)
            hasAnnouncedStopping = false
        } catch let error as KeyboardHIDCaptureError where error.canRetry {
            scheduleReconnect(immediately: false)
        } catch let error as KeyboardHIDCaptureError where error == .permissionUnavailable {
            isClosed = true
            await consumer.sessionLifecycleChanged(.failed(generation, reason: error.localizedDescription))
        } catch is CancellationError {
            return
        } catch {
            guard !isClosed, !isPaused else { return }
            isClosed = true
            await consumer.sessionLifecycleChanged(.failed(
                generation,
                reason: "The target keyboard collection could not be safely reconnected"
            ))
        }
    }

    private func releaseHeldInputs() async {
        guard var decoder else { return }
        let outputs = decoder.releaseHeldInputs()
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
            case .dialPress(let control):
                _ = await consumer.dialPressed(control: control, generation: generation)
            }
        }
        isDrainingDeliveries = false
        let waiters = deliveryWaiters
        deliveryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
