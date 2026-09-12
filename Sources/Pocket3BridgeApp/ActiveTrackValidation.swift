import Foundation
import Pocket3Core

extension AppModel {
    /// Developer-only ActiveTrack validation endpoint. The current app passes
    /// no executor and no coordinate calibration, so this path can only return
    /// a strict dry-run plan or an explicit gate result.
    func handleActiveTrackValidation(_ request: ServiceRequest) async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "ActiveTrack validation requires an explicit development launch")
        }
        let input = try NativeActiveTrackValidationRequest(arguments: request.arguments)
        let wireless = self.wireless
        let snapshot = NativeActiveTrackValidationSnapshot(
            session: wireless.nativeSessionStatus,
            baseline: wireless.discovery.activeTrackObservations,
            coordinateCalibration: .unverified,
            nowUptime: ProcessInfo.processInfo.systemUptime)
        do {
            let result = try await NativeActiveTrackValidationService().run(input,
                                                                            snapshot: snapshot)
            return ServiceReply(id: request.id, result: try .encode(result))
        } catch let error as NativeActiveTrackValidationError {
            throw activeTrackValidationFailure(error)
        }
    }

    private func activeTrackValidationFailure(
        _ error: NativeActiveTrackValidationError
    ) -> BridgeFailure {
        switch error {
        case .invalidTrackingID:
            BridgeFailure("invalid_active_track_box",
                "set requires a non-zero id and a valid normalized tracking box")
        case .invalidRequestIdentity:
            BridgeFailure("native_active_track_session_changed",
                "The requested ActiveTrack session or native generation is no longer current")
        case .invalidTimeout:
            BridgeFailure("invalid_active_track_timeout",
                "timeout must be between 0 and 5 seconds")
        case .sessionNotReady:
            BridgeFailure("native_active_track_command_not_ready",
                "ActiveTrack validation requires a command-ready native session")
        case .missingSessionIdentity:
            BridgeFailure("native_active_track_session_missing",
                "The native session has no exact camera identity")
        case .baselineRequired:
            BridgeFailure("native_active_track_baseline_missing",
                "Fresh A5 and A89 readbacks from the same paired session are required")
        case .invalidBaseline:
            BridgeFailure("native_active_track_baseline_invalid",
                "The ActiveTrack baseline is unknown, stale or bound to another session")
        case .operationInFlight:
            BridgeFailure("native_active_track_validation_busy",
                "An ActiveTrack validation operation is already in flight")
        case .staleTransaction:
            BridgeFailure("native_active_track_transaction_stale",
                "The A6 transaction belongs to another native generation")
        case .uncalibratedCoordinates:
            BridgeFailure("active_track_coordinates_uncalibrated",
                "Rotation and mirror mapping are not calibrated; execute is disabled")
        }
    }
}
