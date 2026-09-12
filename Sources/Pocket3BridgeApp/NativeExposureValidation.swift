import Foundation
import Pocket3Core

extension AppModel {
    /// Developer-only exposure validation. All baselines come from the
    /// already admitted Bluetooth property store; this route never performs
    /// an implicit GET, creates a link, joins Wi-Fi, or exposes a normal UI
    /// writer. `--execute` is the only path that asks WirelessGimbalModel for
    /// its existing single-owner datalink adapter.
    func handleNativeExposureValidation(_ request: ServiceRequest)
        async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "Native exposure validation requires an explicit development launch")
        }

        let input: NativeExposureValidationRequest
        do {
            input = try NativeExposureValidationRequest(arguments: request.arguments)
        } catch let error as Pocket3ExposureValidationError {
            throw nativeExposureValidationFailure(error)
        }

        let wireless = self.wireless
        let readiness = wireless.nativeSessionStatus
        let discovery = wireless.discovery
        guard input.expectedSessionID == readiness.sessionID,
              input.peripheralID == readiness.peerID,
              input.expectedSessionID == discovery.sessionID,
              input.peripheralID == discovery.selectedPeripheralID else {
            throw BridgeFailure("native_exposure_session_changed",
                "The requested native session or peer is no longer current")
        }

        let now = ProcessInfo.processInfo.systemUptime
        let exposure = nativeExposureBaseline(discovery: discovery,
            session: readiness, nowUptime: now)
        let modeContext = nativeExposureModeContext(discovery: discovery,
            nowUptime: now)
        // The current read-only store has no keyed 02/8E cache. Keeping this
        // nil makes ISO-limit execute fail closed with baselineRequired rather
        // than silently issuing a GET to manufacture one.
        let snapshot = Pocket3ExposureValidationSnapshot(
            session: readiness, exposure: exposure, isoLimit: nil,
            modeContext: modeContext, nowUptime: now)

        do {
            let adapter = input.execute
                ? wireless.nativeExposureValidationAdapter() : nil
            let result = try await NativeExposureValidationService(adapter: adapter)
                .run(input, snapshot: snapshot)
            // Keep only the credential-free, typed validation evidence for the
            // developer Disclosure. It is memory-only and remains fenced by
            // the exact native session in the presentation layer.
            developerExposureValidationResult = result
            return ServiceReply(id: request.id, result: try .encode(result))
        } catch let error as Pocket3ExposureValidationError {
            throw nativeExposureValidationFailure(error)
        }
    }

    private func nativeExposureBaseline(
        discovery: BluetoothDiscoveryStatus,
        session: NativeCameraSessionStatus,
        nowUptime: TimeInterval
    ) -> Pocket3ExposureObservation? {
        guard let sessionID = session.sessionID,
              let peripheralID = session.peerID,
              discovery.sessionID == sessionID,
              discovery.selectedPeripheralID == peripheralID else { return nil }
        let binding = ContinuousGimbalBinding(
            sessionID: "ble:\(sessionID.uuidString)", generation: 0)
        return discovery.cameraSettingsObservations.reversed().compactMap { value in
            guard value.property == .exposure,
                  value.binding == binding,
                  value.isFresh(now: nowUptime,
                                maximumAge: Pocket3ExposureObservation.maximumAge) else {
                return nil
            }
            return Pocket3ExposureObservation(sessionID: sessionID,
                generation: session.generation, observation: value)
        }.first
    }

    private func nativeExposureModeContext(
        discovery: BluetoothDiscoveryStatus,
        nowUptime: TimeInterval
    ) -> Pocket3ExposureModeContext {
        let modeRaw: UInt8?
        if let status = discovery.cameraStatus,
           status.isFresh(nowUptime: nowUptime,
                          maximumAge: 5) {
            modeRaw = status.shootingModeRaw
        } else {
            modeRaw = nil
        }
        let frameRateRaw = discovery.cameraSettingsObservations.reversed()
            .first(where: {
                $0.property == .videoParameters &&
                $0.isFresh(now: nowUptime,
                           maximumAge: Pocket3ExposureObservation.maximumAge)
            })
            .flatMap { observation -> UInt8? in
                guard case .videoParameters(let value) = observation.readOnlyValue else {
                    return nil
                }
                return value.frameRateRaw
            }
        return Pocket3ExposureModeContext(shootingModeRaw: modeRaw,
                                          frameRateRaw: frameRateRaw)
    }
}

private func nativeExposureValidationFailure(
    _ error: Pocket3ExposureValidationError
) -> BridgeFailure {
    switch error {
    case .invalidArguments:
        BridgeFailure("invalid_native_exposure_request",
            "Pass one exposure action, exact session identity and its typed value")
    case .invalidValue:
        BridgeFailure("invalid_native_exposure_value",
            "The exposure value is outside the reviewed typed candidate domain")
    case .invalidRequestIdentity:
        BridgeFailure("native_exposure_session_changed",
            "The requested native session, peer or generation is no longer current")
    case .invalidTimeout:
        BridgeFailure("invalid_native_exposure_timeout",
            "timeout must be between 0 and 5 seconds")
    case .sessionNotReady:
        BridgeFailure("native_exposure_command_not_ready",
            "Exposure validation requires a command-ready native session")
    case .missingSessionIdentity:
        BridgeFailure("native_exposure_session_missing",
            "The native session has no exact camera identity")
    case .baselineRequired:
        BridgeFailure("native_exposure_baseline_missing",
            "A fresh typed cam_expo_param or ISO-limit baseline is required")
    case .invalidBaseline:
        BridgeFailure("native_exposure_baseline_invalid",
            "The exposure baseline is stale, incomplete or bound to another generation")
    case .alreadyAtTarget:
        BridgeFailure("native_exposure_noop",
            "The camera already reports the requested exposure value")
    case .operationInFlight:
        BridgeFailure("native_exposure_validation_busy",
            "An exposure validation operation is already in flight")
    case .staleTransaction:
        BridgeFailure("native_exposure_transaction_stale",
            "The exposure transaction belongs to another native generation")
    case .unsupportedMode:
        BridgeFailure("native_exposure_mode_unsupported",
            "The selected exposure value is not valid for the current camera mode")
    case .unsupportedFrameRate:
        BridgeFailure("native_exposure_frame_rate_unsupported",
            "The current FPS does not provide a confirmed shutter lower bound")
    case .cancelled:
        BridgeFailure("native_exposure_cancelled", "Exposure validation was cancelled")
    case .executorUnavailable:
        BridgeFailure("native_exposure_executor_unavailable",
            "The existing native datalink owner is unavailable")
    }
}
