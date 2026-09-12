import Foundation
import Testing
@testable import Pocket3Core

@Suite("Native capture format metrics matrix")
struct NativeCaptureFormatValidationTests {
    @Test func matrixUsesLongRunningIPCTimeout() {
        #expect(IPCClient.timeoutSeconds(
            for: NativeCaptureFormatValidationRequest.operation) == 120)
    }
    private let sessionID = "capture-session-fixture"
    private let deviceID = "0x11000002ca30023"

    private func request(_ cases: [NativeCaptureFormatValidationCase] =
        NativeCaptureFormatValidationCase.representative)
        throws -> NativeCaptureFormatValidationRequest {
        try NativeCaptureFormatValidationRequest(
            expectedSessionID: sessionID, expectedDeviceID: deviceID,
            caseIDs: cases.map(\.id))
    }

    private func cleanup(_ clean: Bool = true)
        -> NativeCaptureFormatCleanupEvidence {
        NativeCaptureFormatCleanupEvidence(
            stopRequested: clean, finalPhase: clean ? "paused" : "ready",
            finalFrameCount: clean ? 0 : 1,
            cameraImagesStored: false, automaticFallback: false)
    }

    private func sample(
        _ definition: NativeCaptureFormatValidationCase,
        frames: Int = 120,
        age: Double? = 0.1,
        session: String? = nil,
        device: String? = nil,
        output: String? = nil,
        fps: Double = 30,
        videoSamples: Int = 120,
        pixelBuffers: Int = 120,
        decodedH264: Int = 120,
        decodeFailures: Int = 0,
        fallback: Bool = false
    ) -> NativeCaptureFormatValidationSample {
        NativeCaptureFormatValidationSample(
            sessionID: session ?? sessionID, deviceID: device ?? deviceID,
            frames: frames, recentFPS: fps, age: age,
            width: definition.mode.width, height: definition.mode.height,
            inputPixelFormat: definition.inputPixelFormat,
            inputFourCC: definition.expectedInputFourCC,
            videoSampleFourCC: output ?? definition.expectedOutputFourCC,
            outputFourCC: "BGRA",
            rotationDegrees: 0, mirrored: false,
            videoSampleCount: videoSamples, pixelBufferCount: pixelBuffers,
            nonImageVideoSampleCount: definition.outputPolicy == .h264
                ? videoSamples : 0,
            nonImageVideoBlockBufferCount: definition.outputPolicy == .h264
                ? videoSamples : 0,
            decodedH264FrameCount: definition.outputPolicy == .h264
                ? decodedH264 : 0,
            h264DecodeFailureCount: decodeFailures,
            requestedOutputPolicy: definition.outputPolicy.rawValue,
            fallbackUsed: fallback)
    }

    private func positiveMetrics(
        _ definition: NativeCaptureFormatValidationCase,
        cleanup: NativeCaptureFormatCleanupEvidence? = nil,
        sampleOverride: NativeCaptureFormatValidationSample? = nil
    ) -> NativeCaptureFormatValidationMetrics {
        let first = sampleOverride ?? sample(definition, frames: 100)
        let second = sample(definition, frames: 130)
        return NativeCaptureFormatValidationMetrics(
            caseID: definition.id, sessionID: sessionID, deviceID: deviceID,
            samples: [first, second], cleanup: cleanup ?? self.cleanup())
    }

    @Test func representativePlanKeepsExactCurrentFormatBoundaries() throws {
        let cases = NativeCaptureFormatValidationCase.representative
        #expect(cases.count == 4)
        #expect(cases[0].mode == CaptureMode(width: 1920, height: 1080,
                                              frameRate: 30))
        #expect(cases[0].inputPixelFormat == .nv12 &&
                cases[0].outputPolicy == .bgra)
        #expect(cases[1].isPortrait && cases[1].mode.width == 1080 &&
                cases[1].mode.height == 1920)
        #expect(cases[2].mode.width == 3840 && cases[2].mode.height == 2160 &&
                cases[2].mode.frameRate == 30 &&
                cases[2].outputPolicy == .h264)
        #expect(cases[3].expectsZeroCallbacks &&
                cases[3].inputPixelFormat == .uyvy &&
                cases[3].mode.frameRate == 60)

        let request = try request()
        let plan = NativeCaptureFormatValidationService.dryRun(request)
        #expect(plan.phase == "dry_run" && !plan.passed)
        #expect(plan.plan.cases == cases)
        #expect(!plan.plan.hardwareExecutionEnabled &&
                !plan.plan.cameraImagesStored && !plan.plan.automaticFallback)
    }

    @Test func requestParsesOnlyBoundedReviewedCaseIDs() throws {
        let first = NativeCaptureFormatValidationCase.nv12BGRA1080p30
        let second = NativeCaptureFormatValidationCase
            .uyvyH2644K60NoCallback
        let request = try NativeCaptureFormatValidationRequest(cliArguments: [
            "--session", sessionID, "--device", deviceID,
            "--case", first.id, "--case", second.id, "--max-samples", "4"
        ])
        #expect(request.caseIDs == [first.id, second.id])
        #expect(request.maximumSamplesPerCase == 4)
        let decoded = try JSONDecoder().decode(
            NativeCaptureFormatValidationRequest.self,
            from: JSONEncoder().encode(request))
        #expect(decoded == request)
        #expect(throws: NativeCaptureFormatValidationError.unknownCase) {
            try NativeCaptureFormatValidationRequest(
                expectedSessionID: sessionID, expectedDeviceID: deviceID,
                caseIDs: ["uyvy-h264-4k60-guess"])
        }
        #expect(throws: NativeCaptureFormatValidationError.duplicateCase) {
            try NativeCaptureFormatValidationRequest(
                expectedSessionID: sessionID, expectedDeviceID: deviceID,
                caseIDs: [first.id, first.id])
        }

        let execute = try NativeCaptureFormatValidationRequest(cliArguments: [
            "--session", sessionID, "--device", deviceID,
            "--case", first.id, "--execute", "--warmup-seconds", "2",
            "--sample-interval", "0.25", "--max-samples", "3"
        ])
        #expect(execute.execute && execute.warmupSeconds == 2 &&
                execute.sampleInterval == 0.25 &&
                execute.maximumSamplesPerCase == 3)
    }

    @Test func evaluatorSeparatesVerifiedPositiveModesFromExpectedZeroCallback()
        throws {
        let cases = NativeCaptureFormatValidationCase.representative
        let zero = cases[3]
        let zeroMetrics = NativeCaptureFormatValidationMetrics(
            caseID: zero.id, sessionID: sessionID, deviceID: deviceID,
            samples: [], cleanup: cleanup(), videoSampleCount: 0,
            pixelBufferCount: 0, nonImageVideoSampleCount: 0,
            nonImageVideoBlockBufferCount: 0, decodedH264FrameCount: 0,
            h264DecodeFailureCount: 0, runtimeErrorCount: 0,
            interruptionCount: 0, requestedOutputPolicy: "h264")
        let metrics = cases.prefix(3).map { positiveMetrics($0) } + [zeroMetrics]
        let report = NativeCaptureFormatValidationService.evaluate(
            try request(), metrics: metrics)

        #expect(report.completed && report.passed)
        #expect(report.verifiedCaseCount == 3 &&
                report.expectedFailureCount == 1)
        #expect(report.failureCode == nil)
        #expect(report.trials.first(where: { $0.caseID == zero.id })?.outcome ==
                .expectedFailure)
        #expect(report.trials.first(where: { $0.caseID == zero.id })?.failureCode ==
                "capture_format_zero_callback_observed")
    }

    @Test func evaluatorRejectsPositiveMismatchAndUnexpectedZeroCallback()
        throws {
        let positive = NativeCaptureFormatValidationCase.nv12H2644K30
        let zero = NativeCaptureFormatValidationCase
            .uyvyH2644K60NoCallback
        let mismatch = positiveMetrics(positive, sampleOverride: sample(
            positive, age: 1.0))
        let unexpected = NativeCaptureFormatValidationMetrics(
            caseID: zero.id, sessionID: sessionID, deviceID: deviceID,
            samples: [], cleanup: cleanup(), videoSampleCount: 1,
            pixelBufferCount: 0, nonImageVideoSampleCount: 1,
            nonImageVideoBlockBufferCount: 1, decodedH264FrameCount: 0,
            requestedOutputPolicy: "h264")
        let report = NativeCaptureFormatValidationService.evaluate(
            try request([positive, zero]), metrics: [mismatch, unexpected])
        #expect(!report.passed && report.failureCode ==
                "capture_format_sample_mismatch")
        #expect(report.trials.allSatisfy { $0.outcome == .failed })
        #expect(report.trials.last?.failureCode ==
                "capture_format_zero_callback_expected")
    }

    @Test func evaluatorFencesSessionAndCleanupWithoutSavingOrFallback()
        throws {
        let definition = NativeCaptureFormatValidationCase.nv12BGRA1080p30
        let foreignSample = sample(definition, session: "other-session")
        let foreignSession = NativeCaptureFormatValidationMetrics(
            caseID: definition.id, sessionID: "other-session", deviceID: deviceID,
            samples: [foreignSample, foreignSample], cleanup: cleanup(),
            initialSessionID: "other-session")
        let changedCleanup = positiveMetrics(definition, cleanup: cleanup(false))
        let fallback = positiveMetrics(definition, sampleOverride: sample(
            definition, fallback: true))

        let sessionReport = NativeCaptureFormatValidationService.evaluate(
            try request([definition]), metrics: [foreignSession])
        #expect(sessionReport.failureCode == "capture_format_session_changed")
        let cleanupReport = NativeCaptureFormatValidationService.evaluate(
            try request([definition]), metrics: [changedCleanup])
        #expect(cleanupReport.failureCode == "capture_format_cleanup_failed")
        let fallbackReport = NativeCaptureFormatValidationService.evaluate(
            try request([definition]), metrics: [fallback])
        #expect(fallbackReport.failureCode == "capture_format_automatic_fallback")
    }

    @Test func statsProjectionRetainsScalarDiagnosticsOnly() throws {
        let definition = NativeCaptureFormatValidationCase.nv12BGRAPortrait1080p30
        let frame = FrameInfo(id: "frame", sessionID: sessionID,
            deviceID: deviceID, receivedAt: Date(), receivedUptime: 10,
            presentationTime: 1, width: 1080, height: 1920,
            inputPixelFormat: .nv12, inputPixelFormatFourCC: "420v",
            outputPixelFormat: "BGRA")
        var diagnostics = CaptureSampleDiagnostics()
        diagnostics.videoSampleCount = 12
        diagnostics.pixelBufferCount = 12
        diagnostics.requestedOutputPolicy = "bgra"
        let stats = CaptureStats(sessionID: sessionID, frames: 12,
            recentFPS: 30, frame: frame, age: 0.1, audio: AudioStats(),
            sampleDiagnostics: diagnostics)
        let metrics = NativeCaptureFormatValidationMetrics(
            caseID: definition.id, stats: [stats], expectedDeviceID: deviceID,
            cleanup: cleanup())
        let sample = try #require(metrics.samples.first)
        #expect(sample.width == 1080 && sample.height == 1920)
        #expect(sample.inputPixelFormat == .nv12 &&
                sample.outputFourCC == "BGRA")
        #expect(sample.videoSampleCount == 12 && !sample.fallbackUsed)
    }

    @Test func fakeExecutorRunsCasesSequentiallyCleansEachAndRestores()
        async throws {
        let request = try NativeCaptureFormatValidationRequest(
            expectedSessionID: sessionID, expectedDeviceID: deviceID,
            maximumSamplesPerCase: 3, execute: true, warmupSeconds: 1,
            sampleInterval: 0.1)
        let definitions = NativeCaptureFormatValidationCase.representative
        let positive = Dictionary(uniqueKeysWithValues: definitions.prefix(3).map {
            ($0.id, positiveMetrics($0))
        })
        let zero = definitions[3]
        let zeroMetrics = NativeCaptureFormatValidationMetrics(
            caseID: zero.id, sessionID: "zero-trial-session", deviceID: deviceID,
            samples: [], cleanup: cleanup(), initialSessionID: sessionID,
            requestedOutputPolicy: "h264")
        let metricsByID = positive.merging([zero.id: zeroMetrics]) {
            existing, _ in existing
        }
        let events = MatrixEventCounter()
        let adapter = NativeCaptureFormatValidationExecutorAdapter(
            runCase: { definition, _ in
                events.append("run:\(definition.id)")
                guard let metrics = metricsByID[definition.id] else {
                    throw NativeCaptureFormatValidationError.unknownCase
                }
                return metrics
            },
            cleanup: {
                events.append("cleanup")
                return NativeCaptureFormatCleanupEvidence(
                    stopRequested: true, finalPhase: "paused",
                    finalFrameCount: 0)
            },
            restore: {
                events.append("restore")
                return NativeCaptureFormatRestoreEvidence(
                    attempted: true, succeeded: true,
                    sessionID: "restored-session")
            })

        let report = await NativeCaptureFormatValidationService.execute(
            request, adapter: adapter)
        #expect(report.completed && report.passed)
        #expect(report.verifiedCaseCount == 3 &&
                report.expectedFailureCount == 1)
        #expect(report.restoration?.succeeded == true)
        #expect(events.values.filter { $0 == "cleanup" }.count == 4)
        #expect(events.values.last == "restore")
        let expectedPrefix = definitions.flatMap {
            ["run:\($0.id)", "cleanup"]
        }
        #expect(Array(events.values.prefix(8)) == expectedPrefix)
    }

    @Test func cancellationPreservesPartialMetricsAndStillRestoresWhenClean()
        async throws {
        let request = try NativeCaptureFormatValidationRequest(
            expectedSessionID: sessionID, expectedDeviceID: deviceID,
            maximumSamplesPerCase: 2, execute: true, warmupSeconds: 1,
            sampleInterval: 0.1)
        let events = MatrixEventCounter()
        let adapter = NativeCaptureFormatValidationExecutorAdapter(
            runCase: { definition, _ in
                events.append("run:\(definition.id)")
                throw CancellationError()
            },
            cleanup: {
                events.append("cleanup")
                return NativeCaptureFormatCleanupEvidence(
                    stopRequested: true, finalPhase: "paused",
                    finalFrameCount: 0)
            },
            restore: {
                events.append("restore")
                return NativeCaptureFormatRestoreEvidence(
                    attempted: true, succeeded: true)
            })
        let report = await NativeCaptureFormatValidationService.execute(
            request, adapter: adapter)
        #expect(!report.completed && !report.passed && report.phase == "cancelled")
        #expect(report.trials.first?.failureCode == "capture_format_cancelled")
        #expect(report.restoration?.attempted == true)
        #expect(report.restoration?.succeeded == true)
        #expect(events.values == [
            "run:\(NativeCaptureFormatValidationCase.nv12BGRA1080p30.id)",
            "cleanup", "restore"
        ])
    }
}

private final class MatrixEventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var eventsStorage: [String] = []

    func append(_ value: String) { lock.withLock { eventsStorage.append(value) } }
    var values: [String] { lock.withLock { eventsStorage } }
}
