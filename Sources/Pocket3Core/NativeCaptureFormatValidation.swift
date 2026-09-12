import Foundation

/// The callback outcome expected by one metrics-only format trial. A
/// zero-callback case is retained as an explicit expected failure in the
/// report; it is never promoted to a supported format.
public enum NativeCaptureFormatExpectation: String, Codable, Sendable,
    Equatable, CaseIterable {
    case framesRequired = "frames_required"
    case zeroCallbacks = "zero_callbacks"
}

/// Four representative current-device paths. These are validation fixtures,
/// not an availability claim and not a request to start capture.
public struct NativeCaptureFormatValidationCase: Codable, Sendable,
    Equatable, Identifiable {
    public let id: String
    public let mode: CaptureMode
    public let inputPixelFormat: CapturePixelFormat
    public let outputPolicy: CaptureOutputPolicy
    public let expectation: NativeCaptureFormatExpectation
    public let expectedInputFourCC: String
    public let expectedOutputFourCC: String?
    public let fpsTolerance: Double

    public init(id: String, mode: CaptureMode,
                inputPixelFormat: CapturePixelFormat,
                outputPolicy: CaptureOutputPolicy,
                expectation: NativeCaptureFormatExpectation,
                expectedInputFourCC: String,
                expectedOutputFourCC: String?,
                fpsTolerance: Double = 0.05) {
        self.id = id
        self.mode = mode
        self.inputPixelFormat = inputPixelFormat
        self.outputPolicy = outputPolicy
        self.expectation = expectation
        self.expectedInputFourCC = expectedInputFourCC
        self.expectedOutputFourCC = expectedOutputFourCC
        self.fpsTolerance = fpsTolerance
    }

    public var isPortrait: Bool { mode.isPortrait }
    public var expectsZeroCallbacks: Bool { expectation == .zeroCallbacks }

    public static let nv12BGRA1080p30 = Self(
        id: "nv12-bgra-1080p30",
        mode: CaptureMode(width: 1920, height: 1080, frameRate: 30),
        inputPixelFormat: .nv12, outputPolicy: .bgra,
        expectation: .framesRequired, expectedInputFourCC: "420v",
        expectedOutputFourCC: "BGRA")

    public static let nv12BGRAPortrait1080p30 = Self(
        id: "nv12-bgra-portrait-1080p30",
        mode: CaptureMode(width: 1080, height: 1920, frameRate: 30),
        inputPixelFormat: .nv12, outputPolicy: .bgra,
        expectation: .framesRequired, expectedInputFourCC: "420v",
        expectedOutputFourCC: "BGRA")

    public static let nv12H2644K30 = Self(
        id: "nv12-h264-4k30",
        mode: CaptureMode(width: 3840, height: 2160, frameRate: 30),
        inputPixelFormat: .nv12, outputPolicy: .h264,
        expectation: .framesRequired, expectedInputFourCC: "420v",
        expectedOutputFourCC: "avc1")

    public static let uyvyH2644K60NoCallback = Self(
        id: "uyvy-h264-4k60-zero-callback",
        mode: CaptureMode(width: 3840, height: 2160, frameRate: 60),
        inputPixelFormat: .uyvy, outputPolicy: .h264,
        expectation: .zeroCallbacks, expectedInputFourCC: "2vuy",
        expectedOutputFourCC: nil)

    public static let representative: [Self] = [
        .nv12BGRA1080p30, .nv12BGRAPortrait1080p30, .nv12H2644K30,
        .uyvyH2644K60NoCallback
    ]

    public static func resolve(_ id: String) -> Self? {
        representative.first { $0.id == id }
    }
}

public enum NativeCaptureFormatValidationError: Error, Codable, Sendable,
    Equatable {
    case invalidArguments
    case invalidSession
    case unknownCase
    case duplicateCase
    case tooManyCases
    case invalidSampleLimit
}

