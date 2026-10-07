import Foundation
import XCTest
@testable import DialDeckCore

final class ActionRuntimeTests: XCTestCase {
    func testCommandCAndVUseBalancedSyntheticModifierEvents() async throws {
        let service = RecordingActionService()
        let executor = HostActionExecutor(service: service)
        let profileID = ProfileID()
        for key: UInt16 in [8, 9] {
            let chord = KeyboardChord(
                key: try XCTUnwrap(MacVirtualKeyCode(key)),
                modifiers: [.command]
            )
            let result = await executor.executeDialAction(
                .primitive(.keyboardShortcut(chord)),
                profileID: profileID,
                dialMagnitude: 1,
                advanceMode: noModeChange,
                admissionRevision: 0
            )
            XCTAssertEqual(result.outcome, .acceptedUnverified)
        }

        let intents = await service.intents
        XCTAssertEqual(intents, [
            .keyboard(.down, .modifier(.command)),
            .keyboard(.down, .key(try XCTUnwrap(MacVirtualKeyCode(8)))),
            .keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8)))),
            .keyboard(.up, .modifier(.command)),
            .keyboard(.down, .modifier(.command)),
            .keyboard(.down, .key(try XCTUnwrap(MacVirtualKeyCode(9)))),
            .keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(9)))),
            .keyboard(.up, .modifier(.command)),
        ])
    }

    func testHeldKeysShareSyntheticModifiersAndReleaseAfterLastOwner() async throws {
        let service = RecordingActionService()
        let executor = HostActionExecutor(service: service)
        let firstControl = try key("fixture-key-a")
        let secondControl = try key("fixture-key-b")
        let generation = SessionGeneration(7)
        let profileID = ProfileID()
        let modifiers: Set<KeyboardModifier> = [.control, .option]

        _ = await executor.keyDown(
            control: firstControl,
            generation: generation,
            action: .primitive(.holdKeys(KeyboardChord(key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: modifiers))),
            profileID: profileID,
            advanceMode: noModeChange,
            admissionRevision: 0
        )
        _ = await executor.keyDown(
            control: secondControl,
            generation: generation,
            action: .primitive(.holdKeys(KeyboardChord(key: try XCTUnwrap(MacVirtualKeyCode(9)), modifiers: modifiers))),
            profileID: profileID,
            advanceMode: noModeChange,
            admissionRevision: 0
        )

        let firstRelease = await executor.keyUp(control: firstControl, generation: generation, admissionRevision: 0)
        XCTAssertEqual(firstRelease.outcome, .acceptedUnverified)
        var intents = await service.intents
        XCTAssertEqual(count(.keyboard(.down, .modifier(.control)), in: intents), 1)
        XCTAssertEqual(count(.keyboard(.down, .modifier(.option)), in: intents), 1)
        XCTAssertFalse(intents.contains(.keyboard(.up, .modifier(.control))))
        XCTAssertFalse(intents.contains(.keyboard(.up, .modifier(.option))))

        let secondRelease = await executor.keyUp(control: secondControl, generation: generation, admissionRevision: 0)
        XCTAssertEqual(secondRelease.outcome, .acceptedUnverified)
        intents = await service.intents
        XCTAssertEqual(count(.keyboard(.up, .modifier(.control)), in: intents), 1)
        XCTAssertEqual(count(.keyboard(.up, .modifier(.option)), in: intents), 1)
        XCTAssertFalse(intents.contains(.keyboard(.down, .modifier(.command))))
        XCTAssertFalse(intents.contains(.keyboard(.down, .modifier(.shift))))
    }

    func testDuplicateDownAndStaleUpDoNotChangeHeldOwnership() async throws {
        let service = RecordingActionService()
        let executor = HostActionExecutor(service: service)
        let control = try key("fixture-key-a")
        let generation = SessionGeneration(2)
        let action = ConfiguredAction.primitive(.holdKeys(KeyboardChord(
            key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command]
        )))

        _ = await executor.keyDown(control: control, generation: generation, action: action, profileID: ProfileID(), advanceMode: noModeChange, admissionRevision: 0)
        let duplicate = await executor.keyDown(control: control, generation: generation, action: action, profileID: ProfileID(), advanceMode: noModeChange, admissionRevision: 0)
        XCTAssertEqual(duplicate.outcome, .ignored)
        let staleUp = await executor.keyUp(control: control, generation: SessionGeneration(1), admissionRevision: 0)
        XCTAssertEqual(staleUp.outcome, .ignored)
        let heldIntents = await service.intents
        XCTAssertEqual(count(.keyboard(.down, .modifier(.command)), in: heldIntents), 1)

        _ = await executor.keyUp(control: control, generation: generation, admissionRevision: 0)
        let finalIntents = await service.intents
        XCTAssertEqual(count(.keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8)))), in: finalIntents), 1)
        XCTAssertEqual(count(.keyboard(.up, .modifier(.command)), in: finalIntents), 1)
    }

    func testStructuredLaunchShortcutClipboardScrollAndZoomDispatch() async throws {
        let service = RecordingActionService()
        let executor = HostActionExecutor(service: service)
        let appID = try XCTUnwrap(ApplicationBundleIdentifier("com.example.editor"))
        let shortcut = try XCTUnwrap(AppleShortcutName("Fixture Shortcut"))
        let sequence = try ActionSequence(steps: [
            .action(.openApplication(appID)),
            .action(.runAppleShortcut(shortcut)),
            .action(.clipboardManagerShortcut(KeyboardChord(
                key: try XCTUnwrap(MacVirtualKeyCode(11)), modifiers: [.command, .shift]
            ))),
            .action(.scroll(axis: .horizontal, speed: try XCTUnwrap(ScrollSpeed(3)))),
            .action(.zoom(.in)),
        ])

        let result = await executor.executeDialAction(
            .sequence(sequence), profileID: ProfileID(), dialMagnitude: -2, advanceMode: noModeChange, admissionRevision: 0
        )
        XCTAssertEqual(result.outcome, .acceptedUnverified)
        let intents = await service.intents
        XCTAssertTrue(intents.contains(.launchOrActivateApplication(appID)))
        XCTAssertTrue(intents.contains(.runAppleShortcut(shortcut)))
        XCTAssertTrue(intents.contains(.clipboardManagerShortcut(KeyboardChord(
            key: try XCTUnwrap(MacVirtualKeyCode(11)), modifiers: [.command, .shift]
        ))))
        XCTAssertTrue(intents.contains(.scroll(axis: .horizontal, detents: -2, speed: try XCTUnwrap(ScrollSpeed(3)))))
        XCTAssertTrue(intents.contains(.zoom(.in, steps: 2, application: nil)))
    }

    func testSequencePreservesOrderAndHonorsPause() async throws {
        let service = RecordingActionService()
        let executor = HostActionExecutor(service: service)
        let firstID = try XCTUnwrap(ApplicationBundleIdentifier("com.example.first"))
        let secondID = try XCTUnwrap(ApplicationBundleIdentifier("com.example.second"))
        let sequence = try ActionSequence(steps: [
            .action(.openApplication(firstID)),
            .pause(milliseconds: 20),
            .action(.openApplication(secondID)),
        ])

        let result = await executor.executeDialAction(
            .sequence(sequence), profileID: ProfileID(), dialMagnitude: 1, advanceMode: noModeChange, admissionRevision: 0
        )
        XCTAssertEqual(result.outcome, .acceptedUnverified)
        let intents = await service.intents
        XCTAssertEqual(intents, [.launchOrActivateApplication(firstID), .launchOrActivateApplication(secondID)])
        let timestamps = await service.timestamps
        XCTAssertGreaterThanOrEqual(timestamps[1] - timestamps[0], .milliseconds(15))
    }

    func testCancellationDuringPausePreventsLaterActionsAndCleansOwnedInputs() async throws {
        let service = RecordingActionService()
        let executor = HostActionExecutor(service: service)
        let sequence = try ActionSequence(steps: [
            .action(.holdKeys(KeyboardChord(key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.control, .option]))),
            .pause(milliseconds: 500),
            .action(.openApplication(try XCTUnwrap(ApplicationBundleIdentifier("com.example.never")))),
        ])
        let run = Task {
            await executor.executeDialAction(
                .sequence(sequence), profileID: ProfileID(), dialMagnitude: 1,
                advanceMode: noModeChange, admissionRevision: 0
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        let cleanupFailures = await executor.cancelAndRelease(floor: 0)
        XCTAssertTrue(cleanupFailures.isEmpty)
        let result = await run.value
        XCTAssertEqual(result.outcome, .cancelled)
        let intents = await service.intents
        XCTAssertFalse(intents.contains(.launchOrActivateApplication(try XCTUnwrap(ApplicationBundleIdentifier("com.example.never")))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8))))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.control))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.option))))
    }

    func testAdmissionFloorRejectsLateOldRevisionWhileCleanupWaitsForExecutorGate() async throws {
        let service = RecordingActionService()
        let advanceGate = CancellationHoldingModeAdvance()
        let executor = HostActionExecutor(service: service)
        let profileID = ProfileID()
        let staleTarget = try XCTUnwrap(ApplicationBundleIdentifier("com.example.stale"))
        let activeRequest = Task {
            await executor.executeDialAction(
                .primitive(.nextDialMode),
                profileID: profileID,
                dialMagnitude: 1,
                advanceMode: { _ in await advanceGate.advance() },
                admissionRevision: 7
            )
        }
        let advanceStarted = await advanceGate.waitUntilStarted()
        XCTAssertTrue(advanceStarted)

        let cleanupCompleted = AsyncTestFlag()
        let cleanup = Task {
            let failures = await executor.cancelAndRelease(floor: 8)
            await cleanupCompleted.mark()
            return failures
        }
        let cancellationObserved = await advanceGate.waitUntilCancellationObserved()
        XCTAssertTrue(cancellationObserved)

        let staleCompleted = AsyncTestFlag()
        let staleRequest = Task {
            let result = await executor.executeDialAction(
                .primitive(.openApplication(staleTarget)),
                profileID: profileID,
                dialMagnitude: 1,
                advanceMode: noModeChange,
                admissionRevision: 7
            )
            await staleCompleted.mark()
            return result
        }
        try await Task.sleep(for: .milliseconds(40))
        let staleWasRejectedBeforeGateRelease = await staleCompleted.isMarked
        let cleanupReturnedBeforeGateRelease = await cleanupCompleted.isMarked

        await advanceGate.releaseWithCancellation()
        _ = await activeRequest.value
        let staleResult = await staleRequest.value
        let cleanupFailures = await cleanup.value
        let intents = await service.intents

        XCTAssertTrue(staleWasRejectedBeforeGateRelease, "An old revision must be rejected while cleanup still owns the executor gate")
        XCTAssertFalse(cleanupReturnedBeforeGateRelease, "Cleanup must wait for the in-flight action to leave the gate")
        XCTAssertEqual(staleResult.outcome, .ignored)
        XCTAssertTrue(cleanupFailures.isEmpty)
        XCTAssertTrue(intents.isEmpty, "The stale request must not call the injected service")
    }

    func testTimedOutServiceReturnsTypedFailure() async throws {
        let service = RecordingActionService(delay: .seconds(1))
        let executor = HostActionExecutor(
            service: service,
            limits: ActionExecutionLimits(perActionTimeout: .milliseconds(25), sequenceDeadline: .seconds(1))
        )
        let result = await executor.executeDialAction(
            .primitive(.openApplication(try XCTUnwrap(ApplicationBundleIdentifier("com.example.timeout")))),
            profileID: ProfileID(), dialMagnitude: 1, advanceMode: noModeChange, admissionRevision: 0
        )
        XCTAssertEqual(result.outcome, .failed(.actionTimedOut))
    }

    func testCancellationBeforeServiceInvocationJoinsNestedRace() async throws {
        let service = RecordingActionService()
        let invocationGate = CancellationGate()
        let executor = HostActionExecutor(
            service: service,
            limits: ActionExecutionLimits(perActionTimeout: .seconds(2), sequenceDeadline: .seconds(2)),
            beforeServiceInvocation: { await invocationGate.suspend() }
        )
        let target = try XCTUnwrap(ApplicationBundleIdentifier("com.example.cancelled-before-call"))
        let action = Task {
            await executor.executeDialAction(
                .primitive(.openApplication(target)),
                profileID: ProfileID(),
                dialMagnitude: 1,
                advanceMode: noModeChange,
                admissionRevision: 41
            )
        }

        let reachedInvocationGate = await invocationGate.waitUntilEntered()
        XCTAssertTrue(reachedInvocationGate, "The service child should pause immediately before invocation")
        guard reachedInvocationGate else {
            await invocationGate.release()
            _ = await action.value
            return
        }

        let cleanupCompleted = AsyncTestFlag()
        let cleanup = Task {
            let failures = await executor.cancelAndRelease(floor: 42)
            await cleanupCompleted.mark()
            return failures
        }
        let cancellationReachedChild = await invocationGate.waitUntilCancelled()
        XCTAssertTrue(cancellationReachedChild, "The nested operation should observe cancellation before service invocation")
        let cleanupReturnedBeforeChildJoined = await cleanupCompleted.isMarked
        XCTAssertFalse(cleanupReturnedBeforeChildJoined, "Cleanup must wait for the structured race child to return")

        await invocationGate.release()
        let result = await action.value
        let cleanupFailures = await cleanup.value
        let intents = await service.intents
        let cleanupReturned = await cleanupCompleted.isMarked
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(cleanupFailures.isEmpty)
        XCTAssertTrue(cleanupReturned)
        XCTAssertTrue(intents.isEmpty, "The cancellation check must prevent perform from starting")
    }

    func testLateAcceptedKeyDownIsLedgeredAndReleasedDuringExecutorCleanup() async throws {
        let keyCode = try XCTUnwrap(MacVirtualKeyCode(8))
        let down = HostActionIntent.keyboard(.down, .key(keyCode))
        let service = LateAcceptedKeyDownActionService(gatedDown: down)
        let executor = HostActionExecutor(
            service: service,
            limits: ActionExecutionLimits(perActionTimeout: .seconds(2), sequenceDeadline: .seconds(5))
        )
        let sequence = try ActionSequence(steps: [
            .action(.holdKeys(KeyboardChord(key: keyCode, modifiers: []))),
            .pause(milliseconds: 1_000),
        ])
        let action = Task {
            await executor.executeDialAction(
                .sequence(sequence),
                profileID: ProfileID(),
                dialMagnitude: 1,
                advanceMode: noModeChange,
                admissionRevision: 0
            )
        }

        let downStarted = await service.waitUntilDownStarted()
        XCTAssertTrue(downStarted, "The synthetic key-down should enter the gated adapter call")
        guard downStarted else {
            await service.releaseDown()
            _ = await action.value
            return
        }
        let cleanup = Task { await executor.cancelAndRelease(floor: 1) }
        let cancellationObserved = await service.waitUntilCancellationObserved()
        XCTAssertTrue(cancellationObserved, "Executor cleanup should cancel the in-flight key-down call")

        await service.releaseDown()
        let result = await action.value
        let cleanupFailures = await cleanup.value
        let intents = await service.intents

        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(cleanupFailures.isEmpty)
        XCTAssertEqual(intents, [down, .keyboard(.up, .key(keyCode))],
                       "A late accepted down must be entered in the owner ledger so executor cleanup balances it")
    }

    func testMissingTargetIsActionableAndSequencesReportPartialFailure() async throws {
        let missingID = try XCTUnwrap(ApplicationBundleIdentifier("com.example.missing"))
        let service = RecordingActionService(result: .missingTarget(.application(missingID)))
        let executor = HostActionExecutor(service: service)
        let sequence = try ActionSequence(steps: [
            .action(.doNothing),
            .action(.openApplication(missingID)),
        ])
        let result = await executor.executeDialAction(
            .sequence(sequence), profileID: ProfileID(), dialMagnitude: 1, advanceMode: noModeChange, admissionRevision: 0
        )
        XCTAssertEqual(result.outcome, .partialFailure(
            completedSteps: 1,
            failure: .missingTarget(.application(missingID))
        ))
    }

    func testUnsupportedServiceTargetsRemainDistinctFromMissingTargets() async throws {
        let service = RecordingActionService(result: .unsupported(reason: "The action service does not support this target"))
        let executor = HostActionExecutor(service: service)
        let result = await executor.executeDialAction(
            .primitive(.runAppleShortcut(try XCTUnwrap(AppleShortcutName("Fixture Shortcut")))),
            profileID: ProfileID(), dialMagnitude: 1, advanceMode: noModeChange, admissionRevision: 0
        )
        XCTAssertEqual(result.outcome, .failed(.unsupportedAction("The action service does not support this target")))
    }

    func testNextDialModeReturnsStateChangeInsteadOfClaimingAnOSAction() async {
        let service = RecordingActionService()
        let executor = HostActionExecutor(service: service)
        let profileID = ProfileID()
        let nextModeID = DialModeID()
        let result = await executor.executeDialAction(
            .primitive(.nextDialMode),
            profileID: profileID,
            dialMagnitude: 1,
            advanceMode: { _ in .advanced(nextModeID) },
            admissionRevision: 0
        )
        XCTAssertEqual(result.outcome, .modeChanged(profileID: profileID, modeID: nextModeID))
        let intents = await service.intents
        XCTAssertTrue(intents.isEmpty)
    }

    func testProgrammingCompletionPreservesCallerRequestCorrelation() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.doNothing), appButton: .inherit)
        let store = ConfigurationStore(
            primaryURL: URL(fileURLWithPath: "/virtual/programming-\(UUID().uuidString).json"),
            fileAccess: MemoryConfigurationFiles()
        )
        try await store.save(fixture.configuration)
        let runtime = ActionRuntime(
            inputProducer: ManualInputProducer(),
            capabilities: FixtureCapabilities(),
            programmer: MismatchedProgrammer(),
            foregroundApplication: MutableForeground(),
            controlMapping: FixtureMapping([:]),
            configurationStore: store,
            actionService: RecordingActionService()
        )
        let request = ProgrammingRequest(assignments: [])
        let completion = await runtime.submit(.program(request))
        guard case .programming(let result) = completion else {
            return XCTFail("Programming command must return a correlated completion")
        }
        XCTAssertEqual(result.requestID, request.requestID)
        XCTAssertEqual(result.outcome, .failed(.init(reason: "Programming service returned a mismatched request ID")))
    }

    func testRuntimeKeyAssignmentCandidatesExposeOnlyReviewedVectors() throws {
        let candidates: [(RuntimeKeyAssignmentCandidate, UInt8, UInt8)] = [
            (.topLeftUsage05, 3, 0x05),
            (.topRightUsage09, 6, 0x09),
            (.middleLeftUsage04, 2, 0x04),
            (.middleRightUsage08, 5, 0x08),
            (.bottomLeftUsage1B, 1, 0x1b),
            (.bottomLeftUsage1D, 1, 0x1d),
            (.bottomRightUsage07, 4, 0x07),
            (.clockwiseKnobUsage0D, 15, 0x0d),
            (.counterclockwiseKnobUsage0A, 13, 0x0a),
            (.knobPressUsage0B, 14, 0x0b),
        ]

        XCTAssertEqual(candidates.count, 10)
        for (candidate, slot, usage) in candidates {
            XCTAssertEqual(candidate.slot, slot)
            XCTAssertEqual(candidate.usage, usage)
            XCTAssertEqual(RuntimeKeyAssignmentCandidate(slot: slot, usage: usage), candidate)
        }
        XCTAssertNil(RuntimeKeyAssignmentCandidate(slot: 1, usage: 0x04), "A usage supported on another slot must be rejected")
        XCTAssertNil(RuntimeKeyAssignmentCandidate(slot: 99, usage: 0x05), "An unsupported slot must be rejected")
    }

    func testTypedKeyAssignmentMethodPreservesCandidateConsentIdentityAndUnverifiedCount() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.doNothing), appButton: .inherit)
        let programmer = RecordingKeyAssignmentProgrammer(outcome: .sentUnverified(reportsAccepted: 4))
        let runtime = try await makeRuntime(
            configuration: fixture.configuration,
            service: RecordingActionService(),
            foreground: MutableForeground(),
            input: ManualInputProducer(),
            mapping: [:],
            keyAssignmentProgrammer: programmer
        )
        let request = KeyAssignmentProgrammingRequest(
            requestID: UUID(),
            candidate: .bottomLeftUsage1D,
            acceptsPersistentOverwrite: true
        )

        let handler: any RuntimeCommandHandling = runtime
        let result = await handler.programKeyAssignment(request)

        XCTAssertEqual(result, .init(
            requestID: request.requestID,
            outcome: .sentUnverified(reportsAccepted: 4)
        ))
        let captured = await programmer.requests
        XCTAssertEqual(captured, [request])
    }

    func testTypedKeyAssignmentRejectsMissingConsentAndUnsupportedInputWithoutProgrammerCall() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.doNothing), appButton: .inherit)
        let programmer = RecordingKeyAssignmentProgrammer(outcome: .sentUnverified(reportsAccepted: 4))
        let runtime = try await makeRuntime(
            configuration: fixture.configuration,
            service: RecordingActionService(),
            foreground: MutableForeground(),
            input: ManualInputProducer(),
            mapping: [:],
            keyAssignmentProgrammer: programmer
        )
        let denied = KeyAssignmentProgrammingRequest(
            candidate: .topLeftUsage05,
            acceptsPersistentOverwrite: false
        )

        let handler: any RuntimeCommandHandling = runtime
        let deniedResult = await handler.programKeyAssignment(denied)

        XCTAssertEqual(deniedResult, .init(
            requestID: denied.requestID,
            outcome: .failed(reason: "Persistent overwrite was not accepted", reportsAccepted: 0)
        ))
        XCTAssertNil(RuntimeKeyAssignmentCandidate(slot: 1, usage: 0x04))
        let captured = await programmer.requests
        XCTAssertTrue(captured.isEmpty, "Unaccepted or unsupported assignment input must not reach the programmer")
    }

    func testTypedKeyAssignmentFailsClosedWithoutProgrammer() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.doNothing), appButton: .inherit)
        let runtime = try await makeRuntime(
            configuration: fixture.configuration,
            service: RecordingActionService(),
            foreground: MutableForeground(),
            input: ManualInputProducer(),
            mapping: [:]
        )
        let request = KeyAssignmentProgrammingRequest(
            candidate: .knobPressUsage0B,
            acceptsPersistentOverwrite: true
        )

        let handler: any RuntimeCommandHandling = runtime
        let result = await handler.programKeyAssignment(request)

        XCTAssertEqual(result, .init(
            requestID: request.requestID,
            outcome: .failed(
                reason: "No supported key assignment programmer is configured",
                reportsAccepted: 0
            )
        ))
    }

    func testTypedKeyAssignmentRejectsMismatchedResultIdentityAndPreservesAcceptedCount() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.doNothing), appButton: .inherit)
        let runtime = try await makeRuntime(
            configuration: fixture.configuration,
            service: RecordingActionService(),
            foreground: MutableForeground(),
            input: ManualInputProducer(),
            mapping: [:],
            keyAssignmentProgrammer: MismatchedKeyAssignmentProgrammer(result: .init(
                requestID: UUID(),
                outcome: .sentUnverified(reportsAccepted: 2)
            ))
        )
        let request = KeyAssignmentProgrammingRequest(
            candidate: .clockwiseKnobUsage0D,
            acceptsPersistentOverwrite: true
        )

        let handler: any RuntimeCommandHandling = runtime
        let result = await handler.programKeyAssignment(request)

        XCTAssertEqual(result, .init(
            requestID: request.requestID,
            outcome: .failed(
                reason: "Key assignment service returned a mismatched request ID",
                reportsAccepted: 2
            )
        ))
    }

    func testLightingCommandPreservesTypedRequestIdentityAndAcceptedCount() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.doNothing), appButton: .inherit)
        let lightingProgrammer = RecordingLightingProgrammer(outcome: .sentUnverified(reportsAccepted: 3))
        let runtime = try await makeRuntime(
            configuration: fixture.configuration,
            service: RecordingActionService(),
            foreground: MutableForeground(),
            input: ManualInputProducer(),
            mapping: [:],
            lightingProgrammer: lightingProgrammer
        )
        let request = LightingProgrammingRequest(
            requestID: UUID(), mode: .mode1, acceptsPersistentOverwrite: true)

        let completion = await runtime.submit(.programLighting(request))

        XCTAssertEqual(completion, .lightingProgramming(.init(
            requestID: request.requestID,
            outcome: .sentUnverified(reportsAccepted: 3)
        )))
        let captured = await lightingProgrammer.lastRequest
        XCTAssertEqual(captured, request)
    }

    func testLightingCommandRequiresFreshAcceptanceAndFailsClosedWithoutProgrammer() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.doNothing), appButton: .inherit)
        let withoutProgrammer = try await makeRuntime(
            configuration: fixture.configuration,
            service: RecordingActionService(),
            foreground: MutableForeground(),
            input: ManualInputProducer(),
            mapping: [:]
        )
        let accepted = LightingProgrammingRequest(
            mode: .mode2, acceptsPersistentOverwrite: true)
        let unavailableCompletion = await withoutProgrammer.submit(.programLighting(accepted))
        XCTAssertEqual(unavailableCompletion, .lightingProgramming(.init(
            requestID: accepted.requestID,
            outcome: .failed(
                reason: "No supported device lighting programmer is configured",
                reportsAccepted: 0
            )
        )))

        let recorder = RecordingLightingProgrammer(outcome: .sentUnverified(reportsAccepted: 3))
        let withProgrammer = try await makeRuntime(
            configuration: fixture.configuration,
            service: RecordingActionService(),
            foreground: MutableForeground(),
            input: ManualInputProducer(),
            mapping: [:],
            lightingProgrammer: recorder
        )
        let denied = LightingProgrammingRequest(
            mode: .mode2, acceptsPersistentOverwrite: false)
        let deniedCompletion = await withProgrammer.submit(.programLighting(denied))
        XCTAssertEqual(deniedCompletion, .lightingProgramming(.init(
            requestID: denied.requestID,
            outcome: .failed(reason: "Persistent overwrite was not accepted", reportsAccepted: 0)
        )))
        let captured = await recorder.lastRequest
        XCTAssertNil(captured, "A denied request must not reach the hardware programmer")
    }

    func testLightingCommandRejectsMismatchedResultIDAndPreservesAcceptedCount() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.doNothing), appButton: .inherit)
        let wrongID = UUID()
        let runtime = try await makeRuntime(
            configuration: fixture.configuration,
            service: RecordingActionService(),
            foreground: MutableForeground(),
            input: ManualInputProducer(),
            mapping: [:],
            lightingProgrammer: MismatchedLightingProgrammer(result: .init(
                requestID: wrongID,
                outcome: .sentUnverified(reportsAccepted: 2)
            ))
        )
        let request = LightingProgrammingRequest(
            mode: .mode1, acceptsPersistentOverwrite: true)

        let completion = await runtime.submit(.programLighting(request))

        XCTAssertEqual(completion, .lightingProgramming(.init(
            requestID: request.requestID,
            outcome: .failed(
                reason: "Lighting service returned a mismatched request ID",
                reportsAccepted: 2
            )
        )))
    }

    func testSequenceDeadlineBoundsConfiguredPauses() async throws {
        let service = RecordingActionService()
        let executor = HostActionExecutor(
            service: service,
            limits: ActionExecutionLimits(perActionTimeout: .seconds(1), sequenceDeadline: .milliseconds(20))
        )
        let sequence = try ActionSequence(steps: [
            .action(.holdKeys(KeyboardChord(
                key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.control, .option]
            ))),
            .pause(milliseconds: 1_000),
            .action(.zoom(.in)),
        ])
        let startedAt = ContinuousClock.now
        let result = await executor.executeDialAction(
            .sequence(sequence), profileID: ProfileID(), dialMagnitude: 1, advanceMode: noModeChange, admissionRevision: 0
        )
        let elapsed = startedAt.duration(to: .now)
        XCTAssertEqual(result.outcome, .partialFailure(
            completedSteps: 1,
            failure: .sequenceDeadlineExceeded
        ))
        XCTAssertLessThan(elapsed, .milliseconds(300), "Pause should stop at the sequence deadline")
        let intents = await service.intents
        XCTAssertTrue(intents.contains(.keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8))))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.control))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.option))))
        XCTAssertFalse(intents.contains(.zoom(.in, steps: 1, application: nil)))
    }

    func testCleanupCrossingDeadlineReclassifiesPendingSequenceFailure() async throws {
        let keyCode = try XCTUnwrap(MacVirtualKeyCode(8))
        let target = try XCTUnwrap(ApplicationBundleIdentifier("com.example.failing-step"))
        let sequence = try ActionSequence(steps: [
            .action(.holdKeys(KeyboardChord(key: keyCode, modifiers: []))),
            .action(.openApplication(target)),
        ])
        let cleanupGate = CancellationGate()
        let service = GatedCleanupActionService(gate: cleanupGate, failingApplication: target)
        let limits = ActionExecutionLimits(
            perActionTimeout: .seconds(2),
            sequenceDeadline: .milliseconds(250)
        )
        let executor = HostActionExecutor(service: service, limits: limits)
        let startedAt = ContinuousClock.now
        let action = Task {
            await executor.executeDialAction(
                .sequence(sequence),
                profileID: ProfileID(),
                dialMagnitude: 1,
                advanceMode: noModeChange,
                admissionRevision: 0
            )
        }

        let cleanupStarted = await cleanupGate.waitUntilEntered()
        XCTAssertTrue(cleanupStarted, "The earlier failed step should enter held-key cleanup")
        guard cleanupStarted else {
            await cleanupGate.release()
            _ = await action.value
            return
        }
        XCTAssertLessThan(
            startedAt.duration(to: .now),
            limits.sequenceDeadline,
            "The failed action should enter cleanup before the sequence deadline"
        )
        let remaining = ContinuousClock.now.duration(to: startedAt.advanced(by: limits.sequenceDeadline))
        if remaining > .zero { try await Task.sleep(for: remaining + .milliseconds(20)) }
        XCTAssertGreaterThanOrEqual(
            startedAt.duration(to: .now),
            limits.sequenceDeadline,
            "The gated cleanup should remain pending until after the sequence deadline"
        )

        await cleanupGate.release()
        let result = await action.value
        XCTAssertEqual(result.outcome, .partialFailure(
            completedSteps: 1,
            failure: .sequenceDeadlineExceeded
        ))
    }

    func testExpiredDeadlineSurvivesConcurrentCancellationForBothActionEntryPoints() async throws {
        let configuredActionResult = try await runSequenceCancelledDuringCleanup(useKeyDown: false)
        let keyDownResult = try await runSequenceCancelledDuringCleanup(useKeyDown: true)
        let expected: ActionExecutionOutcome = .partialFailure(
            completedSteps: 1,
            failure: .sequenceDeadlineExceeded
        )
        XCTAssertEqual(configuredActionResult.outcome, expected)
        XCTAssertEqual(keyDownResult.outcome, expected)
    }

    func testSequenceDeadlineBoundsServiceCallAndCleansHeldInputs() async throws {
        let application = try XCTUnwrap(ApplicationBundleIdentifier("com.example.slow"))
        let service = RecordingActionService(
            delay: .seconds(1),
            delayedIntent: .launchOrActivateApplication(application)
        )
        let executor = HostActionExecutor(
            service: service,
            limits: ActionExecutionLimits(perActionTimeout: .seconds(2), sequenceDeadline: .milliseconds(30))
        )
        let sequence = try ActionSequence(steps: [
            .action(.holdKeys(KeyboardChord(
                key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.control, .option]
            ))),
            .action(.openApplication(application)),
        ])
        let startedAt = ContinuousClock.now
        let result = await executor.executeDialAction(
            .sequence(sequence), profileID: ProfileID(), dialMagnitude: 1, advanceMode: noModeChange, admissionRevision: 0
        )
        let elapsed = startedAt.duration(to: .now)

        XCTAssertEqual(result.outcome, .partialFailure(
            completedSteps: 1,
            failure: .sequenceDeadlineExceeded
        ))
        XCTAssertLessThan(elapsed, .milliseconds(300), "Service action should be capped by remaining sequence time")
        let intents = await service.intents
        XCTAssertFalse(intents.contains(.launchOrActivateApplication(application)))
        XCTAssertTrue(intents.contains(.keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8))))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.control))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.option))))
    }

    func testSequenceModePersistenceExpiryCancelsBeforePrimaryCommitAndReleasesInputs() async throws {
        let chord = KeyboardChord(
            key: try XCTUnwrap(MacVirtualKeyCode(8)),
            modifiers: [.control, .option]
        )
        let sequence = try ActionSequence(steps: [
            .action(.holdKeys(chord)),
            .action(.nextDialMode),
        ])
        let fixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            clockwiseAction: .sequence(sequence)
        )
        let files = GatedBackupConfigurationFiles()
        let url = URL(fileURLWithPath: "/virtual/sequence-mode-deadline-\(UUID().uuidString).json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: files)
        try await store.save(fixture.configuration)
        files.blockNextBackupWrite()

        let input = ManualInputProducer()
        let service = RecordingActionService()
        let runtime = ActionRuntime(
            inputProducer: input,
            capabilities: FixtureCapabilities(),
            programmer: FixtureProgrammer(),
            foregroundApplication: MutableForeground(),
            controlMapping: FixtureMapping([:]),
            configurationStore: store,
            actionService: service,
            executionLimits: ActionExecutionLimits(
                perActionTimeout: .seconds(1),
                sequenceDeadline: .milliseconds(70)
            )
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-dial", kind: .dial))
        let rotation = try XCTUnwrap(NormalizedInputEvent.dialRotation(
            control: dial,
            delta: 1,
            generation: generation
        ))

        let completion = AsyncTestFlag()
        let routing = Task {
            await input.emit(rotation)
            await completion.mark()
        }
        guard files.waitForBlockedBackup() else {
            XCTFail("Mode persistence should enter the gated backup write")
            return
        }
        try await Task.sleep(for: .milliseconds(140))
        let completedBeforeBackupRelease = await completion.isMarked
        XCTAssertFalse(completedBeforeBackupRelease, "A timed-out mode advance must join the pending store operation")
        XCTAssertEqual(files.primaryWriteCount, 1, "Cancellation before the primary commit must leave the persisted mode unchanged")

        files.releaseBlockedBackup()
        await routing.value
        XCTAssertTrue(files.waitForBlockedBackupToFinish())

        let actionResult = await runtime.currentSnapshot().lastActionResult
        XCTAssertEqual(actionResult?.outcome, .partialFailure(
            completedSteps: 1,
            failure: .sequenceDeadlineExceeded
        ))

        let key = try XCTUnwrap(MacVirtualKeyCode(8))
        let intents = await service.intents
        XCTAssertTrue(intents.contains(.keyboard(.up, .key(key))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.control))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.option))))
        XCTAssertEqual(files.primaryWriteCount, 1, "The expired mode change must not start a primary write")
        let reloaded = try await ConfigurationStore(primaryURL: url, fileAccess: files).load()
        XCTAssertEqual(reloaded.defaultProfile.selectedDialMode.id, fixture.firstModeID)
    }

    func testSequenceDeadlineWinsWhenModeCallbackIsCancelledBeforeItsFirstGuard() async throws {
        let sequence = try ActionSequence(steps: [.action(.nextDialMode)])
        let fixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            clockwiseAction: .sequence(sequence)
        )
        let url = URL(fileURLWithPath: "/virtual/sequence-mode-first-guard-\(UUID().uuidString).json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: MemoryConfigurationFiles())
        try await store.save(fixture.configuration)

        let input = ManualInputProducer()
        let runtime = ActionRuntime(
            inputProducer: input,
            capabilities: FixtureCapabilities(),
            programmer: FixtureProgrammer(),
            foregroundApplication: MutableForeground(),
            controlMapping: FixtureMapping([:]),
            configurationStore: store,
            actionService: RecordingActionService(),
            executionLimits: ActionExecutionLimits(
                perActionTimeout: .seconds(1),
                sequenceDeadline: .milliseconds(70)
            )
        )
        let modeGate = CancellationGate()
        await runtime.setModeAdvanceStartGateForTesting { await modeGate.suspend() }
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-dial", kind: .dial))
        let rotation = try XCTUnwrap(NormalizedInputEvent.dialRotation(
            control: dial,
            delta: 1,
            generation: generation
        ))
        let routeCompleted = AsyncTestFlag()
        let routing = Task {
            await input.emit(rotation)
            await routeCompleted.mark()
        }

        let callbackPausedBeforeGuard = await modeGate.waitUntilEntered()
        XCTAssertTrue(callbackPausedBeforeGuard, "The test gate must pause before the runtime deadline guard")
        guard callbackPausedBeforeGuard else {
            await modeGate.release()
            await routing.value
            return
        }
        let callbackCancelled = await modeGate.waitUntilCancelled()
        XCTAssertTrue(callbackCancelled, "The deadline must cancel the mode callback while it is before the first guard")
        let routeReturnedBeforeGuard = await routeCompleted.isMarked
        XCTAssertFalse(routeReturnedBeforeGuard, "The executor must join the blocked callback before returning")

        await modeGate.release()
        await routing.value
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.lastActionResult?.outcome, .failed(.sequenceDeadlineExceeded))
        XCTAssertEqual(snapshot.selectedDialModeID, fixture.firstModeID)
        let persisted = try await store.load()
        XCTAssertEqual(persisted.defaultProfile.selectedDialMode.id, fixture.firstModeID)
    }

    func testSequenceModePersistenceJoiningPrimaryCommitReportsModeChange() async throws {
        let sequence = try ActionSequence(steps: [.action(.nextDialMode)])
        let fixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            clockwiseAction: .sequence(sequence)
        )
        let files = GatedBackupConfigurationFiles()
        let url = URL(fileURLWithPath: "/virtual/sequence-mode-primary-race-\(UUID().uuidString).json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: files)
        try await store.save(fixture.configuration)
        files.blockNextPrimaryWrite()

        let input = ManualInputProducer()
        let runtime = ActionRuntime(
            inputProducer: input,
            capabilities: FixtureCapabilities(),
            programmer: FixtureProgrammer(),
            foregroundApplication: MutableForeground(),
            controlMapping: FixtureMapping([:]),
            configurationStore: store,
            actionService: RecordingActionService(),
            executionLimits: ActionExecutionLimits(
                perActionTimeout: .seconds(1),
                sequenceDeadline: .milliseconds(70)
            )
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-dial", kind: .dial))
        let rotation = try XCTUnwrap(NormalizedInputEvent.dialRotation(
            control: dial,
            delta: 1,
            generation: generation
        ))
        let completion = AsyncTestFlag()
        let routing = Task {
            await input.emit(rotation)
            await completion.mark()
        }

        guard files.waitForBlockedPrimaryWrite() else {
            XCTFail("Mode persistence should enter the gated primary replacement")
            return
        }
        try await Task.sleep(for: .milliseconds(140))
        let completedBeforePrimaryRelease = await completion.isMarked
        XCTAssertFalse(completedBeforePrimaryRelease, "A timed-out mode advance must wait for the actual primary-write result")
        files.releaseBlockedPrimaryWrite()
        await routing.value
        XCTAssertTrue(files.waitForBlockedPrimaryWriteToFinish())

        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.lastActionResult?.outcome, .modeChanged(
            profileID: fixture.configuration.defaultProfileID,
            modeID: fixture.secondModeID
        ))
        XCTAssertEqual(snapshot.selectedDialModeID, fixture.secondModeID)
        let reloaded = try await ConfigurationStore(primaryURL: url, fileAccess: files).load()
        XCTAssertEqual(reloaded.defaultProfile.selectedDialMode.id, fixture.secondModeID)
        XCTAssertEqual(files.primaryWriteCount, 2)
    }

    func testExplicitStopDuringPrimaryCommitWaitsAndReportsCommittedMode() async throws {
        let keyCode = try XCTUnwrap(MacVirtualKeyCode(8))
        let sequence = try ActionSequence(steps: [
            .action(.holdKeys(KeyboardChord(key: keyCode, modifiers: []))),
            .action(.nextDialMode),
        ])
        let fixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            clockwiseAction: .sequence(sequence)
        )
        let files = GatedBackupConfigurationFiles()
        let url = URL(fileURLWithPath: "/virtual/sequence-mode-explicit-cancel-\(UUID().uuidString).json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: files)
        try await store.save(fixture.configuration)
        files.blockNextPrimaryWrite()

        let input = ManualInputProducer()
        let service = RecordingActionService()
        let runtime = ActionRuntime(
            inputProducer: input,
            capabilities: FixtureCapabilities(),
            programmer: FixtureProgrammer(),
            foregroundApplication: MutableForeground(),
            controlMapping: FixtureMapping([:]),
            configurationStore: store,
            actionService: service,
            executionLimits: ActionExecutionLimits(
                perActionTimeout: .seconds(1),
                sequenceDeadline: .seconds(5)
            )
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-dial", kind: .dial))
        let rotation = try XCTUnwrap(NormalizedInputEvent.dialRotation(
            control: dial,
            delta: 1,
            generation: generation
        ))
        let routeCompleted = AsyncTestFlag()
        let routing = Task {
            await input.emit(rotation)
            await routeCompleted.mark()
        }

        guard files.waitForBlockedPrimaryWrite() else {
            files.releaseBlockedPrimaryWrite()
            XCTFail("Mode persistence should enter the gated primary replacement")
            return
        }

        let stopCompleted = AsyncTestFlag()
        let stopping = Task {
            _ = await runtime.submit(.stop)
            await stopCompleted.mark()
        }
        var observedStopping = false
        for _ in 0..<100 {
            if await runtime.currentStatus() == .stopping(generation: generation) {
                observedStopping = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let stopReturnedBeforePrimaryRelease = await stopCompleted.isMarked
        let routeReturnedBeforePrimaryRelease = await routeCompleted.isMarked
        XCTAssertTrue(observedStopping, "Stop should reach executor cleanup while the primary write is gated")
        XCTAssertFalse(stopReturnedBeforePrimaryRelease, "Cancellation cleanup must join the committed store write")
        XCTAssertFalse(routeReturnedBeforePrimaryRelease, "The route must await the actual mode-advance result")

        files.releaseBlockedPrimaryWrite()
        await routing.value
        await stopping.value
        XCTAssertTrue(files.waitForBlockedPrimaryWriteToFinish())

        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.lastActionResult?.outcome, .modeChanged(
            profileID: fixture.configuration.defaultProfileID,
            modeID: fixture.secondModeID
        ))
        XCTAssertEqual(snapshot.selectedDialModeID, fixture.secondModeID)
        let intents = await service.intents
        XCTAssertEqual(intents, [.keyboard(.down, .key(keyCode)), .keyboard(.up, .key(keyCode))],
                       "A committed terminal mode result should survive cancellation-only held-key cleanup")
        let reloaded = try await ConfigurationStore(primaryURL: url, fileAccess: files).load()
        XCTAssertEqual(reloaded.defaultProfile.selectedDialMode.id, fixture.secondModeID)
        XCTAssertEqual(files.primaryWriteCount, 2)
    }

    func testInstallConfigurationCancelsExecutorSequenceAndReleasesInputsBeforeReturning() async throws {
        try await assertConfigurationReplacementCancelsExecutorWork(reload: false)
    }

    func testReloadConfigurationCancelsExecutorSequenceAndReleasesInputsBeforeReturning() async throws {
        try await assertConfigurationReplacementCancelsExecutorWork(reload: true)
    }

    private func assertConfigurationReplacementCancelsExecutorWork(reload: Bool) async throws {
        let target = try XCTUnwrap(ApplicationBundleIdentifier("com.example.blocked"))
        let chord = KeyboardChord(
            key: try XCTUnwrap(MacVirtualKeyCode(8)),
            modifiers: [.control, .option]
        )
        let sequence = try ActionSequence(steps: [
            .action(.holdKeys(chord)),
            .action(.openApplication(target)),
        ])
        let oldFixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            clockwiseAction: .sequence(sequence)
        )
        let newFixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            clockwiseAction: .primitive(.zoom(.out))
        )
        let files = MemoryConfigurationFiles()
        let url = URL(fileURLWithPath: "/virtual/configuration-cancels-executor-\(UUID().uuidString).json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: files)
        try await store.save(oldFixture.configuration)
        let service = CancellationAwareGatedActionService(
            delayedIntent: .launchOrActivateApplication(target)
        )
        let input = ManualInputProducer()
        let runtime = ActionRuntime(
            inputProducer: input,
            capabilities: FixtureCapabilities(),
            programmer: FixtureProgrammer(),
            foregroundApplication: MutableForeground(),
            controlMapping: FixtureMapping([:]),
            configurationStore: store,
            actionService: service,
            executionLimits: ActionExecutionLimits(
                perActionTimeout: .seconds(4),
                sequenceDeadline: .seconds(5)
            )
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-dial", kind: .dial))
        let rotation = try XCTUnwrap(NormalizedInputEvent.dialRotation(
            control: dial,
            delta: 1,
            generation: generation
        ))
        let routing = Task { await input.emit(rotation) }
        guard await service.waitUntilDelayedActionEntered() else {
            _ = await runtime.submit(.stop)
            XCTFail("Sequence should reach the gated service call")
            return
        }

        if reload {
            try await store.save(newFixture.configuration)
            try await runtime.reloadConfiguration()
        } else {
            try await runtime.installConfiguration(newFixture.configuration)
        }
        let replacementReturnedAt = ContinuousClock.now
        let callsAtReplacementReturn = await service.startedCallCount
        await routing.value
        let callsAfterRoutingCompleted = await service.startedCallCount
        XCTAssertEqual(
            callsAfterRoutingCompleted,
            callsAtReplacementReturn,
            "No executor service call should begin after configuration replacement returns"
        )
        let cancellationObserved = await service.didObserveCancellation
        XCTAssertTrue(cancellationObserved, "Replacement should cancel the active sequence service wait")
        let callStartTimes = await service.callStartTimes
        XCTAssertTrue(
            callStartTimes.allSatisfy { $0 < replacementReturnedAt },
            "Every service call must start before configuration replacement returns"
        )
        let intents = await service.completedIntents
        let key = try XCTUnwrap(MacVirtualKeyCode(8))
        XCTAssertTrue(intents.contains(.keyboard(.up, .key(key))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.control))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.option))))
        XCTAssertFalse(intents.contains(.launchOrActivateApplication(target)))
    }

    func testInstallConfigurationInvalidatesRouteWaitingForForeground() async throws {
        try await assertConfigurationReplacementInvalidatesRoute(reload: false)
    }

    func testReloadConfigurationInvalidatesRouteWaitingForForeground() async throws {
        try await assertConfigurationReplacementInvalidatesRoute(reload: true)
    }

    func testInstallConfigurationRejectsKeyRoutePausedAfterPermitCheckBeforeExecutorAdmission() async throws {
        let oldTarget = try XCTUnwrap(ApplicationBundleIdentifier("com.example.pre-replacement"))
        let oldFixture = try makeConfiguration(
            defaultButton: .primitive(.openApplication(oldTarget)),
            appButton: .inherit
        )
        let newFixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit
        )
        let files = MemoryConfigurationFiles()
        let store = ConfigurationStore(
            primaryURL: URL(fileURLWithPath: "/virtual/route-admission-floor-\(UUID().uuidString).json"),
            fileAccess: files
        )
        try await store.save(oldFixture.configuration)
        let foreground = GatedForeground(value: nil)
        let input = ManualInputProducer()
        let service = RecordingActionService()
        let key = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-key-admission", kind: .key))
        let runtime = ActionRuntime(
            inputProducer: input,
            capabilities: FixtureCapabilities(),
            programmer: FixtureProgrammer(),
            foregroundApplication: foreground,
            controlMapping: FixtureMapping([key: .button1]),
            configurationStore: store,
            actionService: service
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        let event = try XCTUnwrap(NormalizedInputEvent.keyDown(control: key, generation: generation))

        await foreground.pauseNext()
        let routing = Task { await runtime.consume(event) }
        await foreground.waitUntilEntered()

        try await runtime.installConfiguration(newFixture.configuration)
        await foreground.resume()
        await routing.value

        let intents = await service.intents
        XCTAssertTrue(intents.isEmpty, "A key route paused after its current-route check must not be admitted after replacement returns")
    }

    private func assertConfigurationReplacementInvalidatesRoute(reload: Bool) async throws {
        let oldFixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            clockwiseAction: .primitive(.nextDialMode)
        )
        let newFixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            clockwiseAction: .primitive(.zoom(.out))
        )
        let files = MemoryConfigurationFiles()
        let url = URL(fileURLWithPath: "/virtual/configuration-replacement-\(UUID().uuidString).json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: files)
        try await store.save(oldFixture.configuration)
        let foreground = GatedForeground(value: nil)
        let input = ManualInputProducer()
        let service = RecordingActionService()
        let runtime = ActionRuntime(
            inputProducer: input,
            capabilities: FixtureCapabilities(),
            programmer: FixtureProgrammer(),
            foregroundApplication: foreground,
            controlMapping: FixtureMapping([:]),
            configurationStore: store,
            actionService: service
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-dial", kind: .dial))
        let rotation = try XCTUnwrap(NormalizedInputEvent.dialRotation(
            control: dial,
            delta: 1,
            generation: generation
        ))
        await foreground.pauseNext()

        let routing = Task { await input.emit(rotation) }
        await foreground.waitUntilEntered()
        if reload {
            try await store.save(newFixture.configuration)
            try await runtime.reloadConfiguration()
        } else {
            try await runtime.installConfiguration(newFixture.configuration)
        }
        await foreground.resume()
        await routing.value

        let staleIntents = await service.intents
        XCTAssertTrue(staleIntents.isEmpty, "A route from the replaced configuration must not dispatch")
        let persistedAfterStaleRoute = try await ConfigurationStore(primaryURL: url, fileAccess: files).load()
        XCTAssertEqual(
            persistedAfterStaleRoute.defaultProfile.selectedDialMode.id,
            newFixture.firstModeID,
            "A stale mode-advance route must not persist over the replacement"
        )

        await input.emit(rotation)
        let freshIntents = await service.intents
        XCTAssertTrue(freshIntents.contains(.zoom(.out, steps: 1, application: nil)))
        XCTAssertFalse(freshIntents.contains(.zoom(.in, steps: 1, application: nil)))
    }

    func testRuntimeRoutesByForegroundButKeyUpUsesOriginalHeldAssignment() async throws {
        let defaultChord = KeyboardChord(key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command])
        let appChord = KeyboardChord(key: try XCTUnwrap(MacVirtualKeyCode(9)), modifiers: [.control, .option])
        let fixture = try makeConfiguration(
            defaultButton: .primitive(.holdKeys(defaultChord)),
            appButton: .set(.primitive(.holdKeys(appChord))),
            modePress: .primitive(.nextDialMode)
        )
        let service = RecordingActionService()
        let foreground = MutableForeground()
        let keyControl = try key("fixture-button-1")
        let appKey = try key("fixture-button-2")
        let input = ManualInputProducer()
        let runtime = try await makeRuntime(configuration: fixture.configuration, service: service, foreground: foreground, input: input, mapping: [keyControl: .button1, appKey: .button1])
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)

        await input.emit(try XCTUnwrap(NormalizedInputEvent.keyDown(control: keyControl, generation: generation)))
        await foreground.set(try XCTUnwrap(ApplicationBundleIdentifier("com.example.target")))
        await input.emit(try XCTUnwrap(NormalizedInputEvent.keyDown(control: appKey, generation: generation)))
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-dial", kind: .dial))
        let modeChange = await runtime.dialPressed(control: dial, generation: generation)
        let changedMode = await runtime.currentSnapshot()
        XCTAssertEqual(modeChange.outcome, ActionExecutionOutcome.modeChanged(
            profileID: try XCTUnwrap(changedMode.activeProfileID),
            modeID: fixture.appSecondModeID
        ))
        XCTAssertEqual(changedMode.selectedDialModeID, fixture.appSecondModeID)
        await foreground.set(nil)
        await input.emit(try XCTUnwrap(NormalizedInputEvent.keyUp(control: appKey, generation: generation)))
        await input.emit(try XCTUnwrap(NormalizedInputEvent.keyUp(control: keyControl, generation: generation)))

        let intents = await service.intents
        XCTAssertTrue(intents.contains(.keyboard(.down, .modifier(.command))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.command))))
        XCTAssertTrue(intents.contains(.keyboard(.down, .key(try XCTUnwrap(MacVirtualKeyCode(8))))))
        XCTAssertTrue(intents.contains(.keyboard(.down, .modifier(.control))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.control))))
        XCTAssertTrue(intents.contains(.keyboard(.down, .modifier(.option))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.option))))
        XCTAssertTrue(intents.contains(.keyboard(.down, .key(try XCTUnwrap(MacVirtualKeyCode(9))))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(9))))))
    }

    func testStaleKeyRouteAfterStopDoesNotDispatchAndCleansPreviouslyOwnedInput() async throws {
        let chord = KeyboardChord(key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command])
        let fixture = try makeConfiguration(defaultButton: .primitive(.holdKeys(chord)), appButton: .inherit)
        let service = RecordingActionService()
        let foreground = GatedForeground(value: nil)
        let input = ManualInputProducer()
        let firstKey = try key("fixture-button-1")
        let pendingKey = try key("fixture-button-2")
        let url = URL(fileURLWithPath: "/virtual/stale-route-\(UUID().uuidString).json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: MemoryConfigurationFiles())
        try await store.save(fixture.configuration)
        let runtime = ActionRuntime(
            inputProducer: input,
            capabilities: FixtureCapabilities(),
            programmer: FixtureProgrammer(),
            foregroundApplication: foreground,
            controlMapping: FixtureMapping([firstKey: .button1, pendingKey: .button1]),
            configurationStore: store,
            actionService: service
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        let down = try XCTUnwrap(NormalizedInputEvent.keyDown(control: firstKey, generation: generation))
        await input.emit(down)
        await foreground.pauseNext()

        let pendingDown = try XCTUnwrap(NormalizedInputEvent.keyDown(control: pendingKey, generation: generation))
        let routing = Task { await input.emit(pendingDown) }
        await foreground.waitUntilEntered()
        _ = await runtime.submit(.stop)
        await foreground.resume()
        await routing.value

        let intents = await service.intents
        let heldKey = try XCTUnwrap(MacVirtualKeyCode(8))
        XCTAssertEqual(intents.filter { $0 == .keyboard(.down, .key(heldKey)) }.count, 1)
        XCTAssertEqual(intents.filter { $0 == .keyboard(.up, .key(heldKey)) }.count, 1)
        XCTAssertEqual(intents.filter { $0 == .keyboard(.down, .modifier(.command)) }.count, 1)
        XCTAssertEqual(intents.filter { $0 == .keyboard(.up, .modifier(.command)) }.count, 1)
        XCTAssertFalse(intents.contains(.keyboard(.down, .key(try XCTUnwrap(MacVirtualKeyCode(9))))))
        let status = await runtime.currentStatus()
        XCTAssertEqual(status, .idle)
    }

    func testInheritedApplicationButtonUsesDefaultAssignmentAndZoomTarget() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.zoom(.out)), appButton: .inherit)
        let service = RecordingActionService()
        let foreground = MutableForeground()
        let input = ManualInputProducer()
        let key = try key("fixture-button-1")
        let runtime = try await makeRuntime(
            configuration: fixture.configuration,
            service: service,
            foreground: foreground,
            input: input,
            mapping: [key: .button1]
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        await foreground.set(try XCTUnwrap(ApplicationBundleIdentifier("com.example.target")))
        await input.emit(try XCTUnwrap(NormalizedInputEvent.keyDown(control: key, generation: generation)))
        let intents = await service.intents
        XCTAssertTrue(intents.contains(.zoom(.out, steps: 1, application: try XCTUnwrap(ApplicationBundleIdentifier("com.example.target")))))
    }

    func testEditingAndStaleSessionSuppressNormalActions() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.zoom(.in)), appButton: .inherit)
        let service = RecordingActionService()
        let key = try key("fixture-button-1")
        let input = ManualInputProducer()
        let runtime = try await makeRuntime(configuration: fixture.configuration, service: service, foreground: MutableForeground(), input: input, mapping: [key: .button1])
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        await runtime.setConfigurationEditing(true)
        await input.emit(try XCTUnwrap(NormalizedInputEvent.keyDown(control: key, generation: generation)))
        await runtime.setConfigurationEditing(false)
        await input.emit(try XCTUnwrap(NormalizedInputEvent.keyDown(control: key, generation: SessionGeneration(generation.rawValue + 99))))
        let intents = await service.intents
        XCTAssertTrue(intents.isEmpty)
    }

    func testDialPressPersistsOrderedModeAndRestoresAfterStoreReload() async throws {
        let fixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            modePress: .primitive(.nextDialMode)
        )
        let files = MemoryConfigurationFiles()
        let url = URL(fileURLWithPath: "/virtual/action-runtime-\(UUID().uuidString).json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: files)
        try await store.save(fixture.configuration)
        let input = ManualInputProducer()
        let runtime = ActionRuntime(
            inputProducer: input,
            capabilities: FixtureCapabilities(),
            programmer: FixtureProgrammer(),
            foregroundApplication: MutableForeground(),
            controlMapping: FixtureMapping([:]),
            configurationStore: store,
            actionService: RecordingActionService()
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-dial", kind: .dial))
        let result = await runtime.dialPressed(control: dial, generation: generation)
        XCTAssertEqual(result.outcome, .modeChanged(
            profileID: fixture.configuration.defaultProfileID,
            modeID: fixture.secondModeID
        ))
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.selectedDialModeID, fixture.secondModeID)

        let reloadedStore = ConfigurationStore(primaryURL: url, fileAccess: files)
        let reloaded = try await reloadedStore.load()
        XCTAssertEqual(reloaded.defaultProfile.selectedDialMode.id, fixture.secondModeID)
        let deletedSelection = try reloaded.deletingDialMode(
            fixture.secondModeID,
            from: reloaded.defaultProfile.id
        )
        try await runtime.installConfiguration(deletedSelection)
        let fallbackSnapshot = await runtime.currentSnapshot()
        XCTAssertEqual(fallbackSnapshot.selectedDialModeID, fixture.firstModeID)
    }

    func testDialPressExecutesSelectedModePressAction() async throws {
        let shortcut = KeyboardChord(key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command])
        let actionFixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            modePress: .primitive(.keyboardShortcut(shortcut))
        )
        let service = RecordingActionService()
        let input = ManualInputProducer()
        let runtime = try await makeRuntime(
            configuration: actionFixture.configuration,
            service: service,
            foreground: MutableForeground(),
            input: input,
            mapping: [:]
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-dial", kind: .dial))

        let result = await runtime.dialPressed(control: dial, generation: generation)
        XCTAssertEqual(result.outcome, .acceptedUnverified)
        let actionSnapshot = await runtime.currentSnapshot()
        XCTAssertEqual(actionSnapshot.selectedDialModeID, actionFixture.firstModeID)
        let actionIntents = await service.intents
        XCTAssertEqual(actionIntents, [
            .keyboard(.down, .modifier(.command)),
            .keyboard(.down, .key(try XCTUnwrap(MacVirtualKeyCode(8)))),
            .keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8)))),
            .keyboard(.up, .modifier(.command)),
        ])

        let doNothingFixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            modePress: .primitive(.doNothing)
        )
        let noActionService = RecordingActionService()
        let noActionInput = ManualInputProducer()
        let noActionRuntime = try await makeRuntime(
            configuration: doNothingFixture.configuration,
            service: noActionService,
            foreground: MutableForeground(),
            input: noActionInput,
            mapping: [:]
        )
        _ = await noActionRuntime.submit(.start)
        let noActionGenerationValue = await noActionInput.currentGeneration
        let noActionGeneration = try XCTUnwrap(noActionGenerationValue)
        let noActionResult = await noActionRuntime.dialPressed(control: dial, generation: noActionGeneration)
        XCTAssertEqual(noActionResult.outcome, .ignored)
        let noActionIntents = await noActionService.intents
        XCTAssertTrue(noActionIntents.isEmpty)

        let heldPressFixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            modePress: .primitive(.holdKeys(shortcut))
        )
        let heldPressService = RecordingActionService()
        let heldPressInput = ManualInputProducer()
        let heldPressRuntime = try await makeRuntime(
            configuration: heldPressFixture.configuration,
            service: heldPressService,
            foreground: MutableForeground(),
            input: heldPressInput,
            mapping: [:]
        )
        _ = await heldPressRuntime.submit(.start)
        let heldPressGenerationValue = await heldPressInput.currentGeneration
        let heldPressGeneration = try XCTUnwrap(heldPressGenerationValue)
        let heldPressResult = await heldPressRuntime.dialPressed(control: dial, generation: heldPressGeneration)
        XCTAssertEqual(heldPressResult.outcome, .failed(.unsupportedAction("Hold Keys requires a physical key press")))
        let heldPressIntents = await heldPressService.intents
        XCTAssertTrue(heldPressIntents.isEmpty)
    }

    func testDialPressProtocolDispatchExecutesOnceAndSerializesWithInput() async throws {
        let shortcut = KeyboardChord(key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command])
        let fixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            modePress: .primitive(.keyboardShortcut(shortcut))
        )
        let service = RecordingActionService()
        let foreground = GatedForeground(value: nil)
        let input = ManualInputProducer()
        let keyControl = try key("fixture-button-1")
        let runtime = try await makeRuntime(
            configuration: fixture.configuration,
            service: service,
            foreground: foreground,
            input: input,
            mapping: [keyControl: .button1]
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-dial", kind: .dial))
        let consumer: any NormalizedInputConsumer = runtime

        await foreground.pauseNext()
        let keyDown = try XCTUnwrap(NormalizedInputEvent.keyDown(control: keyControl, generation: generation))
        let keyRouting = Task { await input.emit(keyDown) }
        await foreground.waitUntilEntered()

        // The normalized key route holds the input gate while the dial callback
        // is delivered through the consumer existential. Releasing the first
        // route must allow the callback to complete without reacquiring the gate.
        let pressing = Task { await consumer.dialPressed(control: dial, generation: generation) }
        await foreground.resume()
        await keyRouting.value
        let result = await pressing.value

        XCTAssertEqual(result.outcome, .acceptedUnverified)
        let expectedPress = [
            HostActionIntent.keyboard(.down, .modifier(.command)),
            .keyboard(.down, .key(try XCTUnwrap(MacVirtualKeyCode(8)))),
            .keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8)))),
            .keyboard(.up, .modifier(.command)),
        ]
        let pressIntents = await service.intents
        XCTAssertEqual(pressIntents, expectedPress)

        let invalidResult = await consumer.dialPressed(control: keyControl, generation: generation)
        XCTAssertEqual(invalidResult.outcome, .failed(.invalidInput))
        let intentsAfterInvalidControl = await service.intents
        XCTAssertEqual(intentsAfterInvalidControl, expectedPress, "A key-kind control must not run the configured dial press")
    }

    func testDialRotationDoesNotPersistModeAfterEditingDuringForegroundLookup() async throws {
        let fixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            clockwiseAction: .primitive(.nextDialMode)
        )
        let files = MemoryConfigurationFiles()
        let url = URL(fileURLWithPath: "/virtual/stale-rotation-\(UUID().uuidString).json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: files)
        try await store.save(fixture.configuration)
        let foreground = GatedForeground(value: nil)
        let input = ManualInputProducer()
        let service = RecordingActionService()
        let runtime = ActionRuntime(
            inputProducer: input,
            capabilities: FixtureCapabilities(),
            programmer: FixtureProgrammer(),
            foregroundApplication: foreground,
            controlMapping: FixtureMapping([:]),
            configurationStore: store,
            actionService: service
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-dial", kind: .dial))
        let rotation = try XCTUnwrap(NormalizedInputEvent.dialRotation(control: dial, delta: 1, generation: generation))
        await foreground.pauseNext()

        let routing = Task { await input.emit(rotation) }
        await foreground.waitUntilEntered()
        await runtime.setConfigurationEditing(true)
        await foreground.resume()
        await routing.value

        let reloaded = try await ConfigurationStore(primaryURL: url, fileAccess: files).load()
        XCTAssertEqual(reloaded.defaultProfile.selectedDialMode.id, fixture.firstModeID)
        let intents = await service.intents
        XCTAssertTrue(intents.isEmpty)
    }

    func testDialPressDoesNotPersistModeAfterStopDuringForegroundLookup() async throws {
        let fixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            modePress: .primitive(.nextDialMode)
        )
        let files = MemoryConfigurationFiles()
        let url = URL(fileURLWithPath: "/virtual/stale-dial-press-\(UUID().uuidString).json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: files)
        try await store.save(fixture.configuration)
        let foreground = GatedForeground(value: nil)
        let input = ManualInputProducer()
        let service = RecordingActionService()
        let runtime = ActionRuntime(
            inputProducer: input,
            capabilities: FixtureCapabilities(),
            programmer: FixtureProgrammer(),
            foregroundApplication: foreground,
            controlMapping: FixtureMapping([:]),
            configurationStore: store,
            actionService: service
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        let dial = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-dial", kind: .dial))
        await foreground.pauseNext()

        let pressing = Task { await runtime.dialPressed(control: dial, generation: generation) }
        await foreground.waitUntilEntered()
        _ = await runtime.submit(.stop)
        await foreground.resume()
        let result = await pressing.value

        XCTAssertEqual(result.outcome, .ignored)
        let reloaded = try await ConfigurationStore(primaryURL: url, fileAccess: files).load()
        XCTAssertEqual(reloaded.defaultProfile.selectedDialMode.id, fixture.firstModeID)
        let intents = await service.intents
        XCTAssertTrue(intents.isEmpty)
    }

    func testPermissionLossStopsSessionAndReleasesHeldInputs() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.holdKeys(KeyboardChord(
            key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command]
        ))), appButton: .inherit)
        let capabilities = MutableCapabilities(DeviceCapabilities(detection: .detected, access: .available))
        let service = RecordingActionService()
        let key = try key("fixture-button-1")
        let input = ManualInputProducer()
        let runtime = try await makeRuntime(
            configuration: fixture.configuration,
            service: service,
            foreground: MutableForeground(),
            input: input,
            mapping: [key: .button1],
            capabilities: capabilities
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        await input.emit(try XCTUnwrap(NormalizedInputEvent.keyDown(control: key, generation: generation)))
        await capabilities.set(DeviceCapabilities(detection: .detected, access: .denied(reason: "fixture permission revoked")))
        _ = await runtime.submit(.refreshCapabilities)

        let status = await runtime.currentStatus()
        XCTAssertEqual(status, .failed(.inputAccessDenied))
        let intents = await service.intents
        XCTAssertTrue(intents.contains(.keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8))))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.command))))
    }

    func testSessionReplacementIgnoresOldGenerationAndCleansOldPress() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.holdKeys(KeyboardChord(
            key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command]
        ))), appButton: .inherit)
        let service = RecordingActionService()
        let key = try key("fixture-button-1")
        let input = ManualInputProducer()
        let runtime = try await makeRuntime(configuration: fixture.configuration, service: service, foreground: MutableForeground(), input: input, mapping: [key: .button1])
        _ = await runtime.submit(.start)
        let firstGenerationValue = await input.currentGeneration
        let firstGeneration = try XCTUnwrap(firstGenerationValue)
        await input.emit(try XCTUnwrap(NormalizedInputEvent.keyDown(control: key, generation: firstGeneration)))
        _ = await runtime.submit(.start)
        let secondGenerationValue = await input.currentGeneration
        let secondGeneration = try XCTUnwrap(secondGenerationValue)
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        let afterReplacement = await service.intents
        XCTAssertTrue(afterReplacement.contains(.keyboard(.up, .modifier(.command))))
        XCTAssertEqual(count(.keyboard(.down, .modifier(.command)), in: afterReplacement), 1)

        await runtime.consume(try XCTUnwrap(NormalizedInputEvent.keyDown(control: key, generation: firstGeneration)))
        let afterStaleEvent = await service.intents
        XCTAssertEqual(count(.keyboard(.down, .modifier(.command)), in: afterStaleEvent), 1)
        _ = await runtime.submit(.stop)
    }

    func testDisconnectReleasesHeldInputsAndReportsFailure() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.holdKeys(KeyboardChord(
            key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command]
        ))), appButton: .inherit)
        let service = RecordingActionService()
        let key = try key("fixture-button-1")
        let input = ManualInputProducer()
        let runtime = try await makeRuntime(configuration: fixture.configuration, service: service, foreground: MutableForeground(), input: input, mapping: [key: .button1])
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        await input.emit(try XCTUnwrap(NormalizedInputEvent.keyDown(control: key, generation: generation)))
        await input.disconnect(reason: "fixture disconnect")
        let status = await runtime.currentStatus()
        XCTAssertEqual(status, .failed(.operationFailed(reason: "fixture disconnect")))
        let intents = await service.intents
        XCTAssertTrue(intents.contains(.keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8))))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.command))))
    }

    func testKeyDownAndKeyUpBurstsRetainEveryTransition() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.holdKeys(KeyboardChord(
            key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command]
        ))), appButton: .inherit)
        let service = RecordingActionService()
        let key = try key("fixture-button-1")
        let input = ManualInputProducer()
        let runtime = try await makeRuntime(configuration: fixture.configuration, service: service, foreground: MutableForeground(), input: input, mapping: [key: .button1])
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        for _ in 0..<2 {
            await input.emit(try XCTUnwrap(NormalizedInputEvent.keyDown(control: key, generation: generation)))
            await input.emit(try XCTUnwrap(NormalizedInputEvent.keyUp(control: key, generation: generation)))
        }
        let intents = await service.intents
        XCTAssertEqual(count(.keyboard(.down, .key(try XCTUnwrap(MacVirtualKeyCode(8)))), in: intents), 2)
        XCTAssertEqual(count(.keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8)))), in: intents), 2)
    }

    func testForegroundContextChangeReleasesHeldInputAndInvalidatesPendingRoute() async throws {
        let chord = KeyboardChord(key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command])
        let fixture = try makeConfiguration(defaultButton: .primitive(.holdKeys(chord)), appButton: .inherit)
        let service = RecordingActionService()
        let foreground = GatedForeground(value: nil)
        let input = ManualInputProducer()
        let firstKey = try key("fixture-button-1")
        let pendingKey = try key("fixture-button-2")
        let runtime = try await makeRuntime(
            configuration: fixture.configuration,
            service: service,
            foreground: foreground,
            input: input,
            mapping: [firstKey: .button1, pendingKey: .button1]
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)

        await input.emit(try XCTUnwrap(NormalizedInputEvent.keyDown(control: firstKey, generation: generation)))
        await foreground.pauseNext()
        let pendingEvent = try XCTUnwrap(NormalizedInputEvent.keyDown(control: pendingKey, generation: generation))
        let staleRoute = Task {
            await input.emit(pendingEvent)
        }
        await foreground.waitUntilEntered()
        await runtime.foregroundContextDidChange()
        let cleanedBeforeRouteResumed = await service.intents
        XCTAssertEqual(count(.keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8)))), in: cleanedBeforeRouteResumed), 1)
        XCTAssertEqual(count(.keyboard(.up, .modifier(.command)), in: cleanedBeforeRouteResumed), 1)
        await foreground.resume()
        await staleRoute.value

        let intents = await service.intents
        XCTAssertEqual(count(.keyboard(.down, .key(try XCTUnwrap(MacVirtualKeyCode(8)))), in: intents), 1)
        XCTAssertEqual(count(.keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8)))), in: intents), 1)
        XCTAssertEqual(count(.keyboard(.down, .modifier(.command)), in: intents), 1)
        XCTAssertEqual(count(.keyboard(.up, .modifier(.command)), in: intents), 1)
        XCTAssertEqual(intents.count, 4, "The route paused across a focus invalidation must not dispatch")
    }

    func testPressCapturedBeforeFocusChangeIsDroppedWhenDeliveredAfterward() async throws {
        let fixture = try makeConfiguration(
            defaultButton: .primitive(.zoom(.in)),
            appButton: .inherit
        )
        let service = RecordingActionService()
        let key = try key("fixture-button-1")
        let input = ManualInputProducer()
        let runtime = try await makeRuntime(
            configuration: fixture.configuration,
            service: service,
            foreground: MutableForeground(),
            input: input,
            mapping: [key: .button1]
        )
        _ = await runtime.submit(.start)

        let capturedBeforeFocusChangeValue = await input.captureKeyDown(control: key)
        let capturedBeforeFocusChange = try XCTUnwrap(capturedBeforeFocusChangeValue)
        XCTAssertEqual(capturedBeforeFocusChange.focusEpoch, .initial)
        await runtime.foregroundContextDidChange()
        await input.emit(capturedBeforeFocusChange)

        let intents = await service.intents
        XCTAssertTrue(intents.isEmpty, "A pre-focus press delivered afterward must be dropped")
        _ = await runtime.submit(.stop)
    }

    func testHeldKeyIsReleasedAcrossFocusChangeAndStaleRepeatIsNotRefired() async throws {
        let chord = KeyboardChord(key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command])
        let fixture = try makeConfiguration(defaultButton: .primitive(.holdKeys(chord)), appButton: .inherit)
        let service = RecordingActionService()
        let key = try key("fixture-button-1")
        let input = ManualInputProducer()
        let runtime = try await makeRuntime(
            configuration: fixture.configuration,
            service: service,
            foreground: MutableForeground(),
            input: input,
            mapping: [key: .button1]
        )
        _ = await runtime.submit(.start)

        let heldPress = await input.captureKeyDown(control: key)
        await input.emit(try XCTUnwrap(heldPress))
        let repeatedPressValue = await input.captureKeyDown(control: key)
        let repeatedPressCapturedBeforeFocus = try XCTUnwrap(repeatedPressValue)
        await runtime.foregroundContextDidChange()
        await input.emit(repeatedPressCapturedBeforeFocus)

        let intents = await service.intents
        let heldKey = try XCTUnwrap(MacVirtualKeyCode(8))
        XCTAssertEqual(count(.keyboard(.down, .key(heldKey)), in: intents), 1)
        XCTAssertEqual(count(.keyboard(.up, .key(heldKey)), in: intents), 1)
        XCTAssertEqual(count(.keyboard(.down, .modifier(.command)), in: intents), 1)
        XCTAssertEqual(count(.keyboard(.up, .modifier(.command)), in: intents), 1)
        _ = await runtime.submit(.stop)
    }

    func testBurstSpanningFocusChangeDispatchesOnlyEventsCapturedInCurrentEpoch() async throws {
        let fixture = try makeConfiguration(
            defaultButton: .primitive(.zoom(.in)),
            appButton: .inherit
        )
        let service = RecordingActionService()
        let key = try key("fixture-button-1")
        let input = ManualInputProducer()
        let runtime = try await makeRuntime(
            configuration: fixture.configuration,
            service: service,
            foreground: MutableForeground(),
            input: input,
            mapping: [key: .button1]
        )
        _ = await runtime.submit(.start)

        var beforeFocus: [NormalizedInputEvent] = []
        for _ in 0..<12 {
            let capturedDown = await input.captureKeyDown(control: key)
            let capturedUp = await input.captureKeyUp(control: key)
            beforeFocus.append(try XCTUnwrap(capturedDown))
            beforeFocus.append(try XCTUnwrap(capturedUp))
        }
        await runtime.foregroundContextDidChange()
        var afterFocus: [NormalizedInputEvent] = []
        for _ in 0..<12 {
            let capturedDown = await input.captureKeyDown(control: key)
            let capturedUp = await input.captureKeyUp(control: key)
            afterFocus.append(try XCTUnwrap(capturedDown))
            afterFocus.append(try XCTUnwrap(capturedUp))
        }
        XCTAssertTrue(beforeFocus.allSatisfy { $0.focusEpoch == .initial })
        XCTAssertTrue(afterFocus.allSatisfy { $0.focusEpoch == FocusEpoch(1) })

        for event in beforeFocus { await input.emit(event) }
        for event in afterFocus { await input.emit(event) }

        let intents = await service.intents
        XCTAssertEqual(intents.filter { $0 == .zoom(.in, steps: 1, application: nil) }.count, 12)
        _ = await runtime.submit(.stop)
    }

    func testForegroundInvalidationDoesNotWaitOnInputOrConfigurationMutationGates() async throws {
        let chord = KeyboardChord(key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command])
        let fixture = try makeConfiguration(defaultButton: .primitive(.holdKeys(chord)), appButton: .inherit)
        let files = GatedBackupConfigurationFiles()
        let store = ConfigurationStore(
            primaryURL: URL(fileURLWithPath: "/virtual/focus-gates-\(UUID().uuidString).json"),
            fileAccess: files
        )
        try await store.save(fixture.configuration)
        files.blockNextBackupWrite()

        let service = RecordingActionService()
        let foreground = GatedForeground(value: nil)
        let input = ManualInputProducer()
        let firstKey = try key("fixture-button-1")
        let pendingKey = try key("fixture-button-2")
        let runtime = ActionRuntime(
            inputProducer: input,
            capabilities: FixtureCapabilities(),
            programmer: FixtureProgrammer(),
            foregroundApplication: foreground,
            controlMapping: FixtureMapping([firstKey: .button1, pendingKey: .button1]),
            configurationStore: store,
            actionService: service
        )
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        await input.emit(try XCTUnwrap(NormalizedInputEvent.keyDown(control: firstKey, generation: generation)))

        await foreground.pauseNext()
        let pendingEvent = try XCTUnwrap(NormalizedInputEvent.keyDown(control: pendingKey, generation: generation))
        let staleRoute = Task { await input.emit(pendingEvent) }
        await foreground.waitUntilEntered()

        let mutation = Task { try await runtime.installConfiguration(fixture.configuration) }
        let backupWriteBlocked = files.waitForBlockedBackup()
        XCTAssertTrue(backupWriteBlocked, "Configuration mutation should reach its injected backup-write gate")
        let focusInvalidationFinished = AsyncTestFlag()
        let invalidation = Task {
            await runtime.foregroundContextDidChange()
            await focusInvalidationFinished.mark()
        }
        try await Task.sleep(for: .milliseconds(40))
        let invalidationCompletedWhileBothGatesWereHeld = await focusInvalidationFinished.isMarked
        XCTAssertTrue(invalidationCompletedWhileBothGatesWereHeld)
        let cleanupIntents = await service.intents
        XCTAssertTrue(cleanupIntents.contains(.keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8))))))
        XCTAssertTrue(cleanupIntents.contains(.keyboard(.up, .modifier(.command))))

        files.releaseBlockedBackup()
        try await mutation.value
        await invalidation.value
        await foreground.resume()
        await staleRoute.value

        let finalIntents = await service.intents
        XCTAssertEqual(count(.keyboard(.down, .key(try XCTUnwrap(MacVirtualKeyCode(8)))), in: finalIntents), 1)
        XCTAssertEqual(count(.keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8)))), in: finalIntents), 1)
        XCTAssertEqual(finalIntents.count, 4, "A route invalidated across both gates must not dispatch")
    }

    func testRuntimeMeasurementHarnessSeparatesDispatchServiceAndSequenceTiming() async throws {
        let application = try XCTUnwrap(ApplicationBundleIdentifier("com.example.measurement"))
        let sequence = try ActionSequence(steps: [
            .action(.openApplication(application)),
            .pause(milliseconds: 2),
            .action(.scroll(axis: .horizontal, speed: try XCTUnwrap(ScrollSpeed(2)))),
        ])
        let fixture = try makeConfiguration(
            defaultButton: .primitive(.doNothing),
            appButton: .inherit,
            clockwiseAction: .sequence(sequence)
        )
        func makeRuntimeForWorkload(
            service: any HostActionServicing
        ) async throws -> (ActionRuntime, ManualInputProducer, RuntimeMeasurementRecorder, NormalizedInputEvent) {
            let input = ManualInputProducer()
            let metrics = RuntimeMeasurementRecorder(capacity: 1_024)
            let runtime = try await makeRuntime(
                configuration: fixture.configuration,
                service: service,
                foreground: MutableForeground(),
                input: input,
                mapping: [:],
                measurementRecorder: metrics
            )
            _ = await runtime.submit(.start)
            let generationValue = await input.currentGeneration
            let generation = try XCTUnwrap(generationValue)
            let dial = try XCTUnwrap(PhysicalControlID(rawValue: "fixture-dial", kind: .dial))
            let event = try XCTUnwrap(NormalizedInputEvent.dialRotation(control: dial, delta: 1, generation: generation))
            return (runtime, input, metrics, event)
        }
        func runNormalWorkload() async throws -> (RuntimeTimingSnapshot, RuntimeMeasurementRecorder, any HostActionServicing) {
            let service = RecordingActionService()
            let (runtime, input, metrics, event) = try await makeRuntimeForWorkload(service: service)
            for index in 0..<50 {
                await input.emit(event)
                if index < 49 { try await Task.sleep(for: .milliseconds(10)) }
            }
            let snapshot = metrics.snapshot()
            _ = await runtime.submit(.stop)
            return (snapshot, metrics, service)
        }
        func runBurstWorkload() async throws -> (RuntimeTimingSnapshot, RuntimeMeasurementRecorder, any HostActionServicing) {
            let service = FirstCallBarrierActionService()
            let (runtime, input, metrics, event) = try await makeRuntimeForWorkload(service: service)
            var deliveries: [Task<Void, Never>] = [await input.enqueue(event)]
            let firstActionReachedBarrier = await service.waitUntilFirstCallEntered()
            XCTAssertTrue(firstActionReachedBarrier, "First event must be suspended in its service call")

            for _ in 1..<50 {
                deliveries.append(await input.enqueue(event))
            }
            let receiptDeadline = ContinuousClock.now + .seconds(3)
            while metrics.eventReceiptCount < 50 && ContinuousClock.now < receiptDeadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertEqual(metrics.eventReceiptCount, 50, "All burst events must enter the runtime while the first action is suspended")
            XCTAssertEqual(
                metrics.snapshot().percentiles(for: .receiptToDispatch, inputClass: .dialRotation).count,
                1,
                "The remaining events must still be queued before releasing the first action"
            )

            await service.releaseFirstCall()
            for delivery in deliveries { await delivery.value }
            let snapshot = metrics.snapshot()
            _ = await runtime.submit(.stop)
            return (snapshot, metrics, service)
        }
        func runKnobSpinWorkload() async throws -> (RuntimeTimingSnapshot, RuntimeMeasurementRecorder, any HostActionServicing) {
            let service = RecordingActionService()
            let (runtime, input, metrics, event) = try await makeRuntimeForWorkload(service: service)
            let clock = ContinuousClock()
            let start = clock.now
            var deliveries: [Task<Void, Never>] = []
            for index in 0..<40 {
                let scheduledAt = start + .milliseconds(index * 50)
                let now = clock.now
                if now < scheduledAt {
                    try await Task.sleep(for: now.duration(to: scheduledAt))
                }
                deliveries.append(await input.enqueue(event))
            }
            for delivery in deliveries { await delivery.value }
            let snapshot = metrics.snapshot()
            _ = await runtime.submit(.stop)
            return (snapshot, metrics, service)
        }
        func timingLine(_ name: String, _ snapshot: RuntimeTimingSnapshot) -> String {
            let dispatch = snapshot.percentiles(for: .receiptToDispatch, inputClass: .dialRotation)
            let queueWait = snapshot.percentiles(for: .inputQueueWait, inputClass: .dialRotation)
            let routing = snapshot.percentiles(for: .preDispatchRouting, inputClass: .dialRotation)
            let handling = snapshot.percentiles(for: .eventHandling, inputClass: .dialRotation)
            let adapter = snapshot.percentiles(for: .serviceCall, inputClass: .dialRotation)
            let sequenceActions = snapshot.percentiles(for: .sequenceAction, inputClass: .dialRotation)
            let sequencePauses = snapshot.percentiles(for: .sequencePause, inputClass: .dialRotation)
            let dispatches = snapshot.dispatchDecompositions.filter { $0.inputClass == .dialRotation }
            let slowestDispatch = dispatches.max { $0.receiptToDispatchNanoseconds < $1.receiptToDispatchNanoseconds }
            return "SIMULATED_RUNTIME_METRICS workload=\(name) events=\(dispatch.count) " +
                "dispatch_ms_p50=\(Double(dispatch.p50Nanoseconds) / 1_000_000) " +
                "p95=\(Double(dispatch.p95Nanoseconds) / 1_000_000) p99=\(Double(dispatch.p99Nanoseconds) / 1_000_000) " +
                "max=\(Double(dispatch.maximumNanoseconds) / 1_000_000) under_50ms=\(dispatch.maximumNanoseconds < 50_000_000) " +
                "queue_wait_ms_p50=\(Double(queueWait.p50Nanoseconds) / 1_000_000) " +
                "p95=\(Double(queueWait.p95Nanoseconds) / 1_000_000) max=\(Double(queueWait.maximumNanoseconds) / 1_000_000) " +
                "pre_dispatch_routing_ms_p50=\(Double(routing.p50Nanoseconds) / 1_000_000) " +
                "p95=\(Double(routing.p95Nanoseconds) / 1_000_000) max=\(Double(routing.maximumNanoseconds) / 1_000_000) " +
                "event_handling_ms_p50=\(Double(handling.p50Nanoseconds) / 1_000_000) " +
                "p95=\(Double(handling.p95Nanoseconds) / 1_000_000) max=\(Double(handling.maximumNanoseconds) / 1_000_000) " +
                "slowest_dispatch_queue_ms=\(Double(slowestDispatch?.inputQueueWaitNanoseconds ?? 0) / 1_000_000) " +
                "slowest_dispatch_routing_ms=\(Double(slowestDispatch?.preDispatchRoutingNanoseconds ?? 0) / 1_000_000) " +
                "slowest_dispatch_total_ms=\(Double(slowestDispatch?.receiptToDispatchNanoseconds ?? 0) / 1_000_000) " +
                "service_call_ms_p50=\(Double(adapter.p50Nanoseconds) / 1_000_000) " +
                "p95=\(Double(adapter.p95Nanoseconds) / 1_000_000) p99=\(Double(adapter.p99Nanoseconds) / 1_000_000) " +
                "max=\(Double(adapter.maximumNanoseconds) / 1_000_000) " +
                "sequence_action_ms_p50=\(Double(sequenceActions.p50Nanoseconds) / 1_000_000) " +
                "p95=\(Double(sequenceActions.p95Nanoseconds) / 1_000_000) p99=\(Double(sequenceActions.p99Nanoseconds) / 1_000_000) " +
                "max=\(Double(sequenceActions.maximumNanoseconds) / 1_000_000) " +
                "sequence_pause_ms_p50=\(Double(sequencePauses.p50Nanoseconds) / 1_000_000) " +
                "p95=\(Double(sequencePauses.p95Nanoseconds) / 1_000_000) p99=\(Double(sequencePauses.p99Nanoseconds) / 1_000_000) " +
                "max=\(Double(sequencePauses.maximumNanoseconds) / 1_000_000)"
        }

        let normal = try await runNormalWorkload()
        let burst = try await runBurstWorkload()
        let knobSpin = try await runKnobSpinWorkload()
        for (snapshot, expectedEvents) in [(normal.0, 50), (burst.0, 50), (knobSpin.0, 40)] {
            let dispatch = snapshot.percentiles(for: .receiptToDispatch, inputClass: .dialRotation)
            let queueWait = snapshot.percentiles(for: .inputQueueWait, inputClass: .dialRotation)
            let routing = snapshot.percentiles(for: .preDispatchRouting, inputClass: .dialRotation)
            let handling = snapshot.percentiles(for: .eventHandling, inputClass: .dialRotation)
            let adapter = snapshot.percentiles(for: .serviceCall, inputClass: .dialRotation)
            let sequenceActions = snapshot.percentiles(for: .sequenceAction, inputClass: .dialRotation)
            let sequencePauses = snapshot.percentiles(for: .sequencePause, inputClass: .dialRotation)
            XCTAssertEqual(dispatch.count, expectedEvents)
            XCTAssertEqual(queueWait.count, expectedEvents)
            XCTAssertEqual(routing.count, expectedEvents)
            XCTAssertEqual(handling.count, expectedEvents)
            XCTAssertEqual(adapter.count, expectedEvents * 2)
            XCTAssertEqual(sequenceActions.count, expectedEvents * 2)
            XCTAssertEqual(sequencePauses.count, expectedEvents)
            XCTAssertEqual(snapshot.dispatchDecompositions.count, expectedEvents)
            for decomposition in snapshot.dispatchDecompositions {
                let componentSum = decomposition.inputQueueWaitNanoseconds
                    + decomposition.preDispatchRoutingNanoseconds
                let roundingDifference = componentSum > decomposition.receiptToDispatchNanoseconds
                    ? componentSum - decomposition.receiptToDispatchNanoseconds
                    : decomposition.receiptToDispatchNanoseconds - componentSum
                XCTAssertLessThanOrEqual(roundingDifference, 2, "Each dispatch sample must decompose into queue wait plus routing")
            }
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            XCTAssertTrue(snapshot.samples.allSatisfy { $0.durationNanoseconds < 10_000_000_000 })
        }
        print(timingLine("normal-spaced-10ms", normal.0))
        print(timingLine("burst-no-gap", burst.0))
        print(timingLine("rapid-knob-spin-20hz", knobSpin.0))
        let independentExecutor = HostActionExecutor(service: burst.2)
        _ = await independentExecutor.executeDialAction(
            .primitive(.openApplication(application)),
            profileID: fixture.configuration.defaultProfile.id,
            dialMagnitude: 1,
            advanceMode: noModeChange,
            admissionRevision: 0
        )
        XCTAssertEqual(burst.1.snapshot().samples.count, burst.0.samples.count, "A standalone executor task must not inherit runtime event attribution")
    }

    func testLifecycleStopReleasesRuntimeOwnedInputs() async throws {
        let fixture = try makeConfiguration(defaultButton: .primitive(.holdKeys(KeyboardChord(
            key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command]
        ))), appButton: .inherit)
        let service = RecordingActionService()
        let key = try key("fixture-button-1")
        let input = ManualInputProducer()
        let runtime = try await makeRuntime(configuration: fixture.configuration, service: service, foreground: MutableForeground(), input: input, mapping: [key: .button1])
        _ = await runtime.submit(.start)
        let generationValue = await input.currentGeneration
        let generation = try XCTUnwrap(generationValue)
        await input.emit(try XCTUnwrap(NormalizedInputEvent.keyDown(control: key, generation: generation)))
        _ = await runtime.submit(.stop)
        let status = await runtime.currentStatus()
        XCTAssertEqual(status, .idle)
        let intents = await service.intents
        XCTAssertTrue(intents.contains(.keyboard(.up, .key(try XCTUnwrap(MacVirtualKeyCode(8))))))
        XCTAssertTrue(intents.contains(.keyboard(.up, .modifier(.command))))
    }

    private func makeRuntime(
        configuration: Configuration,
        service: any HostActionServicing,
        foreground: any ForegroundApplicationProviding,
        input: ManualInputProducer,
        mapping: [PhysicalControlID: ActionAssignmentTarget],
        capabilities: any DeviceCapabilityProviding = FixtureCapabilities(),
        lightingProgrammer: (any DeviceLightingProgramming)? = nil,
        keyAssignmentProgrammer: (any DeviceKeyAssignmentProgramming)? = nil,
        measurementRecorder: RuntimeMeasurementRecorder? = nil
    ) async throws -> ActionRuntime {
        let url = URL(fileURLWithPath: "/virtual/action-runtime-\(UUID().uuidString).json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: MemoryConfigurationFiles())
        try await store.save(configuration)
        return ActionRuntime(
            inputProducer: input,
            capabilities: capabilities,
            programmer: FixtureProgrammer(),
            foregroundApplication: foreground,
            controlMapping: FixtureMapping(mapping),
            configurationStore: store,
            actionService: service,
            executionLimits: ActionExecutionLimits(perActionTimeout: .seconds(1), sequenceDeadline: .seconds(2)),
            lightingProgrammer: lightingProgrammer,
            keyAssignmentProgrammer: keyAssignmentProgrammer,
            measurementRecorder: measurementRecorder
        )
    }

    private func makeConfiguration(
        defaultButton: ConfiguredAction,
        appButton: ActionOverride,
        modePress: ConfiguredAction = .primitive(.doNothing),
        clockwiseAction: ConfiguredAction = .primitive(.zoom(.in)),
        counterclockwiseAction: ConfiguredAction = .primitive(.zoom(.out))
    ) throws -> (configuration: Configuration, firstModeID: DialModeID, secondModeID: DialModeID, appSecondModeID: DialModeID) {
        let defaultID = ProfileID()
        let appID = ProfileID()
        let firstModeID = DialModeID()
        let secondModeID = DialModeID()
        let appModeID = DialModeID()
        let appSecondModeID = DialModeID()
        func mode(_ id: DialModeID, _ name: String) -> DialMode {
            DialMode(
                id: id,
                name: DisplayName(name)!,
                counterclockwise: counterclockwiseAction,
                clockwise: clockwiseAction,
                press: modePress
            )
        }
        let defaultProfile = try Profile(
            id: defaultID,
            name: DisplayName("Default")!,
            scope: .default,
            assignments: [.button1: .set(defaultButton)],
            dialModes: [mode(firstModeID, "First"), mode(secondModeID, "Second")],
            defaultDialModeID: firstModeID
        )
        let appProfile = try Profile(
            id: appID,
            name: DisplayName("Target")!,
            scope: .application(try XCTUnwrap(ApplicationBundleIdentifier("com.example.target"))),
            assignments: [.button1: appButton],
            dialModes: [mode(appModeID, "Target A"), mode(appSecondModeID, "Target B")],
            defaultDialModeID: appModeID
        )
        return (
            try Configuration(defaultProfileID: defaultID, profiles: [defaultProfile, appProfile]),
            firstModeID,
            secondModeID,
            appSecondModeID
        )
    }

    private func key(_ raw: String) throws -> PhysicalControlID {
        try XCTUnwrap(PhysicalControlID(rawValue: raw, kind: .key))
    }

    private func runSequenceCancelledDuringCleanup(useKeyDown: Bool) async throws -> ActionExecutionResult {
        let keyCode = try XCTUnwrap(MacVirtualKeyCode(8))
        let control = try key("fixture-cancelled-deadline-key")
        let sequence = try ActionSequence(steps: [
            .action(.holdKeys(KeyboardChord(key: keyCode, modifiers: []))),
            .pause(milliseconds: 1_000),
        ])
        let cleanupGate = CancellationGate()
        let service = GatedCleanupActionService(gate: cleanupGate)
        let executor = HostActionExecutor(
            service: service,
            limits: ActionExecutionLimits(
                perActionTimeout: .seconds(2),
                sequenceDeadline: .milliseconds(70)
            )
        )
        let action: Task<ActionExecutionResult, Never>
        if useKeyDown {
            action = Task {
                await executor.keyDown(
                    control: control,
                    generation: SessionGeneration(3),
                    action: .sequence(sequence),
                    profileID: ProfileID(),
                    advanceMode: noModeChange,
                    admissionRevision: 0
                )
            }
        } else {
            action = Task {
                await executor.executeDialAction(
                    .sequence(sequence),
                    profileID: ProfileID(),
                    dialMagnitude: 1,
                    advanceMode: noModeChange,
                    admissionRevision: 0
                )
            }
        }

        let cleanupStarted = await cleanupGate.waitUntilEntered()
        XCTAssertTrue(cleanupStarted, "Deadline failure should reach the gated key-up cleanup")
        guard cleanupStarted else {
            await cleanupGate.release()
            return await action.value
        }
        let cleanup = Task { await executor.cancelAndRelease(floor: 1) }
        let cancellationReachedChild = await cleanupGate.waitUntilCancelled()
        XCTAssertTrue(cancellationReachedChild, "Explicit cancellation should arrive while the expired sequence is cleaning up")
        await cleanupGate.release()
        let result = await action.value
        _ = await cleanup.value
        return result
    }

    private func count(_ intent: HostActionIntent, in intents: [HostActionIntent]) -> Int {
        intents.filter { $0 == intent }.count
    }
}

