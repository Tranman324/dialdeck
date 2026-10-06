import XCTest
@testable import DialDeckCore

final class KeyboardHIDInputProducerTests: XCTestCase {
    func testAllNineUsagesNormalizeOnlyTheirExpectedTransitions() throws {
        let plan = try variablePlan()
        var decoder = KeyboardHIDUsageDecoder(generation: SessionGeneration(11), plan: plan)
        let expectedKeys: [(UInt32, String)] = [
            (0x6b, "bottom-left"),
            (0x6c, "middle-left"),
            (0x6d, "top-left"),
            (0x6e, "bottom-right"),
            (0x6f, "middle-right"),
            (0x70, "top-right"),
        ]

        for (usage, identifier) in expectedKeys {
            let down = decoder.consume(variableValue(usage: usage, value: 1))
            XCTAssertEqual(down, [.event(try keyEvent(identifier, down: true, generation: 11))])
            XCTAssertTrue(decoder.consume(variableValue(usage: usage, value: 1)).isEmpty)

            let up = decoder.consume(variableValue(usage: usage, value: 0))
            XCTAssertEqual(up, [.event(try keyEvent(identifier, down: false, generation: 11))])
            XCTAssertTrue(decoder.consume(variableValue(usage: usage, value: 0)).isEmpty)
        }

        let counterclockwiseDown = decoder.consume(variableValue(usage: 0x71, value: 1))
        XCTAssertEqual(counterclockwiseDown, [.event(try rotationEvent(-1, generation: 11))])
        XCTAssertTrue(decoder.consume(variableValue(usage: 0x71, value: 1)).isEmpty)
        XCTAssertTrue(decoder.consume(variableValue(usage: 0x71, value: 0)).isEmpty)

        let pressDown = decoder.consume(variableValue(usage: 0x72, value: 1))
        XCTAssertEqual(pressDown, [.dialPress(try XCTUnwrap(PhysicalControlID(rawValue: "knob", kind: .dial)))])
        XCTAssertTrue(decoder.consume(variableValue(usage: 0x72, value: 1)).isEmpty)
        XCTAssertTrue(decoder.consume(variableValue(usage: 0x72, value: 0)).isEmpty)

        let clockwiseDown = decoder.consume(variableValue(usage: 0x73, value: 1))
        XCTAssertEqual(clockwiseDown, [.event(try rotationEvent(1, generation: 11))])
        XCTAssertTrue(decoder.consume(variableValue(usage: 0x73, value: 0)).isEmpty)
    }

    func testBurstDialTicksRemainDistinctAndF23ReleaseNeverCallsConsumer() throws {
        let plan = try variablePlan()
        var decoder = KeyboardHIDUsageDecoder(generation: SessionGeneration(12), plan: plan)

        var rotations: [NormalizedInputEvent] = []
        for _ in 0..<20 {
            rotations += decoder.consume(variableValue(usage: 0x73, value: 1)).compactMap(eventValue)
            XCTAssertTrue(decoder.consume(variableValue(usage: 0x73, value: 1)).isEmpty)
            _ = decoder.consume(variableValue(usage: 0x73, value: 0))
        }

        XCTAssertEqual(rotations.count, 20)
        XCTAssertTrue(rotations.allSatisfy { $0.payload == .dialRotation(delta: 1) })
        XCTAssertEqual(decoder.consume(variableValue(usage: 0x72, value: 1)).count, 1)
        XCTAssertTrue(decoder.consume(variableValue(usage: 0x72, value: 0)).isEmpty)
    }

    func testSessionCallsDialPressConsumerOnceForF23DownAndNeverForRelease() async throws {
        let connection = TestKeyboardHIDConnection(plan: try variablePlan())
        let producer = KeyboardHIDInputEventProducer(
            transport: TestKeyboardHIDTransport(connections: [connection])
        )
        let consumer = RecordingInputConsumer()
        let generation = SessionGeneration(120)
        let session = try await producer.start(generation: generation, consumer: consumer)

        connection.send(.value(variableValue(usage: 0x72, value: 1)))
        connection.send(.value(variableValue(usage: 0x72, value: 1)))
        connection.send(.value(variableValue(usage: 0x72, value: 0)))
        await assertEventually { await consumer.snapshot().dialPresses.count == 1 }

        let snapshot = await consumer.snapshot()
        XCTAssertEqual(snapshot.dialPresses.count, 1)
        XCTAssertEqual(snapshot.dialPresses.first?.0, PhysicalControlID(rawValue: "knob", kind: .dial))
        XCTAssertEqual(snapshot.dialPresses.first?.1, generation)
        XCTAssertTrue(snapshot.events.isEmpty)
        await session.cancel()
    }

