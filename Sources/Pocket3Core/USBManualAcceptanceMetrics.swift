import Foundation

/// A deliberately non-operational acceptance schema for the current manual
/// USB path. A driver outside this module can record status/metrics into these
/// values; this module only evaluates the evidence and never opens UVC.
public enum USBManualAcceptanceAxis: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable {
    case pan
    case tilt
    case zoom
}

public enum USBManualAcceptanceProfile: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable {
    case near
    case far
}

public struct USBManualAcceptanceBinding: Codable, Sendable,
    Equatable, Hashable {
    public let deviceID: String
    public let captureSessionID: String
    public let registryID: String
    public let bootSessionID: String

    public init(deviceID: String, captureSessionID: String,
                registryID: String, bootSessionID: String) {
        self.deviceID = deviceID
        self.captureSessionID = captureSessionID
        self.registryID = registryID
        self.bootSessionID = bootSessionID
    }

    public var isComplete: Bool {
        [deviceID, captureSessionID, registryID, bootSessionID]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public struct USBManualFrameEvidence: Codable, Sendable,
    Equatable, Hashable {
    public let frameID: String
    public let sessionID: String
    public let deviceID: String
    public let receivedUptime: TimeInterval
    public let sampledUptime: TimeInterval
    public let age: TimeInterval
    public let width: Int
    public let height: Int

    public init(frameID: String, sessionID: String, deviceID: String,
                receivedUptime: TimeInterval, sampledUptime: TimeInterval,
                age: TimeInterval, width: Int, height: Int) {
        self.frameID = frameID
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.receivedUptime = receivedUptime
        self.sampledUptime = sampledUptime
        self.age = age
        self.width = width
        self.height = height
    }

    public func isFresh(for binding: USBManualAcceptanceBinding,
                        maximumAge: TimeInterval = 1) -> Bool {
        !frameID.isEmpty && sessionID == binding.captureSessionID &&
            deviceID == binding.deviceID &&
            receivedUptime.isFinite && sampledUptime.isFinite &&
            age.isFinite && age >= 0 && age <= maximumAge &&
            sampledUptime >= receivedUptime &&
            sampledUptime - receivedUptime <= maximumAge &&
            width > 0 && height > 0
    }
}

public struct USBManualPositionSample: Codable, Sendable,
    Equatable {
    public let elapsed: TimeInterval
    public let position: GimbalPosition
    public let frame: USBManualFrameEvidence
    public let phase: String
    public let motionActive: Bool

    public init(elapsed: TimeInterval, position: GimbalPosition,
                frame: USBManualFrameEvidence, phase: String,
                motionActive: Bool) {
        self.elapsed = elapsed
        self.position = position
        self.frame = frame
        self.phase = phase
        self.motionActive = motionActive
    }
}

public struct USBManualStopEvidence: Codable, Sendable,
    Equatable {
    public let submitted: Bool
    public let verified: Bool
    public let motionStopped: Bool
    public let held: GimbalPosition?
    public let final: GimbalPosition?
    /// Zoom stop evidence uses these raw fields; position fields stay nil for
    /// a scalar UVC zoom operation.
    public let heldRaw: Int?
    public let finalRaw: Int?
    public let stableSampleCount: Int
    public let stableDurationSeconds: TimeInterval
    public let failureCode: String?

    public init(submitted: Bool, verified: Bool, motionStopped: Bool,
                held: GimbalPosition? = nil, final: GimbalPosition? = nil,
                heldRaw: Int? = nil, finalRaw: Int? = nil,
                stableSampleCount: Int = 0,
                stableDurationSeconds: TimeInterval = 0,
                failureCode: String? = nil) {
        self.submitted = submitted
        self.verified = verified
        self.motionStopped = motionStopped
        self.held = held
        self.final = final
        self.heldRaw = heldRaw
        self.finalRaw = finalRaw
        self.stableSampleCount = stableSampleCount
        self.stableDurationSeconds = stableDurationSeconds
        self.failureCode = failureCode
    }
}

public struct USBManualRestoreEvidence: Codable, Sendable,
    Equatable {
    public let requested: GimbalPosition
    public let observed: GimbalPosition?
    public let submitted: Bool
    public let verified: Bool
    public let stableSampleCount: Int
    public let stableDurationSeconds: TimeInterval
    public let failureCode: String?

    public init(requested: GimbalPosition, observed: GimbalPosition? = nil,
                submitted: Bool, verified: Bool,
                stableSampleCount: Int = 0,
                stableDurationSeconds: TimeInterval = 0,
                failureCode: String? = nil) {
        self.requested = requested
        self.observed = observed
        self.submitted = submitted
        self.verified = verified
        self.stableSampleCount = stableSampleCount
        self.stableDurationSeconds = stableDurationSeconds
        self.failureCode = failureCode
    }
}

public struct USBManualGimbalHoldMetric: Codable, Sendable,
    Equatable, Identifiable {
    public let id: UUID
    public let axis: USBManualAcceptanceAxis
    /// Sign of the requested raw UVC direction: +1 or -1.
    public let direction: Int
    public let profile: USBManualAcceptanceProfile
    public let inputMagnitude: Double
    public let speed: Double
    public let holdDurationSeconds: TimeInterval
    public let origin: GimbalPosition
    public let samples: [USBManualPositionSample]
    public let stop: USBManualStopEvidence
    public let restore: USBManualRestoreEvidence

    public init(id: UUID = UUID(), axis: USBManualAcceptanceAxis,
                direction: Int, profile: USBManualAcceptanceProfile,
                inputMagnitude: Double, speed: Double,
                holdDurationSeconds: TimeInterval,
                origin: GimbalPosition,
                samples: [USBManualPositionSample],
                stop: USBManualStopEvidence,
                restore: USBManualRestoreEvidence) {
        self.id = id
        self.axis = axis
        self.direction = direction
        self.profile = profile
        self.inputMagnitude = inputMagnitude
        self.speed = speed
        self.holdDurationSeconds = holdDurationSeconds
        self.origin = origin
        self.samples = samples
        self.stop = stop
        self.restore = restore
    }
}

public struct USBManualZoomProgressSample: Codable, Sendable,
    Equatable, Hashable {
    public let elapsed: TimeInterval
    public let current: Int
    public let frame: USBManualFrameEvidence
    public let phase: String
    public let motionActive: Bool

    public init(elapsed: TimeInterval, current: Int,
                frame: USBManualFrameEvidence, phase: String,
                motionActive: Bool) {
        self.elapsed = elapsed
        self.current = current
        self.frame = frame
        self.phase = phase
        self.motionActive = motionActive
    }
}

public struct USBManualZoomMetric: Codable, Sendable,
    Equatable {
    public let origin: Int
    public let target: Int
    public let minimum: Int
    public let maximum: Int
    public let step: Int
    public let progress: [USBManualZoomProgressSample]
    public let stop: USBManualStopEvidence
    public let restore: USBManualZoomRestoreEvidence

    public init(origin: Int, target: Int, minimum: Int, maximum: Int,
                step: Int, progress: [USBManualZoomProgressSample],
                stop: USBManualStopEvidence,
                restore: USBManualZoomRestoreEvidence) {
        self.origin = origin
        self.target = target
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.progress = progress
        self.stop = stop
        self.restore = restore
    }
}

public struct USBManualZoomRestoreEvidence: Codable, Sendable,
    Equatable, Hashable {
    public let requestedRaw: Int
    public let observedRaw: Int?
    public let submitted: Bool
    public let verified: Bool
    public let stableSampleCount: Int
    public let stableDurationSeconds: TimeInterval
    public let failureCode: String?

    public init(requestedRaw: Int, observedRaw: Int? = nil,
                submitted: Bool, verified: Bool,
                stableSampleCount: Int = 0,
                stableDurationSeconds: TimeInterval = 0,
                failureCode: String? = nil) {
        self.requestedRaw = requestedRaw
        self.observedRaw = observedRaw
        self.submitted = submitted
        self.verified = verified
        self.stableSampleCount = stableSampleCount
        self.stableDurationSeconds = stableDurationSeconds
        self.failureCode = failureCode
    }
}

public struct USBManualReconnectFenceMetric: Codable, Sendable,
    Equatable, Hashable {
    public let oldBinding: USBManualAcceptanceBinding
    public let newBinding: USBManualAcceptanceBinding
    public let oldOperationStopped: Bool
    public let oldOperationSuppressed: Bool
    public let newSessionReady: Bool

    public init(oldBinding: USBManualAcceptanceBinding,
                newBinding: USBManualAcceptanceBinding,
                oldOperationStopped: Bool,
                oldOperationSuppressed: Bool,
                newSessionReady: Bool) {
        self.oldBinding = oldBinding
        self.newBinding = newBinding
        self.oldOperationStopped = oldOperationStopped
        self.oldOperationSuppressed = oldOperationSuppressed
        self.newSessionReady = newSessionReady
    }
}

public struct USBManualAcceptanceReport: Codable, Sendable,
    Equatable {
    public static let currentVersion = 1
    public static let currentProfile = "usb_manual_gimbal_zoom_metrics_v1"

    public var version: Int
    public var profile: String
    public var createdAt: Date
    public var initialBinding: USBManualAcceptanceBinding
    public var baselineFrames: [USBManualFrameEvidence]
    public var gimbalHolds: [USBManualGimbalHoldMetric]
    public var zoom: USBManualZoomMetric
    public var reconnect: USBManualReconnectFenceMetric
    public var finalBinding: USBManualAcceptanceBinding
    public var finalGimbalPosition: GimbalPosition?
    public var finalZoomRaw: Int?
    public var cameraImagesStored: Bool
    public var physicalMotionVerified: Bool

    public init(version: Int = Self.currentVersion,
                profile: String = Self.currentProfile,
                createdAt: Date = Date(),
                initialBinding: USBManualAcceptanceBinding,
                baselineFrames: [USBManualFrameEvidence],
                gimbalHolds: [USBManualGimbalHoldMetric],
                zoom: USBManualZoomMetric,
                reconnect: USBManualReconnectFenceMetric,
                finalBinding: USBManualAcceptanceBinding,
                finalGimbalPosition: GimbalPosition? = nil,
                finalZoomRaw: Int? = nil,
                cameraImagesStored: Bool = false,
                physicalMotionVerified: Bool = false) {
        self.version = version
        self.profile = profile
        self.createdAt = createdAt
        self.initialBinding = initialBinding
        self.baselineFrames = baselineFrames
        self.gimbalHolds = gimbalHolds
        self.zoom = zoom
        self.reconnect = reconnect
        self.finalBinding = finalBinding
        self.finalGimbalPosition = finalGimbalPosition
        self.finalZoomRaw = finalZoomRaw
        self.cameraImagesStored = cameraImagesStored
        self.physicalMotionVerified = physicalMotionVerified
    }
}

public struct USBManualAcceptancePlan: Codable, Sendable,
    Equatable, Hashable {
    public let version: Int
    public let profile: String
    public let stages: [String]
    public let maximumHoldSeconds: TimeInterval
    public let maximumZoomProgressSamples: Int
    public let maximumFrameAgeSeconds: TimeInterval
    public let hardwareExecutionEnabled: Bool

    public init(version: Int = USBManualAcceptanceReport.currentVersion,
                profile: String = USBManualAcceptanceReport.currentProfile,
                stages: [String], maximumHoldSeconds: TimeInterval,
                maximumZoomProgressSamples: Int,
                maximumFrameAgeSeconds: TimeInterval,
                hardwareExecutionEnabled: Bool = false) {
        self.version = version
        self.profile = profile
        self.stages = stages
        self.maximumHoldSeconds = maximumHoldSeconds
        self.maximumZoomProgressSamples = maximumZoomProgressSamples
        self.maximumFrameAgeSeconds = maximumFrameAgeSeconds
        self.hardwareExecutionEnabled = hardwareExecutionEnabled
    }
}

public struct USBManualAcceptanceEvaluation: Codable, Sendable,
    Equatable, Hashable {
    public let version: Int
    public let profile: String
    public let metricsPassed: Bool
    public let checks: [String: Bool]
    public let failureCode: String?
    public let remainingPhysicalSteps: [String]
    public let cameraImagesStored: Bool
    public let physicalMotionVerified: Bool

    public init(version: Int, profile: String, metricsPassed: Bool,
                checks: [String: Bool], failureCode: String?,
                remainingPhysicalSteps: [String],
                cameraImagesStored: Bool, physicalMotionVerified: Bool) {
        self.version = version
        self.profile = profile
        self.metricsPassed = metricsPassed
        self.checks = checks
        self.failureCode = failureCode
        self.remainingPhysicalSteps = remainingPhysicalSteps
        self.cameraImagesStored = cameraImagesStored
        self.physicalMotionVerified = physicalMotionVerified
    }
}

/// Metrics-only acceptance planner/evaluator. No method in this type has a
/// transport parameter or performs I/O, so a dry-run cannot touch hardware.
public enum USBManualAcceptanceExecutor {
    public static let maximumFrameAge: TimeInterval = 1
    public static let minimumHoldSamples = 3
    public static let minimumStopSamples = 3
    public static let minimumStopDuration: TimeInterval = 0.2
    public static let minimumZoomStopDuration: TimeInterval = 0.8
    public static let maximumHoldDuration: TimeInterval = 1.2
    public static let maximumBaselineFrames = 64
    public static let maximumHoldSamples = 24
    public static let restorationToleranceRaw: Int64 = 1080
    public static let positionJitterToleranceRaw: Int64 = 360

    public static func dryRunPlan() -> USBManualAcceptancePlan {
        .init(stages: [
            "baseline_fresh_frame",
            "pan_near_continuous_hold",
            "pan_far_continuous_hold",
            "tilt_near_continuous_hold",
            "tilt_far_continuous_hold",
            "release_and_verified_stop",
            "zoom_progress_and_verified_stop",
            "reconnect_old_session_fence",
            "restore_gimbal_and_zoom"
        ], maximumHoldSeconds: maximumHoldDuration,
        maximumZoomProgressSamples: 24,
        maximumFrameAgeSeconds: maximumFrameAge,
        hardwareExecutionEnabled: false)
    }

    public static func evaluate(
        _ report: USBManualAcceptanceReport
    ) -> USBManualAcceptanceEvaluation {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) {
            checks[name] = value
        }

        check("schema", report.version == USBManualAcceptanceReport.currentVersion &&
            report.profile == USBManualAcceptanceReport.currentProfile)
        check("metrics_only", !report.cameraImagesStored &&
            !report.physicalMotionVerified)
        check("initial_binding", report.initialBinding.isComplete)
        check("fresh_baseline_frames", baselinePassed(report))
        check("gimbal_hold_matrix", gimbalMatrixPassed(report))
        check("distance_based_speed", distanceSpeedPassed(report))
        check("zoom_progress_stop", zoomPassed(report))
        check("reconnect_session_fence", reconnectPassed(report))
        check("final_binding", report.finalBinding == report.reconnect.newBinding &&
            report.finalBinding.isComplete)
        check("restore", restorePassed(report))

        let passed = checks.values.allSatisfy { $0 }
        let failureCode: String?
        if passed {
            failureCode = nil
        } else {
            failureCode = checks.first(where: { !$0.value })?.key
        }
        return USBManualAcceptanceEvaluation(
            version: report.version, profile: report.profile,
            metricsPassed: passed, checks: checks, failureCode: failureCode,
            remainingPhysicalSteps: remainingPhysicalSteps,
            cameraImagesStored: report.cameraImagesStored,
            physicalMotionVerified: report.physicalMotionVerified)
    }

    public static let remainingPhysicalSteps: [String] = [
        "Confirm pan and tilt directions and physical angle mapping on the camera.",
        "Measure mechanical stop latency and verify release/Stop on the real unit.",
        "Confirm zoom progress changes the intended optical framing; raw UVC values are not optical magnification.",
        "Repeat reconnect during an active hold and verify the old session cannot move the new attachment.",
        "Confirm final gimbal and zoom restoration on the real unit."
    ]

    private static func baselinePassed(_ report: USBManualAcceptanceReport) -> Bool {
        guard report.baselineFrames.count >= minimumHoldSamples,
              report.baselineFrames.count <= maximumBaselineFrames else { return false }
        let IDs = Set(report.baselineFrames.map(\.frameID))
        return IDs.count >= minimumHoldSamples &&
            report.baselineFrames.allSatisfy {
                $0.isFresh(for: report.initialBinding,
                           maximumAge: maximumFrameAge)
            }
    }

    private static func gimbalMatrixPassed(
        _ report: USBManualAcceptanceReport
    ) -> Bool {
        guard report.gimbalHolds.count == 4 else { return false }
        let required = Set([
            "pan.near", "pan.far", "tilt.near", "tilt.far"
        ])
        let actual = Set(report.gimbalHolds.map {
            "\($0.axis.rawValue).\($0.profile.rawValue)"
        })
        guard actual == required else { return false }
        return report.gimbalHolds.allSatisfy {
            holdPassed($0, binding: report.initialBinding)
        }
    }

    private static func holdPassed(
        _ hold: USBManualGimbalHoldMetric,
        binding: USBManualAcceptanceBinding
    ) -> Bool {
        guard hold.direction == 1 || hold.direction == -1,
              hold.inputMagnitude.isFinite,
              (0.05...1).contains(hold.inputMagnitude),
              hold.speed.isFinite, (0...1).contains(hold.speed),
              hold.holdDurationSeconds.isFinite,
              (0.15...maximumHoldDuration).contains(hold.holdDurationSeconds),
              hold.samples.count >= minimumHoldSamples,
              hold.samples.count <= maximumHoldSamples,
              hold.stop.submitted, hold.stop.verified,
              hold.stop.motionStopped,
              hold.stop.failureCode == nil,
              hold.stop.stableSampleCount >= minimumStopSamples,
              hold.stop.stableDurationSeconds.isFinite,
              hold.stop.stableDurationSeconds >= minimumStopDuration,
              hold.stop.stableDurationSeconds <= maximumHoldDuration,
              hold.restore.submitted, hold.restore.verified,
              hold.restore.failureCode == nil,
              hold.restore.stableSampleCount >= minimumStopSamples,
              hold.restore.stableDurationSeconds.isFinite,
              hold.restore.stableDurationSeconds >= minimumStopDuration,
              hold.restore.stableDurationSeconds <= maximumHoldDuration,
              let restored = hold.restore.observed,
              restored.distance(to: hold.origin) <= restorationToleranceRaw else {
            return false
        }
        guard Set(hold.samples.map(\.frame.frameID)).count >= minimumHoldSamples else {
            return false
        }
        var previous = hold.origin
        var previousElapsed: TimeInterval = -1
        for sample in hold.samples {
            guard sample.elapsed.isFinite, sample.elapsed >= 0,
                  sample.elapsed > previousElapsed,
                  sample.elapsed <= hold.holdDurationSeconds + 0.15,
                  sample.motionActive,
                  sample.phase == "moving",
                  sample.frame.isFresh(for: binding,
                                       maximumAge: maximumFrameAge) else {
                return false
            }
            let value = axisValue(hold.axis, sample.position)
            let prior = axisValue(hold.axis, previous)
            guard (Int64(value) - Int64(prior)) * Int64(hold.direction) >=
                    -positionJitterToleranceRaw else { return false }
            let orthogonal = orthogonalValue(hold.axis, sample.position)
            let originOrthogonal = orthogonalValue(hold.axis, hold.origin)
            guard abs(Int64(orthogonal) - Int64(originOrthogonal)) <=
                    restorationToleranceRaw else { return false }
            previous = sample.position
            previousElapsed = sample.elapsed
        }
        let final = hold.samples.last!.position
        let travel = signedDistance(hold.axis, from: hold.origin, to: final,
                                    direction: hold.direction)
        guard travel > positionJitterToleranceRaw else { return false }
        if let held = hold.stop.held, let finalStop = hold.stop.final {
            guard finalStop.distance(to: held) <= restorationToleranceRaw else {
                return false
            }
        } else {
            return false
        }
        return true
    }

    private static func distanceSpeedPassed(
        _ report: USBManualAcceptanceReport
    ) -> Bool {
        for axis in [USBManualAcceptanceAxis.pan, .tilt] {
            guard let near = report.gimbalHolds.first(where: {
                $0.axis == axis && $0.profile == .near
            }), let far = report.gimbalHolds.first(where: {
                $0.axis == axis && $0.profile == .far
            }) else { return false }
            let nearTravel = signedDistance(axis, from: near.origin,
                                            to: near.samples.last!.position,
                                            direction: near.direction)
            let farTravel = signedDistance(axis, from: far.origin,
                                           to: far.samples.last!.position,
                                           direction: far.direction)
            let nearRate = Double(nearTravel) / near.holdDurationSeconds
            let farRate = Double(farTravel) / far.holdDurationSeconds
            guard far.inputMagnitude > near.inputMagnitude,
                  farTravel >= nearTravel,
                  nearRate.isFinite, farRate.isFinite,
                  farRate >= nearRate * 0.75 else { return false }
        }
        return true
    }

    private static func zoomPassed(
        _ report: USBManualAcceptanceReport
    ) -> Bool {
        let value = report.zoom
        guard value.step > 0,
              value.minimum >= 0, value.maximum <= 65_535,
              value.minimum <= value.origin,
              value.origin <= value.maximum,
              value.minimum <= value.target,
              value.target <= value.maximum,
              value.target != value.origin,
              abs(value.target - value.origin) % value.step == 0,
              abs(value.target - value.origin) >= value.step * 2,
              value.progress.count >= 2,
              value.progress.count <= 24,
              value.stop.submitted, value.stop.verified,
              value.stop.motionStopped,
              value.stop.failureCode == nil,
              value.stop.stableSampleCount >= minimumStopSamples,
              value.stop.stableDurationSeconds >= minimumZoomStopDuration,
              value.stop.stableDurationSeconds <= 1.2,
              value.restore.submitted, value.restore.verified,
              value.restore.failureCode == nil,
              value.restore.stableSampleCount >= minimumStopSamples,
              value.restore.stableDurationSeconds.isFinite,
              value.restore.stableDurationSeconds >= minimumZoomStopDuration,
              value.restore.stableDurationSeconds <= 1.2,
              value.restore.requestedRaw == value.origin,
              value.restore.observedRaw == value.origin else {
            return false
        }
        let sign = value.target > value.origin ? 1 : -1
        var previous = value.origin
        var previousElapsed: TimeInterval = -1
        var distinct = false
        var intermediate = false
        for sample in value.progress {
            guard sample.elapsed.isFinite, sample.elapsed >= 0,
                  sample.elapsed > previousElapsed,
                  sample.elapsed <= 5,
                  sample.motionActive, sample.phase == "moving",
                  sample.frame.isFresh(for: report.initialBinding,
                                       maximumAge: maximumFrameAge),
                  sample.current >= value.minimum,
                  sample.current <= value.maximum,
                  abs(sample.current - value.origin) % value.step == 0,
                  (sample.current - previous) * sign >= -value.step else {
                return false
            }
            if sample.current != previous { distinct = true }
            if (sample.current - value.origin) * sign >= value.step &&
                (value.target - sample.current) * sign >= value.step {
                intermediate = true
            }
            previous = sample.current
            previousElapsed = sample.elapsed
        }
        guard distinct, intermediate,
              let heldRaw = value.stop.heldRaw,
              let finalRaw = value.stop.finalRaw,
              abs(heldRaw - finalRaw) <= Int(restorationToleranceRaw),
              value.restore.observedRaw == value.origin else { return false }
        return true
    }

    private static func reconnectPassed(
        _ report: USBManualAcceptanceReport
    ) -> Bool {
        let fence = report.reconnect
        guard fence.oldBinding == report.initialBinding,
              fence.oldBinding.isComplete, fence.newBinding.isComplete,
              fence.newBinding.deviceID == fence.oldBinding.deviceID,
              fence.newBinding.captureSessionID != fence.oldBinding.captureSessionID,
              fence.newBinding.registryID != fence.oldBinding.registryID ||
                fence.newBinding.bootSessionID != fence.oldBinding.bootSessionID,
              fence.oldOperationStopped, fence.oldOperationSuppressed,
              fence.newSessionReady else { return false }
        return report.gimbalHolds.allSatisfy { hold in
            hold.samples.allSatisfy {
                $0.frame.sessionID == fence.oldBinding.captureSessionID
            }
        }
    }

    private static func restorePassed(
        _ report: USBManualAcceptanceReport
    ) -> Bool {
        guard let finalPosition = report.finalGimbalPosition,
              let last = report.gimbalHolds.last,
              finalPosition.distance(to: last.origin) <= restorationToleranceRaw,
              let finalZoom = report.finalZoomRaw,
              finalZoom == report.zoom.origin else { return false }
        return report.gimbalHolds.allSatisfy { hold in
            guard let observed = hold.restore.observed else { return false }
            return hold.restore.verified &&
                observed.distance(to: hold.origin) <= restorationToleranceRaw
        }
    }

    private static func axisValue(
        _ axis: USBManualAcceptanceAxis,
        _ position: GimbalPosition
    ) -> Int32 {
        axis == .pan ? position.pan : position.tilt
    }

    private static func orthogonalValue(
        _ axis: USBManualAcceptanceAxis,
        _ position: GimbalPosition
    ) -> Int32 {
        axis == .pan ? position.tilt : position.pan
    }

    private static func signedDistance(
        _ axis: USBManualAcceptanceAxis,
        from origin: GimbalPosition,
        to final: GimbalPosition,
        direction: Int
    ) -> Int64 {
        (Int64(axisValue(axis, final)) - Int64(axisValue(axis, origin))) * Int64(direction)
    }
}

public typealias Pocket3USBManualAcceptanceReport = USBManualAcceptanceReport
public typealias Pocket3USBManualAcceptanceEvaluation = USBManualAcceptanceEvaluation
public typealias Pocket3USBManualAcceptanceExecutor = USBManualAcceptanceExecutor
