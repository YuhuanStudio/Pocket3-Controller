import Foundation

/// A clock boundary keeps live-view watchdog and cooldown policy deterministic
/// in developer validation without sleeping or touching the host network.
public protocol Pocket3LiveViewClock: Sendable {
    var now: TimeInterval { get }
}

public struct SystemPocket3LiveViewClock: Pocket3LiveViewClock, Sendable {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// A small observation emitted by the existing pktType-02 assembler/sink.
/// `codecReady` is the normalizer gate; `hasRandomAccessPoint` is retained as
/// a separate condition so a future source cannot promote live readiness from
/// parameter sets alone.
public struct Pocket3LiveViewMediaObservation: Codable, Sendable, Equatable {
    public let generation: UInt64
    public let messageID: UInt64
    public let codec: VideoToolboxCodec?
    public let codecReady: Bool
    public let hasRandomAccessPoint: Bool
    public let receivedUptime: TimeInterval

    public init(
        generation: UInt64,
        messageID: UInt64,
        codec: VideoToolboxCodec?,
        codecReady: Bool,
        hasRandomAccessPoint: Bool,
        receivedUptime: TimeInterval
    ) {
        self.generation = generation
        self.messageID = messageID
        self.codec = codec
        self.codecReady = codecReady
        self.hasRandomAccessPoint = hasRandomAccessPoint
        self.receivedUptime = receivedUptime
    }

    public init(
        message: Pocket3LiveViewMediaMessage,
        receivedUptime: TimeInterval
    ) {
        self.init(
            generation: message.generation,
            messageID: message.messageID,
            codec: message.codec,
            codecReady: message.isDecoderReady,
            hasRandomAccessPoint: message.containsRandomAccessPoint,
            receivedUptime: receivedUptime)
    }
}

/// Read-only media boundary used by the coordinator.  The source may be the
/// existing ``Pocket3LiveViewMediaSink`` or a deterministic fake; it owns no
/// command and no network association operation.
public protocol Pocket3LiveViewMediaSource: AnyObject, Sendable {
    func attach(generation: UInt64)
    func flush(generation: UInt64)
    func latestMediaObservation() -> Pocket3LiveViewMediaObservation?
}

extension Pocket3LiveViewMediaSink: Pocket3LiveViewMediaSource {}

/// The sole command owner is injected so tests can prove command cadence
/// without opening a socket.  The production adapter below forwards to the
/// existing ``Pocket3Datalink.transact`` owner.
public protocol Pocket3LiveViewCommandExecutor: Sendable {
    func execute(
        _ request: NativeCommandTransactionRequest,
        readiness: NativeCameraSessionStatus
    ) async throws -> NativeCommandTransactionResult
}

/// Closure-backed executor for developer routes that need one extra model
/// identity fence around the existing datalink owner.
public struct Pocket3LiveViewCommandExecutorAdapter:
    Pocket3LiveViewCommandExecutor, Sendable {
    public typealias Execute = @Sendable (
        _ request: NativeCommandTransactionRequest,
        _ readiness: NativeCameraSessionStatus
    ) async throws -> NativeCommandTransactionResult

    private let body: Execute

    public init(_ body: @escaping Execute) {
        self.body = body
    }

    public func execute(
        _ request: NativeCommandTransactionRequest,
        readiness: NativeCameraSessionStatus
    ) async throws -> NativeCommandTransactionResult {
        try await body(request, readiness)
    }
}

public enum Pocket3LiveViewSessionCommandKind: String, Codable, Sendable,
    Equatable, CaseIterable {
    case preEnableHint
    case enable
    case requestIDR
}

/// Typed, wire-independent live-view command candidates.  The receiver ID and
/// command type are retained as route evidence alongside the existing DUML
/// frame shape; sequence allocation remains exclusively in Pocket3Datalink.
public struct Pocket3LiveViewSessionCommand: Codable, Sendable, Equatable {
    public static let preEnableHintPayload = Data([0x08])
    public static let enablePayload = Data([
        0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x05, 0x01
    ])
    public static let requestIDRPayload = Data([
        0x00, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ])

    public let kind: Pocket3LiveViewSessionCommandKind
    public let frame: NativeCommandFrame
    public let receiverType: UInt8
    public let receiverID: UInt8
    public let commandType: UInt8

