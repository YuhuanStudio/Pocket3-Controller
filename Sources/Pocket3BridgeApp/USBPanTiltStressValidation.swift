import Foundation
import Pocket3Core

@MainActor private var usbPanTiltStressRunning = false

/// Developer-only presentation for the scalar stress report. It deliberately
/// has no image field and keeps the plan visible when a range was supplied.
private enum USBPanTiltStressAppPresentation {
    static func dryRun(_ request: USBPanTiltStressRequest) throws -> JSONValue {
        let plan: JSONValue
        if let range = request.declaredRange {
            plan = try .encode(
                USBPanTiltStressAcceptance.dryRunPlan(range: range))
        } else {
            plan = .null
        }
        return .object([
            "operation": .string(USBPanTiltStressRequest.operation),
            "executeRequested": .bool(false),
            "hardwareValidation": .bool(true),
            "bounded": .bool(true),
            "rangeRequiredForExecute": .bool(true),
            "plan": plan,
            "request": try .encode(request),
            "cameraImagesStored": .bool(false),
            "physicalMotionVerified": .bool(false)
        ])
    }

    static func result(
        request: USBPanTiltStressRequest,
        report: USBPanTiltStressReport,
        evaluation: USBPanTiltStressEvaluation
    ) throws -> JSONValue {
        .object([
            "operation": .string(USBPanTiltStressRequest.operation),
            "executeRequested": .bool(request.execute),
            "hardwareValidation": .bool(true),
            "bounded": .bool(true),
            "report": try .encode(report),
            "evaluation": try .encode(evaluation),
            "cameraImagesStored": .bool(false),
            "physicalMotionVerified": .bool(false)
        ])
    }
}

private struct USBPanTiltStressStableWindow: Sendable {
    let first: GimbalPosition?
    let last: GimbalPosition?
    let count: Int
    let duration: TimeInterval
    let motionStopped: Bool
    let stable: Bool
}

/// Read-only helpers for the existing CameraService owner. No snapshot or
/// pixel-buffer operation is reachable from this file.
private enum USBPanTiltStressValidationSupport {
    static func binding(from status: ServiceStatus)
        throws -> USBManualAcceptanceBinding {
        guard let deviceID = status.selected?.id,
              !status.capture.sessionID.isEmpty,
              let gimbal = status.gimbal,
              let registryID = gimbal.registryID,
              let bootSessionID = gimbal.bootSessionID,
              !registryID.isEmpty, !bootSessionID.isEmpty else {
            throw BridgeFailure("usb_pan_tilt_stress_binding_missing",
                "The current USB status has no complete attachment binding")
        }
        return USBManualAcceptanceBinding(
            deviceID: deviceID,
            captureSessionID: status.capture.sessionID,
            registryID: registryID, bootSessionID: bootSessionID)
    }

    static func observation(service: CameraService)
        async throws -> USBPanTiltStressHardwareObservation {
        let sampled = ProcessInfo.processInfo.systemUptime
        let status = await service.status()
        let binding = try binding(from: status)
        guard let capabilities = status.gimbal else {
            throw BridgeFailure("usb_pan_tilt_stress_gimbal_missing",
                "The current USB status has no gimbal capability")
        }
        let frame: USBManualFrameEvidence?
        if let info = status.capture.frame {
            frame = USBManualFrameEvidence(
                frameID: info.id, sessionID: info.sessionID,
                deviceID: info.deviceID,
                receivedUptime: info.receivedUptime,
                sampledUptime: sampled,
                age: sampled - info.receivedUptime,
                width: info.width, height: info.height)
        } else {
            frame = nil
        }
        return USBPanTiltStressHardwareObservation(
            binding: binding, capabilities: capabilities,
            frame: frame, sampledUptime: sampled,
            phase: status.phase, motionActive: status.motionActive)
    }

