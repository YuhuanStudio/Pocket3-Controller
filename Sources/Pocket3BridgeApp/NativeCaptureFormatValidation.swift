import Foundation
import Pocket3Core

@MainActor private var nativeCaptureFormatValidationRunning = false

extension AppModel {
    /// Developer-only bounded format matrix. Dry-run returns a plan without
    /// touching CameraService. Execute uses the existing CameraService owner
    /// sequentially, pauses between cases, records scalar status samples, and
    /// optionally restores the exact initial mode after cleanup.
    func handleNativeCaptureFormatValidation(_ request: ServiceRequest)
        async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "Capture format validation requires an explicit development launch")
        }
        let input: NativeCaptureFormatValidationRequest
        do {
            input = try NativeCaptureFormatValidationRequest(
                arguments: request.arguments)
        } catch let error as NativeCaptureFormatValidationError {
            throw nativeCaptureFormatValidationFailure(error)
        }
        guard input.execute else {
            let report = NativeCaptureFormatValidationService.dryRun(input)
            return ServiceReply(id: request.id, result: try .encode(report))
        }
        guard !nativeCaptureFormatValidationRunning else {
            throw BridgeFailure("capture_format_matrix_busy",
                "A capture format matrix is already running")
        }
        nativeCaptureFormatValidationRunning = true
        defer { nativeCaptureFormatValidationRunning = false }

        let cameraService = service
        let initial = await cameraService.status()
        guard initial.phase == "ready",
              initial.selected?.id == input.expectedDeviceID,
              initial.capture.sessionID == input.expectedSessionID,
              initial.capture.frame?.sessionID == input.expectedSessionID,
              initial.capture.frame?.deviceID == input.expectedDeviceID,
              initial.capture.age.map({ $0.isFinite && $0 >= 0 && $0 <= 1 }) == true else {
            throw BridgeFailure("capture_format_initial_session_changed",
                "The requested initial capture device or session is not current")
        }

        let initialMode = initial.requestedMode
        let initialPixelFormat = initial.requestedPixelFormat ?? .automatic
        let initialOutputPolicy = initial.requestedOutputPolicy ?? .bgra
        let runCase: NativeCaptureFormatValidationExecutorAdapter.RunCase =
            { definition, request in
                do {
                    try Task.checkCancellation()
                    try await cameraService.connect(
                        id: request.expectedDeviceID, mode: definition.mode,
                        pixelFormat: definition.inputPixelFormat,
                        outputPolicy: definition.outputPolicy,
                        validationStartupTimeout: min(
                            30, max(1, request.warmupSeconds + 5)),
                        validationSkipUVC: true)
                    let connected = await cameraService.status()
                    guard connected.phase == "ready",
                          connected.selected?.id == request.expectedDeviceID,
                          connected.requestedMode == definition.mode,
                          connected.requestedPixelFormat ==
                              definition.inputPixelFormat,
                          connected.requestedOutputPolicy ==
                              definition.outputPolicy else {
                        throw BridgeFailure(
                            "capture_format_negotiation_mismatch",
                            "The exact requested format was not retained")
                    }
                    let trialSession = connected.capture.sessionID
                    try await Task.sleep(for: .seconds(request.warmupSeconds))
                    var stats: [CaptureStats] = []
                    stats.reserveCapacity(request.maximumSamplesPerCase)
                    for index in 0..<request.maximumSamplesPerCase {
                        try Task.checkCancellation()
                        let current = await cameraService.status()
                        guard current.selected?.id == request.expectedDeviceID,
                              current.capture.sessionID == trialSession else {
                            throw BridgeFailure("capture_format_session_changed",
                                "The capture session changed during this trial")
                        }
                        stats.append(current.capture)
                        if index + 1 < request.maximumSamplesPerCase {
                            try await Task.sleep(
                                for: .seconds(request.sampleInterval))
                        }
                    }
                    return NativeCaptureFormatValidationMetrics(
                        caseID: definition.id, stats: stats,
                        expectedDeviceID: request.expectedDeviceID,
                        cleanup: .init(stopRequested: false,
                            finalPhase: "running",
                            finalFrameCount: stats.last?.frames ?? 0),
                        initialSessionID: request.expectedSessionID)
                } catch let failure as BridgeFailure
                    where definition.expectsZeroCallbacks &&
                        failure.code == "no_frame" {
                    // CameraService retains the failed start's bounded
                    // diagnostics even after its failure cleanup. This is the
                    // explicit UYVY/4K60 zero-callback evidence path.
                    let failed = await cameraService.status()
                    let diagnostics = failed.lastCaptureAttempt
                        ?? CaptureSampleDiagnostics()
                    let performance = NativeCaptureFormatPerformanceEvidence(
                        encodedVideoSampleCount: diagnostics.videoSampleCount,
                        decodedH264FrameCount:
                            diagnostics.decodedH264FrameCount ?? 0,
                        h264DecodeFailureCount:
                            diagnostics.h264DecodeFailureCount ?? 0,
                        h264DecodeSubmittedCount:
                            diagnostics.h264DecodeSubmittedCount ?? 0,
                        h264DecodeDroppedFrameCount:
                            diagnostics.h264DecodeDroppedFrameCount ?? 0,
                        h264DecodeQueueLatencyTotalMilliseconds:
                            diagnostics.h264DecodeQueueLatencyTotalMilliseconds ?? 0,
                        h264DecodeQueueLatencyMaximumMilliseconds:
                            diagnostics.h264DecodeQueueLatencyMaximumMilliseconds ?? 0,
                        h264DecodeTotalMilliseconds:
                            diagnostics.h264DecodeTotalMilliseconds ?? 0,
                        h264DecodeMaximumMilliseconds:
                            diagnostics.h264DecodeMaximumMilliseconds ?? 0,
                        decodedHEVCFrameCount:
                            diagnostics.decodedHEVCFrameCount ?? 0,
                        droppedVideoFrameCount:
                            diagnostics.droppedVideoFrameCount ?? 0,
                        backpressureEventCount:
                            diagnostics.backpressureEventCount ?? 0,
                        callbackTimeoutCount:
                            diagnostics.callbackTimeoutCount ?? 0,
                        callbackWaitTimedOut:
                            diagnostics.callbackWaitTimedOut ?? false,
                        lastDroppedFrameReason:
                            diagnostics.lastDroppedFrameReason)
                    return NativeCaptureFormatValidationMetrics(
                        caseID: definition.id,
                        sessionID: failed.capture.sessionID,
                        deviceID: request.expectedDeviceID, samples: [],
                        cleanup: .init(stopRequested: false,
                            finalPhase: "failed", finalFrameCount: 0),
                        initialSessionID: request.expectedSessionID,
                        videoSampleCount: diagnostics.videoSampleCount,
                        pixelBufferCount: diagnostics.pixelBufferCount,
                        nonImageVideoSampleCount:
                            diagnostics.nonImageVideoSampleCount,
                        nonImageVideoBlockBufferCount:
                            diagnostics.nonImageVideoBlockBufferCount,
                        decodedH264FrameCount:
                            diagnostics.decodedH264FrameCount ?? 0,
                        h264DecodeFailureCount:
                            diagnostics.h264DecodeFailureCount ?? 0,
                        runtimeErrorCount: diagnostics.runtimeErrorCount,
                        interruptionCount: diagnostics.interruptionCount,
                        requestedOutputPolicy:
                            diagnostics.requestedOutputPolicy,
                        fallbackUsed: false,
                        executionFailureCode: nil,
                        performance: performance)
                } catch let failure as BridgeFailure
                    where failure.code == "no_frame" {
                    throw BridgeFailure("capture_format_no_video_sample",
                        failure.message)
                }
            }
        let cleanup: NativeCaptureFormatValidationExecutorAdapter.Cleanup = {
                await cameraService.pause()
                let final = await cameraService.status()
                return NativeCaptureFormatCleanupEvidence(
                    stopRequested: true, finalPhase: final.phase,
                    finalFrameCount: final.capture.frames,
                    finalSessionID: final.capture.sessionID)
            }
        let restore: NativeCaptureFormatValidationExecutorAdapter.Restore?
        if let mode = initialMode {
            restore = { () async throws -> NativeCaptureFormatRestoreEvidence in
                    do {
                        try Task.checkCancellation()
                        try await cameraService.connect(
                            id: input.expectedDeviceID, mode: mode,
                            pixelFormat: initialPixelFormat,
                            outputPolicy: initialOutputPolicy,
                            validationStartupTimeout: min(
                                30, max(1, input.warmupSeconds + 5)),
                            validationSkipUVC:
                                initial.uvcControlDisabledForCapture ?? false)
                        let restored = await cameraService.status()
                        guard restored.phase == "ready",
                              restored.selected?.id == input.expectedDeviceID,
                              restored.requestedMode == mode,
                              restored.requestedPixelFormat == initialPixelFormat,
                              restored.requestedOutputPolicy ==
                                  initialOutputPolicy else {
                            await cameraService.pause()
                            return .init(attempted: true, succeeded: false,
                                sessionID: restored.capture.sessionID,
                                failureCode:
                                    "capture_format_restore_mismatch")
                        }
                        return .init(attempted: true, succeeded: true,
                            sessionID: restored.capture.sessionID)
                    } catch is CancellationError {
                        await cameraService.pause()
                        return .init(attempted: true, succeeded: false,
                            failureCode: "capture_format_restore_cancelled")
                    } catch let failure as BridgeFailure {
                        await cameraService.pause()
                        return .init(attempted: true, succeeded: false,
                            failureCode: String(failure.code.prefix(128)))
                    } catch {
                        await cameraService.pause()
                        return .init(attempted: true, succeeded: false,
                            failureCode: "capture_format_restore_failed")
                    }
                }
        } else {
            restore = nil
        }
        let adapter = NativeCaptureFormatValidationExecutorAdapter(
            runCase: runCase, cleanup: cleanup, restore: restore)
        let report = await NativeCaptureFormatValidationService.execute(
            input, adapter: adapter)
        return ServiceReply(id: request.id, result: try .encode(report))
    }
}

private func nativeCaptureFormatValidationFailure(
    _ error: NativeCaptureFormatValidationError
) -> BridgeFailure {
    switch error {
    case .invalidArguments:
        BridgeFailure("invalid_capture_format_matrix_arguments",
            "Pass an exact capture session, device and bounded case list")
    case .invalidSession:
        BridgeFailure("capture_format_session_required",
            "Capture format validation requires exact session and device IDs")
    case .unknownCase:
        BridgeFailure("capture_format_case_unknown",
            "The requested format case is not in the reviewed matrix")
    case .duplicateCase:
        BridgeFailure("capture_format_case_duplicate",
            "Each capture format case may appear only once")
    case .tooManyCases:
        BridgeFailure("capture_format_case_limit",
            "The capture format matrix is limited to six cases")
    case .invalidSampleLimit:
        BridgeFailure("capture_format_sample_limit",
            "Each capture format case accepts at most twenty scalar samples")
    }
}
