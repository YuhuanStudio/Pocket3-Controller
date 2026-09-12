import Foundation
import Pocket3Core

extension AppModel {
    /// Developer-only audio DSP validator. The initial A0 GET is the only
    /// source of the variable-length baseline; the service then owns the
    /// single 9F patch and matching verification GET.
    func handleNativeAudioDSPValidation(_ request: ServiceRequest) async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "Audio DSP validation requires an explicit development launch")
        }
        let input = try NativeAudioDSPValidationRequest(arguments: request.arguments)
        let wireless = self.wireless
        guard let sessionID = wireless.nativeSessionStatus.sessionID else {
            throw BridgeFailure("native_audio_dsp_session_missing",
                "The native session has no exact camera identity")
        }
        let binding = ContinuousGimbalBinding(
            sessionID: "ble:\(sessionID.uuidString)", generation: 0)
        let snapshot = NativeAudioDSPValidationSnapshot(
            session: wireless.nativeSessionStatus, binding: binding,
            baseline: nil, nowUptime: ProcessInfo.processInfo.systemUptime)
        do {
            let adapter = input.execute ? wireless.nativeAudioDSPValidationAdapter() : nil
            let service = NativeAudioDSPValidationService(adapter: adapter)
            let result = try await service.run(input, snapshot: snapshot)
            return ServiceReply(id: request.id, result: try .encode(result))
        } catch let error as NativeAudioDSPValidationError {
            throw nativeAudioDSPValidationFailure(error)
        }
    }

    private func nativeAudioDSPValidationFailure(
        _ error: NativeAudioDSPValidationError
    ) -> BridgeFailure {
        switch error {
        case .noRequestedChange:
            BridgeFailure("invalid_audio_dsp_change",
                "Pass wind, direction or both")
        case .invalidRequestIdentity:
            BridgeFailure("native_audio_dsp_session_changed",
                "The requested native session or generation is no longer current")
        case .invalidTimeout:
            BridgeFailure("invalid_audio_dsp_timeout",
                "timeout must be between 0 and 5 seconds")
        case .sessionNotReady:
            BridgeFailure("native_audio_dsp_command_not_ready",
                "Audio DSP validation requires a command-ready native session")
        case .missingSessionIdentity:
            BridgeFailure("native_audio_dsp_session_missing",
                "The native session has no exact camera identity")
        case .invalidBinding:
            BridgeFailure("native_audio_dsp_binding_invalid",
                "The audio DSP baseline is not bound to the selected BLE session")
        case .baselineRequired:
            BridgeFailure("native_audio_dsp_baseline_missing",
                "A fresh variable-length A0 audio DSP readback is required")
        case .invalidBaseline:
            BridgeFailure("native_audio_dsp_baseline_invalid",
                "The audio DSP baseline is stale, unknown or bound to another session")
        case .operationInFlight:
            BridgeFailure("native_audio_dsp_validation_busy",
                "An audio DSP validation operation is already in flight")
        case .staleTransaction:
            BridgeFailure("native_audio_dsp_transaction_stale",
                "The audio DSP transaction belongs to another native generation")
        }
    }
}