private let noModeChange: @Sendable (ProfileID) async -> DialModeAdvanceResult = {
    _ in .failed(.modePersistenceFailed("Unexpected mode advance in fixture"))
}

private actor RecordingActionService: HostActionServicing {
    private(set) var intents: [HostActionIntent] = []
    private(set) var timestamps: [ContinuousClock.Instant] = []
    private let result: HostActionServiceResult
    private let delay: Duration
    private let delayedIntent: HostActionIntent?

    init(
        result: HostActionServiceResult = .acceptedUnverified,
        delay: Duration = .zero,
        delayedIntent: HostActionIntent? = nil
    ) {
        self.result = result
        self.delay = delay
        self.delayedIntent = delayedIntent
    }

    func perform(_ intent: HostActionIntent) async -> HostActionServiceResult {
        if delay > .zero && (delayedIntent == nil || delayedIntent == intent) {
            do { try await Task.sleep(for: delay) } catch { return .failed(reason: "cancelled by timeout fixture") }
        }
        intents.append(intent)
        timestamps.append(.now)
        return result
    }
}

private actor FirstCallBarrierActionService: HostActionServicing {
    private let gate = CancellationGate()
    private var didBlockFirstCall = false

    func waitUntilFirstCallEntered() async -> Bool {
        await gate.waitUntilEntered()
    }

    func releaseFirstCall() async {
        await gate.release()
    }

    func perform(_ intent: HostActionIntent) async -> HostActionServiceResult {
        if !didBlockFirstCall {
            didBlockFirstCall = true
            await gate.suspend()
        }
        return .acceptedUnverified
    }
}