/// Developer-only request for a bounded format plan. The route has no execute
/// flag by design: it can return a dry-run plan, while a test harness can feed
/// scalar metrics into the evaluator without opening a camera.
public struct NativeCaptureFormatValidationRequest: Codable, Sendable,
    Equatable {
    public static let operation = "validation-capture-format-matrix"
    public static let maximumCases = 4
    public static let maximumSamples = 20

    public let expectedSessionID: String
    public let expectedDeviceID: String
    public let caseIDs: [String]
    public let maximumSamplesPerCase: Int

    public init(expectedSessionID: String, expectedDeviceID: String,
                caseIDs: [String] = NativeCaptureFormatValidationCase
                    .representative.map(\.id),
                maximumSamplesPerCase: Int = Self.maximumSamples) throws {
        guard Self.isNonEmpty(expectedSessionID),
              Self.isNonEmpty(expectedDeviceID) else {
            throw NativeCaptureFormatValidationError.invalidSession
        }
        guard !caseIDs.isEmpty, caseIDs.count <= Self.maximumCases else {
            throw NativeCaptureFormatValidationError.tooManyCases
        }
        guard Set(caseIDs).count == caseIDs.count else {
            throw NativeCaptureFormatValidationError.duplicateCase
        }
        guard caseIDs.allSatisfy({ NativeCaptureFormatValidationCase.resolve($0) != nil }) else {
            throw NativeCaptureFormatValidationError.unknownCase
        }
        guard (1...Self.maximumSamples).contains(maximumSamplesPerCase) else {
            throw NativeCaptureFormatValidationError.invalidSampleLimit
        }
        self.expectedSessionID = expectedSessionID
        self.expectedDeviceID = expectedDeviceID
        self.caseIDs = caseIDs
        self.maximumSamplesPerCase = maximumSamplesPerCase
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                "expectedSessionID", "deviceID", "cases", "maxSamples"
              ]),
              let session = fields["expectedSessionID"]?.string,
              let device = fields["deviceID"]?.string else {
            throw NativeCaptureFormatValidationError.invalidArguments
        }
        let cases: [String]
        if let value = fields["cases"] {
            guard case .array(let values) = value,
                  !values.isEmpty,
                  values.allSatisfy({ $0.string != nil }) else {
                throw NativeCaptureFormatValidationError.invalidArguments
            }
            cases = values.compactMap(\.string)
        } else {
            cases = NativeCaptureFormatValidationCase.representative.map(\.id)
        }
        let maxSamples: Int
        if let value = fields["maxSamples"] {
            guard let number = value.number, number.isFinite,
                  number.rounded() == number, let parsed = Int(exactly: number) else {
                throw NativeCaptureFormatValidationError.invalidSampleLimit
            }
            maxSamples = parsed
        } else {
            maxSamples = Self.maximumSamples
        }
        try self.init(expectedSessionID: session, expectedDeviceID: device,
                      caseIDs: cases, maximumSamplesPerCase: maxSamples)
    }

    public init(cliArguments: [String]) throws {
        var session: String?
        var device: String?
        var cases: [String] = []
        var maxSamples: Int?
        var index = 0
        while index < cliArguments.count {
            let option = cliArguments[index]
            guard index + 1 < cliArguments.count else {
                throw NativeCaptureFormatValidationError.invalidArguments
            }
            switch option {
            case "--session":
                guard session == nil else { throw NativeCaptureFormatValidationError.invalidArguments }
                session = cliArguments[index + 1]
            case "--device":
                guard device == nil else { throw NativeCaptureFormatValidationError.invalidArguments }
                device = cliArguments[index + 1]
            case "--case":
                cases.append(cliArguments[index + 1])
            case "--max-samples":
                guard maxSamples == nil, let value = Int(cliArguments[index + 1]) else {
                    throw NativeCaptureFormatValidationError.invalidSampleLimit
                }
                maxSamples = value
            default:
                throw NativeCaptureFormatValidationError.invalidArguments
            }
            index += 2
        }
        try self.init(expectedSessionID: session ?? "",
                      expectedDeviceID: device ?? "",
                      caseIDs: cases.isEmpty
                        ? NativeCaptureFormatValidationCase.representative.map(\.id)
                        : cases,
                      maximumSamplesPerCase: maxSamples ?? Self.maximumSamples)
    }

    public var arguments: JSONValue {
        .object([
            "expectedSessionID": .string(expectedSessionID),
            "deviceID": .string(expectedDeviceID),
            "cases": .array(caseIDs.map(JSONValue.string)),
            "maxSamples": .number(Double(maximumSamplesPerCase))
        ])
    }

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }

    private static func isNonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct NativeCaptureFormatValidationPlan: Codable, Sendable,
    Equatable {
    public let operation: String
    public let expectedSessionID: String
    public let expectedDeviceID: String
    public let cases: [NativeCaptureFormatValidationCase]
    public let maximumSamplesPerCase: Int
    public let hardwareExecutionEnabled: Bool
    public let cameraImagesStored: Bool
    public let automaticFallback: Bool

    init(request: NativeCaptureFormatValidationRequest) {
        operation = NativeCaptureFormatValidationRequest.operation
        expectedSessionID = request.expectedSessionID
        expectedDeviceID = request.expectedDeviceID
        cases = request.caseIDs.compactMap(NativeCaptureFormatValidationCase.resolve)
        maximumSamplesPerCase = request.maximumSamplesPerCase
        hardwareExecutionEnabled = false
        cameraImagesStored = false
        automaticFallback = false
    }
}

