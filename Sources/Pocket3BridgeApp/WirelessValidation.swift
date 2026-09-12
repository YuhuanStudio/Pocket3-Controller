import Foundation
import Pocket3Core

extension AppModel {
    func handleWirelessValidation(_ request: ServiceRequest) async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled", "Wireless validation requires an explicit development launch.")
        }
        switch request.operation {
        case "validation-wireless-status": break
        case "validation-wireless-scan": await wireless.scan()
        case "validation-wireless-connect":
            guard let selected = request.arguments["peripheralID"].string, UUID(uuidString: selected) != nil else {
                throw BridgeFailure("bluetooth_selection_required", "Pass the exact peripheral UUID returned by the current scan.")
            }
            wireless.selectedPeripheral = selected
            try wireless.connectBluetooth()
        case "validation-wireless-pair":
            guard case .object(let fields) = request.arguments,
                  Set(fields.keys).isSubset(of: ["pairOnly"]),
                  fields["pairOnly"] == nil || fields["pairOnly"]?.bool != nil else {
                throw BridgeFailure("invalid_pairing_options", "Pairing accepts only an optional pairOnly Boolean; it never joins a network")
            }
            try wireless.pair(pairOnly: fields["pairOnly"]?.bool ?? true)
        case "validation-wireless-read-settings":
            guard request.arguments == .object([:]) else {
                throw BridgeFailure("invalid_camera_settings_read_arguments", "Read settings accepts no arguments")
            }
            wireless.readCameraSettings()
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while wireless.readingCameraSettings, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard !wireless.readingCameraSettings else {
                throw BridgeFailure("camera_settings_read_timeout", "Timed out waiting for the paired-camera settings reader")
            }
            await wireless.refresh()
            return ServiceReply(id: request.id, result: .object([
                "completed": .bool(wireless.issue == nil), "issue": wireless.issue.map(JSONValue.string) ?? .null,
                "observations": try .array(wireless.discovery.cameraSettingsObservations.map(JSONValue.encode)),
                "bluetooth": try .encode(wireless.discovery)
            ]))
        case "validation-wireless-probe": return try await performBluetoothGimbalProbe(request)
        case "validation-wireless-recenter": return try await performBluetoothNativeRecenter(request)
        case "validation-wireless-tap-focus": return try await performBluetoothTapFocus(request)
        case "validation-wireless-setting":
            let arguments = try BluetoothCameraSettingWriteRequest(arguments: request.arguments)
            return ServiceReply(id: request.id, result: try .encode(try await writeCameraSetting(arguments)))
        case "validation-wireless-lens":
            return ServiceReply(id: request.id, result: try .encode(try await wireless.bluetooth.queryLensState()))
        case "validation-wireless-lens-series":
            let arguments = try BluetoothLensSeriesRequest(arguments: request.arguments)
            return ServiceReply(id: request.id, result: try .encode(try await wireless.bluetooth.recordLensPoints(
                expectedSessionID: arguments.expectedSessionID, peripheralID: arguments.peripheralID)))
        case BluetoothCameraEventRecordingRequest.operation:
            let arguments = try BluetoothCameraEventRecordingRequest(arguments: request.arguments)
            return ServiceReply(id: request.id, result: try .encode(try await wireless.bluetooth.recordCameraEvents(
                expectedSessionID: arguments.expectedSessionID, peripheralID: arguments.peripheralID)))
        case "validation-wireless-property":
            guard let name = request.arguments["property"].string,
                  let property = CameraSettingsProperty(rawValue: name) else {
                throw BridgeFailure("invalid_camera_property", "Choose cam_lens_state, cam_image_effect or cam_expo_param")
            }
            return ServiceReply(id: request.id, result: try .encode(try await wireless.bluetooth.queryCameraProperty(property: property)))
        case "validation-wireless-readiness":
            let result = try await wireless.bluetooth.queryNativeReadiness()
            return ServiceReply(id: request.id, result: try .encode(result))
        case "validation-wireless-body":
            return try await performNativeBodyValidation(request)
        case "validation-wireless-join", "validation-wireless-datalink":
            throw BridgeFailure("wifi_control_disabled", "This project keeps the Mac on its current network. Camera Wi-Fi control is not an active connection path.")
        case "validation-wireless-disconnect": await wireless.disconnect()
        default: throw BridgeFailure("unknown_operation", "Unknown wireless validation operation.")
        }
        await wireless.refresh()
        return ServiceReply(id: request.id, result: try wireless.validationStatus())
    }

    /// Developer-only body command validation. The App supplies only the
    /// exact readiness/readback snapshot already owned by WirelessGimbalModel;
    /// command submission is intentionally absent until a future owner
    /// injects a NativeBodyValidationService executor.
    private func performNativeBodyValidation(_ request: ServiceRequest) async throws -> ServiceReply {
        guard case .object(let fields) = request.arguments else {
            throw BridgeFailure("invalid_body_validation_arguments", "Body validation requires an object of action options")
        }
        guard Set(fields.keys).isSubset(of: ["action", "execute", "resolution", "fps", "timeout"]) else {
            throw BridgeFailure("invalid_body_validation_arguments", "Use action, execute, resolution, fps and timeout only")
        }
        guard let action = fields["action"]?.string,
              let operation = NativeBodyValidationRequest.Operation(rawValue: action) else {
            throw BridgeFailure("invalid_body_validation_action", "Use action start, stop or format")
        }
        let execute: Bool
        if let value = fields["execute"] {
            guard let bool = value.bool else {
                throw BridgeFailure("invalid_body_validation_execute", "execute must be a Boolean")
            }
            execute = bool
        } else {
            execute = false
        }
        let timeout: TimeInterval
        if let value = fields["timeout"] {
            guard let number = value.number else {
                throw BridgeFailure("invalid_body_validation_timeout", "timeout must be a finite number of seconds")
            }
            timeout = number
        } else {
            timeout = NativeBodyValidationService.defaultTimeout
        }

        let format: CameraBodyRecordingFormatCommand?
        if operation == .format {
            guard let resolutionName = fields["resolution"]?.string,
                  let resolution = nativeBodyResolution(resolutionName),
                  let frameRateName = fields["fps"]?.string,
                  let frameRate = nativeBodyFrameRate(frameRateName) else {
                throw BridgeFailure("invalid_body_format", "Format validation requires a known resolution and fps")
            }
            format = CameraBodyRecordingFormatCommand(resolution: resolution, frameRate: frameRate)
        } else {
            guard fields["resolution"] == nil, fields["fps"] == nil else {
                throw BridgeFailure("invalid_body_validation_arguments", "resolution and fps are only valid for action format")
            }
            format = nil
        }

        let wireless = self.wireless
        let readiness = wireless.nativeSessionStatus
        let now = ProcessInfo.processInfo.systemUptime
        let discovery = wireless.discovery
        guard let sessionID = readiness.sessionID,
              sessionID == discovery.sessionID,
              let peripheralID = discovery.selectedPeripheralID else {
            throw BridgeFailure("native_body_session_missing", "Body validation requires the current selected native session")
        }

        let bodyStatus = discovery.cameraStatus.flatMap { observation -> NativeBodyRecordingLifecycleSample? in
            guard observation.sessionID == discovery.sessionID,
                  observation.peripheralID == peripheralID,
                  observation.isFresh(nowUptime: now,
                                      maximumAge: NativeBodyRecordingCoordinator.maximumReadbackAge) else { return nil }
            return NativeBodyRecordingLifecycleSample(sessionID: sessionID,
                generation: readiness.generation, receivedUptime: observation.receivedUptime,
                status: observation.recordingStatus)
        }

        let settingsBinding = "ble:\(discovery.sessionID.uuidString)"
        let freshSettings = discovery.cameraSettingsObservations.filter {
            $0.binding.sessionID == settingsBinding && $0.binding.generation == 0 &&
            $0.isFresh(now: now, maximumAge: NativeBodyFormatCoordinator.maximumReadbackAge)
        }
        let parametersObservation = freshSettings.first(where: { $0.property == .videoParameters })
        let formatParameters: CameraVideoParameters?
        if let parametersObservation,
           case .videoParameters(let parameters) = parametersObservation.readOnlyValue {
            formatParameters = parameters
        } else {
            formatParameters = nil
        }
        let capabilities = freshSettings.first(where: { $0.property == .videoFormatCapabilities })?.bodyRecordingCapabilities
        let formatBaseline: NativeBodyFormatReadback?
        if let parametersObservation, let formatParameters {
            formatBaseline = NativeBodyFormatReadback(sessionID: sessionID,
                generation: readiness.generation,
                receivedUptime: parametersObservation.receivedUptime,
                parameters: formatParameters)
        } else {
            formatBaseline = nil
        }
        let validationRequest = NativeBodyValidationRequest(operation: operation,
            execute: execute, format: format, timeout: timeout)
        developerBodyValidationResult = nil
        do {
            // Keep the default path read-only. An explicit --execute binds
            // only to WirelessGimbalModel's current datalink owner; if that
            // owner is absent or disarmed, the service returns partial
            // unavailable evidence without creating another transport.
            let adapter = execute ? wireless.nativeBodyValidationAdapter() : nil
            let service = NativeBodyValidationService(adapter: adapter)
            let result = try await service.run(validationRequest,
                snapshot: NativeBodyValidationSnapshot(session: readiness,
                    recordingBaseline: bodyStatus, formatBaseline: formatBaseline,
                    formatCapabilities: capabilities, nowUptime: now))
            developerBodyValidationResult = result
            return ServiceReply(id: request.id, result: try .encode(result))
        } catch let error as NativeBodyValidationServiceError {
            throw bodyValidationFailure(error)
        } catch let error as NativeBodyRecordingCoordinatorError {
            throw bodyValidationFailure(error)
        } catch let error as NativeBodyFormatCoordinatorError {
            throw bodyValidationFailure(error)
        }
    }

    private func bodyValidationFailure(_ error: NativeBodyValidationServiceError) -> BridgeFailure {
        switch error {
        case .formatRequired: BridgeFailure("invalid_body_format", "Format validation requires resolution and fps")
        case .recordingBaselineRequired: BridgeFailure("native_body_recording_baseline_missing", "No fresh current 02/80 body status is available")
        case .formatBaselineRequired: BridgeFailure("native_body_format_baseline_missing", "No fresh current cam_video_param_v2 readback is available")
        case .legalCapabilityRequired: BridgeFailure("native_body_format_capability_missing", "No fresh legal camcap_video_format readback is available")
        case .invalidClock: BridgeFailure("native_body_validation_clock", "The monotonic validation clock is invalid")
        case .invalidTimeout: BridgeFailure("native_body_validation_timeout", "timeout must be between 0 and 5 seconds")
        }
    }

    private func bodyValidationFailure(_ error: NativeBodyRecordingCoordinatorError) -> BridgeFailure {
        switch error {
        case .sessionNotReady: BridgeFailure("native_body_command_not_ready", "The native session is not command-ready")
        case .missingSessionIdentity: BridgeFailure("native_body_session_missing", "The native session has no exact identity")
        case .invalidBaseline: BridgeFailure("native_body_recording_baseline_invalid", "The body status baseline is stale or belongs to another session")
        case .alreadyAtTarget: BridgeFailure("native_body_recording_noop", "The camera is already in the requested recording state")
        case .operationInFlight: BridgeFailure("native_body_validation_busy", "A body validation operation is already in flight")
        case .staleTransaction: BridgeFailure("native_body_transaction_stale", "The transaction belongs to another session or generation")
        case .staleObservation: BridgeFailure("native_body_readback_stale", "The terminal body readback is stale")
        case .invalidReadback: BridgeFailure("native_body_readback_invalid", "The body readback is not a known terminal state")
        }
    }

    private func bodyValidationFailure(_ error: NativeBodyFormatCoordinatorError) -> BridgeFailure {
        switch error {
        case .sessionNotReady: BridgeFailure("native_body_command_not_ready", "The native session is not command-ready")
        case .missingSessionIdentity: BridgeFailure("native_body_session_missing", "The native session has no exact identity")
        case .invalidBaseline: BridgeFailure("native_body_format_baseline_invalid", "The format baseline is stale or belongs to another session")
        case .missingCapabilityEvidence: BridgeFailure("native_body_format_capability_missing", "No legal format capability evidence is available")
        case .unsupportedFormat: BridgeFailure("native_body_format_unsupported", "The selected body format is not in the current legal capability table")
        case .alreadyAtTarget: BridgeFailure("native_body_format_noop", "The camera already reports the selected body format")
        case .operationInFlight: BridgeFailure("native_body_validation_busy", "A body validation operation is already in flight")
        }
    }

    /// Shared by the developer RPC and the App's explicit setting action.
    /// The Discovery layer still requires the development launch independently.
    func writeCameraSetting(_ request: BluetoothCameraSettingWriteRequest) async throws -> BluetoothCameraSettingWriteResult {
        let bluetooth = wireless.bluetooth
        let execution = try await withBluetoothCameraWriteReservation(sessionID: request.expectedSessionID,
            peripheralID: request.peripheralID, captureSessionID: request.expectedCaptureSessionID,
            cancel: { permit in _ = await bluetooth.stopCameraSettingWrite(permit: permit) }) { context in
                try await bluetooth.writeCameraSetting(request: request, permit: context.permit,
                    validateCapture: context.validateCapture, validateCaptureSynchronously: context.validateCaptureSynchronously)
            }
        return execution.output
    }

    private func performBluetoothTapFocus(_ request: ServiceRequest) async throws -> ServiceReply {
        let arguments = try BluetoothTapFocusRequest(arguments: request.arguments)
        let bluetooth = wireless.bluetooth
        let execution = try await withBluetoothCameraWriteReservation(sessionID: arguments.expectedSessionID,
            peripheralID: arguments.peripheralID, captureSessionID: arguments.expectedCaptureSessionID,
            cancel: { permit in _ = await bluetooth.stopTapFocusProbe(permit: permit) }) { context in
                try await bluetooth.probeTapFocus(request: arguments, permit: context.permit,
                    validateCapture: context.validateCapture, validateCaptureSynchronously: context.validateCaptureSynchronously)
            }
        var output: [String: JSONValue] = ["probe": try .encode(execution.output), "beforeFrame": try .encode(execution.before),
            "cameraImagesIncluded": .bool(false), "usbBluetoothIdentityAssociated": .bool(false)]
        if let after = execution.after { output["afterFrame"] = try .encode(after) }
        return ServiceReply(id: request.id, result: .object(output))
    }

    private func withBluetoothCameraWriteReservation<Output: Sendable>(sessionID: UUID, peripheralID: UUID,
        captureSessionID: String, cancel: @escaping @MainActor @Sendable (OperationPermit) async -> Void,
        operation: @MainActor @Sendable (BluetoothCameraWriteContext) async throws -> Output
    ) async throws -> (output: Output, before: FrameInfo, after: FrameInfo?) {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled", "BLE camera setting writes require a development launch")
        }
        guard bluetoothProbePermit == nil else { throw BridgeFailure("probe_busy", "A Bluetooth camera operation is already active") }
        let bluetooth = wireless.bluetooth
        guard bluetooth.status.sessionID == sessionID, bluetooth.status.selectedPeripheralID == peripheralID,
              !bluetooth.status.nativeProbeActive else {
            throw BridgeFailure("bluetooth_camera_write_connection_changed", "Choose the exact idle paired Bluetooth session")
        }
        let before = try service.capture.store.latest(maxAge: 1).info
        guard before.sessionID == captureSessionID else {
            throw BridgeFailure("bluetooth_camera_write_capture_changed", "The requested USB capture session is no longer current")
        }
        let binding = ContinuousGimbalBinding(sessionID: "ble-camera-write:\(sessionID.uuidString):\(UUID().uuidString)", generation: 0)
        let permit = OperationPermit(), service = self.service
        bluetoothProbePermit = permit
        defer { if bluetoothProbePermit === permit { bluetoothProbePermit = nil } }
        cancelLensControlDrafts(); aiTask?.cancel()
        await continuousGimbal.stop(reason: .cancelled)
        try permit.perform {}
        await intelligence.cancelObservation()
        try permit.perform {}
        try await service.reserveNativeControl(binding: binding, readStatus: { NativeControlStatus(starting: true) }, writePermit: permit) {
            permit.invalidate()
            await cancel(permit)
            await service.releaseNativeControl(binding: binding)
            // Cancelling host work cannot undo an already-submitted camera
            // setting. No neutral, optical-stop or invented restore is sent.
            return MotionResult(accepted: true, completed: true, verified: false,
                verification: "ble_camera_write_cancelled_state_unconfirmed", target: nil, observed: nil,
                message: "Pending BLE camera writes cancelled; already submitted camera-side effects are unconfirmed")
        }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try permit.perform {}
            let context = BluetoothCameraWriteContext(permit: permit, validateCapture: {
                try await service.validateNativeControlReservation(binding: binding,
                    expectedCaptureSessionID: captureSessionID, writePermit: permit)
            }, validateCaptureSynchronously: {
                guard try service.capture.store.latest(maxAge: 1).info.sessionID == captureSessionID else {
                    throw BridgeFailure("bluetooth_camera_write_capture_changed", "The final USB capture identity changed")
                }
            })
            let output = try await operation(context)
            await service.releaseNativeControl(binding: binding)
            let candidate = try? service.capture.store.latest(maxAge: 1, after: started).info
            return (output, before, candidate?.sessionID == captureSessionID ? candidate : nil)
        } catch {
            permit.invalidate()
            await cancel(permit)
            await service.releaseNativeControl(binding: binding)
            throw error
        }
    }

    private func performBluetoothNativeRecenter(_ request: ServiceRequest) async throws -> ServiceReply {
        guard bluetoothProbePermit == nil else { throw BridgeFailure("probe_busy", "A Bluetooth probe is already active.") }
        await continuousGimbal.stop(reason: .cancelled)
        let bluetooth = wireless.bluetooth
        let session = bluetooth.status.sessionID
        let binding = ContinuousGimbalBinding(sessionID: "ble-recenter:\(session.uuidString)", generation: 0)
        let permit = OperationPermit()
        bluetoothProbePermit = permit
        defer { if bluetoothProbePermit === permit { bluetoothProbePermit = nil } }
        let before = await service.status()
        let service = self.service
        try await service.reserveNativeControl(binding: binding, readStatus: { NativeControlStatus(starting: true) }) {
            permit.invalidate()
            await bluetooth.cancelNativeRecenter()
            return try await service.stopNativeControlAndHold(binding: binding)
        }
        do {
            try permit.perform {}
            guard bluetooth.status.sessionID == session else { throw CancellationError() }
            aiTask?.cancel(); await intelligence.cancelObservation()
            let result = try await bluetooth.probeNativeRecenter(permit: permit)
            let afterNative = await service.status()
            let cleanup = try await service.stopNativeControlAndHold(binding: binding)
            return ServiceReply(id: request.id, result: .object([
                "probe": try .encode(result), "usbBefore": try .encode(before.gimbal),
                "usbAfterNative": try .encode(afterNative.gimbal), "cleanup": try .encode(cleanup),
                "nativeCapabilityConfirmed": .bool(false)]))
        } catch {
            permit.invalidate(); bluetooth.cancelNativeRecenter()
            _ = try? await service.stopNativeControlAndHold(binding: binding)
            throw error
        }
    }

    private func performBluetoothGimbalProbe(_ request: ServiceRequest) async throws -> ServiceReply {
        guard bluetoothProbePermit == nil else { throw BridgeFailure("probe_busy", "A Bluetooth probe is already active.") }
        let bluetooth = wireless.bluetooth
        let session = bluetooth.status.sessionID
        let binding = ContinuousGimbalBinding(sessionID: "ble-probe:\(session.uuidString)", generation: 0)
        let permit = OperationPermit()
        bluetoothProbePermit = permit
        defer { if bluetoothProbePermit === permit { bluetoothProbePermit = nil } }
        let before = try service.capture.store.latest()
        try await service.reserveNativeControl(binding: binding,
            readStatus: { NativeControlStatus(starting: true) }) {
                permit.invalidate()
                let result = await bluetooth.stopNativeProbe()
                return MotionResult(accepted: result?.neutralSent == true,
                    completed: result?.stableTelemetry == true, verified: result?.stableTelemetry == true,
                    verification: "ble_probe_neutral_and_pose_stability", target: nil, observed: nil,
                    message: result?.stableTelemetry == true ? "BLE 探測已停止，新的姿態回報已穩定" : "BLE 探測已撤回，停止回報尚未完整確認")
            }
        do {
            try permit.perform {}
            guard bluetooth.status.sessionID == session else { throw CancellationError() }
            aiTask?.cancel(); await intelligence.cancelObservation()
            try permit.perform {}
            let result = try await bluetooth.probeNativeJoystick(permit: permit)
            await service.releaseNativeControl(binding: binding)
            var metadata: [String: JSONValue] = ["probe": try .encode(result), "beforeFrame": try .encode(before.info)]
            do {
                let finished = ProcessInfo.processInfo.systemUptime
                var after: FramePacket?
                repeat {
                    try Task.checkCancellation()
                    if let candidate = try? service.capture.store.latest(after: finished) {
                        guard candidate.info.sessionID == before.info.sessionID else { throw BridgeFailure("session_changed", "Camera changed after the probe.") }
                        after = candidate; break
                    }
                    try await Task.sleep(for: .milliseconds(40))
                } while ProcessInfo.processInfo.systemUptime - finished < 1
                guard let after else { throw BridgeFailure("post_probe_frame_unavailable", "Probe finished, but a new video frame was unavailable. Do not repeat movement for an image.") }
                let (info, jpeg) = try await Task.detached { try after.jpegWithInfo(maxDimension: 1280) }.value
                metadata["afterFrame"] = try .encode(info)
                return ServiceReply(id: request.id, result: .object(metadata), imageJPEG: jpeg)
            } catch {
                metadata["imageError"] = .string((error as? BridgeFailure)?.code ?? "post_probe_frame_unavailable")
                return ServiceReply(id: request.id, result: .object(metadata))
            }
        } catch {
            permit.invalidate()
            _ = await bluetooth.stopNativeProbe()
            await service.releaseNativeControl(binding: binding)
            throw error
        }
    }
}

