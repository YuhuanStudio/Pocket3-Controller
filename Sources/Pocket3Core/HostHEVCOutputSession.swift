import CoreMedia
import CoreVideo
import Foundation

public enum HostHEVCOutputSessionPhase: String, Codable, Sendable,
    Equatable {
    case running
    case reconnecting
    case stopping
    case stopped
    case cancelled
    case failed
}

public struct HostHEVCOutputCapabilityReport: Codable, Sendable, Equatable {
    public let transport: HostVideoEncodingTransport
    public let codec: VideoToolboxCodec
    public let codecIdentifier: String
    public let inputPixelFormats: [HostVideoInputPixelFormat]
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let sessionID: String
    public let generation: UInt64
    public let configured: Bool
    public let observedSampleCount: Int
    public let verified: Bool
    public let usbWireCodecClaim: String?

    public init(
        transport: HostVideoEncodingTransport = .macVideoToolboxHost,
        codec: VideoToolboxCodec = .hevc,
        codecIdentifier: String = "hvc1",
        inputPixelFormats: [HostVideoInputPixelFormat] = [
            .bgra, .nv12VideoRange, .nv12FullRange
        ],
        width: Int,
        height: Int,
        frameRate: Double,
        sessionID: String,
        generation: UInt64,
        configured: Bool = true,
        observedSampleCount: Int = 0,
        usbWireCodecClaim: String? = nil
    ) {
        self.transport = transport
        self.codec = codec
        self.codecIdentifier = String(codecIdentifier.prefix(16))
        self.inputPixelFormats = Array(inputPixelFormats.prefix(3))
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.sessionID = String(sessionID.prefix(128))
        self.generation = generation
        self.configured = configured
        self.observedSampleCount = max(0, observedSampleCount)
        self.verified = configured && observedSampleCount > 0
        self.usbWireCodecClaim = usbWireCodecClaim
    }
}

public enum HostHEVCOutputSubmissionDisposition: String, Codable, Sendable,
    Equatable {
    case accepted
    case droppedBackpressure
    case staleSession
    case staleGeneration
    case inputStale
    case inputClockInvalid
    case pixelFormatUnsupported
    case dimensionMismatch
    case stopped
}

public struct HostHEVCOutputSubmissionEvidence: Codable, Sendable,
    Equatable {
    public let disposition: HostHEVCOutputSubmissionDisposition
    public let sessionID: String
    public let generation: UInt64
    public let sequence: UInt64
    public let inputPixelFormat: HostVideoInputPixelFormat?
    public let inputAgeSeconds: Double?
    public let encoder: HostHEVCSubmissionEvidence?

    public init(
        disposition: HostHEVCOutputSubmissionDisposition,
        sessionID: String,
        generation: UInt64,
        sequence: UInt64,
        inputPixelFormat: HostVideoInputPixelFormat? = nil,
        inputAgeSeconds: Double? = nil,
        encoder: HostHEVCSubmissionEvidence? = nil
    ) {
        self.disposition = disposition
        self.sessionID = String(sessionID.prefix(128))
        self.generation = generation
        self.sequence = sequence
        self.inputPixelFormat = inputPixelFormat
        self.inputAgeSeconds = inputAgeSeconds
        self.encoder = encoder
    }
}

public struct HostHEVCOutputSessionSnapshot: Codable, Sendable,
    Equatable {
    public let phase: HostHEVCOutputSessionPhase
    public let sessionID: String
    public let generation: UInt64
    public let capability: HostHEVCOutputCapabilityReport
    public let encoder: HostHEVCEncoderSnapshot
    public let maximumInputAgeSeconds: Double
    public let lastInputUptime: Double?
    public let lastOutputSequence: UInt64?
    public let failureCode: String?
}

public enum HostHEVCOutputSessionError: Error, LocalizedError, Sendable,
    Equatable {
    case invalidFreshnessWindow
    case invalidSessionID

    public var errorDescription: String? {
        switch self {
        case .invalidFreshnessWindow:
            "host HEVC output freshness window is invalid"
        case .invalidSessionID:
            "host HEVC output session ID must be non-empty"
        }
    }
}

