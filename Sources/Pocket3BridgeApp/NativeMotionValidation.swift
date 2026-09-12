import Foundation
import Pocket3Core

extension AppModel {
    /// Developer-only native zoom/gimbal validation. The snapshot is made from
    /// the already initialized wireless/native owner; this route never scans,
    /// pairs, joins Wi-Fi, or creates another datalink.
    func handleNativeMotionValidation(_ request: ServiceRequest) async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "Native motion validation requires an explicit development launch")
        }
        let input: NativeMotionValidationRequest
        do {
            input = try NativeMotionValidationRequest(arguments: request.arguments)
        } catch let error as NativeMotionValidationError {
            throw nativeMotionValidationFailure(error)
        }

        let wireless = self.wireless
        let readiness = wireless.nativeSessionStatus
        let discovery = wireless.discovery
        guard input.expectedSessionID == readiness.sessionID,
              input.peripheralID == readiness.peerID,
              input.expectedSessionID == discovery.sessionID,
              input.peripheralID == discovery.selectedPeripheralID else {
            throw BridgeFailure("native_motion_session_changed",
                "The requested native session or peer is no longer current")
        }

        let now = ProcessInfo.processInfo.systemUptime
        let zoomBaseline: Pocket3NativeLensStateObservation?
        if let sessionID = readiness.sessionID {
            let expectedBinding = ContinuousGimbalBinding(
                sessionID: "ble:\(sessionID.uuidString)", generation: 0)
            zoomBaseline = discovery.cameraSettingsObservations.reversed().compactMap { observation in
                guard observation.property == .lensState,
                      observation.binding == expectedBinding,
                      observation.isFresh(now: now,
                                          maximumAge: Pocket3NativeLensStateObservation.maximumAge) else {
                    return nil
                }
                return Pocket3NativeLensStateObservation(sessionID: sessionID,
                    generation: readiness.generation, observation: observation)
            }.first
        } else {
            zoomBaseline = nil
        }

        // There is no cached 04/50 native gimbal baseline in the existing
        // owner. Requiring one in the snapshot keeps this route from issuing
        // an implicit GET before a requested SET.
        let snapshot = NativeMotionValidationSnapshot(session: readiness,
            zoomBaseline: zoomBaseline, gimbalBaseline: nil, nowUptime: now)
        let adapter = input.execute ? wireless.nativeMotionValidationAdapter() : nil
        do {
            let result = try await NativeMotionValidationService(adapter: adapter).run(
                input, snapshot: snapshot)
            return ServiceReply(id: request.id, result: try .encode(result))
        } catch let error as NativeMotionValidationError {
            throw nativeMotionValidationFailure(error)
        }
    }

    private func nativeMotionValidationFailure(
        _ error: NativeMotionValidationError
    ) -> BridgeFailure {
        switch error {
        case .invalidArguments:
            BridgeFailure("invalid_native_motion_request", "Pass one native zoom or gimbal action with exact session options")
        case .invalidAction:
            BridgeFailure("invalid_native_motion_action", "Use zoom-absolute, zoom-relative, zoom-stop, gimbal-mode or gimbal-speed")
        case .invalidRequestIdentity:
            BridgeFailure("native_motion_session_changed", "The requested native session, peer or generation is no longer current")
        case .invalidTimeout:
            BridgeFailure("invalid_native_motion_timeout", "timeout must be between 0 and 5 seconds")
        case .sessionNotReady:
            BridgeFailure("native_motion_command_not_ready", "Native motion validation requires a command-ready session")
        case .missingSessionIdentity:
            BridgeFailure("native_motion_session_missing", "The native session has no exact camera identity")
        case .zoomBaselineRequired:
            BridgeFailure("native_motion_zoom_baseline_missing", "A fresh complete cam_lens_state readback is required")
        case .gimbalBaselineRequired:
            BridgeFailure("native_motion_gimbal_baseline_missing", "A fresh complete 04/50 readback is required before a gimbal SET")
        case .invalidBaseline:
            BridgeFailure("native_motion_baseline_invalid", "The baseline is stale, incomplete or belongs to another generation")
        case .invalidFormat:
            BridgeFailure("native_motion_zoom_format_invalid", "The absolute raw zoom target is outside the selected body-format bound")
        case .alreadyAtTarget:
            BridgeFailure("native_motion_noop", "The camera already reports the requested native state")
        case .operationInFlight:
            BridgeFailure("native_motion_validation_busy", "A native motion validation operation is already in flight")
        case .staleTransaction:
            BridgeFailure("native_motion_transaction_stale", "The transaction belongs to another native generation")
    }
}
}
