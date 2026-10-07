import XCTest
@testable import DialDeckCore

final class ContractsSmokeTests: XCTestCase {
    func testFakeInputProducerDeliversGenerationScopedEventsAndCancels() async throws {
        let control = try XCTUnwrap(PhysicalControlID(rawValue: "opaque-key-a", kind: .key))
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "opaque-dial-a", kind: .dial))
        let generation = SessionGeneration(4)
        let focusEpochClock = FocusEpochClock()
        let consumer = FakeInputConsumer()
        let producer = FakeInputProducer(control: control, dial: dial)
        let expectedEvents = [
            try XCTUnwrap(NormalizedInputEvent.keyDown(
                control: control,
                generation: generation,
                focusEpoch: focusEpochClock.snapshot()
            )),
            try XCTUnwrap(NormalizedInputEvent.keyUp(
                control: control,
                generation: generation,
                focusEpoch: focusEpochClock.snapshot()
            )),
            try XCTUnwrap(NormalizedInputEvent.dialRotation(
                control: dial,
                delta: 1,
                generation: generation,
                focusEpoch: focusEpochClock.snapshot()
            )),
            try XCTUnwrap(NormalizedInputEvent.keyDown(
                control: control,
                generation: generation,
                focusEpoch: focusEpochClock.snapshot()
            )),
        ]

        let session = try await producer.start(
            generation: generation,
            consumer: consumer,
            focusEpochClock: focusEpochClock
        )
        let events = await consumer.events
        XCTAssertEqual(events, expectedEvents)
        XCTAssertEqual(session.generation, generation)
        let heldBeforeCancellation = await consumer.heldControls
        XCTAssertEqual(heldBeforeCancellation, [control])

        await session.cancel()
        let wasCancelled = await (session as! FakeInputSession).isCancelled
        let heldAfterCancellation = await consumer.heldControls
        let lifecycleEvents = await consumer.lifecycleEvents
        XCTAssertTrue(wasCancelled)
        XCTAssertTrue(heldAfterCancellation.isEmpty)
        XCTAssertEqual(lifecycleEvents, [.started(generation), .stopping(generation), .stopped(generation)])
    }

    func testNormalizedInputFactoriesRejectMismatchedControlKinds() throws {
        let key = try XCTUnwrap(PhysicalControlID(rawValue: "opaque-key-a", kind: .key))
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "opaque-dial-a", kind: .dial))
        let generation = SessionGeneration(5)

        XCTAssertNil(NormalizedInputEvent.keyDown(control: dial, generation: generation))
        XCTAssertNil(NormalizedInputEvent.keyUp(control: dial, generation: generation))
        XCTAssertNil(NormalizedInputEvent.dialRotation(control: key, delta: 1, generation: generation))
        XCTAssertNotNil(NormalizedInputEvent.keyDown(control: key, generation: generation))
        XCTAssertNotNil(NormalizedInputEvent.keyUp(control: key, generation: generation))
        XCTAssertNotNil(NormalizedInputEvent.dialRotation(control: dial, delta: 1, generation: generation))
    }

    func testLegacyNormalizedInputConsumerGetsIgnoredDialPressDefault() async throws {
        let key = try XCTUnwrap(PhysicalControlID(rawValue: "opaque-key-a", kind: .key))
        let generation = SessionGeneration(6)
        let consumer: any NormalizedInputConsumer = LegacyNormalizedInputConsumer()

        let result = await consumer.dialPressed(control: key, generation: generation)

        XCTAssertEqual(result.outcome, .ignored)
    }

    func testCapabilityAndProgrammingConsumersPreserveUnverifiedStates() async throws {
        let control = try XCTUnwrap(PhysicalControlID(rawValue: "opaque-dial-a", kind: .dial))
        let request = ProgrammingRequest(assignments: [
            .init(control: control, actionIdentifier: "example.action")
        ])
        let capabilities = FakeCapabilities()
        let programmer = FakeProgrammer(outcome: .sentUnverified)

        let capabilitySnapshot = await capabilities.currentCapabilities()
        let result = await programmer.program(request)
        let capturedRequest = await programmer.lastRequest

        XCTAssertEqual(capabilitySnapshot, DeviceCapabilities())
        XCTAssertEqual(result, ProgrammingResult(requestID: request.requestID, outcome: .sentUnverified))
        XCTAssertEqual(capturedRequest, request)
    }

    func testRuntimeCommandConsumerExposesLifecycleStatus() async {
        let runtime = FakeRuntime()

        let startCompletion = await runtime.submit(.start)
        let runningStatus = await runtime.currentStatus()
        let stopCompletion = await runtime.submit(.stop)
        let finalStatus = await runtime.currentStatus()

        XCTAssertEqual(startCompletion, .noProgrammingResult)
        XCTAssertEqual(stopCompletion, .noProgrammingResult)
        XCTAssertEqual(runningStatus, .running(generation: SessionGeneration(1)))
        XCTAssertEqual(finalStatus, .idle)
    }

    func testExistingRuntimeCommandHandlerUsesFailClosedTypedAssignmentDefault() async {
        let handler: any RuntimeCommandHandling = LegacyRuntimeCommandHandler()
        let request = KeyAssignmentProgrammingRequest(
            requestID: UUID(),
            candidate: .topLeftUsage05,
            acceptsPersistentOverwrite: true
        )

        let completion = await handler.submit(.start)
        let result = await handler.programKeyAssignment(request)

        XCTAssertEqual(completion, .noProgrammingResult)
        XCTAssertEqual(result, .init(
            requestID: request.requestID,
            outcome: .failed(
                reason: "This runtime does not support typed key assignment",
                reportsAccepted: 0
            )
        ))
    }

    func testProgramCommandReturnsCorrelatedResultAtEveryOutcomeLevel() async throws {
        let control = try XCTUnwrap(PhysicalControlID(rawValue: "opaque-key-a", kind: .key))
        let outcomes: [ProgrammingOutcome] = [
            .sentUnverified,
            .behaviorVerified(.init(summary: "synthetic behavior evidence")),
            .persistenceVerified(.init(summary: "synthetic persistence evidence")),
            .failed(.init(reason: "synthetic programming failure")),
        ]
        for expectedOutcome in outcomes {
            let runtime = FakeRuntime(programmer: FakeProgrammer(outcome: expectedOutcome))
            let uiConsumer = FakeRuntimeConsumer(runtime: runtime)
            let request = ProgrammingRequest(assignments: [
                .init(control: control, actionIdentifier: "example.action")
            ])

            let completion = await uiConsumer.submit(.program(request))

            switch completion {
            case let .programming(result):
                XCTAssertEqual(result.requestID, request.requestID)
                XCTAssertEqual(result.outcome, expectedOutcome)
            case .lightingProgramming:
                XCTFail("A keyboard assignment command must return a keyboard programming result")
            case .noProgrammingResult:
                XCTFail("A programming command must return its correlated result")
            }
        }
    }

    func testAllProgrammingOutcomeLevelsRemainDistinct() {
        let evidence = VerificationEvidence(summary: "synthetic test evidence")
        XCTAssertNotEqual(ProgrammingOutcome.sentUnverified, .behaviorVerified(evidence))
        XCTAssertNotEqual(ProgrammingOutcome.behaviorVerified(evidence), .persistenceVerified(evidence))
        XCTAssertNotEqual(ProgrammingOutcome.failed(.init(reason: "synthetic failure")), .sentUnverified)
    }
}