    public init(kind: Pocket3LiveViewSessionCommandKind) throws {
        self.kind = kind
        switch kind {
        case .preEnableHint:
            frame = try NativeCommandFrame(
                source: 0x02, destination: 0x01, flags: 0x40,
                commandSet: 0x02, commandID: 0x68,
                payload: Self.preEnableHintPayload)
            receiverType = 0x01
            receiverID = 0x01
            commandType = 0x02
        case .enable:
            frame = try NativeCommandFrame(
                source: 0x02, destination: 0x01, flags: 0x40,
                commandSet: 0x01, commandID: 0x01,
                payload: Self.enablePayload)
            receiverType = 0x01
            receiverID = 0x00
            commandType = 0x00
        case .requestIDR:
            frame = try NativeCommandFrame(
                source: 0x02, destination: 0x01, flags: 0x40,
                commandSet: 0x09, commandID: 0xa8,
                payload: Self.requestIDRPayload)
            receiverType = 0x01
            receiverID = 0x02
            commandType = 0x02
        }
    }

    public var commandSet: UInt8 { frame.commandSet }
    public var commandID: UInt8 { frame.commandID }
    public var payload: Data { frame.payload }

    public func request(
        generation: UInt64,
        sessionID: UUID,
        timeout: TimeInterval = 2
    ) throws -> NativeCommandTransactionRequest {
        let command: NativeCameraSessionCommand
        switch kind {
        case .preEnableHint: command = .livePreviewHint
        case .enable: command = .livePreviewEnable
        case .requestIDR: command = .livePreviewIDR
        }
        return try NativeCommandTransactionRequest(
            command: command, generation: generation, sessionID: sessionID,
            frame: frame, timeout: timeout)
    }
}

public typealias Pocket3LiveViewCommand = Pocket3LiveViewSessionCommand

/// A single command attempt retained in the final developer result.  ACK is
/// transport evidence only; it does not certify that a decoder produced a
/// frame or that a camera UI mode changed.
public struct Pocket3LiveViewCommandEvidence: Codable, Sendable, Equatable {
    public let kind: Pocket3LiveViewSessionCommandKind
    public let requestID: UUID?
    public let generation: UInt64
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let end: NativeCommandTransactionEnd?
    public let responseStatus: UInt8?
    public let failureCode: String?

    public init(
        kind: Pocket3LiveViewSessionCommandKind,
        generation: UInt64,
        requestID: UUID? = nil,
        requested: Bool = true,
        submitted: Bool = false,
        acknowledged: Bool = false,
        observed: Bool = false,
        end: NativeCommandTransactionEnd? = nil,
        responseStatus: UInt8? = nil,
        failureCode: String? = nil
    ) {
        self.kind = kind
        self.requestID = requestID
        self.generation = generation
        self.requested = requested
        self.submitted = submitted
        self.acknowledged = acknowledged
        self.observed = observed
        self.end = end
        self.responseStatus = responseStatus
        self.failureCode = failureCode.map { String($0.prefix(128)) }
    }

    public init(kind: Pocket3LiveViewSessionCommandKind,
                transaction: NativeCommandTransactionResult) {
        self.init(kind: kind, generation: transaction.generation,
                  requestID: transaction.id, requested: transaction.requested,
                  submitted: transaction.submitted,
                  acknowledged: transaction.acknowledged,
                  observed: transaction.observed, end: transaction.end,
                  responseStatus: transaction.responseStatus,
                  failureCode: transaction.failureCode)
    }

