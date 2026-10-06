import DialDeckUSB
import Foundation

/// A deliberate layer-1 flash write to one observed protocol slot.
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

public enum KeyboardDeviceWriteOutcome: Equatable, Sendable {
    case sentUnverified(reportsAccepted: Int)
    case failed(reason: String, reportsAccepted: Int)
    case cancelled(reportsAccepted: Int)
}

public struct KeyboardDeviceWriteResult: Equatable, Sendable {
    public let id: UUID
    public let outcome: KeyboardDeviceWriteOutcome
}

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
    private static let observedUsages: [UInt8: UInt8] = [
        1: 0x1b, 2: 0x04, 3: 0x05, 4: 0x07, 5: 0x08, 6: 0x09,
        13: 0x0a, 14: 0x0b, 15: 0x0d
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

    public func program(_ request: KeyboardDeviceWriteRequest) async -> KeyboardDeviceWriteResult {
        guard request.acceptsPersistentOverwrite else {
            return .init(id: request.id, outcome: .failed(
                reason: "Persistent overwrite was not accepted", reportsAccepted: 0))
        }
        guard request.strokes.count == 1,
              request.strokes[0].modifiers == 0,
              let observedUsage = Self.observedUsages[request.slot],
              request.strokes[0].usage == observedUsage else {
            return .init(id: request.id, outcome: .failed(
                reason: "Only observed slot and plain-usage assignments are enabled",
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
        guard let cancellation = USBWriteCancellation() else {
            return .init(id: request.id, outcome: .failed(
                reason: "Unable to allocate cancellation state", reportsAccepted: 0))
        }
        let bytes = reports.flatMap { $0 }
        let transport = self.transport
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let result = transport(bytes, reports.count, cancellation.pointer)
                    let accepted = Int(result.reports_accepted)
                    let outcome: KeyboardDeviceWriteOutcome
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
                    continuation.resume(returning: .init(id: request.id, outcome: outcome))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
