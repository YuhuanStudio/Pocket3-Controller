import Foundation
import Pocket3Core

extension AppModel {
    /// Product IPC route for ordinary camera-side Video recording. It reuses
    /// WirelessGimbalModel's command-ready Pocket3Datalink owner and never
    /// creates a second Bluetooth or LAN transport.
    func handleCameraBodyRecording(_ request: ServiceRequest) async throws
        -> ServiceReply {
        let input: CameraBodyRecordingRequest
        do {
            input = try CameraBodyRecordingRequest(arguments: request.arguments)
        } catch CameraBodyRecordingRequestError.formatRequired {
            throw BridgeFailure("camera_body_format_required",
                "Format action requires a resolution and frame rate")
        } catch CameraBodyRecordingRequestError.invalidFormat,
                CameraBodyRecordingRequestError.formatNotAllowed {
            throw BridgeFailure("camera_body_format_invalid",
                "Use one known resolution and frame rate pair")
        } catch {
            throw BridgeFailure("invalid_camera_body_recording_request",
                "Pass action, exact native session/peer/generation and optional format")
        }

        let wireless = self.wireless
        let readiness = wireless.nativeSessionStatus
        let discovery = wireless.discovery
        guard input.expectedSessionID == readiness.sessionID,
              input.peripheralID == readiness.peerID,
              input.expectedSessionID == discovery.sessionID,
              input.peripheralID == discovery.selectedPeripheralID,
              input.generation == readiness.generation else {
            throw BridgeFailure("camera_body_recording_session_changed",
                "The requested native session, peer or generation is no longer current")
        }

        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = try cameraBodyRecordingSnapshot(
            readiness: readiness, discovery: discovery, nowUptime: now)

        // A body write must retire a currently held native gimbal lease before
        // it enters the datalink transaction owner. Dry-run only inspects the
        // already-cached snapshot and must not cancel another operation.
        if input.execute {
            await continuousGimbal.stop(reason: .cancelled)
            wireless.invalidatePendingOperations()
        }
        let adapter = input.execute
            ? wireless.nativeBodyValidationAdapter() : nil
        let service = CameraBodyRecordingService(
            adapter: adapter,
            cleanup: {
                await MainActor.run {
                    wireless.invalidatePendingOperations()
                }
                return true
            })
        do {
            let result = try await service.run(input, snapshot: snapshot)
            developerBodyValidationResult = result.validation
            return ServiceReply(id: request.id, result: try .encode(result))
        } catch let error as CameraBodyRecordingServiceError {
            throw cameraBodyRecordingFailure(error)
        } catch let error as NativeBodyValidationServiceError {
            throw cameraBodyValidationFailure(error)
        } catch let error as NativeBodyRecordingCoordinatorError {
            throw cameraBodyValidationFailure(error)
        } catch let error as NativeBodyFormatCoordinatorError {
            throw cameraBodyValidationFailure(error)
        }
    }

    private func cameraBodyRecordingSnapshot(
        readiness: NativeCameraSessionStatus,
        discovery: BluetoothDiscoveryStatus,
        nowUptime: TimeInterval
    ) throws -> NativeBodyValidationSnapshot {
        guard let sessionID = readiness.sessionID,
              let peripheralID = readiness.peerID,
              discovery.sessionID == sessionID,
              discovery.selectedPeripheralID == peripheralID,
              let status = discovery.cameraStatus,
              status.sessionID == sessionID,
              status.peripheralID == peripheralID,
              status.isFresh(nowUptime: nowUptime,
                             maximumAge: NativeBodyRecordingCoordinator.maximumReadbackAge),
              status.shootingMode != nil else {
            throw BridgeFailure("camera_body_recording_baseline_missing",
                "A fresh 02/80 Video status is required")
        }

        let recordingBaseline = NativeBodyRecordingLifecycleSample(
            sessionID: sessionID, generation: readiness.generation,
            receivedUptime: status.receivedUptime,
            status: status.recordingStatus)

        let settingsBinding = ContinuousGimbalBinding(
            sessionID: "ble:\(sessionID.uuidString)", generation: 0)
        let freshSettings = discovery.cameraSettingsObservations.reversed().filter {
            $0.binding == settingsBinding &&
                $0.isFresh(now: nowUptime,
                           maximumAge: NativeBodyFormatCoordinator.maximumReadbackAge)
        }
        let parametersObservation = freshSettings.first {
            $0.property == .videoParameters
        }
        let formatBaseline = parametersObservation.flatMap { observation
            -> NativeBodyFormatReadback? in
            guard case .videoParameters(let value) = observation.readOnlyValue else {
                return nil
            }
            return NativeBodyFormatReadback(
                sessionID: sessionID, generation: readiness.generation,
                receivedUptime: observation.receivedUptime,
                parameters: value)
        }
        let capabilities = freshSettings.first {
            $0.property == .videoFormatCapabilities
        }?.bodyRecordingCapabilities

        return NativeBodyValidationSnapshot(
            session: readiness,
            videoMode: status.shootingMode,
            recordingBaseline: recordingBaseline,
            formatBaseline: formatBaseline,
            formatCapabilities: capabilities,
            nowUptime: nowUptime)
    }
}

