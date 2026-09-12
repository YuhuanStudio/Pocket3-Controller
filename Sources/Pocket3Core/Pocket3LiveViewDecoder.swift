import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// An attachment token for the optional, receive-only type-02 live-view sink.
/// A token is bound to one datalink generation; a token from an older
/// connection cannot detach or receive traffic from a newer one.
public struct Pocket3DatalinkLiveViewSinkToken: Codable, Sendable,
    Equatable, Hashable {
    public let id: UUID
    public let generation: UInt64

    public init(id: UUID = UUID(), generation: UInt64) {
        self.id = id
        self.generation = generation
    }
}

public typealias Pocket3LiveViewSinkToken = Pocket3DatalinkLiveViewSinkToken

/// A passive datalink consumer.  Implementations are called only for an
/// already admitted DJI UDP pktType-02 datagram.  The protocol has no send,
/// enable, Wi-Fi, or command operation by design.
public protocol Pocket3DatalinkLiveViewSink: AnyObject, Sendable {
    func attach(generation: UInt64)
    func receive(_ datagram: DJIUDPDatagram, generation: UInt64)
    func flush(generation: UInt64)
}

public extension Pocket3DatalinkLiveViewSink {
    /// Simple test sinks may not need an activation callback.  The concrete
    /// media sink overrides this to reset its assembler fence.
    func attach(generation _: UInt64) {}
}

/// Errors returned by the bounded live-view decoder service before or around
/// a decoder adapter call.  Readiness is kept separate from successful
/// VideoToolbox output; a parameter-set/IDR gate never claims a decoded frame.
public enum Pocket3LiveViewDecoderError: Error, Sendable, Equatable {
    case invalidGeneration
    case invalidLimits
    case notReady
    case invalidInput
    case backpressure
    case staleGeneration(expected: UInt64, actual: UInt64)
    case terminated
    case underlying(String)
}

/// Bounds for the adapter queue and its retained typed evidence.
public struct Pocket3LiveViewDecodeServiceLimits: Codable, Sendable,
    Equatable {
    public static let defaultMaximumPendingMessages = 4
    public static let defaultMaximumEvidence = 16

    public let maximumPendingMessages: Int
    public let maximumEvidence: Int

    public static let `default` = Self()

    public init(
        maximumPendingMessages: Int = Self.defaultMaximumPendingMessages,
        maximumEvidence: Int = Self.defaultMaximumEvidence
    ) {
        self.maximumPendingMessages = maximumPendingMessages
        self.maximumEvidence = maximumEvidence
    }

    fileprivate var isValid: Bool {
        maximumPendingMessages > 0 && maximumEvidence > 0
    }
}

public typealias Pocket3LiveViewDecodeLimits = Pocket3LiveViewDecodeServiceLimits

/// The immutable input passed to a decoder adapter.  Parameter sets are raw
/// NAL units without Annex-B start codes; normalizedData uses the existing
/// four-byte big-endian length-prefixed contract.
public struct Pocket3LiveViewDecodeRequest: Sendable, Equatable {
    public static let maximumParameterSetCount = 3
    public static let maximumParameterSetBytes = 512 * 1024
    public static let maximumAccessUnitBytes = 8 * 1024 * 1024

    public let sessionID: UInt16
    public let generation: UInt64
    public let messageID: UInt64
    public let codec: VideoToolboxCodec
    public let normalizedData: Data
    public let parameterSets: [Data]
    public let parameterSetsChanged: Bool
    public let timestampCounter: UInt32

    public init(message: Pocket3LiveViewMediaMessage) throws {
        guard message.generation != 0,
              message.isDecoderReady,
              message.videoToolboxInputValidated,
              let codec = message.codec,
              let normalizedData = message.normalizedData,
              !normalizedData.isEmpty,
              normalizedData.count <= Self.maximumAccessUnitBytes,
              !message.parameterSets.isEmpty,
              message.parameterSets.count <= Self.maximumParameterSetCount,
              message.parameterSets.reduce(0, { $0 + $1.count }) <= Self.maximumParameterSetBytes else {
            throw Pocket3LiveViewDecoderError.notReady
        }
        self.sessionID = message.sessionID
        self.generation = message.generation
        self.messageID = message.messageID
        self.codec = codec
        self.normalizedData = Data(normalizedData)
        self.parameterSets = message.parameterSets.map(Data.init)
        self.parameterSetsChanged = message.parameterSetsChanged
        self.timestampCounter = message.timestampCounter
    }

