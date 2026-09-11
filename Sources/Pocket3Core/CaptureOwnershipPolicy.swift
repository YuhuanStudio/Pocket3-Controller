import Foundation

/// The stable and transitional ownership states for the camera's video
/// streaming endpoint.
///
/// The policy is deliberately independent of AVFoundation, IOKit and the
/// direct UVC implementation.  A caller performs the actual work and feeds
/// the resulting evidence back through the callbacks below.
public enum CaptureOwnershipState: String, Codable, CaseIterable, Sendable, Equatable {
    case idle
    case avfoundationRunning
    case stoppingAVF
    case acquiringDirect
    case directRunning
    case releasingDirect
    case restartingAVF
    case error

    public var transitionStage: CaptureOwnershipStage? {
        switch self {
        case .stoppingAVF: .stoppingAVF
        case .acquiringDirect: .acquiringDirect
        case .releasingDirect: .releasingDirect
        case .restartingAVF: .restartingAVF
        default: nil
        }
    }

    public var isStable: Bool { transitionStage == nil }
}

/// An asynchronous operation for which the owner must retain and return the
/// exact permit it received.  A new permit is issued for every asynchronous
/// stage, so a callback from an earlier stage cannot complete a later one.
public enum CaptureOwnershipStage: String, Codable, CaseIterable, Sendable, Equatable {
    case stoppingAVF
    case acquiringDirect
    case releasingDirect
    case restartingAVF

    fileprivate var state: CaptureOwnershipState {
        switch self {
        case .stoppingAVF: .stoppingAVF
        case .acquiringDirect: .acquiringDirect
        case .releasingDirect: .releasingDirect
        case .restartingAVF: .restartingAVF
        }
    }
}

/// Opaque authorization for one lifecycle stage.
///
/// `generation` is observable for diagnostics, while `id` makes the permit
/// unforgeable by callers that only know the generation.  Both values are
/// checked before a completion, failure or cancellation can mutate policy
/// state.
public struct CaptureOwnershipPermit: Hashable, Sendable {
    public let id: UUID
    public let generation: UInt64
    public let stage: CaptureOwnershipStage

    public var operation: CaptureOwnershipStage { stage }

    fileprivate init(generation: UInt64, stage: CaptureOwnershipStage) {
        self.id = UUID()
        self.generation = generation
        self.stage = stage
    }
}

/// Evidence that AVFoundation has relinquished the endpoint completely.
///
/// A stop notification by itself is insufficient: queued sample-buffer
/// callbacks must also be drained before direct UVC acquisition may start.
public struct AVFoundationStopEvidence: Codable, Sendable, Equatable {
    public let avfoundationStopped: Bool
    public let frameQueueDrained: Bool

    public init(avfoundationStopped: Bool = false, frameQueueDrained: Bool = false) {
        self.avfoundationStopped = avfoundationStopped
        self.frameQueueDrained = frameQueueDrained
    }

    /// Spelling useful at call sites that describe the AVFoundation session
    /// rather than the AVF shorthand used by the state machine.
    public init(sessionStopped: Bool, frameQueueDrained: Bool) {
        self.init(avfoundationStopped: sessionStopped, frameQueueDrained: frameQueueDrained)
    }

    public init(stopConfirmed: Bool, frameQueueDrained: Bool) {
        self.init(avfoundationStopped: stopConfirmed, frameQueueDrained: frameQueueDrained)
    }

    public static let complete = Self(avfoundationStopped: true, frameQueueDrained: true)

    public var isComplete: Bool { avfoundationStopped && frameQueueDrained }
    public var sessionStopped: Bool { avfoundationStopped }
    public var stopConfirmed: Bool { avfoundationStopped }
}

/// Evidence that every direct-UVC resource has been released.
///
/// The individual flags let a future transport report which cleanup fence it
/// has reached.  Restarting AVFoundation requires all four flags, rather than
/// a reader-stop callback or interface close in isolation.
public struct DirectCaptureReleaseEvidence: Codable, Sendable, Equatable {
    public let readerStopped: Bool
    public let pipeReleased: Bool
    public let interfaceReleased: Bool
    public let objectsReleased: Bool