private actor LateAcceptedKeyDownActionService: HostActionServicing {
    private let gatedDown: HostActionIntent
    private let gate = CancellationGate()
    private(set) var intents: [HostActionIntent] = []

    init(gatedDown: HostActionIntent) {
        self.gatedDown = gatedDown
    }

    func waitUntilDownStarted() async -> Bool {
        await gate.waitUntilEntered()
    }

    func waitUntilCancellationObserved() async -> Bool {
        await gate.waitUntilCancelled()
    }

    func releaseDown() async {
        await gate.release()
    }

    func perform(_ intent: HostActionIntent) async -> HostActionServiceResult {
        intents.append(intent)
        if intent == gatedDown { await gate.suspend() }
        return .acceptedUnverified
    }
}

private actor CancellationHoldingModeAdvance {
    private var advanceContinuation: CheckedContinuation<DialModeAdvanceResult, Never>?
    private var startedContinuation: CheckedContinuation<Bool, Never>?
    private var cancellationContinuation: CheckedContinuation<Bool, Never>?
    private var startedWatchdog: Task<Void, Never>?
    private var cancellationWatchdog: Task<Void, Never>?
    private var didStart = false
    private var didObserveCancellation = false

    func waitUntilStarted() async -> Bool {
        if didStart { return true }
        return await withCheckedContinuation { continuation in
            startedContinuation = continuation
            startedWatchdog = Task {
                try? await Task.sleep(for: .seconds(3))
                self.expireStartedWait()
            }
        }
    }

    func waitUntilCancellationObserved() async -> Bool {
        if didObserveCancellation { return true }
        return await withCheckedContinuation { continuation in
            cancellationContinuation = continuation
            cancellationWatchdog = Task {
                try? await Task.sleep(for: .seconds(3))
                self.expireCancellationWait()
            }
        }
    }

    func advance() async -> DialModeAdvanceResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                advanceContinuation = continuation
                didStart = true
                startedWatchdog?.cancel()
                startedWatchdog = nil
                startedContinuation?.resume(returning: true)
                startedContinuation = nil
            }
        } onCancel: {
            Task { await self.noteCancellation() }
        }
    }

    func releaseWithCancellation() {
        let continuation = advanceContinuation
        advanceContinuation = nil
        continuation?.resume(returning: .failed(.cancelled))
    }

    private func noteCancellation() {
        didObserveCancellation = true
        cancellationWatchdog?.cancel()
        cancellationWatchdog = nil
        let continuation = cancellationContinuation
        cancellationContinuation = nil
        continuation?.resume(returning: true)
    }

    private func expireStartedWait() {
        let continuation = startedContinuation
        startedContinuation = nil
        startedWatchdog = nil
        continuation?.resume(returning: false)
    }

    private func expireCancellationWait() {
        let continuation = cancellationContinuation
        cancellationContinuation = nil
        cancellationWatchdog = nil
        continuation?.resume(returning: false)
    }
}