    /// A bounded, explicit constructor for fake adapters and tests.  The
    /// production path should prefer ``init(message:)`` so the readiness and
    /// VideoToolbox-input gates are enforced together.
    public init(
        sessionID: UInt16,
        generation: UInt64,
        messageID: UInt64,
        codec: VideoToolboxCodec,
        normalizedData: Data,
        parameterSets: [Data],
        parameterSetsChanged: Bool = false,
        timestampCounter: UInt32 = 0
    ) throws {
        guard generation != 0,
              !normalizedData.isEmpty,
              normalizedData.count <= Self.maximumAccessUnitBytes,
              !parameterSets.isEmpty,
              parameterSets.count <= Self.maximumParameterSetCount,
              parameterSets.reduce(0, { $0 + $1.count }) <= Self.maximumParameterSetBytes else {
            throw Pocket3LiveViewDecoderError.invalidInput
        }
        self.sessionID = sessionID
        self.generation = generation
        self.messageID = messageID
        self.codec = codec
        self.normalizedData = Data(normalizedData)
        self.parameterSets = parameterSets.map(Data.init)
        self.parameterSetsChanged = parameterSetsChanged
        self.timestampCounter = timestampCounter
    }
}

/// A decoder adapter returns only bounded output metadata plus an optional
/// pixel buffer.  The service turns it into generation-fenced evidence.
public struct Pocket3LiveViewDecodedFrame: @unchecked Sendable {
    public let status: Int32
    public let infoFlagsRawValue: UInt32
    public let pixelBuffer: CVPixelBuffer?
    public let frameWasDropped: Bool
    public let parameterSetRebuilt: Bool

    public var didProducePixelBuffer: Bool { pixelBuffer != nil }

    public init(
        status: Int32 = 0,
        infoFlagsRawValue: UInt32 = 0,
        pixelBuffer: CVPixelBuffer? = nil,
        frameWasDropped: Bool = false,
        parameterSetRebuilt: Bool = false
    ) {
        self.status = status
        self.infoFlagsRawValue = infoFlagsRawValue
        self.pixelBuffer = pixelBuffer
        self.frameWasDropped = frameWasDropped
        self.parameterSetRebuilt = parameterSetRebuilt
    }
}

/// A synchronous adapter boundary.  The media sink and service own all
/// bounded queueing and generation checks; an adapter only decodes one
/// already validated access unit or resets its own codec session.
public protocol Pocket3LiveViewDecoder: AnyObject, Sendable {
    func decode(_ request: Pocket3LiveViewDecodeRequest) throws
        -> Pocket3LiveViewDecodedFrame
    func reset(generation: UInt64)
}

public typealias Pocket3LiveViewDecoderAdapter = Pocket3LiveViewDecoder

public enum Pocket3LiveViewDecodeDisposition: String, Codable, Sendable,
    Equatable {
    case queued
    case skippedNotReady
    case droppedBackpressure
    case droppedStaleGeneration
    case decoded
    case frameDropped
    case failed
    case terminated
}

/// Typed evidence for one media message.  `decoded` is emitted only after the
/// adapter returned; `queued` means it was accepted by the bounded service and
/// is not a claim that VideoToolbox produced output.
public struct Pocket3LiveViewDecodeEvidence: Codable, Sendable, Equatable {
    public let sessionID: UInt16
    public let generation: UInt64
    public let messageID: UInt64
    public let codec: VideoToolboxCodec?
    public let disposition: Pocket3LiveViewDecodeDisposition
    public let decoderSubmitted: Bool
    public let didProduceFrame: Bool
    public let frameWasDropped: Bool
    public let parameterSetRebuilt: Bool
    public let status: Int32?
    public let errorCode: String?