    public var accepted: Bool { submitted && acknowledged }
}

public enum Pocket3LiveViewSessionPhase: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable {
    case idle
    case ingesting
    case hinting
    case enabling
    case requestingIDR
    case waitingForCodec
    case waitingForFirstRandomAccess
    case ready
    case warning
    case degraded
    case stalled
    case cooldown
    case cancelled
    case disconnected
    case generationChanged
    case failed
}

public enum Pocket3LiveViewStallStage: String, Codable, Sendable,
    Equatable, CaseIterable {
    case none
    case awaitingCodec
    case awaitingFirstRandomAccess
    case warning
    case degraded
    case stalled
}

public struct Pocket3LiveViewSessionConfiguration: Codable, Sendable,
    Equatable {
    public static let defaultCooldown: TimeInterval = 3
    public static let defaultWarningAfter: TimeInterval = 0.75
    public static let defaultDegradedAfter: TimeInterval = 1.5
    public static let defaultStalledAfter: TimeInterval = 3
    public static let defaultMaximumMediaAge: TimeInterval = 5

    public let sendPreEnableHint: Bool
    public let cooldown: TimeInterval
    public let warningAfter: TimeInterval
    public let degradedAfter: TimeInterval
    public let stalledAfter: TimeInterval
    public let maximumMediaAge: TimeInterval
    public let commandTimeout: TimeInterval

    public static let `default` = Self()

    public init(
        sendPreEnableHint: Bool = false,
        cooldown: TimeInterval = Self.defaultCooldown,
        warningAfter: TimeInterval = Self.defaultWarningAfter,
        degradedAfter: TimeInterval = Self.defaultDegradedAfter,
        stalledAfter: TimeInterval = Self.defaultStalledAfter,
        maximumMediaAge: TimeInterval = Self.defaultMaximumMediaAge,
        commandTimeout: TimeInterval = 2
    ) {
        self.sendPreEnableHint = sendPreEnableHint
        self.cooldown = cooldown
        self.warningAfter = warningAfter
        self.degradedAfter = degradedAfter
        self.stalledAfter = stalledAfter
        self.maximumMediaAge = maximumMediaAge
        self.commandTimeout = commandTimeout
    }

    fileprivate var isValid: Bool {
        cooldown.isFinite && cooldown >= 1 && cooldown <= 60 &&
            warningAfter.isFinite && warningAfter > 0 &&
            degradedAfter.isFinite && degradedAfter >= warningAfter &&
            stalledAfter.isFinite && stalledAfter >= degradedAfter &&
            maximumMediaAge.isFinite && maximumMediaAge > 0 &&
            commandTimeout.isFinite && commandTimeout > 0 &&
            commandTimeout <= NativeCommandTransactionRequest.maximumTimeout
    }
}

public enum Pocket3LiveViewSessionCoordinatorError: Error, Sendable,
    Equatable {
    case invalidConfiguration
    case invalidClock
    case sessionNotReady
    case missingSessionIdentity
    case routeUnavailable(String)
    case cooldown(until: TimeInterval)
    case busy
    case ingestRequired
    case alreadyStarted
    case staleGeneration
}

/// A serializable projection used by developer diagnostics and fake tests.
public struct Pocket3LiveViewSessionSnapshot: Codable, Sendable,
    Equatable {
    public let sessionID: UUID?
    public let generation: UInt64
    public let phase: Pocket3LiveViewSessionPhase
    public let stallStage: Pocket3LiveViewStallStage
    public let stallAge: TimeInterval?
    public let mediaIngested: Bool
    public let codecReady: Bool
    public let firstRandomAccessObserved: Bool
    public let enableSendCount: Int
    public let idrRequestSendCount: Int
    public let enableUptime: TimeInterval?
    public let lastMediaUptime: TimeInterval?
    public let cooldownUntil: TimeInterval?
    public let routeAllowed: Bool
    public let routeState: Pocket3DatalinkRouteState?
    public let failureCode: String?
}

public struct Pocket3LiveViewSessionResult: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let generation: UInt64
    public let phase: Pocket3LiveViewSessionPhase
    public let stallStage: Pocket3LiveViewStallStage
    public let mediaIngested: Bool
    public let codecReady: Bool
    public let firstRandomAccessObserved: Bool
    public let hint: Pocket3LiveViewCommandEvidence?
    public let enable: Pocket3LiveViewCommandEvidence?
    public let idr: Pocket3LiveViewCommandEvidence?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let ready: Bool
    public let failureCode: String?

    public init(
        sessionID: UUID,
        generation: UInt64,
        phase: Pocket3LiveViewSessionPhase,
        stallStage: Pocket3LiveViewStallStage,
        mediaIngested: Bool,
        codecReady: Bool,
        firstRandomAccessObserved: Bool,
        hint: Pocket3LiveViewCommandEvidence?,
        enable: Pocket3LiveViewCommandEvidence?,
        idr: Pocket3LiveViewCommandEvidence?,
        failureCode: String?
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.phase = phase
        self.stallStage = stallStage
        self.mediaIngested = mediaIngested
        self.codecReady = codecReady
        self.firstRandomAccessObserved = firstRandomAccessObserved
        self.hint = hint
        self.enable = enable
        self.idr = idr
        let attempts = [hint, enable, idr].compactMap { $0 }
        self.requested = !attempts.isEmpty
        self.submitted = attempts.contains { $0.submitted }
        self.acknowledged = attempts.contains { $0.acknowledged }
        self.ready = phase == .ready
        self.failureCode = failureCode
    }
}

/// Developer-only live-view lifecycle coordinator.  It begins by attaching
/// the already-created passive media source, requires one current media
/// observation before enabling, sends at most one optional hint, one enable,
/// and one 09/A8 IDR request, then only observes media/watchdog state.
public final class Pocket3LiveViewSessionCoordinator: @unchecked Sendable {
    public let configuration: Pocket3LiveViewSessionConfiguration

    private let clock: any Pocket3LiveViewClock
    private let mediaSource: any Pocket3LiveViewMediaSource
    private let executor: any Pocket3LiveViewCommandExecutor
    private let lock = NSLock()

