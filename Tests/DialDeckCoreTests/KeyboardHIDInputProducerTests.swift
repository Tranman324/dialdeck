import XCTest
import IOKit
import IOKit.hid
import IOKit.hidsystem
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

    func testRawReportDescriptorSelectionRequiresOneExactMatch() throws {
        let descriptor = KeyboardHIDTarget.rawReportDescriptor
        let expectedDescriptorHex = """
        05 01 09 06 A1 01 85 01 05 07 19 E0 29 E7 15 00 25 01 75 01 95 08 81 02
        95 01 75 08 81 01 95 03 75 01 05 08 19 01 29 03 91 02 95 05 75 01 91 01
        95 06 75 08 26 FF 00 05 07 19 00 29 91 81 00 C0
        """
        let expectedDescriptor = try expectedDescriptorHex.split(whereSeparator: \.isWhitespace).map { token in
            guard let byte = UInt8(token, radix: 16) else {
                throw RawReportFixtureError.invalidByte(String(token))
            }
            return byte
        }
        XCTAssertEqual(descriptor, Data(expectedDescriptor))

        let unrelatedDescriptor = Data(descriptor.dropLast())

        XCTAssertEqual(
            try KeyboardHIDRawReportInterfaceSelection.uniqueMatchingIndex(
                in: [unrelatedDescriptor, descriptor]
            ),
            1
        )
        XCTAssertThrowsError(
            try KeyboardHIDRawReportInterfaceSelection.uniqueMatchingIndex(in: [unrelatedDescriptor])
        ) { error in
            XCTAssertEqual(error as? KeyboardHIDCaptureError, .interfaceMismatch)
        }
        XCTAssertThrowsError(
            try KeyboardHIDRawReportInterfaceSelection.uniqueMatchingIndex(in: [descriptor, descriptor])
        ) { error in
            XCTAssertEqual(error as? KeyboardHIDCaptureError, .ambiguousTarget)
        }
    }

    func testGoldenRawReportsDecodeNineControlsAndObservedGestures() throws {
        // Sanitized byte-for-byte payloads from .apm/evidence/hardware/hid-raw-reports-2026-10-06.md.
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "hid-raw-reports-2026-10-06",
                withExtension: "txt"
            )
        )
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
        let reports = try fixture.split(whereSeparator: \.isNewline).map { line -> [UInt8] in
            try line.split(separator: " ").map { token in
                guard let byte = UInt8(token, radix: 16) else {
                    throw RawReportFixtureError.invalidByte(String(token))
                }
                return byte
            }
        }
        XCTAssertEqual(reports.count, 20, "The fixture mirrors all 20 reports from the 2026-10-06 capture.")

        var rawDecoder = KeyboardHIDRawReportDecoder()
        var usageDecoder = KeyboardHIDUsageDecoder(
            generation: SessionGeneration(31),
            plan: .observedArrayControlPlan
        )
        let deliveries = reports.flatMap { report in
            rawDecoder.consume(reportID: KeyboardHIDRawReportDecoder.expectedReportID, bytes: report)
                .flatMap { rawValue in usageDecoder.consume(rawValue) }
        }

        let expected: [KeyboardHIDDelivery] = [
            .event(try keyEvent("top-left", down: true, generation: 31)),
            .event(try keyEvent("top-left", down: false, generation: 31)),
            .event(try keyEvent("top-right", down: true, generation: 31)),
            .event(try keyEvent("top-right", down: false, generation: 31)),
            .event(try keyEvent("middle-left", down: true, generation: 31)),
            .event(try keyEvent("middle-left", down: false, generation: 31)),
            .event(try keyEvent("middle-right", down: true, generation: 31)),
            .event(try keyEvent("middle-right", down: false, generation: 31)),
            .event(try keyEvent("bottom-left", down: true, generation: 31)),
            .event(try keyEvent("bottom-left", down: false, generation: 31)),
            .event(try keyEvent("bottom-right", down: true, generation: 31)),
            .event(try keyEvent("bottom-right", down: false, generation: 31)),
            .event(try rotationEvent(1, generation: 31)),
            .event(try rotationEvent(1, generation: 31)),
            .event(try rotationEvent(-1, generation: 31)),
            .dialPress(try XCTUnwrap(PhysicalControlID(rawValue: "knob", kind: .dial))),
        ]
        XCTAssertEqual(deliveries, expected)
    }

    func testRawReportDecoderKeepsOverlappingKeysUntilEachIsReleased() {
        var decoder = KeyboardHIDRawReportDecoder()

        XCTAssertEqual(
            decoder.consume(reportID: 1, bytes: rawReport(keys: [0x6b, 0x6c])),
            [rawValue(usage: 0x6b, pressed: true), rawValue(usage: 0x6c, pressed: true)]
        )
        XCTAssertEqual(
            decoder.consume(reportID: 1, bytes: rawReport(keys: [0x6c])),
            [rawValue(usage: 0x6b, pressed: false)]
        )
        XCTAssertEqual(
            decoder.consume(reportID: 1, bytes: rawReport(keys: [])),
            [rawValue(usage: 0x6c, pressed: false)]
        )
    }

    func testRawReportRolloverDoesNotChangeActiveState() {
        var decoder = KeyboardHIDRawReportDecoder()
        _ = decoder.consume(reportID: 1, bytes: rawReport(keys: [0x6b]))

        XCTAssertTrue(decoder.consume(reportID: 1, bytes: rawReport(keys: [1, 1, 1, 1, 1, 1])).isEmpty)
        XCTAssertEqual(decoder.activeUsages, [0x6b])
        XCTAssertEqual(
            decoder.consume(reportID: 1, bytes: rawReport(keys: [])),
            [rawValue(usage: 0x6b, pressed: false)]
        )
    }

    func testRawReportDecoderIgnoresWrongLengthAndReportIDsWithoutChangingState() {
        var decoder = KeyboardHIDRawReportDecoder()
        _ = decoder.consume(reportID: 1, bytes: rawReport(keys: [0x6b]))

        XCTAssertTrue(decoder.consume(reportID: 2, bytes: rawReport(keys: [])).isEmpty)
        XCTAssertTrue(decoder.consume(reportID: 1, bytes: [1, 0, 0, 0]).isEmpty)
        var wrongEmbeddedID = rawReport(keys: [])
        wrongEmbeddedID[0] = 2
        XCTAssertTrue(decoder.consume(reportID: 1, bytes: wrongEmbeddedID).isEmpty)
        XCTAssertEqual(decoder.activeUsages, [0x6b])
    }

    func testRawReportDecoderIgnoresZeroAndUnknownUsages() {
        var decoder = KeyboardHIDRawReportDecoder()

        XCTAssertEqual(
            decoder.consume(reportID: 1, bytes: rawReport(keys: [0, 0x6b, 0xfe, 0x6c])),
            [rawValue(usage: 0x6b, pressed: true), rawValue(usage: 0x6c, pressed: true)]
        )
        XCTAssertEqual(
            decoder.consume(reportID: 1, bytes: rawReport(keys: [0xfe])),
            [rawValue(usage: 0x6b, pressed: false), rawValue(usage: 0x6c, pressed: false)]
        )
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

    func testHIDDescriptorDumpIsDisabledUnlessSeparatelyEnabled() {
        XCTAssertFalse(HIDDescriptorDumpHarness.isEnabled(environment: [:]))
        XCTAssertFalse(HIDDescriptorDumpHarness.isEnabled(environment: [
            HIDDescriptorDumpHarness.environmentKey: "true",
        ]))
        XCTAssertTrue(HIDDescriptorDumpHarness.isEnabled(environment: [
            HIDDescriptorDumpHarness.environmentKey: "1",
        ]))
    }

    func testDescriptorDumpContinuesAfterElementCopyFailureAndReturnsIncompleteResult() {
        struct SyntheticElementCopyFailure: Error, LocalizedError {
            var errorDescription: String? { "synthetic element-list copy failure" }
        }

        var inspectedChildren: [Int] = []
        var failedChildren: [Int] = []
        let failures = HIDDescriptorDumpHarness.inspectChildren(
            [10, 20, 30],
            inspect: { index, _ in
                inspectedChildren.append(index)
                if index == 1 { throw SyntheticElementCopyFailure() }
            },
            onFailure: { index, _, _ in
                failedChildren.append(index)
            }
        )

        XCTAssertEqual(inspectedChildren, [0, 1, 2])
        XCTAssertEqual(failedChildren, [1])
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].hasPrefix("child 2: synthetic element-list copy failure"))
    }

    /// This is a dump-only diagnostic. The target-filtered manager is opened
    /// non-seizing for enumeration, which opens matching devices per IOKit;
    /// this path installs no callbacks and captures no input.
    func testOptInTargetKeyboardHIDDescriptorDump() throws {
        guard HIDDescriptorDumpHarness.isEnabled(environment: ProcessInfo.processInfo.environment) else {
            throw XCTSkip("Set DIALDECK_RUN_HID_DESCRIPTOR_DUMP=1 to dump target keyboard descriptors.")
        }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw XCTSkip("Input Monitoring is not already granted; no permission request was made.")
        }

        try HIDDescriptorDumpHarness.dumpTargetKeyboardChildren()
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

    /// One supervised production-path capture. It is opt-in, non-seizing, and
    /// the injected ActionRuntime service never synthesizes host input. Evidence
    /// contains normalized events and lifecycle/close diagnostics, not raw HID
    /// reports or text. macOS may still receive the keypad's ordinary F-key events.
    func testOptInPhysicalKeyboardHIDVerificationRoutesToNoOpRuntime() async throws {
        guard PhysicalVerificationHarness.isEnabled(environment: ProcessInfo.processInfo.environment) else {
            throw XCTSkip("Set DIALDECK_RUN_PHYSICAL_HID_VERIFICATION=1 for supervised physical verification.")
        }
        let reconnectConfirmationOnly = ProcessInfo.processInfo.environment[
            PhysicalVerificationHarness.confirmationOnlyEnvironmentKey
        ] == "1"
        let candidateSHA = ProcessInfo.processInfo.environment["DIALDECK_CANDIDATE_SHA"] ?? ""
        let candidateSHAIsValid = candidateSHA.count == 40 && candidateSHA.allSatisfy(\.isHexDigit)

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
        let recorder = PhysicalVerificationEventRecorder(
            maximumEvents: PhysicalVerificationHarness.maximumSupervisedEvents + 32
        )
        let diagnosticLog = PhysicalVerificationDiagnosticLog()
        let producer = PhysicalVerificationRecordingProducer(
            base: KeyboardHIDInputEventProducer(
                transport: MacOSKeyboardHIDCaptureTransport { diagnostic in
                    diagnosticLog.record(diagnostic)
                }
            ),
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

        let captureStartedAt = Date()
        var captureFailure: String?
        do {
            _ = await runtime.submit(.start)
            let startupStatus = await runtime.currentStatus()
            guard case .running = startupStatus else {
                throw PhysicalVerificationHarnessError.sessionDidNotStart(status: startupStatus)
            }
            try PhysicalVerificationEvidenceWriter.signalCaptureArmed()
            if reconnectConfirmationOnly {
                print("PHYSICAL_HID_CAPTURE_ARMED: unplug and reconnect the keypad once, then press and release bottom-left once.")
                let completedSequence = try await PhysicalVerificationHarness.waitForReconnectConfirmation(
                    from: recorder,
                    timeout: .seconds(90)
                )
                if completedSequence.events.count != 2 || completedSequence.reconnectEventCount != 0 {
                    captureFailure = "Timed out before the reconnect confirmation completed; observed \(completedSequence.events.count) normalized events and reconnect boundary \(completedSequence.reconnectEventCount.map(String.init) ?? "none")."
                }
            } else {
                print("PHYSICAL_HID_CAPTURE_ARMED: top-left, top-right, middle-left, middle-right, bottom-left, bottom-right; knob clockwise one click, counterclockwise one click, press; hold top-left and top-right together, then release top-left and top-right one at a time; unplug/replug once; press/release bottom-left once.")
                let completedSequence = try await PhysicalVerificationHarness.waitForSupervisedSequence(
                    from: recorder,
                    timeout: .seconds(240)
                )
                if completedSequence.events.count < PhysicalVerificationHarness.maximumSupervisedEvents
                    || completedSequence.reconnectEventCount != 19 {
                    captureFailure = "Timed out before the requested physical sequence completed; observed \(completedSequence.events.count) normalized events and reconnect boundary \(completedSequence.reconnectEventCount.map(String.init) ?? "none")."
                }
            }
        } catch {
            captureFailure = error.localizedDescription
        }

        _ = await runtime.submit(.stop)
        let captureFinishedAt = Date()
        let recorded = await recorder.snapshot()
        let diagnostics = diagnosticLog.snapshot()
        let runtimeStatusAfterStop = await runtime.currentStatus()
        let serviceCalls = await actionService.callCount
        let expectedInitial = Set(keyTargets.flatMap { identifier, _ in
            [
                PhysicalVerificationRecordedEvent(controlID: identifier, kind: .keyDown),
                PhysicalVerificationRecordedEvent(controlID: identifier, kind: .keyUp),
            ]
        } + [
            .init(controlID: "knob", kind: .dialRotation(delta: -1)),
            .init(controlID: "knob", kind: .dialRotation(delta: 1)),
            .init(controlID: "knob", kind: .dialPress),
        ])
        let overlapEvents = Array(recorded.events.dropFirst(15).prefix(4))
        let reconnectEvents = Array(recorded.events.dropFirst(19).prefix(2))
        let expectedOverlap: [PhysicalVerificationRecordedEvent] = [
            .init(controlID: "top-left", kind: .keyDown),
            .init(controlID: "top-right", kind: .keyDown),
            .init(controlID: "top-left", kind: .keyUp),
            .init(controlID: "top-right", kind: .keyUp),
        ]
        let expectedReconnect: [PhysicalVerificationRecordedEvent] = [
            .init(controlID: "bottom-left", kind: .keyDown),
            .init(controlID: "bottom-left", kind: .keyUp),
        ]
        let reconnectConfirmationEvents: [PhysicalVerificationRecordedEvent] = [
            .init(controlID: "bottom-left", kind: .keyDown),
            .init(controlID: "bottom-left", kind: .keyUp),
        ]
        let managerCloseResults = diagnostics.compactMap { entry -> Int32? in
            guard case .managerClosed(_, let result) = entry else { return nil }
            return result
        }
        let deviceCloseResults = diagnostics.compactMap { entry -> Int32? in
            guard case .deviceClosed(_, let result) = entry else { return nil }
            return result
        }
        let deviceCancelCount = diagnostics.filter {
            if case .deviceCancelIssued = $0 { return true }
            return false
        }.count
        let removedDeviceIDs = diagnostics.compactMap { entry -> UInt64? in
            guard case .deviceRemoved(let registryEntryID) = entry else { return nil }
            return registryEntryID
        }
        let skippedRemovedDeviceCloseIDs = diagnostics.compactMap { entry -> UInt64? in
            guard case .deviceCloseSkippedRemoved(let registryEntryID) = entry else { return nil }
            return registryEntryID
        }
        let selectedIDs = diagnostics.compactMap { entry -> UInt64? in
            guard case .selectedChild(let registryEntryID) = entry else { return nil }
            return registryEntryID
        }
        let lifecycleGenerations = recorded.lifecycleEvents.map { event -> UInt64 in
            switch event {
            case .started(let generation), .stopping(let generation), .stopped(let generation):
                generation.rawValue
            case .failed(let generation, _):
                generation.rawValue
            }
        }
        let allOneGeneration = Set(recorded.eventGenerations + lifecycleGenerations).count == 1
            && recorded.eventGenerations.count == recorded.events.count
            && !lifecycleGenerations.isEmpty
        let closeResultsAreSuccess = !managerCloseResults.isEmpty
            && !deviceCloseResults.isEmpty
            && managerCloseResults.allSatisfy { $0 == 0 }
            && deviceCloseResults.allSatisfy { $0 == 0 }
            && deviceCancelCount == deviceCloseResults.count + skippedRemovedDeviceCloseIDs.count
            && removedDeviceIDs == skippedRemovedDeviceCloseIDs
            && removedDeviceIDs.count == 1
        let sequencePassed: Bool
        if reconnectConfirmationOnly {
            sequencePassed = recorded.events == reconnectConfirmationEvents
                && recorded.reconnectEventCount == 0
        } else {
            sequencePassed = recorded.events.count == PhysicalVerificationHarness.maximumSupervisedEvents
                && recorded.reconnectEventCount == 19
                && Set(recorded.events.prefix(15)) == expectedInitial
                && recorded.events.prefix(15).count == expectedInitial.count
                && overlapEvents == expectedOverlap
                && reconnectEvents == expectedReconnect
        }
        let passed = captureFailure == nil
            && sequencePassed
            && candidateSHAIsValid
            && allOneGeneration
            && selectedIDs.count >= 4
            && Set(selectedIDs.prefix(2)).count == 1
            && Set(selectedIDs.suffix(2)).count == 1
            && closeResultsAreSuccess
            && serviceCalls == 0

        try PhysicalVerificationEvidenceWriter.write(
            events: recorded.events,
            eventGenerations: recorded.eventGenerations,
            lifecycleEvents: recorded.lifecycleEvents,
            reconnectEventCount: recorded.reconnectEventCount,
            diagnostics: diagnostics,
            captureStartedAt: captureStartedAt,
            captureFinishedAt: captureFinishedAt,
            runtimeStatusAfterStop: runtimeStatusAfterStop,
            actionServiceCallCount: serviceCalls,
            captureFailure: captureFailure,
            passed: passed,
            captureScenario: reconnectConfirmationOnly ? "short committed-SHA reconnect confirmation" : "full supervised sequence"
        )

        XCTAssertNil(captureFailure)
        XCTAssertTrue(sequencePassed, "The recorded event sequence must match the selected supervised capture mode.")
        XCTAssertTrue(allOneGeneration, "All normalized input and reconnect lifecycle events must keep one generation.")
        XCTAssertGreaterThanOrEqual(selectedIDs.count, 4, "Initial and reconnect selections must be recorded.")
        XCTAssertEqual(Set(selectedIDs.prefix(2)).count, 1, "Initial double-selection must agree.")
        XCTAssertEqual(Set(selectedIDs.suffix(2)).count, 1, "Reconnect double-selection must agree.")
        XCTAssertTrue(closeResultsAreSuccess, "Every manager/device close must return 0x00000000 after device cancel.")
        XCTAssertEqual(serviceCalls, 0, "The injected service must not synthesize host actions.")
        XCTAssertTrue(passed, "The recorded evidence must satisfy every capture acceptance condition.")
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

    private func rawReport(keys: [UInt8]) -> [UInt8] {
        [1, 0, 0] + Array((keys + Array(repeating: 0, count: 6)).prefix(6))
    }

    private func rawValue(usage: UInt32, pressed: Bool) -> KeyboardHIDRawValue {
        KeyboardHIDRawValue(
            cookie: UInt64(usage),
            usagePage: KeyboardHIDTarget.keyboardUsagePage,
            elementUsage: usage,
            isArray: false,
            integerValue: pressed ? 1 : 0
        )
    }

    private enum RawReportFixtureError: Error {
        case invalidByte(String)
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

    func cancel() async -> KeyboardHIDCaptureError? {
        lock.withLock { cancelled = true }
        await cancelEntered?.open()
        await cancelBarrier?.wait()
        if finishesStreamOnCancel { continuation.finish() }
        return nil
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
    let eventGenerations: [UInt64]
    let lifecycleEvents: [SessionLifecycleEvent]
    /// Number of normalized input summaries observed before the reconnect start.
    let reconnectEventCount: Int?
}

private actor PhysicalVerificationEventRecorder {
    private let maximumEvents: Int
    private(set) var events: [PhysicalVerificationRecordedEvent] = []
    private(set) var eventGenerations: [UInt64] = []
    private(set) var lifecycleEvents: [SessionLifecycleEvent] = []
    private var startCount = 0
    private var stoppingSeenSinceStart = false
    private var reconnectEventCount: Int?

    init(maximumEvents: Int = PhysicalVerificationHarness.maximumEvents) {
        self.maximumEvents = maximumEvents
    }

    func record(_ event: PhysicalVerificationRecordedEvent, generation: UInt64) {
        guard events.count < maximumEvents else { return }
        events.append(event)
        eventGenerations.append(generation)
    }

    func recordLifecycle(_ event: SessionLifecycleEvent) {
        lifecycleEvents.append(event)
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
        PhysicalVerificationRecorderSnapshot(
            events: events,
            eventGenerations: eventGenerations,
            lifecycleEvents: lifecycleEvents,
            reconnectEventCount: reconnectEventCount
        )
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
        await recorder.record(
            .init(controlID: event.control.rawValue, kind: kind),
            generation: event.generation.rawValue
        )
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
        await recorder.record(
            .init(controlID: control.rawValue, kind: .dialPress),
            generation: generation.rawValue
        )
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
    static let confirmationOnlyEnvironmentKey = "DIALDECK_PHYSICAL_HID_CONFIRMATION_ONLY"
    static let maximumEvents = 17
    static let maximumSupervisedEvents = 21

    static func isEnabled(environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }

    static func waitForSupervisedSequence(
        from recorder: PhysicalVerificationEventRecorder,
        timeout: Duration
    ) async throws -> PhysicalVerificationRecorderSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let snapshot = await recorder.snapshot()
            if snapshot.events.count >= maximumSupervisedEvents,
               snapshot.reconnectEventCount == 19 {
                return snapshot
            }
            let now = clock.now
            guard now < deadline else { return snapshot }
            try await Task.sleep(for: min(.milliseconds(50), now.duration(to: deadline)))
        }
    }

    static func waitForReconnectConfirmation(
        from recorder: PhysicalVerificationEventRecorder,
        timeout: Duration
    ) async throws -> PhysicalVerificationRecorderSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let snapshot = await recorder.snapshot()
            if let reconnectEventCount = snapshot.reconnectEventCount,
               snapshot.events.count >= reconnectEventCount + 2 {
                return snapshot
            }
            let now = clock.now
            guard now < deadline else { return snapshot }
            try await Task.sleep(for: min(.milliseconds(50), now.duration(to: deadline)))
        }
    }
}