private actor CancellationAwareGatedActionService: HostActionServicing {
    private let delayedIntent: HostActionIntent
    private var delayedContinuation: CheckedContinuation<HostActionServiceResult, Never>?
    private var enteredContinuation: CheckedContinuation<Bool, Never>?
    private var entryWatchdog: Task<Void, Never>?
    private var didEnterDelayedAction = false
    private(set) var startedCallCount = 0
    private(set) var callStartTimes: [ContinuousClock.Instant] = []
    private(set) var didObserveCancellation = false
    private(set) var completedIntents: [HostActionIntent] = []

    init(delayedIntent: HostActionIntent) {
        self.delayedIntent = delayedIntent
    }

    func waitUntilDelayedActionEntered() async -> Bool {
        if didEnterDelayedAction { return true }
        return await withCheckedContinuation { continuation in
            enteredContinuation = continuation
            entryWatchdog = Task {
                try? await Task.sleep(for: .seconds(3))
                self.expireEntryWait()
            }
        }
    }

    func perform(_ intent: HostActionIntent) async -> HostActionServiceResult {
        startedCallCount += 1
        callStartTimes.append(.now)
        guard intent == delayedIntent else {
            completedIntents.append(intent)
            return .acceptedUnverified
        }

        let watchdog = Task {
            try? await Task.sleep(for: .seconds(3))
            self.expireDelayedAction()
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                delayedContinuation = continuation
                didEnterDelayedAction = true
                entryWatchdog?.cancel()
                entryWatchdog = nil
                enteredContinuation?.resume(returning: true)
                enteredContinuation = nil
            }
        } onCancel: {
            Task { await self.cancelDelayedAction() }
        }
        watchdog.cancel()
        return result
    }

    private func cancelDelayedAction() {
        didObserveCancellation = true
        finishDelayedAction(.failed(reason: "cancelled by configuration replacement"))
    }

    private func expireDelayedAction() {
        finishDelayedAction(.failed(reason: "service gate expired"))
    }

    private func finishDelayedAction(_ result: HostActionServiceResult) {
        let continuation = delayedContinuation
        delayedContinuation = nil
        continuation?.resume(returning: result)
    }

    private func expireEntryWait() {
        let continuation = enteredContinuation
        enteredContinuation = nil
        entryWatchdog = nil
        continuation?.resume(returning: false)
    }
}

