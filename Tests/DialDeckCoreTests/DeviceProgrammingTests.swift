import DialDeckUSB
import Foundation
import XCTest
@testable import DialDeckCore

final class DeviceProgrammingTests: XCTestCase {
    private let observed: [(slot: UInt8, usage: UInt8)] = [
        (1, 0x1b), (2, 0x04), (3, 0x05), (4, 0x07), (5, 0x08), (6, 0x09),
        (13, 0x0a), (14, 0x0b), (15, 0x0d)
    ]

    func testReadOnlyCapabilityCatalogContainsOnlyObservedUnitVectors() {
        let capabilities = ObservedDeviceProgrammingCapabilities.observedUnit
        let expected: [(ObservedDeviceControl, UInt8, UInt8)] = [
            (.topLeftKey, 3, 0x05), (.topRightKey, 6, 0x09),
            (.middleLeftKey, 2, 0x04), (.middleRightKey, 5, 0x08),
            (.bottomLeftKey, 1, 0x1b), (.bottomRightKey, 4, 0x07),
            (.knobClockwise, 15, 0x0d), (.knobCounterclockwise, 13, 0x0a),
            (.knobPress, 14, 0x0b)
        ]
        XCTAssertEqual(capabilities.plainKeyVectors.count, 9)
        XCTAssertEqual(Set(capabilities.plainKeyVectors.map(\.control)), Set(ObservedDeviceControl.allCases))
        for (control, slot, usage) in expected {
            XCTAssertEqual(capabilities.plainKeyVectors.filter {
                $0.control == control && $0.layer == 1 && $0.slot == slot && $0.usage == usage
            }.count, 1)
            XCTAssertTrue(capabilities.containsPlainKeyVector(layer: 1, slot: slot, usage: usage))
        }
        XCTAssertFalse(capabilities.containsPlainKeyVector(layer: 2, slot: 1, usage: 0x1b))
        XCTAssertFalse(capabilities.containsPlainKeyVector(layer: 1, slot: 7, usage: 0x1b))
        XCTAssertFalse(capabilities.containsPlainKeyVector(layer: 1, slot: 1, usage: 0x04))
        XCTAssertEqual(capabilities.lightingModes, [.mode1, .mode2])
        XCTAssertTrue(capabilities.containsLightingMode(.mode1))
        XCTAssertTrue(capabilities.containsLightingMode(.mode2))
    }

