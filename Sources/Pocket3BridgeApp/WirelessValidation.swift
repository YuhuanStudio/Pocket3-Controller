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
        case "validation-wireless-pair": try wireless.pair()
        case "validation-wireless-probe": return try await performBluetoothGimbalProbe(request)
        case "validation-wireless-recenter": return try await performBluetoothNativeRecenter(request)
        case "validation-wireless-tap-focus": return try await performBluetoothTapFocus(request)
        case "validation-wireless-lens":
            return ServiceReply(id: request.id, result: try .encode(try await wireless.bluetooth.queryLensState()))
        case "validation-wireless-lens-series":
            let arguments = try BluetoothLensSeriesRequest(arguments: request.arguments)
            return ServiceReply(id: request.id, result: try .encode(try await wireless.bluetooth.recordLensPoints(
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
        case "validation-wireless-join", "validation-wireless-datalink":
            throw BridgeFailure("wifi_control_disabled", "This project keeps the Mac on its current network. Camera Wi-Fi control is not an active connection path.")
        case "validation-wireless-disconnect": await wireless.disconnect()
        default: throw BridgeFailure("unknown_operation", "Unknown wireless validation operation.")
        }
        await wireless.refresh()
        return ServiceReply(id: request.id, result: try wireless.validationStatus())
    }

    private func performBluetoothTapFocus(_ request: ServiceRequest) async throws -> ServiceReply {
        let arguments = try BluetoothTapFocusRequest(arguments: request.arguments)
        guard bluetoothProbePermit == nil else { throw BridgeFailure("probe_busy", "A Bluetooth probe is already active") }
        let bluetooth = wireless.bluetooth
        guard bluetooth.status.sessionID == arguments.expectedSessionID,
              bluetooth.status.selectedPeripheralID == arguments.peripheralID,
              !bluetooth.status.nativeProbeActive else {
            throw BridgeFailure("bluetooth_focus_connection_changed", "Choose the exact idle paired Bluetooth session")
        }
        let before = try service.capture.store.latest(maxAge: 1).info
        guard before.sessionID == arguments.expectedCaptureSessionID else {
            throw BridgeFailure("bluetooth_focus_capture_changed", "The requested USB capture session is no longer current")
        }
        // Every attempt has its own service identity: a late old cleanup cannot
        // release/cancel a later attempt using the same BLE/USB connections.
        let binding = ContinuousGimbalBinding(sessionID: "ble-tap-focus:\(arguments.expectedSessionID.uuidString):\(UUID().uuidString)", generation: 0)
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
            _ = await bluetooth.stopTapFocusProbe(permit: permit)
            await service.releaseNativeControl(binding: binding)
            // This cancels future steps only. It neither claims to halt optical
            // AF nor sends an invented camera AE/focus restore command.
            return MotionResult(accepted: true, completed: true, verified: false,
                verification: "ble_focus_steps_cancelled_camera_state_unconfirmed", target: nil, observed: nil,
                message: "Pending BLE focus steps cancelled; previously submitted camera-side effects are unconfirmed")
        }
        do {
            try permit.perform {}
            let result = try await bluetooth.probeTapFocus(request: arguments, permit: permit, validateCapture: {
                try await service.validateNativeControlReservation(binding: binding,
                    expectedCaptureSessionID: arguments.expectedCaptureSessionID, writePermit: permit)
            }, validateCaptureSynchronously: {
                guard try service.capture.store.latest(maxAge: 1).info.sessionID == arguments.expectedCaptureSessionID else {
                    throw BridgeFailure("bluetooth_focus_capture_changed", "The final USB capture identity changed")
                }
            })
            await service.releaseNativeControl(binding: binding)
            var output: [String: JSONValue] = ["probe": try .encode(result), "beforeFrame": try .encode(before),
                "cameraImagesIncluded": .bool(false), "usbBluetoothIdentityAssociated": .bool(false)]
            if let after = try? service.capture.store.latest(maxAge: 1, after: result.startedUptime).info,
               after.sessionID == arguments.expectedCaptureSessionID {
                output["afterFrame"] = try .encode(after)
            }
            return ServiceReply(id: request.id, result: .object(output))
        } catch {
            permit.invalidate()
            _ = await bluetooth.stopTapFocusProbe(permit: permit)
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