private actor AsyncTestFlag {
    private(set) var isMarked = false
    func mark() { isMarked = true }
}

private actor CancellationGate {
    private var operationContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Bool, Never>?
    private var cancelledContinuation: CheckedContinuation<Bool, Never>?
    private var enteredWatchdog: Task<Void, Never>?
    private var cancelledWatchdog: Task<Void, Never>?
    private var didEnter = false
    private var didCancel = false

    func suspend() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operationContinuation = continuation
                didEnter = true
                enteredWatchdog?.cancel()
                enteredWatchdog = nil
                enteredContinuation?.resume(returning: true)
                enteredContinuation = nil
            }
        } onCancel: {
            Task { await self.noteCancellation() }
        }
    }

    func waitUntilEntered() async -> Bool {
        if didEnter { return true }
        return await withCheckedContinuation { continuation in
            enteredContinuation = continuation
            enteredWatchdog = Task {
                try? await Task.sleep(for: .seconds(3))
                self.expireEnteredWait()
            }
        }
    }

    func waitUntilCancelled() async -> Bool {
        if didCancel { return true }
        return await withCheckedContinuation { continuation in
            cancelledContinuation = continuation
            cancelledWatchdog = Task {
                try? await Task.sleep(for: .seconds(3))
                self.expireCancelledWait()
            }
        }
    }

    func release() {
        let continuation = operationContinuation
        operationContinuation = nil
        continuation?.resume()
    }

    private func noteCancellation() {
        didCancel = true
        cancelledWatchdog?.cancel()
        cancelledWatchdog = nil
        let continuation = cancelledContinuation
        cancelledContinuation = nil
        continuation?.resume(returning: true)
    }

    private func expireEnteredWait() {
        let continuation = enteredContinuation
        enteredContinuation = nil
        enteredWatchdog = nil
        continuation?.resume(returning: false)
    }

    private func expireCancelledWait() {
        let continuation = cancelledContinuation
        cancelledContinuation = nil
        cancelledWatchdog = nil
        continuation?.resume(returning: false)
    }
}

