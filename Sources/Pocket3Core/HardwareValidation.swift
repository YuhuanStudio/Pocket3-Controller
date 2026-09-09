import Foundation

public struct PositionTrial: Codable, Sendable {
    public var axis: String
    public var iteration: Int
    public var target: GimbalPosition
    public var observed: GimbalPosition
    public var residual: Int64
    public var stable: Bool
    public var passed: Bool
}
public struct StopTrial: Codable, Sendable {
    public var axis: String
    public var iteration: Int
    public var delayMS: Int
    public var origin: GimbalPosition
    public var requested: GimbalPosition
    public var held: GimbalPosition
    public var final: GimbalPosition
    public var interruptedBeforeTarget: Bool
    public var motionWasObserved: Bool
    public var holdResidual: Int64
    public var stable: Bool
    public var restoredPosition: GimbalPosition
    public var restorationStable: Bool
    public var restorationResidual: Int64
    /// Fresh measured pose immediately before this trial's target SET. The
    /// global origin remains the restoration target; its tolerance is not motion.
    public var motionOrigin: GimbalPosition? = nil
}
/// Best-effort hold at a newly read current pose. This never means return-to-origin.
public struct HardwareValidationCleanup: Codable, Sendable {
    public var attempted: Bool
    public var writeSubmitted: Bool
    public var target: GimbalPosition?
    public var observed: GimbalPosition?
    public var stable: Bool
    public var residual: Int64?
    public var failureCode: String?
}
public struct HardwareValidationReport: Codable, Sendable {
    public var version: Int
    public var date: Date
    public var deviceID: String
    public var registryID: String?
    public var bootSessionID: String?
    public var osVersion: String
    public var original: GimbalPosition
    public var final: GimbalPosition
    public var positionTrials: [PositionTrial]
    public var stopTrials: [StopTrial]
    public var stopPassed: Bool
    public var positionPassed: Bool
    public var restored: Bool
    public var images: [String: Data]
    public var profile: String? = nil
    public var failedStage: String? = nil
    public var failureCode: String? = nil
    public var cancelled: Bool? = nil
    public var cleanup: HardwareValidationCleanup? = nil
}

public enum HardwareValidator {
    public static let version = 5
    public static let profile = "finite_absolute_pan_tilt_positive_offsets_v1"