    public init(readerStopped: Bool = false, pipeReleased: Bool = false,
                interfaceReleased: Bool = false, objectsReleased: Bool = false) {
        self.readerStopped = readerStopped
        self.pipeReleased = pipeReleased
        self.interfaceReleased = interfaceReleased
        self.objectsReleased = objectsReleased
    }

    /// Convenience for tests and adapters that have one authoritative
    /// release fence instead of four separate callbacks.
    public init(released: Bool) {
        self.init(readerStopped: released, pipeReleased: released,
                  interfaceReleased: released, objectsReleased: released)
    }

    public init(directCaptureReleased: Bool) {
        self.init(released: directCaptureReleased)
    }

    public init(fullyReleased: Bool) {
        self.init(released: fullyReleased)
    }

    public static let complete = Self(released: true)

    public var isComplete: Bool {
        readerStopped && pipeReleased && interfaceReleased && objectsReleased
    }
    public var released: Bool { isComplete }
    public var directCaptureReleased: Bool { isComplete }
}

public enum CaptureOwnershipEvidence: String, Codable, Sendable, Equatable {
    case avfoundationStoppedAndFrameQueueDrained
    case directCaptureReleased
}

/// A failure retained while the policy is in `.error`.
public enum CaptureOwnershipFailure: Sendable, Equatable {
    case cancelled(CaptureOwnershipStage)
    case operationFailed(CaptureOwnershipStage)
    case disconnected

    public var stage: CaptureOwnershipStage? {
        switch self {
        case .cancelled(let stage), .operationFailed(let stage): stage
        case .disconnected: nil
        }
    }
}

public enum CaptureOwnershipError: Error, LocalizedError, Sendable, Equatable {
    case busy(CaptureOwnershipState)
    case invalidState(expected: CaptureOwnershipState, actual: CaptureOwnershipState)
    case stalePermit
    case evidenceRequired(CaptureOwnershipEvidence)
    case operationFailed(CaptureOwnershipStage)
    case recoveryUnavailable

    public var errorDescription: String? {
        switch self {
        case .busy(let state): "Capture ownership is busy in \(state.rawValue)"
        case .invalidState(let expected, let actual):
            "Expected capture ownership state \(expected.rawValue), got \(actual.rawValue)"
        case .stalePermit: "Capture ownership permit is stale"
        case .evidenceRequired(let evidence): "Required capture ownership evidence is missing: \(evidence.rawValue)"
        case .operationFailed(let stage): "Capture ownership operation failed: \(stage.rawValue)"
        case .recoveryUnavailable: "No safe recovery is available for the current capture ownership failure"
        }
    }
}

public struct CaptureOwnershipSnapshot: Sendable, Equatable {
    public let state: CaptureOwnershipState
    public let generation: UInt64
    public let activePermit: CaptureOwnershipPermit?
    public let failure: CaptureOwnershipFailure?

    public init(state: CaptureOwnershipState, generation: UInt64,
                activePermit: CaptureOwnershipPermit?, failure: CaptureOwnershipFailure?) {
        self.state = state
        self.generation = generation
        self.activePermit = activePermit
        self.failure = failure
    }
}

/// Pure state and transition policy for switching video endpoint ownership.
///
/// This type performs no I/O and is safe to pass by value between tasks.  For
/// shared mutable use, ``CaptureOwnershipCoordinator`` provides an actor that
/// serializes the same reducer operations.
public struct CaptureOwnershipPolicy: Sendable {
    public private(set) var state: CaptureOwnershipState
    public private(set) var generation: UInt64
    public private(set) var activePermit: CaptureOwnershipPermit?
    public private(set) var failure: CaptureOwnershipFailure?

    public init(initialState: CaptureOwnershipState = .idle, generation: UInt64 = 0) {
        precondition(initialState.isStable, "A transitional state requires an active lifecycle permit")
        self.state = initialState
        self.generation = generation
        self.activePermit = nil
        self.failure = initialState == .error ? .operationFailed(.stoppingAVF) : nil
    }