/// One scalar callback/status sample. No CVPixelBuffer, JPEG, block bytes or
/// file path is retained.
public struct NativeCaptureFormatValidationSample: Codable, Sendable,
    Equatable {
    public let sessionID: String
    public let deviceID: String
    public let frames: Int
    public let recentFPS: Double
    public let age: Double?
    public let width: Int?
    public let height: Int?
    public let inputPixelFormat: CapturePixelFormat?
    public let inputFourCC: String?
    public let outputFourCC: String?
    public let rotationDegrees: Int?
    public let mirrored: Bool?
    public let videoSampleCount: Int
    public let pixelBufferCount: Int
    public let nonImageVideoSampleCount: Int
    public let nonImageVideoBlockBufferCount: Int
    public let decodedH264FrameCount: Int
    public let h264DecodeFailureCount: Int
    public let runtimeErrorCount: Int
    public let interruptionCount: Int
    public let requestedOutputPolicy: String?
    public let fallbackUsed: Bool

    public init(sessionID: String, deviceID: String, frames: Int,
                recentFPS: Double, age: Double?, width: Int?, height: Int?,
                inputPixelFormat: CapturePixelFormat?, inputFourCC: String?,
                outputFourCC: String?, rotationDegrees: Int? = 0,
                mirrored: Bool? = false, videoSampleCount: Int = 0,
                pixelBufferCount: Int = 0,
                nonImageVideoSampleCount: Int = 0,
                nonImageVideoBlockBufferCount: Int = 0,
                decodedH264FrameCount: Int = 0,
                h264DecodeFailureCount: Int = 0,
                runtimeErrorCount: Int = 0, interruptionCount: Int = 0,
                requestedOutputPolicy: String? = nil,
                fallbackUsed: Bool = false) {
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.frames = frames
        self.recentFPS = recentFPS
        self.age = age
        self.width = width
        self.height = height
        self.inputPixelFormat = inputPixelFormat
        self.inputFourCC = inputFourCC
        self.outputFourCC = outputFourCC
        self.rotationDegrees = rotationDegrees
        self.mirrored = mirrored
        self.videoSampleCount = videoSampleCount
        self.pixelBufferCount = pixelBufferCount
        self.nonImageVideoSampleCount = nonImageVideoSampleCount
        self.nonImageVideoBlockBufferCount = nonImageVideoBlockBufferCount
        self.decodedH264FrameCount = decodedH264FrameCount
        self.h264DecodeFailureCount = h264DecodeFailureCount
        self.runtimeErrorCount = runtimeErrorCount
        self.interruptionCount = interruptionCount
        self.requestedOutputPolicy = requestedOutputPolicy
        self.fallbackUsed = fallbackUsed
    }

    public init(stats: CaptureStats, expectedDeviceID: String) {
        let frame = stats.frame
        let diagnostics = stats.sampleDiagnostics
        self.init(sessionID: stats.sessionID,
                  deviceID: frame?.deviceID ?? expectedDeviceID,
                  frames: stats.frames, recentFPS: stats.recentFPS,
                  age: stats.age, width: frame?.width, height: frame?.height,
                  inputPixelFormat: frame?.inputPixelFormat,
                  inputFourCC: frame?.inputPixelFormatFourCC,
                  outputFourCC: frame?.outputPixelFormat,
                  rotationDegrees: frame?.rotationDegrees,
                  mirrored: frame?.mirrored,
                  videoSampleCount: diagnostics?.videoSampleCount ?? 0,
                  pixelBufferCount: diagnostics?.pixelBufferCount ?? 0,
                  nonImageVideoSampleCount: diagnostics?.nonImageVideoSampleCount ?? 0,
                  nonImageVideoBlockBufferCount: diagnostics?.nonImageVideoBlockBufferCount ?? 0,
                  decodedH264FrameCount: diagnostics?.decodedH264FrameCount ?? 0,
                  h264DecodeFailureCount: diagnostics?.h264DecodeFailureCount ?? 0,
                  runtimeErrorCount: diagnostics?.runtimeErrorCount ?? 0,
                  interruptionCount: diagnostics?.interruptionCount ?? 0,
                  requestedOutputPolicy: diagnostics?.requestedOutputPolicy)
    }
}

