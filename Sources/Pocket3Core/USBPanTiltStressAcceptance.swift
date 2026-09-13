import Foundation

/// Raw UVC pan/tilt coverage used by the metrics-only stress evaluator.  The
/// values are device units; this type deliberately does not call them degrees
/// or infer a mechanical center from a camera model.
public struct USBPanTiltStressRange: Codable, Sendable, Equatable {
    public let minimum: GimbalPosition
    public let center: GimbalPosition
    public let maximum: GimbalPosition

    public init(minimum: GimbalPosition, center: GimbalPosition,
                maximum: GimbalPosition) throws {
        guard minimum.pan <= center.pan, center.pan <= maximum.pan,
              minimum.tilt <= center.tilt, center.tilt <= maximum.tilt else {
            throw USBPanTiltStressAcceptanceError.invalidRange
        }
        self.minimum = minimum
        self.center = center
        self.maximum = maximum
    }

    private enum CodingKeys: String, CodingKey {
        case minimum, center, maximum
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minimum: values.decode(GimbalPosition.self, forKey: .minimum),
            center: values.decode(GimbalPosition.self, forKey: .center),
            maximum: values.decode(GimbalPosition.self, forKey: .maximum))
    }

    public func contains(_ position: GimbalPosition) -> Bool {
        position.pan >= minimum.pan && position.pan <= maximum.pan &&
            position.tilt >= minimum.tilt && position.tilt <= maximum.tilt
    }

    public func target(axis: USBPanTiltStressAxis,
                      direction: USBPanTiltStressDirection,
                      fraction: Double) -> GimbalPosition {
        let clamped = min(1, max(0, fraction))
        let endpoint: Int32
        switch (axis, direction) {
        case (.pan, .negative): endpoint = minimum.pan
        case (.pan, .positive): endpoint = maximum.pan
        case (.tilt, .negative): endpoint = minimum.tilt
        case (.tilt, .positive): endpoint = maximum.tilt
        }
        let start: Int32 = axis == .pan ? center.pan : center.tilt
        let value = Double(start) +
            Double(Int64(endpoint) - Int64(start)) * clamped
        let rounded = max(Double(Int32.min), min(Double(Int32.max), value.rounded()))
        if axis == .pan {
            return GimbalPosition(pan: Int32(rounded), tilt: center.tilt)
        }
        return GimbalPosition(pan: center.pan, tilt: Int32(rounded))
    }
}

public enum USBPanTiltStressAxis: String, Codable, Sendable,
    Equatable, CaseIterable {
    case pan
    case tilt
}

public enum USBPanTiltStressDirection: String, Codable, Sendable,
    Equatable, CaseIterable {
    case negative
    case positive

    public var sign: Int { self == .positive ? 1 : -1 }
}

/// Input distance is the normalized distance from the stick center.  The
/// limit case uses the far input distance but drives the raw target all the
/// way to the corresponding declared UVC endpoint.
public enum USBPanTiltStressDistanceBand: String, Codable, Sendable,
    Equatable, CaseIterable {
    case near
    case middle
    case far
    case limit

    public var inputDistance: Double {
        switch self {
        case .near: 0.25
        case .middle: 0.55
        case .far, .limit: 0.80
        }
    }

    public var targetFraction: Double {
        switch self {
        case .near: 0.25
        case .middle: 0.55
        case .far: 0.80
        case .limit: 1.0
        }
    }
}

public struct USBPanTiltStressCasePlan: Codable, Sendable, Equatable {
    public let id: String
    public let axis: USBPanTiltStressAxis
    public let direction: USBPanTiltStressDirection
    public let distanceBand: USBPanTiltStressDistanceBand
    public let inputDistance: Double
    public let targetFraction: Double
    public let target: GimbalPosition

    init(axis: USBPanTiltStressAxis,
         direction: USBPanTiltStressDirection,
         distanceBand: USBPanTiltStressDistanceBand,
         range: USBPanTiltStressRange) {
        self.axis = axis
        self.direction = direction
        self.distanceBand = distanceBand
        inputDistance = distanceBand.inputDistance
        targetFraction = distanceBand.targetFraction
        id = "\(axis.rawValue).\(direction.rawValue).\(distanceBand.rawValue)"
        target = range.target(axis: axis, direction: direction,
                              fraction: distanceBand.targetFraction)
    }
}

