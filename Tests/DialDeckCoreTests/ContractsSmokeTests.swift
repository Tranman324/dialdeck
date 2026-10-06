import XCTest
@testable import DialDeckCore

final class ContractsSmokeTests: XCTestCase {
    func testFakeInputProducerDeliversGenerationScopedEventsAndCancels() async throws {
        let control = try XCTUnwrap(PhysicalControlID(rawValue: "opaque-key-a", kind: .key))
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "opaque-dial-a", kind: .dial))
        let generation = SessionGeneration(4)
        let consumer = FakeInputConsumer()
        let producer = FakeInputProducer(control: control, dial: dial)

        let session = try await producer.start(generation: generation, consumer: consumer)
        let events = await consumer.events
        XCTAssertEqual(events, [
            .keyDown(control: control, generation: generation),
            .keyUp(control: control, generation: generation),
            .dialRotation(control: dial, delta: 1, generation: generation),
            .keyDown(control: control, generation: generation),
        ])
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

        await runtime.submit(.start)
        let runningStatus = await runtime.currentStatus()
        await runtime.submit(.stop)
        let finalStatus = await runtime.currentStatus()

        XCTAssertEqual(runningStatus, .running(generation: SessionGeneration(1)))
        XCTAssertEqual(finalStatus, .idle)
    }

    func testAllProgrammingOutcomeLevelsRemainDistinct() {
        let evidence = VerificationEvidence(summary: "synthetic test evidence")
        XCTAssertNotEqual(ProgrammingOutcome.sentUnverified, .behaviorVerified(evidence))
        XCTAssertNotEqual(ProgrammingOutcome.behaviorVerified(evidence), .persistenceVerified(evidence))
        XCTAssertNotEqual(ProgrammingOutcome.failed(.init(reason: "synthetic failure")), .sentUnverified)
    }
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
        switch event {
        case let .keyDown(control, _):
            heldControls.insert(control)
        case let .keyUp(control, _):
            heldControls.remove(control)
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
        consumer: any NormalizedInputConsumer
    ) async throws -> any InputSessionHandle {
        await consumer.sessionLifecycleChanged(.started(generation))
        await consumer.consume(.keyDown(control: control, generation: generation))
        await consumer.consume(.keyUp(control: control, generation: generation))
        await consumer.consume(.dialRotation(control: dial, delta: 1, generation: generation))
        await consumer.consume(.keyDown(control: control, generation: generation))
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

private actor FakeRuntime: RuntimeCommandHandling, RuntimeStatusProviding {
    private var status: RuntimeStatus = .idle
    private var nextGeneration: UInt64 = 1

    func submit(_ command: RuntimeCommand) async {
        switch command {
        case .start:
            status = .running(generation: SessionGeneration(nextGeneration))
            nextGeneration += 1
        case .stop:
            status = .idle
        case .refreshCapabilities, .program:
            break
        }
    }

    func currentStatus() async -> RuntimeStatus {
        status
    }
}