    private var session: NativeCameraSessionStatus?
    private var routePlan: Pocket3DatalinkRoutePlan?
    private var generation: UInt64 = 0
    private var phase: Pocket3LiveViewSessionPhase = .idle
    private var stallStage: Pocket3LiveViewStallStage = .none
    private var mediaIngested = false
    private var codecReady = false
    private var firstRandomAccessObserved = false
    private var enableUptime: TimeInterval?
    private var lastMediaUptime: TimeInterval?
    private var cooldownUntil: TimeInterval?
    private var enableSendCount = 0
    private var idrRequestSendCount = 0
    private var hintEvidence: Pocket3LiveViewCommandEvidence?
    private var enableEvidence: Pocket3LiveViewCommandEvidence?
    private var idrEvidence: Pocket3LiveViewCommandEvidence?
    private var failureCode: String?
    private var attemptID: UUID?

    public init(
        mediaSource: any Pocket3LiveViewMediaSource,
        executor: any Pocket3LiveViewCommandExecutor,
        clock: any Pocket3LiveViewClock = SystemPocket3LiveViewClock(),
        configuration: Pocket3LiveViewSessionConfiguration = .default
    ) throws {
        guard configuration.isValid else {
            throw Pocket3LiveViewSessionCoordinatorError.invalidConfiguration
        }
        self.mediaSource = mediaSource
        self.executor = executor
        self.clock = clock
        self.configuration = configuration
    }

    public var currentGeneration: UInt64 {
        lock.withLock { generation }
    }

    /// Start an ingest lifecycle. This method attaches/reset-fences the
    /// passive source and sends no command. A fresh observation must be fed by
    /// ``observeMedia`` or ``ingestLatestMedia`` before ``enableIfReady``.
    @discardableResult
    public func begin(
        session: NativeCameraSessionStatus,
        routePlan: Pocket3DatalinkRoutePlan? = nil,
        nowUptime: TimeInterval? = nil
    ) throws -> Pocket3LiveViewSessionSnapshot {
        let now = try validNow(nowUptime)
        guard session.generation != 0 else {
            throw Pocket3LiveViewSessionCoordinatorError.sessionNotReady
        }
        guard session.state.satisfies(.commandReady) else {
            throw Pocket3LiveViewSessionCoordinatorError.sessionNotReady
        }
        guard session.sessionID != nil else {
            throw Pocket3LiveViewSessionCoordinatorError.missingSessionIdentity
        }
        if let routePlan {
            guard routePlan.allowed,
                  routePlan.status.state != .unknown else {
                throw Pocket3LiveViewSessionCoordinatorError.routeUnavailable(
                    routePlan.failureCode ?? "native_route_unvalidated")
            }
        }

        let state = lock.withLock { (generation, phase, cooldownUntil) }
        let activePhases: Set<Pocket3LiveViewSessionPhase> = [
            .ingesting, .hinting, .enabling, .requestingIDR,
            .waitingForCodec, .waitingForFirstRandomAccess, .ready,
            .warning, .degraded, .stalled
        ]
        if state.0 == session.generation && activePhases.contains(state.1) {
            throw Pocket3LiveViewSessionCoordinatorError.busy
        }
        if let cooldownUntil = state.2,
           state.0 == session.generation, now < cooldownUntil {
            throw Pocket3LiveViewSessionCoordinatorError.cooldown(
                until: cooldownUntil)
        }
        if state.0 != 0, state.0 != session.generation {
            mediaSource.flush(generation: state.0)
        }
        mediaSource.attach(generation: session.generation)

        lock.withLock {
            self.session = session
            self.routePlan = routePlan
            generation = session.generation
            phase = .ingesting
            stallStage = .none
            mediaIngested = false
            codecReady = false
            firstRandomAccessObserved = false
            enableUptime = nil
            lastMediaUptime = nil
            cooldownUntil = nil
            enableSendCount = 0
            idrRequestSendCount = 0
            hintEvidence = nil
            enableEvidence = nil
            idrEvidence = nil
            failureCode = nil
            attemptID = nil
        }
        return snapshot(nowUptime: now)
    }

    public typealias PrepareResult = Pocket3LiveViewSessionSnapshot

    @discardableResult
    public func prepare(
        session: NativeCameraSessionStatus,
        routePlan: Pocket3DatalinkRoutePlan? = nil,
        nowUptime: TimeInterval? = nil
    ) throws -> Pocket3LiveViewSessionSnapshot {
        try begin(session: session, routePlan: routePlan,
                  nowUptime: nowUptime)
    }