/// Errors are kept typed so a future collector can reject malformed plans
/// before opening a control path.  This module has no collector or transport.
public enum USBPanTiltStressAcceptanceError: Error, Codable, Sendable,
    Equatable {
    case invalidRange
    case invalidPlan
    case invalidTrial
}

/// Pure, non-operational plan for a complete raw pan/tilt stress matrix.
/// `hardwareExecutionEnabled` is stored false by construction: a later
/// developer route must explicitly own any hardware executor rather than
/// turning this evaluator into an accidental writer.
public struct USBPanTiltStressPlan: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let currentProfile = "usb_pan_tilt_continuous_stress_v1"
    public static let maximumHoldSeconds: TimeInterval = 1.2
    public static let maximumExecutionSeconds: TimeInterval = 60
    public static let maximumSamplesPerCase = 24
    public static let maximumFrameAgeSeconds: TimeInterval = 1

    public let version: Int
    public let profile: String
    public let range: USBPanTiltStressRange
    public let cases: [USBPanTiltStressCasePlan]
    public let stages: [String]
    public let maximumHoldSeconds: TimeInterval
    public let maximumExecutionSeconds: TimeInterval
    public let maximumSamplesPerCase: Int
    public let maximumFrameAgeSeconds: TimeInterval
    public let hardwareExecutionEnabled: Bool
    public let cameraImagesStored: Bool

    public init(range: USBPanTiltStressRange,
                maximumHoldSeconds: TimeInterval = Self.maximumHoldSeconds,
                maximumExecutionSeconds: TimeInterval = Self.maximumExecutionSeconds,
                maximumSamplesPerCase: Int = Self.maximumSamplesPerCase,
                maximumFrameAgeSeconds: TimeInterval = Self.maximumFrameAgeSeconds) throws {
        guard maximumHoldSeconds.isFinite,
              (0.15...Self.maximumHoldSeconds).contains(maximumHoldSeconds),
              maximumExecutionSeconds.isFinite,
              (15...Self.maximumExecutionSeconds).contains(maximumExecutionSeconds),
              (3...Self.maximumSamplesPerCase).contains(maximumSamplesPerCase),
              maximumFrameAgeSeconds.isFinite,
              (0.1...Self.maximumFrameAgeSeconds).contains(maximumFrameAgeSeconds) else {
            throw USBPanTiltStressAcceptanceError.invalidPlan
        }
        version = Self.currentVersion
        profile = Self.currentProfile
        self.range = range
        cases = USBPanTiltStressAxis.allCases.flatMap { axis in
            USBPanTiltStressDirection.allCases.flatMap { direction in
                USBPanTiltStressDistanceBand.allCases.map { band in
                    USBPanTiltStressCasePlan(
                        axis: axis, direction: direction,
                        distanceBand: band, range: range)
                }
            }
        }
        stages = [
            "fresh_center_baseline",
            "pan_negative_near_middle_far_limit",
            "pan_positive_near_middle_far_limit",
            "tilt_negative_near_middle_far_limit",
            "tilt_positive_near_middle_far_limit",
            "distance_to_speed_metrics",
            "moving_stop_stable_window",
            "restore_center_after_each_case",
            "reconnect_old_session_fence",
            "final_center_restore"
        ]
        self.maximumHoldSeconds = maximumHoldSeconds
        self.maximumExecutionSeconds = maximumExecutionSeconds
        self.maximumSamplesPerCase = maximumSamplesPerCase
        self.maximumFrameAgeSeconds = maximumFrameAgeSeconds
        hardwareExecutionEnabled = false
        cameraImagesStored = false
    }

    private enum CodingKeys: String, CodingKey {
        case version, profile, range, cases, stages,
             maximumHoldSeconds, maximumExecutionSeconds,
             maximumSamplesPerCase,
             maximumFrameAgeSeconds, hardwareExecutionEnabled,
             cameraImagesStored
    }

    /// Decoding rebuilds the reviewed matrix and safety flags instead of
    /// trusting a caller-provided case list or an encoded execution switch.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        let profile = try values.decode(String.self, forKey: .profile)
        let hardwareExecutionEnabled = try values.decode(
            Bool.self, forKey: .hardwareExecutionEnabled)
        let cameraImagesStored = try values.decode(
            Bool.self, forKey: .cameraImagesStored)
        guard version == Self.currentVersion,
              profile == Self.currentProfile,
              !hardwareExecutionEnabled,
              !cameraImagesStored else {
            throw USBPanTiltStressAcceptanceError.invalidPlan
        }
        let rebuilt = try Self.init(
            range: values.decode(USBPanTiltStressRange.self, forKey: .range),
            maximumHoldSeconds: values.decode(
                TimeInterval.self, forKey: .maximumHoldSeconds),
            maximumExecutionSeconds: values.decode(
                TimeInterval.self, forKey: .maximumExecutionSeconds),
            maximumSamplesPerCase: values.decode(
                Int.self, forKey: .maximumSamplesPerCase),
            maximumFrameAgeSeconds: values.decode(
                TimeInterval.self, forKey: .maximumFrameAgeSeconds))
        let encodedCases = try values.decode(
            [USBPanTiltStressCasePlan].self, forKey: .cases)
        let encodedStages = try values.decode(
            [String].self, forKey: .stages)
        guard encodedCases == rebuilt.cases,
              encodedStages == rebuilt.stages else {
            throw USBPanTiltStressAcceptanceError.invalidPlan
        }
        self = rebuilt
    }
}

