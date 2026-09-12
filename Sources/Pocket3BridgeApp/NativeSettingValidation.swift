import Foundation
import Pocket3Core

extension AppModel {
    /// Developer-only native setting validation. Baselines come from the
    /// already-owned paired-camera property store; this route never performs
    /// an implicit GET, creates a datalink, or exposes a general UI writer.
    func handleNativeSettingValidation(_ request: ServiceRequest) async throws
        -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "Native setting validation requires an explicit development launch")
        }

        let input: NativeSettingValidationRequest
        do {
            input = try NativeSettingValidationRequest(arguments: request.arguments)
        } catch let error as NativeSettingValidationError {
            throw nativeSettingValidationFailure(error)
        }

        let wireless = self.wireless
        let readiness = wireless.nativeSessionStatus
        let discovery = wireless.discovery
        guard input.expectedSessionID == readiness.sessionID,
              input.peripheralID == readiness.peerID,
              input.expectedSessionID == discovery.sessionID,
              input.peripheralID == discovery.selectedPeripheralID else {
            throw BridgeFailure("native_setting_session_changed",
                "The requested native session or peer is no longer current")
        }

        let now = ProcessInfo.processInfo.systemUptime
        let baseline = nativeSettingBaseline(input.action,
            observations: discovery.cameraSettingsObservations,
            sessionID: input.expectedSessionID, generation: input.generation,
            nowUptime: now)
        let snapshot = NativeSettingValidationSnapshot(session: readiness,
            baseline: baseline, nowUptime: now)
        let adapter = input.execute ? wireless.nativeSettingValidationAdapter() : nil
        do {
            let result = try await NativeSettingValidationService(adapter: adapter).run(
                input, snapshot: snapshot)
            return ServiceReply(id: request.id, result: try .encode(result))
        } catch let error as NativeSettingValidationError {
            throw nativeSettingValidationFailure(error)
        }
    }

    private func nativeSettingBaseline(
        _ action: NativeSettingValidationOperation,
        observations: [CameraSettingsObservation],
        sessionID: UUID, generation: UInt64,
        nowUptime: TimeInterval
    ) -> Pocket3NativeSettingObservation? {
        let property: CameraSettingsProperty?
        switch action {
        case .whiteBalance, .colorProfile: property = .imageEffect
        case .focusMode: property = .lensState
        case .productShowcase:
            // Product Showcase is a keyed 02/8E reply, not a named 00/99
            // property. No cached GET evidence exists in this owner yet.
            property = nil
        }
        guard let property else { return nil }
        let binding = ContinuousGimbalBinding(
            sessionID: "ble:\(sessionID.uuidString)", generation: 0)
        guard let observation = observations.reversed().first(where: {
            $0.property == property && $0.binding == binding &&
                $0.isFresh(now: nowUptime,
                           maximumAge: Pocket3NativeSettingObservation.maximumAge) &&
                $0.readOnlyValue != nil
        }) else { return nil }
        return Pocket3NativeSettingObservation(sessionID: sessionID,
            generation: generation, observation: observation)
    }
}

private func nativeSettingValidationFailure(
    _ error: NativeSettingValidationError
) -> BridgeFailure {
    switch error {
    case .invalidArguments:
        BridgeFailure("invalid_native_setting_request",
            "Pass one typed native setting action, value and exact session options")
    case .invalidAction:
        BridgeFailure("invalid_native_setting_action",
            "Use white-balance, focus-mode, color-profile or product-showcase")
    case .invalidValue:
        BridgeFailure("invalid_native_setting_value",
            "The value is not a supported typed candidate for the selected action")
    case .invalidRequestIdentity:
        BridgeFailure("native_setting_session_changed",
            "The requested native session, peer or generation is no longer current")
    case .invalidTimeout:
        BridgeFailure("invalid_native_setting_timeout",
            "timeout must be between 0 and 5 seconds")
    case .sessionNotReady:
        BridgeFailure("native_setting_command_not_ready",
            "Native setting validation requires a command-ready session")
    case .missingSessionIdentity:
        BridgeFailure("native_setting_session_missing",
            "The native session has no exact camera identity")
    case .baselineRequired:
        BridgeFailure("native_setting_baseline_missing",
            "A fresh complete matching camera setting readback is required")
    case .invalidBaseline:
        BridgeFailure("native_setting_baseline_invalid",
            "The baseline is stale, incomplete or belongs to another property/generation")
    case .alreadyAtTarget:
        BridgeFailure("native_setting_noop",
            "The camera already reports the requested native setting")
    case .operationInFlight:
        BridgeFailure("native_setting_validation_busy",
            "A native setting validation operation is already in flight")
    case .staleTransaction:
        BridgeFailure("native_setting_transaction_stale",
            "The transaction belongs to another native generation")
    }
}
