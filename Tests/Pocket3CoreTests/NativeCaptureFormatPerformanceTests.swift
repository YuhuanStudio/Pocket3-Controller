import Foundation
import CoreMedia
import Testing
@testable import Pocket3Core

@Suite("Native capture format performance evidence")
struct NativeCaptureFormatPerformanceTests {
    private let definition = NativeCaptureFormatValidationCase.nv12H2644K30
    private let sessionID = "capture-performance-session"
    private let deviceID = "capture-performance-device"

    private func cleanup() -> NativeCaptureFormatCleanupEvidence {
        .init(stopRequested: true, finalPhase: "paused", finalFrameCount: 0)
    }

    private func sample(
        fps: Double = 30,
        frames: Int = 120,
        performance: NativeCaptureFormatPerformanceEvidence = .init(
            encodedVideoSampleCount: 120,
            decodedH264FrameCount: 120,
            h264DecodeFailureCount: 0,
            h264DecodeSubmittedCount: 120,
            h264DecodeQueueLatencyTotalMilliseconds: 36,
            h264DecodeQueueLatencyMaximumMilliseconds: 3,
            h264DecodeTotalMilliseconds: 480,
            h264DecodeMaximumMilliseconds: 8)
    ) -> NativeCaptureFormatValidationSample {
        .init(sessionID: sessionID, deviceID: deviceID,
              frames: frames, recentFPS: fps, age: 0.1,
              width: definition.mode.width, height: definition.mode.height,
              inputPixelFormat: .nv12, inputFourCC: "420v",
              videoSampleFourCC: "avc1", outputFourCC: "BGRA",
              rotationDegrees: 0, mirrored: false,
              videoSampleCount: 120, pixelBufferCount: 120,
              nonImageVideoSampleCount: 120,
              nonImageVideoBlockBufferCount: 120,
              decodedH264FrameCount: 120,
              h264DecodeFailureCount: 0,
              requestedOutputPolicy: "h264",
              performance: performance)
    }

    private func metrics(
        samples: [NativeCaptureFormatValidationSample],
        performance: NativeCaptureFormatPerformanceEvidence? = nil
    ) -> NativeCaptureFormatValidationMetrics {
        .init(caseID: definition.id, sessionID: sessionID,
              deviceID: deviceID, samples: samples, cleanup: cleanup(),
              initialSessionID: "initial-session", videoSampleCount: 120,
              pixelBufferCount: 120, nonImageVideoSampleCount: 120,
              nonImageVideoBlockBufferCount: 120,
              decodedH264FrameCount: 120, h264DecodeFailureCount: 0,
              requestedOutputPolicy: "h264", performance: performance)
    }

    private func request() throws -> NativeCaptureFormatValidationRequest {
        try .init(expectedSessionID: "initial-session",
                  expectedDeviceID: deviceID, caseIDs: [definition.id],
                  maximumSamplesPerCase: 3)
    }

    @Test func lowRealtimeRateKeepsCodecAndDecodeEvidenceSeparate() throws {
        let performance = NativeCaptureFormatPerformanceEvidence(
            encodedVideoSampleCount: 120, decodedH264FrameCount: 120,
            h264DecodeFailureCount: 0, h264DecodeSubmittedCount: 120,
            h264DecodeQueueLatencyTotalMilliseconds: 36,
            h264DecodeQueueLatencyMaximumMilliseconds: 3,
            h264DecodeTotalMilliseconds: 480,
            h264DecodeMaximumMilliseconds: 8)
        let value = metrics(samples: [sample(fps: 21.25, frames: 100, performance: performance),
                                      sample(fps: 21.25, frames: 130, performance: performance)],
                            performance: performance)
        let report = NativeCaptureFormatValidationService.evaluate(
            try request(), metrics: [value])
        let trial = try #require(report.trials.first)

        #expect(!report.passed)
        #expect(report.failureCode == "capture_format_realtime_rate_failed")
        #expect(trial.medianFPS == 21.25)
        #expect(trial.minimumFPS == 21.25 && trial.maximumFPS == 21.25)
        #expect(trial.codecStatus == NativeCaptureFormatEvidenceStatus.verified)
        #expect(trial.decodeStatus == NativeCaptureFormatEvidenceStatus.verified)
        #expect(trial.realtimeRateStatus == NativeCaptureFormatEvidenceStatus.failed)
        #expect(trial.performance.encodedVideoSampleCount == 120)
        #expect(trial.performance.decodedH264FrameCount == 120)
        #expect(trial.performance.h264DecodeSubmittedCount == 120)
        #expect(trial.performance.h264DecodeTotalMilliseconds == 480)
        #expect(trial.performance.h264DecodeMaximumMilliseconds == 8)
        #expect(trial.performance.h264DecodeQueueLatencyTotalMilliseconds == 36)
        #expect(trial.performance.h264DecodeQueueLatencyMaximumMilliseconds == 3)
        #expect(trial.performance.h264DecodeAverageMilliseconds == 4)
    }

    @Test func explicitDropAndBackpressureEvidenceFailsRealtimeDimension() throws {
        let performance = NativeCaptureFormatPerformanceEvidence(
            encodedVideoSampleCount: 120, decodedH264FrameCount: 120,
            h264DecodeSubmittedCount: 120,
            h264DecodeDroppedFrameCount: 4,
            h264DecodeQueueLatencyTotalMilliseconds: 120,
            h264DecodeQueueLatencyMaximumMilliseconds: 12,
            h264DecodeTotalMilliseconds: 300,
            h264DecodeMaximumMilliseconds: 6,
            droppedVideoFrameCount: 2, backpressureEventCount: 1,
            callbackTimeoutCount: 0)
        let value = metrics(
            samples: [sample(frames: 100, performance: performance),
                      sample(frames: 130, performance: performance)], performance: performance)
        let report = NativeCaptureFormatValidationService.evaluate(
            try request(), metrics: [value])
        let trial = try #require(report.trials.first)

        #expect(report.failureCode == "capture_format_realtime_drop_or_backpressure")
        #expect(trial.codecStatus == NativeCaptureFormatEvidenceStatus.verified &&
                trial.decodeStatus == NativeCaptureFormatEvidenceStatus.verified)
        #expect(trial.realtimeRateStatus == NativeCaptureFormatEvidenceStatus.failed)
        #expect(trial.performance.droppedVideoFrameCount == 2)
        #expect(trial.performance.backpressureEventCount == 1)
    }

    @Test func frameStoreCarriesDropAndDecodeTimingAsScalarEvidence() throws {
        let store = FrameStore()
        store.reset(deviceID: deviceID)
        store.recordVideoSample(hasImageBuffer: false, hasBlockBuffer: true,
                                mediaSubType: kCMVideoCodecType_H264,
                                inputMediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        store.recordH264Decode(success: true, durationSeconds: 0.004)
        store.recordVideoDrop(reason: "frame_was_late", backpressure: true)
        let diagnostics = store.sampleDiagnostics()
        #expect(diagnostics.droppedVideoFrameCount == 1)
        #expect(diagnostics.backpressureEventCount == 1)
        #expect(diagnostics.lastDroppedFrameReason == "frame_was_late")

        let stats = store.stats()
        let sample = NativeCaptureFormatValidationSample(
            stats: stats, expectedDeviceID: deviceID)
        #expect(sample.performance.encodedVideoSampleCount == 1)
        #expect(sample.performance.decodedH264FrameCount == 1)
        #expect(sample.performance.h264DecodeTotalMilliseconds == 4)
        #expect(sample.performance.droppedVideoFrameCount == 1)
        #expect(sample.performance.backpressureEventCount == 1)
    }
}