    public init(
        sessionID: UInt16,
        generation: UInt64,
        messageID: UInt64,
        codec: VideoToolboxCodec?,
        disposition: Pocket3LiveViewDecodeDisposition,
        decoderSubmitted: Bool = false,
        didProduceFrame: Bool = false,
        frameWasDropped: Bool = false,
        parameterSetRebuilt: Bool = false,
        status: Int32? = nil,
        errorCode: String? = nil
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.messageID = messageID
        self.codec = codec
        self.disposition = disposition
        self.decoderSubmitted = decoderSubmitted
        self.didProduceFrame = didProduceFrame
        self.frameWasDropped = frameWasDropped
        self.parameterSetRebuilt = parameterSetRebuilt
        self.status = status
        self.errorCode = errorCode.map { String($0.prefix(128)) }
    }
}

public struct Pocket3LiveViewDecodeServiceStatistics: Codable, Sendable,
    Equatable {
    public let acceptedCount: UInt64
    public let skippedNotReadyCount: UInt64
    public let queueDropCount: UInt64
    public let staleGenerationCount: UInt64
    public let decodeSuccessCount: UInt64
    public let frameDropCount: UInt64
    public let decodeFailureCount: UInt64
    public let terminatedCount: UInt64
    public let flushedCount: UInt64
    public let pendingMessageCount: Int
    public let evidenceCount: Int
}

/// Bounded, serial decoder service.  It never sends a live-view command and
/// never opens a transport.  A generation reset clears queued work and fences
/// output from a decoder call that was already in flight.
public final class Pocket3LiveViewDecodeService: @unchecked Sendable {
    public let limits: Pocket3LiveViewDecodeServiceLimits

    private let decoder: any Pocket3LiveViewDecoder
    private let lock = NSLock()
    private let decoderLock = NSLock()
    private let workerQueue: DispatchQueue
    private var generation: UInt64
    private var pending: [Pocket3LiveViewDecodeRequest] = []
    private var evidence: [Pocket3LiveViewDecodeEvidence] = []
    private var workerRunning = false
    private var terminated = false

    private var acceptedCount: UInt64 = 0
    private var skippedNotReadyCount: UInt64 = 0
    private var queueDropCount: UInt64 = 0
    private var staleGenerationCount: UInt64 = 0
    private var decodeSuccessCount: UInt64 = 0
    private var frameDropCount: UInt64 = 0
    private var decodeFailureCount: UInt64 = 0
    private var terminatedCount: UInt64 = 0
    private var flushedCount: UInt64 = 0

    public init(
        decoder: any Pocket3LiveViewDecoder,
        generation: UInt64 = 1,
        limits: Pocket3LiveViewDecodeServiceLimits = .default,
        queue: DispatchQueue? = nil
    ) throws {
        guard generation != 0 else {
            throw Pocket3LiveViewDecoderError.invalidGeneration
        }
        guard limits.isValid else {
            throw Pocket3LiveViewDecoderError.invalidLimits
        }
        self.decoder = decoder
        self.generation = generation
        self.limits = limits
        self.workerQueue = queue ?? DispatchQueue(
            label: "studio.yuhuan.pocket3.live-view-decoder",
            qos: .userInitiated)
        decoder.reset(generation: generation)
    }

    public var currentGeneration: UInt64 {
        lock.withLock { generation }
    }

    public var pendingCount: Int {
        lock.withLock { pending.count }
    }

    public var isTerminated: Bool {
        lock.withLock { terminated }
    }