private actor LegacyNormalizedInputConsumer: NormalizedInputConsumer {
    func consume(_ event: NormalizedInputEvent) async {}
    func sessionLifecycleChanged(_ event: SessionLifecycleEvent) async {}
}

private actor FakeInputSession: InputSessionHandle {
    nonisolated let generation: SessionGeneration
    private let consumer: any NormalizedInputConsumer
    private var cancellationTask: Task<Void, Never>?
    private(set) var isCancelled = false

    init(generation: SessionGeneration, consumer: any NormalizedInputConsumer) {
        self.generation = generation
        self.consumer = consumer
    }

    func cancel() async {
        if let cancellationTask {
            await cancellationTask.value
            return
        }
        let lifecycleConsumer = consumer
        let currentGeneration = generation
        let task = Task {
            await lifecycleConsumer.sessionLifecycleChanged(.stopping(currentGeneration))
            await lifecycleConsumer.sessionLifecycleChanged(.stopped(currentGeneration))
        }
        cancellationTask = task
        await task.value
        isCancelled = true
    }
}

private actor FakeInputConsumer: NormalizedInputConsumer {
    private(set) var events: [NormalizedInputEvent] = []
    private(set) var lifecycleEvents: [SessionLifecycleEvent] = []
    private(set) var heldControls: Set<PhysicalControlID> = []

    func consume(_ event: NormalizedInputEvent) async {
        events.append(event)
        switch event.payload {
        case .keyDown:
            heldControls.insert(event.control)
        case .keyUp:
            heldControls.remove(event.control)
        case .dialRotation:
            break
        }
    }

    func sessionLifecycleChanged(_ event: SessionLifecycleEvent) async {
        lifecycleEvents.append(event)
        switch event {
        case .stopping, .stopped, .failed:
            heldControls.removeAll()
        case .started:
            break
        }
    }
}

