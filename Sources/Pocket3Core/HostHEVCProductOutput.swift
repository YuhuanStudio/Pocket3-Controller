import CryptoKit
import CoreMedia
import Foundation

/// Explicit product output selection for the Mac capture path.
///
/// `host-hevc` is an additional host-side output mode. It consumes copied
/// BGRA/NV12 frames from the existing capture path and leaves the BGRA preview
/// available to its caller. It does not describe, enable, or infer a codec on
/// the camera USB wire.
public enum HostHEVCProductSelection: String, Codable, CaseIterable, Sendable,
    Equatable, Identifiable {
    case bgraPreview = "bgra"
    case hostHEVC = "host-hevc"

    public var id: String { rawValue }
}

/// Local developer IPC contract for the persistent product host-output
/// lifecycle. Start is dry-run unless `execute` is explicit; status and stop
/// only address an already-created local host-output service.
public struct HostHEVCProductStartRequest: Codable, Sendable, Equatable {
    public static let startOperation = "host-hevc-start"
    public static let statusOperation = "host-hevc-status"
    public static let stopOperation = "host-hevc-stop"
    public static let maximumInputAgeSeconds = 5.0

    public let expectedDeviceID: String?
    public let expectedCaptureSessionID: String?
    public let expectedGeneration: UInt64?
    public let maximumInputAge: Double
    /// Explicit local output path. A nil path keeps the existing bounded
    /// sample-evidence consumer and never creates a recording.
    public let outputPath: String?
    public let maximumOutputBytes: Int?
    public let maximumDurationSeconds: Double?
    public let execute: Bool