private final class HostHEVCOutputRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let sessionID: String
    private let generation: UInt64
    private var sampleCount = 0
    private var lastSequence: UInt64?
    private let sink: @Sendable (HostHEVCEncodedSample) -> Void

    init(sessionID: String, generation: UInt64,
         sink: @escaping @Sendable (HostHEVCEncodedSample) -> Void) {
        self.sessionID = sessionID
        self.generation = generation
        self.sink = sink
    }

    func receive(_ sample: HostHEVCEncodedSample) {
        guard sample.sessionID == sessionID, sample.generation == generation else {
            return
        }
        lock.withLock {
            sampleCount += 1
            lastSequence = sample.sequence
        }
        // The sample owns copied bytes. The sink is outside this relay's lock
        // so a slow caller cannot block diagnostic state reads indefinitely.
        sink(sample)
    }

    func snapshot() -> (count: Int, lastSequence: UInt64?) {
        lock.withLock { (sampleCount, lastSequence) }
    }
}

/// Session/service seam for feeding fresh frames from the existing
/// AVFoundation NV12/BGRA path into the bounded host encoder. It owns no
/// camera session and has no USB/direct-UVC side effects.
public actor HostHEVCOutputSession {
    public let configuration: HostVideoEncoderConfiguration
    public let maximumInputAgeSeconds: Double

    private let backend: any HostHEVCEncoderBackend
    private let sink: @Sendable (HostHEVCEncodedSample) -> Void
    private var relay: HostHEVCOutputRelay
    private var encoder: HostHEVCEncoder
    private var phase: HostHEVCOutputSessionPhase = .running
    private var sessionID: String
    private var generation: UInt64
    private var lastInputUptime: Double?
    private var failureCode: String?

    public init(
        sessionID: String,
        generation: UInt64,
        configuration: HostVideoEncoderConfiguration,
        backend: any HostHEVCEncoderBackend,
        maximumInputAgeSeconds: Double = 1,
        sink: @escaping @Sendable (HostHEVCEncodedSample) -> Void = { _ in }
    ) throws {
        let sessionID = String(sessionID.prefix(128))
        guard !sessionID.isEmpty else {
            throw HostHEVCOutputSessionError.invalidSessionID
        }
        guard maximumInputAgeSeconds.isFinite,
              maximumInputAgeSeconds > 0,
              maximumInputAgeSeconds <= 5 else {
            throw HostHEVCOutputSessionError.invalidFreshnessWindow
        }
        self.configuration = configuration
        self.maximumInputAgeSeconds = maximumInputAgeSeconds
        self.backend = backend
        self.sink = sink
        self.sessionID = sessionID
        self.generation = generation
        let relay = HostHEVCOutputRelay(
            sessionID: sessionID, generation: generation, sink: sink)
        self.relay = relay
        self.encoder = HostHEVCEncoder(
            sessionID: sessionID, generation: generation,
            configuration: configuration, backend: backend,
            output: relay.receive)
    }

    public func snapshot() async -> HostHEVCOutputSessionSnapshot {
        let encoderSnapshot = await encoder.snapshot()
        let relaySnapshot = relay.snapshot()
        let effectivePhase: HostHEVCOutputSessionPhase
        if phase == .running && encoderSnapshot.phase == .failed {
            effectivePhase = .failed
        } else {
            effectivePhase = phase
        }
        let capability = HostHEVCOutputCapabilityReport(
            width: configuration.width, height: configuration.height,
            frameRate: configuration.frameRate,
            sessionID: sessionID, generation: generation,
            observedSampleCount: relaySnapshot.count)
        return HostHEVCOutputSessionSnapshot(
            phase: effectivePhase, sessionID: sessionID,
            generation: generation, capability: capability,
            encoder: encoderSnapshot,
            maximumInputAgeSeconds: maximumInputAgeSeconds,
            lastInputUptime: lastInputUptime,
            lastOutputSequence: relaySnapshot.lastSequence,
            failureCode: failureCode ?? encoderSnapshot.failureCode)
    }

    /// Submit one frame with an explicit monotonic receive timestamp. The
    /// caller's timestamp is required so stale callback buffers cannot enter
    /// the host encoder after a reconnect.
    public func submit(
        _ frame: HostVideoFrame,
        receivedUptime: Double,
        nowUptime: Double
    ) async -> HostHEVCOutputSubmissionEvidence {
        let format = frame.inputPixelFormat
        guard phase == .running else {
            return evidence(.stopped, for: frame, format: format)
        }
        guard frame.sessionID == sessionID else {
            return evidence(.staleSession, for: frame, format: format)
        }
        guard frame.generation == generation else {
            return evidence(.staleGeneration, for: frame, format: format)
        }
        guard receivedUptime.isFinite, nowUptime.isFinite,
              receivedUptime >= 0, nowUptime >= receivedUptime else {
            return evidence(.inputClockInvalid, for: frame, format: format)
        }
        let age = nowUptime - receivedUptime
        guard age <= maximumInputAgeSeconds else {
            return evidence(.inputStale, for: frame, format: format, age: age)
        }
        guard format != nil else {
            return evidence(.pixelFormatUnsupported, for: frame, format: nil,
                            age: age)
        }
        guard CVPixelBufferGetWidth(frame.pixelBuffer) == configuration.width,
              CVPixelBufferGetHeight(frame.pixelBuffer) == configuration.height else {
            return evidence(.dimensionMismatch, for: frame, format: format,
                            age: age)
        }
        lastInputUptime = receivedUptime
        let encoderEvidence = await encoder.submit(frame)
        if (await encoder.snapshot()).phase == .failed {
            phase = .failed
        }
        let disposition: HostHEVCOutputSubmissionDisposition
        switch encoderEvidence.disposition {
        case .accepted: disposition = .accepted
        case .droppedBackpressure: disposition = .droppedBackpressure
        case .staleSession: disposition = .staleSession
        case .staleGeneration: disposition = .staleGeneration
        case .stopped: disposition = .stopped
        }
        return evidence(disposition, for: frame, format: format,
                        age: age, encoder: encoderEvidence)
    }

    /// Replaces the source session/generation. The old encoder is stopped,
    /// its pending/in-flight output is fenced, and the backend is reset before
    /// the new source is accepted.
    public func reconnect(sessionID: String, generation: UInt64) async
        -> HostHEVCOutputSessionSnapshot {
        phase = .reconnecting
        let stopped = await encoder.stop()
        if stopped.phase == .failed { await backend.cancel() }
        await backend.reset()
        self.sessionID = String(sessionID.prefix(128))
        self.generation = generation
        self.relay = HostHEVCOutputRelay(
            sessionID: self.sessionID, generation: generation, sink: sink)
        self.encoder = HostHEVCEncoder(
            sessionID: self.sessionID, generation: generation,
            configuration: configuration, backend: backend,
            output: relay.receive)
        self.lastInputUptime = nil
        self.failureCode = nil
        self.phase = self.sessionID.isEmpty ? .failed : .running
        if self.sessionID.isEmpty { self.failureCode = "host_hevc_session_identity_changed" }
        return await snapshot()
    }

    public func stop() async -> HostHEVCOutputSessionSnapshot {
        guard phase == .running || phase == .failed else {
            return await snapshot()
        }
        phase = .stopping
        let result = await encoder.stop()
        if result.phase == .failed { await backend.cancel() }
        phase = .stopped
        failureCode = result.failureCode
        return await snapshot()
    }

    public func cancel() async -> HostHEVCOutputSessionSnapshot {
        guard phase == .running || phase == .failed else {
            return await snapshot()
        }
        phase = .stopping
        let result = await encoder.stop()
        if result.phase == .failed { await backend.cancel() }
        phase = .cancelled
        failureCode = result.failureCode ?? "cancelled"
        return await snapshot()
    }

    private func evidence(
        _ disposition: HostHEVCOutputSubmissionDisposition,
        for frame: HostVideoFrame,
        format: HostVideoInputPixelFormat?,
        age: Double? = nil,
        encoder: HostHEVCSubmissionEvidence? = nil
    ) -> HostHEVCOutputSubmissionEvidence {
        HostHEVCOutputSubmissionEvidence(
            disposition: disposition, sessionID: frame.sessionID,
            generation: frame.generation, sequence: frame.sequence,
            inputPixelFormat: format, inputAgeSeconds: age,
            encoder: encoder)
    }
}

public typealias HostH265OutputSession = HostHEVCOutputSession