private final class PhysicalVerificationDiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [KeyboardHIDCaptureDiagnostic] = []

    func record(_ diagnostic: KeyboardHIDCaptureDiagnostic) {
        lock.lock()
        entries.append(diagnostic)
        lock.unlock()
    }

    func snapshot() -> [KeyboardHIDCaptureDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private enum PhysicalVerificationEvidenceWriter {
    static let pathEnvironmentKey = "DIALDECK_PHYSICAL_HID_EVIDENCE_PATH"
    static let readyPathEnvironmentKey = "DIALDECK_PHYSICAL_HID_READY_PATH"

    static func signalCaptureArmed() throws {
        guard let path = ProcessInfo.processInfo.environment[readyPathEnvironmentKey] else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("capture armed\n".utf8).write(to: url, options: .atomic)
    }

    static func write(
        events: [PhysicalVerificationRecordedEvent],
        eventGenerations: [UInt64],
        lifecycleEvents: [SessionLifecycleEvent],
        reconnectEventCount: Int?,
        diagnostics: [KeyboardHIDCaptureDiagnostic],
        captureStartedAt: Date,
        captureFinishedAt: Date,
        runtimeStatusAfterStop: RuntimeStatus,
        actionServiceCallCount: Int,
        captureFailure: String?,
        passed: Bool,
        captureScenario: String
    ) throws {
        let environment = ProcessInfo.processInfo.environment
        let output = environment[pathEnvironmentKey]
            ?? ".apm/evidence/hardware/hid-production-capture-2026-10-07.md"
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let url = URL(fileURLWithPath: output, relativeTo: currentDirectory).standardizedFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let selectedIDs = diagnostics.compactMap { entry -> UInt64? in
            guard case .selectedChild(let registryEntryID) = entry else { return nil }
            return registryEntryID
        }
        let managerCloseCount = diagnostics.filter {
            if case .managerClosed = $0 { return true }
            return false
        }.count
        let deviceCloseCount = diagnostics.filter {
            if case .deviceClosed = $0 { return true }
            return false
        }.count
        let deviceCloseSkippedCount = diagnostics.filter {
            if case .deviceCloseSkippedRemoved = $0 { return true }
            return false
        }.count
        let candidateSHA = environment["DIALDECK_CANDIDATE_SHA"] ?? "not supplied"
        var lines = [
            "# Supervised production HID capture",
            "",
            "- Candidate source revision: `\(candidateSHA)`",
            "- Capture scenario: \(captureScenario)",
            "- Diagnostics are collected by the opt-in test harness through an injected observer; the production default has no diagnostic output.",
            "- Result: **\(passed ? "PASS" : "FAIL")**",
            "- Started: `\(timestamp(captureStartedAt))`",
            "- Finished: `\(timestamp(captureFinishedAt))`",
            "- Selected registryEntryID values: `\(selectedIDs.map(String.init).joined(separator: ", "))`",
            "- Reconnect boundary: `\(reconnectEventCount.map(String.init) ?? "not observed")` normalized events before the reconnect start",
            "- Normalized event count: `\(events.count)`",
            "- Action service calls: `\(actionServiceCallCount)` (expected 0)",
            "- Runtime status after stop: `\(String(describing: runtimeStatusAfterStop))`",
            "- Close calls recorded: `\(managerCloseCount)` manager, `\(deviceCloseCount)` device",
            "- Removed-device close skips: `\(deviceCloseSkippedCount)` (service had already been removed)",
            "",
            "## Normalized events",
            "",
        ]
        for (index, event) in events.enumerated() {
            let generation = index < eventGenerations.count ? String(eventGenerations[index]) : "missing"
            lines.append("\(index + 1). `\(event.controlID)` — `\(eventKind(event.kind))` — generation `\(generation)`")
        }
        lines.append(contentsOf: ["", "## Session lifecycle", ""])
        for (index, event) in lifecycleEvents.enumerated() {
            lines.append("\(index + 1). `\(lifecycleDescription(event))`")
        }
        lines.append(contentsOf: ["", "## HID manager and device teardown", ""])
        for (index, diagnostic) in diagnostics.enumerated() {
            lines.append("\(index + 1). `\(diagnosticDescription(diagnostic))`")
        }
        if let captureFailure {
            lines.append(contentsOf: ["", "## Capture failure", "", captureFailure])
        }
        lines.append("")

        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        print("PHYSICAL_HID_EVIDENCE_WRITTEN=\(url.path)")
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func eventKind(_ kind: PhysicalVerificationEventKind) -> String {
        switch kind {
        case .keyDown: "keyDown"
        case .keyUp: "keyUp"
        case .dialRotation(let delta): "dialRotation(\(delta))"
        case .dialPress: "dialPress"
        }
    }

    private static func lifecycleDescription(_ event: SessionLifecycleEvent) -> String {
        switch event {
        case .started(let generation): "started generation \(generation.rawValue)"
        case .stopping(let generation): "stopping generation \(generation.rawValue)"
        case .stopped(let generation): "stopped generation \(generation.rawValue)"
        case .failed(let generation, let reason): "failed generation \(generation.rawValue): \(reason)"
        }
    }

    private static func diagnosticDescription(_ diagnostic: KeyboardHIDCaptureDiagnostic) -> String {
        switch diagnostic {
        case .selectedChild(let registryEntryID):
            return "selected registryEntryID=\(registryEntryID)"
        case .managerClosed(let selectedRegistryEntryID, let result):
            let target = selectedRegistryEntryID.map(String.init) ?? "unavailable"
            return "IOHIDManagerClose selectedRegistryEntryID=\(target) IOReturn=\(formatIOReturn(result))"
        case .deviceRemoved(let registryEntryID):
            return "device removal callback registryEntryID=\(registryEntryID)"
        case .deviceCancelIssued(let registryEntryID):
            return "IOHIDDeviceCancel registryEntryID=\(registryEntryID)"
        case .deviceClosed(let registryEntryID, let result):
            return "IOHIDDeviceClose registryEntryID=\(registryEntryID) IOReturn=\(formatIOReturn(result))"
        case .deviceCloseSkippedRemoved(let registryEntryID):
            return "IOHIDDeviceClose skipped registryEntryID=\(registryEntryID): removed service"
        }
    }

    private static func formatIOReturn(_ result: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: result))
    }
}