    public init(expectedDeviceID: String? = nil,
                expectedCaptureSessionID: String? = nil,
                expectedGeneration: UInt64? = nil,
                maximumInputAge: Double = 1,
                outputPath: String? = nil,
                maximumOutputBytes: Int? = nil,
                maximumDurationSeconds: Double? = nil,
                execute: Bool = false) throws {
        if let expectedDeviceID {
            guard !expectedDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HostHEVCProductStartRequestError.invalidArguments
            }
        }
        if let expectedCaptureSessionID {
            guard !expectedCaptureSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HostHEVCProductStartRequestError.invalidArguments
            }
        }
        if let outputPath {
            guard !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HostHEVCProductStartRequestError.invalidArguments
            }
        }
        if maximumOutputBytes != nil || maximumDurationSeconds != nil {
            guard outputPath != nil else {
                throw HostHEVCProductStartRequestError.invalidArguments
            }
            do {
                _ = try HostHEVCProductFileConfiguration(
                    outputPath: outputPath ?? "",
                    maximumBytes: maximumOutputBytes
                        ?? HostHEVCProductFileConfiguration.defaultMaximumBytes,
                    maximumDurationSeconds: maximumDurationSeconds
                        ?? HostHEVCProductFileConfiguration.defaultMaximumDurationSeconds)
            } catch {
                throw HostHEVCProductStartRequestError.invalidArguments
            }
        } else if outputPath != nil {
            do {
                _ = try HostHEVCProductFileConfiguration(
                    outputPath: outputPath ?? "")
            } catch {
                throw HostHEVCProductStartRequestError.invalidArguments
            }
        }
        if execute {
            guard let expectedDeviceID, !expectedDeviceID.isEmpty,
                  let expectedCaptureSessionID, !expectedCaptureSessionID.isEmpty else {
                throw HostHEVCProductStartRequestError.identityRequired
            }
        }
        guard maximumInputAge.isFinite, maximumInputAge > 0,
              maximumInputAge <= Self.maximumInputAgeSeconds,
              expectedGeneration.map({ $0 > 0 }) ?? true else {
            throw HostHEVCProductStartRequestError.invalidArguments
        }
        self.expectedDeviceID = expectedDeviceID
        self.expectedCaptureSessionID = expectedCaptureSessionID
        self.expectedGeneration = expectedGeneration
        self.maximumInputAge = maximumInputAge
        self.outputPath = outputPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumDurationSeconds = maximumDurationSeconds
        self.execute = execute
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                  "deviceID", "session", "generation", "maxAgeSeconds",
                  "outputPath", "maxBytes", "maxDurationSeconds", "execute"
              ]) else {
            throw HostHEVCProductStartRequestError.invalidArguments
        }
        let device = try Self.string(fields["deviceID"])
        let session = try Self.string(fields["session"])
        let generation: UInt64?
        if let value = fields["generation"] {
            guard let number = value.number, number.isFinite,
                  number.rounded() == number, number > 0,
                  number <= Double(UInt64.max) else {
                throw HostHEVCProductStartRequestError.invalidArguments
            }
            generation = UInt64(number)
        } else {
            generation = nil
        }
        let maxAge = fields["maxAgeSeconds"]?.number ?? 1
        let outputPath = try Self.string(fields["outputPath"])
        let maxBytes: Int?
        if let value = fields["maxBytes"] {
            guard let number = value.number, number.isFinite,
                  number.rounded() == number, let parsed = Int(exactly: number) else {
                throw HostHEVCProductStartRequestError.invalidArguments
            }
            maxBytes = parsed
        } else {
            maxBytes = nil
        }
        let maxDuration = fields["maxDurationSeconds"]?.number
        if fields["maxDurationSeconds"] != nil,
           maxDuration == nil {
            throw HostHEVCProductStartRequestError.invalidArguments
        }
        let execute: Bool
        if let value = fields["execute"] {
            guard let parsed = value.bool else {
                throw HostHEVCProductStartRequestError.invalidArguments
            }
            execute = parsed
        } else {
            execute = false
        }
        try self.init(expectedDeviceID: device,
                      expectedCaptureSessionID: session,
                      expectedGeneration: generation,
                      maximumInputAge: maxAge,
                      outputPath: outputPath,
                      maximumOutputBytes: maxBytes,
                      maximumDurationSeconds: maxDuration,
                      execute: execute)
    }

    public init(cliArguments: [String]) throws {
        var device: String?
        var session: String?
        var generation: UInt64?
        var maxAge = 1.0
        var outputPath: String?
        var maxBytes: Int?
        var maxDuration: Double?
        var execute = false
        var index = 0
        while index < cliArguments.count {
            let argument = cliArguments[index]
            if argument == "--execute" {
                guard !execute else {
                    throw HostHEVCProductStartRequestError.invalidArguments
                }
                execute = true
                index += 1
                continue
            }
            guard index + 1 < cliArguments.count else {
                throw HostHEVCProductStartRequestError.invalidArguments
            }
            let value = cliArguments[index + 1]
            switch argument {
            case "--device":
                guard device == nil else { throw HostHEVCProductStartRequestError.invalidArguments }
                device = value
            case "--session":
                guard session == nil else { throw HostHEVCProductStartRequestError.invalidArguments }
                session = value
            case "--generation":
                guard generation == nil, let parsed = UInt64(value), parsed > 0 else {
                    throw HostHEVCProductStartRequestError.invalidArguments
                }
                generation = parsed
            case "--max-age-seconds":
                guard let parsed = Double(value) else {
                    throw HostHEVCProductStartRequestError.invalidArguments
                }
                maxAge = parsed
            case "--output":
                guard outputPath == nil else {
                    throw HostHEVCProductStartRequestError.invalidArguments
                }
                outputPath = value
            case "--max-bytes":
                guard maxBytes == nil, let parsed = Int(value) else {
                    throw HostHEVCProductStartRequestError.invalidArguments
                }
                maxBytes = parsed
            case "--max-duration-seconds":
                guard maxDuration == nil, let parsed = Double(value) else {
                    throw HostHEVCProductStartRequestError.invalidArguments
                }
                maxDuration = parsed
            default:
                throw HostHEVCProductStartRequestError.invalidArguments
            }
            index += 2
        }
        try self.init(expectedDeviceID: device,
                      expectedCaptureSessionID: session,
                      expectedGeneration: generation,
                      maximumInputAge: maxAge,
                      outputPath: outputPath,
                      maximumOutputBytes: maxBytes,
                      maximumDurationSeconds: maxDuration,
                      execute: execute)
    }

    public var arguments: JSONValue {
        var fields: [String: JSONValue] = [
            "maxAgeSeconds": .number(maximumInputAge),
            "execute": .bool(execute)
        ]
        if let expectedDeviceID { fields["deviceID"] = .string(expectedDeviceID) }
        if let expectedCaptureSessionID { fields["session"] = .string(expectedCaptureSessionID) }
        if let expectedGeneration { fields["generation"] = .number(Double(expectedGeneration)) }
        if let outputPath { fields["outputPath"] = .string(outputPath) }
        if let maximumOutputBytes {
            fields["maxBytes"] = .number(Double(maximumOutputBytes))
        }
        if let maximumDurationSeconds {
            fields["maxDurationSeconds"] = .number(maximumDurationSeconds)
        }
        return .object(fields)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "deviceID": .object(["type": .string("string"), "minLength": .number(1)]),
            "session": .object(["type": .string("string"), "minLength": .number(1)]),
            "generation": .object(["type": .string("integer"), "minimum": .number(1)]),
            "maxAgeSeconds": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(maximumInputAgeSeconds)]),
            "outputPath": .object(["type": .string("string"), "minLength": .number(1)]),
            "maxBytes": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(Double(HostHEVCProductFileConfiguration.maximumBytes))]),
            "maxDurationSeconds": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(HostHEVCProductFileConfiguration.maximumDurationSeconds)]),
            "execute": .object(["type": .string("boolean")])
        ]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }

    private static func string(_ value: JSONValue?) throws -> String? {
        guard let value else { return nil }
        guard let result = value.string, !result.isEmpty else {
            throw HostHEVCProductStartRequestError.invalidArguments
        }
        return result
    }
}

