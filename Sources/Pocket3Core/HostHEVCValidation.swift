import CoreMedia
import CryptoKit
import Foundation

/// Developer-only host HEVC validation request. A caller must identify the
/// exact current device and CaptureEngine session; generation is optional for
/// CLI convenience and is always resolved to the current source generation.
public struct HostHEVCValidationRequest: Codable, Sendable, Equatable {
    public static let operation = "validation-host-hevc"
    public static let maximumFrames = 16
    public static let maximumInputAgeSeconds = 5.0

    public let expectedDeviceID: String
    public let expectedCaptureSessionID: String
    public let expectedGeneration: UInt64?
    public let maximumFramesToEncode: Int
    public let maximumInputAgeSeconds: Double
    public let execute: Bool

    public init(expectedDeviceID: String,
                expectedCaptureSessionID: String,
                expectedGeneration: UInt64? = nil,
                maximumFramesToEncode: Int = Self.maximumFrames,
                maximumInputAgeSeconds: Double = 1,
                execute: Bool = false) throws {
        let device = expectedDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = expectedCaptureSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !device.isEmpty, !session.isEmpty else {
            throw HostHEVCValidationError.invalidIdentity
        }
        guard (1...Self.maximumFrames).contains(maximumFramesToEncode) else {
            throw HostHEVCValidationError.invalidFrameLimit
        }
        guard maximumInputAgeSeconds.isFinite,
              maximumInputAgeSeconds > 0,
              maximumInputAgeSeconds <= Self.maximumInputAgeSeconds else {
            throw HostHEVCValidationError.invalidFreshnessWindow
        }
        self.expectedDeviceID = String(device.prefix(128))
        self.expectedCaptureSessionID = String(session.prefix(128))
        self.expectedGeneration = expectedGeneration
        self.maximumFramesToEncode = maximumFramesToEncode
        self.maximumInputAgeSeconds = maximumInputAgeSeconds
        self.execute = execute
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                "deviceID", "session", "generation", "maxFrames",
                "maxAgeSeconds", "execute"
              ]),
              let device = fields["deviceID"]?.string,
              let session = fields["session"]?.string else {
            throw HostHEVCValidationError.invalidArguments
        }
        let generation: UInt64?
        if let value = fields["generation"] {
            guard let number = value.number, number.isFinite,
                  number.rounded() == number, number >= 0,
                  number <= Double(UInt64.max) else {
                throw HostHEVCValidationError.invalidGeneration
            }
            generation = UInt64(number)
        } else {
            generation = nil
        }
        let maxFrames: Int
        if let value = fields["maxFrames"] {
            guard let number = value.number, number.isFinite,
                  number.rounded() == number, let parsed = Int(exactly: number) else {
                throw HostHEVCValidationError.invalidFrameLimit
            }
            maxFrames = parsed
        } else {
            maxFrames = Self.maximumFrames
        }
        let maxAge = fields["maxAgeSeconds"]?.number ?? 1
        let execute = fields["execute"]?.bool ?? false
        if fields["execute"] != nil, fields["execute"]?.bool == nil {
            throw HostHEVCValidationError.invalidArguments
        }
        try self.init(expectedDeviceID: device,
                      expectedCaptureSessionID: session,
                      expectedGeneration: generation,
                      maximumFramesToEncode: maxFrames,
                      maximumInputAgeSeconds: maxAge,
                      execute: execute)
    }

    public init(cliArguments: [String]) throws {
        var device: String?
        var session: String?
        var generation: UInt64?
        var maxFrames: Int?
        var maxAge: Double?
        var execute = false
        var index = 0
        while index < cliArguments.count {
            let option = cliArguments[index]
            if option == "--execute" {
                guard !execute else { throw HostHEVCValidationError.invalidArguments }
                execute = true
                index += 1
                continue
            }
            guard index + 1 < cliArguments.count else {
                throw HostHEVCValidationError.invalidArguments
            }
            let value = cliArguments[index + 1]
            switch option {
            case "--device":
                guard device == nil else { throw HostHEVCValidationError.invalidArguments }
                device = value
            case "--session":
                guard session == nil else { throw HostHEVCValidationError.invalidArguments }
                session = value
            case "--generation":
                guard generation == nil, let parsed = UInt64(value) else {
                    throw HostHEVCValidationError.invalidGeneration
                }
                generation = parsed
            case "--max-frames":
                guard maxFrames == nil, let parsed = Int(value) else {
                    throw HostHEVCValidationError.invalidFrameLimit
                }
                maxFrames = parsed
            case "--max-age-seconds":
                guard maxAge == nil, let parsed = Double(value) else {
                    throw HostHEVCValidationError.invalidFreshnessWindow
                }
                maxAge = parsed
            default:
                throw HostHEVCValidationError.invalidArguments
            }
            index += 2
        }
        try self.init(expectedDeviceID: device ?? "",
                      expectedCaptureSessionID: session ?? "",
                      expectedGeneration: generation,
                      maximumFramesToEncode: maxFrames ?? Self.maximumFrames,
                      maximumInputAgeSeconds: maxAge ?? 1,
                      execute: execute)
    }

    public var arguments: JSONValue {
        var fields: [String: JSONValue] = [
            "deviceID": .string(expectedDeviceID),
            "session": .string(expectedCaptureSessionID),
            "maxFrames": .number(Double(maximumFramesToEncode)),
            "maxAgeSeconds": .number(maximumInputAgeSeconds),
            "execute": .bool(execute)
        ]
        if let expectedGeneration {
            fields["generation"] = .number(Double(expectedGeneration))
        }
        return .object(fields)
    }

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }
}

