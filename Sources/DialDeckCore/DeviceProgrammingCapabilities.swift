/// Physical controls in the upright orientation, with the knob above the keys.
public enum ObservedDeviceControl: String, CaseIterable, Sendable {
    case topLeftKey
    case topRightKey
    case middleLeftKey
    case middleRightKey
    case bottomLeftKey
    case bottomRightKey
    case knobClockwise
    case knobCounterclockwise
    case knobPress
}

/// One exact layer-1 unmodified keyboard vector observed on the user's keypad.
/// `usage` is a USB HID usage, not a macOS virtual key code; F16-F24 are
/// function-key usages rather than printable characters.
public struct ObservedPlainKeyVector: Equatable, Sendable {
    public let control: ObservedDeviceControl
    public let layer: UInt8
    public let slot: UInt8
    public let usage: UInt8

    fileprivate init(control: ObservedDeviceControl, slot: UInt8, usage: UInt8) {
        self.control = control
        self.layer = 1
        self.slot = slot
        self.usage = usage
    }
}

/// Read-only evidence for one observed keypad, not discovery of the currently
/// connected device. A write still needs a fresh, specific user decision, and
/// `sentUnverified` only confirms host report acceptance.
public struct ObservedDeviceProgrammingCapabilities: Equatable, Sendable {
    public static let observedUnit = Self()

    public let plainKeyVectors: [ObservedPlainKeyVector]
    public let lightingModes: [DeviceLightingModeCandidate]

    private init() {
        plainKeyVectors = [
            .init(control: .topLeftKey, slot: 3, usage: 0x6d),
            .init(control: .topRightKey, slot: 6, usage: 0x70),
            .init(control: .middleLeftKey, slot: 2, usage: 0x6c),
            .init(control: .middleRightKey, slot: 5, usage: 0x6f),
            .init(control: .bottomLeftKey, slot: 1, usage: 0x6b),
            .init(control: .bottomRightKey, slot: 4, usage: 0x6e),
            .init(control: .knobClockwise, slot: 15, usage: 0x73),
            .init(control: .knobCounterclockwise, slot: 13, usage: 0x71),
            .init(control: .knobPress, slot: 14, usage: 0x72)
        ]
        lightingModes = [.mode1, .mode2]
    }

    public func containsPlainKeyVector(layer: UInt8, slot: UInt8, usage: UInt8) -> Bool {
        plainKeyVectors.contains {
            $0.layer == layer && $0.slot == slot && $0.usage == usage
        }
    }

    public func containsLightingMode(_ mode: DeviceLightingModeCandidate) -> Bool {
        lightingModes.contains(mode)
    }
}