/// Scalar teardown evidence supplied by the existing capture owner. A paused
/// owner must expose zero retained frames; the evaluator never calls pause.
public struct NativeCaptureFormatCleanupEvidence: Codable, Sendable,
    Equatable {
    public let stopRequested: Bool
    public let finalPhase: String
    public let finalFrameCount: Int
    public let finalSessionID: String?
    public let cameraImagesStored: Bool
    public let automaticFallback: Bool

    public init(stopRequested: Bool, finalPhase: String,
                finalFrameCount: Int, finalSessionID: String? = nil,
                cameraImagesStored: Bool = false,
                automaticFallback: Bool = false) {
        self.stopRequested = stopRequested
        self.finalPhase = finalPhase
        self.finalFrameCount = finalFrameCount
        self.finalSessionID = finalSessionID
        self.cameraImagesStored = cameraImagesStored
        self.automaticFallback = automaticFallback
    }

    public var isClean: Bool {
        stopRequested && ["paused", "idle"].contains(finalPhase) &&
            finalFrameCount == 0 && !cameraImagesStored &&
            !automaticFallback
    }
}

/// Bounded scalar trial metrics gathered by an external runner or fake. The
/// evaluator accepts no transport and therefore cannot execute hardware.
public struct NativeCaptureFormatValidationMetrics: Codable, Sendable,
    Equatable {
    public let caseID: String
    public let sessionID: String
    public let deviceID: String
    public let samples: [NativeCaptureFormatValidationSample]
    public let videoSampleCount: Int
    public let pixelBufferCount: Int
    public let nonImageVideoSampleCount: Int
    public let nonImageVideoBlockBufferCount: Int
    public let decodedH264FrameCount: Int
    public let h264DecodeFailureCount: Int
    public let runtimeErrorCount: Int
    public let interruptionCount: Int
    public let requestedOutputPolicy: String?
    public let fallbackUsed: Bool
    public let cleanup: NativeCaptureFormatCleanupEvidence

    public init(caseID: String, sessionID: String, deviceID: String,
                samples: [NativeCaptureFormatValidationSample],
                cleanup: NativeCaptureFormatCleanupEvidence,
                videoSampleCount: Int? = nil, pixelBufferCount: Int? = nil,
                nonImageVideoSampleCount: Int? = nil,
                nonImageVideoBlockBufferCount: Int? = nil,
                decodedH264FrameCount: Int? = nil,
                h264DecodeFailureCount: Int? = nil,
                runtimeErrorCount: Int? = nil, interruptionCount: Int? = nil,
                requestedOutputPolicy: String? = nil,
                fallbackUsed: Bool = false) {
        let last = samples.last
        self.caseID = caseID
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.samples = samples
        self.videoSampleCount = videoSampleCount ?? last?.videoSampleCount ?? 0
        self.pixelBufferCount = pixelBufferCount ?? last?.pixelBufferCount ?? 0
        self.nonImageVideoSampleCount = nonImageVideoSampleCount ??
            last?.nonImageVideoSampleCount ?? 0
        self.nonImageVideoBlockBufferCount = nonImageVideoBlockBufferCount ??
            last?.nonImageVideoBlockBufferCount ?? 0
        self.decodedH264FrameCount = decodedH264FrameCount ??
            last?.decodedH264FrameCount ?? 0
        self.h264DecodeFailureCount = h264DecodeFailureCount ??
            last?.h264DecodeFailureCount ?? 0
        self.runtimeErrorCount = runtimeErrorCount ??
            last?.runtimeErrorCount ?? 0
        self.interruptionCount = interruptionCount ??
            last?.interruptionCount ?? 0
        self.requestedOutputPolicy = requestedOutputPolicy ??
            last?.requestedOutputPolicy
        self.fallbackUsed = fallbackUsed || samples.contains { $0.fallbackUsed }
        self.cleanup = cleanup
    }

    public init(caseID: String, stats: [CaptureStats],
                expectedDeviceID: String,
                cleanup: NativeCaptureFormatCleanupEvidence) {
        self.init(caseID: caseID,
                  sessionID: stats.last?.sessionID ?? "",
                  deviceID: stats.last?.frame?.deviceID ?? expectedDeviceID,
                  samples: stats.map { NativeCaptureFormatValidationSample(
                      stats: $0, expectedDeviceID: expectedDeviceID) },
                  cleanup: cleanup)
    }
}