private struct FakeInputProducer: InputEventProducing {
    let control: PhysicalControlID
    let dial: PhysicalControlID

    func start(
        generation: SessionGeneration,
        consumer: any NormalizedInputConsumer,
        focusEpochClock: FocusEpochClock
    ) async throws -> any InputSessionHandle {
        await consumer.sessionLifecycleChanged(.started(generation))
        let events = [
            try XCTUnwrap(NormalizedInputEvent.keyDown(control: control, generation: generation)),
            try XCTUnwrap(NormalizedInputEvent.keyUp(control: control, generation: generation)),
            try XCTUnwrap(NormalizedInputEvent.dialRotation(control: dial, delta: 1, generation: generation)),
            try XCTUnwrap(NormalizedInputEvent.keyDown(control: control, generation: generation)),
        ]
        for event in events {
            await consumer.consume(event)
        }
        return FakeInputSession(generation: generation, consumer: consumer)
    }
}

private struct FakeCapabilities: DeviceCapabilityProviding {
    func currentCapabilities() async -> DeviceCapabilities {
        DeviceCapabilities()
    }
}

private actor FakeProgrammer: DeviceProgramming {
    let outcome: ProgrammingOutcome
    private(set) var lastRequest: ProgrammingRequest?

    init(outcome: ProgrammingOutcome) {
        self.outcome = outcome
    }

    func program(_ request: ProgrammingRequest) async -> ProgrammingResult {
        lastRequest = request
        return ProgrammingResult(requestID: request.requestID, outcome: outcome)
    }
}

private struct FakeRuntimeConsumer: Sendable {
    let runtime: any RuntimeCommandHandling

    func submit(_ command: RuntimeCommand) async -> RuntimeCommandCompletion {
        await runtime.submit(command)
    }
}

private struct LegacyRuntimeCommandHandler: RuntimeCommandHandling {
    func submit(_ command: RuntimeCommand) async -> RuntimeCommandCompletion {
        .noProgrammingResult
    }
}

private actor FakeRuntime: RuntimeCommandHandling, RuntimeStatusProviding {
    private var status: RuntimeStatus = .idle
    private var nextGeneration: UInt64 = 1
    private let programmer: any DeviceProgramming

    init(programmer: any DeviceProgramming = FakeProgrammer(outcome: .sentUnverified)) {
        self.programmer = programmer
    }

    func submit(_ command: RuntimeCommand) async -> RuntimeCommandCompletion {
        switch command {
        case .start:
            status = .running(generation: SessionGeneration(nextGeneration))
            nextGeneration += 1
            return .noProgrammingResult
        case .stop:
            status = .idle
            return .noProgrammingResult
        case .refreshCapabilities:
            return .noProgrammingResult
        case let .program(request):
            return .programming(await programmer.program(request))
        case let .programLighting(request):
            return .lightingProgramming(.init(
                requestID: request.requestID,
                outcome: .failed(reason: "Fake runtime has no lighting programmer", reportsAccepted: 0)
            ))
        }
    }

    func currentStatus() async -> RuntimeStatus {
        status
    }
}
