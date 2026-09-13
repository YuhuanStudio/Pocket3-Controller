import Foundation
import Pocket3Core

extension AppModel {
    /// Developer-only station native gimbal acceptance.  The model supplies
    /// the exact station LAN link it already owns; this route never discovers,
    /// opens or replaces a datalink and never changes the Mac's Wi-Fi route.
    func handleNativeGimbalAcceptanceValidation(_ request: ServiceRequest)
        async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "Native gimbal acceptance requires an explicit development launch")
        }

        let input: Pocket3NativeGimbalAcceptanceValidationRequest
        do {
            input = try Pocket3NativeGimbalAcceptanceValidationRequest(
                arguments: request.arguments)
        } catch let error as Pocket3NativeGimbalAcceptanceError {
            throw nativeGimbalAcceptanceFailure(error)
        }

        do {
            let result = try await wireless.runNativeGimbalAcceptance(input)
            return ServiceReply(id: request.id, result: try .encode(result))
        } catch let error as Pocket3NativeGimbalAcceptanceError {
            throw nativeGimbalAcceptanceFailure(error)
        }
    }
}

private func nativeGimbalAcceptanceFailure(
    _ error: Pocket3NativeGimbalAcceptanceError
) -> BridgeFailure {
    switch error {
    case .invalidRequest:
        BridgeFailure("invalid_native_gimbal_acceptance_request",
            "Pass exact BLE/native session identities and bounded acceptance options")
    case .ownerUnavailable:
        BridgeFailure("native_gimbal_acceptance_owner_unavailable",
            "The current station datalink owner is unavailable")
    case .ownerNotReady:
        BridgeFailure("native_gimbal_acceptance_owner_not_ready",
            "The current station owner is not command-ready")
    case .stationIdentityMismatch:
        BridgeFailure("native_gimbal_acceptance_identity_mismatch",
            "The station BLE and LAN 07/07 identities do not match")
    case .connectionChanged:
        BridgeFailure("native_gimbal_acceptance_connection_changed",
            "The station session or native owner changed")
    case .timeout:
        BridgeFailure("native_gimbal_acceptance_timeout",
            "The bounded gimbal acceptance step timed out")
    case .neutralFailed:
        BridgeFailure("native_gimbal_acceptance_neutral_failed",
            "The existing gimbal owner did not reach neutral")
    }
}