/// One scalar sample from a held input.  `frame` is metadata only; no pixel
/// bytes or paths are accepted by this evidence type.
public struct USBPanTiltStressSample: Codable, Sendable, Equatable {
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

public struct USBPanTiltStressTrial: Codable, Sendable, Equatable {
    public let planID: String
    public let axis: USBPanTiltStressAxis
    public let direction: USBPanTiltStressDirection
    public let distanceBand: USBPanTiltStressDistanceBand
    public let inputDistance: Double
    public let origin: GimbalPosition
    public let target: GimbalPosition
    public let holdDurationSeconds: TimeInterval
    public let samples: [USBPanTiltStressSample]
    public let stop: USBManualStopEvidence
    public let restore: USBManualRestoreEvidence

    public init(plan: USBPanTiltStressCasePlan,
                origin: GimbalPosition,
                holdDurationSeconds: TimeInterval,
                samples: [USBPanTiltStressSample],
                stop: USBManualStopEvidence,
                restore: USBManualRestoreEvidence) {
        planID = plan.id
        axis = plan.axis
        direction = plan.direction
        distanceBand = plan.distanceBand
        inputDistance = plan.inputDistance
        self.origin = origin
        target = plan.target
        self.holdDurationSeconds = holdDurationSeconds
        self.samples = samples
        self.stop = stop
        self.restore = restore
    }
}

public struct USBPanTiltStressReport: Codable, Sendable, Equatable {
    public let version: Int
    public let profile: String
    public let createdAt: Date
    public let plan: USBPanTiltStressPlan
    public let initialBinding: USBManualAcceptanceBinding
    public let baselineFrames: [USBManualFrameEvidence]
    public let trials: [USBPanTiltStressTrial]
    public let reconnect: USBManualReconnectFenceMetric
    public let finalBinding: USBManualAcceptanceBinding
    public let finalPosition: GimbalPosition?
    public let cameraImagesStored: Bool
    public let physicalMotionVerified: Bool

    public init(plan: USBPanTiltStressPlan,
                initialBinding: USBManualAcceptanceBinding,
                baselineFrames: [USBManualFrameEvidence],
                trials: [USBPanTiltStressTrial],
                reconnect: USBManualReconnectFenceMetric,
                finalBinding: USBManualAcceptanceBinding,
                finalPosition: GimbalPosition? = nil,
                cameraImagesStored: Bool = false,
                physicalMotionVerified: Bool = false,
                createdAt: Date = Date()) {
        version = plan.version
        profile = plan.profile
        self.createdAt = createdAt
        self.plan = plan
        self.initialBinding = initialBinding
        self.baselineFrames = baselineFrames
        self.trials = trials
        self.reconnect = reconnect
        self.finalBinding = finalBinding
        self.finalPosition = finalPosition
        self.cameraImagesStored = cameraImagesStored
        self.physicalMotionVerified = physicalMotionVerified
    }
}

public struct USBPanTiltStressEvaluation: Codable, Sendable, Equatable {
    public let version: Int
    public let profile: String
    public let metricsPassed: Bool
    public let checks: [String: Bool]
    public let failureCode: String?
    public let remainingPhysicalSteps: [String]
    public let cameraImagesStored: Bool
    public let physicalMotionVerified: Bool