public enum HostHEVCProductStartRequestError: Error, LocalizedError,
    Codable, Sendable, Equatable {
    case invalidArguments
    case identityRequired

    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "invalid host HEVC product arguments"
        case .identityRequired: "host HEVC product execution requires exact device and session IDs"
        }
    }
}

/// Immutable provenance and fallback contract for one product selection.
///
/// The initializer derives all transport and codec fields from the selection,
/// so callers cannot construct a `host-hevc` status that claims USB-wire HEVC
/// or silently falls back to BGRA after an encoder failure.
public struct HostHEVCProductContract: Codable, Sendable, Equatable {
    public let selection: HostHEVCProductSelection
    public let transport: HostVideoEncodingTransport?
    public let codec: VideoToolboxCodec?
    public let codecIdentifier: String?
    public let inputPixelFormats: [HostVideoInputPixelFormat]
    public let supportsConcurrentBGRAPreview: Bool
    public let automaticFallback: Bool
    public let usbWireCodecClaim: String?

    public init(selection: HostHEVCProductSelection) {
        self.selection = selection
        self.supportsConcurrentBGRAPreview = true
        self.automaticFallback = false
        self.usbWireCodecClaim = nil
        switch selection {
        case .bgraPreview:
            self.transport = nil
            self.codec = nil
            self.codecIdentifier = nil
            self.inputPixelFormats = [.bgra]
        case .hostHEVC:
            self.transport = .macVideoToolboxHost
            self.codec = .hevc
            self.codecIdentifier = "hvc1"
            self.inputPixelFormats = [
                .bgra, .nv12VideoRange, .nv12FullRange
            ]
        }
    }
}

/// Runtime capability projected from the bounded host output session.
/// Contract fields remain fixed by `HostHEVCProductContract`; the remaining
/// fields are observations from the current or most recently stopped session.
public struct HostHEVCProductCapability: Codable, Sendable, Equatable {
    public let contract: HostHEVCProductContract
    public let sessionID: String?
    public let generation: UInt64?
    public let configured: Bool
    public let verified: Bool
    public let observedSampleCount: Int

