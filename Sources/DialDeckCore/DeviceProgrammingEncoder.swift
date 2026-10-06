import Foundation

/// A keyboard usage from USB HID usage page 0x07, not a macOS virtual key code.
public struct USBKeyboardStroke: Equatable, Sendable {
    public let modifiers: UInt8
    public let usage: UInt8

    public init?(modifiers: UInt8, usage: UInt8) {
        guard modifiers & ~UInt8(0x0f) == 0, usage != 0 else { return nil }
        self.modifiers = modifiers
        self.usage = usage
    }
}

public enum ReportID3EncodingError: Error, Equatable, Sendable {
    case unsupportedSlot
    case unsupportedLayer
    case invalidSequenceLength
}

/// The packet layout is source-derived. Its broader stroke sequences are
/// offline-only; the transport separately restricts callable writes to the
/// nine observed vectors and one explicitly staged validation vector.
public enum ReportID3KeyboardEncoder {
    public static func encode(
        slot: UInt8,
        layer: UInt8,
        strokes: [USBKeyboardStroke]
    ) throws -> [[UInt8]] {
        guard (1...6).contains(slot) || (13...15).contains(slot) else {
            throw ReportID3EncodingError.unsupportedSlot
        }
        guard layer == 1 else { throw ReportID3EncodingError.unsupportedLayer }
        guard (1...5).contains(strokes.count) else {
            throw ReportID3EncodingError.invalidSequenceLength
        }

        var reports: [[UInt8]] = []
        reports.append(report([0xa1, layer]))
        let prefix: [UInt8] = [slot, (layer << 4) | 1, UInt8(strokes.count)]
        reports.append(report(prefix + [0, strokes[0].modifiers, 0]))
        for (index, stroke) in strokes.enumerated() {
            reports.append(report(prefix + [UInt8(index + 1), stroke.modifiers, stroke.usage]))
        }
        reports.append(report([0xaa, 0xaa]))
        return reports
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