    public func statistics() -> Pocket3LiveViewDecodeServiceStatistics {
        lock.withLock {
            Pocket3LiveViewDecodeServiceStatistics(
                acceptedCount: acceptedCount,
                skippedNotReadyCount: skippedNotReadyCount,
                queueDropCount: queueDropCount,
                staleGenerationCount: staleGenerationCount,
                decodeSuccessCount: decodeSuccessCount,
                frameDropCount: frameDropCount,
                decodeFailureCount: decodeFailureCount,
                terminatedCount: terminatedCount,
                flushedCount: flushedCount,
                pendingMessageCount: pending.count,
                evidenceCount: evidence.count)
        }
    }

    /// Admit one message if its generation and codec readiness are current.
    /// This method never waits for the decoder and returns `.queued` before
    /// the adapter is called.
    @discardableResult
    public func submit(
        _ message: Pocket3LiveViewMediaMessage,
        expectedGeneration: UInt64? = nil
    ) -> Pocket3LiveViewDecodeEvidence {
        let request = try? Pocket3LiveViewDecodeRequest(message: message)
        var startWorker = false
        let result: Pocket3LiveViewDecodeEvidence
        lock.lock()
        defer {
            lock.unlock()
            if startWorker { workerQueue.async { [self] in processQueue() } }
        }

        if terminated {
            terminatedCount &+= 1
            return evidence(for: message, disposition: .terminated,
                            errorCode: "live_view_decoder_terminated")
        }
        guard let request else {
            skippedNotReadyCount &+= 1
            return evidence(for: message, disposition: .skippedNotReady,
                            errorCode: "live_view_not_decoder_ready")
        }
        guard request.generation == generation,
              expectedGeneration == nil || expectedGeneration == generation else {
            staleGenerationCount &+= 1
            return evidence(for: message,
                            disposition: .droppedStaleGeneration,
                            errorCode: "live_view_decoder_generation_changed")
        }
        guard pending.count < limits.maximumPendingMessages else {
            queueDropCount &+= 1
            return evidence(for: message,
                            disposition: .droppedBackpressure,
                            errorCode: "live_view_decoder_backpressure")
        }
        pending.append(request)
        acceptedCount &+= 1
        if !workerRunning {
            workerRunning = true
            startWorker = true
        }
        result = evidence(for: message, disposition: .queued)
        return result
    }

    /// Remove the oldest completed decode evidence.  Pixel buffers are not
    /// retained by this service; adapters may deliver them to their own
    /// consumer while this queue remains bounded to typed evidence.
    public func dequeueEvidence() -> Pocket3LiveViewDecodeEvidence? {
        lock.withLock {
            guard !evidence.isEmpty else { return nil }
            return evidence.removeFirst()
        }
    }

    /// Reset to an exact new owner generation.  In-flight work is fenced and
    /// queued/evidence state is dropped before the adapter is reset.
    @discardableResult
    public func reset(to nextGeneration: UInt64) throws -> UInt64 {
        guard nextGeneration != 0 else {
            throw Pocket3LiveViewDecoderError.invalidGeneration
        }
        lock.withLock {
            generation = nextGeneration
            pending.removeAll(keepingCapacity: false)
            evidence.removeAll(keepingCapacity: false)
            terminated = false
            flushedCount &+= 1
        }
        decoderLock.lock()
        decoder.reset(generation: nextGeneration)
        decoderLock.unlock()
        lock.withLock {
            // An old worker can finish between the generation update and the
            // adapter reset.  Do not let its evidence survive this fence.
            evidence.removeAll(keepingCapacity: false)
        }
        return nextGeneration
    }

    /// Flush queued work without changing the current generation.  A sink
    /// calls this on detach/disconnect before allowing a future attachment.
    public func flush(generation expectedGeneration: UInt64? = nil) {
        let current = lock.withLock { () -> UInt64? in
            guard !terminated,
                  expectedGeneration == nil || expectedGeneration == generation else {
                return nil
            }
            pending.removeAll(keepingCapacity: false)
            evidence.removeAll(keepingCapacity: false)
            flushedCount &+= 1
            return generation
        }
        guard let current else { return }
        decoderLock.lock()
        decoder.reset(generation: current)
        decoderLock.unlock()
        lock.withLock { evidence.removeAll(keepingCapacity: false) }
    }