    /// Feed one source observation.  Pre-enable observations satisfy only the
    /// ingest barrier; codec/random-access readiness is counted only after the
    /// single enable has been acknowledged.
    @discardableResult
    public func observeMedia(
        _ observation: Pocket3LiveViewMediaObservation,
        nowUptime: TimeInterval? = nil
    ) -> Bool {
        let now = nowUptime ?? clock.now
        guard now.isFinite, now >= 0, observation.receivedUptime.isFinite,
              observation.receivedUptime >= 0, now >= observation.receivedUptime else {
            return false
        }
        lock.lock()
        guard generation != 0, observation.generation == generation,
              phase != .idle, phase != .disconnected,
              phase != .cancelled, phase != .cooldown,
              phase != .generationChanged else {
            lock.unlock()
            return false
        }
        mediaIngested = true
        lastMediaUptime = observation.receivedUptime
        let enabledAt = enableUptime
        let afterEnable = enabledAt.map {
            observation.receivedUptime >= $0 &&
                now - observation.receivedUptime <= configuration.maximumMediaAge
        } == true
        if afterEnable {
            codecReady = codecReady || observation.codecReady
            firstRandomAccessObserved = firstRandomAccessObserved ||
                (observation.codecReady && observation.hasRandomAccessPoint)
            if firstRandomAccessObserved {
                phase = .ready
                stallStage = .none
                failureCode = nil
            } else if codecReady {
                phase = .waitingForFirstRandomAccess
                stallStage = .awaitingFirstRandomAccess
            } else {
                phase = .waitingForCodec
                stallStage = .awaitingCodec
            }
        }
        lock.unlock()
        return true
    }

    /// Explicitly pull the newest observation from the existing sink.  This is
    /// a read-only poll; it does not start a timer or resend a command.
    @discardableResult
    public func ingestLatestMedia(nowUptime: TimeInterval? = nil) -> Bool {
        guard let observation = mediaSource.latestMediaObservation() else {
            return false
        }
        return observeMedia(observation, nowUptime: nowUptime)
    }

    public typealias ObserveResult = Pocket3LiveViewSessionSnapshot

    /// Send the bounded start sequence once after ingest.  A failed hint is
    /// retained as partial evidence because it is optional; enable and IDR
    /// failures are terminal for this attempt and are never retried.
    public func enableIfReady(
        nowUptime: TimeInterval? = nil
    ) async throws -> Pocket3LiveViewSessionResult {
        let now = try validNow(nowUptime)
        let attempt: (id: UUID, generation: UInt64,
                      session: NativeCameraSessionStatus)? = lock.withLock {
            guard phase == .ingesting else {
                if phase == .cooldown, let cooldownUntil, now < cooldownUntil {
                    return nil
                }
                return nil
            }
            guard mediaIngested, let lastMediaUptime,
                  now >= lastMediaUptime,
                  now - lastMediaUptime <= configuration.maximumMediaAge,
                  let session else { return nil }
            let id = UUID()
            attemptID = id
            phase = configuration.sendPreEnableHint ? .hinting : .enabling
            return (id, generation, session)
        }
        guard let attempt else {
            let current = lock.withLock { phase }
            if current == .cooldown, let until = lock.withLock({ cooldownUntil }) {
                throw Pocket3LiveViewSessionCoordinatorError.cooldown(until: until)
            }
            if current == .ingesting {
                throw Pocket3LiveViewSessionCoordinatorError.ingestRequired
            }
            throw Pocket3LiveViewSessionCoordinatorError.busy
        }

        if configuration.sendPreEnableHint {
            let hint = await execute(.preEnableHint, attempt: attempt)
            let current = lock.withLock { () -> Bool in
                guard isCurrentAttemptLocked(attempt.id, generation: attempt.generation) else {
                    if generation == attempt.generation, hint.submitted {
                        hintEvidence = hint
                    }
                    return false
                }
                hintEvidence = hint
                phase = .enabling
                return true
            }
            guard current else { return currentResult() }
        }

        let enable = await execute(.enable, attempt: attempt)
        let acceptedEnable = lock.withLock { () -> Bool in
            guard generation == attempt.generation else {
                return false
            }
            guard isCurrentAttemptLocked(attempt.id, generation: attempt.generation) else {
                if enable.submitted {
                    enableEvidence = enable
                    enableSendCount += 1
                    let sentAt = max(now, clock.now)
                    enableUptime = sentAt
                    lastMediaUptime = sentAt
                    cooldownUntil = sentAt + configuration.cooldown
                }
                return false
            }
            enableEvidence = enable
            if enable.submitted {
                enableSendCount += 1
                let sentAt = max(now, clock.now)
                enableUptime = sentAt
                lastMediaUptime = sentAt
                cooldownUntil = sentAt + configuration.cooldown
            }
            guard enable.accepted else {
                phase = .failed
                failureCode = enable.failureCode ?? "live_view_enable_not_acknowledged"
                attemptID = nil
                return false
            }
            codecReady = false
            firstRandomAccessObserved = false
            stallStage = .awaitingCodec
            phase = .requestingIDR
            return true
        }
        guard acceptedEnable else {
            if !isCurrentAttempt(attempt) { return currentResult() }
            return currentResult()
        }

        let idr = await execute(.requestIDR, attempt: attempt)
        lock.withLock {
            guard generation == attempt.generation else {
                return
            }
            guard isCurrentAttemptLocked(attempt.id, generation: attempt.generation) else {
                if idr.submitted {
                    idrEvidence = idr
                    idrRequestSendCount += 1
                }
                return
            }
            idrEvidence = idr
            idrRequestSendCount += idr.submitted ? 1 : 0
            phase = .waitingForCodec
            stallStage = .awaitingCodec
            if !idr.accepted {
                failureCode = idr.failureCode ?? "live_view_idr_request_not_acknowledged"
            }
            attemptID = nil
        }
        return currentResult()
    }