public enum HostHEVCValidationError: Error, LocalizedError, Codable, Sendable,
    Equatable {
    case invalidArguments
    case invalidIdentity
    case invalidGeneration
    case invalidFrameLimit
    case invalidFreshnessWindow

    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "invalid host HEVC validation arguments"
        case .invalidIdentity: "host HEVC validation requires exact device and capture session IDs"
        case .invalidGeneration: "host HEVC validation generation is invalid"
        case .invalidFrameLimit: "host HEVC validation frame limit is invalid"
        case .invalidFreshnessWindow: "host HEVC validation freshness window is invalid"
        }
    }
}

/// Hash-only evidence for one copied host `hvc1` sample. No image, sample
/// buffer or encoded payload bytes are retained by the validation result.
public struct HostHEVCSampleDigest: Codable, Sendable, Equatable {
    public let transport: HostVideoEncodingTransport
    public let codec: VideoToolboxCodec
    public let codecIdentifier: String
    public let sessionID: String
    public let generation: UInt64
    public let sequence: UInt64
    public let width: Int
    public let height: Int
    public let parameterSetByteCount: Int
    public let accessUnitByteCount: Int
    public let parameterSetSHA256: String
    public let accessUnitSHA256: String
    public let isKeyFrame: Bool
    public let usbWireCodecClaim: String?