    func testArraySlotsDecodeOnlyObservedValuesAndReleaseOnSlotReplacement() throws {
        let descriptors = [arrayDescriptor(cookie: 90), arrayDescriptor(cookie: 91)]
        let plan = try KeyboardHIDElementPlan(validating: descriptors)
        var decoder = KeyboardHIDUsageDecoder(generation: SessionGeneration(13), plan: plan)

        XCTAssertTrue(decoder.consume(arrayValue(cookie: 90, usage: 0x04)).isEmpty)
        XCTAssertEqual(
            decoder.consume(arrayValue(cookie: 90, usage: 0x6b)),
            [.event(try keyEvent("bottom-left", down: true, generation: 13))]
        )
        XCTAssertEqual(
            decoder.consume(arrayValue(cookie: 91, usage: 0x6b)),
            []
        )
        XCTAssertEqual(
            decoder.consume(arrayValue(cookie: 90, usage: 0x6c)),
            [.event(try keyEvent("middle-left", down: true, generation: 13))]
        )
        XCTAssertEqual(
            decoder.consume(arrayValue(cookie: 91, usage: 0x00)),
            [.event(try keyEvent("bottom-left", down: false, generation: 13))]
        )
        XCTAssertEqual(
            decoder.consume(arrayValue(cookie: 90, usage: 0x00)),
            [.event(try keyEvent("middle-left", down: false, generation: 13))]
        )
    }

    func testHeldKeysAreReleasedWhenDecoderIsReset() throws {
        let plan = try variablePlan()
        var decoder = KeyboardHIDUsageDecoder(generation: SessionGeneration(14), plan: plan)
        _ = decoder.consume(variableValue(usage: 0x6b, value: 1))
        _ = decoder.consume(variableValue(usage: 0x72, value: 1))

        XCTAssertEqual(
            decoder.releaseHeldInputs(),
            [.event(try keyEvent("bottom-left", down: false, generation: 14))]
        )
        XCTAssertTrue(decoder.releaseHeldInputs().isEmpty)
    }

    func testSessionCancellationReleasesHeldKeysAndCompletesLifecycle() async throws {
        let connection = TestKeyboardHIDConnection(plan: try variablePlan())
        let producer = KeyboardHIDInputEventProducer(
            transport: TestKeyboardHIDTransport(connections: [connection])
        )
        let consumer = RecordingInputConsumer()
        let generation = SessionGeneration(140)
        let session = try await producer.start(generation: generation, consumer: consumer)

        connection.send(.value(variableValue(usage: 0x6b, value: 1)))
        await assertEventually { await consumer.events.count == 1 }
        await session.cancel()

        let snapshot = await consumer.snapshot()
        XCTAssertEqual(snapshot.events.map(\.payload), [.keyDown, .keyUp])
        XCTAssertEqual(snapshot.lifecycle, [
            .started(generation),
            .stopping(generation),
            .stopped(generation),
        ])
        XCTAssertTrue(connection.wasCancelled)

        await session.cancel()
        let snapshotAfterRepeatedCancel = await consumer.snapshot()
        XCTAssertEqual(snapshotAfterRepeatedCancel, snapshot)
    }

    func testElementPlanFailsClosedForMissingOrAmbiguousInputLayouts() throws {
        var missing = variableDescriptors()
        missing.removeLast()
        XCTAssertThrowsError(try KeyboardHIDElementPlan(validating: missing))

        var ambiguous = variableDescriptors()
        ambiguous.append(arrayDescriptor(cookie: 90))
        XCTAssertThrowsError(try KeyboardHIDElementPlan(validating: ambiguous))

        let twoArrayGroups = [
            arrayDescriptor(cookie: 90, reportID: 1),
            arrayDescriptor(cookie: 91, reportID: 2),
        ]
        XCTAssertThrowsError(try KeyboardHIDElementPlan(validating: twoArrayGroups))
    }