private actor GatedCleanupActionService: HostActionServicing {
    private let gate: CancellationGate
    private let failingApplication: ApplicationBundleIdentifier?
    private var gateNextKeyUp = true

    init(gate: CancellationGate, failingApplication: ApplicationBundleIdentifier? = nil) {
        self.gate = gate
        self.failingApplication = failingApplication
    }

    func perform(_ intent: HostActionIntent) async -> HostActionServiceResult {
        if case .keyboard(.up, .key) = intent, gateNextKeyUp {
            gateNextKeyUp = false
            await gate.suspend()
        }
        if case .launchOrActivateApplication(let bundleID) = intent,
           bundleID == failingApplication {
            return .failed(reason: "synthetic fixture failure")
        }
        return .acceptedUnverified
    }
}

private actor MutableForeground: ForegroundApplicationProviding {
    private var value: ApplicationBundleIdentifier?
    func foregroundBundleIdentifier() async -> ApplicationBundleIdentifier? { value }
    func set(_ value: ApplicationBundleIdentifier?) { self.value = value }
}

private actor GatedForeground: ForegroundApplicationProviding {
    private let value: ApplicationBundleIdentifier?
    private var pauseNextLookup = false
    private var lookupIsWaiting = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(value: ApplicationBundleIdentifier?) {
        self.value = value
    }

    func pauseNext() {
        pauseNextLookup = true
    }

    func waitUntilEntered() async {
        if lookupIsWaiting { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func foregroundBundleIdentifier() async -> ApplicationBundleIdentifier? {
        guard pauseNextLookup else { return value }
        pauseNextLookup = false
        lookupIsWaiting = true
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
        lookupIsWaiting = false
        return value
    }
}

private actor MutableCapabilities: DeviceCapabilityProviding {
    private var value: DeviceCapabilities
    init(_ value: DeviceCapabilities) { self.value = value }
    func currentCapabilities() async -> DeviceCapabilities { value }
    func set(_ value: DeviceCapabilities) { self.value = value }
}

private struct FixtureMapping: PhysicalActionMappingProviding {
    let targets: [PhysicalControlID: ActionAssignmentTarget]
    init(_ targets: [PhysicalControlID: ActionAssignmentTarget]) { self.targets = targets }
    func actionTarget(for control: PhysicalControlID) async -> ActionAssignmentTarget? { targets[control] }
}

private struct FixtureCapabilities: DeviceCapabilityProviding {
    func currentCapabilities() async -> DeviceCapabilities {
        DeviceCapabilities(detection: .detected, access: .available)
    }
}

private struct FixtureProgrammer: DeviceProgramming {
    func program(_ request: ProgrammingRequest) async -> ProgrammingResult {
        ProgrammingResult(requestID: request.requestID, outcome: .sentUnverified)
    }
}

private struct MismatchedProgrammer: DeviceProgramming {
    func program(_ request: ProgrammingRequest) async -> ProgrammingResult {
        ProgrammingResult(requestID: UUID(), outcome: .sentUnverified)
    }
}

private actor RecordingKeyAssignmentProgrammer: DeviceKeyAssignmentProgramming {
    let outcome: KeyAssignmentProgrammingOutcome
    private(set) var requests: [KeyAssignmentProgrammingRequest] = []

    init(outcome: KeyAssignmentProgrammingOutcome) {
        self.outcome = outcome
    }

    func programKeyAssignment(_ request: KeyAssignmentProgrammingRequest) async -> KeyAssignmentProgrammingResult {
        requests.append(request)
        return KeyAssignmentProgrammingResult(requestID: request.requestID, outcome: outcome)
    }
}

private struct MismatchedKeyAssignmentProgrammer: DeviceKeyAssignmentProgramming {
    let result: KeyAssignmentProgrammingResult

    func programKeyAssignment(_ request: KeyAssignmentProgrammingRequest) async -> KeyAssignmentProgrammingResult {
        result
    }
}

private actor RecordingLightingProgrammer: DeviceLightingProgramming {
    let outcome: LightingProgrammingOutcome
    private(set) var lastRequest: LightingProgrammingRequest?

    init(outcome: LightingProgrammingOutcome) {
        self.outcome = outcome
    }

    func programLighting(_ request: LightingProgrammingRequest) async -> LightingProgrammingResult {
        lastRequest = request
        return LightingProgrammingResult(requestID: request.requestID, outcome: outcome)
    }
}

private struct MismatchedLightingProgrammer: DeviceLightingProgramming {
    let result: LightingProgrammingResult

    func programLighting(_ request: LightingProgrammingRequest) async -> LightingProgrammingResult {
        result
    }
}

private actor ManualInputProducer: InputEventProducing {
    private var consumer: (any NormalizedInputConsumer)?
    private var session: ManualInputSession?
    private var focusEpochClock: FocusEpochClock?
    private(set) var currentGeneration: SessionGeneration?
    var currentFocusEpoch: FocusEpoch { focusEpochClock?.snapshot() ?? .initial }

    func start(
        generation: SessionGeneration,
        consumer: any NormalizedInputConsumer,
        focusEpochClock: FocusEpochClock
    ) async throws -> any InputSessionHandle {
        let session = ManualInputSession(generation: generation, consumer: consumer)
        self.consumer = consumer
        self.session = session
        self.focusEpochClock = focusEpochClock
        currentGeneration = generation
        await consumer.sessionLifecycleChanged(.started(generation))
        return session
    }

    func captureKeyDown(control: PhysicalControlID) -> NormalizedInputEvent? {
        guard let currentGeneration else { return nil }
        return NormalizedInputEvent.keyDown(
            control: control,
            generation: currentGeneration,
            focusEpoch: focusEpochClock?.snapshot() ?? .initial
        )
    }

    func captureKeyUp(control: PhysicalControlID) -> NormalizedInputEvent? {
        guard let currentGeneration else { return nil }
        return NormalizedInputEvent.keyUp(
            control: control,
            generation: currentGeneration,
            focusEpoch: focusEpochClock?.snapshot() ?? .initial
        )
    }

    func emit(_ event: NormalizedInputEvent) async {
        await consumer?.consume(event)
    }

    func enqueue(_ event: NormalizedInputEvent) -> Task<Void, Never> {
        let consumer = self.consumer
        return Task { await consumer?.consume(event) }
    }

    func disconnect(reason: String) async {
        if let currentGeneration {
            await consumer?.sessionLifecycleChanged(.failed(currentGeneration, reason: reason))
        }
    }
}

private actor ManualInputSession: InputSessionHandle {
    nonisolated let generation: SessionGeneration
    private let consumer: any NormalizedInputConsumer

    init(generation: SessionGeneration, consumer: any NormalizedInputConsumer) {
        self.generation = generation
        self.consumer = consumer
    }

    func cancel() async {
        await consumer.sessionLifecycleChanged(.stopping(generation))
        await consumer.sessionLifecycleChanged(.stopped(generation))
    }
}

private final class MemoryConfigurationFiles: ConfigurationFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]

    func exists(at url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return files[url.path] != nil
    }

    func read(from url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[url.path] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        files[url.path] = data
    }
}

