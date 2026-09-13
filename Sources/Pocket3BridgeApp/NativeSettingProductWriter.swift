import Foundation
import Pocket3Core

extension AppModel {
    func nativeSettingProductStatus() throws -> JSONValue {
        .object([
            "nativeReadiness": try .encode(wireless.nativeSessionStatus),
            "writers": try .encode(Pocket3WriterSupportReport.current.entries),
            "productWritesRequireRestore": .bool(true),
            "transport": .string(Pocket3WriterSupportReport.current.localTransport.rawValue)
        ])
    }

    /// General product writer for the four typed native setting candidates.
    /// It uses WirelessGimbalModel's existing command-ready datalink owner;
    /// no Bluetooth session, Station link or fallback transport is created
    /// here.
    func handleNativeSettingProductWrite(_ request: ServiceRequest)
        async throws -> ServiceReply {
        let input: NativeSettingValidationRequest
        do {
            input = try NativeSettingValidationRequest(arguments: request.arguments)
        } catch let error as NativeSettingValidationError {
            throw nativeSettingProductFailure(error)
        }
        guard input.execute else {
            throw BridgeFailure(
                "native_setting_execute_required",
                "Native setting writes require explicit execute=true")
        }

        let wireless = self.wireless
        let readiness = wireless.nativeSessionStatus
        let discovery = wireless.discovery
        guard input.expectedSessionID == readiness.sessionID,
              input.peripheralID == readiness.peerID,
              input.expectedSessionID == discovery.sessionID,
              input.peripheralID == discovery.selectedPeripheralID else {
            throw BridgeFailure(
                "native_setting_session_changed",
                "The requested native session or peer is no longer current")
        }
        let writer = NativeSettingProductWriterService(
            adapter: wireless.nativeSettingValidationAdapter())
        guard writer.isUnlocked(for: input.action) else {
            throw BridgeFailure(
                "native_setting_product_locked",
                "This native setting remains locked until its command-ready ACK/readback/restore evidence is accepted")
        }

        let now = ProcessInfo.processInfo.systemUptime
        let baseline = nativeSettingBaseline(
            input.action, observations: discovery.cameraSettingsObservations,
            sessionID: input.expectedSessionID, generation: input.generation,
            nowUptime: now)
        let snapshot = NativeSettingValidationSnapshot(
            session: readiness, baseline: baseline, nowUptime: now)
        do {
            let result = try await writer.write(input, snapshot: snapshot)
            return ServiceReply(id: request.id, result: try .encode(result))
        } catch let error as NativeSettingProductWriterError {
            throw nativeSettingProductFailure(error)
        } catch let error as NativeSettingValidationError {
            throw nativeSettingProductFailure(error)
        }
    }
}

private func nativeSettingProductFailure(
    _ error: NativeSettingProductWriterError
) -> BridgeFailure {
    switch error {
    case .unsupportedSetting:
        BridgeFailure("native_setting_product_unsupported",
            "This native setting has no supported product writer")
    case .executionNotUnlocked:
        BridgeFailure("native_setting_product_locked",
            "This native setting remains locked until its command-ready ACK/readback/restore evidence is accepted")
    case .executionRequired:
        BridgeFailure("native_setting_execute_required",
            "Native setting writes require explicit execute=true")
    case .restoreBaselineUnavailable:
        BridgeFailure("native_setting_restore_baseline_missing",
            "The exact typed baseline cannot be restored safely")
    case .targetNotCompleted:
        BridgeFailure("native_setting_target_unconfirmed",
            "The target did not receive matching ACK and readback")
    case .restoreNotCompleted:
        BridgeFailure("native_setting_restore_unconfirmed",
            "The captured baseline did not receive matching ACK and readback")
    case .restoreMismatch:
        BridgeFailure("native_setting_restore_mismatch",
            "The restored native setting does not match the captured baseline")
    }
}

private func nativeSettingProductFailure(
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
            "Native setting writes require a command-ready session")
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
            "A native setting operation is already in flight")
    case .staleTransaction:
        BridgeFailure("native_setting_transaction_stale",
            "The transaction belongs to another native generation")
    }
}
