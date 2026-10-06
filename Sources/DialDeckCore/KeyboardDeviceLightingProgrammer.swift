import Foundation

/// Adapts the runtime's narrow lighting command to the existing guarded
/// keyboard transport. The adapter exposes no report bytes or assignments.
public struct KeyboardDeviceLightingProgrammer: DeviceLightingProgramming {
    private let service: KeyboardDeviceProgrammingService

    public init(service: KeyboardDeviceProgrammingService = KeyboardDeviceProgrammingService()) {
        self.service = service
    }

    public func programLighting(_ request: LightingProgrammingRequest) async -> LightingProgrammingResult {
        guard request.acceptsPersistentOverwrite else {
            return LightingProgrammingResult(
                requestID: request.requestID,
                outcome: .failed(reason: "Persistent overwrite was not accepted", reportsAccepted: 0)
            )
        }

        let mode: DeviceLightingModeCandidate
        switch request.mode {
        case .mode1:
            mode = .mode1
        case .mode2:
            mode = .mode2
        }

        let serviceRequest = DeviceLightingModeRequest(
            id: request.requestID,
            mode: mode,
            acceptsPersistentOverwrite: request.acceptsPersistentOverwrite
        )
        let result = await service.programLighting(serviceRequest)
        let outcome: LightingProgrammingOutcome
        switch result.outcome {
        case .sentUnverified(let reportsAccepted):
            outcome = .sentUnverified(reportsAccepted: reportsAccepted)
        case .failed(let reason, let reportsAccepted):
            outcome = .failed(reason: reason, reportsAccepted: reportsAccepted)
        case .cancelled(let reportsAccepted):
            outcome = .cancelled(reportsAccepted: reportsAccepted)
        }
        return LightingProgrammingResult(requestID: result.id, outcome: outcome)
    }
}
