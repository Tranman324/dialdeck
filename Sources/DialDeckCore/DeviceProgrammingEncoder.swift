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

public enum ReportID3ConsumerControlCode: UInt8, CaseIterable, Sendable {
    case playPause = 0xcd
    case previous = 0xb6
    case next = 0xb5
    case mute = 0xe2
    case volumeUp = 0xe9
    case volumeDown = 0xea
    case stop = 0xb7
}

public struct ReportID3MouseButtons: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let left = Self(rawValue: 0x01)
    public static let right = Self(rawValue: 0x02)
    public static let middle = Self(rawValue: 0x04)
}

public enum ReportID3MouseWheelDirection: UInt8, CaseIterable, Sendable {
    case up = 0x01
    case down = 0xff
}

public struct ReportID3MouseModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = Self(rawValue: 0x01)
    public static let shift = Self(rawValue: 0x02)
    public static let alt = Self(rawValue: 0x04)
}

public enum ReportID3EncodingError: Error, Equatable, Sendable {
    case unsupportedSlot
    case unsupportedLayer
    case invalidSequenceLength
    case invalidMouseButtons
    case invalidMouseModifiers
    case emptyMouseOperation
}

/// Pure source-derived Report ID 3 encodings. Only the programming service
/// decides which encoded assignment vectors can reach the USB transport.
public enum ReportID3KeyboardEncoder {
    /// Encodes a type-1 keyboard macro containing one through five strokes.
    public static func encode(
        slot: UInt8,
        layer: UInt8,
        strokes: [USBKeyboardStroke]
    ) throws -> [[UInt8]] {
        try validate(slot: slot, layer: layer)
        guard (1...5).contains(strokes.count) else {
            throw ReportID3EncodingError.invalidSequenceLength
        }

        let header: [UInt8] = [slot, (layer << 4) | 1, UInt8(strokes.count)]
        var reports = [layerSelectReport(layer)]
        reports.append(report(header + [0, strokes[0].modifiers, 0]))
        for (index, stroke) in strokes.enumerated() {
            reports.append(report(header + [UInt8(index + 1), stroke.modifiers, stroke.usage]))
        }
        reports.append(saveReport())
        return reports
    }

    /// Encodes a type-2 consumer-control assignment using a reviewed code.
    public static func encodeConsumerControl(
        slot: UInt8,
        layer: UInt8,
        code: ReportID3ConsumerControlCode
    ) throws -> [[UInt8]] {
        try validate(slot: slot, layer: layer)
        return [
            layerSelectReport(layer),
            report([slot, (layer << 4) | 2, code.rawValue, 0]),
            saveReport()
        ]
    }

    /// Encodes a type-3 mouse button or wheel assignment. At least one button
    /// or wheel direction must be present; unknown bit flags are rejected.
    public static func encodeMouse(
        slot: UInt8,
        layer: UInt8,
        buttons: ReportID3MouseButtons,
        wheel: ReportID3MouseWheelDirection? = nil,
        modifiers: ReportID3MouseModifiers = []
    ) throws -> [[UInt8]] {
        try validate(slot: slot, layer: layer)
        guard buttons.rawValue & ~UInt8(0x07) == 0 else {
            throw ReportID3EncodingError.invalidMouseButtons
        }
        guard modifiers.rawValue & ~UInt8(0x07) == 0 else {
            throw ReportID3EncodingError.invalidMouseModifiers
        }
        guard !buttons.isEmpty || wheel != nil else {
            throw ReportID3EncodingError.emptyMouseOperation
        }

        return [
            layerSelectReport(layer),
            report([
                slot,
                (layer << 4) | 3,
                buttons.rawValue,
                0,
                0,
                wheel?.rawValue ?? 0,
                modifiers.rawValue
            ]),
            saveReport()
        ]
    }

    private static func validate(slot: UInt8, layer: UInt8) throws {
        guard (1...6).contains(slot) || (13...15).contains(slot) else {
            throw ReportID3EncodingError.unsupportedSlot
        }
        guard (1...3).contains(layer) else {
            throw ReportID3EncodingError.unsupportedLayer
        }
    }

    private static func layerSelectReport(_ layer: UInt8) -> [UInt8] {
        report([0xa1, layer])
    }

    private static func saveReport() -> [UInt8] {
        report([0xaa, 0xaa])
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
