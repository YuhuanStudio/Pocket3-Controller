import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Provenance for the Mac-side compressed output path. This is deliberately
/// distinct from a UVC wire codec or a camera body recording setting.
public enum HostVideoEncodingTransport: String, Codable, Sendable, Equatable {
    case macVideoToolboxHost
}

public enum HostVideoInputPixelFormat: String, Codable, Sendable, Equatable {
    case bgra
    case nv12VideoRange
    case nv12FullRange

    fileprivate var pixelFormatType: OSType {
        switch self {
        case .bgra: return kCVPixelFormatType_32BGRA
        case .nv12VideoRange: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .nv12FullRange: return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }

    fileprivate init?(pixelBuffer: CVPixelBuffer) {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_32BGRA: self = .bgra
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: self = .nv12VideoRange
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: self = .nv12FullRange
        default: return nil
        }
    }
}

public struct HostVideoEncoderConfiguration: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let keyFrameInterval: Int
    public let averageBitRate: Int?
    public let maximumPendingFrames: Int

    public init(width: Int, height: Int, frameRate: Double = 30,
                keyFrameInterval: Int = 30, averageBitRate: Int? = nil,
                maximumPendingFrames: Int = 3) throws {
        guard width > 0, height > 0,
              frameRate.isFinite, frameRate > 0, frameRate <= 120,
              keyFrameInterval > 0, keyFrameInterval <= 600,
              averageBitRate.map({ $0 > 0 && $0 <= 500_000_000 }) ?? true,
              (1...16).contains(maximumPendingFrames) else {
            throw HostHEVCEncoderError.invalidConfiguration
        }
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.keyFrameInterval = keyFrameInterval
        self.averageBitRate = averageBitRate
        self.maximumPendingFrames = maximumPendingFrames
    }
}

/// A copied ownership envelope around one pixel buffer supplied by the
/// existing NV12/BGRA capture path. The encoder never retains a
/// `CMSampleBuffer` or an AVCapture callback object.
public struct HostVideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let sessionID: String
    public let generation: UInt64
    public let sequence: UInt64
    public let presentationTimeStamp: CMTime
    public let duration: CMTime

    public init(pixelBuffer: CVPixelBuffer, sessionID: String, generation: UInt64,
                sequence: UInt64, presentationTimeStamp: CMTime,
                duration: CMTime = .invalid) {
        self.pixelBuffer = pixelBuffer
        self.sessionID = String(sessionID.prefix(128))
        self.generation = generation
        self.sequence = sequence
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
    }

    public var inputPixelFormat: HostVideoInputPixelFormat? {
        HostVideoInputPixelFormat(pixelBuffer: pixelBuffer)
    }
}

public struct HostHEVCEncodedSample: @unchecked Sendable, Equatable {
    public let transport: HostVideoEncodingTransport
    public let codec: VideoToolboxCodec
    public let parameterSets: VideoToolboxParameterSetBundle
    public let accessUnit: Data
    public let dimensions: CMVideoDimensions
    public let presentationTimeStamp: CMTime
    public let duration: CMTime
    public let sessionID: String
    public let generation: UInt64
    public let sequence: UInt64
    public let isKeyFrame: Bool

    public init(
        transport: HostVideoEncodingTransport = .macVideoToolboxHost,
        codec: VideoToolboxCodec = .hevc,
        parameterSets: VideoToolboxParameterSetBundle,
        accessUnit: Data,
        dimensions: CMVideoDimensions,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        sessionID: String,
        generation: UInt64,
        sequence: UInt64,
        isKeyFrame: Bool
    ) throws {
        guard codec == .hevc, !accessUnit.isEmpty,
              dimensions.width > 0, dimensions.height > 0,
              parameterSets.codec == .hevc else {
            throw HostHEVCEncoderError.invalidEncodedSample
        }
        self.transport = transport
        self.codec = codec
        self.parameterSets = parameterSets
        self.accessUnit = Data(accessUnit)
        self.dimensions = dimensions
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
        self.sessionID = String(sessionID.prefix(128))
        self.generation = generation
        self.sequence = sequence
        self.isKeyFrame = isKeyFrame
    }