    public func enable(nowUptime: TimeInterval? = nil) async throws
        -> Pocket3LiveViewSessionResult {
        try await enableIfReady(nowUptime: nowUptime)
    }

    /// Advance the watchdog ladder.  This method only updates typed state;
    /// it never sends another 09/A8 request.
    @discardableResult
    public func tick(nowUptime: TimeInterval? = nil)
        -> Pocket3LiveViewSessionSnapshot {
        let now = nowUptime ?? clock.now
        guard now.isFinite, now >= 0 else {
            lock.withLock { failureCode = "live_view_invalid_clock" }
            return snapshot(nowUptime: nil)
        }
        lock.lock()
        guard let enabledAt = enableUptime,
              phase != .idle, phase != .disconnected,
              phase != .cancelled, phase != .cooldown,
              phase != .generationChanged else {
            lock.unlock()
            return snapshot(nowUptime: now)
        }
        let reference = lastMediaUptime ?? enabledAt
        let age = max(0, now - reference)
        if age >= configuration.stalledAfter {
            stallStage = .stalled
            phase = .stalled
        } else if age >= configuration.degradedAfter {
            stallStage = .degraded
            phase = .degraded
        } else if age >= configuration.warningAfter {
            stallStage = .warning
            phase = .warning
        } else if firstRandomAccessObserved {
            stallStage = .none
            phase = .ready
        } else if codecReady {
            stallStage = .awaitingFirstRandomAccess
            phase = .waitingForFirstRandomAccess
        } else {
            stallStage = .awaitingCodec
            phase = .waitingForCodec
        }
        lock.unlock()
        return snapshot(nowUptime: now)
    }

    /// Cancel and flush the current media generation.  In-flight command
    /// results are fenced after their awaited executor call returns.
    @discardableResult
    public func cancel(
        generation callbackGeneration: UInt64,
        nowUptime: TimeInterval? = nil
    ) -> Pocket3LiveViewSessionSnapshot {
        let now = nowUptime ?? clock.now
        let shouldFlush = lock.withLock { () -> Bool in
            guard generation != 0, generation == callbackGeneration else { return false }
            attemptID = nil
            phase = .cancelled
            failureCode = "cancelled"
            return true
        }
        if shouldFlush { mediaSource.flush(generation: callbackGeneration) }
        return snapshot(nowUptime: now)
    }

    /// Disconnect has no live-view STOP write in this foundation.  It only
    /// fences the generation, flushes the sink/decoder, and records cooldown.
    @discardableResult
    public func disconnect(
        generation callbackGeneration: UInt64,
        nowUptime: TimeInterval? = nil
    ) -> Pocket3LiveViewSessionSnapshot {
        let now = nowUptime ?? clock.now
        let shouldFlush = lock.withLock { () -> Bool in
            guard generation != 0, generation == callbackGeneration else { return false }
            attemptID = nil
            if let enabledAt = enableUptime {
                let until = enabledAt + configuration.cooldown
                cooldownUntil = until
                phase = now < until ? .cooldown : .disconnected
            } else {
                cooldownUntil = nil
                phase = .disconnected
            }
            failureCode = "disconnected"
            return true
        }
        if shouldFlush { mediaSource.flush(generation: callbackGeneration) }
        return snapshot(nowUptime: now)
    }

    public func stop(generation callbackGeneration: UInt64,
                     nowUptime: TimeInterval? = nil)
        -> Pocket3LiveViewSessionSnapshot {
        disconnect(generation: callbackGeneration, nowUptime: nowUptime)
    }