private struct BluetoothCameraWriteContext: Sendable {
    let permit: OperationPermit
    let validateCapture: @MainActor @Sendable () async throws -> Void
    let validateCaptureSynchronously: @MainActor @Sendable () throws -> Void
}

private func nativeBodyResolution(_ value: String) -> CameraVideoResolution? {
    switch value.lowercased().replacingOccurrences(of: " ", with: "") {
    case "p1080", "1080p": .p1080
    case "p2.7k", "p27k", "2.7k", "27k": .p2_7K
    case "p4k", "4k": .p4K
    case "square1080", "1:1-1080": .square1080
    case "square2160", "1:1-2160": .square2160
    case "square3k", "1:1-3k": .square3K
    case "portrait1080", "9:16-1080": .portrait1080
    case "portrait2.7k", "portrait27k", "9:16-2.7k": .portrait2_7K
    case "portrait3k", "9:16-3k": .portrait3K
    default: nil
    }
}

private func nativeBodyFrameRate(_ value: String) -> CameraFrameRate? {
    let normalized = value.lowercased().replacingOccurrences(of: " ", with: "")
    let number = normalized.hasPrefix("fps") ? String(normalized.dropFirst(3)) : normalized
    switch number {
    case "24": return .fps24
    case "25": return .fps25
    case "30": return .fps30
    case "48": return .fps48
    case "50": return .fps50
    case "60": return .fps60
    case "120": return .fps120
    case "240": return .fps240
    default: return nil
    }
}