private enum PhysicalVerificationHarnessError: Error, LocalizedError {
    case sessionDidNotStart(status: RuntimeStatus)

    var errorDescription: String? {
        switch self {
        case .sessionDidNotStart(let status):
            "Input session did not start; ActionRuntime status: \(String(describing: status))"
        }
    }
}

private enum HIDDescriptorDumpHarness {
    static let environmentKey = "DIALDECK_RUN_HID_DESCRIPTOR_DUMP"

    private enum DumpError: Error, LocalizedError {
        case permissionNotGranted
        case managerOpenFailed(IOReturn)
        case managerCloseFailed(IOReturn)
        case operationAndCloseFailed(operation: String, closeResult: IOReturn)
        case noMatchingKeyboardChildren
        case elementListUnavailable
        case elementListFailures([String])

        var errorDescription: String? {
            switch self {
            case .permissionNotGranted:
                "Input Monitoring access is not already granted; no permission request was made"
            case .managerOpenFailed(let result):
                "Target-only HID manager open failed with IOReturn \(format(result))"
            case .managerCloseFailed(let result):
                "Target-only HID manager close failed with IOReturn \(format(result))"
            case .operationAndCloseFailed(let operation, let closeResult):
                "Descriptor dump failed (\(operation)); manager close also failed with IOReturn \(format(closeResult))"
            case .noMatchingKeyboardChildren:
                "No target USB keyboard children matched VID 0x1189, PID 0x8890, and the keyboard application usage"
            case .elementListUnavailable:
                "IOHIDDeviceCopyMatchingElements returned no complete element list for a matching keyboard child"
            case .elementListFailures(let failures):
                "Descriptor dump is incomplete because element copying failed for matching child(ren): \(failures.joined(separator: "; "))"
            }
        }