    public var snapshot: CaptureOwnershipSnapshot {
        CaptureOwnershipSnapshot(state: state, generation: generation,
                                 activePermit: activePermit, failure: failure)
    }

    /// Requests the AVFoundation -> direct-UVC handoff.  The returned permit
    /// authorizes only the stop operation; direct acquisition is not admitted
    /// until ``avfoundationStopped(_:evidence:)`` receives complete evidence.
    @discardableResult
    public mutating func beginDirectCapture() throws -> CaptureOwnershipPermit {
        guard state == .avfoundationRunning else { throw CaptureOwnershipError.busy(state) }
        return issue(.stoppingAVF)
    }

    public mutating func requestDirectCapture() throws -> CaptureOwnershipPermit {
        try beginDirectCapture()
    }

    /// Accepts AVFoundation stop completion and atomically begins the direct
    /// acquisition stage.  A stop callback without a drained frame queue is
    /// intentionally rejected and leaves the policy in `.stoppingAVF`.
    @discardableResult
    public mutating func avfoundationStopped(_ permit: CaptureOwnershipPermit,
                                             evidence: AVFoundationStopEvidence) throws -> CaptureOwnershipPermit {
        try require(permit, stage: .stoppingAVF)
        guard evidence.isComplete else {
            throw CaptureOwnershipError.evidenceRequired(.avfoundationStoppedAndFrameQueueDrained)
        }
        return issue(.acquiringDirect)
    }

    @discardableResult
    public mutating func didStopAVFoundation(_ permit: CaptureOwnershipPermit,
                                             evidence: AVFoundationStopEvidence) throws -> CaptureOwnershipPermit {
        try avfoundationStopped(permit, evidence: evidence)
    }

    /// Completes direct UVC acquisition.  Acquisition is possible only after
    /// the stop callback above has accepted both required AVF fences.
    public mutating func directAcquired(_ permit: CaptureOwnershipPermit) throws {
        try require(permit, stage: .acquiringDirect)
        state = .directRunning
        activePermit = nil
        failure = nil
    }

    public mutating func didAcquireDirect(_ permit: CaptureOwnershipPermit) throws {
        try directAcquired(permit)
    }

    /// Requests the direct-UVC -> AVFoundation handoff.
    @discardableResult
    public mutating func beginAVFoundationRestart() throws -> CaptureOwnershipPermit {
        guard state == .directRunning else { throw CaptureOwnershipError.busy(state) }
        return issue(.releasingDirect)
    }

    public mutating func requestAVFoundationRestart() throws -> CaptureOwnershipPermit {
        try beginAVFoundationRestart()
    }

    /// Accepts direct release completion and begins AVFoundation restart only
    /// when every direct resource release fence is present.
    @discardableResult
    public mutating func directReleased(_ permit: CaptureOwnershipPermit,
                                        evidence: DirectCaptureReleaseEvidence) throws -> CaptureOwnershipPermit {
        try require(permit, stage: .releasingDirect)
        guard evidence.isComplete else {
            throw CaptureOwnershipError.evidenceRequired(.directCaptureReleased)
        }
        return issue(.restartingAVF)
    }

    @discardableResult
    public mutating func didReleaseDirect(_ permit: CaptureOwnershipPermit,
                                          evidence: DirectCaptureReleaseEvidence) throws -> CaptureOwnershipPermit {
        try directReleased(permit, evidence: evidence)
    }

    /// Completes AVFoundation restart and returns to the normal AVF owner.
    public mutating func avfoundationRestarted(_ permit: CaptureOwnershipPermit) throws {
        try require(permit, stage: .restartingAVF)
        state = .avfoundationRunning
        activePermit = nil
        failure = nil
    }

    public mutating func didRestartAVFoundation(_ permit: CaptureOwnershipPermit) throws {
        try avfoundationRestarted(permit)
    }