    /// Permanently stop this service.  Future submissions return typed
    /// `.terminated` evidence and no adapter call is made.
    public func terminate() {
        let current = lock.withLock { () -> UInt64? in
            guard !terminated else { return nil }
            terminated = true
            pending.removeAll(keepingCapacity: false)
            evidence.removeAll(keepingCapacity: false)
            return generation
        }
        guard let current else { return }
        decoderLock.lock()
        decoder.reset(generation: current)
        decoderLock.unlock()
    }

    /// Bounded polling helper for tests and developer diagnostics.
    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval = 1) -> Bool {
        guard timeout.isFinite, timeout >= 0 else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime <= deadline {
            let idle = lock.withLock { pending.isEmpty && !workerRunning }
            if idle { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return lock.withLock { pending.isEmpty && !workerRunning }
    }

    private func processQueue() {
        while true {
            guard let request = lock.withLock({ () -> Pocket3LiveViewDecodeRequest? in
                guard !pending.isEmpty else {
                    workerRunning = false
                    return nil
                }
                return pending.removeFirst()
            }) else { return }

            let output = decode(request)
            lock.withLock {
                if evidence.count >= limits.maximumEvidence {
                    evidence.removeFirst()
                }
                evidence.append(output)
            }
        }
    }

    private func decode(_ request: Pocket3LiveViewDecodeRequest)
        -> Pocket3LiveViewDecodeEvidence {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        let current = lock.withLock { () -> UInt64? in
            guard !terminated else { return nil }
            return generation
        }
        guard let current else {
            return evidence(for: request,
                            disposition: .terminated,
                            errorCode: "live_view_decoder_terminated")
        }
        guard current == request.generation else {
            lock.withLock { staleGenerationCount &+= 1 }
            return evidence(for: request,
                            disposition: .droppedStaleGeneration,
                            errorCode: "live_view_decoder_generation_changed")
        }

        if request.parameterSetsChanged {
            decoder.reset(generation: request.generation)
        }
        do {
            let frame = try decoder.decode(request)
            let stillCurrent = lock.withLock {
                !terminated && generation == request.generation
            }
            guard stillCurrent else {
                lock.withLock { staleGenerationCount &+= 1 }
                return evidence(for: request,
                                disposition: .droppedStaleGeneration,
                                errorCode: "live_view_decoder_generation_changed")
            }
            if frame.frameWasDropped {
                lock.withLock { frameDropCount &+= 1 }
            } else {
                lock.withLock { decodeSuccessCount &+= 1 }
            }
            return evidence(
                for: request,
                disposition: frame.frameWasDropped ? .frameDropped : .decoded,
                decoderSubmitted: true,
                didProduceFrame: frame.didProducePixelBuffer,
                frameWasDropped: frame.frameWasDropped,
                parameterSetRebuilt: request.parameterSetsChanged || frame.parameterSetRebuilt,
                status: frame.status)
        } catch {
            lock.withLock { decodeFailureCount &+= 1 }
            return evidence(for: request, disposition: .failed,
                            decoderSubmitted: true,
                            errorCode: Self.errorCode(error))
        }
    }

    private func evidence(
        for message: Pocket3LiveViewMediaMessage,
        disposition: Pocket3LiveViewDecodeDisposition,
        decoderSubmitted: Bool = false,
        didProduceFrame: Bool = false,
        frameWasDropped: Bool = false,
        parameterSetRebuilt: Bool = false,
        status: Int32? = nil,
        errorCode: String? = nil
    ) -> Pocket3LiveViewDecodeEvidence {
        Pocket3LiveViewDecodeEvidence(
            sessionID: message.sessionID, generation: message.generation,
            messageID: message.messageID, codec: message.codec,
            disposition: disposition, decoderSubmitted: decoderSubmitted,
            didProduceFrame: didProduceFrame, frameWasDropped: frameWasDropped,
            parameterSetRebuilt: parameterSetRebuilt, status: status,
            errorCode: errorCode)
    }

    private func evidence(
        for request: Pocket3LiveViewDecodeRequest,
        disposition: Pocket3LiveViewDecodeDisposition,
        decoderSubmitted: Bool = false,
        didProduceFrame: Bool = false,
        frameWasDropped: Bool = false,
        parameterSetRebuilt: Bool = false,
        status: Int32? = nil,
        errorCode: String? = nil
    ) -> Pocket3LiveViewDecodeEvidence {
        Pocket3LiveViewDecodeEvidence(
            sessionID: request.sessionID, generation: request.generation,
            messageID: request.messageID, codec: request.codec,
            disposition: disposition, decoderSubmitted: decoderSubmitted,
            didProduceFrame: didProduceFrame, frameWasDropped: frameWasDropped,
            parameterSetRebuilt: parameterSetRebuilt, status: status,
            errorCode: errorCode)
    }

    private static func errorCode(_ error: Error) -> String {
        if let error = error as? Pocket3LiveViewDecoderError {
            switch error {
            case .invalidGeneration: return "live_view_decoder_invalid_generation"
            case .invalidLimits: return "live_view_decoder_invalid_limits"
            case .notReady: return "live_view_decoder_not_ready"
            case .invalidInput: return "live_view_decoder_invalid_input"
            case .backpressure: return "live_view_decoder_backpressure"
            case .staleGeneration: return "live_view_decoder_generation_changed"
            case .terminated: return "live_view_decoder_terminated"
            case .underlying(let value): return String(value.prefix(128))
            }
        }
        return String(String(describing: error).prefix(128))
    }
}

/// A lazy VideoToolbox adapter for the media sink.  The first ready message
/// creates a format description/session from the assembler's current bounded
/// parameter-set cache.  A codec or parameter-set change discards that
/// session and creates a new one on the next decode.
public final class Pocket3LiveViewVideoToolboxDecoder: @unchecked Sendable,
    Pocket3LiveViewDecoder {
    public let limits: VideoToolboxDecoderLimits

    private let lock = NSLock()
    private var logicalGeneration: UInt64
    private var decoder: VideoToolboxAccessUnitDecoder?
    private var configuredCodec: VideoToolboxCodec?
    private var configuredParameterSets: [Data] = []
    private var invalidated = false

    public init(
        generation: UInt64 = 1,
        limits: VideoToolboxDecoderLimits = .default
    ) throws {
        guard generation != 0 else {
            throw Pocket3LiveViewDecoderError.invalidGeneration
        }
        self.logicalGeneration = generation
        self.limits = limits
    }

    public var currentGeneration: UInt64 {
        lock.withLock { logicalGeneration }
    }

    public var isInvalidated: Bool {
        lock.withLock { invalidated }
    }

    public func decode(_ request: Pocket3LiveViewDecodeRequest)
        throws -> Pocket3LiveViewDecodedFrame {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else {
            throw Pocket3LiveViewDecoderError.terminated
        }
        guard request.generation == logicalGeneration else {
            throw Pocket3LiveViewDecoderError.staleGeneration(
                expected: request.generation, actual: logicalGeneration)
        }
        guard request.normalizedData.count <= limits.maxAccessUnitBytes else {
            throw Pocket3LiveViewDecoderError.invalidInput
        }

        let bundle: VideoToolboxParameterSetBundle
        do {
            bundle = try VideoToolboxParameterSetBundle(
                codec: request.codec, parameterSets: request.parameterSets,
                limits: limits)
        } catch {
            throw Pocket3LiveViewDecoderError.underlying(
                String(String(describing: error).prefix(128)))
        }

        let needsRebuild = decoder == nil || configuredCodec != request.codec ||
            configuredParameterSets != bundle.parameterSets
        if needsRebuild {
            _ = decoder?.reset()
            decoder = try VideoToolboxAccessUnitDecoder(
                codec: request.codec, parameterSets: bundle, limits: limits)
            configuredCodec = request.codec
            configuredParameterSets = bundle.parameterSets
        }
        guard let decoder else {
            throw Pocket3LiveViewDecoderError.underlying(
                "live_view_decoder_unavailable")
        }
        do {
            let result = try decoder.decode(
                request.normalizedData,
                expectedGeneration: decoder.currentGeneration)
            return Pocket3LiveViewDecodedFrame(
                status: Int32(result.status),
                infoFlagsRawValue: result.infoFlags.rawValue,
                pixelBuffer: result.pixelBuffer,
                frameWasDropped: result.frameWasDropped,
                parameterSetRebuilt: needsRebuild)
        } catch {
            throw Pocket3LiveViewDecoderError.underlying(
                String(String(describing: error).prefix(128)))
        }
    }

    public func reset(generation nextGeneration: UInt64) {
        guard nextGeneration != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        logicalGeneration = nextGeneration
        _ = decoder?.reset()
        decoder = nil
        configuredCodec = nil
        configuredParameterSets.removeAll(keepingCapacity: false)
    }

    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { return }
        invalidated = true
        decoder?.invalidate()
        decoder = nil
        configuredCodec = nil
        configuredParameterSets.removeAll(keepingCapacity: false)
    }
}

