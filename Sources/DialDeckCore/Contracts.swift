import Foundation

/// An opaque identity for a physical input control. The raw value is supplied by
/// an adapter; this type makes no claim about device numbering or control layout.
public struct PhysicalControlID: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case key
        case dial
    }

    public let rawValue: String
    public let kind: Kind

    public init?(rawValue: String, kind: Kind) {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
        self.rawValue = trimmedValue
        self.kind = kind
    }
}

/// Monotonically increasing generation assigned to one input session.
public struct SessionGeneration: Hashable, Sendable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Normalized input independent of any device's protocol or physical mapping.
/// Use the validated factories so key events can only carry key IDs and rotation
/// events can only carry dial IDs.
public struct NormalizedInputEvent: Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case keyDown
        case keyUp
        /// Signed detent delta after adapter normalization. Its sign does not
        /// claim a verified direction mapping for any particular device.
        case dialRotation(delta: Int)
    }

    public let control: PhysicalControlID
    public let generation: SessionGeneration
    public let payload: Payload

    private init(control: PhysicalControlID, generation: SessionGeneration, payload: Payload) {
        self.control = control
        self.generation = generation
        self.payload = payload
    }

    public static func keyDown(
        control: PhysicalControlID,
        generation: SessionGeneration
    ) -> Self? {
        guard control.kind == .key else { return nil }
        return Self(control: control, generation: generation, payload: .keyDown)
    }

    public static func keyUp(
        control: PhysicalControlID,
        generation: SessionGeneration
    ) -> Self? {
        guard control.kind == .key else { return nil }
        return Self(control: control, generation: generation, payload: .keyUp)
    }

    public static func dialRotation(
        control: PhysicalControlID,
        delta: Int,
        generation: SessionGeneration
    ) -> Self? {
        guard control.kind == .dial else { return nil }
        return Self(control: control, generation: generation, payload: .dialRotation(delta: delta))
    }
}

/// Lifecycle events are associated with a generation so stale events can be
/// rejected after cancellation or reconnect.
public enum SessionLifecycleEvent: Equatable, Sendable {
    case started(SessionGeneration)
    case stopping(SessionGeneration)
    case stopped(SessionGeneration)
    case failed(SessionGeneration, reason: String)
}

public protocol InputSessionHandle: Sendable {
    var generation: SessionGeneration { get }
    /// Cancellation emits stopping/stopped lifecycle events, prevents future
    /// delivery for this generation, and returns only after teardown completes.
    func cancel() async
}

public protocol NormalizedInputConsumer: Sendable {
    func consume(_ event: NormalizedInputEvent) async
    func sessionLifecycleChanged(_ event: SessionLifecycleEvent) async
}

public protocol InputEventProducing: Sendable {
    func start(
        generation: SessionGeneration,
        consumer: any NormalizedInputConsumer
    ) async throws -> any InputSessionHandle
}

public enum DeviceDetectionState: Equatable, Sendable {
    case unknown
    case notDetected
    case detected
    case unavailable(reason: String)
}

public enum DeviceAccessState: Equatable, Sendable {
    case unknown
    case available
    case denied(reason: String)
    case unavailable(reason: String)
}

public enum CapabilityState: Equatable, Sendable {
    case unknown
    case supported
    case unsupported
    case requiresPermission
    case unavailable(reason: String)
}

/// Reported capability state. Unknown is the initial state; it does not imply
/// support or establish a physical control mapping.
public struct DeviceCapabilities: Equatable, Sendable {
    public var detection: DeviceDetectionState
    public var access: DeviceAccessState
    public var keyInput: CapabilityState
    public var dialInput: CapabilityState
    public var programming: CapabilityState
    public var persistence: CapabilityState

    public init(
        detection: DeviceDetectionState = .unknown,
        access: DeviceAccessState = .unknown,
        keyInput: CapabilityState = .unknown,
        dialInput: CapabilityState = .unknown,
        programming: CapabilityState = .unknown,
        persistence: CapabilityState = .unknown
    ) {
        self.detection = detection
        self.access = access
        self.keyInput = keyInput
        self.dialInput = dialInput
        self.programming = programming
        self.persistence = persistence
    }
}

public protocol DeviceCapabilityProviding: Sendable {
    func currentCapabilities() async -> DeviceCapabilities
}

/// An app-level intent for a future device adapter. It is not a protocol packet.
public struct ProgrammingRequest: Equatable, Sendable {
    public struct Assignment: Equatable, Sendable {
        public let control: PhysicalControlID
        public let actionIdentifier: String

