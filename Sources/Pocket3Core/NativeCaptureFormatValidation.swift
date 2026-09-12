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

/// Developer-only request for a bounded format plan or execution. Execution is
/// opt-in and is available only through the development App route; the Core
/// evaluator itself accepts scalar metrics and never opens a camera.
public struct NativeCaptureFormatValidationRequest: Codable, Sendable,
    Equatable {
    public static let operation = "validation-capture-format-matrix"
    public static let maximumCases = 4
    public static let maximumSamples = 20
    public static let maximumExecutionWindow: TimeInterval = 90

    public let expectedSessionID: String
    public let expectedDeviceID: String
    public let caseIDs: [String]
    public let maximumSamplesPerCase: Int
    public let execute: Bool
    public let warmupSeconds: TimeInterval
    public let sampleInterval: TimeInterval

    public init(expectedSessionID: String, expectedDeviceID: String,
                caseIDs: [String] = NativeCaptureFormatValidationCase
                    .representative.map(\.id),
                maximumSamplesPerCase: Int = Self.maximumSamples,
                execute: Bool = false,
                warmupSeconds: TimeInterval = 10,
                sampleInterval: TimeInterval = 0.5) throws {
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
        guard warmupSeconds.isFinite, (1...30).contains(warmupSeconds),
              sampleInterval.isFinite, (0.1...5).contains(sampleInterval),
              warmupSeconds + sampleInterval *
                  Double(maximumSamplesPerCase - 1) <=
                  Self.maximumExecutionWindow else {
            throw NativeCaptureFormatValidationError.invalidArguments
        }
        self.expectedSessionID = expectedSessionID
        self.expectedDeviceID = expectedDeviceID
        self.caseIDs = caseIDs
        self.maximumSamplesPerCase = maximumSamplesPerCase
        self.execute = execute
        self.warmupSeconds = warmupSeconds
        self.sampleInterval = sampleInterval
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                "expectedSessionID", "deviceID", "cases", "maxSamples",
                "execute", "warmupSeconds", "sampleInterval"
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
        let execute: Bool
        if let value = fields["execute"] {
            guard let parsed = value.bool else {
                throw NativeCaptureFormatValidationError.invalidArguments
            }
            execute = parsed
        } else {
            execute = false
        }
        let warmupSeconds = fields["warmupSeconds"]?.number ?? 10
        let sampleInterval = fields["sampleInterval"]?.number ?? 0.5
        try self.init(expectedSessionID: session, expectedDeviceID: device,
                      caseIDs: cases, maximumSamplesPerCase: maxSamples,
                      execute: execute, warmupSeconds: warmupSeconds,
                      sampleInterval: sampleInterval)
    }

    public init(cliArguments: [String]) throws {
        var session: String?
        var device: String?
        var cases: [String] = []
        var maxSamples: Int?
        var execute = false
        var warmupSeconds: TimeInterval?
        var sampleInterval: TimeInterval?
        var index = 0
        while index < cliArguments.count {
            let option = cliArguments[index]
            if option == "--execute" {
                guard !execute else {
                    throw NativeCaptureFormatValidationError.invalidArguments
                }
                execute = true
                index += 1
                continue
            }
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
            case "--warmup-seconds":
                guard warmupSeconds == nil,
                      let value = Double(cliArguments[index + 1]) else {
                    throw NativeCaptureFormatValidationError.invalidArguments
                }
                warmupSeconds = value
            case "--sample-interval":
                guard sampleInterval == nil,
                      let value = Double(cliArguments[index + 1]) else {
                    throw NativeCaptureFormatValidationError.invalidArguments
                }
                sampleInterval = value
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
                      maximumSamplesPerCase: maxSamples ?? Self.maximumSamples,
                      execute: execute,
                      warmupSeconds: warmupSeconds ?? 10,
                      sampleInterval: sampleInterval ?? 0.5)
    }

    public var arguments: JSONValue {
        .object([
            "expectedSessionID": .string(expectedSessionID),
            "deviceID": .string(expectedDeviceID),
            "cases": .array(caseIDs.map(JSONValue.string)),
            "maxSamples": .number(Double(maximumSamplesPerCase)),
            "execute": .bool(execute),
            "warmupSeconds": .number(warmupSeconds),
            "sampleInterval": .number(sampleInterval)
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
    public let executeRequested: Bool
    public let warmupSeconds: TimeInterval
    public let sampleInterval: TimeInterval
    public let hardwareExecutionEnabled: Bool
    public let cameraImagesStored: Bool
    public let automaticFallback: Bool

    init(request: NativeCaptureFormatValidationRequest) {
        operation = NativeCaptureFormatValidationRequest.operation
        expectedSessionID = request.expectedSessionID
        expectedDeviceID = request.expectedDeviceID
        cases = request.caseIDs.compactMap(NativeCaptureFormatValidationCase.resolve)
        maximumSamplesPerCase = request.maximumSamplesPerCase
        executeRequested = request.execute
        warmupSeconds = request.warmupSeconds
        sampleInterval = request.sampleInterval
        hardwareExecutionEnabled = request.execute
        cameraImagesStored = false
        automaticFallback = false
    }
}

public enum NativeCaptureFormatEvidenceStatus: String, Codable, Sendable,
    Equatable, CaseIterable {
    case verified
    case failed
    case notApplicable = "not_applicable"
    case unknown
}

/// Scalar performance evidence retained with each format sample. Counts come
/// from the capture callback/decoder diagnostics; no sample buffers or image
/// bytes are retained. A low realtime rate can therefore be reported while
/// codec and decode evidence remain independently successful.
public struct NativeCaptureFormatPerformanceEvidence: Codable, Sendable,
    Equatable, Hashable {
    public let encodedVideoSampleCount: Int
    public let decodedH264FrameCount: Int
    public let h264DecodeFailureCount: Int
    public let h264DecodeSubmittedCount: Int
    public let h264DecodeDroppedFrameCount: Int
    public let h264DecodeQueueLatencyTotalMilliseconds: Double
    public let h264DecodeQueueLatencyMaximumMilliseconds: Double
    public let h264DecodeTotalMilliseconds: Double
    public let h264DecodeMaximumMilliseconds: Double
    public let decodedHEVCFrameCount: Int
    public let droppedVideoFrameCount: Int
    public let backpressureEventCount: Int
    public let callbackTimeoutCount: Int
    public let callbackWaitTimedOut: Bool
    public let lastDroppedFrameReason: String?

    public init(encodedVideoSampleCount: Int = 0,
                decodedH264FrameCount: Int = 0,
                h264DecodeFailureCount: Int = 0,
                h264DecodeSubmittedCount: Int = 0,
                h264DecodeDroppedFrameCount: Int = 0,
                h264DecodeQueueLatencyTotalMilliseconds: Double = 0,
                h264DecodeQueueLatencyMaximumMilliseconds: Double = 0,
                h264DecodeTotalMilliseconds: Double = 0,
                h264DecodeMaximumMilliseconds: Double = 0,
                decodedHEVCFrameCount: Int = 0,
                droppedVideoFrameCount: Int = 0,
                backpressureEventCount: Int = 0,
                callbackTimeoutCount: Int = 0,
                callbackWaitTimedOut: Bool = false,
                lastDroppedFrameReason: String? = nil) {
        self.encodedVideoSampleCount = max(0, encodedVideoSampleCount)
        self.decodedH264FrameCount = max(0, decodedH264FrameCount)
        self.h264DecodeFailureCount = max(0, h264DecodeFailureCount)
        self.h264DecodeSubmittedCount = max(0, h264DecodeSubmittedCount)
        self.h264DecodeDroppedFrameCount = max(0, h264DecodeDroppedFrameCount)
        self.h264DecodeQueueLatencyTotalMilliseconds =
            h264DecodeQueueLatencyTotalMilliseconds
        self.h264DecodeQueueLatencyMaximumMilliseconds =
            h264DecodeQueueLatencyMaximumMilliseconds
        self.h264DecodeTotalMilliseconds = h264DecodeTotalMilliseconds
        self.h264DecodeMaximumMilliseconds = h264DecodeMaximumMilliseconds
        self.decodedHEVCFrameCount = max(0, decodedHEVCFrameCount)
        self.droppedVideoFrameCount = max(0, droppedVideoFrameCount)
        self.backpressureEventCount = max(0, backpressureEventCount)
        self.callbackTimeoutCount = max(0, callbackTimeoutCount)
        self.callbackWaitTimedOut = callbackWaitTimedOut
        self.lastDroppedFrameReason = lastDroppedFrameReason
    }

    public static let zero = Self()

    public var h264DecodeAverageMilliseconds: Double? {
        let count = decodedH264FrameCount + h264DecodeFailureCount
        guard count > 0, h264DecodeTotalMilliseconds.isFinite,
              h264DecodeTotalMilliseconds >= 0 else { return nil }
        return h264DecodeTotalMilliseconds / Double(count)
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
    /// FourCC of the AVFoundation sample before optional host decode.
    public let videoSampleFourCC: String?
    /// Pixel format published by FrameStore after any host decode.
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
    public let performance: NativeCaptureFormatPerformanceEvidence

    public init(sessionID: String, deviceID: String, frames: Int,
                recentFPS: Double, age: Double?, width: Int?, height: Int?,
                inputPixelFormat: CapturePixelFormat?, inputFourCC: String?,
                videoSampleFourCC: String? = nil,
                outputFourCC: String?, rotationDegrees: Int? = 0,
                mirrored: Bool? = false, videoSampleCount: Int = 0,
                pixelBufferCount: Int = 0,
                nonImageVideoSampleCount: Int = 0,
                nonImageVideoBlockBufferCount: Int = 0,
                decodedH264FrameCount: Int = 0,
                h264DecodeFailureCount: Int = 0,
                h264DecodeSubmittedCount: Int = 0,
                h264DecodeDroppedFrameCount: Int = 0,
                h264DecodeQueueLatencyTotalMilliseconds: Double = 0,
                h264DecodeQueueLatencyMaximumMilliseconds: Double = 0,
                runtimeErrorCount: Int = 0, interruptionCount: Int = 0,
                requestedOutputPolicy: String? = nil,
                fallbackUsed: Bool = false,
                performance: NativeCaptureFormatPerformanceEvidence? = nil) {
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.frames = frames
        self.recentFPS = recentFPS
        self.age = age
        self.width = width
        self.height = height
        self.inputPixelFormat = inputPixelFormat
        self.inputFourCC = inputFourCC
        self.videoSampleFourCC = videoSampleFourCC ?? outputFourCC
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
        self.performance = performance ?? NativeCaptureFormatPerformanceEvidence(
            encodedVideoSampleCount: videoSampleCount,
            decodedH264FrameCount: decodedH264FrameCount,
            h264DecodeFailureCount: h264DecodeFailureCount,
            h264DecodeSubmittedCount: h264DecodeSubmittedCount,
            h264DecodeDroppedFrameCount: h264DecodeDroppedFrameCount,
            h264DecodeQueueLatencyTotalMilliseconds:
                h264DecodeQueueLatencyTotalMilliseconds,
            h264DecodeQueueLatencyMaximumMilliseconds:
                h264DecodeQueueLatencyMaximumMilliseconds)
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
                  videoSampleFourCC: diagnostics?.lastVideoSampleFourCC,
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
                  requestedOutputPolicy: diagnostics?.requestedOutputPolicy,
                  performance: .init(
                      encodedVideoSampleCount: diagnostics?.videoSampleCount ?? 0,
                      decodedH264FrameCount: diagnostics?.decodedH264FrameCount ?? 0,
                      h264DecodeFailureCount: diagnostics?.h264DecodeFailureCount ?? 0,
                      h264DecodeSubmittedCount:
                          diagnostics?.h264DecodeSubmittedCount ?? 0,
                      h264DecodeDroppedFrameCount:
                          diagnostics?.h264DecodeDroppedFrameCount ?? 0,
                      h264DecodeQueueLatencyTotalMilliseconds:
                          diagnostics?.h264DecodeQueueLatencyTotalMilliseconds ?? 0,
                      h264DecodeQueueLatencyMaximumMilliseconds:
                          diagnostics?.h264DecodeQueueLatencyMaximumMilliseconds ?? 0,
                      h264DecodeTotalMilliseconds:
                          diagnostics?.h264DecodeTotalMilliseconds ?? 0,
                      h264DecodeMaximumMilliseconds:
                          diagnostics?.h264DecodeMaximumMilliseconds ?? 0,
                      decodedHEVCFrameCount:
                          diagnostics?.decodedHEVCFrameCount ?? 0,
                      droppedVideoFrameCount:
                          diagnostics?.droppedVideoFrameCount ?? 0,
                      backpressureEventCount:
                          diagnostics?.backpressureEventCount ?? 0,
                      callbackTimeoutCount:
                          diagnostics?.callbackTimeoutCount ?? 0,
                      callbackWaitTimedOut:
                          diagnostics?.callbackWaitTimedOut ?? false,
                      lastDroppedFrameReason:
                          diagnostics?.lastDroppedFrameReason))
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
    /// Session that was active before the matrix began. Each trial receives a
    /// fresh capture session after its explicit connect, so this stays
    /// separate from the per-trial `sessionID`.
    public let initialSessionID: String?
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
    public let executionFailureCode: String?
    public let performance: NativeCaptureFormatPerformanceEvidence
    public let cleanup: NativeCaptureFormatCleanupEvidence

    public init(caseID: String, sessionID: String, deviceID: String,
                samples: [NativeCaptureFormatValidationSample],
                cleanup: NativeCaptureFormatCleanupEvidence,
                initialSessionID: String? = nil,
                videoSampleCount: Int? = nil, pixelBufferCount: Int? = nil,
                nonImageVideoSampleCount: Int? = nil,
                nonImageVideoBlockBufferCount: Int? = nil,
                decodedH264FrameCount: Int? = nil,
                h264DecodeFailureCount: Int? = nil,
                h264DecodeSubmittedCount: Int? = nil,
                h264DecodeDroppedFrameCount: Int? = nil,
                h264DecodeQueueLatencyTotalMilliseconds: Double? = nil,
                h264DecodeQueueLatencyMaximumMilliseconds: Double? = nil,
                h264DecodeTotalMilliseconds: Double? = nil,
                h264DecodeMaximumMilliseconds: Double? = nil,
                decodedHEVCFrameCount: Int? = nil,
                droppedVideoFrameCount: Int? = nil,
                backpressureEventCount: Int? = nil,
                callbackTimeoutCount: Int? = nil,
                callbackWaitTimedOut: Bool? = nil,
                lastDroppedFrameReason: String? = nil,
                runtimeErrorCount: Int? = nil, interruptionCount: Int? = nil,
                requestedOutputPolicy: String? = nil,
                fallbackUsed: Bool = false,
                executionFailureCode: String? = nil,
                performance: NativeCaptureFormatPerformanceEvidence? = nil) {
        let last = samples.last
        let encodedSamples = videoSampleCount ?? last?.videoSampleCount ?? 0
        let decodedH264 = decodedH264FrameCount ??
            last?.performance.decodedH264FrameCount ?? 0
        let decodeFailures = h264DecodeFailureCount ??
            last?.performance.h264DecodeFailureCount ?? 0
        let decodeSubmitted = h264DecodeSubmittedCount ??
            last?.performance.h264DecodeSubmittedCount ?? 0
        let decodeDropped = h264DecodeDroppedFrameCount ??
            last?.performance.h264DecodeDroppedFrameCount ?? 0
        let queueLatencyTotal = h264DecodeQueueLatencyTotalMilliseconds ??
            last?.performance.h264DecodeQueueLatencyTotalMilliseconds ?? 0
        let queueLatencyMaximum = h264DecodeQueueLatencyMaximumMilliseconds ??
            last?.performance.h264DecodeQueueLatencyMaximumMilliseconds ?? 0
        let decodeTotal = h264DecodeTotalMilliseconds ??
            last?.performance.h264DecodeTotalMilliseconds ?? 0
        let decodeMaximum = h264DecodeMaximumMilliseconds ??
            last?.performance.h264DecodeMaximumMilliseconds ?? 0
        let decodedHEVC = decodedHEVCFrameCount ??
            last?.performance.decodedHEVCFrameCount ?? 0
        let dropped = droppedVideoFrameCount ??
            last?.performance.droppedVideoFrameCount ?? 0
        let backpressure = backpressureEventCount ??
            last?.performance.backpressureEventCount ?? 0
        let callbackTimeouts = callbackTimeoutCount ??
            last?.performance.callbackTimeoutCount ?? 0
        let callbackTimedOut = callbackWaitTimedOut ??
            last?.performance.callbackWaitTimedOut ?? false
        let dropReason = lastDroppedFrameReason ??
            last?.performance.lastDroppedFrameReason
        self.caseID = caseID
        self.initialSessionID = initialSessionID
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
        self.executionFailureCode = executionFailureCode
        self.performance = performance ??
            NativeCaptureFormatPerformanceEvidence(
                encodedVideoSampleCount: encodedSamples,
                decodedH264FrameCount: decodedH264,
                h264DecodeFailureCount: decodeFailures,
                h264DecodeSubmittedCount: decodeSubmitted,
                h264DecodeDroppedFrameCount: decodeDropped,
                h264DecodeQueueLatencyTotalMilliseconds: queueLatencyTotal,
                h264DecodeQueueLatencyMaximumMilliseconds: queueLatencyMaximum,
                h264DecodeTotalMilliseconds: decodeTotal,
                h264DecodeMaximumMilliseconds: decodeMaximum,
                decodedHEVCFrameCount: decodedHEVC,
                droppedVideoFrameCount: dropped,
                backpressureEventCount: backpressure,
                callbackTimeoutCount: callbackTimeouts,
                callbackWaitTimedOut: callbackTimedOut,
                lastDroppedFrameReason: dropReason)
        self.cleanup = cleanup
    }

    public init(caseID: String, stats: [CaptureStats],
                expectedDeviceID: String,
                cleanup: NativeCaptureFormatCleanupEvidence,
                initialSessionID: String? = nil) {
        self.init(caseID: caseID,
                  sessionID: stats.last?.sessionID ?? "",
                  deviceID: stats.last?.frame?.deviceID ?? expectedDeviceID,
                  samples: stats.map { NativeCaptureFormatValidationSample(
                      stats: $0, expectedDeviceID: expectedDeviceID) },
                  cleanup: cleanup, initialSessionID: initialSessionID)
    }

    func withCleanup(_ cleanup: NativeCaptureFormatCleanupEvidence) -> Self {
        Self(caseID: caseID, sessionID: sessionID, deviceID: deviceID,
             samples: samples, cleanup: cleanup,
             initialSessionID: initialSessionID,
             videoSampleCount: videoSampleCount,
             pixelBufferCount: pixelBufferCount,
             nonImageVideoSampleCount: nonImageVideoSampleCount,
             nonImageVideoBlockBufferCount: nonImageVideoBlockBufferCount,
             decodedH264FrameCount: decodedH264FrameCount,
             h264DecodeFailureCount: h264DecodeFailureCount,
             runtimeErrorCount: runtimeErrorCount,
             interruptionCount: interruptionCount,
             requestedOutputPolicy: requestedOutputPolicy,
             fallbackUsed: fallbackUsed,
             executionFailureCode: executionFailureCode,
             performance: performance)
    }

    func withExecutionFailure(_ code: String) -> Self {
        Self(caseID: caseID, sessionID: sessionID, deviceID: deviceID,
             samples: samples, cleanup: cleanup,
             initialSessionID: initialSessionID,
             videoSampleCount: videoSampleCount,
             pixelBufferCount: pixelBufferCount,
             nonImageVideoSampleCount: nonImageVideoSampleCount,
             nonImageVideoBlockBufferCount: nonImageVideoBlockBufferCount,
             decodedH264FrameCount: decodedH264FrameCount,
             h264DecodeFailureCount: h264DecodeFailureCount,
             runtimeErrorCount: runtimeErrorCount,
             interruptionCount: interruptionCount,
             requestedOutputPolicy: requestedOutputPolicy,
             fallbackUsed: fallbackUsed,
             executionFailureCode: code,
             performance: performance)
    }
}

/// Scalar restoration evidence for the mode that was active before the
/// matrix. The adapter decides whether restoration is safe after the final
/// cleanup and exact-session checks.
public struct NativeCaptureFormatRestoreEvidence: Codable, Sendable,
    Equatable {
    public let attempted: Bool
    public let succeeded: Bool
    public let sessionID: String?
    public let failureCode: String?

    public init(attempted: Bool, succeeded: Bool,
                sessionID: String? = nil, failureCode: String? = nil) {
        self.attempted = attempted
        self.succeeded = succeeded
        self.sessionID = sessionID
        self.failureCode = failureCode
    }
}

/// Existing-owner seam for the bounded matrix. `runCase` may select and
/// sample one format, while `cleanup` must pause that case before the next
/// one. No production transport is stored by this value.
public struct NativeCaptureFormatValidationExecutorAdapter: Sendable {
    public typealias RunCase = @Sendable (
        _ definition: NativeCaptureFormatValidationCase,
        _ request: NativeCaptureFormatValidationRequest
    ) async throws -> NativeCaptureFormatValidationMetrics
    public typealias Cleanup = @Sendable () async
        -> NativeCaptureFormatCleanupEvidence
    public typealias Restore = @Sendable () async throws
        -> NativeCaptureFormatRestoreEvidence

    let runCase: RunCase
    let cleanup: Cleanup
    let restore: Restore?

    public init(
        runCase: @escaping RunCase,
        cleanup: @escaping Cleanup,
        restore: Restore? = nil
    ) {
        self.runCase = runCase
        self.cleanup = cleanup
        self.restore = restore
    }
}

public enum NativeCaptureFormatTrialOutcome: String, Codable, Sendable,
    Equatable, CaseIterable {
    case verified
    case expectedFailure = "expected_failure"
    case failed
}

private func nativeCaptureFormatEncodedCount(
    _ metrics: NativeCaptureFormatValidationMetrics
) -> Int {
    max(metrics.videoSampleCount,
        metrics.performance.encodedVideoSampleCount)
}

private func nativeCaptureFormatCodecStatus(
    definition: NativeCaptureFormatValidationCase,
    metrics: NativeCaptureFormatValidationMetrics
) -> NativeCaptureFormatEvidenceStatus {
    guard !definition.expectsZeroCallbacks, let sample = metrics.samples.last else {
        return definition.expectsZeroCallbacks ? .notApplicable : .unknown
    }
    let expectedSampleFourCC = definition.expectedOutputFourCC ?? "BGRA"
    let metadataMatches = sample.sessionID == metrics.sessionID &&
        sample.deviceID == metrics.deviceID &&
        sample.width == definition.mode.width &&
        sample.height == definition.mode.height &&
        sample.inputPixelFormat == definition.inputPixelFormat &&
        sample.inputFourCC == definition.expectedInputFourCC &&
        sample.videoSampleFourCC == expectedSampleFourCC &&
        sample.outputFourCC == "BGRA" &&
        sample.requestedOutputPolicy == definition.outputPolicy.rawValue
    return metadataMatches && nativeCaptureFormatEncodedCount(metrics) > 0
        ? .verified : .failed
}

private func nativeCaptureFormatDecodeStatus(
    definition: NativeCaptureFormatValidationCase,
    metrics: NativeCaptureFormatValidationMetrics
) -> NativeCaptureFormatEvidenceStatus {
    guard !definition.expectsZeroCallbacks else { return .notApplicable }
    guard definition.outputPolicy == .h264 else { return .notApplicable }
    let decoded = max(metrics.decodedH264FrameCount,
                      metrics.performance.decodedH264FrameCount)
    let failures = max(metrics.h264DecodeFailureCount,
                       metrics.performance.h264DecodeFailureCount)
    let timingValid = metrics.performance.h264DecodeTotalMilliseconds.isFinite &&
        metrics.performance.h264DecodeTotalMilliseconds >= 0 &&
        metrics.performance.h264DecodeMaximumMilliseconds.isFinite &&
        metrics.performance.h264DecodeMaximumMilliseconds >= 0 &&
        metrics.performance.h264DecodeTotalMilliseconds >=
            metrics.performance.h264DecodeMaximumMilliseconds
    return decoded > 0 && failures == 0 && timingValid ? .verified : .failed
}

private func nativeCaptureFormatRealtimeRateStatus(
    definition: NativeCaptureFormatValidationCase,
    metrics: NativeCaptureFormatValidationMetrics
) -> NativeCaptureFormatEvidenceStatus {
    guard !definition.expectsZeroCallbacks else { return .notApplicable }
    let rates = metrics.samples.map(\.recentFPS)
        .filter { $0.isFinite && $0 > 0 }.sorted()
    guard let median = rates.isEmpty ? nil : rates[rates.count / 2] else {
        return .unknown
    }
    let tolerance = max(1, definition.mode.frameRate * definition.fpsTolerance)
    guard abs(median - definition.mode.frameRate) <= tolerance else {
        return .failed
    }
    let performance = metrics.performance
    return performance.droppedVideoFrameCount == 0 &&
        performance.h264DecodeDroppedFrameCount == 0 &&
        performance.backpressureEventCount == 0 &&
        performance.callbackTimeoutCount == 0 &&
        !performance.callbackWaitTimedOut ? .verified : .failed
}

public struct NativeCaptureFormatValidationTrial: Codable, Sendable,
    Equatable, Identifiable {
    public let id: String
    public let caseID: String
    public let expectation: NativeCaptureFormatExpectation
    public let sampleCount: Int
    public let videoSampleCount: Int
    public let decodedH264FrameCount: Int
    public let medianFPS: Double?
    public let minimumFPS: Double?
    public let maximumFPS: Double?
    public let performance: NativeCaptureFormatPerformanceEvidence
    public let codecStatus: NativeCaptureFormatEvidenceStatus
    public let decodeStatus: NativeCaptureFormatEvidenceStatus
    public let realtimeRateStatus: NativeCaptureFormatEvidenceStatus
    public let videoSampleFourCC: String?
    public let frameOutputFourCC: String?
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
        let rates = metrics.samples.map(\.recentFPS)
            .filter { $0.isFinite && $0 > 0 }.sorted()
        medianFPS = rates.isEmpty ? nil : rates[rates.count / 2]
        minimumFPS = rates.first
        maximumFPS = rates.last
        performance = metrics.performance
        codecStatus = nativeCaptureFormatCodecStatus(
            definition: definition, metrics: metrics)
        decodeStatus = nativeCaptureFormatDecodeStatus(
            definition: definition, metrics: metrics)
        realtimeRateStatus = nativeCaptureFormatRealtimeRateStatus(
            definition: definition, metrics: metrics)
        videoSampleFourCC = metrics.samples.last?.videoSampleFourCC
        frameOutputFourCC = metrics.samples.last?.outputFourCC
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
    public let restoration: NativeCaptureFormatRestoreEvidence?
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
            automaticFallback: false, restoration: nil)
    }

    /// Runs each case through an injected owner in strict order. The owner is
    /// responsible for the actual CameraService connect; this coordinator only
    /// imposes warmup/sample bounds, pause cleanup between cases, and optional
    /// safe restoration. Tests inject a fake owner, while the route supplies
    /// the existing CameraService owner.
    public static func execute(
        _ request: NativeCaptureFormatValidationRequest,
        adapter: NativeCaptureFormatValidationExecutorAdapter
    ) async -> NativeCaptureFormatValidationReport {
        var metrics: [NativeCaptureFormatValidationMetrics] = []
        var cleanupAllowsRestore = true
        let definitions = request.caseIDs.compactMap(
            NativeCaptureFormatValidationCase.resolve)

        for definition in definitions {
            do {
                let value = try await adapter.runCase(definition, request)
                let caseMetrics = value.caseID == definition.id ? value
                    : value.withExecutionFailure("capture_format_case_mismatch")
                let cleanup = await adapter.cleanup()
                metrics.append(caseMetrics.withCleanup(cleanup))
                guard cleanup.isClean else {
                    cleanupAllowsRestore = false
                    break
                }
            } catch is CancellationError {
                let cleanup = await adapter.cleanup()
                metrics.append(.empty(caseID: definition.id,
                    sessionID: request.expectedSessionID,
                    deviceID: request.expectedDeviceID,
                    cleanup: cleanup,
                    initialSessionID: request.expectedSessionID,
                    executionFailureCode: "capture_format_cancelled"))
                cleanupAllowsRestore = cleanup.isClean
                break
            } catch {
                let cleanup = await adapter.cleanup()
                metrics.append(.empty(caseID: definition.id,
                    sessionID: request.expectedSessionID,
                    deviceID: request.expectedDeviceID,
                    cleanup: cleanup,
                    initialSessionID: request.expectedSessionID,
                    executionFailureCode: executionFailureCode(error)))
                cleanupAllowsRestore = cleanup.isClean
                break
            }
        }

        var restoration: NativeCaptureFormatRestoreEvidence?
        if let restore = adapter.restore,
           cleanupAllowsRestore, !metrics.isEmpty {
            do {
                restoration = try await restore()
            } catch is CancellationError {
                restoration = .init(attempted: true, succeeded: false,
                    failureCode: "capture_format_restore_cancelled")
            } catch {
                restoration = .init(attempted: true, succeeded: false,
                    failureCode: executionFailureCode(error))
            }
        } else if adapter.restore != nil {
            restoration = .init(attempted: false, succeeded: false,
                failureCode: cleanupAllowsRestore
                    ? "capture_format_restore_not_ready"
                    : "capture_format_restore_not_safe")
        }

        let report = evaluate(request, metrics: metrics)
        let cancelled = metrics.contains {
            $0.executionFailureCode == "capture_format_cancelled"
        }
        let phase = cancelled ? "cancelled" :
            report.completed ? "completed" : "partial"
        return report.withExecutionPhase(phase, restoration: restoration)
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
            trials: trials, phase: "completed",
            completed: metrics.count == request.caseIDs.count,
            passed: failures.isEmpty && metrics.count == request.caseIDs.count,
            verifiedCaseCount: verified,
            expectedFailureCount: expectedFailures,
            failureCode: aggregateFailure,
            cameraImagesStored: imagesStored,
            automaticFallback: fallback, restoration: nil)
    }

    private static func failureCode(
        _ definition: NativeCaptureFormatValidationCase,
        metrics: NativeCaptureFormatValidationMetrics,
        request: NativeCaptureFormatValidationRequest
    ) -> String? {
        guard (metrics.initialSessionID ?? request.expectedSessionID) ==
                request.expectedSessionID else {
            return "capture_format_session_changed"
        }
        guard metrics.deviceID == request.expectedDeviceID else {
            return "capture_format_device_changed"
        }
        guard metrics.samples.count <= request.maximumSamplesPerCase else {
            return "capture_format_sample_limit_exceeded"
        }
        if let executionFailureCode = metrics.executionFailureCode {
            return executionFailureCode
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
            sample.sessionID == metrics.sessionID &&
                sample.deviceID == request.expectedDeviceID &&
                sample.width == definition.mode.width &&
                sample.height == definition.mode.height &&
                sample.inputPixelFormat == definition.inputPixelFormat &&
                sample.inputFourCC == definition.expectedInputFourCC &&
                sample.videoSampleFourCC == definition.expectedOutputFourCC &&
                sample.outputFourCC == "BGRA" &&
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
            return "capture_format_realtime_rate_missing"
        }
        let sorted = rates.sorted()
        let median = sorted[sorted.count / 2]
        let tolerance = max(1, definition.mode.frameRate * definition.fpsTolerance)
        guard abs(median - definition.mode.frameRate) <= tolerance else {
            return "capture_format_realtime_rate_failed"
        }
        guard metrics.performance.droppedVideoFrameCount == 0,
              metrics.performance.h264DecodeDroppedFrameCount == 0,
              metrics.performance.backpressureEventCount == 0,
              metrics.performance.callbackTimeoutCount == 0,
              !metrics.performance.callbackWaitTimedOut else {
            return "capture_format_realtime_drop_or_backpressure"
        }
        if definition.outputPolicy == .bgra,
           metrics.pixelBufferCount == 0 {
            return "capture_format_pixel_buffer_missing"
        }
        if definition.outputPolicy == .h264 {
            let decoded = max(metrics.decodedH264FrameCount,
                              metrics.performance.decodedH264FrameCount)
            let decodeFailures = max(metrics.h264DecodeFailureCount,
                                     metrics.performance.h264DecodeFailureCount)
            guard decoded > 0 else {
                return "capture_format_h264_decode_missing"
            }
            guard decodeFailures == 0 else {
                return "capture_format_h264_decode_failed"
            }
            guard metrics.performance.h264DecodeTotalMilliseconds.isFinite,
                  metrics.performance.h264DecodeTotalMilliseconds >= 0,
                  metrics.performance.h264DecodeMaximumMilliseconds.isFinite,
                  metrics.performance.h264DecodeMaximumMilliseconds >= 0,
                  metrics.performance.h264DecodeTotalMilliseconds >=
                      metrics.performance.h264DecodeMaximumMilliseconds else {
                return "capture_format_h264_decode_timing_invalid"
            }
        }
        return nil
    }

    private static func executionFailureCode(_ error: Error) -> String {
        if let failure = error as? BridgeFailure {
            return String(failure.code.prefix(128))
        }
        if error is CancellationError { return "capture_format_cancelled" }
        return String("capture_format_executor_failed_\(error)".prefix(128))
    }
}

private extension NativeCaptureFormatValidationReport {
    func withExecutionPhase(
        _ phase: String,
        restoration: NativeCaptureFormatRestoreEvidence?
    ) -> Self {
        let restorationFailure = restoration.flatMap {
            $0.attempted && !$0.succeeded ? $0.failureCode : nil
        }
        return Self(operation: operation, expectedSessionID: expectedSessionID,
             expectedDeviceID: expectedDeviceID, plan: plan, trials: trials,
             phase: phase, completed: completed,
             passed: passed && restorationFailure == nil,
             verifiedCaseCount: verifiedCaseCount,
             expectedFailureCount: expectedFailureCount,
             failureCode: failureCode ?? restorationFailure,
             cameraImagesStored: cameraImagesStored,
             automaticFallback: automaticFallback, restoration: restoration)
    }
}

private extension NativeCaptureFormatValidationMetrics {
    static func empty(caseID: String, sessionID: String,
                      deviceID: String,
                      cleanup: NativeCaptureFormatCleanupEvidence = .init(
                          stopRequested: true, finalPhase: "paused",
                          finalFrameCount: 0),
                      initialSessionID: String? = nil,
                      executionFailureCode: String? = nil) -> Self {
        .init(caseID: caseID, sessionID: sessionID, deviceID: deviceID,
              samples: [], cleanup: cleanup,
              initialSessionID: initialSessionID,
              executionFailureCode: executionFailureCode)
    }
}

public typealias Pocket3NativeCaptureFormatValidationRequest =
    NativeCaptureFormatValidationRequest
public typealias Pocket3NativeCaptureFormatValidationReport =
    NativeCaptureFormatValidationReport
