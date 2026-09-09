import Foundation

public struct USBContinuousGimbalFeedback: Sendable {
    public let capabilities: UVCCapabilities
    /// Conservative monotonic timestamp: the start of the corresponding
    /// GET_CUR, not when a slow request finally returned.
    public let observedAt: TimeInterval
    public init(capabilities: UVCCapabilities, observedAt: TimeInterval) {
        self.capabilities = capabilities; self.observedAt = observedAt
    }
}

/// Held input becomes successive absolute UVC targets. This does not provide
/// native USB velocity or a mechanical emergency stop. The injected I/O must
/// retain one attachment and finish under its own bounded request deadlines.
public actor USBContinuousGimbalTransport: ContinuousGimbalInputTransport {
    public typealias Start = @Sendable (ContinuousGimbalLease, OperationPermit) async throws -> Void
    public typealias Continue = @Sendable (ContinuousGimbalLease) async throws -> Void
    public typealias Read = @Sendable (ContinuousGimbalLease) async throws -> USBContinuousGimbalFeedback
    public typealias Write = @Sendable (GimbalPosition, ContinuousGimbalLease, TimeInterval, OperationPermit) async throws -> Void
    public typealias Stopped = @Sendable (ContinuousGimbalLease, MotionResult) async -> Void

    public let binding: ContinuousGimbalBinding
    public private(set) var lastStop: MotionResult?
    private let onStart: Start
    private let onContinue: Continue
    private let read: Read
    private let write: Write
    private let onStop: Stopped
    private let clock: any ContinuousGimbalClock
    private var activeLease: ContinuousGimbalLease?
    private var claimedLease: ContinuousGimbalLease?
    // Never evict retired IDs during this endpoint's connection lifetime:
    // eviction would let an old delayed callback resurrect a retired gesture.
    private var retired = Set<UUID>()
    private var planner: USBPositionTrajectory?
    private var plannedMinimum: GimbalPosition?
    private var plannedMaximum: GimbalPosition?
    private var pending: Task<Void, Error>?
    private var pendingID: UUID?
    private var pendingPermit: OperationPermit?
    private var cleanup: Task<Void, Error>?
    private var stoppingLease: ContinuousGimbalLease?
    private var lastStoppedLease: ContinuousGimbalLease?
    private var lastStopFailure: BridgeFailure?

    public init(binding: ContinuousGimbalBinding, onStart: @escaping Start,
                onContinue: @escaping Continue = { _ in },
                read: @escaping Read, write: @escaping Write, onStop: @escaping Stopped,
                clock: any ContinuousGimbalClock = SystemContinuousGimbalClock()) {
        self.binding = binding; self.onStart = onStart; self.onContinue = onContinue; self.read = read
        self.write = write; self.onStop = onStop; self.clock = clock
    }

    public func send(_ input: ContinuousGimbalInput, lease: ContinuousGimbalLease, permit: OperationPermit) async throws {
        try Task.checkCancellation()
        try validate(lease)
        guard !retired.contains(lease.id) else { throw ContinuousGimbalError.staleLease }
        guard pending == nil, cleanup == nil, activeLease == nil || activeLease == lease else {
            throw ContinuousGimbalError.busy
        }
        try permit.perform {}
        activeLease = lease
        let operation = UUID()
        let task = Task(priority: .userInitiated) { try await self.performSend(input, lease: lease, permit: permit) }
        pendingID = operation; pending = task; pendingPermit = permit
        defer {
            if pendingID == operation { pending = nil; pendingID = nil; pendingPermit = nil }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            permit.invalidate(); task.cancel()
        }
    }

    /// Retires the exact gesture before waiting for its in-flight operation.
    /// Cleanup survives cancellation of the caller and never redirects to a
    /// newer gesture/connection. A centered stick uses send(.neutral) instead.
    public func stop(lease: ContinuousGimbalLease, permit: OperationPermit) async throws {
        try validate(lease)
        if stoppingLease == lease, let cleanup { return try await cleanup.value }
        if lastStoppedLease == lease {
            if let lastStopFailure { throw lastStopFailure }
            return
        }
        guard activeLease == nil || activeLease == lease else { throw ContinuousGimbalError.staleLease }
        guard !retired.contains(lease.id) else { throw ContinuousGimbalError.staleLease }
        retired.insert(lease.id)
        stoppingLease = lease
        pendingPermit?.invalidate()
        pending?.cancel()
        let inFlight = pending
        let task = Task(priority: .userInitiated) {
            _ = await inFlight?.result
            try await self.performStop(lease, permit: permit)
        }
        cleanup = task
        // Do not propagate this caller's cancellation into independent cleanup.
        try await task.value
    }

    private func validate(_ lease: ContinuousGimbalLease) throws {
        guard !binding.sessionID.isEmpty, lease.binding == binding else { throw ContinuousGimbalError.invalidSession }
    }

    private func requireLive(_ lease: ContinuousGimbalLease, permit: OperationPermit) throws {
        try Task.checkCancellation()
        guard activeLease == lease, !retired.contains(lease.id) else { throw ContinuousGimbalError.staleLease }
        try permit.perform {}
    }

    private func fresh(_ feedback: USBContinuousGimbalFeedback, maximumAge: TimeInterval) throws {
        let now = clock.now
        guard now.isFinite, feedback.observedAt.isFinite, feedback.observedAt <= now,
              now - feedback.observedAt <= maximumAge else {
            throw BridgeFailure("usb_feedback_stale", "USB 位置回讀已過期，沒有送出目標")
        }
        let caps = feedback.capabilities
        guard caps.writable, let low = caps.minimum, let high = caps.maximum,
              low.pan <= high.pan, low.tilt <= high.tilt,
              caps.position.pan >= low.pan, caps.position.pan <= high.pan,
              caps.position.tilt >= low.tilt, caps.position.tilt <= high.tilt else {
            throw BridgeFailure("usb_feedback_invalid", "USB 位置或控制範圍無效")
        }
    }

    private func performSend(_ input: ContinuousGimbalInput, lease: ContinuousGimbalLease, permit: OperationPermit) async throws {
        try requireLive(lease, permit: permit)
        if claimedLease == nil {
            try await onStart(lease, permit)
            // onStart commits service ownership on success. Record that fact
            // before checking cancellation, so Stop can always release it.
            claimedLease = lease
            lastStop = nil; lastStopFailure = nil
        }
        try requireLive(lease, permit: permit)
        try await onContinue(lease)
        try requireLive(lease, permit: permit)
        let feedback = try await read(lease)
        try requireLive(lease, permit: permit)
        try fresh(feedback, maximumAge: 0.25)
        let caps = feedback.capabilities, now = clock.now
        let neutral = input.isNeutral || hypot(input.x, input.y) <= 0.06
        let target: GimbalPosition
        if neutral {
            // A neutral stick is a fresh absolute hold, never centre and never
            // lease retirement. Do not run a settle loop every scheduler tick.
            planner = nil; plannedMinimum = nil; plannedMaximum = nil
            target = caps.position
        } else {
            if planner == nil {
                planner = try USBPositionTrajectory(capabilities: caps, now: now)
                plannedMinimum = caps.minimum; plannedMaximum = caps.maximum
            }
            guard caps.minimum == plannedMinimum, caps.maximum == plannedMaximum else {
                throw BridgeFailure("usb_capabilities_changed", "USB 控制範圍已改變，請重新開始操作")
            }
            target = try planner!.advance(x: input.x, y: input.y, speed: input.speed, now: now,
                                          observed: caps.position, observedAt: feedback.observedAt)
        }
        let validUntil = min(feedback.observedAt + 0.25, now + 0.10)
        try requireLive(lease, permit: permit)
        // The injected write must repeat binding, deadline, and permit checks
        // at the actual synchronous setFast call, after any actor queue wait.
        try await write(target, lease, validUntil, permit)
        try requireLive(lease, permit: permit)
    }

    private func performStop(_ lease: ContinuousGimbalLease, permit: OperationPermit) async throws {
        var target: GimbalPosition?, observed: GimbalPosition?
        var submitted = false
        var failure: BridgeFailure?
        var verified = false
        let owned = claimedLease == lease
        if owned {
            do {
                let feedback = try await read(lease)
                try fresh(feedback, maximumAge: 0.10)
                target = feedback.capabilities.position; observed = target
                try await write(feedback.capabilities.position, lease, feedback.observedAt + 0.10, permit)
                submitted = true
                let submittedAt = clock.now, deadline = submittedAt + 1.2
                var samples: [(position: GimbalPosition, time: TimeInterval)] = []
                var previousReadAt = submittedAt
                for _ in 0..<10 {
                    try await clock.sleep(until: clock.now + 0.10)
                    if clock.now > deadline { break }
                    let next = try await read(lease)
                    try fresh(next, maximumAge: 0.10)
                    observed = next.capabilities.position
                    guard clock.now <= deadline, next.observedAt > previousReadAt else {
                        throw BridgeFailure("usb_stop_feedback_stale", "停止回讀沒有提供新的位置樣本")
                    }
                    previousReadAt = next.observedAt
                    samples.append((next.capabilities.position, next.observedAt))
                    if samples.count > 3 { samples.removeFirst() }
                    if samples.count == 3, samples[2].time - samples[0].time >= 0.20 - 1e-9 {
                        let panSpan = Int64(samples.map(\.position.pan).max()!) - Int64(samples.map(\.position.pan).min()!)
                        let tiltSpan = Int64(samples.map(\.position.tilt).max()!) - Int64(samples.map(\.position.tilt).min()!)
                        if max(panSpan, tiltSpan) <= 360,
                           samples.allSatisfy({ $0.position.distance(to: feedback.capabilities.position) <= 1080 }) {
                            verified = true; break
                        }
                    }
                }
                if !verified { throw BridgeFailure("usb_stop_unverified", "保持目標已送出，但停止回讀未穩定") }
            } catch {
                failure = (error as? BridgeFailure) ?? BridgeFailure("usb_stop_failed", "USB 停止未確認")
            }
        }
        let result = MotionResult(accepted: submitted || !owned, completed: verified || !owned,
            verified: verified || !owned,
            verification: owned ? "hold_current_target_and_stable_uvc_readback" : "no_active_usb_motion",
            target: target, observed: observed,
            message: owned ? (verified ? "已保持新鮮回讀位置；不是裝置端緊急停止命令" : "USB 停止未確認") : "此手勢未取得 USB 控制權，已退休")
        lastStop = result; lastStoppedLease = lease; lastStopFailure = failure
        // Keep the transport busy until the service has released this exact
        // gesture, including when read/hold/verification failed.
        if owned { await onStop(lease, result) }
        if claimedLease == lease { claimedLease = nil }
        if activeLease == lease { activeLease = nil }
        planner = nil; plannedMinimum = nil; plannedMaximum = nil
        pending = nil; pendingID = nil; pendingPermit = nil
        stoppingLease = nil; cleanup = nil
        if let failure { throw failure }
    }
}