    func testDisconnectReleasesHeldKeyAndReconnectsWithinSameGeneration() async throws {
        let first = TestKeyboardHIDConnection(plan: try variablePlan())
        let second = TestKeyboardHIDConnection(plan: try variablePlan())
        let transport = TestKeyboardHIDTransport(connections: [first, second])
        let consumer = RecordingInputConsumer()
        let producer = KeyboardHIDInputEventProducer(transport: transport)
        let generation = SessionGeneration(15)

        let session = try await producer.start(generation: generation, consumer: consumer)
        first.send(.value(variableValue(usage: 0x6b, value: 1)))
        await assertEventually { await consumer.events.count == 1 }
        first.send(.disconnected)

        await assertEventually {
            let snapshot = await consumer.snapshot()
            return snapshot.events.count == 2
                && snapshot.lifecycle.filter { $0 == .started(generation) }.count == 2
        }
        let beforeLateValue = await consumer.snapshot()
        XCTAssertEqual(beforeLateValue.events.map(\.payload), [.keyDown, .keyUp])
        XCTAssertEqual(beforeLateValue.events.map(\.generation), [generation, generation])
        await assertEventually { first.wasCancelled }

        second.send(.value(variableValue(usage: 0x71, value: 1)))
        await assertEventually { await consumer.events.count == 3 }
        let afterReconnect = await consumer.snapshot()
        XCTAssertEqual(afterReconnect.events.last?.payload, .dialRotation(delta: -1))

        await session.cancel()
        let beforeStaleCallback = await consumer.snapshot()
        first.send(.value(variableValue(usage: 0x6c, value: 1)))
        second.send(.value(variableValue(usage: 0x6d, value: 1)))
        try await Task.sleep(for: .milliseconds(30))
        let afterStaleCallback = await consumer.snapshot()
        XCTAssertEqual(afterStaleCallback, beforeStaleCallback)
    }

    func testPauseReleasesInputsAndResumeWaitsForOneCurrentTarget() async throws {
        let first = TestKeyboardHIDConnection(plan: try variablePlan())
        let second = TestKeyboardHIDConnection(plan: try variablePlan())
        let transport = TestKeyboardHIDTransport(connections: [first, second])
        let consumer = RecordingInputConsumer()
        let producer = KeyboardHIDInputEventProducer(transport: transport)
        let generation = SessionGeneration(16)
        let session = try await producer.start(generation: generation, consumer: consumer)
        first.send(.value(variableValue(usage: 0x70, value: 1)))
        await assertEventually { await consumer.events.count == 1 }

        await producer.setPaused(true)
        await assertEventually { first.wasCancelled }
        let pausedSnapshot = await consumer.snapshot()
        XCTAssertEqual(pausedSnapshot.events.map(\.payload), [.keyDown, .keyUp])
        XCTAssertEqual(pausedSnapshot.lifecycle, [.started(generation), .stopping(generation)])

        try await Task.sleep(for: .milliseconds(350))
        let attemptsWhilePaused = await transport.connectionAttempts
        XCTAssertEqual(attemptsWhilePaused, 1)

        await producer.setPaused(false)
        await assertEventually {
            let snapshot = await consumer.snapshot()
            let attempts = await transport.connectionAttempts
            return snapshot.lifecycle.filter { $0 == .started(generation) }.count == 2
                && attempts == 2
        }
        await session.cancel()
    }

