import Foundation
import Pocket3Core

extension AppModel {
    /// Developer-only native camera capture validation. The baseline is made
    /// exclusively from the current BLE status/property store; this route
    /// never performs an implicit GET, joins Wi-Fi, or creates a datalink.
    func handleNativeCameraCaptureValidation(_ request: ServiceRequest)
        async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "Native camera capture validation requires an explicit development launch")
        }

        let input: NativeCameraCaptureValidationRequest
        do {
            input = try NativeCameraCaptureValidationRequest(arguments: request.arguments)
        } catch let error as NativeCameraCaptureValidationError {
            throw nativeCameraCaptureValidationFailure(error)
        }

        let wireless = self.wireless
        let readiness = wireless.nativeSessionStatus
        let discovery = wireless.discovery
        guard input.expectedSessionID == readiness.sessionID,
              input.peripheralID == readiness.peerID,
              input.expectedSessionID == discovery.sessionID,
              input.peripheralID == discovery.selectedPeripheralID else {
            throw BridgeFailure("native_camera_capture_session_changed",
                "The requested native session or peer is no longer current")
        }

        let now = ProcessInfo.processInfo.systemUptime
        let baseline = nativeCameraCaptureBaseline(
            input.action, discovery: discovery, session: readiness,
            nowUptime: now)
        let snapshot = NativeCameraCaptureValidationSnapshot(session: readiness,
            baseline: baseline, nowUptime: now)
        do {
            // Dry-run remains the default. Explicit execution is bound to the
            // existing model owner and therefore cannot open a second link.
            let adapter = input.execute
                ? wireless.nativeCameraCaptureValidationAdapter() : nil
            let result = try await NativeCameraCaptureValidationService(
                adapter: adapter).run(input, snapshot: snapshot)
            return ServiceReply(id: request.id, result: try .encode(result))
        } catch let error as NativeCameraCaptureValidationError {
            throw nativeCameraCaptureValidationFailure(error)
        }
    }

    /// Selects one fresh status and, when required, one fresh named-property
    /// readback. A property baseline uses the older timestamp of its status
    /// and property samples so mixed-age fields cannot masquerade as one fresh
    /// baseline. Unknown raw enum values remain in the readback but fail the
    /// coordinator's known-target/mode gate.
    private func nativeCameraCaptureBaseline(
        _ action: NativeCameraCaptureValidationOperation,
        discovery: BluetoothDiscoveryStatus,
        session: NativeCameraSessionStatus,
        nowUptime: TimeInterval
    ) -> Pocket3NativeCameraReadback? {
        guard let sessionID = session.sessionID,
              let peripheralID = session.peerID,
              discovery.sessionID == sessionID,
              discovery.selectedPeripheralID == peripheralID,
              let status = discovery.cameraStatus,
              status.sessionID == sessionID,
              status.peripheralID == peripheralID,
              status.shootingModeRaw != nil,
              status.isFresh(nowUptime: nowUptime,
                             maximumAge: Pocket3NativeCameraReadback.maximumAge) else {
            return nil
        }

        let statusReadback = Pocket3NativeCameraReadback(
            sessionID: sessionID, generation: session.generation,
            receivedUptime: status.receivedUptime,
            modeRaw: status.shootingModeRaw,
            recordingStatus: status.recordingStatus)
        switch action {
        case .mode,
             .startTimelapse, .stopTimelapse, .startHyperlapse, .stopHyperlapse,
             .startMotionlapse, .stopMotionlapse:
            return statusReadback
        case .photoFrame, .photoFormat, .photoCountdown, .photoShutter:
            guard case .photoParameters(let value) = freshCameraReadOnlyValue(
                .photoParameters, discovery: discovery, sessionID: sessionID,
                peripheralID: peripheralID, nowUptime: nowUptime) else { return nil }
            return statusReadbackWith(statusReadback, receivedUptime: min(
                status.receivedUptime,
                latestCameraPropertyUptime(.photoParameters, discovery: discovery,
                    sessionID: sessionID, peripheralID: peripheralID,
                    nowUptime: nowUptime)), photo: value)
        case .panoramaType, .panoramaFormat, .panoramaShutter:
            guard case .panoramaParameters(let value) = freshCameraReadOnlyValue(
                .panoramaParameters, discovery: discovery, sessionID: sessionID,
                peripheralID: peripheralID, nowUptime: nowUptime) else { return nil }
            return statusReadbackWith(statusReadback, receivedUptime: min(
                status.receivedUptime,
                latestCameraPropertyUptime(.panoramaParameters, discovery: discovery,
                    sessionID: sessionID, peripheralID: peripheralID,
                    nowUptime: nowUptime)), panorama: value)
        case .timelapseConfiguration, .hyperlapseSpeed:
            guard case .lapseParameters(let value) = freshCameraReadOnlyValue(
                .lapseParameters, discovery: discovery, sessionID: sessionID,
                peripheralID: peripheralID, nowUptime: nowUptime) else { return nil }
            return statusReadbackWith(statusReadback, receivedUptime: min(
                status.receivedUptime,
                latestCameraPropertyUptime(.lapseParameters, discovery: discovery,
                    sessionID: sessionID, peripheralID: peripheralID,
                    nowUptime: nowUptime)), lapse: value)
        case .motionlapseConfiguration, .motionlapseDirection:
            guard case .motionlapseParameters(let value) = freshCameraReadOnlyValue(
                .motionlapseParameters, discovery: discovery, sessionID: sessionID,
                peripheralID: peripheralID, nowUptime: nowUptime) else { return nil }
            return statusReadbackWith(statusReadback, receivedUptime: min(
                status.receivedUptime,
                latestCameraPropertyUptime(.motionlapseParameters, discovery: discovery,
                    sessionID: sessionID, peripheralID: peripheralID,
                    nowUptime: nowUptime)), motionlapse: value)
        }
    }

    private func freshCameraReadOnlyValue(
        _ property: CameraSettingsProperty,
        discovery: BluetoothDiscoveryStatus,
        sessionID: UUID, peripheralID: UUID,
        nowUptime: TimeInterval
    ) -> CameraReadOnlyValue? {
        let binding = ContinuousGimbalBinding(
            sessionID: "ble:\(sessionID.uuidString)", generation: 0)
        return discovery.cameraSettingsObservations.reversed().first(where: {
            $0.property == property && $0.binding == binding &&
                $0.readOnlyValue != nil &&
                $0.isFresh(now: nowUptime,
                           maximumAge: Pocket3NativeCameraReadback.maximumAge)
        })?.readOnlyValue
    }

    private func latestCameraPropertyUptime(
        _ property: CameraSettingsProperty,
        discovery: BluetoothDiscoveryStatus,
        sessionID: UUID, peripheralID: UUID,
        nowUptime: TimeInterval
    ) -> TimeInterval {
        let binding = ContinuousGimbalBinding(
            sessionID: "ble:\(sessionID.uuidString)", generation: 0)
        return discovery.cameraSettingsObservations.reversed().first(where: {
            $0.property == property && $0.binding == binding &&
                $0.readOnlyValue != nil &&
                $0.isFresh(now: nowUptime,
                           maximumAge: Pocket3NativeCameraReadback.maximumAge)
        })?.receivedUptime ?? -.infinity
    }

    private func statusReadbackWith(
        _ status: Pocket3NativeCameraReadback,
        receivedUptime: TimeInterval,
        photo: CameraPhotoParameters? = nil,
        lapse: CameraLapseParameters? = nil,
        motionlapse: CameraMotionlapseParameters? = nil,
        panorama: CameraPanoramaParameters? = nil
    ) -> Pocket3NativeCameraReadback {
        Pocket3NativeCameraReadback(sessionID: status.sessionID,
            generation: status.generation, receivedUptime: receivedUptime,
            modeRaw: status.modeRaw,
            recordingStatus: status.recordingStatus,
            photo: photo, lapse: lapse, motionlapse: motionlapse,
            panorama: panorama)
    }
}

