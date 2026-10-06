import DialDeckUSB
import Foundation
import XCTest
@testable import DialDeckCore

final class DeviceProgrammingTests: XCTestCase {
    private let observed: [(slot: UInt8, usage: UInt8)] = [
        (1, 0x1b), (2, 0x04), (3, 0x05), (4, 0x07), (5, 0x08), (6, 0x09),
        (13, 0x0a), (14, 0x0b), (15, 0x0d)
    ]

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
        for layer: UInt8 in [0, 2] {
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

    func testPureValidatorAcceptsOnlyTheBoundedModeTwoLightingSave() throws {
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
            (68, 0x01),  // mode 1
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
