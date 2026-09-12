import Foundation
import Pocket3Core

/// The manual USB acceptance route is deliberately separate from ordinary
/// camera commands.  It is admitted only by a development launch flag and is
/// serialized so an acceptance run cannot race a normal gesture or zoom.
@MainActor private var usbManualAcceptanceRunning = false

private struct USBManualAcceptanceStageError: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

private struct USBManualAcceptanceStatusSample: Sendable {
    let status: ServiceStatus
    let sampledUptime: TimeInterval
}

extension AppModel {
    /// Runs the bounded, developer-only manual USB acceptance path.  A dry run
    /// returns the same typed plan used by the metrics evaluator and performs
    /// no service/status call.  Execute drives only the existing AppModel
    /// continuous-control endpoint and CameraService UVC transaction owner.
    func handleUSBManualAcceptance(_ request: ServiceRequest) async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled", "USB manual acceptance requires --hardware-validation")
        }

        let arguments: USBManualAcceptanceRequest
        do {
            arguments = try USBManualAcceptanceRequest(arguments: request.arguments)
        } catch USBManualAcceptanceRequestError.identityRequired {
            throw BridgeFailure("identity_required", "Execute requires the exact current --device and --session")
        } catch {
            throw BridgeFailure("invalid_usb_manual_acceptance_arguments", "Use the bounded USB manual acceptance arguments")
        }

        guard !usbManualAcceptanceRunning else {
            throw BridgeFailure("validation_busy", "A USB manual acceptance run is already in progress")
        }
        usbManualAcceptanceRunning = true
        defer { usbManualAcceptanceRunning = false }

        if !arguments.execute {
            return ServiceReply(id: request.id, result: try acceptancePlanPayload(arguments))
        }

        return try await runUSBManualAcceptance(arguments, requestID: request.id)
    }

    private func acceptancePlanPayload(_ request: USBManualAcceptanceRequest) throws -> JSONValue {
        .object([
            "operation": .string(USBManualAcceptanceRequest.operation),
            "executeRequested": .bool(request.execute),
            "hardwareValidation": .bool(true),
            "bounded": .bool(true),
            "cameraImagesStored": .bool(false),
            "physicalMotionVerified": .bool(false),
            "plan": try .encode(USBManualAcceptanceExecutor.dryRunPlan()),
            "remainingPhysicalSteps": .array(USBManualAcceptanceExecutor.remainingPhysicalSteps.map(JSONValue.string))
        ])
    }

    private func runUSBManualAcceptance(
        _ request: USBManualAcceptanceRequest,
        requestID: String
    ) async throws -> ServiceReply {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + request.timeout
        var stage = "initial_status"
        var failure: String?
        var initialBinding: USBManualAcceptanceBinding?
        var finalBinding: USBManualAcceptanceBinding?
        var initialStatus: ServiceStatus?
        var baselineFrames: [USBManualFrameEvidence] = []
        var gimbalHolds: [USBManualGimbalHoldMetric] = []
        var zoomMetric: USBManualZoomMetric?
        var reconnectMetric: USBManualReconnectFenceMetric?
        var initialGimbalOrigin: GimbalPosition?
        var initialZoomOrigin: Int?
        var activeBinding: USBManualAcceptanceBinding?

        do {
            var status = await service.status()
            try validateInitialStatus(status, request: request)
            guard let binding = acceptanceBinding(from: status) else {
                throw USBManualAcceptanceStageError("binding_missing", "Current USB status has no complete device/session binding")
            }
            try validate(binding: binding, status: status, request: request)
            initialBinding = binding
            activeBinding = binding
            initialStatus = status
            initialGimbalOrigin = status.gimbal?.position

            // Manual acceptance owns the manual USB path for its complete
            // bounded run.  This does not send a camera command.
            await service.setAccess(.manual)
            status = await service.status()
            try validate(binding: binding, status: status, request: request)
            guard status.phase == "ready", !status.motionActive else {
                throw USBManualAcceptanceStageError("camera_not_ready", "USB capture/control is not idle and ready")
            }
            initialStatus = status
            initialGimbalOrigin = status.gimbal?.position

            stage = "baseline_fresh_frame"
            baselineFrames = try await collectBaseline(
                binding: binding, deadline: min(deadline, started + 5))
            try checkDeadline(deadline)

            guard let zoom = try? await service.zoomCapabilities(
                expectedSessionID: binding.captureSessionID),
                  zoom.writable,
                  let low = zoom.minimum, let high = zoom.maximum,
                  let step = zoom.step, step > 0, low <= zoom.current,
                  zoom.current <= high else {
                throw USBManualAcceptanceStageError("zoom_capability_missing", "Current USB zoom range is not writable and complete")
            }
            initialZoomOrigin = zoom.current

            let matrix: [(USBManualAcceptanceAxis, USBManualAcceptanceProfile, Int, ContinuousGimbalInput)] = [
                (.pan, .near, 1, .init(x: 0.25, y: 0)),
                (.pan, .far, 1, .init(x: 0.80, y: 0)),
                (.tilt, .near, 1, .init(x: 0, y: -0.25)),
                (.tilt, .far, 1, .init(x: 0, y: -0.80))
            ]
            for (axis, profile, direction, input) in matrix {
                stage = "\(axis.rawValue)_\(profile.rawValue)_continuous_hold"
                try checkDeadline(deadline)
                let current = try await currentAcceptanceStatus(
                    binding: binding, request: request)
                guard current.status.phase == "ready", !current.status.motionActive,
                      let origin = current.status.gimbal?.position else {
                    throw USBManualAcceptanceStageError("gimbal_baseline_missing", "No fresh idle UVC gimbal baseline is available")
                }
                let hold = await collectGimbalHold(
                    axis: axis, profile: profile, direction: direction,
                    input: input, origin: origin, binding: binding,
                    holdSeconds: request.holdSeconds, deadline: deadline)
                gimbalHolds.append(hold)
                // A failed hold is retained as partial evidence and fences the
                // rest of the run.  A second writer after an uncertain stop is
                // not safe.
                guard hold.stop.verified, hold.restore.verified else {
                    throw USBManualAcceptanceStageError(
                        hold.stop.failureCode ?? hold.restore.failureCode ?? "gimbal_hold_failed",
                        "A bounded gimbal hold or restore was not verified")
                }
            }

            stage = "zoom_progress_and_verified_stop"
            zoomMetric = try await collectZoom(
                binding: binding, origin: initialZoomOrigin!,
                deadline: deadline, holdSeconds: request.holdSeconds)
            guard zoomMetric?.stop.verified == true,
                  zoomMetric?.restore.verified == true else {
                throw USBManualAcceptanceStageError("zoom_validation_failed", "Zoom stop or restore was not verified")
            }

            stage = "reconnect_old_session_fence"
            reconnectMetric = try await reconnectAndFence(
                oldBinding: binding, initial: initialStatus!,
                deadline: deadline)
            finalBinding = reconnectMetric?.newBinding
            activeBinding = finalBinding

            stage = "restore_gimbal_and_zoom"
            let finalStatus = await service.status()
            guard let endBinding = acceptanceBinding(from: finalStatus) else {
                throw USBManualAcceptanceStageError("final_binding_missing", "Reconnect did not publish a complete final binding")
            }
            try validate(binding: endBinding, status: finalStatus, request: nil)
            finalBinding = endBinding
            guard finalStatus.phase == "ready", !finalStatus.motionActive,
                  let finalGimbal = finalStatus.gimbal?.position,
                  let finalZoom = try? await service.zoomCapabilities(
                      expectedSessionID: endBinding.captureSessionID) else {
                throw USBManualAcceptanceStageError("final_restore_missing", "Final USB state is not fresh and ready")
            }

            let report = USBManualAcceptanceReport(
                initialBinding: initialBinding!, baselineFrames: baselineFrames,
                gimbalHolds: gimbalHolds, zoom: zoomMetric!,
                reconnect: reconnectMetric!, finalBinding: endBinding,
                finalGimbalPosition: finalGimbal,
                finalZoomRaw: finalZoom.current,
                cameraImagesStored: false, physicalMotionVerified: false)
            let evaluation = USBManualAcceptanceExecutor.evaluate(report)
            return ServiceReply(id: requestID, result: try acceptanceResultPayload(
                request: request, stage: "completed", failure: nil,
                baselineFrames: baselineFrames, gimbalHolds: gimbalHolds,
                zoom: zoomMetric, reconnect: reconnectMetric,
                report: report, evaluation: evaluation))
        } catch is CancellationError {
            failure = "cancelled"
        } catch let error as USBManualAcceptanceStageError {
            failure = error.code
        } catch let error as BridgeFailure {
            failure = error.code
        } catch {
            failure = "usb_manual_acceptance_failed"
        }

        // Cancellation/failure cleanup is awaited before returning the partial
        // result.  It is always fenced by the currently observed binding and
        // never sends an old-session restore to a replacement attachment.
        await cleanupUSBManualAcceptance(
            binding: activeBinding, gimbalOrigin: initialGimbalOrigin,
            zoomOrigin: initialZoomOrigin)
        return ServiceReply(id: requestID, result: try acceptanceResultPayload(
            request: request, stage: stage, failure: failure,
            baselineFrames: baselineFrames, gimbalHolds: gimbalHolds,
            zoom: zoomMetric, reconnect: reconnectMetric,
            report: nil, evaluation: nil))
    }

    private func validateInitialStatus(
        _ status: ServiceStatus,
        request: USBManualAcceptanceRequest
    ) throws {
        guard status.selected != nil, !status.capture.sessionID.isEmpty,
              status.phase == "ready", !status.motionActive,
              status.controlTransport == "usb_position" else {
            throw USBManualAcceptanceStageError(
                "usb_capture_not_ready",
                "USB capture must be ready with the ordinary usb_position control transport")
        }
        guard let deviceID = status.selected?.id,
              deviceID == request.expectedDeviceID,
              status.capture.sessionID == request.expectedSessionID else {
            throw USBManualAcceptanceStageError(
                "session_changed",
                "The requested device/session is not the current USB attachment")
        }
        guard let gimbal = status.gimbal, gimbal.writable,
              let low = gimbal.minimum, let high = gimbal.maximum,
              low.pan <= high.pan, low.tilt <= high.tilt,
              gimbal.position.pan >= low.pan, gimbal.position.pan <= high.pan,
              gimbal.position.tilt >= low.tilt, gimbal.position.tilt <= high.tilt else {
            throw USBManualAcceptanceStageError(
                "gimbal_capability_missing",
                "The current USB gimbal range is not writable and complete")
        }
    }

    private func acceptanceBinding(from status: ServiceStatus) -> USBManualAcceptanceBinding? {
        guard let deviceID = status.selected?.id,
              !status.capture.sessionID.isEmpty,
              let gimbal = status.gimbal,
              let registryID = gimbal.registryID,
              let bootSessionID = gimbal.bootSessionID else { return nil }
        return USBManualAcceptanceBinding(
            deviceID: deviceID, captureSessionID: status.capture.sessionID,
            registryID: registryID, bootSessionID: bootSessionID)
    }

    private func validate(
        binding: USBManualAcceptanceBinding,
        status: ServiceStatus,
        request: USBManualAcceptanceRequest?
    ) throws {
        guard acceptanceBinding(from: status) == binding,
              status.capture.sessionID == binding.captureSessionID,
              status.selected?.id == binding.deviceID else {
            throw USBManualAcceptanceStageError(
                "session_changed",
                "USB device, capture session or attachment identity changed")
        }
        if let request,
           request.expectedDeviceID != binding.deviceID ||
           request.expectedSessionID != binding.captureSessionID {
            throw USBManualAcceptanceStageError(
                "session_changed",
                "The requested device/session no longer matches the attachment")
        }
    }

    private func currentAcceptanceStatus(
        binding: USBManualAcceptanceBinding,
        request: USBManualAcceptanceRequest?
    ) async throws -> USBManualAcceptanceStatusSample {
        let now = ProcessInfo.processInfo.systemUptime
        let status = await service.status()
        try validate(binding: binding, status: status, request: request)
        return USBManualAcceptanceStatusSample(status: status, sampledUptime: now)
    }

    private func frameEvidence(
        status: ServiceStatus,
        sampledUptime: TimeInterval,
        binding: USBManualAcceptanceBinding
    ) -> USBManualFrameEvidence? {
        guard let frame = status.capture.frame else { return nil }
        let age = sampledUptime - frame.receivedUptime
        guard age.isFinite else { return nil }
        let evidence = USBManualFrameEvidence(
            frameID: frame.id, sessionID: frame.sessionID,
            deviceID: frame.deviceID, receivedUptime: frame.receivedUptime,
            sampledUptime: sampledUptime, age: max(0, age),
            width: frame.width, height: frame.height)
        return evidence.isFresh(for: binding) ? evidence : nil
    }

    private func collectBaseline(
        binding: USBManualAcceptanceBinding,
        deadline: TimeInterval
    ) async throws -> [USBManualFrameEvidence] {
        var frames: [USBManualFrameEvidence] = []
        var frameIDs = Set<String>()
        for _ in 0..<USBManualAcceptanceExecutor.maximumBaselineFrames {
            try checkDeadline(deadline)
            let sample = try await currentAcceptanceStatus(binding: binding, request: nil)
            if let frame = frameEvidence(status: sample.status,
                                         sampledUptime: sample.sampledUptime,
                                         binding: binding),
               frameIDs.insert(frame.frameID).inserted {
                frames.append(frame)
            }
            if frames.count >= USBManualAcceptanceExecutor.minimumHoldSamples {
                return frames
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw USBManualAcceptanceStageError(
            "fresh_frame_missing",
            "The current USB capture did not provide three fresh distinct frames")
    }

    private func collectGimbalHold(
        axis: USBManualAcceptanceAxis,
        profile: USBManualAcceptanceProfile,
        direction: Int,
        input: ContinuousGimbalInput,
        origin: GimbalPosition,
        binding: USBManualAcceptanceBinding,
        holdSeconds: TimeInterval,
        deadline: TimeInterval
    ) async -> USBManualGimbalHoldMetric {
        let started = ProcessInfo.processInfo.systemUptime
        var samples: [USBManualPositionSample] = []
        var failure: String?
        let gestureID = UUID()
        let oldSpeed = continuousGimbal.speed
        continuousGimbal.setSpeed(1)
        let began = continuousGimbal.beginGesture(id: gestureID, input: input)
        if !began { failure = "manual_control_unavailable" }

        if began {
            do {
                for _ in 0..<USBManualAcceptanceExecutor.maximumHoldSamples {
                    try checkDeadline(deadline)
                    let sample = try await currentAcceptanceStatus(
                        binding: binding, request: nil)
                    if sample.status.phase == "moving",
                       sample.status.motionActive,
                       let position = sample.status.gimbal?.position,
                       let frame = frameEvidence(status: sample.status,
                                                 sampledUptime: sample.sampledUptime,
                                                 binding: binding) {
                        samples.append(USBManualPositionSample(
                            elapsed: max(0, sample.sampledUptime - started),
                            position: position, frame: frame, phase: "moving",
                            motionActive: true))
                    }
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    if elapsed >= holdSeconds { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch is CancellationError {
                failure = "cancelled"
            } catch let error as USBManualAcceptanceStageError {
                failure = error.code
            } catch let error as BridgeFailure {
                failure = error.code
            } catch {
                failure = "gimbal_observation_failed"
            }
        }

        // The matching lease owns its own neutral cleanup.  Calling this once
        // is safe even when begin failed and does not redirect to a new lease.
        let stopResult = await continuousGimbal.stop(reason: .released)
        let stopWindow = await stableGimbalPosition(binding: binding)
        let stopSubmitted = stopResult?.matchedLease == true && stopResult?.neutralSent == true
        let stopVerified = stopSubmitted && stopWindow.stable
        let stopFailure = stopResult?.failure ?? (stopVerified ? nil : "gimbal_stop_unverified")
        let stop = USBManualStopEvidence(
            submitted: stopSubmitted, verified: stopVerified,
            motionStopped: stopWindow.motionStopped,
            held: stopWindow.first, final: stopWindow.last,
            stableSampleCount: stopWindow.count,
            stableDurationSeconds: stopWindow.duration,
            failureCode: failure ?? stopFailure)

        var restore = USBManualRestoreEvidence(
            requested: origin, submitted: false, verified: false,
            failureCode: failure ?? "restore_not_attempted")
        restore = await restoreGimbal(origin: origin, binding: binding)
        continuousGimbal.setSpeed(oldSpeed)
        let holdDuration = min(USBManualAcceptanceExecutor.maximumHoldDuration,
                               max(0.15, ProcessInfo.processInfo.systemUptime - started))
        return USBManualGimbalHoldMetric(
            axis: axis, direction: direction, profile: profile,
            inputMagnitude: min(1, max(0, hypot(input.x, input.y))),
            speed: 1, holdDurationSeconds: holdDuration, origin: origin,
            samples: samples, stop: stop, restore: restore)
    }

    private struct GimbalStability {
        var first: GimbalPosition?
        var last: GimbalPosition?
        var count = 0
        var duration: TimeInterval = 0
        var motionStopped = false
        var stable = false
    }

    private func stableGimbalPosition(
        binding: USBManualAcceptanceBinding
    ) async -> GimbalStability {
        let started = ProcessInfo.processInfo.systemUptime
        var result = GimbalStability()
        var values: [(GimbalPosition, TimeInterval)] = []
        for _ in 0..<10 {
            let now = ProcessInfo.processInfo.systemUptime
            if now - started > 1 { break }
            guard let sample = try? await currentAcceptanceStatus(binding: binding,
                                                                   request: nil),
                  sample.status.phase == "ready",
                  !sample.status.motionActive,
                  let position = sample.status.gimbal?.position else {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            values.append((position, sample.sampledUptime))
            if values.count > USBManualAcceptanceExecutor.minimumStopSamples {
                values.removeFirst()
            }
            if result.first == nil { result.first = position }
            result.last = position; result.count = values.count
            guard let firstTime = values.first?.1,
                  let lastTime = values.last?.1 else { continue }
            result.duration = max(0, lastTime - firstTime)
            result.motionStopped = true
            if values.count >= USBManualAcceptanceExecutor.minimumStopSamples,
               result.duration >= USBManualAcceptanceExecutor.minimumStopDuration,
               let first = values.first?.0,
               let last = values.last?.0,
               let minimumPan = values.map({ Int64($0.0.pan) }).min(),
               let maximumPan = values.map({ Int64($0.0.pan) }).max(),
               let minimumTilt = values.map({ Int64($0.0.tilt) }).min(),
               let maximumTilt = values.map({ Int64($0.0.tilt) }).max(),
               maximumPan - minimumPan <= 360,
               maximumTilt - minimumTilt <= 360,
               first.distance(to: last) <= USBManualAcceptanceExecutor.restorationToleranceRaw {
                result.stable = true; return result
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return result
    }

    private func restoreGimbal(
        origin: GimbalPosition,
        binding: USBManualAcceptanceBinding
    ) async -> USBManualRestoreEvidence {
        guard let current = try? await currentAcceptanceStatus(binding: binding,
                                                                 request: nil),
              current.status.phase == "ready", !current.status.motionActive else {
            return USBManualRestoreEvidence(
                requested: origin, submitted: false, verified: false,
                failureCode: "restore_session_not_ready")
        }
        do {
            let result = try await service.point(
                panDegrees: Double(origin.pan) / 3600,
                tiltDegrees: Double(origin.tilt) / 3600,
                origin: .manual, expectedSessionID: binding.captureSessionID)
            let stable = await stableGimbalPosition(binding: binding)
            return USBManualRestoreEvidence(
                requested: origin, observed: result.observed ?? stable.last,
                submitted: result.accepted, verified: result.verified && stable.stable,
                stableSampleCount: stable.count,
                stableDurationSeconds: stable.duration,
                failureCode: result.verified && stable.stable ? nil : result.verification)
        } catch let error as BridgeFailure {
            return USBManualRestoreEvidence(
                requested: origin, submitted: false, verified: false,
                failureCode: error.code)
        } catch {
            return USBManualRestoreEvidence(
                requested: origin, submitted: false, verified: false,
                failureCode: "gimbal_restore_failed")
        }
    }

    private func collectZoom(
        binding: USBManualAcceptanceBinding,
        origin: Int,
        deadline: TimeInterval,
        holdSeconds: TimeInterval
    ) async throws -> USBManualZoomMetric {
        let capabilities = try await service.zoomCapabilities(
            expectedSessionID: binding.captureSessionID)
        guard capabilities.writable,
              let minimum = capabilities.minimum,
              let maximum = capabilities.maximum,
              let step = capabilities.step, step > 0,
              minimum <= origin, origin <= maximum else {
            throw USBManualAcceptanceStageError("zoom_capability_missing", "Zoom range or step is not complete")
        }
        let span = max(0, maximum - minimum)
        let availableUp = max(0, maximum - origin)
        let availableDown = max(0, origin - minimum)
        let sign = availableUp >= step * 4 ? 1 : -1
        let available = sign > 0 ? availableUp : availableDown
        guard available >= step * 2 else {
            throw USBManualAcceptanceStageError("zoom_range_too_small", "Zoom range cannot provide two advertised steps")
        }
        let steps = max(2, min(12, max(2, span / max(step * 3, 1))))
        let delta = min(available / step, steps) * step
        let target = origin + sign * delta
        guard target != origin, target >= minimum, target <= maximum else {
            throw USBManualAcceptanceStageError("zoom_target_invalid", "No bounded zoom target is available")
        }

        var progress: [USBManualZoomProgressSample] = []
        let started = ProcessInfo.processInfo.systemUptime
        var zoomTask: Task<USBZoomResult, Error>?
        var stopMotion: MotionResult?
        var stopIssued = false
        do {
            zoomTask = Task { try await service.zoom(
                rawValue: target, expectedSessionID: binding.captureSessionID,
                origin: .manual) }
            for _ in 0..<USBManualAcceptanceExecutor.maximumHoldSamples {
                try checkDeadline(deadline)
                let sample = try await currentAcceptanceStatus(binding: binding,
                                                                request: nil)
                if sample.status.phase == "moving", sample.status.motionActive,
                   let frame = frameEvidence(status: sample.status,
                                             sampledUptime: sample.sampledUptime,
                                             binding: binding),
                   let current = try? await service.zoomCapabilities(
                       expectedSessionID: binding.captureSessionID) {
                    progress.append(USBManualZoomProgressSample(
                        elapsed: max(0, sample.sampledUptime - started),
                        current: current.current, frame: frame, phase: "moving",
                        motionActive: true))
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                if !stopIssued && (progress.count >= 2 || elapsed >= max(0.35, holdSeconds)) {
                    stopIssued = true
                    stopMotion = try? await service.stop()
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            if !stopIssued {
                stopIssued = true
                stopMotion = try? await service.stop()
            }
            _ = try? await zoomTask?.value
        } catch {
            zoomTask?.cancel()
            if !stopIssued {
                stopIssued = true
                stopMotion = try? await service.stop()
            }
            throw error
        }

        let afterStop = await service.status()
        let zoomStop = stopMotion?.zoomStop
        let stop = USBManualStopEvidence(
            submitted: zoomStop?.submitted == true,
            verified: zoomStop?.verified == true,
            motionStopped: zoomStop?.verified == true && !afterStop.motionActive,
            heldRaw: zoomStop?.target ?? zoomStop?.observed,
            finalRaw: zoomStop?.observed,
            stableSampleCount: zoomStop?.sampleCount ?? 0,
            stableDurationSeconds: zoomStop?.stableDurationSeconds ?? 0,
            failureCode: zoomStop?.failure)
        let restore = await restoreZoom(origin: origin, binding: binding)
        return USBManualZoomMetric(
            origin: origin, target: target, minimum: minimum, maximum: maximum,
            step: step, progress: progress, stop: stop, restore: restore)
    }

    private func restoreZoom(
        origin: Int,
        binding: USBManualAcceptanceBinding
    ) async -> USBManualZoomRestoreEvidence {
        guard let status = try? await currentAcceptanceStatus(binding: binding,
                                                               request: nil),
              status.status.phase == "ready", !status.status.motionActive else {
            return USBManualZoomRestoreEvidence(
                requestedRaw: origin, submitted: false, verified: false,
                failureCode: "zoom_restore_session_not_ready")
        }
        do {
            let result = try await service.zoom(
                rawValue: origin, expectedSessionID: binding.captureSessionID,
                origin: .manual)
            return USBManualZoomRestoreEvidence(
                requestedRaw: origin, observedRaw: result.observed,
                submitted: result.accepted,
                verified: result.verified && result.observed == origin,
                stableSampleCount: result.sampleCount ?? 0,
                stableDurationSeconds: result.stableDurationSeconds ?? 0,
                failureCode: result.verified && result.observed == origin ? nil : result.verification)
        } catch let error as BridgeFailure {
            return USBManualZoomRestoreEvidence(
                requestedRaw: origin, submitted: false, verified: false,
                failureCode: error.code)
        } catch {
            return USBManualZoomRestoreEvidence(
                requestedRaw: origin, submitted: false, verified: false,
                failureCode: "zoom_restore_failed")
        }
    }

    private func reconnectAndFence(
        oldBinding: USBManualAcceptanceBinding,
        initial: ServiceStatus,
        deadline: TimeInterval
    ) async throws -> USBManualReconnectFenceMetric {
        try checkDeadline(deadline)
        // Stop/pause are lifecycle fences.  There is no auto-join or network
        // transition here; reconnect is the same explicit USB connect path as
        // the App's selected camera.
        _ = try? await service.stop()
        await service.pause()
        try checkDeadline(deadline)
        try await service.connect(
            id: oldBinding.deviceID,
            mode: initial.requestedMode,
            pixelFormat: initial.requestedPixelFormat ?? .automatic,
            outputPolicy: initial.requestedOutputPolicy ?? .bgra)
        await refresh()
        let status = await service.status()
        guard let newBinding = acceptanceBinding(from: status),
              newBinding.deviceID == oldBinding.deviceID,
              newBinding.captureSessionID != oldBinding.captureSessionID else {
            throw USBManualAcceptanceStageError(
                "reconnect_session_missing",
                "Reconnect did not create a new exact USB capture session")
        }

        // This call is intentionally rejected by CameraService's expected
        // session fence before any UVC SET.  It records that an old-session
        // operation is suppressed after reconnect.
        var oldOperationSuppressed = false
        do {
            _ = try await service.point(
                panDegrees: nil, tiltDegrees: nil, origin: .manual,
                expectedSessionID: oldBinding.captureSessionID)
        } catch let error as BridgeFailure where error.code == "session_changed" {
            oldOperationSuppressed = true
        } catch {
            oldOperationSuppressed = false
        }
        let sampled = ProcessInfo.processInfo.systemUptime
        let fresh = frameEvidence(status: status, sampledUptime: sampled,
                                  binding: newBinding) != nil
        return USBManualReconnectFenceMetric(
            oldBinding: oldBinding, newBinding: newBinding,
            oldOperationStopped: true,
            oldOperationSuppressed: oldOperationSuppressed,
            newSessionReady: status.phase == "ready" && !status.motionActive && fresh)
    }

    private func cleanupUSBManualAcceptance(
        binding: USBManualAcceptanceBinding?,
        gimbalOrigin: GimbalPosition?,
        zoomOrigin: Int?
    ) async {
        await continuousGimbal.stop(reason: .cancelled)
        guard let binding else { return }
        let status = await service.status()
        guard acceptanceBinding(from: status) == binding,
              status.capture.sessionID == binding.captureSessionID else { return }
        _ = try? await service.stop()
        if let gimbalOrigin {
            _ = await restoreGimbal(origin: gimbalOrigin, binding: binding)
        }
        if let zoomOrigin {
            _ = await restoreZoom(origin: zoomOrigin, binding: binding)
        }
    }

    private func checkDeadline(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw USBManualAcceptanceStageError("timeout", "USB manual acceptance exceeded its bounded timeout")
        }
    }

    private func acceptanceResultPayload(
        request: USBManualAcceptanceRequest,
        stage: String,
        failure: String?,
        baselineFrames: [USBManualFrameEvidence],
        gimbalHolds: [USBManualGimbalHoldMetric],
        zoom: USBManualZoomMetric?,
        reconnect: USBManualReconnectFenceMetric?,
        report: USBManualAcceptanceReport?,
        evaluation: USBManualAcceptanceEvaluation?
    ) throws -> JSONValue {
        var partial: [String: JSONValue] = [
            "baselineFrames": try .encode(baselineFrames),
            "gimbalHolds": try .encode(gimbalHolds),
            "zoom": try zoom.map(JSONValue.encode) ?? .null,
            "reconnect": try reconnect.map(JSONValue.encode) ?? .null
        ]
        // Keep the explicit privacy flags beside the partial evidence so a
        // consumer never has to infer whether images were retained.
        partial["cameraImagesStored"] = .bool(false)
        partial["physicalMotionVerified"] = .bool(false)
        var result: [String: JSONValue] = [
            "operation": .string(USBManualAcceptanceRequest.operation),
            "executeRequested": .bool(request.execute),
            "hardwareValidation": .bool(true),
            "bounded": .bool(true),
            "stage": .string(stage),
            "failure": failure.map(JSONValue.string) ?? .null,
            "partialEvidence": .object(partial),
            "cameraImagesStored": .bool(false),
            "physicalMotionVerified": .bool(false),
            "remainingPhysicalSteps": .array(USBManualAcceptanceExecutor.remainingPhysicalSteps.map(JSONValue.string))
        ]
        result["report"] = try report.map(JSONValue.encode) ?? .null
        result["evaluation"] = try evaluation.map(JSONValue.encode) ?? .null
        return .object(result)
    }
}
