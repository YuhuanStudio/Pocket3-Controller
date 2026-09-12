import Foundation
import Pocket3Core

extension AppModel {
    /// Developer-only native datalink tap-AF route. The current owner supplies
    /// no coordinate calibration or executor, so this endpoint is a dry-run
    /// plan and cannot submit the four camera commands.
    func handleNativeTapFocusValidation(_ request: ServiceRequest) async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "Native tap-AF validation requires an explicit development launch")
        }
        let input = try NativeTapFocusValidationRequest(arguments: request.arguments)
        let wireless = self.wireless
        let snapshot = NativeTapFocusValidationSnapshot(
            session: wireless.nativeSessionStatus,
            observations: wireless.discovery.cameraSettingsObservations,
            coordinateCalibration: .unverifiedLandscape,
            nowUptime: ProcessInfo.processInfo.systemUptime)
        do {
            let adapter = input.execute ? wireless.nativeTapFocusValidationAdapter() : nil
            let service = NativeTapFocusValidationService(adapter: adapter)
            let result = try await service.run(input, snapshot: snapshot)
            developerNativeTapFocusValidationResult = result
            return ServiceReply(id: request.id, result: try .encode(result))
        } catch let error as NativeTapFocusValidationError {
            throw nativeTapFocusValidationFailure(error)
        }
    }

    private func nativeTapFocusValidationFailure(
        _ error: NativeTapFocusValidationError
    ) -> BridgeFailure {
        switch error {
        case .invalidCoordinate:
            BridgeFailure("invalid_native_tap_focus_coordinates",
                "x and y must be finite normalized DJI coordinates in 0.1...0.9")
        case .invalidRequestIdentity:
            BridgeFailure("native_tap_focus_session_changed",
                "The requested native session or generation is no longer current")
        case .invalidTimeout:
            BridgeFailure("invalid_native_tap_focus_timeout",
                "timeout must be between 0 and 5 seconds")
        case .sessionNotReady:
            BridgeFailure("native_tap_focus_command_not_ready",
                "Tap-AF validation requires a command-ready native session")
        case .missingSessionIdentity:
            BridgeFailure("native_tap_focus_session_missing",
                "The native session has no exact camera identity")
        case .baselineRequired:
            BridgeFailure("native_tap_focus_baseline_missing",
                "Fresh known lens mode and automatic-exposure readbacks are required")
        case .invalidBaseline:
            BridgeFailure("native_tap_focus_baseline_invalid",
                "The lens/exposure baseline is stale or bound to another session")
        case .operationInFlight:
            BridgeFailure("native_tap_focus_validation_busy",
                "A native tap-AF validation operation is already in flight")
        case .staleTransaction:
            BridgeFailure("native_tap_focus_transaction_stale",
                "A tap-AF step belongs to another native generation")
        case .uncalibratedCoordinates:
            BridgeFailure("native_tap_focus_coordinates_uncalibrated",
                "Rotation and mirror mapping are not calibrated; execute is disabled")
        }
    }
}