    /// Host encoding is intentionally never evidence about the USB wire
    /// codec. A later direct UVC path must provide its own COMMIT evidence.
    public var usbWireCodecClaim: String? { nil }
    public var isHostEncoded: Bool { transport == .macVideoToolboxHost }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.transport == rhs.transport && lhs.codec == rhs.codec &&
            lhs.parameterSets == rhs.parameterSets && lhs.accessUnit == rhs.accessUnit &&
            lhs.dimensions.width == rhs.dimensions.width &&
            lhs.dimensions.height == rhs.dimensions.height &&
            lhs.presentationTimeStamp == rhs.presentationTimeStamp &&
            lhs.duration == rhs.duration && lhs.sessionID == rhs.sessionID &&
            lhs.generation == rhs.generation && lhs.sequence == rhs.sequence &&
            lhs.isKeyFrame == rhs.isKeyFrame
    }
}

public enum HostHEVCEncoderError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration
    case invalidPixelBuffer
    case pixelFormatUnsupported
    case dimensionMismatch
    case backendUnavailable
    case videoToolbox(OSStatus)
    case adapter(String)
    case invalidEncodedSample
    case cancelled
    case staleSession
    case staleGeneration
    case stopped

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "host HEVC encoder configuration is invalid"
        case .invalidPixelBuffer: "host HEVC encoder received an invalid pixel buffer"
        case .pixelFormatUnsupported: "host HEVC encoder accepts only BGRA or NV12 pixel buffers"
        case .dimensionMismatch: "host HEVC encoder pixel dimensions do not match its configuration"
        case .backendUnavailable: "host HEVC VideoToolbox backend is unavailable"
        case .videoToolbox(let status): "host HEVC VideoToolbox operation failed: \(status)"
        case .adapter(let reason): "host HEVC sample adapter failed: " + reason
        case .invalidEncodedSample: "host HEVC backend returned an invalid encoded sample"
        case .cancelled: "host HEVC encoding was cancelled"
        case .staleSession: "host HEVC frame belongs to an older capture session"
        case .staleGeneration: "host HEVC frame belongs to an older capture generation"
        case .stopped: "host HEVC encoder is stopped"
        }
    }
}

public enum HostHEVCEncoderPhase: String, Codable, Sendable, Equatable {
    case running
    case stopping
    case stopped
    case failed
}

public enum HostHEVCSubmissionDisposition: String, Codable, Sendable,
    Equatable {
    case accepted
    case droppedBackpressure
    case staleSession
    case staleGeneration
    case stopped
}

public struct HostHEVCSubmissionEvidence: Codable, Sendable, Equatable {
    public let disposition: HostHEVCSubmissionDisposition
    public let sessionID: String
    public let generation: UInt64
    public let sequence: UInt64
    public let queueDepth: Int

    public init(disposition: HostHEVCSubmissionDisposition,
                sessionID: String, generation: UInt64, sequence: UInt64,
                queueDepth: Int) {
        self.disposition = disposition
        self.sessionID = String(sessionID.prefix(128))
        self.generation = generation
        self.sequence = sequence
        self.queueDepth = queueDepth
    }
}

public struct HostHEVCEncoderSnapshot: Codable, Sendable, Equatable {
    public let phase: HostHEVCEncoderPhase
    public let sessionID: String
    public let generation: UInt64
    public let pendingFrames: Int
    public let submittedFrames: Int
    public let encodedFrames: Int
    public let droppedBackpressure: Int
    public let droppedStaleOutput: Int
    public let cancelledFrames: Int
    public let failureCode: String?
}

/// Backend boundary used by the bounded actor and by synthetic tests.
/// Implementations return copied host-encoded samples; they never expose a
/// camera/USB transport claim.
public protocol HostHEVCEncoderBackend: Sendable {
    func encode(_ frame: HostVideoFrame,
                configuration: HostVideoEncoderConfiguration) async throws
        -> HostHEVCEncodedSample
    func finish() async
    func cancel() async
    func reset() async
}