    func testGoldenReportID3VectorsForNineObservedAssignments() throws {
        for (slot, usage) in observed {
            let stroke = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: usage))
            let reports = try ReportID3KeyboardEncoder.encode(
                slot: slot, layer: 1, strokes: [stroke])
            XCTAssertEqual(reports, [
                padded([0x03, 0xa1, 0x01]),
                padded([0x03, slot, 0x11, 0x01, 0x00, 0x00, 0x00]),
                padded([0x03, slot, 0x11, 0x01, 0x01, 0x00, usage]),
                padded([0x03, 0xaa, 0xaa])
            ], "slot \(slot)")
            XCTAssertTrue(reports.allSatisfy { $0.count == 65 })
        }
    }

    func testEncoderRejectsInvalidSlotLayerSequenceAndStroke() throws {
        let plain = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: 0x1b))
        for slot: UInt8 in [0, 7, 12, 16] {
            XCTAssertThrowsError(try ReportID3KeyboardEncoder.encode(
                slot: slot, layer: 1, strokes: [plain])) { error in
                XCTAssertEqual(error as? ReportID3EncodingError, .unsupportedSlot)
            }
        }
        for layer: UInt8 in [0, 4] {
            XCTAssertThrowsError(try ReportID3KeyboardEncoder.encode(
                slot: 1, layer: layer, strokes: [plain])) { error in
                XCTAssertEqual(error as? ReportID3EncodingError, .unsupportedLayer)
            }
        }
        for strokes in [[], Array(repeating: plain, count: 6)] {
            XCTAssertThrowsError(try ReportID3KeyboardEncoder.encode(
                slot: 1, layer: 1, strokes: strokes)) { error in
                XCTAssertEqual(error as? ReportID3EncodingError, .invalidSequenceLength)
            }
        }
        XCTAssertNil(USBKeyboardStroke(modifiers: 0x10, usage: 0x1b))
        XCTAssertNil(USBKeyboardStroke(modifiers: 0, usage: 0))
    }

    func testKeyboardMacroGoldenPacketsCoverBoundaryCountsAndAllSourceLayers() throws {
        let strokes = [
            try XCTUnwrap(USBKeyboardStroke(modifiers: 0x05, usage: 0x04)),
            try XCTUnwrap(USBKeyboardStroke(modifiers: 0x02, usage: 0x05)),
            try XCTUnwrap(USBKeyboardStroke(modifiers: 0x08, usage: 0x06)),
            try XCTUnwrap(USBKeyboardStroke(modifiers: 0x01, usage: 0x07)),
            try XCTUnwrap(USBKeyboardStroke(modifiers: 0x04, usage: 0x08))
        ]

        for layer: UInt8 in 1...3 {
            for count in [1, 5] {
                let slot: UInt8 = 3
                let selectedStrokes = Array(strokes.prefix(count))
                let header: [UInt8] = [slot, (layer << 4) | 1, UInt8(count)]
                let expected = [padded([0x03, 0xa1, layer])]
                    + [padded([0x03] + header + [0, selectedStrokes[0].modifiers, 0])]
                    + selectedStrokes.enumerated().map { index, stroke in
                        padded([0x03] + header + [UInt8(index + 1), stroke.modifiers, stroke.usage])
                    }
                    + [padded([0x03, 0xaa, 0xaa])]

                let reports = try ReportID3KeyboardEncoder.encode(
                    slot: slot, layer: layer, strokes: selectedStrokes)

                XCTAssertEqual(reports, expected, "layer \(layer), count \(count)")
                XCTAssertEqual(reports.count, count + 3)
                XCTAssertTrue(reports.allSatisfy { $0.count == 65 })
            }
        }
    }

    func testConsumerControlGoldenPacketsCoverEveryCodeAndSourceLayer() throws {
        XCTAssertNil(ReportID3ConsumerControlCode(rawValue: 0x00))
        XCTAssertNil(ReportID3ConsumerControlCode(rawValue: 0xff))

        for layer: UInt8 in 1...3 {
            for code in ReportID3ConsumerControlCode.allCases {
                let reports = try ReportID3KeyboardEncoder.encodeConsumerControl(
                    slot: 14, layer: layer, code: code)
                XCTAssertEqual(reports, [
                    padded([0x03, 0xa1, layer]),
                    padded([0x03, 14, (layer << 4) | 2, code.rawValue, 0]),
                    padded([0x03, 0xaa, 0xaa])
                ], "layer \(layer), code \(code)")
                XCTAssertEqual(reports.count, 3)
                XCTAssertTrue(reports.allSatisfy { $0.count == 65 })
            }
        }
    }

    func testMouseGoldenPacketsCoverButtonsWheelModifiersAndSourceLayers() throws {
        XCTAssertNil(ReportID3MouseWheelDirection(rawValue: 0x00))
        XCTAssertNil(ReportID3MouseWheelDirection(rawValue: 0x02))
        let wheelDirections: [ReportID3MouseWheelDirection?] = [nil, .up, .down]

        for layer: UInt8 in 1...3 {
            for buttonMask: UInt8 in 0...7 {
                for wheel in wheelDirections {
                    if buttonMask == 0 && wheel == nil { continue }
                    for modifierMask: UInt8 in 0...7 {
                        let buttons = ReportID3MouseButtons(rawValue: buttonMask)
                        let modifiers = ReportID3MouseModifiers(rawValue: modifierMask)
                        let reports = try ReportID3KeyboardEncoder.encodeMouse(
                            slot: 15,
                            layer: layer,
                            buttons: buttons,
                            wheel: wheel,
                            modifiers: modifiers
                        )
                        XCTAssertEqual(reports, [
                            padded([0x03, 0xa1, layer]),
                            padded([
                                0x03, 15, (layer << 4) | 3,
                                buttonMask, 0, 0, wheel?.rawValue ?? 0, modifierMask
                            ]),
                            padded([0x03, 0xaa, 0xaa])
                        ], "layer \(layer), buttons \(buttonMask), wheel \(String(describing: wheel)), modifiers \(modifierMask)")
                        XCTAssertEqual(reports.count, 3)
                        XCTAssertTrue(reports.allSatisfy { $0.count == 65 })
                    }
                }
            }
        }
    }

    func testEncoderRejectsInvalidFamilyBoundsAndMalformedMouseState() throws {
        let plain = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: 0x04))
        for layer: UInt8 in [0, 4] {
            XCTAssertThrowsError(try ReportID3KeyboardEncoder.encode(
                slot: 1, layer: layer, strokes: [plain])) { error in
                XCTAssertEqual(error as? ReportID3EncodingError, .unsupportedLayer)
            }
            XCTAssertThrowsError(try ReportID3KeyboardEncoder.encodeConsumerControl(
                slot: 1, layer: layer, code: .playPause)) { error in
                XCTAssertEqual(error as? ReportID3EncodingError, .unsupportedLayer)
            }
            XCTAssertThrowsError(try ReportID3KeyboardEncoder.encodeMouse(
                slot: 1, layer: layer, buttons: .left)) { error in
                XCTAssertEqual(error as? ReportID3EncodingError, .unsupportedLayer)
            }
        }
        for slot: UInt8 in [0, 7, 12, 16] {
            XCTAssertThrowsError(try ReportID3KeyboardEncoder.encodeConsumerControl(
                slot: slot, layer: 1, code: .playPause)) { error in
                XCTAssertEqual(error as? ReportID3EncodingError, .unsupportedSlot)
            }
            XCTAssertThrowsError(try ReportID3KeyboardEncoder.encodeMouse(
                slot: slot, layer: 1, buttons: .left)) { error in
                XCTAssertEqual(error as? ReportID3EncodingError, .unsupportedSlot)
            }
        }

        XCTAssertThrowsError(try ReportID3KeyboardEncoder.encodeMouse(
            slot: 1,
            layer: 1,
            buttons: ReportID3MouseButtons(rawValue: 0x08)
        )) { error in
            XCTAssertEqual(error as? ReportID3MouseEncodingError, .invalidMouseButtons)
        }
        XCTAssertThrowsError(try ReportID3KeyboardEncoder.encodeMouse(
            slot: 1,
            layer: 1,
            buttons: .left,
            modifiers: ReportID3MouseModifiers(rawValue: 0x08)
        )) { error in
            XCTAssertEqual(error as? ReportID3MouseEncodingError, .invalidMouseModifiers)
        }
        XCTAssertThrowsError(try ReportID3KeyboardEncoder.encodeMouse(
            slot: 1,
            layer: 1,
            buttons: [],
            modifiers: .control
        )) { error in
            XCTAssertEqual(error as? ReportID3MouseEncodingError, .emptyMouseOperation)
        }
    }

    func testReportID3EncodingErrorRetainsItsOriginalExhaustiveCases() {
        XCTAssertEqual(legacyEncodingErrorDescription(.unsupportedSlot), "slot")
        XCTAssertEqual(legacyEncodingErrorDescription(.unsupportedLayer), "layer")
        XCTAssertEqual(legacyEncodingErrorDescription(.invalidSequenceLength), "sequence")
    }

    func testEncoderOnlyFamiliesAndLayersRemainOutsideTransportAllowlist() async throws {
        let plain = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: 0x1b))
        let encoderOnlyVectors = [
            try ReportID3KeyboardEncoder.encodeConsumerControl(
                slot: 1, layer: 1, code: .playPause),
            try ReportID3KeyboardEncoder.encodeMouse(slot: 1, layer: 1, buttons: .left),
            try ReportID3KeyboardEncoder.encode(slot: 1, layer: 2, strokes: [plain]),
            try ReportID3KeyboardEncoder.encode(slot: 1, layer: 3, strokes: [plain])
        ]
        for reports in encoderOnlyVectors {
            let bytes = reports.flatMap { $0 }
            // The production C transport invokes this checked allowlist before USB discovery.
            let permitted = bytes.withUnsafeBufferPointer { buffer in
                dd_usb_reports_permitted(buffer.baseAddress, reports.count, bytes.count)
            }
            XCTAssertEqual(permitted, 0)
        }

        // The service accepts typed keyboard requests only; treating a media
        // code as a keyboard usage still fails its unchanged plain-key allowlist.
        let recorder = TransportCallRecorder()
        let service = KeyboardDeviceProgrammingService { bytes, count, _ in
            recorder.record(bytes: bytes, count: count)
            return DDUSBResult(status: DDUSB_SENT_UNVERIFIED, reports_accepted: count)
        }
        let mediaCodeAsKeyboardUsage = try XCTUnwrap(
            USBKeyboardStroke(modifiers: 0, usage: ReportID3ConsumerControlCode.playPause.rawValue))
        let result = await service.program(.init(
            slot: 1, strokes: [mediaCodeAsKeyboardUsage], acceptsPersistentOverwrite: true))

        XCTAssertEqual(result.outcome, .failed(
            reason: "Unsupported slot and plain-usage assignment", reportsAccepted: 0))
        XCTAssertEqual(recorder.count, 0)
    }

    func testEncoderKeepsModifierStateSeparateWithinBoundedSequence() throws {
        let first = try XCTUnwrap(USBKeyboardStroke(modifiers: 0x08, usage: 0x04))
        let second = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: 0x05))
        let reports = try ReportID3KeyboardEncoder.encode(
            slot: 1, layer: 1, strokes: [first, second])
        XCTAssertEqual(reports.count, 5)
        XCTAssertEqual(reports[1], padded([0x03, 0x01, 0x11, 0x02, 0x00, 0x08, 0x00]))
        XCTAssertEqual(reports[2], padded([0x03, 0x01, 0x11, 0x02, 0x01, 0x08, 0x04]))
        XCTAssertEqual(reports[3], padded([0x03, 0x01, 0x11, 0x02, 0x02, 0x00, 0x05]))
        XCTAssertEqual(reports[4], padded([0x03, 0xaa, 0xaa]))
    }

    func testServiceRejectsUnacceptedAndUnsupportedRequestsBeforeTransport() async throws {
        let recorder = TransportCallRecorder()
        let service = KeyboardDeviceProgrammingService { bytes, count, _ in
            recorder.record(bytes: bytes, count: count)
            return DDUSBResult(status: DDUSB_SENT_UNVERIFIED, reports_accepted: 4)
        }
        let x = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: 0x1b))
        let a = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: 0x04))
        let modified = try XCTUnwrap(USBKeyboardStroke(modifiers: 0x08, usage: 0x1b))
        let requests = [
            KeyboardDeviceWriteRequest(slot: 1, strokes: [x], acceptsPersistentOverwrite: false),
            KeyboardDeviceWriteRequest(slot: 7, strokes: [x], acceptsPersistentOverwrite: true),
            KeyboardDeviceWriteRequest(slot: 1, strokes: [a], acceptsPersistentOverwrite: true),
            KeyboardDeviceWriteRequest(slot: 1, strokes: [modified], acceptsPersistentOverwrite: true),
            KeyboardDeviceWriteRequest(slot: 1, strokes: [x, x], acceptsPersistentOverwrite: true)
        ]
        for request in requests {
            let result = await service.program(request)
            XCTAssertEqual(result.id, request.id)
            guard case .failed(_, 0) = result.outcome else {
                return XCTFail("Expected pre-transport failure for slot \(request.slot)")
            }
        }
        XCTAssertEqual(recorder.count, 0)
    }

    func testHomeDockValidationCandidatePermitsOnlySlotOnePlainZ() async throws {
        let recorder = TransportCallRecorder()
        let service = KeyboardDeviceProgrammingService { bytes, count, _ in
            recorder.record(bytes: bytes, count: count)
            return DDUSBResult(status: DDUSB_SENT_UNVERIFIED, reports_accepted: 4)
        }
        let z = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: 0x1d))

        let denied = await service.program(.init(
            slot: 1, strokes: [z], acceptsPersistentOverwrite: false))
        XCTAssertEqual(denied.outcome, .failed(
            reason: "Persistent overwrite was not accepted", reportsAccepted: 0))
        XCTAssertEqual(recorder.count, 0)

        let accepted = await service.program(.init(
            slot: 1, strokes: [z], acceptsPersistentOverwrite: true))
        XCTAssertEqual(accepted.outcome, .sentUnverified(reportsAccepted: 4))
        let expected = try encodedBytes(slot: 1, usage: 0x1d)
        XCTAssertEqual(recorder.lastBytes, expected)
        XCTAssertEqual(recorder.lastReportCount, 4)
        let permitted = expected.withUnsafeBufferPointer { buffer in
            dd_usb_reports_permitted(buffer.baseAddress, 4, expected.count)
        }
        XCTAssertEqual(permitted, 1)

        for (slot, usage) in [(UInt8(2), UInt8(0x1d)), (UInt8(1), UInt8(0x1c))] {
            let unsupported = try encodedBytes(slot: slot, usage: usage)
            let rejected = unsupported.withUnsafeBufferPointer { buffer in
                dd_usb_reports_permitted(buffer.baseAddress, 4, unsupported.count)
            }
            XCTAssertEqual(rejected, 0, "slot \(slot), usage \(usage)")
        }
    }

    func testServicePreservesIdentityAndReportsHostAcceptanceOnly() async throws {
        let recorder = TransportCallRecorder()
        let service = KeyboardDeviceProgrammingService { bytes, count, _ in
            recorder.record(bytes: bytes, count: count)
            return DDUSBResult(status: DDUSB_SENT_UNVERIFIED, reports_accepted: 4)
        }
        let id = UUID()
        let j = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: 0x0d))
        let result = await service.program(.init(
            id: id, slot: 15, strokes: [j], acceptsPersistentOverwrite: true))
        XCTAssertEqual(result.id, id)
        XCTAssertEqual(result.outcome, .sentUnverified(reportsAccepted: 4))
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(recorder.lastByteCount, 260)
        XCTAssertEqual(recorder.lastReportCount, 4)
    }

    func testLightingModeRequiresExplicitOverwriteAndSendsOnlyModeTwoVector() async throws {
        let recorder = TransportCallRecorder()
        let service = KeyboardDeviceProgrammingService { bytes, count, _ in
            recorder.record(bytes: bytes, count: count)
            return DDUSBResult(status: DDUSB_SENT_UNVERIFIED, reports_accepted: 3)
        }
        let deniedID = UUID()
        let denied = await service.programLighting(.init(
            id: deniedID, mode: .mode2, acceptsPersistentOverwrite: false))
        XCTAssertEqual(denied.id, deniedID)
        XCTAssertEqual(denied.outcome, .failed(
            reason: "Persistent overwrite was not accepted", reportsAccepted: 0))
        XCTAssertEqual(recorder.count, 0)

        let acceptedID = UUID()
        let accepted = await service.programLighting(.init(
            id: acceptedID, mode: .mode2, acceptsPersistentOverwrite: true))
        XCTAssertEqual(accepted.id, acceptedID)
        XCTAssertEqual(accepted.outcome, .sentUnverified(reportsAccepted: 3))
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(recorder.lastReportCount, 3)
        XCTAssertEqual(recorder.lastBytes, [
            padded([0x03, 0xa1, 0x01]),
            padded([0x03, 0xb0, 0x18, 0x02]),
            padded([0x03, 0xaa, 0xa1])
        ].flatMap { $0 })
    }

    func testServiceKeepsFailureAndCancellationDistinctFromHostAcceptance() async throws {
        let x = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: 0x1b))
        let request = KeyboardDeviceWriteRequest(
            slot: 1, strokes: [x], acceptsPersistentOverwrite: true)
        let cases: [(DDUSBStatus, Int, KeyboardDeviceWriteOutcome)] = [
            (DDUSB_WRITE_FAILED, 2, .failed(
                reason: "USB report rejected or short", reportsAccepted: 2)),
            (DDUSB_CANCELLED, 1, .cancelled(reportsAccepted: 1)),
            (DDUSB_TARGET_MISMATCH, 0, .failed(
                reason: "Unique device or descriptor check failed", reportsAccepted: 0))
        ]
        for (status, accepted, expected) in cases {
            let service = KeyboardDeviceProgrammingService { _, _, _ in
                DDUSBResult(status: status, reports_accepted: accepted)
            }
            let result = await service.program(request)
            XCTAssertEqual(result.id, request.id)
            XCTAssertEqual(result.outcome, expected)
        }
    }

    func testPureValidatorAcceptsExactlyNineObservedPairs() throws {
        for (slot, usage) in observed {
            let bytes = try encodedBytes(slot: slot, usage: usage)
            let permitted = bytes.withUnsafeBufferPointer { buffer in
                dd_usb_reports_permitted(buffer.baseAddress, 4, bytes.count)
            }
            XCTAssertEqual(permitted, 1, "slot \(slot)")
        }
        let unobservedPair = try encodedBytes(slot: 1, usage: 0x04)
        let permitted = unobservedPair.withUnsafeBufferPointer { buffer in
            dd_usb_reports_permitted(buffer.baseAddress, 4, unobservedPair.count)
        }
        XCTAssertEqual(permitted, 0)
    }

    func testPureValidatorAcceptsBoundedModeTwoLightingSave() throws {
        let modeTwo = [
            padded([0x03, 0xa1, 0x01]),
            padded([0x03, 0xb0, 0x18, 0x02]),
            padded([0x03, 0xaa, 0xa1])
        ].flatMap { $0 }
        let permitted = modeTwo.withUnsafeBufferPointer { buffer in
            dd_usb_reports_permitted(buffer.baseAddress, 3, modeTwo.count)
        }
        XCTAssertEqual(permitted, 1)

        let invalidMutations: [(Int, UInt8)] = [
            (68, 0x00),  // mode 0 remains unavailable
            (67, 0x28),  // layer 2 in the mode report
            (132, 0xaa), // ordinary save instead of LED save
            (2, 0x02)    // layer 2 in the layer-select report
        ]
        for (index, replacement) in invalidMutations {
            var invalid = modeTwo
            invalid[index] = replacement
            let result = invalid.withUnsafeBufferPointer { buffer in
                dd_usb_reports_permitted(buffer.baseAddress, 3, invalid.count)
            }
            XCTAssertEqual(result, 0)
        }
        let missingLayerSelect = Array(modeTwo.dropFirst(65))
        let missingLayerResult = missingLayerSelect.withUnsafeBufferPointer { buffer in
            dd_usb_reports_permitted(buffer.baseAddress, 2, missingLayerSelect.count)
        }
        XCTAssertEqual(missingLayerResult, 0)
    }

    func testModeOneCandidateUsesOnlyTheFixedLayerOneLEDVector() async {
        let recorder = TransportCallRecorder()
        let service = KeyboardDeviceProgrammingService { bytes, count, _ in
            recorder.record(bytes: bytes, count: count)
            return DDUSBResult(status: DDUSB_SENT_UNVERIFIED, reports_accepted: 3)
        }
        let denied = await service.programLighting(.init(
            mode: .mode1, acceptsPersistentOverwrite: false))
        XCTAssertEqual(denied.outcome, .failed(
            reason: "Persistent overwrite was not accepted", reportsAccepted: 0))
        XCTAssertEqual(recorder.count, 0)

        let accepted = await service.programLighting(.init(
            mode: .mode1, acceptsPersistentOverwrite: true))
        XCTAssertEqual(accepted.outcome, .sentUnverified(reportsAccepted: 3))
        let expected = [
            padded([0x03, 0xa1, 0x01]),
            padded([0x03, 0xb0, 0x18, 0x01]),
            padded([0x03, 0xaa, 0xa1])
        ].flatMap { $0 }
        XCTAssertEqual(recorder.lastBytes, expected)
        let permitted = expected.withUnsafeBufferPointer { buffer in
            dd_usb_reports_permitted(buffer.baseAddress, 3, expected.count)
        }
        XCTAssertEqual(permitted, 1)

        var offMode = expected
        offMode[68] = 0
        let offPermitted = offMode.withUnsafeBufferPointer { buffer in
            dd_usb_reports_permitted(buffer.baseAddress, 3, offMode.count)
        }
        XCTAssertEqual(offPermitted, 0)
    }

    func testRuntimeLightingAdapterPreservesCancellationCountAndRequestIdentity() async {
        let recorder = TransportCallRecorder()
        let service = KeyboardDeviceProgrammingService { bytes, count, _ in
            recorder.record(bytes: bytes, count: count)
            return DDUSBResult(status: DDUSB_CANCELLED, reports_accepted: 2)
        }
        let programmer = KeyboardDeviceLightingProgrammer(service: service)
        let request = LightingProgrammingRequest(
            requestID: UUID(), mode: .mode2, acceptsPersistentOverwrite: true)

        let result = await programmer.programLighting(request)

        XCTAssertEqual(result, .init(
            requestID: request.requestID,
            outcome: .cancelled(reportsAccepted: 2)
        ))
        XCTAssertEqual(recorder.lastReportCount, 3)
    }

    func testRuntimeKeyAssignmentAdapterSendsOnlyTheTenBoundedCandidateVectors() async {
        let recorder = TransportCallRecorder()
        let service = KeyboardDeviceProgrammingService { bytes, count, _ in
            recorder.record(bytes: bytes, count: count)
            return DDUSBResult(status: DDUSB_SENT_UNVERIFIED, reports_accepted: 4)
        }
        let programmer = KeyboardDeviceKeyAssignmentProgrammer(service: service)
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
            (.knobPressUsage0B, 14, 0x0b)
        ]

        for (index, (candidate, slot, usage)) in candidates.enumerated() {
            let requestID = UUID()
            let request = KeyAssignmentProgrammingRequest(
                requestID: requestID,
                candidate: candidate,
                acceptsPersistentOverwrite: true
            )

            let result = await programmer.programKeyAssignment(request)

            XCTAssertEqual(candidate.slot, slot)
            XCTAssertEqual(candidate.usage, usage)
            XCTAssertEqual(result, .init(
                requestID: requestID,
                outcome: .sentUnverified(reportsAccepted: 4)
            ))
            XCTAssertEqual(recorder.count, index + 1)
            XCTAssertEqual(recorder.lastReportCount, 4)
            XCTAssertEqual(recorder.lastByteCount, 260)
            XCTAssertEqual(recorder.lastBytes, expectedPlainAssignmentBytes(slot: slot, usage: usage))
        }
    }

    func testRuntimeKeyAssignmentAdapterDeniesOverwriteBeforeTransport() async {
        let recorder = TransportCallRecorder()
        let service = KeyboardDeviceProgrammingService { bytes, count, _ in
            recorder.record(bytes: bytes, count: count)
            return DDUSBResult(status: DDUSB_SENT_UNVERIFIED, reports_accepted: 4)
        }
        let programmer = KeyboardDeviceKeyAssignmentProgrammer(service: service)
        let requestID = UUID()
        let request = KeyAssignmentProgrammingRequest(
            requestID: requestID,
            candidate: .bottomLeftUsage1D,
            acceptsPersistentOverwrite: false
        )

        let result = await programmer.programKeyAssignment(request)

        XCTAssertEqual(result, .init(
            requestID: requestID,
            outcome: .failed(reason: "Persistent overwrite was not accepted", reportsAccepted: 0)
        ))
        XCTAssertEqual(recorder.count, 0)
    }

    func testRuntimeKeyAssignmentAdapterPreservesAcceptedFailedAndCancelledCounts() async {
        let requestID = UUID()
        let request = KeyAssignmentProgrammingRequest(
            requestID: requestID,
            candidate: .knobPressUsage0B,
            acceptsPersistentOverwrite: true
        )
        let cases: [(DDUSBStatus, Int, KeyAssignmentProgrammingOutcome)] = [
            (DDUSB_SENT_UNVERIFIED, 4, .sentUnverified(reportsAccepted: 4)),
            (DDUSB_WRITE_FAILED, 2, .failed(
                reason: "USB report rejected or short", reportsAccepted: 2)),
            (DDUSB_CANCELLED, 1, .cancelled(reportsAccepted: 1))
        ]

        for (status, acceptedCount, expectedOutcome) in cases {
            let recorder = TransportCallRecorder()
            let service = KeyboardDeviceProgrammingService { bytes, count, _ in
                recorder.record(bytes: bytes, count: count)
                return DDUSBResult(status: status, reports_accepted: acceptedCount)
            }
            let programmer = KeyboardDeviceKeyAssignmentProgrammer(service: service)

            let result = await programmer.programKeyAssignment(request)

            XCTAssertEqual(result, .init(requestID: requestID, outcome: expectedOutcome))
            XCTAssertEqual(recorder.count, 1)
            XCTAssertEqual(recorder.lastReportCount, 4)
            XCTAssertEqual(recorder.lastBytes, expectedPlainAssignmentBytes(slot: 14, usage: 0x0b))
        }
    }

    func testServiceLabelsInjectedFailureAndShortTransferAtEveryPosition() async throws {
        let x = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: 0x1b))
        for position in 0..<4 {
            for failureKind in ["failed", "short"] {
                let recorder = TransportCallRecorder()
                let service = KeyboardDeviceProgrammingService { bytes, count, _ in
                    recorder.record(bytes: bytes, count: count)
                    // Both rejected and short transfers are classified by C as WRITE_FAILED.
                    return DDUSBResult(status: DDUSB_WRITE_FAILED, reports_accepted: position)
                }
                let request = KeyboardDeviceWriteRequest(
                    slot: 1, strokes: [x], acceptsPersistentOverwrite: true)
                let result = await service.program(request)
                XCTAssertEqual(result.id, request.id, failureKind)
                XCTAssertEqual(result.outcome, .failed(
                    reason: "USB report rejected or short", reportsAccepted: position),
                    failureKind)
                XCTAssertEqual(recorder.count, 1, failureKind)
            }
        }
    }

    func testServiceLabelsInjectedCancellationAndAcceptedFinalSave() async throws {
        let x = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: 0x1b))
        for position in 0..<4 {
            let service = KeyboardDeviceProgrammingService { _, _, _ in
                DDUSBResult(
                    status: position == 3 ? DDUSB_SENT_UNVERIFIED : DDUSB_CANCELLED,
                    reports_accepted: position + 1)
            }
            let request = KeyboardDeviceWriteRequest(
                slot: 1, strokes: [x], acceptsPersistentOverwrite: true)
            let result = await service.program(request)
            XCTAssertEqual(result.id, request.id)
            XCTAssertEqual(result.outcome, position == 3
                ? .sentUnverified(reportsAccepted: 4)
                : .cancelled(reportsAccepted: position + 1))
        }
        let beforeStart = KeyboardDeviceProgrammingService { _, _, _ in
            DDUSBResult(status: DDUSB_CANCELLED, reports_accepted: 0)
        }
        let result = await beforeStart.program(.init(
            slot: 1, strokes: [x], acceptsPersistentOverwrite: true))
        XCTAssertEqual(result.outcome, .cancelled(reportsAccepted: 0))
    }

    func testPureValidatorRejectsInvalidPayloadAndLength() throws {
        var bytes = try encodedBytes(slot: 1, usage: 0x1b)
        bytes[6] = 0x01
        let invalidPayload = bytes.withUnsafeBufferPointer { buffer in
            dd_usb_reports_permitted(buffer.baseAddress, 4, bytes.count)
        }
        XCTAssertEqual(invalidPayload, 0)

        let valid = try encodedBytes(slot: 1, usage: 0x1b)
        let shortBuffer = valid.withUnsafeBufferPointer { buffer in
            dd_usb_reports_permitted(buffer.baseAddress, 4, valid.count - 1)
        }
        XCTAssertEqual(shortBuffer, 0)
    }

    private func encodedBytes(slot: UInt8, usage: UInt8) throws -> [UInt8] {
        let stroke = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: usage))
        return try ReportID3KeyboardEncoder.encode(slot: slot, layer: 1, strokes: [stroke])
            .flatMap { $0 }
    }

    private func expectedPlainAssignmentBytes(slot: UInt8, usage: UInt8) -> [UInt8] {
        [
            padded([0x03, 0xa1, 0x01]),
            padded([0x03, slot, 0x11, 0x01, 0x00, 0x00, 0x00]),
            padded([0x03, slot, 0x11, 0x01, 0x01, 0x00, usage]),
            padded([0x03, 0xaa, 0xaa])
        ].flatMap { $0 }
    }

    private func legacyEncodingErrorDescription(_ error: ReportID3EncodingError) -> String {
        switch error {
        case .unsupportedSlot:
            "slot"
        case .unsupportedLayer:
            "layer"
        case .invalidSequenceLength:
            "sequence"
        }
    }

    private func padded(_ prefix: [UInt8]) -> [UInt8] {
        prefix + [UInt8](repeating: 0, count: 65 - prefix.count)
    }

}

private final class TransportCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var byteCount = 0
    private var reportCount = 0
    private var bytes: [UInt8] = []

    func record(bytes: [UInt8], count: Int) {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        byteCount = bytes.count
        reportCount = count
        self.bytes = bytes
    }

    var count: Int { lock.withLock { calls } }
    var lastByteCount: Int { lock.withLock { byteCount } }
    var lastReportCount: Int { lock.withLock { reportCount } }
    var lastBytes: [UInt8] { lock.withLock { bytes } }
}