private final class GatedBackupConfigurationFiles: ConfigurationFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var shouldBlockNextBackupWrite = false
    private var shouldBlockNextPrimaryWrite = false
    private var primaryWrites = 0
    private let backupEntered = DispatchSemaphore(value: 0)
    private let releaseBackup = DispatchSemaphore(value: 0)
    private let backupFinished = DispatchSemaphore(value: 0)
    private let primaryEntered = DispatchSemaphore(value: 0)
    private let releasePrimary = DispatchSemaphore(value: 0)
    private let primaryFinished = DispatchSemaphore(value: 0)

    var primaryWriteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return primaryWrites
    }

    func blockNextBackupWrite() {
        lock.lock(); defer { lock.unlock() }
        shouldBlockNextBackupWrite = true
    }

    func waitForBlockedBackup() -> Bool {
        backupEntered.wait(timeout: .now() + .seconds(2)) == .success
    }

    func releaseBlockedBackup() {
        releaseBackup.signal()
    }

    func waitForBlockedBackupToFinish() -> Bool {
        backupFinished.wait(timeout: .now() + .seconds(2)) == .success
    }

    func blockNextPrimaryWrite() {
        lock.lock(); defer { lock.unlock() }
        shouldBlockNextPrimaryWrite = true
    }

    func waitForBlockedPrimaryWrite() -> Bool {
        primaryEntered.wait(timeout: .now() + .seconds(2)) == .success
    }

    func releaseBlockedPrimaryWrite() {
        releasePrimary.signal()
    }

    func waitForBlockedPrimaryWriteToFinish() -> Bool {
        primaryFinished.wait(timeout: .now() + .seconds(2)) == .success
    }

    func exists(at url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return files[url.path] != nil
    }

    func read(from url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[url.path] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let isBackup = url.pathExtension == "backup"
        lock.lock()
        let shouldBlock: Bool
        if isBackup && shouldBlockNextBackupWrite {
            shouldBlockNextBackupWrite = false
            shouldBlock = true
        } else if !isBackup && shouldBlockNextPrimaryWrite {
            shouldBlockNextPrimaryWrite = false
            shouldBlock = true
        } else {
            shouldBlock = false
        }
        lock.unlock()

        if shouldBlock {
            (isBackup ? backupEntered : primaryEntered).signal()
            (isBackup ? releaseBackup : releasePrimary).wait()
        }

        lock.lock()
        files[url.path] = data
        if !isBackup { primaryWrites += 1 }
        lock.unlock()
        if shouldBlock {
            (isBackup ? backupFinished : primaryFinished).signal()
        }
    }
}