    public var selection: HostHEVCProductSelection { contract.selection }
    public var transport: HostVideoEncodingTransport? { contract.transport }
    public var codec: VideoToolboxCodec? { contract.codec }
    public var codecIdentifier: String? { contract.codecIdentifier }
    public var inputPixelFormats: [HostVideoInputPixelFormat] {
        contract.inputPixelFormats
    }
    public var supportsConcurrentBGRAPreview: Bool {
        contract.supportsConcurrentBGRAPreview
    }
    public var automaticFallback: Bool { contract.automaticFallback }
    public var usbWireCodecClaim: String? { contract.usbWireCodecClaim }

    fileprivate init(contract: HostHEVCProductContract,
                     session: HostHEVCOutputSessionSnapshot?) {
        self.contract = contract
        self.sessionID = session?.sessionID
        self.generation = session?.generation
        self.configured = session?.capability.configured ?? false
        self.verified = session?.capability.verified ?? false
        self.observedSampleCount = session?.capability.observedSampleCount ?? 0
    }
}

/// Hash-only provenance for one product hvc1 sample. The encoded access unit
/// and parameter-set bytes are released after hashing; this value never keeps
/// an image, sample buffer or encoded payload.
public struct HostHEVCProductSampleDigest: Codable, Sendable, Equatable {
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

public enum HostHEVCProductOutputPhase: String, Codable, Sendable, Equatable {
    case bgraPreview
    case idle
    case running
    case reconnecting
    case stopping
    case stopped
    case cancelled
    case failed
}

public enum HostHEVCProductConsumer: String, Codable, Sendable, Equatable {
    case localSampleEvidence = "local_sample_evidence"
    case localAnnexBFile = "local_annex_b_file"
}

public struct HostHEVCProductOutputStatus: Codable, Sendable, Equatable {
    public let selection: HostHEVCProductSelection
    public let phase: HostHEVCProductOutputPhase
    public let capability: HostHEVCProductCapability
    public let session: HostHEVCOutputSessionSnapshot?
    public let sinkAttached: Bool
    public let consumer: HostHEVCProductConsumer
    /// Cadence of copied host-encoded samples, derived from a bounded recent
    /// presentation-time window. It is nil until two valid output timestamps
    /// are observed.
    public let encodedFPS: Double?
    public let failureCode: String?
    public let samples: [HostHEVCProductSampleDigest]
    public let file: HostHEVCAnnexBFileConsumerSnapshot?

    public var isRunning: Bool { phase == .running || phase == .reconnecting }
    public var isVerified: Bool { capability.verified }

    fileprivate init(selection: HostHEVCProductSelection,
                     phase: HostHEVCProductOutputPhase,
                     session: HostHEVCOutputSessionSnapshot?,
                     sinkAttached: Bool,
                     consumer: HostHEVCProductConsumer = .localSampleEvidence,
                     encodedFPS: Double? = nil,
                     failureCode: String?,
                     samples: [HostHEVCProductSampleDigest] = [],
                     file: HostHEVCAnnexBFileConsumerSnapshot? = nil) {
        self.selection = selection
        self.phase = phase
        self.capability = HostHEVCProductCapability(
            contract: HostHEVCProductContract(selection: selection),
            session: session)
        self.session = session
        self.sinkAttached = sinkAttached
        self.consumer = consumer
        self.encodedFPS = encodedFPS
        self.failureCode = failureCode ?? session?.failureCode ?? file?.failureCode
        self.samples = Array(samples.prefix(16))
        self.file = file
    }
}

private extension HostHEVCProductOutputStatus {
    enum CodingKeys: String, CodingKey {
        case selection, phase, capability, session, sinkAttached,
             consumer, encodedFPS, failureCode, samples, file
    }
}

extension HostHEVCProductOutputStatus {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selection = try container.decode(HostHEVCProductSelection.self,
            forKey: .selection)
        phase = try container.decode(HostHEVCProductOutputPhase.self,
            forKey: .phase)
        capability = try container.decode(HostHEVCProductCapability.self,
            forKey: .capability)
        session = try container.decodeIfPresent(
            HostHEVCOutputSessionSnapshot.self, forKey: .session)
        sinkAttached = try container.decode(Bool.self, forKey: .sinkAttached)
        consumer = try container.decodeIfPresent(
            HostHEVCProductConsumer.self, forKey: .consumer)
            ?? .localSampleEvidence
        encodedFPS = try container.decodeIfPresent(
            Double.self, forKey: .encodedFPS)
        failureCode = try container.decodeIfPresent(String.self,
            forKey: .failureCode)
        samples = try container.decodeIfPresent(
            [HostHEVCProductSampleDigest].self, forKey: .samples) ?? []
        file = try container.decodeIfPresent(
            HostHEVCAnnexBFileConsumerSnapshot.self, forKey: .file)
    }
}