/// Bounded, generation-fenced host encoder coordinator. Submissions are
/// accepted into a small queue and are dropped with typed evidence when the
/// queue is full; this avoids unbounded memory or hidden retry behavior.
public actor HostHEVCEncoder {
    public let configuration: HostVideoEncoderConfiguration
    public let sessionID: String
    public private(set) var generation: UInt64

    private let backend: any HostHEVCEncoderBackend
    private let output: @Sendable (HostHEVCEncodedSample) -> Void
    private var phase: HostHEVCEncoderPhase = .running
    private var pending: [HostVideoFrame] = []
    private var worker: Task<Void, Never>?
    private var submittedFrames = 0
    private var encodedFrames = 0
    private var droppedBackpressure = 0
    private var droppedStaleOutput = 0
    private var cancelledFrames = 0
    private var failureCode: String?

    public init(
        sessionID: String,
        generation: UInt64,
        configuration: HostVideoEncoderConfiguration,
        backend: any HostHEVCEncoderBackend,
        output: @escaping @Sendable (HostHEVCEncodedSample) -> Void = { _ in }
    ) {
        self.sessionID = String(sessionID.prefix(128))
        self.generation = generation
        self.configuration = configuration
        self.backend = backend
        self.output = output
    }

    public func snapshot() -> HostHEVCEncoderSnapshot {
        HostHEVCEncoderSnapshot(
            phase: phase, sessionID: sessionID, generation: generation,
            pendingFrames: pending.count, submittedFrames: submittedFrames,
            encodedFrames: encodedFrames,
            droppedBackpressure: droppedBackpressure,
            droppedStaleOutput: droppedStaleOutput,
            cancelledFrames: cancelledFrames, failureCode: failureCode)
    }

    public func submit(_ frame: HostVideoFrame)
        -> HostHEVCSubmissionEvidence {
        guard phase == .running else {
            return .init(disposition: .stopped, sessionID: frame.sessionID,
                         generation: frame.generation, sequence: frame.sequence,
                         queueDepth: pending.count)
        }
        guard frame.sessionID == sessionID else {
            return .init(disposition: .staleSession, sessionID: frame.sessionID,
                         generation: frame.generation, sequence: frame.sequence,
                         queueDepth: pending.count)
        }
        guard frame.generation == generation else {
            return .init(disposition: .staleGeneration, sessionID: frame.sessionID,
                         generation: frame.generation, sequence: frame.sequence,
                         queueDepth: pending.count)
        }
        guard pending.count < configuration.maximumPendingFrames else {
            droppedBackpressure += 1
            return .init(disposition: .droppedBackpressure,
                         sessionID: frame.sessionID, generation: frame.generation,
                         sequence: frame.sequence, queueDepth: pending.count)
        }
        pending.append(frame)
        submittedFrames += 1
        ensureWorker()
        return .init(disposition: .accepted, sessionID: frame.sessionID,
                     generation: frame.generation, sequence: frame.sequence,
                     queueDepth: pending.count)
    }

    /// Rebinds the coordinator to a new capture session/generation. Pending
    /// frames are discarded and any late backend output is fenced.
    public func reset(sessionID: String, generation: UInt64) async {
        phase = .stopping
        cancelledFrames += pending.count
        pending.removeAll(keepingCapacity: true)
        self.generation = generation
        // `sessionID` is immutable so a new coordinator is required when the
        // capture session identity changes. A mismatched reset is rejected by
        // retaining the original identity and publishing a failure code.
        if String(sessionID.prefix(128)) != self.sessionID {
            failureCode = "host_hevc_session_identity_changed"
            phase = .failed
            await backend.cancel()
            worker?.cancel()
            return
        }
        await backend.reset()
        phase = .running
        failureCode = nil
        ensureWorker()
    }

    /// Stops accepting frames, cancels queued work and invalidates the backend.
    /// In-flight output is still fenced by the phase/generation checks.
    public func stop() async -> HostHEVCEncoderSnapshot {
        guard phase == .running else { return snapshot() }
        phase = .stopping
        cancelledFrames += pending.count
        pending.removeAll(keepingCapacity: false)
        worker?.cancel()
        await backend.cancel()
        phase = .stopped
        return snapshot()
    }

    private func ensureWorker() {
        guard worker == nil, !pending.isEmpty, phase == .running else { return }
        worker = Task { [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        while !Task.isCancelled {
            guard let frame = dequeue() else { break }
            do {
                let encoded = try await backend.encode(
                    frame, configuration: configuration)
                record(encoded, for: frame)
            } catch is CancellationError {
                cancelledFrames += 1
            } catch let error as HostHEVCEncoderError {
                if case .cancelled = error {
                    cancelledFrames += 1
                } else {
                    phase = .failed
                    failureCode = Self.errorCode(error)
                }
            } catch {
                phase = .failed
                failureCode = String(String(describing: error).prefix(128))
            }
        }
        worker = nil
    }

    private func dequeue() -> HostVideoFrame? {
        guard phase == .running, !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    private func record(_ encoded: HostHEVCEncodedSample,
                        for frame: HostVideoFrame) {
        guard phase == .running,
              frame.sessionID == sessionID,
              frame.generation == generation,
              encoded.sessionID == sessionID,
              encoded.generation == generation,
              encoded.sequence == frame.sequence else {
            droppedStaleOutput += 1
            return
        }
        encodedFrames += 1
        output(encoded)
    }

    private static func errorCode(_ error: HostHEVCEncoderError) -> String {
        switch error {
        case .invalidConfiguration: "host_hevc_invalid_configuration"
        case .invalidPixelBuffer: "host_hevc_invalid_pixel_buffer"
        case .pixelFormatUnsupported: "host_hevc_pixel_format_unsupported"
        case .dimensionMismatch: "host_hevc_dimension_mismatch"
        case .backendUnavailable: "host_hevc_backend_unavailable"
        case .videoToolbox(let status): "host_hevc_videotoolbox_" + String(status)
        case .adapter(let reason): "host_hevc_adapter_" + reason
        case .invalidEncodedSample: "host_hevc_invalid_encoded_sample"
        case .cancelled: "host_hevc_cancelled"
        case .staleSession: "host_hevc_stale_session"
        case .staleGeneration: "host_hevc_stale_generation"
        case .stopped: "host_hevc_stopped"
        }
    }
}

/// Converts one VideoToolbox `hvc1` callback sample into copied HEVC bytes and
/// parameter sets. The result is explicitly host encoded and has no USB wire
/// codec assertion.
public enum HostHEVCEncodedSampleAdapter {
    public static func extract(
        _ sample: CMSampleBuffer,
        frame: HostVideoFrame,
        limits: VideoToolboxDecoderLimits = .default
    ) throws -> HostHEVCEncodedSample {
        let input: AVC1CompressedSample
        do {
            input = try HEVC1SampleAdapter.extract(sample, limits: limits)
        } catch let error as AVC1SampleAdapterError {
            throw HostHEVCEncoderError.adapter(String(describing: error))
        }
        guard input.dimensions.width == Int32(CVPixelBufferGetWidth(frame.pixelBuffer)),
              input.dimensions.height == Int32(CVPixelBufferGetHeight(frame.pixelBuffer)) else {
            throw HostHEVCEncoderError.dimensionMismatch
        }
        return try HostHEVCEncodedSample(
            parameterSets: input.parameterSets,
            accessUnit: input.accessUnit,
            dimensions: input.dimensions,
            presentationTimeStamp: input.presentationTimeStamp,
            duration: input.duration,
            sessionID: frame.sessionID,
            generation: frame.generation,
            sequence: frame.sequence,
            isKeyFrame: Self.isKeyFrame(sample))
    }

    private static func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }
}

/// Production host HEVC backend. It only accepts copied pixel-buffer input;
/// `VTCompressionSession` output is adapted immediately while the callback's
/// sample buffer is valid. Construction is lazy and performs no I/O.
public final class VideoToolboxHostHEVCEncoderBackend: @unchecked Sendable,
    HostHEVCEncoderBackend {
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var activeWaiter: HostHEVCEncodeWaiter?
    private var invalidated = false

    public init() {}

    public func encode(_ frame: HostVideoFrame,
                       configuration: HostVideoEncoderConfiguration) async throws
        -> HostHEVCEncodedSample {
        try Task.checkCancellation()
        guard frame.inputPixelFormat != nil else {
            throw HostHEVCEncoderError.pixelFormatUnsupported
        }
        guard CVPixelBufferGetWidth(frame.pixelBuffer) == configuration.width,
              CVPixelBufferGetHeight(frame.pixelBuffer) == configuration.height else {
            throw HostHEVCEncoderError.dimensionMismatch
        }

        let encoder = try ensureSession(configuration: configuration)
        let waiter = HostHEVCEncodeWaiter(frame: frame)
        lock.withLock { activeWaiter = waiter }
        let refcon = Unmanaged.passRetained(waiter).toOpaque()
        let status = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: frame.pixelBuffer,
            presentationTimeStamp: frame.presentationTimeStamp,
            duration: frame.duration,
            frameProperties: nil, sourceFrameRefcon: refcon,
            infoFlagsOut: nil)
        if status != noErr {
            Unmanaged<HostHEVCEncodeWaiter>.fromOpaque(refcon).release()
            lock.withLock { activeWaiter = nil }
            throw HostHEVCEncoderError.videoToolbox(status)
        }
        let result: HostHEVCEncodedSample
        do {
            result = try await waiter.wait()
        } catch is CancellationError {
            throw HostHEVCEncoderError.cancelled
        } catch let error as HostHEVCEncoderError {
            throw error
        } catch {
            throw HostHEVCEncoderError.adapter(
                String(String(describing: error).prefix(128)))
        }
        lock.withLock { activeWaiter = nil }
        return result
    }

    public func finish() async {
        let encoder = lock.withLock { () -> VTCompressionSession? in
            let value = session
            session = nil
            invalidated = true
            return value
        }
        guard let encoder else { return }
        VTCompressionSessionCompleteFrames(encoder,
                                            untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(encoder)
    }

    public func cancel() async {
        let (encoder, waiter) = lock.withLock { () -> (VTCompressionSession?, HostHEVCEncodeWaiter?) in
            let values = (session, activeWaiter)
            session = nil
            activeWaiter = nil
            invalidated = true
            return values
        }
        waiter?.cancel()
        if let encoder { VTCompressionSessionInvalidate(encoder) }
    }

    public func reset() async {
        await cancel()
        lock.withLock { invalidated = false }
    }

    private func ensureSession(configuration: HostVideoEncoderConfiguration)
        throws -> VTCompressionSession {
        try lock.withLock {
            guard !invalidated else {
                throw HostHEVCEncoderError.stopped
            }
            if let session { return session }
            var created: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(configuration.width),
                height: Int32(configuration.height), codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: nil, imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: hostHEVCCompressionCallback,
                refcon: nil, compressionSessionOut: &created)
            guard status == noErr, let created else {
                throw status == noErr
                    ? HostHEVCEncoderError.backendUnavailable
                    : HostHEVCEncoderError.videoToolbox(status)
            }
            let realTimeStatus = VTSessionSetProperty(
                created, key: kVTCompressionPropertyKey_RealTime,
                value: kCFBooleanTrue)
            guard realTimeStatus == noErr else {
                VTCompressionSessionInvalidate(created)
                throw HostHEVCEncoderError.videoToolbox(realTimeStatus)
            }
            let reorderStatus = VTSessionSetProperty(
                created, key: kVTCompressionPropertyKey_AllowFrameReordering,
                value: kCFBooleanFalse)
            guard reorderStatus == noErr else {
                VTCompressionSessionInvalidate(created)
                throw HostHEVCEncoderError.videoToolbox(reorderStatus)
            }
            let keyIntervalStatus = VTSessionSetProperty(
                created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: configuration.keyFrameInterval as CFTypeRef)
            guard keyIntervalStatus == noErr else {
                VTCompressionSessionInvalidate(created)
                throw HostHEVCEncoderError.videoToolbox(keyIntervalStatus)
            }
            if let bitRate = configuration.averageBitRate {
                let bitRateStatus = VTSessionSetProperty(
                    created, key: kVTCompressionPropertyKey_AverageBitRate,
                    value: bitRate as CFTypeRef)
                guard bitRateStatus == noErr else {
                    VTCompressionSessionInvalidate(created)
                    throw HostHEVCEncoderError.videoToolbox(bitRateStatus)
                }
            }
            let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(created)
            guard prepareStatus == noErr else {
                VTCompressionSessionInvalidate(created)
                throw HostHEVCEncoderError.videoToolbox(prepareStatus)
            }
            session = created
            return created
        }
    }
}

private final class HostHEVCEncodeWaiter: @unchecked Sendable {
    private let frame: HostVideoFrame
    private let lock = NSLock()
    private var result: Result<HostHEVCEncodedSample, Error>?
    private var continuation: CheckedContinuation<HostHEVCEncodedSample, Error>?

    init(frame: HostVideoFrame) { self.frame = frame }

    func receive(status: OSStatus, sample: CMSampleBuffer?) {
        let result: Result<HostHEVCEncodedSample, Error>
        if status != noErr {
            result = .failure(HostHEVCEncoderError.videoToolbox(status))
        } else if let sample {
            do {
                result = .success(try HostHEVCEncodedSampleAdapter.extract(
                    sample, frame: frame))
            } catch {
                result = .failure(error)
            }
        } else {
            result = .failure(HostHEVCEncoderError.backendUnavailable)
        }
        let continuation = lock.withLock { () -> CheckedContinuation<HostHEVCEncodedSample, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume(with: result)
    }

    func wait() async throws -> HostHEVCEncodedSample {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> Result<HostHEVCEncodedSample, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    func cancel() {
        receive(status: kVTInvalidSessionErr, sample: nil)
    }
}

private let hostHEVCCompressionCallback: VTCompressionOutputCallback = {
    _, sourceFrameRefcon, status, _, sampleBuffer in
    guard let sourceFrameRefcon else { return }
    let waiter = Unmanaged<HostHEVCEncodeWaiter>.fromOpaque(sourceFrameRefcon)
        .takeRetainedValue()
    waiter.receive(status: status, sample: sampleBuffer)
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

public typealias HostH265Encoder = HostHEVCEncoder
public typealias VideoToolboxHostH265EncoderBackend = VideoToolboxHostHEVCEncoderBackend
