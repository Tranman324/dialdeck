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

    func testInjectedSequenceWhitelistAcceptsExactlyNineObservedPairs() throws {
        for (slot, usage) in observed {
            let (result, calls) = runInjectedSequence(try encodedBytes(slot: slot, usage: usage))
            XCTAssertEqual(result.status, DDUSB_SENT_UNVERIFIED, "slot \(slot)")
            XCTAssertEqual(result.reports_accepted, 4)
            XCTAssertEqual(calls, 4)
        }
        let unobservedPair = try encodedBytes(slot: 1, usage: 0x04)
        let (rejected, calls) = runInjectedSequence(unobservedPair)
        XCTAssertEqual(rejected.status, DDUSB_TARGET_MISMATCH)
        XCTAssertEqual(calls, 0)
    }

    func testInjectedSequenceStopsOnFailureOrShortTransferAtEveryPosition() throws {
        let bytes = try encodedBytes(slot: 1, usage: 0x1b)
        for position in 0..<4 {
            for returnedLength: Int32 in [-1, 64] {
                let (result, calls) = runInjectedSequence(
                    bytes, failAt: position, failedLength: returnedLength)
                XCTAssertEqual(result.status, DDUSB_WRITE_FAILED)
                XCTAssertEqual(result.reports_accepted, position)
                XCTAssertEqual(calls, position + 1)
            }
        }
    }

    func testInjectedSequenceCancellationStopsLaterReportsButKeepsCommittedSave() throws {
        let bytes = try encodedBytes(slot: 1, usage: 0x1b)
        for position in 0..<4 {
            let (result, calls) = runInjectedSequence(bytes, cancelAfter: position)
            XCTAssertEqual(calls, position + 1)
            XCTAssertEqual(result.reports_accepted, position + 1)
            XCTAssertEqual(result.status, position == 3 ? DDUSB_SENT_UNVERIFIED : DDUSB_CANCELLED)
        }
        let (preCancelled, calls) = runInjectedSequence(bytes, cancelBeforeStart: true)
        XCTAssertEqual(preCancelled.status, DDUSB_CANCELLED)
        XCTAssertEqual(preCancelled.reports_accepted, 0)
        XCTAssertEqual(calls, 0)
    }

    func testInjectedSequenceRejectsInvalidBufferBeforeCallback() throws {
        var bytes = try encodedBytes(slot: 1, usage: 0x1b)
        bytes[6] = 0x01
        let (invalidPayload, calls) = runInjectedSequence(bytes)
        XCTAssertEqual(invalidPayload.status, DDUSB_TARGET_MISMATCH)
        XCTAssertEqual(calls, 0)

        let valid = try encodedBytes(slot: 1, usage: 0x1b)
        let (shortBuffer, shortCalls) = runInjectedSequence(valid, suppliedLength: valid.count - 1)
        XCTAssertEqual(shortBuffer.status, DDUSB_TARGET_MISMATCH)
        XCTAssertEqual(shortCalls, 0)
    }

    private func encodedBytes(slot: UInt8, usage: UInt8) throws -> [UInt8] {
        let stroke = try XCTUnwrap(USBKeyboardStroke(modifiers: 0, usage: usage))
        return try ReportID3KeyboardEncoder.encode(slot: slot, layer: 1, strokes: [stroke])
            .flatMap { $0 }
    }

    private func padded(_ prefix: [UInt8]) -> [UInt8] {
        prefix + [UInt8](repeating: 0, count: 65 - prefix.count)
    }

    private func runInjectedSequence(
        _ bytes: [UInt8],
        suppliedLength: Int? = nil,
        failAt: Int? = nil,
        failedLength: Int32 = -1,
        cancelAfter: Int? = nil,
        cancelBeforeStart: Bool = false
    ) -> (DDUSBResult, Int) {
        let token = dd_usb_cancel_token_create()!
        defer { dd_usb_cancel_token_destroy(token) }
        let context = InjectedTransferContext(
            token: token, failAt: failAt, failedLength: failedLength, cancelAfter: cancelAfter)
        if cancelBeforeStart { dd_usb_cancel(token) }
        let result = bytes.withUnsafeBufferPointer { buffer in
            dd_usb_send_sequence_with_transfer(
                buffer.baseAddress, 4, suppliedLength ?? bytes.count, token,
                { opaque, _, length in
                    let context = Unmanaged<InjectedTransferContext>
                        .fromOpaque(opaque!).takeUnretainedValue()
                    let position = context.calls
                    context.calls += 1
                    if context.cancelAfter == position { dd_usb_cancel(context.token) }
                    if context.failAt == position { return context.failedLength }
                    return Int32(length)
                }, Unmanaged.passUnretained(context).toOpaque())
        }
        return (result, context.calls)
    }
}

private final class InjectedTransferContext {
    let token: OpaquePointer
    let failAt: Int?
    let failedLength: Int32
    let cancelAfter: Int?
    var calls = 0

    init(token: OpaquePointer, failAt: Int?, failedLength: Int32, cancelAfter: Int?) {
        self.token = token
        self.failAt = failAt
        self.failedLength = failedLength
        self.cancelAfter = cancelAfter
    }
}

private final class TransportCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var byteCount = 0
    private var reportCount = 0

    func record(bytes: [UInt8], count: Int) {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        byteCount = bytes.count
        reportCount = count
    }

    var count: Int { lock.withLock { calls } }
    var lastByteCount: Int { lock.withLock { byteCount } }
    var lastReportCount: Int { lock.withLock { reportCount } }
}