private final class HostHEVCProductDigestStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HostHEVCProductSampleDigest] = []
    private var presentationTimes: [Double] = []

    func append(_ sample: HostHEVCEncodedSample) {
        lock.withLock {
            if values.count == 16 {
                values.removeFirst()
            }
            values.append(HostHEVCProductSampleDigest(sample: sample))
            let time = CMTimeGetSeconds(sample.presentationTimeStamp)
            if time.isFinite {
                if presentationTimes.count == 16 {
                    presentationTimes.removeFirst()
                }
                presentationTimes.append(time)
            }
        }
    }

    func reset() {
        lock.withLock {
            values.removeAll(keepingCapacity: true)
            presentationTimes.removeAll(keepingCapacity: true)
        }
    }
    func snapshot() -> [HostHEVCProductSampleDigest] { lock.withLock { values } }
    func encodedFPS() -> Double? {
        lock.withLock {
            guard presentationTimes.count >= 2,
                  let first = presentationTimes.first,
                  let last = presentationTimes.last,
                  last > first else { return nil }
            let fps = Double(presentationTimes.count - 1) / (last - first)
            return fps.isFinite && fps > 0 && fps <= 240 ? fps : nil
        }
    }
}

public enum HostHEVCProductSubmissionDisposition: String, Codable, Sendable,
    Equatable {
    case accepted
    case droppedBackpressure
    case staleSession
    case staleGeneration
    case inputStale
    case inputClockInvalid
    case pixelFormatUnsupported
    case dimensionMismatch
    case notSelected
    case notRunning
    case stopped
}

public struct HostHEVCProductSubmissionEvidence: Codable, Sendable,
    Equatable {
    public let selection: HostHEVCProductSelection
    public let disposition: HostHEVCProductSubmissionDisposition
    public let sessionID: String
    public let generation: UInt64
    public let sequence: UInt64
    public let inputPixelFormat: HostVideoInputPixelFormat?
    public let inputAgeSeconds: Double?
    public let sessionEvidence: HostHEVCOutputSubmissionEvidence?

    fileprivate init(selection: HostHEVCProductSelection,
                     disposition: HostHEVCProductSubmissionDisposition,
                     frame: HostVideoFrame,
                     inputAgeSeconds: Double? = nil,
                     sessionEvidence: HostHEVCOutputSubmissionEvidence? = nil) {
        self.selection = selection
        self.disposition = disposition
        self.sessionID = String(frame.sessionID.prefix(128))
        self.generation = frame.generation
        self.sequence = frame.sequence
        self.inputPixelFormat = frame.inputPixelFormat
        self.inputAgeSeconds = inputAgeSeconds
        self.sessionEvidence = sessionEvidence
    }
}

