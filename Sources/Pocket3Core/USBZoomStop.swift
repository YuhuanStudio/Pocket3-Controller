import Foundation

public struct USBZoomStopResult: Codable, Sendable, Equatable {
    /// True only when the hold request completed successfully. A transport
    /// error can leave submission uncertain; false never means a verified stop.
    public let submitted: Bool
    public let target: Int?
    public let observed: Int?
    public let verified: Bool
    public let sampleCount: Int
    public let failure: String?
    public let verification: String
    public let toleranceRaw: Int?
    public let stableDurationSeconds: TimeInterval?

    public init(submitted: Bool, target: Int?, observed: Int?, verified: Bool,
                sampleCount: Int = 0, failure: String? = nil, toleranceRaw: Int = 0,
                stableDurationSeconds: TimeInterval = 0) {
        self.submitted = submitted; self.target = target; self.observed = observed
        self.verified = verified; self.sampleCount = sampleCount; self.failure = failure
        verification = "fresh_uvc_zoom_hold_with_advertised_tolerance"
        self.toleranceRaw = toleranceRaw; self.stableDurationSeconds = stableDurationSeconds
    }

    static func combining(_ motion: MotionResult, zoom: USBZoomStopResult?) -> MotionResult {
        guard let zoom else { return motion }
        var result = motion
        result.zoomStop = zoom
        result.completed = motion.completed && zoom.verified
        result.verified = motion.verified && zoom.verified
        result.verification = "active_control_and_zoom_hold_readback"
        switch (motion.verified, zoom.verified) {
        case (true, true): result.message = "雲台與縮放回讀已穩定；不是裝置端緊急停止命令"
        case (true, false): result.message = "雲台回讀已穩定，縮放停止未確認"
        case (false, true): result.message = "縮放回讀已穩定，雲台停止未確認"
        case (false, false): result.message = "雲台與縮放停止未確認"
        }
        return result
    }
}

/// Called from independent Stop cleanup, with one retained UVC connection.
/// Read/write closures allow deterministic tests without touching hardware.
enum USBZoomStopOperation {
    static func perform(
        read: @escaping @Sendable () async throws -> USBZoomCapabilities,
        write: @escaping @Sendable (Int, TimeInterval, OperationPermit) async throws -> Void,
        clock: any ContinuousGimbalClock = SystemContinuousGimbalClock()
    ) async -> USBZoomStopResult {
        var target: Int?, observed: Int?, submitted = false, samples = 0, tolerance = 0
        var stableDuration: TimeInterval = 0
        do {
            let started = clock.now
            let fresh = try await read()
            observed = fresh.current; target = fresh.current
            guard started.isFinite, clock.now.isFinite, clock.now >= started, clock.now - started <= 0.10 else {
                throw BridgeFailure("zoom_stop_feedback_stale", "縮放停止回讀已過期")
            }
            try USBZoomPolicy.validate(fresh.current, capabilities: fresh)
            // Longer than the old 3-sample check: a bounded late observation
            // must still be settled, rather than briefly crossing the target.
            var verifier = try USBZoomReadbackVerifier(target: fresh.current, capabilities: fresh, minimumDuration: 0.8)
            tolerance = verifier.toleranceRaw
            try await write(fresh.current, started + 0.10, OperationPermit())
            submitted = true
            let deadline = clock.now + 1.2
            for _ in 0..<16 {
                try await clock.sleep(until: clock.now + 0.08)
                guard clock.now <= deadline else { break }
                let readStarted = clock.now
                let next = try await read()
                observed = next.current; samples += 1
                guard clock.now >= readStarted, clock.now - readStarted <= 0.10, clock.now <= deadline else {
                    throw BridgeFailure("zoom_stop_feedback_stale", "縮放停止回讀已過期")
                }
                let settled = try verifier.observe(next, at: readStarted)
                stableDuration = verifier.stableDurationSeconds
                if settled {
                    return USBZoomStopResult(submitted: true, target: target, observed: observed, verified: true, sampleCount: samples,
                        toleranceRaw: tolerance, stableDurationSeconds: stableDuration)
                }
            }
            throw BridgeFailure("zoom_stop_unverified", "縮放保持目標已送出，但回讀尚未穩定")
        } catch {
            return USBZoomStopResult(submitted: submitted, target: target, observed: observed, verified: false,
                sampleCount: samples, failure: (error as? BridgeFailure)?.code ?? (error is CancellationError ? "cancelled" : "zoom_stop_failed"),
                toleranceRaw: tolerance, stableDurationSeconds: stableDuration)
        }
    }
}