    public func snapshot(nowUptime: TimeInterval? = nil)
        -> Pocket3LiveViewSessionSnapshot {
        let now = nowUptime ?? clock.now
        return lock.withLock {
            let age: TimeInterval? = if let reference = lastMediaUptime ?? enableUptime,
                                        now.isFinite, now >= reference {
                now - reference
            } else { nil }
            return Pocket3LiveViewSessionSnapshot(
                sessionID: session?.sessionID, generation: generation,
                phase: phase, stallStage: stallStage, stallAge: age,
                mediaIngested: mediaIngested, codecReady: codecReady,
                firstRandomAccessObserved: firstRandomAccessObserved,
                enableSendCount: enableSendCount,
                idrRequestSendCount: idrRequestSendCount,
                enableUptime: enableUptime, lastMediaUptime: lastMediaUptime,
                cooldownUntil: cooldownUntil,
                routeAllowed: routePlan?.allowed ?? true,
                routeState: routePlan?.status.state,
                failureCode: failureCode)
        }
    }

    public var result: Pocket3LiveViewSessionResult? {
        currentResultOptional()
    }

    private func execute(
        _ kind: Pocket3LiveViewSessionCommandKind,
        attempt: (id: UUID, generation: UInt64,
                  session: NativeCameraSessionStatus)
    ) async -> Pocket3LiveViewCommandEvidence {
        let command: Pocket3LiveViewSessionCommand
        let request: NativeCommandTransactionRequest
        do {
            command = try Pocket3LiveViewSessionCommand(kind: kind)
            guard let sessionID = attempt.session.sessionID else {
                return Pocket3LiveViewCommandEvidence(
                    kind: kind, generation: attempt.generation,
                    failureCode: "native_session_identity_missing")
            }
            request = try command.request(
                generation: attempt.generation, sessionID: sessionID,
                timeout: configuration.commandTimeout)
        } catch {
            return Pocket3LiveViewCommandEvidence(
                kind: kind, generation: attempt.generation,
                failureCode: Self.errorCode(error))
        }
        do {
            let transaction = try await executor.execute(
                request, readiness: attempt.session)
            guard transaction.id == request.id,
                  transaction.generation == attempt.generation,
                  transaction.command == request.command else {
                return Pocket3LiveViewCommandEvidence(
                    kind: kind, generation: attempt.generation,
                    requestID: request.id,
                    failureCode: "live_view_command_correlation_failed")
            }
            return Pocket3LiveViewCommandEvidence(
                kind: kind, transaction: transaction)
        } catch {
            return Pocket3LiveViewCommandEvidence(
                kind: kind, generation: attempt.generation,
                requestID: request.id, failureCode: Self.errorCode(error))
        }
    }

    private func isCurrentAttempt(
        _ attempt: (id: UUID, generation: UInt64,
                    session: NativeCameraSessionStatus)
    ) -> Bool {
        lock.withLock {
            isCurrentAttemptLocked(attempt.id, generation: attempt.generation)
        }
    }

    private func isCurrentAttemptLocked(_ id: UUID, generation expected: UInt64)
        -> Bool {
        attemptID == id && generation == expected &&
            phase != .cancelled && phase != .disconnected &&
            phase != .generationChanged
    }

    private func currentResult() -> Pocket3LiveViewSessionResult {
        currentResultOptional() ?? Pocket3LiveViewSessionResult(
            sessionID: UUID(), generation: 0, phase: .idle,
            stallStage: .none, mediaIngested: false, codecReady: false,
            firstRandomAccessObserved: false, hint: nil, enable: nil,
            idr: nil, failureCode: "live_view_session_missing")
    }

    private func currentResultOptional() -> Pocket3LiveViewSessionResult? {
        lock.withLock {
            guard let sessionID = session?.sessionID, generation != 0 else {
                return nil
            }
            return Pocket3LiveViewSessionResult(
                sessionID: sessionID, generation: generation,
                phase: phase, stallStage: stallStage,
                mediaIngested: mediaIngested, codecReady: codecReady,
                firstRandomAccessObserved: firstRandomAccessObserved,
                hint: hintEvidence, enable: enableEvidence,
                idr: idrEvidence, failureCode: failureCode)
        }
    }

    private func validNow(_ value: TimeInterval?) throws -> TimeInterval {
        let now = value ?? clock.now
        guard now.isFinite, now >= 0 else {
            throw Pocket3LiveViewSessionCoordinatorError.invalidClock
        }
        return now
    }