        public init(control: PhysicalControlID, actionIdentifier: String) {
            self.control = control
            self.actionIdentifier = actionIdentifier
        }
    }

    public let requestID: UUID
    public let assignments: [Assignment]

    public init(requestID: UUID = UUID(), assignments: [Assignment]) {
        self.requestID = requestID
        self.assignments = assignments
    }
}

public struct VerificationEvidence: Equatable, Sendable {
    public let summary: String

    public init(summary: String) {
        self.summary = summary
    }
}

public struct ProgrammingFailure: Equatable, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// A single outcome avoids implying behavior or persistence from transmission.
public enum ProgrammingOutcome: Equatable, Sendable {
    case sentUnverified
    case failed(ProgrammingFailure)
    case behaviorVerified(VerificationEvidence)
    case persistenceVerified(VerificationEvidence)
}

public struct ProgrammingResult: Equatable, Sendable {
    public let requestID: UUID
    public let outcome: ProgrammingOutcome

    public init(requestID: UUID, outcome: ProgrammingOutcome) {
        self.requestID = requestID
        self.outcome = outcome
    }
}

public protocol DeviceProgramming: Sendable {
    func program(_ request: ProgrammingRequest) async -> ProgrammingResult
}

/// The two lighting behaviors observed on the supported keypad. This typed
/// request is deliberately separate from `ProgrammingRequest.Assignment`,
/// whose opaque action identifier must never be interpreted as USB data.
public enum RuntimeLightingMode: Equatable, Sendable {
    case mode1
    case mode2
}

/// Explicit request to overwrite the device's persistent lighting mode.
/// Callers must supply fresh acceptance for each write; there is no default.
public struct LightingProgrammingRequest: Equatable, Sendable {
    public let requestID: UUID
    public let mode: RuntimeLightingMode
    public let acceptsPersistentOverwrite: Bool

    public init(
        requestID: UUID = UUID(),
        mode: RuntimeLightingMode,
        acceptsPersistentOverwrite: Bool
    ) {
        self.requestID = requestID
        self.mode = mode
        self.acceptsPersistentOverwrite = acceptsPersistentOverwrite
    }
}

/// Result of one lighting write. `reportsAccepted` records host transport
/// acceptance only; it does not claim that the lighting behavior was verified.
public enum LightingProgrammingOutcome: Equatable, Sendable {
    case sentUnverified(reportsAccepted: Int)
    case failed(reason: String, reportsAccepted: Int)
    case cancelled(reportsAccepted: Int)
}

public struct LightingProgrammingResult: Equatable, Sendable {
    public let requestID: UUID
    public let outcome: LightingProgrammingOutcome

    public init(requestID: UUID, outcome: LightingProgrammingOutcome) {
        self.requestID = requestID
        self.outcome = outcome
    }
}

/// Typed runtime entry point for the observed lighting modes only.
public protocol DeviceLightingProgramming: Sendable {
    func programLighting(_ request: LightingProgrammingRequest) async -> LightingProgrammingResult
}

public enum RuntimeCommand: Equatable, Sendable {
    case start
    case stop
    case refreshCapabilities
    case program(ProgrammingRequest)
    case programLighting(LightingProgrammingRequest)
}

/// Completion returned to the UI-facing caller of `RuntimeCommandHandling`.
/// A `.program` command returns `.programming` with the same request ID and its
/// transmission/verification outcome; other commands return `.noProgrammingResult`.
public enum RuntimeCommandCompletion: Equatable, Sendable {
    case noProgrammingResult
    case programming(ProgrammingResult)
    case lightingProgramming(LightingProgrammingResult)
}

public enum RuntimeFailure: Equatable, Sendable {
    case inputAccessDenied
    case deviceUnavailable
    case operationFailed(reason: String)
}

public enum RuntimeStatus: Equatable, Sendable {
    case idle
    case starting
    case running(generation: SessionGeneration)
    case stopping(generation: SessionGeneration)
    case failed(RuntimeFailure)
}

public protocol RuntimeCommandHandling: Sendable {
    /// Awaits command completion. For `.program(request)`, the result's
    /// `requestID` must equal `request.requestID`.
    func submit(_ command: RuntimeCommand) async -> RuntimeCommandCompletion
}

public protocol RuntimeStatusProviding: Sendable {
    func currentStatus() async -> RuntimeStatus
}