    static func stableWindow(
        service: CameraService,
        binding: USBManualAcceptanceBinding,
        maximumDuration: TimeInterval = 0.6
    ) async -> USBPanTiltStressStableWindow {
        let started = ProcessInfo.processInfo.systemUptime
        var values: [(GimbalPosition, TimeInterval)] = []
        while ProcessInfo.processInfo.systemUptime - started <= maximumDuration {
            if let observation = try? await observation(service: service),
               observation.binding == binding,
               observation.phase == "ready", !observation.motionActive {
                values.append((observation.capabilities.position,
                               observation.sampledUptime))
                if values.count >= USBPanTiltStressAcceptance.minimumStopSamples,
                   let first = values.first, let last = values.last,
                   last.1 - first.1 >= USBPanTiltStressAcceptance.minimumStopDuration {
                    let pan = values.map { Int64($0.0.pan) }
                    let tilt = values.map { Int64($0.0.tilt) }
                    let stable = (pan.max()! - pan.min()!) <=
                            USBPanTiltStressAcceptance.positionJitterToleranceRaw &&
                        (tilt.max()! - tilt.min()!) <=
                            USBPanTiltStressAcceptance.positionJitterToleranceRaw &&
                        first.0.distance(to: last.0) <=
                            USBPanTiltStressAcceptance.restorationToleranceRaw
                    if stable {
                        return USBPanTiltStressStableWindow(
                            first: first.0, last: last.0, count: values.count,
                            duration: last.1 - first.1,
                            motionStopped: true, stable: true)
                    }
                }
            }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { break }
        }
        let first = values.first?.0
        let last = values.last?.0
        let duration: TimeInterval
        if let firstTime = values.first?.1,
           let lastTime = values.last?.1 {
            duration = max(0, lastTime - firstTime)
        } else {
            duration = 0
        }
        return USBPanTiltStressStableWindow(
            first: first, last: last, count: values.count,
            duration: duration, motionStopped: !values.isEmpty,
            stable: false)
    }
}