public enum NativeCaptureFormatTrialOutcome: String, Codable, Sendable,
    Equatable, CaseIterable {
    case verified
    case expectedFailure = "expected_failure"
    case failed
}

public struct NativeCaptureFormatValidationTrial: Codable, Sendable,
    Equatable, Identifiable {
    public let id: String
    public let caseID: String
    public let expectation: NativeCaptureFormatExpectation
    public let sampleCount: Int
    public let videoSampleCount: Int
    public let decodedH264FrameCount: Int
    public let cleanupPassed: Bool
    public let outcome: NativeCaptureFormatTrialOutcome
    public let failureCode: String?

    init(case definition: NativeCaptureFormatValidationCase,
         metrics: NativeCaptureFormatValidationMetrics,
         outcome: NativeCaptureFormatTrialOutcome,
         failureCode: String?) {
        id = definition.id
        caseID = definition.id
        expectation = definition.expectation
        sampleCount = metrics.samples.count
        videoSampleCount = metrics.videoSampleCount
        decodedH264FrameCount = metrics.decodedH264FrameCount
        cleanupPassed = metrics.cleanup.isClean
        self.outcome = outcome
        self.failureCode = failureCode
    }
}

public struct NativeCaptureFormatValidationReport: Codable, Sendable,
    Equatable {
    public let operation: String
    public let expectedSessionID: String
    public let expectedDeviceID: String
    public let plan: NativeCaptureFormatValidationPlan
    public let trials: [NativeCaptureFormatValidationTrial]
    public let phase: String
    public let completed: Bool
    /// True when all positive cases verified and every zero-callback case
    /// produced the explicitly expected failure evidence.
    public let passed: Bool
    public let verifiedCaseCount: Int
    public let expectedFailureCount: Int
    public let failureCode: String?
    public let cameraImagesStored: Bool
    public let automaticFallback: Bool
}