public enum HostHEVCProductOutputError: Error, LocalizedError, Sendable,
    Equatable {
    case invalidFreshnessWindow
    case invalidSessionID
    case invalidGeneration
    case hostHEVCSelectionRequired
    case outputAlreadyRunning
    case outputNotRunning
    case selectionChangeRequiresStop
    case staleSession
    case staleGeneration

    public var errorDescription: String? {
        switch self {
        case .invalidFreshnessWindow:
            "host HEVC product freshness window is invalid"
        case .invalidSessionID:
            "host HEVC product session ID must be non-empty"
        case .invalidGeneration:
            "host HEVC product generation must be greater than zero"
        case .hostHEVCSelectionRequired:
            "select host-hevc before starting the host encoder"
        case .outputAlreadyRunning:
            "host HEVC product output is already running"
        case .outputNotRunning:
            "host HEVC product output is not running"
        case .selectionChangeRequiresStop:
            "stop host HEVC output before changing product selection"
        case .staleSession:
            "host HEVC product session identity changed"
        case .staleGeneration:
            "host HEVC product generation changed"
        }
    }
}

/// Product-facing lifecycle owner for explicit Mac host HEVC output.
///
/// The service does not own `CaptureEngine`, change its output policy, open a
/// USB endpoint, or retain a frame queue of its own. `startHostHEVC` attaches
/// one caller sink to one bounded `HostHEVCOutputSession`; stop/cancel releases
/// that session and sink. A failed host encoder stays failed until the caller
/// explicitly stops or cancels it, so BGRA is never an implicit fallback.
public actor HostHEVCProductOutputService {
    public typealias BackendFactory = @Sendable () -> any HostHEVCEncoderBackend
    public typealias SampleSink = @Sendable (HostHEVCEncodedSample) -> Void

    public let configuration: HostVideoEncoderConfiguration
    public let maximumInputAgeSeconds: Double

    private let backendFactory: BackendFactory
    private var selection: HostHEVCProductSelection = .bgraPreview
    private var outputSession: HostHEVCOutputSession?
    private var lastSessionSnapshot: HostHEVCOutputSessionSnapshot?
    private let digestStore = HostHEVCProductDigestStore()
    private var fileConsumer: HostHEVCAnnexBFileConsumer?

    public init(
        configuration: HostVideoEncoderConfiguration,
        maximumInputAgeSeconds: Double = 1,
        backendFactory: @escaping BackendFactory
    ) throws {
        guard maximumInputAgeSeconds.isFinite,
              maximumInputAgeSeconds > 0,
              maximumInputAgeSeconds <= 5 else {
            throw HostHEVCProductOutputError.invalidFreshnessWindow
        }
        self.configuration = configuration
        self.maximumInputAgeSeconds = maximumInputAgeSeconds
        self.backendFactory = backendFactory
    }

    /// Product convenience initializer for the real Mac host encoder. Tests
    /// and alternate hosts should use the injectable initializer above.
    public init(
        configuration: HostVideoEncoderConfiguration,
        maximumInputAgeSeconds: Double = 1
    ) throws {
        try self.init(
            configuration: configuration,
            maximumInputAgeSeconds: maximumInputAgeSeconds,
            backendFactory: { VideoToolboxHostHEVCEncoderBackend() })
    }

    /// Selects a product mode without starting an encoder. Selecting
    /// `host-hevc` is explicit; it does not alter the existing BGRA capture or
    /// preview path until `startHostHEVC` is called.
    public func select(_ selection: HostHEVCProductSelection) async throws
        -> HostHEVCProductOutputStatus {
        if selection == self.selection {
            return await status()
        }
        if let outputSession {
            let snapshot = await outputSession.snapshot()
            guard snapshot.phase == .stopped || snapshot.phase == .cancelled else {
                throw HostHEVCProductOutputError.selectionChangeRequiresStop
            }
            lastSessionSnapshot = snapshot
            self.outputSession = nil
            fileConsumer = nil
        }
        self.selection = selection
        self.lastSessionSnapshot = nil
        digestStore.reset()
        return await status()
    }

    /// Starts one explicit host HEVC output session. The source capture path
    /// remains the caller's responsibility and can continue feeding BGRA
    /// preview at the same time.
    public func startHostHEVC(
        sessionID: String,
        generation: UInt64,
        sink: @escaping SampleSink,
        fileConfiguration: HostHEVCProductFileConfiguration? = nil
    ) async throws -> HostHEVCProductOutputStatus {
        guard selection == .hostHEVC else {
            throw HostHEVCProductOutputError.hostHEVCSelectionRequired
        }
        try validateIdentity(sessionID: sessionID, generation: generation)

        if let outputSession {
            let snapshot = await outputSession.snapshot()
            guard snapshot.phase == .stopped || snapshot.phase == .cancelled else {
                throw HostHEVCProductOutputError.outputAlreadyRunning
            }
            lastSessionSnapshot = snapshot
            self.outputSession = nil
        }

        digestStore.reset()
        let fileConsumer: HostHEVCAnnexBFileConsumer?
        if let fileConfiguration {
            fileConsumer = try HostHEVCAnnexBFileConsumer(
                configuration: fileConfiguration,
                sessionID: sessionID,
                generation: generation)
        } else {
            fileConsumer = nil
        }
        let digestStore = self.digestStore
        let downstreamSink: SampleSink = sink
        let combinedSink: SampleSink = { sample in
            digestStore.append(sample)
            _ = fileConsumer?.append(sample)
            downstreamSink(sample)
        }
        let session = try HostHEVCOutputSession(
            sessionID: sessionID,
            generation: generation,
            configuration: configuration,
            backend: backendFactory(),
            maximumInputAgeSeconds: maximumInputAgeSeconds,
            sink: combinedSink)
        self.outputSession = session
        self.fileConsumer = fileConsumer
        self.lastSessionSnapshot = nil
        return await status()
    }

    /// Submits a frame only when `host-hevc` was explicitly selected and
    /// started. The underlying session performs freshness, dimensions, and
    /// session/generation checks before its bounded encoder queue.
    public func submit(
        _ frame: HostVideoFrame,
        receivedUptime: Double,
        nowUptime: Double
    ) async -> HostHEVCProductSubmissionEvidence {
        guard selection == .hostHEVC else {
            return evidence(.notSelected, for: frame)
        }
        guard let outputSession else {
            let disposition: HostHEVCProductSubmissionDisposition =
                lastSessionSnapshot == nil ? .notRunning : .stopped
            return evidence(disposition, for: frame)
        }
        let sessionEvidence = await outputSession.submit(
            frame, receivedUptime: receivedUptime, nowUptime: nowUptime)
        return evidence(
            Self.map(sessionEvidence.disposition),
            for: frame,
            inputAgeSeconds: sessionEvidence.inputAgeSeconds,
            sessionEvidence: sessionEvidence)
    }

    /// Reconnects the host output only when the caller presents the exact
    /// identity that is currently active. The old session is fenced and its
    /// backend is reset by `HostHEVCOutputSession`.
    public func reconnect(
        expectedSessionID: String,
        expectedGeneration: UInt64,
        newSessionID: String,
        newGeneration: UInt64
    ) async throws -> HostHEVCProductOutputStatus {
        guard selection == .hostHEVC, let outputSession else {
            throw HostHEVCProductOutputError.outputNotRunning
        }
        try validateIdentity(sessionID: newSessionID, generation: newGeneration)
        let current = await outputSession.snapshot()
        guard current.sessionID == expectedSessionID else {
            throw HostHEVCProductOutputError.staleSession
        }
        guard current.generation == expectedGeneration else {
            throw HostHEVCProductOutputError.staleGeneration
        }
        guard current.phase == .running || current.phase == .failed else {
            throw HostHEVCProductOutputError.outputNotRunning
        }
        _ = await outputSession.reconnect(
            sessionID: newSessionID, generation: newGeneration)
        fileConsumer?.rebind(sessionID: newSessionID, generation: newGeneration)
        digestStore.reset()
        return await status()
    }

    /// Stops and releases the current bounded sink/session. The stopped
    /// snapshot remains available through `status()` for diagnostics.
    public func stop() async -> HostHEVCProductOutputStatus {
        guard let outputSession else { return await status() }
        let snapshot = await outputSession.stop()
        fileConsumer?.finish()
        lastSessionSnapshot = snapshot
        self.outputSession = nil
        return await status()
    }

    /// Cancels and releases the current bounded sink/session. Cancellation is
    /// observable in the returned status and never changes selection to BGRA.
    public func cancel() async -> HostHEVCProductOutputStatus {
        guard let outputSession else { return await status() }
        let snapshot = await outputSession.cancel()
        fileConsumer?.cancel()
        lastSessionSnapshot = snapshot
        self.outputSession = nil
        return await status()
    }

    public func status() async -> HostHEVCProductOutputStatus {
        if let outputSession {
            let snapshot = await outputSession.snapshot()
            return makeStatus(snapshot, sinkAttached: true)
        }
        return makeStatus(lastSessionSnapshot, sinkAttached: false)
    }

    private func makeStatus(
        _ snapshot: HostHEVCOutputSessionSnapshot?,
        sinkAttached: Bool
    ) -> HostHEVCProductOutputStatus {
        let fileSnapshot = fileConsumer?.snapshot()
        let consumer: HostHEVCProductConsumer = fileConsumer == nil
            ? .localSampleEvidence : .localAnnexBFile
        let phase: HostHEVCProductOutputPhase
        switch selection {
        case .bgraPreview:
            phase = .bgraPreview
        case .hostHEVC:
            guard let snapshot else {
                phase = .idle
                return HostHEVCProductOutputStatus(
                    selection: selection, phase: phase, session: nil,
                    sinkAttached: false, consumer: consumer,
                    encodedFPS: digestStore.encodedFPS(),
                    failureCode: nil,
                    samples: digestStore.snapshot(), file: fileSnapshot)
            }
            switch snapshot.phase {
            case .running: phase = .running
            case .reconnecting: phase = .reconnecting
            case .stopping: phase = .stopping
            case .stopped: phase = .stopped
            case .cancelled: phase = .cancelled
            case .failed: phase = .failed
            }
        }
        return HostHEVCProductOutputStatus(
            selection: selection, phase: phase, session: snapshot,
            sinkAttached: sinkAttached, consumer: consumer,
            encodedFPS: digestStore.encodedFPS(),
            failureCode: snapshot?.failureCode,
            samples: digestStore.snapshot(), file: fileSnapshot)
    }

    private func validateIdentity(sessionID: String, generation: UInt64) throws {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HostHEVCProductOutputError.invalidSessionID
        }
        guard generation > 0 else {
            throw HostHEVCProductOutputError.invalidGeneration
        }
    }

    private func evidence(
        _ disposition: HostHEVCProductSubmissionDisposition,
        for frame: HostVideoFrame,
        inputAgeSeconds: Double? = nil,
        sessionEvidence: HostHEVCOutputSubmissionEvidence? = nil
    ) -> HostHEVCProductSubmissionEvidence {
        HostHEVCProductSubmissionEvidence(
            selection: selection,
            disposition: disposition,
            frame: frame,
            inputAgeSeconds: inputAgeSeconds,
            sessionEvidence: sessionEvidence)
    }

    private static func map(
        _ disposition: HostHEVCOutputSubmissionDisposition
    ) -> HostHEVCProductSubmissionDisposition {
        switch disposition {
        case .accepted: return .accepted
        case .droppedBackpressure: return .droppedBackpressure
        case .staleSession: return .staleSession
        case .staleGeneration: return .staleGeneration
        case .inputStale: return .inputStale
        case .inputClockInvalid: return .inputClockInvalid
        case .pixelFormatUnsupported: return .pixelFormatUnsupported
        case .dimensionMismatch: return .dimensionMismatch
        case .stopped: return .stopped
        }
    }
}