    public init(sample: HostHEVCEncodedSample) {
        let parameterBytes = sample.parameterSets.parameterSets.reduce(into: Data()) {
            $0.append($1)
        }
        self.transport = sample.transport
        self.codec = sample.codec
        self.codecIdentifier = "hvc1"
        self.sessionID = sample.sessionID
        self.generation = sample.generation
        self.sequence = sample.sequence
        self.width = Int(sample.dimensions.width)
        self.height = Int(sample.dimensions.height)
        self.parameterSetByteCount = parameterBytes.count
        self.accessUnitByteCount = sample.accessUnit.count
        self.parameterSetSHA256 = Self.hex(SHA256.hash(data: parameterBytes))
        self.accessUnitSHA256 = Self.hex(SHA256.hash(data: sample.accessUnit))
        self.isKeyFrame = sample.isKeyFrame
        self.usbWireCodecClaim = sample.usbWireCodecClaim
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct HostHEVCValidationCleanupEvidence: Codable, Sendable,
    Equatable {
    public let requested: Bool
    public let completed: Bool
    public let phase: HostHEVCOutputSessionPhase?
    public let sessionID: String
    public let generation: UInt64

    public init(requested: Bool, completed: Bool,
                phase: HostHEVCOutputSessionPhase?, sessionID: String,
                generation: UInt64) {
        self.requested = requested
        self.completed = completed
        self.phase = phase
        self.sessionID = String(sessionID.prefix(128))
        self.generation = generation
    }
}

public struct HostHEVCValidationResult: Codable, Sendable, Equatable {
    public let operation: String
    public let request: HostHEVCValidationRequest
    public let dryRun: Bool
    public let binding: HostHEVCFrameSourceBinding?
    public let capability: HostHEVCOutputCapabilityReport?
    public let freshFrameObserved: Bool
    public let freshInputPixelFormat: HostVideoInputPixelFormat?
    public let submissions: [HostHEVCOutputSubmissionEvidence]
    public let samples: [HostHEVCSampleDigest]
    public let cleanup: HostHEVCValidationCleanupEvidence
    public let failureCode: String?

    public init(
        request: HostHEVCValidationRequest,
        binding: HostHEVCFrameSourceBinding? = nil,
        capability: HostHEVCOutputCapabilityReport? = nil,
        freshFrameObserved: Bool = false,
        freshInputPixelFormat: HostVideoInputPixelFormat? = nil,
        submissions: [HostHEVCOutputSubmissionEvidence] = [],
        samples: [HostHEVCSampleDigest] = [],
        cleanup: HostHEVCValidationCleanupEvidence,
        failureCode: String? = nil
    ) {
        self.operation = HostHEVCValidationRequest.operation
        self.request = request
        self.dryRun = !request.execute
        self.binding = binding
        self.capability = capability
        self.freshFrameObserved = freshFrameObserved
        self.freshInputPixelFormat = freshInputPixelFormat
        self.submissions = Array(submissions.prefix(HostHEVCValidationRequest.maximumFrames))
        self.samples = Array(samples.prefix(HostHEVCValidationRequest.maximumFrames))
        self.cleanup = cleanup
        self.failureCode = failureCode.map { String($0.prefix(128)) }
    }

    public var completed: Bool {
        request.execute && failureCode == nil && !samples.isEmpty && cleanup.completed
    }
}

/// Developer-only service that binds the real CaptureEngine frame source to
/// the host HEVC session. The backend factory is injectable so all tests stay
/// offline; the default factory is lazy and does not open a camera.
public actor HostHEVCValidationService {
    public typealias BackendFactory = @Sendable () -> any HostHEVCEncoderBackend
    public typealias Clock = @Sendable () -> Double

    private let source: any HostHEVCFrameSource
    private let backendFactory: BackendFactory
    private let clock: Clock
    private var active = false

    public init(
        source: any HostHEVCFrameSource,
        backendFactory: @escaping BackendFactory = {
            VideoToolboxHostHEVCEncoderBackend()
        },
        clock: @escaping Clock = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.source = source
        self.backendFactory = backendFactory
        self.clock = clock
    }

    public func run(_ request: HostHEVCValidationRequest)
        async -> HostHEVCValidationResult {
        guard !active else {
            return Self.failure(request, code: "host_hevc_validation_busy")
        }
        active = true
        defer { active = false }
        return await runActive(request)
    }

    private func runActive(_ request: HostHEVCValidationRequest)
        async -> HostHEVCValidationResult {
        guard let binding = source.currentBinding() else {
            return Self.failure(request, code: "host_hevc_capture_unavailable")
        }
        guard binding.deviceID == request.expectedDeviceID,
              binding.captureSessionID == request.expectedCaptureSessionID,
              request.expectedGeneration.map({ $0 == binding.generation }) ?? true else {
            return Self.failure(request, binding: binding,
                                code: "host_hevc_session_changed")
        }
        let baseCapability = HostHEVCOutputCapabilityReport(
            width: binding.width, height: binding.height,
            frameRate: 30, sessionID: binding.captureSessionID,
            generation: binding.generation)

        let fresh: HostHEVCFreshFrame
        do {
            fresh = try source.freshFrame(
                expected: binding,
                maxAgeSeconds: request.maximumInputAgeSeconds)
        } catch {
            return Self.failure(request, binding: binding,
                                capability: baseCapability,
                                code: Self.sourceErrorCode(error))
        }
        guard fresh.binding == binding else {
            return Self.failure(request, binding: binding,
                                capability: baseCapability,
                                freshFrameObserved: true,
                                freshInputPixelFormat: fresh.frame.inputPixelFormat,
                                code: "host_hevc_session_changed")
        }
        guard !request.execute else {
            return await execute(request, binding: binding, firstFrame: fresh)
        }
        return HostHEVCValidationResult(
            request: request, binding: binding, capability: baseCapability,
            freshFrameObserved: true,
            freshInputPixelFormat: fresh.frame.inputPixelFormat,
            cleanup: .init(requested: false, completed: true, phase: nil,
                           sessionID: binding.captureSessionID,
                           generation: binding.generation))
    }

    private func execute(
        _ request: HostHEVCValidationRequest,
        binding: HostHEVCFrameSourceBinding,
        firstFrame: HostHEVCFreshFrame
    ) async -> HostHEVCValidationResult {
        let configuration: HostVideoEncoderConfiguration
        do {
            configuration = try HostVideoEncoderConfiguration(
                width: binding.width, height: binding.height,
                frameRate: 30, keyFrameInterval: 30,
                maximumPendingFrames: 2)
        } catch {
            return Self.failure(request, binding: binding,
                                code: "host_hevc_invalid_configuration")
        }
        let digestSink = HostHEVCValidationDigestSink()
        let session: HostHEVCOutputSession
        do {
            session = try HostHEVCOutputSession(
                sessionID: binding.captureSessionID,
                generation: binding.generation,
                configuration: configuration,
                backend: backendFactory(),
                maximumInputAgeSeconds: request.maximumInputAgeSeconds,
                sink: digestSink.receive)
        } catch {
            return Self.failure(request, binding: binding,
                                code: "host_hevc_session_unavailable")
        }

        var submissions: [HostHEVCOutputSubmissionEvidence] = []
        var failureCode: String?
        var nextFrame = firstFrame
        for index in 0..<request.maximumFramesToEncode {
            do {
                try Task.checkCancellation()
                guard let current = source.currentBinding(), current == binding else {
                    failureCode = "host_hevc_session_changed"
                    break
                }
                if index > 0 {
                    nextFrame = try source.freshFrame(
                        expected: binding,
                        maxAgeSeconds: request.maximumInputAgeSeconds)
                }
                let now = clock()
                let evidence = await session.submit(
                    nextFrame.frame,
                    receivedUptime: nextFrame.receivedUptime,
                    nowUptime: now)
                submissions.append(evidence)
                switch evidence.disposition {
                case .staleSession, .staleGeneration, .inputClockInvalid,
                     .stopped:
                    failureCode = "host_hevc_submission_" + evidence.disposition.rawValue
                    break
                case .accepted, .droppedBackpressure, .inputStale,
                     .pixelFormatUnsupported, .dimensionMismatch:
                    break
                }
                if failureCode != nil { break }
                if evidence.disposition == .accepted {
                    _ = try await waitForOutput(
                        session: session, sequence: nextFrame.frame.sequence)
                }
            } catch is CancellationError {
                failureCode = "cancelled"
                break
            } catch {
                failureCode = Self.sourceErrorCode(error)
                break
            }
        }

        let cleanupSnapshot: HostHEVCOutputSessionSnapshot
        if failureCode == "cancelled" {
            cleanupSnapshot = await session.cancel()
        } else {
            cleanupSnapshot = await session.stop()
        }
        let relay = digestSink.snapshot()
        let cleanup = HostHEVCValidationCleanupEvidence(
            requested: true,
            completed: cleanupSnapshot.phase == .stopped ||
                cleanupSnapshot.phase == .cancelled,
            phase: cleanupSnapshot.phase,
            sessionID: binding.captureSessionID,
            generation: binding.generation)
        return HostHEVCValidationResult(
            request: request, binding: binding,
            capability: cleanupSnapshot.capability,
            freshFrameObserved: true,
            freshInputPixelFormat: firstFrame.frame.inputPixelFormat,
            submissions: submissions, samples: relay,
            cleanup: cleanup, failureCode: failureCode)
    }

    private func waitForOutput(session: HostHEVCOutputSession,
                               sequence: UInt64) async throws -> Bool {
        let started = clock()
        guard started.isFinite else { throw HostHEVCFrameSourceError.invalidTimestamp }
        let deadline = started + 1
        while clock() < deadline {
            try Task.checkCancellation()
            if await session.snapshot().lastOutputSequence == sequence {
                return true
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    private static func sourceErrorCode(_ error: Error) -> String {
        if let error = error as? HostHEVCFrameSourceError {
            switch error {
            case .captureUnavailable: return "host_hevc_capture_unavailable"
            case .noFreshFrame: return "host_hevc_no_fresh_frame"
            case .invalidFreshnessWindow: return "host_hevc_invalid_freshness"
            case .invalidTimestamp: return "host_hevc_invalid_timestamp"
            case .unsupportedPixelFormat: return "host_hevc_pixel_format_unsupported"
            case .sessionChanged: return "host_hevc_session_changed"
            }
        }
        if let error = error as? HostHEVCOutputSessionError {
            switch error {
            case .invalidFreshnessWindow: return "host_hevc_invalid_freshness"
            case .invalidSessionID: return "host_hevc_invalid_session"
            }
        }
        return String(String(describing: error).prefix(128))
    }

    private static func failure(
        _ request: HostHEVCValidationRequest,
        binding: HostHEVCFrameSourceBinding? = nil,
        capability: HostHEVCOutputCapabilityReport? = nil,
        freshFrameObserved: Bool = false,
        freshInputPixelFormat: HostVideoInputPixelFormat? = nil,
        code: String
    ) -> HostHEVCValidationResult {
        let sessionID = binding?.captureSessionID ?? request.expectedCaptureSessionID
        let generation = binding?.generation ?? request.expectedGeneration ?? 0
        return HostHEVCValidationResult(
            request: request, binding: binding, capability: capability,
            freshFrameObserved: freshFrameObserved,
            freshInputPixelFormat: freshInputPixelFormat,
            cleanup: .init(requested: false, completed: true, phase: nil,
                           sessionID: sessionID, generation: generation),
            failureCode: code)
    }
}

private final class HostHEVCValidationDigestSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [HostHEVCSampleDigest] = []

    func receive(_ sample: HostHEVCEncodedSample) {
        lock.withLock {
            guard samples.count < HostHEVCValidationRequest.maximumFrames else {
                return
            }
            samples.append(HostHEVCSampleDigest(sample: sample))
        }
    }

    func snapshot() -> [HostHEVCSampleDigest] {
        lock.withLock { samples }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