public enum NativeCaptureFormatValidationService {
    public static func dryRun(
        _ request: NativeCaptureFormatValidationRequest
    ) -> NativeCaptureFormatValidationReport {
        let plan = NativeCaptureFormatValidationPlan(request: request)
        return NativeCaptureFormatValidationReport(
            operation: NativeCaptureFormatValidationRequest.operation,
            expectedSessionID: request.expectedSessionID,
            expectedDeviceID: request.expectedDeviceID, plan: plan, trials: [],
            phase: "dry_run", completed: false, passed: false,
            verifiedCaseCount: 0, expectedFailureCount: 0,
            failureCode: nil, cameraImagesStored: false,
            automaticFallback: false)
    }

    public static func evaluate(
        _ request: NativeCaptureFormatValidationRequest,
        metrics: [NativeCaptureFormatValidationMetrics]
    ) -> NativeCaptureFormatValidationReport {
        let plan = NativeCaptureFormatValidationPlan(request: request)
        let definitions = request.caseIDs.compactMap(
            NativeCaptureFormatValidationCase.resolve)
        var trials: [NativeCaptureFormatValidationTrial] = []
        var seen = Set<String>()
        var imagesStored = false
        var fallback = false

        for definition in definitions {
            guard let value = metrics.first(where: {
                $0.caseID == definition.id
            }) else {
                trials.append(.init(case: definition,
                    metrics: .empty(caseID: definition.id,
                        sessionID: request.expectedSessionID,
                        deviceID: request.expectedDeviceID),
                    outcome: .failed, failureCode: "capture_format_metrics_missing"))
                continue
            }
            seen.insert(value.caseID)
            imagesStored = imagesStored || value.cleanup.cameraImagesStored
            fallback = fallback || value.fallbackUsed || value.cleanup.automaticFallback
            let failure = failureCode(definition, metrics: value,
                                      request: request)
            let outcome: NativeCaptureFormatTrialOutcome
            if definition.expectsZeroCallbacks,
               failure == "capture_format_zero_callback_observed" {
                outcome = .expectedFailure
            } else {
                outcome = failure == nil ? .verified : .failed
            }
            trials.append(.init(case: definition, metrics: value,
                                outcome: outcome, failureCode: failure))
        }
        if seen.count != metrics.count {
            let unknownMetrics = metrics.first {
                !request.caseIDs.contains($0.caseID)
            }
            if let unknownMetrics,
               !trials.contains(where: { $0.caseID == unknownMetrics.caseID }) {
                // Keep the report bounded and expose the extra case through a
                // stable aggregate failure rather than silently discarding it.
                fallback = fallback || unknownMetrics.fallbackUsed
            }
        }
        let verified = trials.filter { $0.outcome == .verified }.count
        let expectedFailures = trials.filter {
            $0.outcome == .expectedFailure
        }.count
        let failures = trials.filter { $0.outcome == .failed }
        let aggregateFailure = failures.first?.failureCode ??
            (metrics.count != request.caseIDs.count
                ? "capture_format_case_count_mismatch" : nil)
        return NativeCaptureFormatValidationReport(
            operation: NativeCaptureFormatValidationRequest.operation,
            expectedSessionID: request.expectedSessionID,
            expectedDeviceID: request.expectedDeviceID, plan: plan,
            trials: trials, phase: "completed", completed: true,
            passed: failures.isEmpty && metrics.count == request.caseIDs.count,
            verifiedCaseCount: verified,
            expectedFailureCount: expectedFailures,
            failureCode: aggregateFailure,
            cameraImagesStored: imagesStored,
            automaticFallback: fallback)
    }

