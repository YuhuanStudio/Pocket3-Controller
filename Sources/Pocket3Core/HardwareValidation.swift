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
}

public enum HardwareValidator {
    public static let version = 4
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
                            && motionProgress(axis: axis, origin: $0.origin, held: $0.held, target: $0.requested) >= 720
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
        private var previous: GimbalPosition?
        private var consecutiveStable = 0
        private(set) var observed: GimbalPosition
        var stable: Bool { consecutiveStable >= 3 }
        init(target: GimbalPosition) { self.target = target; observed = target }
        mutating func record(_ position: GimbalPosition) {
            observed = position
            if observed.distance(to: target) <= 1080, let previous, observed.distance(to: previous) <= 360 {
                consecutiveStable += 1
            } else { consecutiveStable = 0 }
            previous = observed
        }
    }
    private static func settled(_ uvc: UVCConnection, at target: GimbalPosition) async throws -> Settlement {
        var result = Settlement(target: target)
        for _ in 0..<35 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(80))
            result.record(try await uvc.status().position)
            if result.stable { return result }
        }
        // A near-target last sample is not evidence that settling succeeded.
        return result
    }
    /// A bounded laboratory sequence, called only while the service owns an
    /// exclusive validation session. No continuous-speed command is used.
    public static func run(uvc: UVCConnection, deviceID: String, frames: FrameStore) async throws -> HardwareValidationReport {
        let cap = try await uvc.status()
        guard cap.registryID != nil && cap.bootSessionID != nil else { throw BridgeFailure("hardware_identity", "無法確認目前的 USB 連接身分，不能保存移動驗證") }
        let original = cap.position
        guard let min = cap.minimum, let max = cap.maximum else { throw BridgeFailure("validation_range", "No UVC range") }
        // Begin from an observed stable pose. A first frame after connecting
        // does not establish that the gimbal has finished its own startup.
        let baseline = try await settled(uvc, at: original)
        guard baseline.stable else { throw BridgeFailure("validation_unstable", "雲台尚未穩定，請稍後再開始控制驗證") }
        var positions: [PositionTrial] = [], stops: [StopTrial] = [], images: [String: Data] = [:]
        func save(_ name: String) { if let frame = try? frames.latest(), let data = try? frame.jpeg(maxDimension: 960) { images[name] = data } }
        do {
            save("before")
            for axis in ["pan", "tilt"] {
                for index in 0..<20 {
                    let target = try boundedOffset(axis: axis, delta: 3600, origin: original, minimum: min, maximum: max)
                    try await uvc.set(target)
                    let observed = try await settled(uvc, at: target)
                    positions.append(PositionTrial(axis: axis, iteration: index, target: target, observed: observed.observed, residual: observed.observed.distance(to: target), stable: observed.stable, passed: observed.stable && observed.observed.distance(to: target) <= 1080))
                    if index == 0 { save(axis + "-moved") }
                    try await uvc.set(original)
                    let restored = try await settled(uvc, at: original)
                    positions.append(PositionTrial(axis: axis + "-return", iteration: index, target: original, observed: restored.observed, residual: restored.observed.distance(to: original), stable: restored.stable, passed: restored.stable && restored.observed.distance(to: original) <= 1080))
                }
                // Five nominal UVC degrees creates time to request a hold before
                // a finite target. Do not confuse a completed target with a stop.
                for repetition in 0..<3 {
                  for delay in [30, 60, 100, 150] {
                    let target = try boundedOffset(axis: axis, delta: 18000, origin: original, minimum: min, maximum: max)
                    try await uvc.set(target)
                    try await Task.sleep(for: .milliseconds(delay))
                    let held = try await uvc.status().position
                    try await uvc.set(held)
                    let final = try await settled(uvc, at: held)
                    save(axis + "-stop-\(repetition)-\(delay)")
                    try await uvc.set(original)
                    let restored = try await settled(uvc, at: original)
                    stops.append(StopTrial(axis: axis, iteration: repetition, delayMS: delay, origin: original, requested: target, held: held, final: final.observed, interruptedBeforeTarget: remainingDistance(axis: axis, origin: original, final: final.observed, target: target) > 3600, motionWasObserved: motionProgress(axis: axis, origin: original, held: held, target: target) >= 720, holdResidual: final.observed.distance(to: held), stable: final.stable, restoredPosition: restored.observed, restorationStable: restored.stable, restorationResidual: restored.observed.distance(to: original)))
                  }
                }
            }
            let final = try await uvc.status().position
            save("restored")
            let stopPassed = stoppingPassed(stops)
            return HardwareValidationReport(version: version, date: Date(), deviceID: deviceID, registryID: cap.registryID, bootSessionID: cap.bootSessionID, osVersion: ProcessInfo.processInfo.operatingSystemVersionString, original: original, final: final, positionTrials: positions, stopTrials: stops, stopPassed: stopPassed, positionPassed: positionsPassed(positions), restored: stops.last?.restorationStable == true && final.distance(to: original) <= 1080, images: images)
        } catch {
            if !Task.isCancelled { try? await uvc.set(original) }
            throw error
        }
    }
}