    init(version: Int, profile: String, metricsPassed: Bool,
         checks: [String: Bool], failureCode: String?,
         cameraImagesStored: Bool, physicalMotionVerified: Bool) {
        self.version = version
        self.profile = profile
        self.metricsPassed = metricsPassed
        self.checks = checks
        self.failureCode = failureCode
        self.cameraImagesStored = cameraImagesStored
        self.physicalMotionVerified = physicalMotionVerified
        remainingPhysicalSteps = [
            "Confirm raw-to-physical pan and tilt direction and angle on the real unit.",
            "Measure mechanical stop latency and post-release tail motion on the real unit.",
            "Repeat the matrix across approved firmware and attachment states.",
            "Confirm final center restoration after a real disconnect or power event."
        ]
    }
}

/// Metrics-only evaluator for a future developer collector.  It never opens a
/// UVC connection, sends a target, saves an image, or turns `verified` into a
/// claim about physical motion.
public enum USBPanTiltStressAcceptance {
    public static let minimumStopSamples = 3
    public static let minimumStopDuration: TimeInterval = 0.2
    public static let minimumTravelRaw: Int64 = 720
    public static let restorationToleranceRaw: Int64 = 1080
    public static let positionJitterToleranceRaw: Int64 = 360
    public static let minimumFarToNearRateRatio = 1.25

    public static func dryRunPlan(
        range: USBPanTiltStressRange
    ) throws -> USBPanTiltStressPlan {
        try USBPanTiltStressPlan(range: range)
    }

    public static func evaluate(
        _ report: USBPanTiltStressReport
    ) -> USBPanTiltStressEvaluation {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) { checks[name] = value }

        check("schema", report.version == USBPanTiltStressPlan.currentVersion &&
            report.profile == USBPanTiltStressPlan.currentProfile &&
            report.plan.version == report.version &&
            report.plan.profile == report.profile &&
            report.plan.maximumExecutionSeconds.isFinite &&
            (15...USBPanTiltStressPlan.maximumExecutionSeconds)
                .contains(report.plan.maximumExecutionSeconds))
        check("metrics_only", !report.cameraImagesStored &&
            !report.physicalMotionVerified &&
            !report.plan.hardwareExecutionEnabled &&
            !report.plan.cameraImagesStored)
        check("initial_binding", report.initialBinding.isComplete)
        check("fresh_center_baseline", baselinePassed(report))
        check("full_range_matrix", matrixPassed(report))
        check("fresh_monotonic_samples", samplesPassed(report))
        check("limit_targets_reached", limitTargetsPassed(report))
        check("speed_follows_input_distance", speedPassed(report))
        check("stop_and_restore", stopAndRestorePassed(report))
        check("reconnect_session_fence", reconnectPassed(report))
        check("final_center_restore", finalRestorePassed(report))

        let passed = checks.values.allSatisfy { $0 }
        return USBPanTiltStressEvaluation(
            version: report.version, profile: report.profile,
            metricsPassed: passed, checks: checks,
            failureCode: passed ? nil : checks.first(where: { !$0.value })?.key,
            cameraImagesStored: report.cameraImagesStored,
            physicalMotionVerified: report.physicalMotionVerified)
    }

    private static func baselinePassed(
        _ report: USBPanTiltStressReport
    ) -> Bool {
        guard report.baselineFrames.count >= minimumStopSamples,
              report.baselineFrames.count <= 64 else { return false }
        let IDs = Set(report.baselineFrames.map(\.frameID))
        return IDs.count == report.baselineFrames.count &&
            report.baselineFrames.allSatisfy {
                $0.isFresh(for: report.initialBinding,
                           maximumAge: report.plan.maximumFrameAgeSeconds)
            }
    }