/// The concrete passive sink joining pktType-02 assembly to the bounded
/// decoder service.  If no decoder service is supplied, completed messages
/// remain available through ``dequeueMessage()`` and no decode is attempted.
public final class Pocket3LiveViewMediaSink: @unchecked Sendable,
    Pocket3DatalinkLiveViewSink {
    /// A zero session ID enables the developer datalink adapter to bind the
    /// assembler to the first admitted UDP session without guessing the
    /// private transport cursor. Explicit callers may continue to provide a
    /// known nonzero session ID.
    public private(set) var sessionID: UInt16
    public let limits: Pocket3LiveViewMediaLimits

    private let lock = NSLock()
    private let autoSessionID: Bool
    private var assembler: Pocket3LiveViewMediaAssembler
    private let decoderService: Pocket3LiveViewDecodeService?
    private var activeGeneration: UInt64?
    private var latestObservationValue: Pocket3LiveViewMediaObservation?
    private var staleDatagramCount: UInt64 = 0
    private var assemblerErrorCount: UInt64 = 0
    private var lastErrorCode: String?

    public init(
        sessionID: UInt16,
        generation: UInt64 = 1,
        limits: Pocket3LiveViewMediaLimits = .default,
        decoderService: Pocket3LiveViewDecodeService? = nil
    ) throws {
        self.sessionID = sessionID
        self.limits = limits
        self.autoSessionID = sessionID == 0
        self.assembler = try Pocket3LiveViewMediaAssembler(
            sessionID: sessionID, generation: generation, limits: limits)
        self.decoderService = decoderService
        self.activeGeneration = generation
    }

    public convenience init(
        sessionID: UInt16 = 0,
        generation: UInt64 = 1,
        limits: Pocket3LiveViewMediaLimits = .default,
        decoder: any Pocket3LiveViewDecoder,
        decoderLimits: Pocket3LiveViewDecodeServiceLimits = .default
    ) throws {
        let service = try Pocket3LiveViewDecodeService(
            decoder: decoder, generation: generation, limits: decoderLimits)
        try self.init(sessionID: sessionID, generation: generation,
                      limits: limits, decoderService: service)
    }

    public var currentGeneration: UInt64? {
        lock.withLock { activeGeneration }
    }

    public var pendingMessageCount: Int {
        let assembled = lock.withLock { assembler.pendingAccessUnitCount }
        return assembled + (decoderService?.pendingCount ?? 0)
    }

    public var staleDatagrams: UInt64 {
        lock.withLock { staleDatagramCount }
    }

    public var lastError: String? {
        lock.withLock { lastErrorCode }
    }

    public func statistics() -> Pocket3LiveViewMediaStatistics {
        lock.withLock { assembler.statistics }
    }

    public func decoderStatistics()
        -> Pocket3LiveViewDecodeServiceStatistics? {
        decoderService?.statistics()
    }

    /// The newest bounded media readiness observation.  The complete media
    /// bytes remain owned by the assembler/decoder queues; this value only
    /// exposes generation, codec and random-access evidence to a session
    /// coordinator.
    public func latestMediaObservation() -> Pocket3LiveViewMediaObservation? {
        lock.withLock { latestObservationValue }
    }

    public func dequeueMessage() -> Pocket3LiveViewMediaMessage? {
        lock.withLock { assembler.dequeue() }
    }

    public func dequeueDecodeEvidence() -> Pocket3LiveViewDecodeEvidence? {
        decoderService?.dequeueEvidence()
    }

    public func attach(generation: UInt64) {
        guard generation != 0 else { return }
        lock.withLock {
            activeGeneration = generation
            if autoSessionID {
                if let fresh = try? Pocket3LiveViewMediaAssembler(
                    sessionID: 0, generation: generation, limits: limits) {
                    assembler = fresh
                    sessionID = 0
                }
            } else {
                try? assembler.reset(to: generation)
            }
            lastErrorCode = nil
            staleDatagramCount = 0
            assemblerErrorCount = 0
            latestObservationValue = nil
        }
        if let decoderService {
            _ = try? decoderService.reset(to: generation)
        }
    }

    public func receive(_ datagram: DJIUDPDatagram, generation: UInt64) {
        var completed: [Pocket3LiveViewMediaMessage] = []
        let receivedUptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard activeGeneration == generation else {
            staleDatagramCount &+= 1
            lock.unlock()
            return
        }
        do {
            if autoSessionID, sessionID == 0 {
                assembler = try Pocket3LiveViewMediaAssembler(
                    sessionID: datagram.header.sessionID,
                    generation: generation, limits: limits)
                sessionID = datagram.header.sessionID
            }
            if let message = try assembler.consume(
                datagram,
                receivedUptime: receivedUptime,
                expectedGeneration: generation) {
                latestObservationValue = Pocket3LiveViewMediaObservation(
                    message: message, receivedUptime: receivedUptime)
            }
            if decoderService != nil {
                while let message = assembler.dequeue() {
                    completed.append(message)
                }
            }
        } catch {
            assemblerErrorCount &+= 1
            lastErrorCode = Self.errorCode(error)
        }
        lock.unlock()

        guard let decoderService else { return }
        for message in completed {
            _ = decoderService.submit(message, expectedGeneration: generation)
        }
    }

    public func flush(generation: UInt64) {
        let shouldFlush = lock.withLock { () -> Bool in
            guard activeGeneration == generation else { return false }
            activeGeneration = nil
            if autoSessionID {
                if let fresh = try? Pocket3LiveViewMediaAssembler(
                    sessionID: 0, generation: generation, limits: limits) {
                    assembler = fresh
                    sessionID = 0
                }
            } else {
                assembler.reset()
            }
            latestObservationValue = nil
            return true
        }
        guard shouldFlush else { return }
        decoderService?.flush(generation: generation)
    }

    private static func errorCode(_ error: Error) -> String {
        if let error = error as? Pocket3LiveViewMediaError {
            switch error {
            case .invalidLimits: return "live_view_invalid_limits"
            case .terminated: return "live_view_terminated"
            case .wrongPacketType: return "live_view_wrong_packet_type"
            case .invalidSession: return "live_view_invalid_session"
            case .invalidGeneration: return "live_view_generation_changed"
            case .invalidHeader: return "live_view_invalid_header"
            case .malformedFragment: return "live_view_malformed_fragment"
            case .declaredLengthInvalid: return "live_view_declared_length_invalid"
            case .fragmentTooLarge: return "live_view_fragment_too_large"
            case .fragmentOverrun: return "live_view_fragment_overrun"
            case .invalidClock: return "live_view_invalid_clock"
            }
        }
        return String(String(describing: error).prefix(128))
    }
}

public typealias Pocket3LiveViewDatalinkSink = Pocket3LiveViewMediaSink
