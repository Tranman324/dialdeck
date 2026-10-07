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

    func testChildSelectionChoosesOneCompleteKeyboardAmongTwoCandidates() throws {
        let incompleteDescriptors = Array(variableDescriptors().dropLast())
        let candidates = [
            childIdentity(descriptors: incompleteDescriptors, registryEntryID: 21),
            childIdentity(registryEntryID: 22),
        ]

        let selectedIndex = try KeyboardHIDChildSelection.uniqueEligibleIndex(in: candidates)

        XCTAssertEqual(selectedIndex, 1)
        XCTAssertEqual(candidates[selectedIndex].elementPlan?.inputsByCookie.count, 9)
    }

    func testChildSelectionFailsWhenNoCandidateHasACompleteVariablePlan() {
        let candidates = [
            childIdentity(descriptors: Array(variableDescriptors().dropLast()), registryEntryID: 31),
            childIdentity(descriptors: [arrayDescriptor(cookie: 90)], registryEntryID: 32),
        ]

        XCTAssertThrowsError(try KeyboardHIDChildSelection.uniqueEligibleIndex(in: candidates)) { error in
            XCTAssertEqual(error as? KeyboardHIDCaptureError, .interfaceMismatch)
        }
    }

    func testChildSelectionFailsWhenTwoChildrenHaveCompleteVariablePlans() {
        let candidates = [
            childIdentity(registryEntryID: 41),
            childIdentity(registryEntryID: 42, usagePairs: [
                KeyboardHIDUsagePair(usagePage: KeyboardHIDTarget.genericDesktopUsagePage,
                                     usage: KeyboardHIDTarget.keyboardApplicationUsage),
                KeyboardHIDUsagePair(usagePage: 0x0c, usage: 0x01),
            ]),
        ]

        XCTAssertThrowsError(try KeyboardHIDChildSelection.uniqueEligibleIndex(in: candidates)) { error in
            XCTAssertEqual(error as? KeyboardHIDCaptureError, .ambiguousTarget)
        }
    }

    func testChildSelectionRequiresExactlyOneKeyboardApplicationCollection() {
        for collectionCount in [0, 2] {
            let candidate = childIdentity(keyboardApplicationCollectionCount: collectionCount)
            XCTAssertThrowsError(try KeyboardHIDChildSelection.uniqueEligibleIndex(in: [candidate])) { error in
                XCTAssertEqual(error as? KeyboardHIDCaptureError, .interfaceMismatch)
            }
        }
    }

    func testArrayBearingChildIsIneligibleAndNeverMergedIntoVariablePlan() throws {
        var arrayDescriptors = variableDescriptors()
        arrayDescriptors.append(arrayDescriptor(cookie: 90))
        let candidates = [
            childIdentity(descriptors: arrayDescriptors, registryEntryID: 51),
            childIdentity(registryEntryID: 52),
        ]

        let selectedIndex = try KeyboardHIDChildSelection.uniqueEligibleIndex(in: candidates)

        XCTAssertEqual(selectedIndex, 1)
        XCTAssertEqual(candidates[selectedIndex].elementPlan?.inputsByCookie.count, 9)
        XCTAssertNil(childIdentity(descriptors: arrayDescriptors).elementPlan)
        XCTAssertThrowsError(try KeyboardHIDChildSelection.uniqueEligibleIndex(in: [
            childIdentity(descriptors: arrayDescriptors),
        ]))

        let unboundedArray = KeyboardHIDElementDescriptor(
            cookie: 91,
            usagePage: KeyboardHIDTarget.keyboardUsagePage,
            representation: .array(minimumUsage: nil, maximumUsage: nil),
            reportID: 3,
            reportCount: 6,
            logicalMinimum: 0,
            logicalMaximum: 0xe7
        )
        XCTAssertNil(childIdentity(descriptors: variableDescriptors() + [unboundedArray]).elementPlan)

        let unrelatedArray = arrayDescriptor(cookie: 92, minimumUsage: 0, maximumUsage: 0x65)
        XCTAssertNoThrow(try KeyboardHIDElementPlan(validating: variableDescriptors() + [unrelatedArray]))
    }

    func testChildIdentityComparesFingerprintUsagePairsRegistryIDAndElementPlan() {
        let baseline = childIdentity(registryEntryID: 61)

        var changedReport = variableDescriptors()
        changedReport[0] = KeyboardHIDElementDescriptor(
            cookie: changedReport[0].cookie,
            usagePage: changedReport[0].usagePage,
            representation: changedReport[0].representation,
            reportID: 4,
            reportCount: changedReport[0].reportCount,
            logicalMinimum: changedReport[0].logicalMinimum,
            logicalMaximum: changedReport[0].logicalMaximum
        )
        let changedFingerprint = childIdentity(descriptors: changedReport, registryEntryID: 61)
        let changedUsagePairs = childIdentity(registryEntryID: 61, usagePairs: [
            KeyboardHIDUsagePair(usagePage: KeyboardHIDTarget.genericDesktopUsagePage,
                                 usage: KeyboardHIDTarget.keyboardApplicationUsage),
            KeyboardHIDUsagePair(usagePage: 0x0c, usage: 0x01),
        ])
        let changedRegistryID = childIdentity(registryEntryID: 62)
        let changedCookies = childIdentity(
            descriptors: variableDescriptors().map { descriptor in
                KeyboardHIDElementDescriptor(
                    cookie: descriptor.cookie + 100,
                    usagePage: descriptor.usagePage,
                    representation: descriptor.representation,
                    reportID: descriptor.reportID,
                    reportCount: descriptor.reportCount,
                    logicalMinimum: descriptor.logicalMinimum,
                    logicalMaximum: descriptor.logicalMaximum
                )
            },
            registryEntryID: 61
        )

        XCTAssertNotEqual(baseline, changedFingerprint)
        XCTAssertNotEqual(baseline, changedUsagePairs)
        XCTAssertNotEqual(baseline, changedRegistryID)
        XCTAssertNotEqual(baseline, changedCookies)
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

    func testMultiSlotArraysFailClosedWhenReportCoverageAndMigrationOrderAreUnknown() {
        let sixSlotLayout = (0..<6).map { slot in
            arrayDescriptor(cookie: UInt64(90 + slot), reportID: 3, reportCount: 6)
        }
        XCTAssertThrowsError(try KeyboardHIDElementPlan(validating: sixSlotLayout))

        let twoCookiesForSixReportedSlots = [
            arrayDescriptor(cookie: 90, reportID: 3, reportCount: 6),
            arrayDescriptor(cookie: 91, reportID: 3, reportCount: 6),
        ]
        XCTAssertThrowsError(try KeyboardHIDElementPlan(validating: twoCookiesForSixReportedSlots))

        var mixed = variableDescriptors()
        mixed.append(arrayDescriptor(cookie: 90, reportID: 3, reportCount: 6))
        XCTAssertThrowsError(try KeyboardHIDElementPlan(validating: mixed))
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

    func testConcurrentCancelAndReplacementStartJoinHeldInputAndConnectionTeardown() async throws {
        let keyUpEntered = TestAsyncBarrier()
        let allowKeyUp = TestAsyncBarrier()
        let connectionCancelEntered = TestAsyncBarrier()
        let allowConnectionCancel = TestAsyncBarrier()
        let firstConnection = TestKeyboardHIDConnection(
            plan: try variablePlan(),
            cancelEntered: connectionCancelEntered,
            cancelBarrier: allowConnectionCancel
        )
        let replacementConnection = TestKeyboardHIDConnection(plan: try variablePlan())
        let transport = TestKeyboardHIDTransport(connections: [firstConnection, replacementConnection])
        let consumer = BarrierInputConsumer(keyUpEntered: keyUpEntered, allowKeyUp: allowKeyUp)
        let producer = KeyboardHIDInputEventProducer(transport: transport)
        let firstGeneration = SessionGeneration(141)
        let session = try await producer.start(generation: firstGeneration, consumer: consumer)

        firstConnection.send(.value(variableValue(usage: 0x6b, value: 1)))
        await assertEventually { await consumer.eventCount == 1 }

        let firstCancelFinished = TestAsyncBarrier()
        let firstCancel = Task {
            await session.cancel()
            await firstCancelFinished.open()
        }
        await keyUpEntered.wait()

        let secondCancelStarted = TestAsyncBarrier()
        let secondCancelFinished = TestAsyncBarrier()
        let secondCancel = Task {
            await secondCancelStarted.open()
            await session.cancel()
            await secondCancelFinished.open()
        }
        let replacementStarted = TestAsyncBarrier()
        let replacementFinished = TestAsyncBarrier()
        let replacementGeneration = SessionGeneration(142)
        let replacementStart = Task<any InputSessionHandle, Error> {
            await replacementStarted.open()
            let newSession = try await producer.start(generation: replacementGeneration, consumer: consumer)
            await replacementFinished.open()
            return newSession
        }

        await secondCancelStarted.wait()
        await replacementStarted.wait()
        try await Task.sleep(for: .milliseconds(30))
        let secondCancelReturnedBeforeRelease = await secondCancelFinished.isOpen
        let replacementReturnedBeforeRelease = await replacementFinished.isOpen
        let attemptsBeforeRelease = await transport.connectionAttempts
        XCTAssertFalse(secondCancelReturnedBeforeRelease)
        XCTAssertFalse(replacementReturnedBeforeRelease)
        XCTAssertEqual(attemptsBeforeRelease, 1)

        await allowKeyUp.open()
        await connectionCancelEntered.wait()
        try await Task.sleep(for: .milliseconds(30))
        let firstCancelReturnedBeforeConnectionClose = await firstCancelFinished.isOpen
        let secondCancelReturnedBeforeConnectionClose = await secondCancelFinished.isOpen
        let replacementReturnedBeforeConnectionClose = await replacementFinished.isOpen
        let attemptsBeforeConnectionClose = await transport.connectionAttempts
        XCTAssertFalse(firstCancelReturnedBeforeConnectionClose)
        XCTAssertFalse(secondCancelReturnedBeforeConnectionClose)
        XCTAssertFalse(replacementReturnedBeforeConnectionClose)
        XCTAssertEqual(attemptsBeforeConnectionClose, 1)

        await allowConnectionCancel.open()
        await firstCancel.value
        await secondCancel.value
        let newSession = try await replacementStart.value
        let finalSnapshot = await consumer.snapshot()
        XCTAssertEqual(finalSnapshot.events.map(\.payload), [.keyDown, .keyUp])
        XCTAssertEqual(finalSnapshot.lifecycle, [
            .started(firstGeneration),
            .stopping(firstGeneration),
            .stopped(firstGeneration),
            .started(replacementGeneration),
        ])
        let attemptsAfterReplacement = await transport.connectionAttempts
        XCTAssertEqual(attemptsAfterReplacement, 2)
        XCTAssertTrue(firstConnection.wasCancelled)

        await session.cancel()
        let snapshotAfterOldCancel = await consumer.snapshot()
        XCTAssertEqual(snapshotAfterOldCancel, finalSnapshot)
        await newSession.cancel()
    }

    func testCancellationJoinsPermissionFailureCleanupWithoutWaitingOnItsReader() async throws {
        let keyUpEntered = TestAsyncBarrier()
        let allowKeyUp = TestAsyncBarrier()
        let connectionCancelEntered = TestAsyncBarrier()
        let allowConnectionCancel = TestAsyncBarrier()
        let connection = TestKeyboardHIDConnection(
            plan: try variablePlan(),
            cancelEntered: connectionCancelEntered,
            cancelBarrier: allowConnectionCancel
        )
        let consumer = BarrierInputConsumer(keyUpEntered: keyUpEntered, allowKeyUp: allowKeyUp)
        let producer = KeyboardHIDInputEventProducer(
            transport: TestKeyboardHIDTransport(connections: [connection])
        )
        let generation = SessionGeneration(143)
        let session = try await producer.start(generation: generation, consumer: consumer)
        connection.send(.value(variableValue(usage: 0x6b, value: 1)))
        await assertEventually { await consumer.eventCount == 1 }

        connection.send(.permissionLost)
        await keyUpEntered.wait()
        let cancelStarted = TestAsyncBarrier()
        let cancelFinished = TestAsyncBarrier()
        let cancelTask = Task {
            await cancelStarted.open()
            await session.cancel()
            await cancelFinished.open()
        }
        await cancelStarted.wait()
        try await Task.sleep(for: .milliseconds(30))
        let cancellationReturnedBeforeKeyRelease = await cancelFinished.isOpen
        XCTAssertFalse(cancellationReturnedBeforeKeyRelease)

        await allowKeyUp.open()
        await connectionCancelEntered.wait()
        try await Task.sleep(for: .milliseconds(30))
        let cancellationReturnedBeforeConnectionClose = await cancelFinished.isOpen
        XCTAssertFalse(cancellationReturnedBeforeConnectionClose)

        await allowConnectionCancel.open()
        await cancelTask.value
        let snapshot = await consumer.snapshot()
        XCTAssertEqual(snapshot.events.map(\.payload), [.keyDown, .keyUp])
        XCTAssertEqual(snapshot.lifecycle, [
            .started(generation),
            .stopping(generation),
            .failed(generation, reason: KeyboardHIDCaptureError.permissionUnavailable.localizedDescription),
        ])
    }

    func testReplacementStartWaitsForInFlightReconnectCandidateTeardown() async throws {
        let reconnectGate = TestConnectionGate()
        let candidateCancelEntered = TestAsyncBarrier()
        let allowCandidateCancel = TestAsyncBarrier()
        let firstConnection = TestKeyboardHIDConnection(plan: try variablePlan())
        let reconnectCandidate = TestKeyboardHIDConnection(
            plan: try variablePlan(),
            cancelEntered: candidateCancelEntered,
            cancelBarrier: allowCandidateCancel
        )
        let replacementConnection = TestKeyboardHIDConnection(plan: try variablePlan())
        let transport = TestKeyboardHIDTransport(
            connections: [firstConnection, reconnectCandidate, replacementConnection],
            gatedAttempts: [1: reconnectGate]
        )
        let consumer = RecordingInputConsumer()
        let producer = KeyboardHIDInputEventProducer(transport: transport)
        let firstGeneration = SessionGeneration(144)
        let session = try await producer.start(generation: firstGeneration, consumer: consumer)

        firstConnection.send(.disconnected)
        await reconnectGate.waitUntilEntered()

        let replacementStarted = TestAsyncBarrier()
        let replacementFinished = TestAsyncBarrier()
        let replacementGeneration = SessionGeneration(145)
        let replacementStart = Task<any InputSessionHandle, Error> {
            await replacementStarted.open()
            let newSession = try await producer.start(generation: replacementGeneration, consumer: consumer)
            await replacementFinished.open()
            return newSession
        }
        await replacementStarted.wait()
        try await Task.sleep(for: .milliseconds(30))
        let replacementReturnedBeforeReconnectResolved = await replacementFinished.isOpen
        let attemptsDuringReconnect = await transport.connectionAttempts
        XCTAssertFalse(replacementReturnedBeforeReconnectResolved)
        XCTAssertEqual(attemptsDuringReconnect, 2)

        await reconnectGate.open()
        await candidateCancelEntered.wait()
        try await Task.sleep(for: .milliseconds(30))
        let replacementReturnedBeforeCandidateClosed = await replacementFinished.isOpen
        let attemptsBeforeCandidateClose = await transport.connectionAttempts
        XCTAssertFalse(replacementReturnedBeforeCandidateClosed)
        XCTAssertEqual(attemptsBeforeCandidateClose, 2)

        await allowCandidateCancel.open()
        let newSession = try await replacementStart.value
        await assertEventually { await transport.connectionAttempts == 3 }
        let snapshot = await consumer.snapshot()
        XCTAssertEqual(snapshot.lifecycle, [
            .started(firstGeneration),
            .stopping(firstGeneration),
            .stopped(firstGeneration),
            .started(replacementGeneration),
        ])
        XCTAssertTrue(firstConnection.wasCancelled)
        XCTAssertTrue(reconnectCandidate.wasCancelled)

        await newSession.cancel()
        await session.cancel()
    }

    func testLateReconnectPermissionFailureDoesNotDeadlockExternalCancellation() async throws {
        let reconnectGate = TestConnectionGate()
        let firstConnection = TestKeyboardHIDConnection(plan: try variablePlan())
        let replacementConnection = TestKeyboardHIDConnection(plan: try variablePlan())
        let transport = TestKeyboardHIDTransport(
            connections: [firstConnection, replacementConnection],
            gatedAttempts: [1: reconnectGate],
            errorsByAttempt: [1: .permissionUnavailable]
        )
        let consumer = RecordingInputConsumer()
        let producer = KeyboardHIDInputEventProducer(transport: transport)
        let firstGeneration = SessionGeneration(146)
        let session = try await producer.start(generation: firstGeneration, consumer: consumer)
        firstConnection.send(.disconnected)
        await reconnectGate.waitUntilEntered()

        let replacementStarted = TestAsyncBarrier()
        let replacementFinished = TestAsyncBarrier()
        let replacementGeneration = SessionGeneration(147)
        let replacementStart = Task<any InputSessionHandle, Error> {
            await replacementStarted.open()
            let newSession = try await producer.start(generation: replacementGeneration, consumer: consumer)
            await replacementFinished.open()
            return newSession
        }
        await replacementStarted.wait()
        try await Task.sleep(for: .milliseconds(30))
        let replacementReturnedBeforePermissionError = await replacementFinished.isOpen
        XCTAssertFalse(replacementReturnedBeforePermissionError)

        await reconnectGate.open()
        let replacementCompleted = await waitUntil {
            await replacementFinished.isOpen
        }
        XCTAssertTrue(replacementCompleted, "External cancellation must join the late reconnect error without deadlocking")
        guard replacementCompleted else { return }

        let newSession = try await replacementStart.value
        let attempts = await transport.connectionAttempts
        XCTAssertEqual(attempts, 3)
        let snapshot = await consumer.snapshot()
        XCTAssertEqual(snapshot.lifecycle, [
            .started(firstGeneration),
            .stopping(firstGeneration),
            .stopped(firstGeneration),
            .started(replacementGeneration),
        ])
        await newSession.cancel()
        await session.cancel()
    }

    func testCaptureProducerRoutesNormalizedKeyAndDialPressThroughActionRuntime() async throws {
        let actionService = CaptureRuntimeActionService()
        let modeID = DialModeID()
        let mode = DialMode(
            id: modeID,
            name: DisplayName("Capture Test")!,
            counterclockwise: .primitive(.doNothing),
            clockwise: .primitive(.doNothing),
            press: .primitive(.zoom(.in))
        )
        let profileID = ProfileID()
        let profile = try Profile(
            id: profileID,
            name: DisplayName("Default")!,
            scope: .default,
            assignments: [.button1: .set(.primitive(.zoom(.out)))],
            dialModes: [mode],
            defaultDialModeID: modeID
        )
        let configuration = try Configuration(defaultProfileID: profileID, profiles: [profile])
        let store = ConfigurationStore(
            primaryURL: URL(fileURLWithPath: "/virtual/capture-runtime-\(UUID().uuidString).json"),
            fileAccess: CaptureRuntimeMemoryFiles()
        )
        try await store.save(configuration)

        let connection = TestKeyboardHIDConnection(plan: try variablePlan())
        let producer = KeyboardHIDInputEventProducer(
            transport: TestKeyboardHIDTransport(connections: [connection])
        )
        let bottomLeft = try XCTUnwrap(PhysicalControlID(rawValue: "bottom-left", kind: .key))
        let runtime = ActionRuntime(
            inputProducer: producer,
            capabilities: CaptureRuntimeCapabilities(),
            programmer: CaptureRuntimeProgrammer(),
            foregroundApplication: CaptureRuntimeForeground(),
            controlMapping: CaptureRuntimeMapping([bottomLeft: .button1]),
            configurationStore: store,
            actionService: actionService
        )

        _ = await runtime.submit(.start)
        connection.send(.value(variableValue(usage: 0x6b, value: 1)))
        connection.send(.value(variableValue(usage: 0x6b, value: 0)))
        connection.send(.value(variableValue(usage: 0x72, value: 1)))
        connection.send(.value(variableValue(usage: 0x72, value: 1)))
        connection.send(.value(variableValue(usage: 0x72, value: 0)))

        await assertEventually { await actionService.intents.count == 2 }
        let intents = await actionService.intents
        XCTAssertEqual(intents.filter { $0 == .zoom(.out, steps: 1, application: nil) }.count, 1)
        XCTAssertEqual(intents.filter { $0 == .zoom(.in, steps: 1, application: nil) }.count, 1)

        _ = await runtime.submit(.stop)
    }

    func testPhysicalVerificationHarnessIsDisabledUnlessExplicitlyEnabled() {
        XCTAssertFalse(PhysicalVerificationHarness.isEnabled(environment: [:]))
        XCTAssertFalse(PhysicalVerificationHarness.isEnabled(environment: [
            PhysicalVerificationHarness.environmentKey: "true",
        ]))
        XCTAssertTrue(PhysicalVerificationHarness.isEnabled(environment: [
            PhysicalVerificationHarness.environmentKey: "1",
        ]))
    }

    func testPhysicalVerificationRecorderBoundsAndForwardsNormalizedEvents() async throws {
        let generation = SessionGeneration(91)
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "knob", kind: .dial))
        let keyIdentifiers = [
            "bottom-left", "middle-left", "top-left",
            "bottom-right", "middle-right", "top-right",
        ]
        let keyEvents = try keyIdentifiers.flatMap { identifier -> [NormalizedInputEvent] in
            let control = try XCTUnwrap(PhysicalControlID(rawValue: identifier, kind: .key))
            return [
                try XCTUnwrap(NormalizedInputEvent.keyDown(control: control, generation: generation)),
                try XCTUnwrap(NormalizedInputEvent.keyUp(control: control, generation: generation)),
            ]
        }
        let counterclockwise = try XCTUnwrap(NormalizedInputEvent.dialRotation(
            control: dial,
            delta: -1,
            generation: generation
        ))
        let clockwise = try XCTUnwrap(NormalizedInputEvent.dialRotation(
            control: dial,
            delta: 1,
            generation: generation
        ))
        let bottomLeft = try XCTUnwrap(PhysicalControlID(rawValue: "bottom-left", kind: .key))
        let afterReconnect = [
            try XCTUnwrap(NormalizedInputEvent.keyDown(control: bottomLeft, generation: generation)),
            try XCTUnwrap(NormalizedInputEvent.keyUp(control: bottomLeft, generation: generation)),
        ]
        let overflow = [try XCTUnwrap(NormalizedInputEvent.keyDown(
            control: bottomLeft,
            generation: generation
        ))]
        let replayEvents = keyEvents + [counterclockwise, clockwise] + afterReconnect + overflow
        let downstream = RecordingInputConsumer()
        let recorder = PhysicalVerificationEventRecorder()
        let producer = PhysicalVerificationRecordingProducer(
            base: PhysicalVerificationReplayProducer(
                eventsBeforeReconnect: keyEvents + [counterclockwise, clockwise],
                eventsAfterReconnect: afterReconnect,
                eventsAfterLimit: overflow,
                dialPress: dial
            ),
            recorder: recorder
        )

        let session = try await producer.start(generation: generation, consumer: downstream)
        let recorded = await recorder.snapshot()
        let forwarded = await downstream.snapshot()
        await session.cancel()

        XCTAssertEqual(recorded.events.count, PhysicalVerificationHarness.maximumEvents)
        XCTAssertEqual(recorded.reconnectEventCount, 15)
        XCTAssertEqual(
            Set(recorded.events),
            Set(keyIdentifiers.flatMap { identifier in
                [
                    PhysicalVerificationRecordedEvent(controlID: identifier, kind: .keyDown),
                    PhysicalVerificationRecordedEvent(controlID: identifier, kind: .keyUp),
                ]
            } + [
                PhysicalVerificationRecordedEvent(controlID: "knob", kind: .dialRotation(delta: -1)),
                PhysicalVerificationRecordedEvent(controlID: "knob", kind: .dialRotation(delta: 1)),
                PhysicalVerificationRecordedEvent(controlID: "knob", kind: .dialPress),
            ])
        )
        XCTAssertEqual(
            Array(recorded.events.suffix(5)),
            [
                .init(controlID: "knob", kind: .dialRotation(delta: -1)),
                .init(controlID: "knob", kind: .dialRotation(delta: 1)),
                .init(controlID: "knob", kind: .dialPress),
                .init(controlID: "bottom-left", kind: .keyDown),
                .init(controlID: "bottom-left", kind: .keyUp),
            ]
        )
        XCTAssertEqual(forwarded.events, replayEvents)
        XCTAssertEqual(forwarded.dialPresses.count, 1)
        XCTAssertEqual(forwarded.dialPresses.first?.0, dial)
        XCTAssertEqual(forwarded.dialPresses.first?.1, generation)
        XCTAssertEqual(forwarded.lifecycle, [
            .started(generation),
            .stopping(generation),
            .started(generation),
        ])
    }

    /// Opt-in supervised check: press and release each of six keys, rotate the
    /// dial once counterclockwise then once clockwise, press it once, unplug/
    /// reconnect the keypad, then press and release bottom-left once more. The
    /// recorder stores normalized control IDs, event kinds, and signed dial
    /// deltas, never raw HID values or text.
    /// Read-only monitoring does not suppress normal macOS keyboard delivery;
    /// any later supervised run must use a safe foreground context.
    func testOptInPhysicalKeyboardHIDVerificationRoutesToNoOpRuntime() async throws {
        guard PhysicalVerificationHarness.isEnabled(environment: ProcessInfo.processInfo.environment) else {
            throw XCTSkip("Set DIALDECK_RUN_PHYSICAL_HID_VERIFICATION=1 for supervised physical verification.")
        }

        let actionService = PhysicalVerificationNoOpActionService()
        let profileID = ProfileID()
        let modeID = DialModeID()
        let noOp = ConfiguredAction.primitive(.doNothing)
        let mode = DialMode(
            id: modeID,
            name: DisplayName("Physical Verification")!,
            counterclockwise: noOp,
            clockwise: noOp,
            press: noOp
        )
        let profile = try Profile(
            id: profileID,
            name: DisplayName("Default")!,
            scope: .default,
            assignments: Dictionary(uniqueKeysWithValues: ActionAssignmentTarget.allCases.map {
                ($0, .set(noOp))
            }),
            dialModes: [mode],
            defaultDialModeID: modeID
        )
        let configuration = try Configuration(defaultProfileID: profileID, profiles: [profile])
        let store = ConfigurationStore(
            primaryURL: URL(fileURLWithPath: "/virtual/physical-verification-\(UUID().uuidString).json"),
            fileAccess: CaptureRuntimeMemoryFiles()
        )
        try await store.save(configuration)

        let keyTargets: [(String, ActionAssignmentTarget)] = [
            ("bottom-left", .button1),
            ("middle-left", .button2),
            ("top-left", .button3),
            ("bottom-right", .button4),
            ("middle-right", .button5),
            ("top-right", .button6),
        ]
        let mapping = Dictionary(uniqueKeysWithValues: try keyTargets.map { identifier, target in
            (try XCTUnwrap(PhysicalControlID(rawValue: identifier, kind: .key)), target)
        })
        let recorder = PhysicalVerificationEventRecorder()
        let producer = PhysicalVerificationRecordingProducer(
            base: KeyboardHIDInputEventProducer(),
            recorder: recorder
        )
        let runtime = ActionRuntime(
            inputProducer: producer,
            capabilities: CaptureRuntimeCapabilities(),
            programmer: CaptureRuntimeProgrammer(),
            foregroundApplication: CaptureRuntimeForeground(),
            controlMapping: CaptureRuntimeMapping(mapping),
            configurationStore: store,
            actionService: actionService
        )

        do {
            _ = await runtime.submit(.start)
            guard case .running = await runtime.currentStatus() else {
                throw PhysicalVerificationHarnessError.sessionDidNotStart(
                    await runtime.currentStatus()
                )
            }

            let recorded = try await PhysicalVerificationHarness.waitForReconnectSequence(
                from: recorder,
                timeout: .seconds(120)
            )
            _ = await runtime.submit(.stop)

            XCTAssertEqual(recorded.events.count, PhysicalVerificationHarness.maximumEvents)
            XCTAssertEqual(recorded.reconnectEventCount, 15)
            for (identifier, _) in keyTargets {
                let expectedPairs = identifier == "bottom-left" ? 2 : 1
                XCTAssertEqual(
                    recorded.events.filter { $0 == .init(controlID: identifier, kind: .keyDown) }.count,
                    expectedPairs
                )
                XCTAssertEqual(
                    recorded.events.filter { $0 == .init(controlID: identifier, kind: .keyUp) }.count,
                    expectedPairs
                )
            }
            XCTAssertEqual(
                recorded.events.filter { $0 == .init(controlID: "knob", kind: .dialPress) }.count,
                1
            )
            XCTAssertEqual(
                recorded.events.filter { $0 == .init(controlID: "knob", kind: .dialRotation(delta: -1)) }.count,
                1
            )
            XCTAssertEqual(
                recorded.events.filter { $0 == .init(controlID: "knob", kind: .dialRotation(delta: 1)) }.count,
                1
            )
            XCTAssertEqual(
                Array(recorded.events.suffix(5)),
                [
                    .init(controlID: "knob", kind: .dialRotation(delta: -1)),
                    .init(controlID: "knob", kind: .dialRotation(delta: 1)),
                    .init(controlID: "knob", kind: .dialPress),
                    .init(controlID: "bottom-left", kind: .keyDown),
                    .init(controlID: "bottom-left", kind: .keyUp),
                ]
            )
            let serviceCalls = await actionService.callCount
            XCTAssertEqual(serviceCalls, 0, "The injected service must not synthesize host actions.")
        } catch {
            _ = await runtime.submit(.stop)
            throw error
        }
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

    private func childIdentity(
        descriptors suppliedDescriptors: [KeyboardHIDElementDescriptor]? = nil,
        registryEntryID: UInt64? = 1,
        keyboardApplicationCollectionCount: Int? = 1,
        usagePairs suppliedUsagePairs: [KeyboardHIDUsagePair]? = [
            KeyboardHIDUsagePair(usagePage: KeyboardHIDTarget.genericDesktopUsagePage,
                                 usage: KeyboardHIDTarget.keyboardApplicationUsage),
        ]
    ) -> KeyboardHIDChildIdentity {
        let descriptors = suppliedDescriptors ?? variableDescriptors()
        return KeyboardHIDChildIdentity(
            descriptorFingerprint: KeyboardHIDDescriptorFingerprint(descriptors: descriptors),
            usagePairs: suppliedUsagePairs?.sorted(),
            keyboardApplicationCollectionCount: keyboardApplicationCollectionCount,
            registryEntryID: registryEntryID,
            elementPlan: try? KeyboardHIDElementPlan(validating: descriptors)
        )
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

    private func arrayDescriptor(
        cookie: UInt64,
        reportID: UInt32 = 3,
        reportCount: UInt32 = 6,
        minimumUsage: UInt32? = 0,
        maximumUsage: UInt32? = 0xe7
    ) -> KeyboardHIDElementDescriptor {
        KeyboardHIDElementDescriptor(
            cookie: cookie,
            usagePage: KeyboardHIDTarget.keyboardUsagePage,
            representation: .array(minimumUsage: minimumUsage, maximumUsage: maximumUsage),
            reportID: reportID,
            reportCount: reportCount,
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
    private let gatedAttempts: [Int: TestConnectionGate]
    private let errorsByAttempt: [Int: KeyboardHIDCaptureError]
    private(set) var connectionAttempts = 0

    init(
        connections: [TestKeyboardHIDConnection],
        gatedAttempts: [Int: TestConnectionGate] = [:],
        errorsByAttempt: [Int: KeyboardHIDCaptureError] = [:]
    ) {
        self.connections = connections
        self.gatedAttempts = gatedAttempts
        self.errorsByAttempt = errorsByAttempt
    }

    func connectToUniqueTarget() async throws -> any KeyboardHIDCaptureConnection {
        let attempt = connectionAttempts
        connectionAttempts += 1
        if let gate = gatedAttempts[attempt] { await gate.wait() }
        if let error = errorsByAttempt[attempt] { throw error }
        guard !connections.isEmpty else { throw KeyboardHIDCaptureError.targetUnavailable }
        let connection = connections.removeFirst()
        return connection
    }
}

private actor TestConnectionGate {
    private let entered = TestAsyncBarrier()
    private let allowed = TestAsyncBarrier()

    func wait() async {
        await entered.open()
        await allowed.wait()
    }

    func waitUntilEntered() async {
        await entered.wait()
    }

    func open() async {
        await allowed.open()
    }
}

private final class TestKeyboardHIDConnection: KeyboardHIDCaptureConnection, @unchecked Sendable {
    let elementPlan: KeyboardHIDElementPlan
    let events: AsyncStream<KeyboardHIDTransportEvent>

    private let continuation: AsyncStream<KeyboardHIDTransportEvent>.Continuation
    private let lock = NSLock()
    private let finishesStreamOnCancel: Bool
    private let cancelEntered: TestAsyncBarrier?
    private let cancelBarrier: TestAsyncBarrier?
    private var cancelled = false

    init(
        plan: KeyboardHIDElementPlan,
        finishesStreamOnCancel: Bool = true,
        cancelEntered: TestAsyncBarrier? = nil,
        cancelBarrier: TestAsyncBarrier? = nil
    ) {
        elementPlan = plan
        self.finishesStreamOnCancel = finishesStreamOnCancel
        self.cancelEntered = cancelEntered
        self.cancelBarrier = cancelBarrier
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
        await cancelEntered?.open()
        await cancelBarrier?.wait()
        if finishesStreamOnCancel { continuation.finish() }
    }
}

private actor TestAsyncBarrier {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool { opened }

    func open() {
        guard !opened else { return }
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
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

private actor BarrierInputConsumer: NormalizedInputConsumer {
    struct Snapshot: Equatable {
        let events: [NormalizedInputEvent]
        let lifecycle: [SessionLifecycleEvent]
    }

    private let keyUpEntered: TestAsyncBarrier
    private let allowKeyUp: TestAsyncBarrier
    private(set) var events: [NormalizedInputEvent] = []
    private(set) var lifecycle: [SessionLifecycleEvent] = []
    var eventCount: Int { events.count }

    init(keyUpEntered: TestAsyncBarrier, allowKeyUp: TestAsyncBarrier) {
        self.keyUpEntered = keyUpEntered
        self.allowKeyUp = allowKeyUp
    }

    func consume(_ event: NormalizedInputEvent) async {
        if event.payload == .keyUp {
            await keyUpEntered.open()
            await allowKeyUp.wait()
        }
        events.append(event)
    }

    func sessionLifecycleChanged(_ event: SessionLifecycleEvent) async {
        lifecycle.append(event)
    }

    func dialPressed(control: PhysicalControlID, generation: SessionGeneration) async -> ActionExecutionResult {
        ActionExecutionResult(outcome: .ignored)
    }

    func snapshot() -> Snapshot {
        Snapshot(events: events, lifecycle: lifecycle)
    }
}

private actor CaptureRuntimeActionService: HostActionServicing {
    private(set) var intents: [HostActionIntent] = []

    func perform(_ intent: HostActionIntent) async -> HostActionServiceResult {
        intents.append(intent)
        return .acceptedUnverified
    }
}

private enum PhysicalVerificationEventKind: Hashable, Sendable {
    case keyDown
    case keyUp
    case dialRotation(delta: Int)
    case dialPress
}

private struct PhysicalVerificationRecordedEvent: Hashable, Sendable {
    let controlID: String
    let kind: PhysicalVerificationEventKind
}

private struct PhysicalVerificationRecorderSnapshot: Sendable {
    let events: [PhysicalVerificationRecordedEvent]
    /// Number of normalized input summaries observed before the reconnect start.
    let reconnectEventCount: Int?
}

private actor PhysicalVerificationEventRecorder {
    private(set) var events: [PhysicalVerificationRecordedEvent] = []
    private var startCount = 0
    private var stoppingSeenSinceStart = false
    private var reconnectEventCount: Int?

    func record(_ event: PhysicalVerificationRecordedEvent) {
        guard events.count < PhysicalVerificationHarness.maximumEvents else { return }
        events.append(event)
    }

    func recordLifecycle(_ event: SessionLifecycleEvent) {
        switch event {
        case .started:
            if startCount > 0, stoppingSeenSinceStart, reconnectEventCount == nil {
                reconnectEventCount = events.count
            }
            startCount += 1
            stoppingSeenSinceStart = false
        case .stopping:
            stoppingSeenSinceStart = true
        case .stopped, .failed:
            stoppingSeenSinceStart = false
        }
    }

    func snapshot() -> PhysicalVerificationRecorderSnapshot {
        PhysicalVerificationRecorderSnapshot(events: events, reconnectEventCount: reconnectEventCount)
    }
}

private struct PhysicalVerificationRecordingProducer: InputEventProducing {
    let base: any InputEventProducing
    let recorder: PhysicalVerificationEventRecorder

    func start(
        generation: SessionGeneration,
        consumer: any NormalizedInputConsumer
    ) async throws -> any InputSessionHandle {
        try await base.start(
            generation: generation,
            consumer: PhysicalVerificationRecordingConsumer(
                recorder: recorder,
                downstream: consumer
            )
        )
    }
}

private actor PhysicalVerificationRecordingConsumer: NormalizedInputConsumer {
    private let recorder: PhysicalVerificationEventRecorder
    private let downstream: any NormalizedInputConsumer

    init(recorder: PhysicalVerificationEventRecorder, downstream: any NormalizedInputConsumer) {
        self.recorder = recorder
        self.downstream = downstream
    }

    func consume(_ event: NormalizedInputEvent) async {
        let kind: PhysicalVerificationEventKind
        switch event.payload {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .dialRotation(let delta): kind = .dialRotation(delta: delta)
        }
        await recorder.record(.init(controlID: event.control.rawValue, kind: kind))
        await downstream.consume(event)
    }

    func sessionLifecycleChanged(_ event: SessionLifecycleEvent) async {
        await recorder.recordLifecycle(event)
        await downstream.sessionLifecycleChanged(event)
    }

    func dialPressed(
        control: PhysicalControlID,
        generation: SessionGeneration
    ) async -> ActionExecutionResult {
        await recorder.record(.init(controlID: control.rawValue, kind: .dialPress))
        return await downstream.dialPressed(control: control, generation: generation)
    }
}

private struct PhysicalVerificationReplayProducer: InputEventProducing {
    let eventsBeforeReconnect: [NormalizedInputEvent]
    let eventsAfterReconnect: [NormalizedInputEvent]
    let eventsAfterLimit: [NormalizedInputEvent]
    let dialPress: PhysicalControlID

    func start(
        generation: SessionGeneration,
        consumer: any NormalizedInputConsumer
    ) async throws -> any InputSessionHandle {
        await consumer.sessionLifecycleChanged(.started(generation))
        for event in eventsBeforeReconnect { await consumer.consume(event) }
        _ = await consumer.dialPressed(control: dialPress, generation: generation)
        await consumer.sessionLifecycleChanged(.stopping(generation))
        await consumer.sessionLifecycleChanged(.started(generation))
        for event in eventsAfterReconnect { await consumer.consume(event) }
        for event in eventsAfterLimit { await consumer.consume(event) }
        return PhysicalVerificationReplaySession(generation: generation)
    }
}

private actor PhysicalVerificationReplaySession: InputSessionHandle {
    let generation: SessionGeneration

    init(generation: SessionGeneration) {
        self.generation = generation
    }

    func cancel() async {}
}

private actor PhysicalVerificationNoOpActionService: HostActionServicing {
    private(set) var callCount = 0

    func perform(_ intent: HostActionIntent) async -> HostActionServiceResult {
        callCount += 1
        return .unsupported(reason: "Physical verification service does not synthesize host input")
    }
}

private enum PhysicalVerificationHarness {
    static let environmentKey = "DIALDECK_RUN_PHYSICAL_HID_VERIFICATION"
    static let maximumEvents = 17

    static func isEnabled(environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }

    static func waitForReconnectSequence(
        from recorder: PhysicalVerificationEventRecorder,
        timeout: Duration
    ) async throws -> PhysicalVerificationRecorderSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let snapshot = await recorder.snapshot()
            if snapshot.events.count >= maximumEvents, snapshot.reconnectEventCount != nil {
                return snapshot
            }
            let now = clock.now
            guard now < deadline else { return snapshot }
            try await Task.sleep(for: min(.milliseconds(50), now.duration(to: deadline)))
        }
    }
}

private enum PhysicalVerificationHarnessError: Error, LocalizedError {
    case sessionDidNotStart(RuntimeStatus)

    var errorDescription: String? {
        switch self {
        case .sessionDidNotStart(let status):
            "Input session did not start; ActionRuntime status: \(String(describing: status))"
        }
    }
}

private struct CaptureRuntimeCapabilities: DeviceCapabilityProviding {
    func currentCapabilities() async -> DeviceCapabilities {
        DeviceCapabilities(detection: .detected, access: .available)
    }
}

private struct CaptureRuntimeProgrammer: DeviceProgramming {
    func program(_ request: ProgrammingRequest) async -> ProgrammingResult {
        ProgrammingResult(requestID: request.requestID, outcome: .sentUnverified)
    }
}

private struct CaptureRuntimeForeground: ForegroundApplicationProviding {
    func foregroundBundleIdentifier() async -> ApplicationBundleIdentifier? { nil }
}

private struct CaptureRuntimeMapping: PhysicalActionMappingProviding {
    let actions: [PhysicalControlID: ActionAssignmentTarget]

    init(_ actions: [PhysicalControlID: ActionAssignmentTarget]) {
        self.actions = actions
    }

    func actionTarget(for control: PhysicalControlID) async -> ActionAssignmentTarget? {
        actions[control]
    }
}

private final class CaptureRuntimeMemoryFiles: ConfigurationFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func exists(at url: URL) -> Bool {
        lock.withLock { values[url.path] != nil }
    }

    func read(from url: URL) throws -> Data {
        try lock.withLock {
            guard let value = values[url.path] else { throw ConfigurationStoreError.notFound }
            return value
        }
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        lock.withLock { values[url.path] = data }
    }
}