        private func format(_ result: IOReturn) -> String {
            String(format: "0x%08X", UInt32(bitPattern: result))
        }
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }

    static func dumpTargetKeyboardChildren() throws {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw DumpError.permissionNotGranted
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: NSNumber(value: KeyboardHIDTarget.vendorID),
            kIOHIDProductIDKey as String: NSNumber(value: KeyboardHIDTarget.productID),
            kIOHIDTransportKey as String: kIOHIDTransportUSBValue,
            kIOHIDDeviceUsagePageKey as String: NSNumber(value: KeyboardHIDTarget.genericDesktopUsagePage),
            kIOHIDDeviceUsageKey as String: NSNumber(value: KeyboardHIDTarget.keyboardApplicationUsage),
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw DumpError.managerOpenFailed(openResult)
        }
        print("Target-only IOHIDManagerOpen returned IOReturn 0x00000000 with kIOHIDOptionsTypeNone; per the macOS SDK, this opens matching current and future target devices. No seize option, callbacks, event capture, or output/device writes are used.")

        do {
            try inspectMatchingChildren(manager)
        } catch {
            let operation = String(describing: error)
            let closeResult = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            guard closeResult == kIOReturnSuccess else {
                throw DumpError.operationAndCloseFailed(operation: operation, closeResult: closeResult)
            }
            print("Target-only HID manager close after dump error succeeded with IOReturn 0x00000000.")
            throw error
        }