    /// Fences the exact in-flight operation.  Cancellation deliberately enters
    /// `.error`: the policy cannot infer whether a partially completed stop,
    /// open, close or restart touched a real resource.  Fresh evidence or a
    /// disconnect is required before another owner can be admitted.
    public mutating func cancel(_ permit: CaptureOwnershipPermit) throws {
        try require(permit, stage: permit.stage)
        let stage = permit.stage
        enterError(.cancelled(stage))
    }

    /// Records an asynchronous operation failure and fences every callback
    /// carrying the failed permit.
    public mutating func fail(_ permit: CaptureOwnershipPermit) throws {
        try require(permit, stage: permit.stage)
        enterError(.operationFailed(permit.stage))
    }

    public mutating func operationFailed(_ permit: CaptureOwnershipPermit) throws {
        try fail(permit)
    }

    /// A physical disconnect removes the owner and invalidates every permit.
    /// `.idle` is safe here because no connected endpoint remains to acquire;
    /// a reconnect must explicitly report AVFoundation running first.
    public mutating func disconnect() {
        _ = advanceGeneration()
        state = .idle
        activePermit = nil
        failure = .disconnected
    }

    /// Records an externally completed AVFoundation startup after a connection
    /// or reconnect.  It is intentionally available only from `.idle`.
    public mutating func avfoundationStarted() throws {
        guard state == .idle else { throw CaptureOwnershipError.busy(state) }
        _ = advanceGeneration()
        state = .avfoundationRunning
        activePermit = nil
        failure = nil
    }

    public mutating func didStartAVFoundation() throws {
        try avfoundationStarted()
    }

    /// Recovery after a failed/cancelled AVF stop.  The evidence must be
    /// complete before direct acquisition can be retried.
    @discardableResult
    public mutating func retryDirectAcquisition(after evidence: AVFoundationStopEvidence) throws -> CaptureOwnershipPermit {
        guard state == .error,
              failure?.stage == .stoppingAVF else { throw CaptureOwnershipError.recoveryUnavailable }
        guard evidence.isComplete else {
            throw CaptureOwnershipError.evidenceRequired(.avfoundationStoppedAndFrameQueueDrained)
        }
        return issue(.acquiringDirect)
    }

    /// Recovery after a failed/cancelled direct acquisition or release.  The
    /// direct resources must be proven released before AVFoundation restart.
    @discardableResult
    public mutating func retryAVFoundationRestart(after evidence: DirectCaptureReleaseEvidence) throws -> CaptureOwnershipPermit {
        guard state == .error,
              let stage = failure?.stage,
              stage == .acquiringDirect || stage == .releasingDirect else {
            throw CaptureOwnershipError.recoveryUnavailable
        }
        guard evidence.isComplete else {
            throw CaptureOwnershipError.evidenceRequired(.directCaptureReleased)
        }
        return issue(.restartingAVF)
    }

    /// A restart failure happens after direct release evidence was accepted,
    /// so retrying that restart does not need to repeat the release fence.
    @discardableResult
    public mutating func retryAVFoundationRestart() throws -> CaptureOwnershipPermit {
        guard state == .error, failure?.stage == .restartingAVF else {
            throw CaptureOwnershipError.recoveryUnavailable
        }
        return issue(.restartingAVF)
    }

    /// Allows a failed AVFoundation stop to be reconciled as a known stopped
    /// and drained endpoint without starting direct capture immediately.
    public mutating func reconcileAVFoundationStopped(_ evidence: AVFoundationStopEvidence) throws {
        guard state == .error, failure?.stage == .stoppingAVF else {
            throw CaptureOwnershipError.recoveryUnavailable
        }
        guard evidence.isComplete else {
            throw CaptureOwnershipError.evidenceRequired(.avfoundationStoppedAndFrameQueueDrained)
        }
        _ = advanceGeneration()
        state = .idle
        activePermit = nil
        failure = nil
    }