    func testPermissionLossFailsSessionAndRejectsLateValues() async throws {
        let connection = TestKeyboardHIDConnection(plan: try variablePlan())
        let unusedReconnect = TestKeyboardHIDConnection(plan: try variablePlan())
        let transport = TestKeyboardHIDTransport(connections: [connection, unusedReconnect])
        let consumer = RecordingInputConsumer()
        let producer = KeyboardHIDInputEventProducer(transport: transport)
        let generation = SessionGeneration(17)
        let session = try await producer.start(generation: generation, consumer: consumer)
        connection.send(.value(variableValue(usage: 0x6e, value: 1)))
        await assertEventually { await consumer.events.count == 1 }

        connection.send(.permissionLost)
        await assertEventually {
            let snapshot = await consumer.snapshot()
            return snapshot.lifecycle.contains(.failed(
                generation,
                reason: KeyboardHIDCaptureError.permissionUnavailable.localizedDescription
            ))
        }
        let failedSnapshot = await consumer.snapshot()
        XCTAssertEqual(failedSnapshot.events.map(\.payload), [.keyDown, .keyUp])
        let attemptsAfterPermissionLoss = await transport.connectionAttempts
        XCTAssertEqual(attemptsAfterPermissionLoss, 1)
        connection.send(.value(variableValue(usage: 0x6f, value: 1)))
        try await Task.sleep(for: .milliseconds(30))
        let afterLateValue = await consumer.snapshot()
        XCTAssertEqual(afterLateValue, failedSnapshot)
        await session.cancel()
    }

    func testNewGenerationCannotReceiveFromClosedPriorSession() async throws {
        let oldConnection = TestKeyboardHIDConnection(plan: try variablePlan(), finishesStreamOnCancel: false)
        let newConnection = TestKeyboardHIDConnection(plan: try variablePlan())
        let transport = TestKeyboardHIDTransport(connections: [oldConnection, newConnection])
        let consumer = RecordingInputConsumer()
        let producer = KeyboardHIDInputEventProducer(transport: transport)

        let oldSession = try await producer.start(generation: SessionGeneration(18), consumer: consumer)
        await oldSession.cancel()
        let newGeneration = SessionGeneration(19)
        let newSession = try await producer.start(generation: newGeneration, consumer: consumer)

        oldConnection.send(.value(variableValue(usage: 0x6b, value: 1)))
        newConnection.send(.value(variableValue(usage: 0x6c, value: 1)))
        await assertEventually { await consumer.events.count == 1 }
        let snapshot = await consumer.snapshot()
        XCTAssertEqual(snapshot.events.map(\.generation), [newGeneration])
        XCTAssertEqual(snapshot.events.first?.payload, .keyDown)
        await newSession.cancel()
    }

    private func variablePlan() throws -> KeyboardHIDElementPlan {
        try KeyboardHIDElementPlan(validating: variableDescriptors())
    }

    private func variableDescriptors() -> [KeyboardHIDElementDescriptor] {
        (UInt32(0x6b)...UInt32(0x73)).enumerated().map { index, usage in
            KeyboardHIDElementDescriptor(
                cookie: UInt64(index + 1),
                usagePage: KeyboardHIDTarget.keyboardUsagePage,
                representation: .variable(usage: usage),
                reportID: 3,
                reportCount: 1,
                logicalMinimum: 0,
                logicalMaximum: 1
            )
        }
    }

    private func arrayDescriptor(cookie: UInt64, reportID: UInt32 = 3) -> KeyboardHIDElementDescriptor {
        KeyboardHIDElementDescriptor(
            cookie: cookie,
            usagePage: KeyboardHIDTarget.keyboardUsagePage,
            representation: .array(minimumUsage: 0, maximumUsage: 0xe7),
            reportID: reportID,
            reportCount: 6,
            logicalMinimum: 0,
            logicalMaximum: 0xe7
        )
    }

    private func variableValue(usage: UInt32, value: Int64) -> KeyboardHIDRawValue {
        KeyboardHIDRawValue(
            cookie: UInt64(usage - 0x6b + 1),
            usagePage: KeyboardHIDTarget.keyboardUsagePage,
            elementUsage: usage,
            isArray: false,
            integerValue: value
        )
    }

    private func arrayValue(cookie: UInt64, usage: Int64) -> KeyboardHIDRawValue {
        KeyboardHIDRawValue(
            cookie: cookie,
            usagePage: KeyboardHIDTarget.keyboardUsagePage,
            elementUsage: 0,
            isArray: true,
            integerValue: usage
        )
    }