    private static func matrixPassed(
        _ report: USBPanTiltStressReport
    ) -> Bool {
        guard report.trials.count == report.plan.cases.count else {
            return false
        }
        let expected = Dictionary(uniqueKeysWithValues: report.plan.cases.map {
            ($0.id, $0)
        })
        let actualIDs = report.trials.map(\.planID)
        guard Set(actualIDs).count == report.trials.count,
              Set(actualIDs) == Set(expected.keys) else { return false }
        return report.trials.allSatisfy { trial in
            guard let plan = expected[trial.planID],
                  trial.axis == plan.axis,
                  trial.direction == plan.direction,
                  trial.distanceBand == plan.distanceBand,
                  abs(trial.inputDistance - plan.inputDistance) <= 1e-9,
                  trial.origin == report.plan.range.center,
                  trial.target == plan.target,
                  report.plan.range.contains(trial.origin),
                  report.plan.range.contains(trial.target) else {
                return false
            }
            return true
        }
    }

    private static func samplesPassed(
        _ report: USBPanTiltStressReport
    ) -> Bool {
        report.trials.allSatisfy { trial in
            guard trial.holdDurationSeconds.isFinite,
                  (0.15...report.plan.maximumHoldSeconds)
                    .contains(trial.holdDurationSeconds),
                  trial.samples.count >= minimumStopSamples,
                  trial.samples.count <= report.plan.maximumSamplesPerCase,
                  Set(trial.samples.map(\.frame.frameID)).count >= minimumStopSamples else {
                return false
            }
            var previous = trial.origin
            var previousElapsed: TimeInterval = -1
            for sample in trial.samples {
                guard sample.elapsed.isFinite,
                      sample.elapsed >= 0,
                      sample.elapsed > previousElapsed,
                      sample.elapsed <= trial.holdDurationSeconds + 0.15,
                      sample.phase == "moving",
                      sample.motionActive,
                      report.plan.range.contains(sample.position),
                      sample.frame.isFresh(
                        for: report.initialBinding,
                        maximumAge: report.plan.maximumFrameAgeSeconds) else {
                    return false
                }
                let progress = signedDistance(
                    axis: trial.axis, from: trial.origin,
                    to: sample.position, direction: trial.direction)
                let priorProgress = signedDistance(
                    axis: trial.axis, from: trial.origin,
                    to: previous, direction: trial.direction)
                guard progress >= -positionJitterToleranceRaw,
                      progress + positionJitterToleranceRaw >= priorProgress,
                      orthogonalDistance(
                        axis: trial.axis, from: trial.origin,
                        to: sample.position) <= restorationToleranceRaw else {
                    return false
                }
                previous = sample.position
                previousElapsed = sample.elapsed
            }
            let travel = signedDistance(
                axis: trial.axis, from: trial.origin,
                to: trial.samples.last!.position, direction: trial.direction)
            return travel >= minimumTravelRaw
        }
    }

    private static func limitTargetsPassed(
        _ report: USBPanTiltStressReport
    ) -> Bool {
        report.trials.filter { $0.distanceBand == .limit }.allSatisfy { trial in
            guard let last = trial.samples.last?.position else { return false }
            return last.distance(to: trial.target) <= restorationToleranceRaw
        }
    }

    private static func speedPassed(
        _ report: USBPanTiltStressReport
    ) -> Bool {
        for axis in USBPanTiltStressAxis.allCases {
            for direction in USBPanTiltStressDirection.allCases {
                guard let near = trial(.near, axis: axis, direction: direction,
                                       report: report),
                      let middle = trial(.middle, axis: axis, direction: direction,
                                         report: report),
                      let far = trial(.far, axis: axis, direction: direction,
                                      report: report) else { return false }
                let nearRate = rate(near), middleRate = rate(middle), farRate = rate(far)
                guard near.inputDistance < middle.inputDistance,
                      middle.inputDistance < far.inputDistance,
                      nearRate.isFinite, middleRate.isFinite, farRate.isFinite,
                      nearRate > 0, middleRate >= nearRate * 0.80,
                      farRate >= nearRate * minimumFarToNearRateRatio,
                      signedTravel(near) <= signedTravel(middle),
                      signedTravel(middle) <= signedTravel(far) else { return false }
            }
        }
        return true
    }

