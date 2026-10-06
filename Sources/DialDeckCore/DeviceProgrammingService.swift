import DialDeckUSB
import Foundation

/// A deliberate layer-1 flash write to one observed slot and approved usage
/// vector, including any separately staged bounded validation candidate.
/// The previous assignment cannot be read back or restored reliably.
public struct KeyboardDeviceWriteRequest: Sendable {
    public let id: UUID
    public let slot: UInt8
    public let strokes: [USBKeyboardStroke]
    public let acceptsPersistentOverwrite: Bool

    public init(
        id: UUID = UUID(),
        slot: UInt8,
        strokes: [USBKeyboardStroke],
        acceptsPersistentOverwrite: Bool
    ) {
        self.id = id
        self.slot = slot
        self.strokes = strokes
        self.acceptsPersistentOverwrite = acceptsPersistentOverwrite
    }
}

/// Mode 2 was observed running a six-color sequence, retained after one reconnect.
/// Mode 1 was observed changing colors on key press and release, including
/// after one reconnect. Exact per-key color behavior remains unverified.
public enum DeviceLightingModeCandidate: UInt8, Sendable {
    case mode1 = 1
    case mode2 = 2
}

public struct DeviceLightingModeRequest: Sendable {
    public let id: UUID
    public let mode: DeviceLightingModeCandidate
    public let acceptsPersistentOverwrite: Bool

    public init(
        id: UUID = UUID(),
        mode: DeviceLightingModeCandidate,
        acceptsPersistentOverwrite: Bool
    ) {
        self.id = id
        self.mode = mode
        self.acceptsPersistentOverwrite = acceptsPersistentOverwrite
    }
}

public enum DeviceProgrammingWriteOutcome: Equatable, Sendable {
    case sentUnverified(reportsAccepted: Int)
    case failed(reason: String, reportsAccepted: Int)
    case cancelled(reportsAccepted: Int)
}

public struct DeviceProgrammingWriteResult: Equatable, Sendable {
    public let id: UUID
    public let outcome: DeviceProgrammingWriteOutcome
}

public typealias KeyboardDeviceWriteOutcome = DeviceProgrammingWriteOutcome
public typealias KeyboardDeviceWriteResult = DeviceProgrammingWriteResult

private final class USBWriteCancellation: @unchecked Sendable {
    let pointer: OpaquePointer

    init?() {
        guard let pointer = dd_usb_cancel_token_create() else { return nil }
        self.pointer = pointer
    }

    func cancel() { dd_usb_cancel(pointer) }

    deinit { dd_usb_cancel_token_destroy(pointer) }
}

/// The C transport serializes discovery through teardown process-wide, including
/// calls from distinct service instances. Blocking USB calls run off the UI actor.
public final class KeyboardDeviceProgrammingService: Sendable {
    private let queue = DispatchQueue(label: "DialDeck.deviceProgramming")
    private let transport: @Sendable ([UInt8], Int, OpaquePointer) -> DDUSBResult
    private static let baselineUsages: [UInt8: UInt8] = [
        1: 0x1b, 2: 0x04, 3: 0x05, 4: 0x07, 5: 0x08, 6: 0x09,
        13: 0x0a, 14: 0x0b, 15: 0x0d
    ]
    // Retained legacy restore vector: layer-1 slot 1 plain z.
    private static let restoreUsages: [UInt8: Set<UInt8>] = [1: [0x1d]]
    // Fixed F16-F24 vectors are observed on the tested unit after reconnect.
    // They remain separate from the typed runtime request contract.
    private static let fKeyRemapUsages: [UInt8: UInt8] = [
        1: 0x6b, 2: 0x6c, 3: 0x6d, 4: 0x6e, 5: 0x6f,
        6: 0x70, 13: 0x71, 14: 0x72, 15: 0x73
    ]