    private static func failureCode(
        _ definition: NativeCaptureFormatValidationCase,
        metrics: NativeCaptureFormatValidationMetrics,
        request: NativeCaptureFormatValidationRequest
    ) -> String? {
        guard metrics.sessionID == request.expectedSessionID else {
            return "capture_format_session_changed"
        }
        guard metrics.deviceID == request.expectedDeviceID else {
            return "capture_format_device_changed"
        }
        guard metrics.samples.count <= request.maximumSamplesPerCase else {
            return "capture_format_sample_limit_exceeded"
        }
        guard metrics.cleanup.isClean else { return "capture_format_cleanup_failed" }
        guard !metrics.fallbackUsed, !metrics.cleanup.automaticFallback else {
            return "capture_format_automatic_fallback"
        }
        guard metrics.runtimeErrorCount == 0,
              metrics.interruptionCount == 0 else {
            return "capture_format_runtime_or_interruption"
        }

        if definition.expectsZeroCallbacks {
            guard metrics.videoSampleCount == 0,
                  metrics.pixelBufferCount == 0,
                  metrics.nonImageVideoSampleCount == 0,
                  metrics.nonImageVideoBlockBufferCount == 0,
                  metrics.decodedH264FrameCount == 0 else {
                return "capture_format_zero_callback_expected"
            }
            return "capture_format_zero_callback_observed"
        }

        guard !metrics.samples.isEmpty else {
            return "capture_format_no_video_sample"
        }
        guard metrics.videoSampleCount > 0 else {
            return "capture_format_no_video_sample"
        }
        guard metrics.samples.allSatisfy({ sample in
            sample.sessionID == request.expectedSessionID &&
                sample.deviceID == request.expectedDeviceID &&
                sample.width == definition.mode.width &&
                sample.height == definition.mode.height &&
                sample.inputPixelFormat == definition.inputPixelFormat &&
                sample.inputFourCC == definition.expectedInputFourCC &&
                sample.outputFourCC == definition.expectedOutputFourCC &&
                sample.age.map { $0.isFinite && $0 >= 0 && $0 < 1 } == true &&
                sample.rotationDegrees == 0 && sample.mirrored == false &&
                sample.requestedOutputPolicy == definition.outputPolicy.rawValue
        }) else {
            return "capture_format_sample_mismatch"
        }
        if metrics.samples.count > 1,
           metrics.samples.last!.frames <= metrics.samples.first!.frames {
            return "capture_format_frames_not_advancing"
        }
        let rates = metrics.samples.map(\.recentFPS)
        guard rates.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return "capture_format_rate_missing"
        }
        let sorted = rates.sorted()
        let median = sorted[sorted.count / 2]
        let tolerance = max(1, definition.mode.frameRate * definition.fpsTolerance)
        guard abs(median - definition.mode.frameRate) <= tolerance else {
            return "capture_format_rate_mismatch"
        }
        if definition.outputPolicy == .bgra,
           metrics.pixelBufferCount == 0 {
            return "capture_format_pixel_buffer_missing"
        }
        if definition.outputPolicy == .h264 {
            guard metrics.decodedH264FrameCount > 0 else {
                return "capture_format_h264_decode_missing"
            }
            guard metrics.h264DecodeFailureCount == 0 else {
                return "capture_format_h264_decode_failed"
            }
        }
        return nil
    }
}

private extension NativeCaptureFormatValidationMetrics {
    static func empty(caseID: String, sessionID: String,
                      deviceID: String) -> Self {
        .init(caseID: caseID, sessionID: sessionID, deviceID: deviceID,
              samples: [], cleanup: .init(stopRequested: true,
                  finalPhase: "paused", finalFrameCount: 0))
    }
}

public typealias Pocket3NativeCaptureFormatValidationRequest =
    NativeCaptureFormatValidationRequest
public typealias Pocket3NativeCaptureFormatValidationReport =
    NativeCaptureFormatValidationReport