extension AppModel {
    /// Runs the bounded 16-case USB pan/tilt stress matrix through
    /// CameraService's existing UVC owner. The route is developer-only and
    /// dry-run by default; it never asks AVFoundation for an image payload.
    func handleUSBPanTiltStress(_ request: ServiceRequest) async throws
        -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "USB pan/tilt stress requires a development launch")
        }

        let input: USBPanTiltStressRequest
        do {
            input = try USBPanTiltStressRequest(arguments: request.arguments)
        } catch USBPanTiltStressRequestError.identityRequired {
            throw BridgeFailure("usb_pan_tilt_stress_identity_required",
                "Execute requires the exact current device and capture session")
        } catch USBPanTiltStressRequestError.rangeRequired {
            throw BridgeFailure("usb_pan_tilt_stress_range_required",
                "Execute requires the exact declared fresh pan/tilt range")
        } catch {
            throw BridgeFailure("invalid_usb_pan_tilt_stress_arguments",
                "Use the bounded USB pan/tilt stress arguments")
        }

        if !input.execute {
            return ServiceReply(id: request.id,
                result: try USBPanTiltStressAppPresentation.dryRun(input))
        }
        guard !usbPanTiltStressRunning else {
            throw BridgeFailure("usb_pan_tilt_stress_busy",
                "A USB pan/tilt stress run is already in progress")
        }
        usbPanTiltStressRunning = true
        defer { usbPanTiltStressRunning = false }

        guard let range = input.declaredRange,
              let expectedDeviceID = input.expectedDeviceID,
              let expectedSessionID = input.expectedSessionID else {
            throw BridgeFailure("usb_pan_tilt_stress_identity_required",
                "Execute requires the exact current device, session and range")
        }

        // Retire a UI gesture before admitting the developer collector. Both
        // calls stay on the existing owners; no native or Station channel is
        // initialized here.
        await continuousGimbal.stop(reason: .cancelled)
        _ = try? await service.stop()
        await service.setAccess(.manual)

        let initial = await service.status()
        guard initial.phase == "ready", !initial.motionActive,
              initial.selected?.id == expectedDeviceID,
              initial.capture.sessionID == expectedSessionID,
              initial.controlTransport == "usb_position",
              let mode = initial.requestedMode else {
            throw BridgeFailure("usb_pan_tilt_stress_not_ready",
                "Execute requires a ready USB position capture session")
        }
        guard let initialGimbal = initial.gimbal,
              initialGimbal.writable,
              initialGimbal.minimum == range.minimum,
              initialGimbal.maximum == range.maximum,
              initialGimbal.position == range.center else {
            throw BridgeFailure("usb_pan_tilt_stress_range_changed",
                "The declared range is not the exact fresh USB range")
        }
        let initialBinding = try USBPanTiltStressValidationSupport.binding(
            from: initial)
        guard initialBinding.deviceID == expectedDeviceID,
              initialBinding.captureSessionID == expectedSessionID else {
            throw BridgeFailure("usb_pan_tilt_stress_session_changed",
                "The requested USB attachment is no longer current")
        }
        let initialPixelFormat = initial.requestedPixelFormat ?? .automatic
        let initialOutputPolicy = initial.requestedOutputPolicy ?? .bgra
        let cameraService = service

        let adapter = USBPanTiltStressExecutorAdapter(
            read: {
                try await USBPanTiltStressValidationSupport.observation(
                    service: cameraService)
            },
            startMove: { target, sessionID in
                Task { () throws -> MotionResult in
                    try await cameraService.validationUSBPanTiltTarget(
                        target, expectedSessionID: sessionID)
                }
            },
            stop: {
                let result = try await cameraService.stop()
                let stable = await USBPanTiltStressValidationSupport.stableWindow(
                    service: cameraService, binding: initialBinding)
                let submitted = result.accepted && result.target != nil
                let verified = submitted && result.verified && stable.stable
                return USBManualStopEvidence(
                    submitted: submitted, verified: verified,
                    motionStopped: stable.motionStopped,
                    held: result.target ?? stable.first,
                    final: result.observed ?? stable.last,
                    stableSampleCount: stable.count,
                    stableDurationSeconds: stable.duration,
                    failureCode: verified ? nil :
                        result.verification == "no_active_action"
                            ? "usb_pan_tilt_stress_stop_not_submitted"
                            : result.verification)
            },
            restore: { origin, sessionID in
                let result = try await cameraService.validationUSBPanTiltTarget(
                    origin, expectedSessionID: sessionID)
                let binding = USBManualAcceptanceBinding(
                    deviceID: expectedDeviceID,
                    captureSessionID: sessionID,
                    registryID: initialBinding.registryID,
                    bootSessionID: initialBinding.bootSessionID)
                let stable = await USBPanTiltStressValidationSupport.stableWindow(
                    service: cameraService, binding: binding)
                let verified = result.accepted && result.verified && stable.stable
                return USBManualRestoreEvidence(
                    requested: origin,
                    observed: result.observed ?? stable.last,
                    submitted: result.accepted, verified: verified,
                    stableSampleCount: stable.count,
                    stableDurationSeconds: stable.duration,
                    failureCode: verified ? nil : result.verification)
            },
            reconnect: { oldBinding, request in
                guard oldBinding == initialBinding else {
                    throw BridgeFailure("usb_pan_tilt_stress_session_changed",
                        "The old stress binding changed before reconnect")
                }
                await cameraService.pause()
                try await cameraService.connect(
                    id: expectedDeviceID, mode: mode,
                    pixelFormat: initialPixelFormat,
                    outputPolicy: initialOutputPolicy,
                    validationStartupTimeout: min(30,
                        max(1, request.timeout / 2)),
                    validationSkipUVC: false)
                let status = await cameraService.status()
                let newBinding = try USBPanTiltStressValidationSupport.binding(
                    from: status)
                let newFrame = try? await USBPanTiltStressValidationSupport
                    .observation(service: cameraService)
                let newReady = status.phase == "ready" &&
                    !status.motionActive &&
                    newBinding.deviceID == expectedDeviceID &&
                    newBinding.captureSessionID != oldBinding.captureSessionID &&
                    newFrame?.frame?.isFresh(
                        for: newBinding,
                        maximumAge: USBPanTiltStressPlan.maximumFrameAgeSeconds) == true

                // CameraService checks expectedSessionID before any UVC SET,
                // so this old-session probe proves suppression without sending
                // a stale target to the replacement attachment.
                var oldOperationSuppressed = false
                do {
                    _ = try await cameraService.validationUSBPanTiltTarget(
                        range.center,
                        expectedSessionID: oldBinding.captureSessionID)
                } catch let error as BridgeFailure
                    where error.code == "session_changed" {
                    oldOperationSuppressed = true
                } catch {
                    oldOperationSuppressed = false
                }
                return USBManualReconnectFenceMetric(
                    oldBinding: oldBinding, newBinding: newBinding,
                    oldOperationStopped: true,
                    oldOperationSuppressed: oldOperationSuppressed,
                    newSessionReady: newReady)
            },
            cleanup: {
                do {
                    let result = try await cameraService.stop()
                    return result.verified
                } catch {
                    return false
                }
            })

        let report = await USBPanTiltStressAcceptance.execute(
            input, adapter: adapter)
        let evaluation = USBPanTiltStressAcceptance.evaluate(report)
        status = await cameraService.status()
        return ServiceReply(id: request.id,
            result: try USBPanTiltStressAppPresentation.result(
                request: input, report: report, evaluation: evaluation))
    }
}