    public init() {
        transport = { bytes, count, token in
            bytes.withUnsafeBufferPointer { buffer in
                dd_usb_send_reports(buffer.baseAddress, count, bytes.count, token)
            }
        }
    }

    // Offline injection only. Production callers use the public initializer.
    internal init(transport: @escaping @Sendable ([UInt8], Int, OpaquePointer) -> DDUSBResult) {
        self.transport = transport
    }

    public func program(_ request: KeyboardDeviceWriteRequest) async -> DeviceProgrammingWriteResult {
        guard request.acceptsPersistentOverwrite else {
            return .init(id: request.id, outcome: .failed(
                reason: "Persistent overwrite was not accepted", reportsAccepted: 0))
        }
        guard request.strokes.count == 1,
              request.strokes[0].modifiers == 0,
              (Self.baselineUsages[request.slot] == request.strokes[0].usage ||
               Self.restoreUsages[request.slot]?.contains(request.strokes[0].usage) == true ||
               Self.fKeyRemapUsages[request.slot] == request.strokes[0].usage) else {
            return .init(id: request.id, outcome: .failed(
                reason: "Unsupported slot and plain-usage assignment",
                reportsAccepted: 0))
        }
        let reports: [[UInt8]]
        do {
            reports = try ReportID3KeyboardEncoder.encode(
                slot: request.slot, layer: 1, strokes: request.strokes)
        } catch {
            return .init(id: request.id, outcome: .failed(
                reason: "Unsupported keyboard assignment", reportsAccepted: 0))
        }
        return await send(reports, requestID: request.id)
    }

    public func programLighting(_ request: DeviceLightingModeRequest) async -> DeviceProgrammingWriteResult {
        guard request.acceptsPersistentOverwrite else {
            return .init(id: request.id, outcome: .failed(
                reason: "Persistent overwrite was not accepted", reportsAccepted: 0))
        }
        let reports = Self.reports(for: request.mode)
        return await send(reports, requestID: request.id)
    }

    private func send(_ reports: [[UInt8]], requestID: UUID) async -> DeviceProgrammingWriteResult {
        guard let cancellation = USBWriteCancellation() else {
            return .init(id: requestID, outcome: .failed(
                reason: "Unable to allocate cancellation state", reportsAccepted: 0))
        }
        let bytes = reports.flatMap { $0 }
        let transport = self.transport
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let result = transport(bytes, reports.count, cancellation.pointer)
                    let accepted = Int(result.reports_accepted)
                    let outcome: DeviceProgrammingWriteOutcome
                    switch result.status {
                    case DDUSB_SENT_UNVERIFIED:
                        outcome = .sentUnverified(reportsAccepted: accepted)
                    case DDUSB_CANCELLED:
                        outcome = .cancelled(reportsAccepted: accepted)
                    case DDUSB_UNAVAILABLE:
                        outcome = .failed(reason: "libusb is unavailable", reportsAccepted: accepted)
                    case DDUSB_TARGET_MISMATCH:
                        outcome = .failed(reason: "Unique device or descriptor check failed", reportsAccepted: accepted)
                    case DDUSB_ACCESS_FAILED:
                        outcome = .failed(reason: "Configuration interface is inaccessible", reportsAccepted: accepted)
                    case DDUSB_WRITE_FAILED:
                        outcome = .failed(reason: "USB report rejected or short", reportsAccepted: accepted)
                    default:
                        outcome = .failed(reason: "Unknown USB failure", reportsAccepted: accepted)
                    }
                    continuation.resume(returning: .init(id: requestID, outcome: outcome))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func reports(for mode: DeviceLightingModeCandidate) -> [[UInt8]] {
        [report([0xa1, 0x01]), report([0xb0, 0x18, mode.rawValue]), report([0xaa, 0xa1])]
    }

    private static func report(_ payload: [UInt8]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 65)
        bytes[0] = 3
        for (index, byte) in payload.enumerated() {
            bytes[index + 1] = byte
        }
        return bytes
    }
}
