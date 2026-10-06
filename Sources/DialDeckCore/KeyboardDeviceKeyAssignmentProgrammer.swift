import Foundation

/// Adapts the runtime's bounded key assignment request to the guarded
/// keyboard programming service. The service remains responsible for target
/// validation and transport; acceptance is never treated as device readback.
public struct KeyboardDeviceKeyAssignmentProgrammer: DeviceKeyAssignmentProgramming {
    private let service: KeyboardDeviceProgrammingService

    public init(service: KeyboardDeviceProgrammingService = KeyboardDeviceProgrammingService()) {
        self.service = service
    }

    public func programKeyAssignment(
        _ request: KeyAssignmentProgrammingRequest
    ) async -> KeyAssignmentProgrammingResult {
        let candidate = request.candidate
        guard let stroke = USBKeyboardStroke(modifiers: 0, usage: candidate.usage) else {
            return KeyAssignmentProgrammingResult(
                requestID: request.requestID,
                outcome: .failed(reason: "Unsupported keyboard assignment", reportsAccepted: 0)
            )
        }

        let serviceRequest = KeyboardDeviceWriteRequest(
            id: request.requestID,
            slot: candidate.slot,
            strokes: [stroke],
            acceptsPersistentOverwrite: request.acceptsPersistentOverwrite
        )
        let result = await service.program(serviceRequest)
        let outcome: KeyAssignmentProgrammingOutcome
        switch result.outcome {
        case .sentUnverified(let reportsAccepted):
            outcome = .sentUnverified(reportsAccepted: reportsAccepted)
        case .failed(let reason, let reportsAccepted):
            outcome = .failed(reason: reason, reportsAccepted: reportsAccepted)
        case .cancelled(let reportsAccepted):
            outcome = .cancelled(reportsAccepted: reportsAccepted)
        }
        return KeyAssignmentProgrammingResult(requestID: result.id, outcome: outcome)
    }
}