        let closeResult = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard closeResult == kIOReturnSuccess else {
            throw DumpError.managerCloseFailed(closeResult)
        }
        print("Target-only HID manager close succeeded with IOReturn 0x00000000.")
    }

    private static func inspectMatchingChildren(_ manager: IOHIDManager) throws {
        guard let deviceSet = IOHIDManagerCopyDevices(manager) else {
            throw DumpError.noMatchingKeyboardChildren
        }
        let devices = (deviceSet as NSSet).allObjects as! [IOHIDDevice]
        let targetDevices = devices.filter(isTargetKeyboard)
        guard !targetDevices.isEmpty else {
            throw DumpError.noMatchingKeyboardChildren
        }

        print("HID descriptor dump: \(targetDevices.count) matching target keyboard child(ren); manager open is non-seizing and has opened matching target devices; no callbacks were registered.")
        var identities: [KeyboardHIDChildIdentity] = []
        let elementListFailures = inspectChildren(
            targetDevices,
            inspect: { index, device in
                print("HID descriptor child \(index + 1)/\(targetDevices.count): target USB keyboard 0x1189:0x8890")
                print("  registryEntryID=\(registryID(for: device).map { String($0) } ?? "unavailable") (source=IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device)))")
                print("  ReportDescriptor=\(reportDescriptorHex(for: device)) (source=IOHIDDeviceGetProperty(kIOHIDReportDescriptorKey))")
                let elements = try copyAllElements(from: device)
                for (elementIndex, element) in elements.enumerated() {
                    print("  element[\(elementIndex)]: \(describe(element))")
                }
                identities.append(describeEligibility(of: device, elements: elements, childIndex: index))
            },
            onFailure: { index, device, error in
                print("HID descriptor child \(index + 1)/\(targetDevices.count): target USB keyboard 0x1189:0x8890")
                let failure = "child \(index + 1): \(error.localizedDescription) [\(String(describing: error))]"
                print("  element list: incomplete; exact error: \(failure)")
                identities.append(ineligibleIdentity(for: device))
            }
        )

        guard elementListFailures.isEmpty else {
            print("HID descriptor selection not evaluated because at least one matching child has no complete element list.")
            throw DumpError.elementListFailures(elementListFailures)
        }

        do {
            let selectedIndex = try KeyboardHIDChildSelection.uniqueEligibleIndex(in: identities)
            print("HID descriptor selection: exactly one eligible keyboard child at index \(selectedIndex + 1); this is an eligibility result after non-seizing manager enumeration.")
        } catch {
            print("HID descriptor selection: no unique eligible keyboard child; exact reason: \(error.localizedDescription)")
        }
    }

    static func inspectChildren<Child>(
        _ children: [Child],
        inspect: (Int, Child) throws -> Void,
        onFailure: (Int, Child, Error) -> Void
    ) -> [String] {
        var failures: [String] = []
        for (index, child) in children.enumerated() {
            do {
                try inspect(index, child)
            } catch {
                failures.append("child \(index + 1): \(error.localizedDescription) [\(String(describing: error))]")
                onFailure(index, child, error)
            }
        }
        return failures
    }

    private static func copyAllElements(from device: IOHIDDevice) throws -> [IOHIDElement] {
        guard let rawElements = IOHIDDeviceCopyMatchingElements(
            device,
            nil,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) else {
            throw DumpError.elementListUnavailable
        }
        return rawElements as! [IOHIDElement]
    }

    private static func describeEligibility(
        of device: IOHIDDevice,
        elements: [IOHIDElement],
        childIndex: Int
    ) -> KeyboardHIDChildIdentity {
        let collectionCount = Set(elements.filter(isKeyboardApplicationCollection).map {
            UInt32(IOHIDElementGetCookie($0))
        }).count
        let descriptors = elements.compactMap { element -> KeyboardHIDElementDescriptor? in
            guard isInputElement(element), belongsToUniqueKeyboardCollection(element),
                  IOHIDElementGetUsagePage(element) == KeyboardHIDTarget.keyboardUsagePage else {
                return nil
            }
            let representation: KeyboardHIDElementDescriptor.Representation
            if IOHIDElementIsArray(element) {
                representation = .array(
                    minimumUsage: propertyInteger(element, key: kIOHIDElementUsageMinKey),
                    maximumUsage: propertyInteger(element, key: kIOHIDElementUsageMaxKey)
                )
            } else {
                representation = .variable(usage: IOHIDElementGetUsage(element))
            }
            return KeyboardHIDElementDescriptor(
                cookie: UInt64(IOHIDElementGetCookie(element)),
                usagePage: IOHIDElementGetUsagePage(element),
                representation: representation,
                reportID: IOHIDElementGetReportID(element),
                reportCount: IOHIDElementGetReportCount(element),
                logicalMinimum: Int64(IOHIDElementGetLogicalMin(element)),
                logicalMaximum: Int64(IOHIDElementGetLogicalMax(element))
            )
        }

        let plan: KeyboardHIDElementPlan?
        do {
            plan = try KeyboardHIDElementPlan(validating: descriptors)
            print("  validator: eligible element plan (\(descriptors.count) target-collection keyboard-page input element(s))")
        } catch {
            plan = nil
            print("  validator: ineligible; exact error: \(validatorErrorDescription(error))")
        }

        let pairs = usagePairs(for: device)
        let registryIdentifier = registryID(for: device)
        let fingerprint = KeyboardHIDDescriptorFingerprint(descriptors: descriptors)
        var reasons: [String] = []
        if fingerprint.canonicalElements.isEmpty {
            reasons.append("keyboard-page input descriptor fingerprint is empty")
        }
        if collectionCount != 1 {
            reasons.append("keyboard Application collection count is \(collectionCount), expected exactly 1")
        }
        if let pairs {
            let keyboardPairCount = pairs.filter {
                $0.usagePage == KeyboardHIDTarget.genericDesktopUsagePage
                    && $0.usage == KeyboardHIDTarget.keyboardApplicationUsage
            }.count
            if keyboardPairCount != 1 {
                reasons.append("keyboard usage-pair count is \(keyboardPairCount), expected exactly 1")
            }
        } else {
            reasons.append("device usage-pair property is unavailable or malformed")
        }
        if registryIdentifier == nil || registryIdentifier == 0 {
            reasons.append("nonzero registry entry ID is unavailable")
        }
        if plan == nil, !reasons.contains(where: { $0.hasPrefix("keyboard-page input descriptor") }) {
            // Keep the validator's exact localized error as the ineligibility reason.
            reasons.append("element plan rejected by validator; see exact validator error above")
        }
        if reasons.isEmpty {
            print("  child eligibility: eligible (candidate \(childIndex + 1))")
        } else {
            print("  child eligibility: ineligible; reason(s): \(reasons.joined(separator: "; "))")
        }

        return KeyboardHIDChildIdentity(
            descriptorFingerprint: fingerprint,
            usagePairs: pairs,
            keyboardApplicationCollectionCount: collectionCount,
            registryEntryID: registryIdentifier,
            elementPlan: plan
        )
    }

    private static func ineligibleIdentity(for device: IOHIDDevice) -> KeyboardHIDChildIdentity {
        let reason = KeyboardHIDCaptureError.interfaceMismatch.localizedDescription
        do {
            _ = try KeyboardHIDElementPlan(validating: [])
            print("  validator fallback: unexpectedly accepted an empty descriptor list")
        } catch {
            print("  validator: ineligible; exact error: \(validatorErrorDescription(error)) (element-list retrieval failed: \(reason))")
        }
        return KeyboardHIDChildIdentity(
            descriptorFingerprint: KeyboardHIDDescriptorFingerprint(descriptors: []),
            usagePairs: usagePairs(for: device),
            keyboardApplicationCollectionCount: nil,
            registryEntryID: registryID(for: device),
            elementPlan: nil
        )
    }

    private static func describe(_ element: IOHIDElement) -> String {
        let type = IOHIDElementGetType(element)
        let collectionContext = collectionAncestors(of: element).map { collection in
            "cookie=\(UInt32(IOHIDElementGetCookie(collection)))/\(collectionTypeName(IOHIDElementGetCollectionType(collection))):page=\(hex(IOHIDElementGetUsagePage(collection))):usage=\(hex(IOHIDElementGetUsage(collection)))"
        }
        let ownCollection: [String]
        if type == kIOHIDElementTypeCollection {
            ownCollection = ["self=cookie=\(UInt32(IOHIDElementGetCookie(element)))/\(collectionTypeName(IOHIDElementGetCollectionType(element))):page=\(hex(IOHIDElementGetUsagePage(element))):usage=\(hex(IOHIDElementGetUsage(element)))"]
        } else {
            ownCollection = []
        }
        let context = (collectionContext + ownCollection).joined(separator: " > ")
        return "cookie=\(UInt32(IOHIDElementGetCookie(element))) type=\(elementTypeName(type)) usagePage=\(hex(IOHIDElementGetUsagePage(element))) usage=\(hex(IOHIDElementGetUsage(element))) usageMin=\(usageBoundDescription(element, key: kIOHIDElementUsageMinKey, keyName: "kIOHIDElementUsageMinKey")) usageMax=\(usageBoundDescription(element, key: kIOHIDElementUsageMaxKey, keyName: "kIOHIDElementUsageMaxKey")) logicalMin=\(IOHIDElementGetLogicalMin(element)) [source=IOHIDElementGetLogicalMin] logicalMax=\(IOHIDElementGetLogicalMax(element)) [source=IOHIDElementGetLogicalMax] isArray=\(IOHIDElementIsArray(element)) reportID=\(IOHIDElementGetReportID(element)) reportSize=\(IOHIDElementGetReportSize(element)) reportCount=\(IOHIDElementGetReportCount(element)) collectionContext=\(context.isEmpty ? "none" : context)"
    }

    private static func usageBoundDescription(
        _ element: IOHIDElement,
        key: String,
        keyName: String
    ) -> String {
        guard let value = propertyInteger(element, key: key) else {
            return "unavailable [source=IOHIDElementGetProperty(\(keyName)); property absent or non-numeric]"
        }
        return "\(hex(value)) [source=IOHIDElementGetProperty(\(keyName))]"
    }

    private static func reportDescriptorHex(for device: IOHIDDevice) -> String {
        guard let property = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) else {
            return "unavailable (property absent)"
        }
        guard let bytes = property as? Data else {
            return "unavailable (unexpected property type \(String(reflecting: type(of: property))))"
        }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func isTargetKeyboard(_ device: IOHIDDevice) -> Bool {
        propertyInteger(device, key: kIOHIDVendorIDKey) == KeyboardHIDTarget.vendorID
            && propertyInteger(device, key: kIOHIDProductIDKey) == KeyboardHIDTarget.productID
            && propertyString(device, key: kIOHIDTransportKey) == kIOHIDTransportUSBValue
            && IOHIDDeviceConformsTo(
                device,
                KeyboardHIDTarget.genericDesktopUsagePage,
                KeyboardHIDTarget.keyboardApplicationUsage
            )
    }

    private static func isKeyboardApplicationCollection(_ element: IOHIDElement) -> Bool {
        IOHIDElementGetType(element) == kIOHIDElementTypeCollection
            && IOHIDElementGetCollectionType(element) == kIOHIDElementCollectionTypeApplication
            && IOHIDElementGetUsagePage(element) == KeyboardHIDTarget.genericDesktopUsagePage
            && IOHIDElementGetUsage(element) == KeyboardHIDTarget.keyboardApplicationUsage
    }

    private static func belongsToUniqueKeyboardCollection(_ element: IOHIDElement) -> Bool {
        var current = IOHIDElementGetParent(element)
        var matchingApplications = 0
        while let parent = current {
            if isKeyboardApplicationCollection(parent) {
                matchingApplications += 1
            }
            current = IOHIDElementGetParent(parent)
        }
        return matchingApplications == 1
    }

    private static func isInputElement(_ element: IOHIDElement) -> Bool {
        let type = IOHIDElementGetType(element)
        return type == kIOHIDElementTypeInput_Misc
            || type == kIOHIDElementTypeInput_Button
            || type == kIOHIDElementTypeInput_ScanCodes
            || type == kIOHIDElementTypeInput_NULL
    }

    private static func collectionAncestors(of element: IOHIDElement) -> [IOHIDElement] {
        var collections: [IOHIDElement] = []
        var current = IOHIDElementGetParent(element)
        while let parent = current {
            if IOHIDElementGetType(parent) == kIOHIDElementTypeCollection {
                collections.append(parent)
            }
            current = IOHIDElementGetParent(parent)
        }
        return collections.reversed()
    }

    private static func elementTypeName(_ type: IOHIDElementType) -> String {
        switch type {
        case kIOHIDElementTypeInput_Misc: "input-misc"
        case kIOHIDElementTypeInput_Button: "input-button"
        case kIOHIDElementTypeInput_Axis: "input-axis"
        case kIOHIDElementTypeInput_ScanCodes: "input-scan-codes"
        case kIOHIDElementTypeInput_NULL: "input-null"
        case kIOHIDElementTypeOutput: "output"
        case kIOHIDElementTypeFeature: "feature"
        case kIOHIDElementTypeCollection: "collection"
        default: "other-\(String(describing: type))"
        }
    }

    private static func collectionTypeName(_ type: IOHIDElementCollectionType) -> String {
        switch type {
        case kIOHIDElementCollectionTypePhysical: "physical"
        case kIOHIDElementCollectionTypeApplication: "application"
        case kIOHIDElementCollectionTypeLogical: "logical"
        case kIOHIDElementCollectionTypeReport: "report"
        case kIOHIDElementCollectionTypeNamedArray: "named-array"
        case kIOHIDElementCollectionTypeUsageSwitch: "usage-switch"
        case kIOHIDElementCollectionTypeUsageModifier: "usage-modifier"
        default: "other-\(String(describing: type))"
        }
    }

    private static func usagePairs(for device: IOHIDDevice) -> [KeyboardHIDUsagePair]? {
        guard let rawPairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? NSArray else {
            return nil
        }
        var pairs: [KeyboardHIDUsagePair] = []
        for value in rawPairs {
            guard let pair = value as? NSDictionary,
                  let page = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.uint32Value,
                  let usage = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.uint32Value else {
                return nil
            }
            pairs.append(KeyboardHIDUsagePair(usagePage: page, usage: usage))
        }
        return pairs.sorted()
    }

    private static func registryID(for device: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else { return nil }
        return identifier
    }

    private static func propertyInteger(_ element: IOHIDElement, key: String) -> UInt32? {
        guard let value = IOHIDElementGetProperty(element, key as CFString) as? NSNumber else { return nil }
        return value.uint32Value
    }

    private static func propertyInteger(_ device: IOHIDDevice, key: String) -> UInt32? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber else { return nil }
        return value.uint32Value
    }

    private static func propertyString(_ device: IOHIDDevice, key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func hex(_ value: UInt32) -> String {
        String(format: "0x%04X", value)
    }

    private static func validatorErrorDescription(_ error: Error) -> String {
        let caseName: String
        switch error as? KeyboardHIDCaptureError {
        case .permissionUnavailable: caseName = "KeyboardHIDCaptureError.permissionUnavailable"
        case .targetUnavailable: caseName = "KeyboardHIDCaptureError.targetUnavailable"
        case .ambiguousTarget: caseName = "KeyboardHIDCaptureError.ambiguousTarget"
        case .ambiguousInterface: caseName = "KeyboardHIDCaptureError.ambiguousInterface"
        case .interfaceMismatch: caseName = "KeyboardHIDCaptureError.interfaceMismatch"
        case .openFailed: caseName = "KeyboardHIDCaptureError.openFailed"
        case .managerCloseFailed: caseName = "KeyboardHIDCaptureError.managerCloseFailed"
        case .deviceCloseFailed: caseName = "KeyboardHIDCaptureError.deviceCloseFailed"
        case nil: caseName = String(reflecting: type(of: error))
        }
        return "\(caseName): \(error.localizedDescription)"
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
