import CoreMedia
import CoreVideo
import Foundation

/// The small state machine behind the encoded video worker.  It is kept
/// independent of VideoToolbox so bounded admission, ordering and lifecycle
/// invalidation can be tested without a camera or fabricated frames.
struct H264DecodePipelineState: Sendable, Equatable {
    struct Admission: Sendable, Equatable {
        let generation: UInt64
        let ordinal: UInt64
    }

    enum Completion: Sendable, Equatable {
        case committed
        case stale
        case outOfOrder
    }

    let maximumPending: Int
    private(set) var generation: UInt64?
    private(set) var pendingCount = 0
    private(set) var submittedCount = 0
    private(set) var droppedCount = 0
    private var nextOrdinal = UInt64(0)
    private var nextCompletionOrdinal = UInt64(0)

    init(maximumPending: Int = 6) {
        self.maximumPending = max(1, maximumPending)
        generation = nil
    }

    mutating func begin(generation: UInt64) {
        self.generation = generation
        pendingCount = 0
        submittedCount = 0
        droppedCount = 0
        nextOrdinal = 0
        nextCompletionOrdinal = 0
    }

    mutating func admit(generation expectedGeneration: UInt64) -> Admission? {
        guard generation == expectedGeneration, pendingCount < maximumPending else {
            droppedCount += 1
            return nil
        }
        let admission = Admission(generation: expectedGeneration, ordinal: nextOrdinal)
        nextOrdinal &+= 1
        pendingCount += 1
        submittedCount += 1
        return admission
    }

    mutating func complete(_ admission: Admission) -> Completion {
        guard generation == admission.generation else { return .stale }
        guard pendingCount > 0 else {
            droppedCount += 1
            return .stale
        }
        pendingCount -= 1
        guard admission.ordinal == nextCompletionOrdinal else {
            droppedCount += 1
            return .outOfOrder
        }
        nextCompletionOrdinal &+= 1
        return .committed
    }

    mutating func cancel() {
        generation = nil
        pendingCount = 0
        nextOrdinal = 0
        nextCompletionOrdinal = 0
    }
}

enum H264DecodePipelineDropReason: String, Sendable {
    case cancelled
    case generationChanged
    case outOfOrder
    case callbackRejected
}

/// A retained capture sample is safe to move to the private worker because
/// CoreMedia ownership is reference counted.  The wrapper makes that boundary
/// explicit to Swift's strict-concurrency checker; all CoreMedia inspection
/// still happens on the worker before any result is published.
struct H264DecodePipelineWork: @unchecked Sendable {
    let sample: CMSampleBuffer
    let binding: CaptureCallbackFence.Binding
    let inputMediaSubType: UInt32?
    let mediaSubType: UInt32?
    let receivedAt: Date
    let receivedUptime: Double
    let presentationTimeStamp: Double
    let submittedUptime: Double
    let admission: H264DecodePipelineState.Admission
}

struct H264DecodePipelineResult: @unchecked Sendable {
    let work: H264DecodePipelineWork
    let pixelBuffer: CVPixelBuffer?
    let attemptedDecode: Bool
    let decodeSucceeded: Bool
    let decodeDurationSeconds: Double
    let queueLatencySeconds: Double
    let dropped: Bool
    let dropReason: H264DecodePipelineDropReason?
}

/// Serial VideoToolbox worker for AVFoundation's compressed H.264 output.
///
/// `CaptureEngine`'s sample callback remains short: it admits at most
/// `maximumPending` samples and returns immediately.  One decoder is retained
/// on this private serial queue, preserving sample order and parameter-set
/// continuity.  Cancellation invalidates the generation before waiting for
/// the queue, so a result can never cross a stop/start fence.
final class H264DecodePipeline: @unchecked Sendable {
    typealias ResultHandler = @Sendable (H264DecodePipelineResult) -> Void

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var state: H264DecodePipelineState
    private var decoder: AVC1SampleDecoder?
    private var handler: ResultHandler?

    init(maximumPending: Int = 6, handler: ResultHandler? = nil) {
        state = H264DecodePipelineState(maximumPending: maximumPending)
        self.handler = handler
        queue = DispatchQueue(label: "studio.yuhuan.pocket3.h264-decode", qos: .userInitiated)
    }

    var maximumPending: Int { lock.withLock { state.maximumPending } }

    func setHandler(_ handler: ResultHandler?) {
        lock.withLock { self.handler = handler }
    }

    func begin(generation: UInt64) {
        lock.withLock { state.begin(generation: generation) }
        queue.sync {
            decoder?.invalidate()
            decoder = nil
        }
    }

    /// Returns `false` when the bounded queue is full or the callback belongs
    /// to an old lifecycle.  A rejected sample is never decoded or turned into
    /// a placeholder frame.
    @discardableResult
    func submit(sample: CMSampleBuffer, binding: CaptureCallbackFence.Binding,
                inputMediaSubType: UInt32?, mediaSubType: UInt32?,
                receivedAt: Date, receivedUptime: Double,
                presentationTimeStamp: Double, submittedUptime: Double) -> Bool {
        guard let admission = lock.withLock({ state.admit(generation: binding.generation) }) else { return false }
        let work = H264DecodePipelineWork(sample: sample, binding: binding,
            inputMediaSubType: inputMediaSubType, mediaSubType: mediaSubType,
            receivedAt: receivedAt, receivedUptime: receivedUptime,
            presentationTimeStamp: presentationTimeStamp,
            submittedUptime: submittedUptime, admission: admission)
        queue.async { [weak self] in self?.process(work) }
        return true
    }

    /// Invalidate before waiting.  The worker may finish its current real
    /// VideoToolbox decode, but its result will be marked stale and rejected
    /// by the callback fence.  No queued work survives the lifecycle change.
    func cancelAndWait() {
        lock.withLock { state.cancel() }
        queue.sync {
            decoder?.invalidate()
            decoder = nil
        }
    }

    private func process(_ work: H264DecodePipelineWork) {
        let started = ProcessInfo.processInfo.systemUptime
        let active = lock.withLock { state.generation == work.admission.generation }
        var pixelBuffer: CVPixelBuffer?
        var attemptedDecode = false
        var decodeSucceeded = false
        var decodeDuration = 0.0

        if active {
            attemptedDecode = true
            do {
                if decoder == nil { decoder = AVC1SampleDecoder() }
                let decodeStarted = ProcessInfo.processInfo.systemUptime
                pixelBuffer = try decoder?.decode(work.sample).pixelBuffer
                decodeDuration = max(0, ProcessInfo.processInfo.systemUptime - decodeStarted)
                decodeSucceeded = pixelBuffer != nil
            } catch {
                decodeDuration = max(0, ProcessInfo.processInfo.systemUptime - started)
            }
        }

        let queueLatency = max(0, started - work.submittedUptime)
        let completion = lock.withLock { state.complete(work.admission) }
        let dropped: Bool
        let reason: H264DecodePipelineDropReason?
        switch completion {
        case .committed:
            dropped = false
            reason = nil
        case .stale:
            dropped = true
            reason = active ? .callbackRejected : .generationChanged
        case .outOfOrder:
            dropped = true
            reason = .outOfOrder
        }
        let result = H264DecodePipelineResult(work: work, pixelBuffer: pixelBuffer,
            attemptedDecode: attemptedDecode, decodeSucceeded: decodeSucceeded,
            decodeDurationSeconds: decodeDuration, queueLatencySeconds: queueLatency,
            dropped: dropped, dropReason: reason)
        let handler = lock.withLock { self.handler }
        handler?(result)
    }
}