    private static func stopAndRestorePassed(
        _ report: USBPanTiltStressReport
    ) -> Bool {
        report.trials.allSatisfy { trial in
            guard trial.stop.submitted, trial.stop.verified,
                  trial.stop.motionStopped,
                  trial.stop.failureCode == nil,
                  trial.stop.stableSampleCount >= minimumStopSamples,
                  trial.stop.stableDurationSeconds.isFinite,
                  trial.stop.stableDurationSeconds >= minimumStopDuration,
                  trial.stop.stableDurationSeconds <= report.plan.maximumHoldSeconds,
                  let held = trial.stop.held,
                  let final = trial.stop.final,
                  final.distance(to: held) <= restorationToleranceRaw,
                  trial.restore.requested == trial.origin,
                  trial.restore.submitted, trial.restore.verified,
                  trial.restore.failureCode == nil,
                  trial.restore.stableSampleCount >= minimumStopSamples,
                  trial.restore.stableDurationSeconds.isFinite,
                  trial.restore.stableDurationSeconds >= minimumStopDuration,
                  trial.restore.stableDurationSeconds <= report.plan.maximumHoldSeconds,
                  let restored = trial.restore.observed,
                  restored.distance(to: trial.origin) <= restorationToleranceRaw else {
                return false
            }
            return report.plan.range.contains(held) &&
                report.plan.range.contains(final) &&
                report.plan.range.contains(restored)
        }
    }

    private static func reconnectPassed(
        _ report: USBPanTiltStressReport
    ) -> Bool {
        let fence = report.reconnect
        guard fence.oldBinding == report.initialBinding,
              fence.oldBinding.isComplete,
              fence.newBinding.isComplete,
              fence.newBinding.deviceID == fence.oldBinding.deviceID,
              fence.newBinding.captureSessionID != fence.oldBinding.captureSessionID,
              fence.newBinding.registryID == fence.oldBinding.registryID,
              fence.newBinding.bootSessionID == fence.oldBinding.bootSessionID,
              fence.oldOperationStopped,
              fence.oldOperationSuppressed,
              fence.newSessionReady,
              report.finalBinding == fence.newBinding else { return false }
        return report.trials.allSatisfy { trial in
            trial.samples.allSatisfy {
                $0.frame.sessionID == fence.oldBinding.captureSessionID
            }
        }
    }

    private static func finalRestorePassed(
        _ report: USBPanTiltStressReport
    ) -> Bool {
        guard report.finalBinding == report.reconnect.newBinding,
              let final = report.finalPosition,
              final.distance(to: report.plan.range.center) <= restorationToleranceRaw else {
            return false
        }
        return report.trials.allSatisfy { trial in
            trial.restore.verified &&
                (trial.restore.observed?.distance(to: trial.origin) ?? .max) <=
                    restorationToleranceRaw
        }
    }

    private static func trial(
        _ band: USBPanTiltStressDistanceBand,
        axis: USBPanTiltStressAxis,
        direction: USBPanTiltStressDirection,
        report: USBPanTiltStressReport
    ) -> USBPanTiltStressTrial? {
        report.trials.first {
            $0.axis == axis && $0.direction == direction &&
                $0.distanceBand == band
        }
    }

    private static func rate(_ trial: USBPanTiltStressTrial) -> Double {
        Double(signedTravel(trial)) / trial.holdDurationSeconds
    }

    private static func signedTravel(_ trial: USBPanTiltStressTrial) -> Int64 {
        guard let last = trial.samples.last else { return 0 }
        return signedDistance(axis: trial.axis, from: trial.origin,
                              to: last.position, direction: trial.direction)
    }

    private static func signedDistance(
        axis: USBPanTiltStressAxis,
        from origin: GimbalPosition,
        to position: GimbalPosition,
        direction: USBPanTiltStressDirection
    ) -> Int64 {
        let start = Int64(axis == .pan ? origin.pan : origin.tilt)
        let end = Int64(axis == .pan ? position.pan : position.tilt)
        return (end - start) * Int64(direction.sign)
    }

    private static func orthogonalDistance(
        axis: USBPanTiltStressAxis,
        from origin: GimbalPosition,
        to position: GimbalPosition
    ) -> Int64 {
        if axis == .pan {
            return abs(Int64(position.tilt) - Int64(origin.tilt))
        }
        return abs(Int64(position.pan) - Int64(origin.pan))
    }
}

public typealias Pocket3USBPanTiltStressRange = USBPanTiltStressRange
public typealias Pocket3USBPanTiltStressPlan = USBPanTiltStressPlan
public typealias Pocket3USBPanTiltStressReport = USBPanTiltStressReport
public typealias Pocket3USBPanTiltStressEvaluation = USBPanTiltStressEvaluation