    /// Allows a stop/restart callback to report a known running AVFoundation
    /// session after the policy entered `.error`.
    public mutating func reconcileAVFoundationRunning() throws {
        guard state == .error,
              let stage = failure?.stage,
              stage == .stoppingAVF || stage == .restartingAVF else {
            throw CaptureOwnershipError.recoveryUnavailable
        }
        _ = advanceGeneration()
        state = .avfoundationRunning
        activePermit = nil
        failure = nil
    }

    private mutating func issue(_ stage: CaptureOwnershipStage) -> CaptureOwnershipPermit {
        let next = advanceGeneration()
        let permit = CaptureOwnershipPermit(generation: next, stage: stage)
        state = stage.state
        activePermit = permit
        failure = nil
        return permit
    }

    private mutating func enterError(_ failure: CaptureOwnershipFailure) {
        _ = advanceGeneration()
        state = .error
        activePermit = nil
        self.failure = failure
    }

    @discardableResult
    private mutating func advanceGeneration() -> UInt64 {
        generation = generation == .max ? 0 : generation + 1
        return generation
    }

    private func require(_ permit: CaptureOwnershipPermit, stage: CaptureOwnershipStage) throws {
        guard permit.stage == stage,
              permit.generation == generation,
              activePermit == permit,
              state.transitionStage == stage else {
            throw CaptureOwnershipError.stalePermit
        }
    }
}

/// Actor facade for callers that share one policy between capture callbacks,
/// cancellation handlers and UI tasks.  It has no transport or hardware
/// dependency; every method is just a serialized reducer operation.
public actor CaptureOwnershipCoordinator {
    private var policy: CaptureOwnershipPolicy

    public init(initialState: CaptureOwnershipState = .idle, generation: UInt64 = 0) {
        policy = CaptureOwnershipPolicy(initialState: initialState, generation: generation)
    }

    public func snapshot() -> CaptureOwnershipSnapshot { policy.snapshot }
    public func state() -> CaptureOwnershipState { policy.state }
    public func currentGeneration() -> UInt64 { policy.generation }

    @discardableResult
    public func beginDirectCapture() throws -> CaptureOwnershipPermit {
        try policy.beginDirectCapture()
    }

    @discardableResult
    public func avfoundationStopped(_ permit: CaptureOwnershipPermit,
                                    evidence: AVFoundationStopEvidence) throws -> CaptureOwnershipPermit {
        try policy.avfoundationStopped(permit, evidence: evidence)
    }

    public func directAcquired(_ permit: CaptureOwnershipPermit) throws {
        try policy.directAcquired(permit)
    }

    @discardableResult
    public func beginAVFoundationRestart() throws -> CaptureOwnershipPermit {
        try policy.beginAVFoundationRestart()
    }

    @discardableResult
    public func directReleased(_ permit: CaptureOwnershipPermit,
                               evidence: DirectCaptureReleaseEvidence) throws -> CaptureOwnershipPermit {
        try policy.directReleased(permit, evidence: evidence)
    }

    public func avfoundationRestarted(_ permit: CaptureOwnershipPermit) throws {
        try policy.avfoundationRestarted(permit)
    }

    public func cancel(_ permit: CaptureOwnershipPermit) throws {
        try policy.cancel(permit)
    }

    public func fail(_ permit: CaptureOwnershipPermit) throws {
        try policy.fail(permit)
    }

    public func disconnect() { policy.disconnect() }
    public func avfoundationStarted() throws { try policy.avfoundationStarted() }

    @discardableResult
    public func retryDirectAcquisition(after evidence: AVFoundationStopEvidence) throws -> CaptureOwnershipPermit {
        try policy.retryDirectAcquisition(after: evidence)
    }

    @discardableResult
    public func retryAVFoundationRestart(after evidence: DirectCaptureReleaseEvidence) throws -> CaptureOwnershipPermit {
        try policy.retryAVFoundationRestart(after: evidence)
    }

    @discardableResult
    public func retryAVFoundationRestart() throws -> CaptureOwnershipPermit {
        try policy.retryAVFoundationRestart()
    }
}

public typealias CaptureOwnershipActor = CaptureOwnershipCoordinator