    private func keyEvent(_ identifier: String, down: Bool, generation: UInt64) throws -> NormalizedInputEvent {
        let control = try XCTUnwrap(PhysicalControlID(rawValue: identifier, kind: .key))
        let sessionGeneration = SessionGeneration(generation)
        return try XCTUnwrap(down
            ? NormalizedInputEvent.keyDown(control: control, generation: sessionGeneration)
            : NormalizedInputEvent.keyUp(control: control, generation: sessionGeneration))
    }

    private func rotationEvent(_ delta: Int, generation: UInt64) throws -> NormalizedInputEvent {
        try XCTUnwrap(NormalizedInputEvent.dialRotation(
            control: XCTUnwrap(PhysicalControlID(rawValue: "knob", kind: .dial)),
            delta: delta,
            generation: SessionGeneration(generation)
        ))
    }

    private func eventValue(_ delivery: KeyboardHIDDelivery) -> NormalizedInputEvent? {
        guard case .event(let event) = delivery else { return nil }
        return event
    }

    private func waitUntil(
        attempts: Int = 120,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func assertEventually(
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async {
        let succeeded = await waitUntil(condition: condition)
        XCTAssertTrue(succeeded, file: file, line: line)
    }
}

private actor TestKeyboardHIDTransport: KeyboardHIDCaptureTransport {
    private var connections: [TestKeyboardHIDConnection]
    private(set) var connectionAttempts = 0

    init(connections: [TestKeyboardHIDConnection]) {
        self.connections = connections
    }

    func connectToUniqueTarget() async throws -> any KeyboardHIDCaptureConnection {
        connectionAttempts += 1
        guard !connections.isEmpty else { throw KeyboardHIDCaptureError.targetUnavailable }
        return connections.removeFirst()
    }
}

private final class TestKeyboardHIDConnection: KeyboardHIDCaptureConnection, @unchecked Sendable {
    let elementPlan: KeyboardHIDElementPlan
    let events: AsyncStream<KeyboardHIDTransportEvent>

    private let continuation: AsyncStream<KeyboardHIDTransportEvent>.Continuation
    private let lock = NSLock()
    private let finishesStreamOnCancel: Bool
    private var cancelled = false

    init(plan: KeyboardHIDElementPlan, finishesStreamOnCancel: Bool = true) {
        elementPlan = plan
        self.finishesStreamOnCancel = finishesStreamOnCancel
        let pair = AsyncStream<KeyboardHIDTransportEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func send(_ event: KeyboardHIDTransportEvent) {
        continuation.yield(event)
    }

    var wasCancelled: Bool { lock.withLock { cancelled } }

    func cancel() async {
        lock.withLock { cancelled = true }
        if finishesStreamOnCancel { continuation.finish() }
    }
}

private actor RecordingInputConsumer: NormalizedInputConsumer {
    struct Snapshot: Equatable {
        let events: [NormalizedInputEvent]
        let lifecycle: [SessionLifecycleEvent]
        let dialPresses: [(PhysicalControlID, SessionGeneration)]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.events == rhs.events
                && lhs.lifecycle == rhs.lifecycle
                && lhs.dialPresses.count == rhs.dialPresses.count
                && zip(lhs.dialPresses, rhs.dialPresses).allSatisfy {
                    $0.0.0 == $0.1.0 && $0.0.1 == $0.1.1
                }
        }
    }

    private(set) var events: [NormalizedInputEvent] = []
    private(set) var lifecycleEvents: [SessionLifecycleEvent] = []
    private var dialPresses: [(PhysicalControlID, SessionGeneration)] = []

    func consume(_ event: NormalizedInputEvent) async {
        events.append(event)
    }

    func sessionLifecycleChanged(_ event: SessionLifecycleEvent) async {
        lifecycleEvents.append(event)
    }

    func dialPressed(control: PhysicalControlID, generation: SessionGeneration) async -> ActionExecutionResult {
        dialPresses.append((control, generation))
        return ActionExecutionResult(outcome: .ignored)
    }

    func snapshot() -> Snapshot {
        Snapshot(events: events, lifecycle: lifecycleEvents, dialPresses: dialPresses)
    }
}