private func nativeCameraCaptureValidationFailure(
    _ error: NativeCameraCaptureValidationError
) -> BridgeFailure {
    switch error {
    case .invalidArguments:
        BridgeFailure("invalid_native_camera_capture_request",
            "Pass one typed camera capture action with exact session options")
    case .invalidAction:
        BridgeFailure("invalid_native_camera_capture_action",
            "Use mode, photo, panorama or bounded timelapse/hyperlapse/motionlapse actions")
    case .invalidValue:
        BridgeFailure("invalid_native_camera_capture_value",
            "The value is not a known capture enum or bounded configuration")
    case .invalidRequestIdentity:
        BridgeFailure("native_camera_capture_session_changed",
            "The requested native session, peer or generation is no longer current")
    case .invalidTimeout:
        BridgeFailure("invalid_native_camera_capture_timeout",
            "timeout must be between 0 and 5 seconds")
    case .sessionNotReady:
        BridgeFailure("native_camera_capture_command_not_ready",
            "Native camera capture validation requires a command-ready session")
    case .missingSessionIdentity:
        BridgeFailure("native_camera_capture_session_missing",
            "The native session has no exact camera identity")
    case .baselineRequired:
        BridgeFailure("native_camera_capture_baseline_missing",
            "A fresh 02/80 status and required named-property readback are required")
    case .invalidBaseline:
        BridgeFailure("native_camera_capture_baseline_invalid",
            "The baseline is stale, incomplete or belongs to another generation")
    case .alreadyAtTarget:
        BridgeFailure("native_camera_capture_noop",
            "The camera already reports the requested capture state")
    case .operationInFlight:
        BridgeFailure("native_camera_capture_validation_busy",
            "A native camera capture validation operation is already in flight")
    case .staleTransaction:
        BridgeFailure("native_camera_capture_transaction_stale",
            "The transaction belongs to another native generation")
    }
}
