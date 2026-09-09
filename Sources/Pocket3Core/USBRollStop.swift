import Foundation

public struct USBRollStopResult: Codable, Sendable, Equatable {
    public let submitted: Bool
    public let target: Int?
    public let observed: Int?
    public let verified: Bool
    public let sampleCount: Int
    public let failure: String?
    public let verification: String
    public let toleranceRaw: Int
    public let stableDurationSeconds: TimeInterval
    public init(submitted: Bool, target: Int?, observed: Int?, verified: Bool, sampleCount: Int = 0,
                failure: String? = nil, stableDurationSeconds: TimeInterval = 0) {
        self.submitted = submitted; self.target = target; self.observed = observed; self.verified = verified
        self.sampleCount = sampleCount; self.failure = failure; self.stableDurationSeconds = stableDurationSeconds
        toleranceRaw = 0; verification = "fresh_exact_uvc_roll_hold_readback"
    }
    static func combining(_ motion: MotionResult, roll: USBRollStopResult?) -> MotionResult {
        guard let roll else { return motion }
        var result = motion
        result.rollStop = roll
        result.completed = motion.completed && roll.verified
        result.verified = motion.verified && roll.verified
        result.verification = "active_control_and_roll_hold_readback"
        result.message = result.verified ? "各項作用中控制的保持回讀已穩定；不是裝置端緊急停止命令"
            : "控制停止未全部確認，請分別檢查雲台、縮放與 Roll 回讀結果"
        return result
    }
}

enum USBRollStopOperation {
    static func perform(read: @escaping @Sendable () async throws -> USBRollCapabilities,
        write: @escaping @Sendable (Int, TimeInterval, OperationPermit) async throws -> Void,
        clock: any ContinuousGimbalClock = SystemContinuousGimbalClock()) async -> USBRollStopResult {
        var target: Int?, observed: Int?, submitted = false, samples = 0
        var stableDuration: TimeInterval = 0
        do {
            let started = clock.now
            let fresh = try await read()
            target = fresh.current; observed = fresh.current
            guard started.isFinite, clock.now.isFinite, clock.now >= started, clock.now - started <= 0.10 else {
                throw BridgeFailure("roll_stop_feedback_stale", "Roll 保持回讀已過期")
            }
            var verifier = try USBRollReadbackVerifier(target: fresh.current, capabilities: fresh, minimumDuration: 0.8)
            try await write(fresh.current, started + 0.10, OperationPermit())
            submitted = true
            let deadline = clock.now + 1.2
            for _ in 0..<16 {
                try await clock.sleep(until: clock.now + 0.08)
                guard clock.now.isFinite, clock.now <= deadline else { break }
                let readStarted = clock.now
                let next = try await read()
                observed = next.current; samples += 1
                guard clock.now.isFinite, clock.now >= readStarted, clock.now - readStarted <= 0.10, clock.now <= deadline else {
                    throw BridgeFailure("roll_stop_feedback_stale", "Roll 保持回讀已過期")
                }
                let settled = try verifier.observe(next, at: readStarted)
                stableDuration = verifier.stableDurationSeconds
                if settled {
                    return USBRollStopResult(submitted: true, target: target, observed: observed, verified: true,
                        sampleCount: samples, stableDurationSeconds: stableDuration)
                }
            }
            throw BridgeFailure("roll_stop_unverified", "Roll 保持目標已送出，但精確回讀未穩定")
        } catch {
            return USBRollStopResult(submitted: submitted, target: target, observed: observed, verified: false,
                sampleCount: samples, failure: (error as? BridgeFailure)?.code ?? (error is CancellationError ? "cancelled" : "roll_stop_failed"),
                stableDurationSeconds: stableDuration)
        }
    }
}
