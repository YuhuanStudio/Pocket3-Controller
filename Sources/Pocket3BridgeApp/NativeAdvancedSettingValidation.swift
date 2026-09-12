import Foundation
import Pocket3Core

extension AppModel {
    /// Developer-only advanced-setting validation. The current discovery
    /// snapshot has no cached keyed `02/8E` observations, so ISO/audio/Vocal
    /// SETs remain baseline-gated and no GET is issued implicitly here.
    func handleNativeAdvancedSettingValidation(_ request: ServiceRequest)
        async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "Native advanced-setting validation requires an explicit development launch")
        }
        let input: NativeAdvancedSettingValidationRequest
        do {
            input = try NativeAdvancedSettingValidationRequest(arguments: request.arguments)
        } catch let error as NativeAdvancedSettingValidationError {
            throw nativeAdvancedSettingValidationFailure(error)
        }

        let wireless = self.wireless
        let readiness = wireless.nativeSessionStatus
        let discovery = wireless.discovery
        guard input.expectedSessionID == readiness.sessionID,
              input.peripheralID == readiness.peerID,
              input.expectedSessionID == discovery.sessionID,
              input.peripheralID == discovery.selectedPeripheralID else {
            throw BridgeFailure("native_advanced_setting_session_changed",
                "The requested native session or peer is no longer current")
        }

        let snapshot = NativeAdvancedSettingValidationSnapshot(
            session: readiness, baseline: nil,
            nowUptime: ProcessInfo.processInfo.systemUptime)
        let adapter = input.execute
            ? wireless.nativeAdvancedSettingValidationAdapter() : nil
        do {
            let result = try await NativeAdvancedSettingValidationService(
                adapter: adapter).run(input, snapshot: snapshot)
            return ServiceReply(id: request.id, result: try .encode(result))
        } catch let error as NativeAdvancedSettingValidationError {
            throw nativeAdvancedSettingValidationFailure(error)
        }
    }
}

private func nativeAdvancedSettingValidationFailure(
    _ error: NativeAdvancedSettingValidationError
) -> BridgeFailure {
    switch error {
    case .invalidArguments:
        BridgeFailure("invalid_native_advanced_setting_request",
            "Pass one advanced-setting action, exact session identity and its typed value")
    case .invalidAction:
        BridgeFailure("invalid_native_advanced_setting_action",
            "Use med-tele, iso-limit, audio-channel, vocal-boost or selfie-flip-get")
    case .invalidValue:
        BridgeFailure("invalid_native_advanced_setting_value",
            "The value is outside the reviewed typed candidate domain")
    case .invalidRequestIdentity:
        BridgeFailure("native_advanced_setting_session_changed",
            "The requested native session, peer or generation is no longer current")
    case .invalidTimeout:
        BridgeFailure("invalid_native_advanced_setting_timeout",
            "timeout must be between 0 and 5 seconds")
    case .sessionNotReady:
        BridgeFailure("native_advanced_setting_command_not_ready",
            "Advanced-setting validation requires a command-ready native session")
    case .missingSessionIdentity:
        BridgeFailure("native_advanced_setting_session_missing",
            "The native session has no exact camera identity")
    case .baselineRequired:
        BridgeFailure("native_advanced_setting_baseline_missing",
            "A fresh typed 02/8E readback baseline is required before this SET")
    case .invalidBaseline:
        BridgeFailure("native_advanced_setting_baseline_invalid",
            "The supplied baseline is stale, unknown or bound to another setting")
    case .alreadyAtTarget:
        BridgeFailure("native_advanced_setting_noop",
            "The camera already reports the requested setting")
    case .operationInFlight:
        BridgeFailure("native_advanced_setting_validation_busy",
            "An advanced-setting validation operation is already in flight")
    case .staleTransaction:
        BridgeFailure("native_advanced_setting_transaction_stale",
            "The transaction belongs to another native generation")
    case .unsupportedNoProtocol:
        BridgeFailure("unsupported_no_protocol",
            "This Pocket 3 setting has no confirmed command and matching readback protocol")
    }
}