    private static func errorCode(_ error: Error) -> String {
        if let error = error as? NativeCommandTransactionError {
            switch error {
            case .invalidPayload: return "native_command_invalid_payload"
            case .invalidTimeout: return "native_command_invalid_timeout"
            case .commandNotReady: return "native_command_not_ready"
            case .staleGeneration: return "native_command_generation_changed"
            case .datalinkUnavailable: return "native_datalink_unavailable"
            case .nativeBusy: return "native_busy"
            }
        }
        if let error = error as? Pocket3LiveViewSessionCoordinatorError {
            switch error {
            case .invalidConfiguration: return "live_view_invalid_configuration"
            case .invalidClock: return "live_view_invalid_clock"
            case .sessionNotReady: return "native_session_not_ready"
            case .missingSessionIdentity: return "native_session_identity_missing"
            case .routeUnavailable(let code): return String(code.prefix(128))
            case .cooldown: return "live_view_cooldown"
            case .busy: return "live_view_busy"
            case .ingestRequired: return "live_view_ingest_required"
            case .alreadyStarted: return "live_view_already_started"
            case .staleGeneration: return "live_view_generation_changed"
            }
        }
        return String(String(describing: error).prefix(128))
    }
}

/// Adapter for the already-owned Pocket3Datalink plus the existing passive
/// sink.  It attaches/detaches by exact generation and delegates commands to
/// `Pocket3Datalink.transact`; it never calls connect, joins Wi-Fi, or creates
/// another datalink owner.
public final class Pocket3LiveViewDatalinkAdapter: @unchecked Sendable,
    Pocket3LiveViewMediaSource, Pocket3LiveViewCommandExecutor {
    public let datalink: Pocket3Datalink
    public let sink: Pocket3LiveViewMediaSink

    private let lock = NSLock()
    private var attachment: Pocket3DatalinkLiveViewSinkToken?
    private var transportGeneration: UInt64?
    private var logicalGeneration: UInt64?

    public init(datalink: Pocket3Datalink,
                sink: Pocket3LiveViewMediaSink) {
        self.datalink = datalink
        self.sink = sink
    }

    @discardableResult
    public func attach(binding: ContinuousGimbalBinding)
        -> Pocket3DatalinkLiveViewSinkToken {
        let token = datalink.attachLiveViewSink(sink, binding: binding)
        lock.withLock {
            attachment = token
            transportGeneration = binding.generation
            logicalGeneration = nil
        }
        return token
    }

    public func attach(generation: UInt64) {
        let physical = lock.withLock {
            transportGeneration ?? generation
        }
        let token = datalink.attachLiveViewSink(sink, generation: physical)
        lock.withLock {
            attachment = token
            transportGeneration = physical
            logicalGeneration = generation
        }
    }

    /// Bind the transport token to the native-session generation used by
    /// command/readiness requests.  Pocket3Datalink and NativeCameraSession
    /// intentionally have independent counters; this mapping keeps both
    /// fences exact without pretending they are the same counter.
    @discardableResult
    public func attach(binding: ContinuousGimbalBinding,
                       logicalGeneration: UInt64)
        -> Pocket3DatalinkLiveViewSinkToken {
        let token = attach(binding: binding)
        lock.withLock { self.logicalGeneration = logicalGeneration }
        return token
    }

    public func flush(generation: UInt64) {
        let token = lock.withLock { () -> Pocket3DatalinkLiveViewSinkToken? in
            guard let attachment,
                  logicalGeneration == generation ||
                  (logicalGeneration == nil && attachment.generation == generation) else {
                return nil
            }
            self.attachment = nil
            transportGeneration = nil
            logicalGeneration = nil
            return attachment
        }
        if let token {
            datalink.detachLiveViewSink(token)
        } else {
            sink.flush(generation: generation)
        }
    }

    public func latestMediaObservation()
        -> Pocket3LiveViewMediaObservation? {
        guard let observation = sink.latestMediaObservation() else {
            return nil
        }
        guard let logical = lock.withLock({ logicalGeneration }) else {
            return observation
        }
        return Pocket3LiveViewMediaObservation(
            generation: logical, messageID: observation.messageID,
            codec: observation.codec, codecReady: observation.codecReady,
            hasRandomAccessPoint: observation.hasRandomAccessPoint,
            receivedUptime: observation.receivedUptime)
    }

    public func execute(
        _ request: NativeCommandTransactionRequest,
        readiness: NativeCameraSessionStatus
    ) async throws -> NativeCommandTransactionResult {
        try await datalink.transact(request, readiness: readiness)
    }
}

public typealias Pocket3LiveViewDatalinkSessionAdapter = Pocket3LiveViewDatalinkAdapter