    /// Injectable transport only; the public entry point always uses the real UVC actor.
    struct IO: Sendable {
        var status: @Sendable () async throws -> UVCCapabilities
        var set: @Sendable (GimbalPosition) async throws -> Void
        var hold: @Sendable (GimbalPosition) async throws -> Void
        var sleep: @Sendable (Int) async throws -> Void
    }
    /// One acceptance gate for live completion and persisted proof reuse.
    static func accepts(_ report: HardwareValidationReport) -> Bool {
        func matches(_ position: GimbalPosition, axis: String, delta: Int64) -> Bool {
            Int64(position.pan) == Int64(report.original.pan) + (axis == "pan" ? delta : 0)
                && Int64(position.tilt) == Int64(report.original.tilt) + (axis == "tilt" ? delta : 0)
        }
        return report.version == version && report.profile == profile && report.cancelled == false
            && report.failedStage == nil && report.failureCode == nil && report.cleanup == nil
            && report.stopPassed && report.positionPassed && report.restored
            && positionsPassed(report.positionTrials) && stoppingPassed(report.stopTrials)
            && report.final.distance(to: report.original) <= 1080
            && report.positionTrials.allSatisfy {
                switch $0.axis {
                case "pan", "tilt": matches($0.target, axis: $0.axis, delta: 3600)
                case "pan-return", "tilt-return": $0.target == report.original
                default: false
                }
            }
            && report.stopTrials.allSatisfy {
                $0.origin == report.original && matches($0.requested, axis: $0.axis, delta: 18000)
                    && $0.motionOrigin.map { $0.distance(to: report.original) <= 1080 } == true
            }
    }
    static func positionsPassed(_ trials: [PositionTrial]) -> Bool {
        guard trials.count == 80, trials.allSatisfy({
            $0.stable && $0.passed && $0.residual == $0.observed.distance(to: $0.target) && $0.residual <= 1080
        }) else { return false }
        return ["pan", "pan-return", "tilt", "tilt-return"].allSatisfy { axis in
            let group = trials.filter { $0.axis == axis }
            return group.count == 20 && Set(group.map(\.iteration)) == Set(0..<20)
        }
    }
    static func stoppingPassed(_ trials: [StopTrial]) -> Bool {
        guard trials.count == 24, trials.allSatisfy({
            $0.stable && $0.holdResidual == $0.final.distance(to: $0.held) && $0.holdResidual <= 1080
                && $0.restorationStable && $0.restorationResidual == $0.restoredPosition.distance(to: $0.origin)
                && $0.restorationResidual <= 1080
        }) else { return false }
        return ["pan", "tilt"].allSatisfy { axis in
            (0..<3).allSatisfy { iteration in
                let group = trials.filter { $0.axis == axis && $0.iteration == iteration }
                return group.count == 4 && Set(group.map(\.delayMS)) == [30, 60, 100, 150]
                    && group.contains {
                        $0.motionWasObserved && $0.interruptedBeforeTarget
                            && motionProgress(axis: axis, origin: $0.motionOrigin ?? $0.origin, held: $0.held, target: $0.requested) >= 720
                            && remainingDistance(axis: axis, origin: $0.origin, final: $0.final, target: $0.requested) > 3600
                    }
            }
        }
    }
    /// Only progress towards the commanded target counts as interrupted motion.
    /// Readback jitter or movement on the other axis is not stopping evidence.
    public static func motionProgress(axis: String, origin: GimbalPosition, held: GimbalPosition, target: GimbalPosition) -> Int64 {
        guard axis == "pan" || axis == "tilt" else { return 0 }
        let start = Int64(axis == "pan" ? origin.pan : origin.tilt)
        let current = Int64(axis == "pan" ? held.pan : held.tilt)
        let end = Int64(axis == "pan" ? target.pan : target.tilt)
        return (current - start) * (end >= start ? 1 : -1)
    }
    /// Positive only while the tested axis remains before its commanded target.
    /// Orthogonal movement and overshoot cannot demonstrate an interrupted move.
    static func remainingDistance(axis: String, origin: GimbalPosition, final: GimbalPosition, target: GimbalPosition) -> Int64 {
        guard axis == "pan" || axis == "tilt" else { return 0 }
        let start = Int64(axis == "pan" ? origin.pan : origin.tilt)
        let current = Int64(axis == "pan" ? final.pan : final.tilt)
        let end = Int64(axis == "pan" ? target.pan : target.tilt)
        guard end != start else { return 0 }
        return (end - current) * (end > start ? 1 : -1)
    }
    static func boundedOffset(axis: String, delta: Int32, origin: GimbalPosition, minimum: GimbalPosition, maximum: GimbalPosition) throws -> GimbalPosition {
        guard axis == "pan" || axis == "tilt" else { throw BridgeFailure("validation_axis", "Unknown validation axis") }
        let pan = Int64(origin.pan) + (axis == "pan" ? Int64(delta) : 0)
        let tilt = Int64(origin.tilt) + (axis == "tilt" ? Int64(delta) : 0)
        guard pan >= Int64(minimum.pan), pan <= Int64(maximum.pan), tilt >= Int64(minimum.tilt), tilt <= Int64(maximum.tilt) else { throw BridgeFailure("validation_range", "Insufficient range for a bounded test") }
        return GimbalPosition(pan: Int32(pan), tilt: Int32(tilt))
    }
    struct Settlement {
        let target: GimbalPosition
        private var window: [GimbalPosition] = []
        private(set) var observed: GimbalPosition
        var stable: Bool { window.count >= 4 }
        init(target: GimbalPosition) { self.target = target; observed = target }
        mutating func record(_ position: GimbalPosition) {
            observed = position
            guard observed.distance(to: target) <= 1080 else { window = []; return }
            // Four samples retain the original three comparisons, but the
            // whole window must stay within 360. A slow ramp is not stability.
            if window.allSatisfy({ observed.distance(to: $0) <= 360 }) { window.append(observed) }
            else { window = [observed] }
            if window.count > 4 { window.removeFirst() }
        }
    }
    private static func readPosition(_ io: IO, binding: UVCCapabilities) async throws -> GimbalPosition {
        let current = try await io.status()
        guard current.registryID == binding.registryID, current.bootSessionID == binding.bootSessionID else {
            throw BridgeFailure("uvc_attachment_changed", "USB 連接已改變，停止控制驗證")
        }
        guard current.writable, current.minimum == binding.minimum, current.maximum == binding.maximum,
              current.step == binding.step else {
            throw BridgeFailure("validation_capabilities_changed", "USB 控制範圍已改變，停止控制驗證")
        }
        return current.position
    }
    private static func settled(_ io: IO, at target: GimbalPosition, binding: UVCCapabilities) async throws -> Settlement {
        var result = Settlement(target: target)
        for _ in 0..<35 {
            try Task.checkCancellation()
            try await io.sleep(80)
            result.record(try await readPosition(io, binding: binding))
            if result.stable { return result }
        }
        // A near-target last sample is not evidence that settling succeeded.
        return result
    }
    private static func failureCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        return (error as? BridgeFailure)?.code ?? "validation_transport"
    }
    private static func holdCurrent(_ io: IO, binding: UVCCapabilities, permit: OperationPermit) async -> HardwareValidationCleanup {
        var cleanup = HardwareValidationCleanup(attempted: false, writeSubmitted: false, stable: false)
        guard permit.isValid else {
            cleanup.failureCode = "cancelled"
            return cleanup
        }
        do {
            let current = try await readPosition(io, binding: binding)
            cleanup.target = current
            cleanup.observed = current
            // Exactly one independent hold attempt; never retry or restore the original pose.
            cleanup.attempted = true
            try await io.hold(current)
            cleanup.writeSubmitted = true
            let held = try await settled(io, at: current, binding: binding)
            cleanup.observed = held.observed
            cleanup.stable = held.stable
            cleanup.residual = held.observed.distance(to: current)
            if !held.stable { cleanup.failureCode = "validation_cleanup_unsettled" }
        } catch { cleanup.failureCode = failureCode(error) }
        return cleanup
    }
    private static func interruptedMotion(_ trial: StopTrial) -> Bool {
        trial.motionWasObserved && trial.interruptedBeforeTarget
            && motionProgress(axis: trial.axis, origin: trial.motionOrigin ?? trial.origin, held: trial.held, target: trial.requested) >= 720
            && remainingDistance(axis: trial.axis, origin: trial.origin, final: trial.final, target: trial.requested) > 3600
    }
    /// A bounded laboratory sequence, called only while the service owns an
    /// exclusive validation session. No continuous-speed command is used.
    /// Reports contain control metadata only; camera images are not retained.
    public static func run(uvc: UVCConnection, deviceID: String, frames: FrameStore,
                           permit: OperationPermit = OperationPermit()) async throws -> HardwareValidationReport {
        try await run(io: IO(status: { try await uvc.status() }, set: { try await uvc.set($0, permit: permit) },
                            hold: { try await uvc.setFast($0, validUntil: ProcessInfo.processInfo.systemUptime + 0.25, permit: permit) },
                            sleep: { try await Task.sleep(for: .milliseconds($0)) }), deviceID: deviceID, permit: permit)
    }
    static func run(io: IO, deviceID: String, permit: OperationPermit = OperationPermit()) async throws -> HardwareValidationReport {
        let cap = try await io.status()
        guard let registry = cap.registryID, !registry.isEmpty,
              let boot = cap.bootSessionID, !boot.isEmpty else {
            throw BridgeFailure("hardware_identity", "無法確認目前的 USB 連接身分，不能保存移動驗證")
        }
        let original = cap.position
        guard cap.writable, let min = cap.minimum, let max = cap.maximum else {
            throw BridgeFailure("validation_range", "No writable UVC range")
        }
        // Reject impossible sequences before issuing any target.
        for axis in ["pan", "tilt"] {
            _ = try boundedOffset(axis: axis, delta: 3600, origin: original, minimum: min, maximum: max)
            _ = try boundedOffset(axis: axis, delta: 18000, origin: original, minimum: min, maximum: max)
        }
        var report = HardwareValidationReport(version: version, date: Date(), deviceID: deviceID,
            registryID: registry, bootSessionID: boot, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            original: original, final: original, positionTrials: [], stopTrials: [], stopPassed: false,
            positionPassed: false, restored: false, images: [:], profile: profile, cancelled: false)
        var stage = "baseline"
        do {
            let baseline = try await settled(io, at: original, binding: cap)
            report.final = baseline.observed
            guard baseline.stable else { throw BridgeFailure("validation_unstable", "雲台尚未穩定，請稍後再開始控制驗證") }
            for axis in ["pan", "tilt"] {
                for index in 0..<20 {
                    let target = try boundedOffset(axis: axis, delta: 3600, origin: original, minimum: min, maximum: max)
                    for (name, position) in [(axis, target), (axis + "-return", original)] {
                        stage = "position.\(name).\(index)"
                        try Task.checkCancellation()
                        try await io.set(position)
                        let result = try await settled(io, at: position, binding: cap)
                        report.final = result.observed
                        let residual = result.observed.distance(to: position)
                        let passed = result.stable && residual <= 1080
                        report.positionTrials.append(PositionTrial(axis: name, iteration: index, target: position,
                            observed: result.observed, residual: residual, stable: result.stable, passed: passed))
                        guard passed else { throw BridgeFailure("validation_position_unsettled", "位置未穩定，已停止後續驗證") }
                    }
                }
                for repetition in 0..<3 {
                    let groupStart = report.stopTrials.count
                    for delay in [30, 60, 100, 150] {
                        stage = "stop.\(axis).\(repetition).\(delay).target"
                        let target = try boundedOffset(axis: axis, delta: 18000, origin: original, minimum: min, maximum: max)
                        try Task.checkCancellation()
                        let motionOrigin = try await readPosition(io, binding: cap)
                        guard motionOrigin.distance(to: original) <= 1080 else {
                            throw BridgeFailure("validation_origin_changed", "停止試驗前的位置已改變")
                        }
                        try await io.set(target)
                        try await io.sleep(delay)
                        stage = "stop.\(axis).\(repetition).\(delay).hold"
                        let held = try await readPosition(io, binding: cap)
                        report.final = held
                        try Task.checkCancellation()
                        try await io.set(held)
                        let final = try await settled(io, at: held, binding: cap)
                        report.final = final.observed
                        var trial = StopTrial(axis: axis, iteration: repetition, delayMS: delay, origin: original,
                            requested: target, held: held, final: final.observed,
                            interruptedBeforeTarget: remainingDistance(axis: axis, origin: original, final: final.observed, target: target) > 3600,
                            motionWasObserved: motionProgress(axis: axis, origin: motionOrigin, held: held, target: target) >= 720,
                            holdResidual: final.observed.distance(to: held), stable: final.stable,
                            restoredPosition: final.observed, restorationStable: false,
                            restorationResidual: final.observed.distance(to: original), motionOrigin: motionOrigin)
                        report.stopTrials.append(trial)
                        guard trial.stable && trial.holdResidual <= 1080 else {
                            throw BridgeFailure("validation_hold_unsettled", "停止位置未穩定，已停止後續驗證")
                        }
                        stage = "stop.\(axis).\(repetition).\(delay).return"
                        try Task.checkCancellation()
                        try await io.set(original)
                        let restored = try await settled(io, at: original, binding: cap)
                        report.final = restored.observed
                        trial.restoredPosition = restored.observed
                        trial.restorationStable = restored.stable
                        trial.restorationResidual = restored.observed.distance(to: original)
                        report.stopTrials[report.stopTrials.count - 1] = trial
                        guard trial.restorationStable && trial.restorationResidual <= 1080 else {
                            throw BridgeFailure("validation_return_unsettled", "返回位置未穩定，已停止後續驗證")
                        }
                    }
                    // A 30 ms hold may precede physical movement. Require interrupted
                    // motion only after all four holds and returns have been verified.
                    stage = "stop.\(axis).\(repetition).interruption"
                    guard report.stopTrials[groupStart...].contains(where: interruptedMotion) else {
                        throw BridgeFailure("validation_no_interrupted_motion", "此組未觀察到移動中停止，已停止後續驗證")
                    }
                }
            }
            stage = "final"
            try Task.checkCancellation()
            report.final = try await readPosition(io, binding: cap)
            try Task.checkCancellation()
            guard report.final.distance(to: original) <= 1080 else {
                throw BridgeFailure("validation_final_drift", "驗證後位置已改變")
            }
            report.stopPassed = stoppingPassed(report.stopTrials)
            report.positionPassed = positionsPassed(report.positionTrials)
            report.restored = report.stopTrials.last?.restorationStable == true
            return report
        } catch {
            report.failedStage = stage
            report.failureCode = failureCode(error)
            report.cancelled = Task.isCancelled || report.failureCode == "cancelled"
            // Await independent cleanup so cancellation cannot skip the physical hold.
            // The service retains its validation session until this task completes.
            let cleanup = await Task.detached { await holdCurrent(io, binding: cap, permit: permit) }.value
            report.cleanup = cleanup
            if let observed = cleanup.observed { report.final = observed }
            return report
        }
    }
}