private func cameraBodyRecordingFailure(
    _ error: CameraBodyRecordingServiceError
) -> BridgeFailure {
    switch error {
    case .invalidRequestIdentity:
        BridgeFailure("camera_body_recording_session_changed",
            "The requested native session, peer or generation is no longer current")
    case .commandNotReady:
        BridgeFailure("camera_body_recording_command_not_ready",
            "Connect the existing native datalink before recording")
    case .videoModeRequired:
        BridgeFailure("camera_body_recording_video_mode_required",
            "The camera must report ordinary Video mode")
    case .recordingBaselineRequired:
        BridgeFailure("camera_body_recording_baseline_missing",
            "A fresh non-transitioning 02/80 status is required")
    case .formatBaselineRequired:
        BridgeFailure("camera_body_format_baseline_missing",
            "A fresh cam_video_param_v2 readback is required")
    case .legalCapabilityRequired:
        BridgeFailure("camera_body_format_capability_missing",
            "A fresh camcap_video_format legal table is required")
    case .formatNotAllowed:
        BridgeFailure("camera_body_format_not_allowed",
            "The selected resolution and frame rate are not a legal pair")
    }
}

private func cameraBodyValidationFailure(
    _ error: NativeBodyValidationServiceError
) -> BridgeFailure {
    switch error {
    case .formatRequired:
        BridgeFailure("camera_body_format_required",
            "Format action requires a resolution and frame rate")
    case .recordingBaselineRequired:
        BridgeFailure("camera_body_recording_baseline_missing",
            "A fresh 02/80 recording status is required")
    case .formatBaselineRequired:
        BridgeFailure("camera_body_format_baseline_missing",
            "A fresh cam_video_param_v2 readback is required")
    case .legalCapabilityRequired:
        BridgeFailure("camera_body_format_capability_missing",
            "A fresh camcap_video_format legal table is required")
    case .invalidClock:
        BridgeFailure("camera_body_recording_clock",
            "The body recording clock is invalid")
    case .invalidTimeout:
        BridgeFailure("camera_body_recording_timeout",
            "timeout must be between 0 and 5 seconds")
    }
}

private func cameraBodyValidationFailure(
    _ error: NativeBodyRecordingCoordinatorError
) -> BridgeFailure {
    switch error {
    case .sessionNotReady:
        BridgeFailure("camera_body_recording_command_not_ready",
            "The native command session is not ready")
    case .missingSessionIdentity:
        BridgeFailure("camera_body_recording_session_missing",
            "The native session has no exact identity")
    case .invalidBaseline:
        BridgeFailure("camera_body_recording_baseline_invalid",
            "The 02/80 baseline is stale or belongs to another session")
    case .alreadyAtTarget:
        BridgeFailure("camera_body_recording_noop",
            "The camera already reports the requested recording state")
    case .operationInFlight:
        BridgeFailure("camera_body_recording_busy",
            "A body recording operation is already in progress")
    case .staleTransaction:
        BridgeFailure("camera_body_recording_transaction_stale",
            "The transaction belongs to another native session")
    case .staleObservation:
        BridgeFailure("camera_body_recording_readback_stale",
            "The terminal recording readback is stale")
    case .invalidReadback:
        BridgeFailure("camera_body_recording_readback_invalid",
            "The terminal recording readback is invalid")
    }
}

private func cameraBodyValidationFailure(
    _ error: NativeBodyFormatCoordinatorError
) -> BridgeFailure {
    switch error {
    case .sessionNotReady:
        BridgeFailure("camera_body_recording_command_not_ready",
            "The native command session is not ready")
    case .missingSessionIdentity:
        BridgeFailure("camera_body_recording_session_missing",
            "The native session has no exact identity")
    case .invalidBaseline:
        BridgeFailure("camera_body_format_baseline_invalid",
            "The format baseline is stale or belongs to another session")
    case .missingCapabilityEvidence:
        BridgeFailure("camera_body_format_capability_missing",
            "No legal format capability evidence is available")
    case .unsupportedFormat:
        BridgeFailure("camera_body_format_not_allowed",
            "The selected pair is not in the current legal format table")
    case .alreadyAtTarget:
        BridgeFailure("camera_body_format_noop",
            "The camera already reports the selected format")
    case .operationInFlight:
        BridgeFailure("camera_body_recording_busy",
            "A body recording operation is already in progress")
    }
}
