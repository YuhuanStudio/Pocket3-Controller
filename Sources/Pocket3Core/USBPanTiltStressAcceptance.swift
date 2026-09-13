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

/// Developer-only request for the full-range pan/tilt collector.  A range is
/// optional for a dry run so the command can show its contract before a
/// camera is connected.  Execution requires the caller to repeat the exact
/// range observed from the current USB attachment.
public struct USBPanTiltStressRequest: Codable, Sendable, Equatable {
    public static let operation = "validation-usb-pan-tilt-stress"
    public static let defaultHoldSeconds: TimeInterval = 0.6
    public static let maximumHoldSeconds: TimeInterval = 1.2
    public static let defaultPollInterval: TimeInterval = 0.05
    public static let minimumPollInterval: TimeInterval = 0.04
    public static let maximumPollInterval: TimeInterval = 0.25
    public static let defaultTimeout: TimeInterval = USBPanTiltStressPlan.maximumExecutionSeconds
    public static let minimumTimeout: TimeInterval = 15
    public static let maximumTimeout: TimeInterval = USBPanTiltStressPlan.maximumExecutionSeconds

    public let expectedDeviceID: String?
    public let expectedSessionID: String?
    public let declaredRange: USBPanTiltStressRange?
    public let holdSeconds: TimeInterval
    public let pollInterval: TimeInterval
    public let timeout: TimeInterval
    public let execute: Bool

    public init(expectedDeviceID: String? = nil,
                expectedSessionID: String? = nil,
                declaredRange: USBPanTiltStressRange? = nil,
                holdSeconds: TimeInterval = Self.defaultHoldSeconds,
                pollInterval: TimeInterval = Self.defaultPollInterval,
                timeout: TimeInterval = Self.defaultTimeout,
                execute: Bool = false) throws {
        if let expectedDeviceID {
            guard !expectedDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw USBPanTiltStressRequestError.invalidArguments
            }
        }
        if let expectedSessionID {
            guard !expectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw USBPanTiltStressRequestError.invalidArguments
            }
        }
        if execute {
            guard let expectedDeviceID, !expectedDeviceID.isEmpty,
                  let expectedSessionID, !expectedSessionID.isEmpty else {
                throw USBPanTiltStressRequestError.identityRequired
            }
            guard declaredRange != nil else {
                throw USBPanTiltStressRequestError.rangeRequired
            }
        }
        guard holdSeconds.isFinite,
              (0.15...Self.maximumHoldSeconds).contains(holdSeconds),
              pollInterval.isFinite,
              (Self.minimumPollInterval...Self.maximumPollInterval).contains(pollInterval),
              timeout.isFinite,
              (Self.minimumTimeout...Self.maximumTimeout).contains(timeout),
              holdSeconds + pollInterval <= timeout else {
            throw USBPanTiltStressRequestError.invalidArguments
        }
        self.expectedDeviceID = expectedDeviceID
        self.expectedSessionID = expectedSessionID
        self.declaredRange = declaredRange
        self.holdSeconds = holdSeconds
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.execute = execute
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                  "device", "session", "range", "holdSeconds", "pollInterval",
                  "timeout", "execute"
              ]) else {
            throw USBPanTiltStressRequestError.invalidArguments
        }
        let device = try Self.string(fields["device"])
        let session = try Self.string(fields["session"])
        let range: USBPanTiltStressRange?
        if let value = fields["range"], value != .null {
            do { range = try value.decode(USBPanTiltStressRange.self) }
            catch { throw USBPanTiltStressRequestError.invalidArguments }
        } else { range = nil }
        let hold = try Self.number(fields["holdSeconds"], default: Self.defaultHoldSeconds)
        let poll = try Self.number(fields["pollInterval"], default: Self.defaultPollInterval)
        let timeout = try Self.number(fields["timeout"], default: Self.defaultTimeout)
        let execute = try Self.boolean(fields["execute"])
        try self.init(expectedDeviceID: device, expectedSessionID: session,
                      declaredRange: range, holdSeconds: hold,
                      pollInterval: poll, timeout: timeout, execute: execute)
    }

    public init(cliArguments: [String]) throws {
        var device: String?
        var session: String?
        var rangeJSON: String?
        var raw: [String: Int32] = [:]
        var hold = Self.defaultHoldSeconds
        var poll = Self.defaultPollInterval
        var timeout = Self.defaultTimeout
        var execute = false
        var index = 0
        while index < cliArguments.count {
            let argument = cliArguments[index]
            if argument == "--execute" {
                guard !execute else { throw USBPanTiltStressRequestError.invalidArguments }
                execute = true
                index += 1
                continue
            }
            guard index + 1 < cliArguments.count else {
                throw USBPanTiltStressRequestError.invalidArguments
            }
            let value = cliArguments[index + 1]
            switch argument {
            case "--device":
                guard device == nil else { throw USBPanTiltStressRequestError.invalidArguments }
                device = value
            case "--session":
                guard session == nil else { throw USBPanTiltStressRequestError.invalidArguments }
                session = value
            case "--range-json":
                guard rangeJSON == nil else { throw USBPanTiltStressRequestError.invalidArguments }
                rangeJSON = value
            case "--minimum-pan", "--min-pan":
                try Self.insertRaw(value, key: "minimumPan", into: &raw)
            case "--minimum-tilt", "--min-tilt":
                try Self.insertRaw(value, key: "minimumTilt", into: &raw)
            case "--center-pan":
                try Self.insertRaw(value, key: "centerPan", into: &raw)
            case "--center-tilt":
                try Self.insertRaw(value, key: "centerTilt", into: &raw)
            case "--maximum-pan", "--max-pan":
                try Self.insertRaw(value, key: "maximumPan", into: &raw)
            case "--maximum-tilt", "--max-tilt":
                try Self.insertRaw(value, key: "maximumTilt", into: &raw)
            case "--hold-seconds":
                guard let parsed = Double(value) else { throw USBPanTiltStressRequestError.invalidArguments }
                hold = parsed
            case "--poll-interval":
                guard let parsed = Double(value) else { throw USBPanTiltStressRequestError.invalidArguments }
                poll = parsed
            case "--timeout":
                guard let parsed = Double(value) else { throw USBPanTiltStressRequestError.invalidArguments }
                timeout = parsed
            default: throw USBPanTiltStressRequestError.invalidArguments
            }
            index += 2
        }

        let declaredRange: USBPanTiltStressRange?
        if let rangeJSON {
            guard raw.isEmpty, let data = rangeJSON.data(using: .utf8) else {
                throw USBPanTiltStressRequestError.invalidArguments
            }
            do {
                declaredRange = try JSONDecoder().decode(
                    USBPanTiltStressRange.self, from: data)
            } catch { throw USBPanTiltStressRequestError.invalidArguments }
        } else if raw.isEmpty {
            declaredRange = nil
        } else {
            guard raw.count == 6,
                  let minimumPan = raw["minimumPan"],
                  let minimumTilt = raw["minimumTilt"],
                  let centerPan = raw["centerPan"],
                  let centerTilt = raw["centerTilt"],
                  let maximumPan = raw["maximumPan"],
                  let maximumTilt = raw["maximumTilt"] else {
                throw USBPanTiltStressRequestError.invalidArguments
            }
            do {
                declaredRange = try USBPanTiltStressRange(
                    minimum: .init(pan: minimumPan, tilt: minimumTilt),
                    center: .init(pan: centerPan, tilt: centerTilt),
                    maximum: .init(pan: maximumPan, tilt: maximumTilt))
            } catch { throw USBPanTiltStressRequestError.invalidArguments }
        }
        try self.init(expectedDeviceID: device, expectedSessionID: session,
                      declaredRange: declaredRange, holdSeconds: hold,
                      pollInterval: poll, timeout: timeout, execute: execute)
    }

    public var arguments: JSONValue {
        var fields: [String: JSONValue] = [
            "holdSeconds": .number(holdSeconds),
            "pollInterval": .number(pollInterval),
            "timeout": .number(timeout),
            "execute": .bool(execute),
            "range": (try? declaredRange.map(JSONValue.encode)) ?? .null
        ]
        if let expectedDeviceID { fields["device"] = .string(expectedDeviceID) }
        if let expectedSessionID { fields["session"] = .string(expectedSessionID) }
        return .object(fields)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "device": .object(["type": .string("string"), "minLength": .number(1)]),
            "session": .object(["type": .string("string"), "minLength": .number(1)]),
            "range": .object(["type": .string("object")]),
            "holdSeconds": .object(["type": .string("number"),
                                      "minimum": .number(0.15),
                                      "maximum": .number(maximumHoldSeconds)]),
            "pollInterval": .object(["type": .string("number"),
                                       "minimum": .number(minimumPollInterval),
                                       "maximum": .number(maximumPollInterval)]),
            "timeout": .object(["type": .string("number"),
                                 "minimum": .number(minimumTimeout),
                                 "maximum": .number(maximumTimeout)]),
            "execute": .object(["type": .string("boolean")])
        ]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }

    private static func string(_ value: JSONValue?) throws -> String? {
        guard let value else { return nil }
        guard let result = value.string, !result.isEmpty else {
            throw USBPanTiltStressRequestError.invalidArguments
        }
        return result
    }

    private static func number(_ value: JSONValue?, default fallback: Double) throws -> Double {
        guard let value else { return fallback }
        guard let result = value.number, result.isFinite else {
            throw USBPanTiltStressRequestError.invalidArguments
        }
        return result
    }

    private static func boolean(_ value: JSONValue?) throws -> Bool {
        guard let value else { return false }
        guard let result = value.bool else {
            throw USBPanTiltStressRequestError.invalidArguments
        }
        return result
    }

    private static func insertRaw(_ value: String, key: String,
                                  into values: inout [String: Int32]) throws {
        guard values[key] == nil, let parsed = Int64(value),
              parsed >= Int64(Int32.min), parsed <= Int64(Int32.max) else {
            throw USBPanTiltStressRequestError.invalidArguments
        }
        values[key] = Int32(parsed)
    }
}

public enum USBPanTiltStressRequestError: Error, Codable, Sendable, Equatable {
    case invalidArguments
    case identityRequired
    case rangeRequired
}

public typealias Pocket3USBPanTiltStressRequest = USBPanTiltStressRequest

/// Errors are kept typed so malformed plans can be rejected before opening a
/// control path. The executor below still receives all hardware access through
/// an existing-owner adapter.
public enum USBPanTiltStressAcceptanceError: Error, Codable, Sendable,
    Equatable {
    case invalidRange
    case invalidPlan
    case invalidTrial
}

/// Pure, non-operational plan for a complete raw pan/tilt stress matrix.
/// `hardwareExecutionEnabled` remains false by construction: the developer
/// route owns execution explicitly and this plan never becomes an accidental
/// generic writer.
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
    /// Execution metadata is populated by the developer collector. Legacy
    /// metrics fixtures default to a completed run for source compatibility.
    public let phase: String
    public let completed: Bool
    public let executionFailureCode: String?
    public let finalRestore: USBManualRestoreEvidence?
    public let cleanupAttempted: Bool
    public let cleanupSucceeded: Bool
    public let cameraImagesStored: Bool
    public let physicalMotionVerified: Bool

    private enum CodingKeys: String, CodingKey {
        case version, profile, createdAt, plan, initialBinding, baselineFrames,
             trials, reconnect, finalBinding, finalPosition, phase, completed,
             executionFailureCode, finalRestore, cleanupAttempted,
             cleanupSucceeded, cameraImagesStored, physicalMotionVerified
    }

    public init(plan: USBPanTiltStressPlan,
                initialBinding: USBManualAcceptanceBinding,
                baselineFrames: [USBManualFrameEvidence],
                trials: [USBPanTiltStressTrial],
                reconnect: USBManualReconnectFenceMetric,
                finalBinding: USBManualAcceptanceBinding,
                finalPosition: GimbalPosition? = nil,
                phase: String = "completed",
                completed: Bool = true,
                executionFailureCode: String? = nil,
                finalRestore: USBManualRestoreEvidence? = nil,
                cleanupAttempted: Bool = true,
                cleanupSucceeded: Bool = true,
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
        self.phase = phase
        self.completed = completed
        self.executionFailureCode = executionFailureCode
        self.finalRestore = finalRestore
        self.cleanupAttempted = cleanupAttempted
        self.cleanupSucceeded = cleanupSucceeded
        self.cameraImagesStored = cameraImagesStored
        self.physicalMotionVerified = physicalMotionVerified
    }

    /// Older metrics reports predate execution metadata. Missing fields retain
    /// the legacy completed-fixture defaults while new collector reports keep
    /// their explicit partial/failure state.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let plan = try values.decode(USBPanTiltStressPlan.self, forKey: .plan)
        try self.init(
            plan: plan,
            initialBinding: values.decode(
                USBManualAcceptanceBinding.self, forKey: .initialBinding),
            baselineFrames: values.decode(
                [USBManualFrameEvidence].self, forKey: .baselineFrames),
            trials: values.decode(
                [USBPanTiltStressTrial].self, forKey: .trials),
            reconnect: values.decode(
                USBManualReconnectFenceMetric.self, forKey: .reconnect),
            finalBinding: values.decode(
                USBManualAcceptanceBinding.self, forKey: .finalBinding),
            finalPosition: values.decodeIfPresent(
                GimbalPosition.self, forKey: .finalPosition),
            phase: values.decodeIfPresent(String.self, forKey: .phase)
                ?? "completed",
            completed: values.decodeIfPresent(Bool.self, forKey: .completed)
                ?? true,
            executionFailureCode: values.decodeIfPresent(
                String.self, forKey: .executionFailureCode),
            finalRestore: values.decodeIfPresent(
                USBManualRestoreEvidence.self, forKey: .finalRestore),
            cleanupAttempted: values.decodeIfPresent(
                Bool.self, forKey: .cleanupAttempted) ?? true,
            cleanupSucceeded: values.decodeIfPresent(
                Bool.self, forKey: .cleanupSucceeded) ?? true,
            cameraImagesStored: values.decodeIfPresent(
                Bool.self, forKey: .cameraImagesStored) ?? false,
            physicalMotionVerified: values.decodeIfPresent(
                Bool.self, forKey: .physicalMotionVerified) ?? false,
            createdAt: values.decodeIfPresent(Date.self, forKey: .createdAt)
                ?? Date())
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

/// Scalar state supplied by the already-running USB owner.  A hardware
/// adapter may read AVFoundation status and UVC position, but it cannot return
/// pixel data through this seam.
public struct USBPanTiltStressHardwareObservation: Sendable {
    public let binding: USBManualAcceptanceBinding
    public let capabilities: UVCCapabilities
    public let frame: USBManualFrameEvidence?
    public let sampledUptime: TimeInterval
    public let phase: String
    public let motionActive: Bool

    public init(binding: USBManualAcceptanceBinding,
                capabilities: UVCCapabilities,
                frame: USBManualFrameEvidence?,
                sampledUptime: TimeInterval,
                phase: String,
                motionActive: Bool) {
        self.binding = binding
        self.capabilities = capabilities
        self.frame = frame
        self.sampledUptime = sampledUptime
        self.phase = phase
        self.motionActive = motionActive
    }
}

/// Existing-owner seam for the full-range collector.  The App supplies
/// closures backed by CameraService; tests can inject scalar state without a
/// UVC connection.  No transport or image sink is stored by this value.
public struct USBPanTiltStressExecutorAdapter: Sendable {
    public typealias Read = @Sendable () async throws
        -> USBPanTiltStressHardwareObservation
    public typealias StartMove = @Sendable (
        _ target: GimbalPosition, _ expectedSessionID: String
    ) -> Task<MotionResult, Error>
    public typealias Stop = @Sendable () async throws
        -> USBManualStopEvidence
    public typealias Restore = @Sendable (
        _ origin: GimbalPosition, _ expectedSessionID: String
    ) async throws -> USBManualRestoreEvidence
    public typealias Reconnect = @Sendable (
        _ oldBinding: USBManualAcceptanceBinding,
        _ request: USBPanTiltStressRequest
    ) async throws -> USBManualReconnectFenceMetric
    /// Optional last-resort cleanup. It must be implemented by the existing
    /// owner with an exact-current-session Stop and must never replay a stale
    /// target. The executor calls it only after a failed Stop/restore or a
    /// failure outside a case.
    public typealias Cleanup = @Sendable () async -> Bool

    let read: Read
    let startMove: StartMove
    let stop: Stop
    let restore: Restore
    let reconnect: Reconnect
    let cleanup: Cleanup?

    public init(read: @escaping Read,
                startMove: @escaping StartMove,
                stop: @escaping Stop,
                restore: @escaping Restore,
                reconnect: @escaping Reconnect,
                cleanup: Cleanup? = nil) {
        self.read = read
        self.startMove = startMove
        self.stop = stop
        self.restore = restore
        self.reconnect = reconnect
        self.cleanup = cleanup
    }
}

/// Metrics evaluator and bounded executor boundary for the developer
/// collector. The Core layer never opens UVC itself; execution can only reach
/// hardware through the existing-owner adapter, records scalar metadata, and
/// never saves an image or turns `verified` into a claim about physical motion.
public enum USBPanTiltStressAcceptance {
    public static let maximumBaselineFrames = 64
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

    /// Runs the reviewed 16-case matrix through the existing USB owner. The
    /// executor records scalar readback and frame metadata only; all writes,
    /// Stop verification and reconnect handling stay behind the adapter.
    /// Cancellation and every failure receive a bounded, independent cleanup
    /// attempt before the partial report is returned.
    public static func execute(
        _ request: USBPanTiltStressRequest,
        adapter: USBPanTiltStressExecutorAdapter,
        clock: any ContinuousGimbalClock = SystemContinuousGimbalClock()
    ) async -> USBPanTiltStressReport {
        let range = request.declaredRange ?? (try! USBPanTiltStressRange(
            minimum: .init(pan: 0, tilt: 0),
            center: .init(pan: 0, tilt: 0),
            maximum: .init(pan: 0, tilt: 0)))
        let plan = try! USBPanTiltStressPlan(
            range: range,
            maximumHoldSeconds: request.holdSeconds,
            maximumExecutionSeconds: request.timeout)

        guard request.execute, request.declaredRange != nil else {
            let placeholder = placeholderBinding(for: request)
            let fence = USBManualReconnectFenceMetric(
                oldBinding: placeholder, newBinding: placeholder,
                oldOperationStopped: false, oldOperationSuppressed: false,
                newSessionReady: false)
            return USBPanTiltStressReport(
                plan: plan, initialBinding: placeholder, baselineFrames: [],
                trials: [], reconnect: fence, finalBinding: placeholder,
                phase: "dry_run", completed: false,
                cleanupAttempted: true, cleanupSucceeded: true,
                cameraImagesStored: false, physicalMotionVerified: false)
        }

        var binding: USBManualAcceptanceBinding?
        var baselineFrames: [USBManualFrameEvidence] = []
        var trials: [USBPanTiltStressTrial] = []
        var reconnect: USBManualReconnectFenceMetric?
        var finalBinding: USBManualAcceptanceBinding?
        var finalPosition: GimbalPosition?
        var finalRestore: USBManualRestoreEvidence?
        var phase = "initial_status"
        var failureCode: String?
        var cleanupAttempted = false
        var cleanupSucceeded = true
        let started = clock.now
        let deadline = started + request.timeout

        do {
            guard started.isFinite, deadline.isFinite else {
                throw BridgeFailure("usb_pan_tilt_stress_timing",
                    "USB pan/tilt stress clock is invalid")
            }
            let initial = try await adapter.read()
            try validateInitial(initial, request: request, range: range,
                                plan: plan)
            binding = initial.binding

            phase = "fresh_center_baseline"
            baselineFrames = try await collectBaseline(
                binding: initial.binding, range: range, plan: plan,
                deadline: min(deadline, started + 5), adapter: adapter,
                clock: clock)
            try checkDeadline(deadline, clock: clock)

            for casePlan in plan.cases {
                phase = "case_\(casePlan.id)"
                try checkDeadline(deadline, clock: clock)
                guard let binding else {
                    throw BridgeFailure("usb_pan_tilt_stress_binding_missing",
                        "The USB stress run lost its current binding")
                }
                let result = await executeCase(
                    casePlan, binding: binding, plan: plan,
                    request: request, deadline: deadline,
                    adapter: adapter, clock: clock)
                cleanupAttempted = cleanupAttempted || result.cleanupAttempted
                cleanupSucceeded = cleanupSucceeded && result.cleanupSucceeded
                if let trial = result.trial { trials.append(trial) }
                guard result.passed else {
                    if result.failureCode == "cancelled" {
                        throw CancellationError()
                    }
                    throw BridgeFailure(
                        result.failureCode ?? "usb_pan_tilt_stress_case_failed",
                        "USB pan/tilt stress case \(casePlan.id) did not complete safely")
                }
            }

            phase = "reconnect_old_session_fence"
            guard let binding else {
                throw BridgeFailure("usb_pan_tilt_stress_binding_missing",
                    "The USB stress run has no old-session binding")
            }
            let fence = try await adapter.reconnect(binding, request)
            reconnect = fence
            guard fence.oldBinding == binding,
                  fence.oldOperationStopped,
                  fence.oldOperationSuppressed,
                  fence.newSessionReady,
                  fence.newBinding.isComplete,
                  fence.newBinding.deviceID == binding.deviceID,
                  fence.newBinding.captureSessionID != binding.captureSessionID else {
                throw BridgeFailure("usb_pan_tilt_stress_reconnect_unverified",
                    "The old USB session was not fenced before the new session")
            }
            finalBinding = fence.newBinding

            phase = "final_center_restore"
            let restored = try await adapter.restore(
                range.center, fence.newBinding.captureSessionID)
            finalRestore = restored
            guard restored.requested == range.center,
                  restored.submitted, restored.verified,
                  restored.failureCode == nil else {
                throw BridgeFailure("usb_pan_tilt_stress_final_restore_unverified",
                    "The final USB center restore was not verified")
            }
            let final = try await adapter.read()
            try validateObservation(final, binding: fence.newBinding,
                                    range: range, plan: plan)
            guard final.phase == "ready", !final.motionActive,
                  let frame = final.frame,
                  frame.isFresh(for: fence.newBinding,
                                maximumAge: plan.maximumFrameAgeSeconds),
                  final.capabilities.position.distance(to: range.center) <=
                    restorationToleranceRaw else {
                throw BridgeFailure("usb_pan_tilt_stress_final_restore_unverified",
                    "The final USB center has no fresh stable scalar readback")
            }
            finalPosition = final.capabilities.position
            phase = "completed"
        } catch is CancellationError {
            failureCode = "cancelled"
            phase = "cancelled"
        } catch let error as BridgeFailure {
            failureCode = error.code
            phase = "failed"
        } catch {
            failureCode = "usb_pan_tilt_stress_failed"
            phase = "failed"
        }

        if failureCode != nil {
            // Even when a case already stopped, a failure during reconnect or
            // final restore may have left a newer owner active. Repeat the
            // owner's current-session cleanup before returning evidence.
            cleanupAttempted = true
            let cleanupResult = await forceCleanup(adapter)
            cleanupSucceeded = cleanupSucceeded && cleanupResult
        }

        let oldBinding = binding ?? placeholderBinding(for: request)
        let fence = reconnect ?? USBManualReconnectFenceMetric(
            oldBinding: oldBinding,
            newBinding: finalBinding ?? oldBinding,
            oldOperationStopped: false, oldOperationSuppressed: false,
            newSessionReady: false)
        let reportBinding = finalBinding ?? fence.newBinding
        return USBPanTiltStressReport(
            plan: plan, initialBinding: oldBinding,
            baselineFrames: baselineFrames, trials: trials,
            reconnect: fence, finalBinding: reportBinding,
            finalPosition: finalPosition, phase: phase,
            completed: failureCode == nil,
            executionFailureCode: failureCode,
            finalRestore: finalRestore,
            cleanupAttempted: cleanupAttempted,
            cleanupSucceeded: cleanupSucceeded,
            cameraImagesStored: false, physicalMotionVerified: false)
    }

    private struct CaseExecutionResult: Sendable {
        let trial: USBPanTiltStressTrial?
        let passed: Bool
        let failureCode: String?
        let cleanupAttempted: Bool
        let cleanupSucceeded: Bool
    }

    private static func executeCase(
        _ casePlan: USBPanTiltStressCasePlan,
        binding: USBManualAcceptanceBinding,
        plan: USBPanTiltStressPlan,
        request: USBPanTiltStressRequest,
        deadline: TimeInterval,
        adapter: USBPanTiltStressExecutorAdapter,
        clock: any ContinuousGimbalClock
    ) async -> CaseExecutionResult {
        let origin = plan.range.center
        let before: USBPanTiltStressHardwareObservation
        do {
            before = try await adapter.read()
            try validateObservation(before, binding: binding,
                                    range: plan.range, plan: plan)
            guard before.phase == "ready", !before.motionActive,
                  before.capabilities.position.distance(to: origin) <=
                    restorationToleranceRaw else {
                throw BridgeFailure("usb_pan_tilt_stress_origin_unstable",
                    "The next USB stress case does not start from its restored center")
            }
        } catch is CancellationError {
            return CaseExecutionResult(trial: nil, passed: false,
                failureCode: "cancelled", cleanupAttempted: false,
                cleanupSucceeded: true)
        } catch let error as BridgeFailure {
            return CaseExecutionResult(trial: nil, passed: false,
                failureCode: error.code, cleanupAttempted: false,
                cleanupSucceeded: true)
        } catch {
            return CaseExecutionResult(trial: nil, passed: false,
                failureCode: "usb_pan_tilt_stress_case_read_failed",
                cleanupAttempted: false, cleanupSucceeded: true)
        }

        let started = clock.now
        var samples: [USBPanTiltStressSample] = []
        var movementFailure: String?
        let moveTask = adapter.startMove(casePlan.target, binding.captureSessionID)
        let moveDeadline = min(deadline, started + request.holdSeconds)
        while movementFailure == nil && samples.count < plan.maximumSamplesPerCase &&
              clock.now < moveDeadline {
            do {
                try checkDeadline(moveDeadline, clock: clock)
                let observation = try await adapter.read()
                try validateObservation(observation, binding: binding,
                                        range: plan.range, plan: plan)
                if observation.phase == "moving", observation.motionActive {
                    guard let frame = observation.frame,
                          frame.isFresh(for: binding,
                            maximumAge: plan.maximumFrameAgeSeconds) else {
                        throw BridgeFailure("usb_pan_tilt_stress_frame_stale",
                            "A moving USB stress sample has no fresh frame")
                    }
                    let elapsed = observation.sampledUptime - started
                    guard elapsed.isFinite, elapsed >= 0 else {
                        throw BridgeFailure("usb_pan_tilt_stress_sample_timing",
                            "A USB stress sample has invalid timing")
                    }
                    samples.append(USBPanTiltStressSample(
                        elapsed: elapsed,
                        position: observation.capabilities.position,
                        frame: frame, phase: "moving", motionActive: true))
                    if samples.count >= minimumStopSamples,
                       observation.capabilities.position.distance(to:
                        casePlan.target) <= restorationToleranceRaw {
                        break
                    }
                }
                let next = min(moveDeadline, clock.now + request.pollInterval)
                try await clock.sleep(until: next)
            } catch is CancellationError {
                movementFailure = "cancelled"
            } catch let error as BridgeFailure {
                movementFailure = error.code
            } catch {
                movementFailure = "usb_pan_tilt_stress_observation_failed"
            }
        }

        let stop = await forceStop(adapter) ?? USBManualStopEvidence(
            submitted: false, verified: false, motionStopped: false,
            held: samples.last?.position, final: samples.last?.position,
            failureCode: "usb_pan_tilt_stress_stop_missing")
        let movementResult = await moveTask.result
        var caseFailure = movementFailure
        if !stop.verified {
            caseFailure = caseFailure ?? stop.failureCode ??
                "usb_pan_tilt_stress_stop_unverified"
        }
        // CameraService reports cancellation of an absolute approach after its
        // exact hold target has been stopped. That expected error is not a
        // second failure when the independent Stop evidence is good.
        if caseFailure == nil, case let .failure(error) = movementResult,
           !stop.verified {
            caseFailure = executionFailureCode(error)
        }

        var restore: USBManualRestoreEvidence?
        if stop.verified {
            do {
                restore = try await adapter.restore(
                    origin, binding.captureSessionID)
                if restore?.verified != true {
                    caseFailure = caseFailure ?? restore?.failureCode ??
                        "usb_pan_tilt_stress_restore_unverified"
                }
            } catch is CancellationError {
                restore = USBManualRestoreEvidence(
                    requested: origin, submitted: false, verified: false,
                    failureCode: "cancelled")
                caseFailure = caseFailure ?? "cancelled"
            } catch let error as BridgeFailure {
                restore = USBManualRestoreEvidence(
                    requested: origin, submitted: false, verified: false,
                    failureCode: error.code)
                caseFailure = caseFailure ?? error.code
            } catch {
                restore = USBManualRestoreEvidence(
                    requested: origin, submitted: false, verified: false,
                    failureCode: "usb_pan_tilt_stress_restore_failed")
                caseFailure = caseFailure ??
                    "usb_pan_tilt_stress_restore_failed"
            }
        } else {
            restore = USBManualRestoreEvidence(
                requested: origin, submitted: false, verified: false,
                failureCode: "restore_not_safe_after_stop_failure")
        }

        let holdDuration = min(plan.maximumHoldSeconds,
            max(0.15, max(0, clock.now - started)))
        let trial = USBPanTiltStressTrial(
            plan: casePlan, origin: origin,
            holdDurationSeconds: holdDuration, samples: samples,
            stop: stop,
            restore: restore ?? USBManualRestoreEvidence(
                requested: origin, submitted: false, verified: false,
                failureCode: "restore_not_attempted"))
        var cleanupSucceeded = stop.verified && restore?.verified == true
        var cleanupAttempted = true
        if !cleanupSucceeded, let cleanup = adapter.cleanup {
            cleanupSucceeded = await Task.detached(priority: .userInitiated) {
                await cleanup()
            }.value
            cleanupAttempted = true
        }
        let passed = caseFailure == nil && samples.count >= minimumStopSamples &&
            stop.verified && restore?.verified == true
        return CaseExecutionResult(trial: trial, passed: passed,
            failureCode: caseFailure, cleanupAttempted: cleanupAttempted,
            cleanupSucceeded: cleanupSucceeded)
    }

    private static func validateInitial(
        _ observation: USBPanTiltStressHardwareObservation,
        request: USBPanTiltStressRequest,
        range: USBPanTiltStressRange,
        plan: USBPanTiltStressPlan
    ) throws {
        guard observation.binding.isComplete,
              observation.binding.deviceID == request.expectedDeviceID,
              observation.binding.captureSessionID == request.expectedSessionID else {
            throw BridgeFailure("usb_pan_tilt_stress_session_changed",
                "Execute requires the exact current USB device and capture session")
        }
        try validateObservation(observation, binding: observation.binding,
                                range: range, plan: plan)
        guard observation.phase == "ready", !observation.motionActive,
              observation.capabilities.position == range.center else {
            throw BridgeFailure("usb_pan_tilt_stress_not_ready",
                "USB pan/tilt stress requires a fresh idle center")
        }
    }

    private static func validateObservation(
        _ observation: USBPanTiltStressHardwareObservation,
        binding: USBManualAcceptanceBinding,
        range: USBPanTiltStressRange,
        plan: USBPanTiltStressPlan
    ) throws {
        guard observation.binding == binding,
              observation.sampledUptime.isFinite,
              observation.capabilities.writable,
              observation.capabilities.minimum == range.minimum,
              observation.capabilities.maximum == range.maximum,
              range.contains(observation.capabilities.position) else {
            throw BridgeFailure("usb_pan_tilt_stress_range_changed",
                "The fresh USB range or attachment changed during stress execution")
        }
        if let frame = observation.frame,
           !frame.isFresh(for: binding,
                          maximumAge: plan.maximumFrameAgeSeconds) {
            throw BridgeFailure("usb_pan_tilt_stress_frame_stale",
                "The current USB scalar frame is stale or belongs to another session")
        }
    }

    private static func collectBaseline(
        binding: USBManualAcceptanceBinding,
        range: USBPanTiltStressRange,
        plan: USBPanTiltStressPlan,
        deadline: TimeInterval,
        adapter: USBPanTiltStressExecutorAdapter,
        clock: any ContinuousGimbalClock
    ) async throws -> [USBManualFrameEvidence] {
        var frames: [USBManualFrameEvidence] = []
        var IDs = Set<String>()
        for _ in 0..<maximumBaselineFrames {
            try checkDeadline(deadline, clock: clock)
            let observation = try await adapter.read()
            try validateObservation(observation, binding: binding,
                                    range: range, plan: plan)
            guard observation.phase == "ready", !observation.motionActive,
                  observation.capabilities.position == range.center else {
                throw BridgeFailure("usb_pan_tilt_stress_center_changed",
                    "The USB center moved during fresh baseline collection")
            }
            if let frame = observation.frame,
               frame.isFresh(for: binding,
                             maximumAge: plan.maximumFrameAgeSeconds),
               IDs.insert(frame.frameID).inserted {
                frames.append(frame)
            }
            if frames.count >= minimumStopSamples { return frames }
            try await clock.sleep(until: min(deadline,
                clock.now + USBPanTiltStressRequest.defaultPollInterval))
        }
        throw BridgeFailure("usb_pan_tilt_stress_fresh_frame_missing",
            "The USB capture did not provide three fresh distinct baseline frames")
    }

    private static func checkDeadline(
        _ deadline: TimeInterval,
        clock: any ContinuousGimbalClock
    ) throws {
        try Task.checkCancellation()
        guard deadline.isFinite, clock.now.isFinite, clock.now <= deadline else {
            throw BridgeFailure("usb_pan_tilt_stress_timeout",
                "USB pan/tilt stress exceeded its bounded execution time")
        }
    }

    private static func forceStop(
        _ adapter: USBPanTiltStressExecutorAdapter
    ) async -> USBManualStopEvidence? {
        await Task.detached(priority: .userInitiated) {
            try? await adapter.stop()
        }.value
    }

    private static func forceCleanup(
        _ adapter: USBPanTiltStressExecutorAdapter
    ) async -> Bool {
        guard let cleanup = adapter.cleanup else { return false }
        return await Task.detached(priority: .userInitiated) {
            await cleanup()
        }.value
    }

    private static func executionFailureCode(_ error: Error) -> String {
        if let failure = error as? BridgeFailure { return failure.code }
        if error is CancellationError { return "cancelled" }
        return "usb_pan_tilt_stress_move_failed"
    }

    private static func placeholderBinding(
        for request: USBPanTiltStressRequest
    ) -> USBManualAcceptanceBinding {
        USBManualAcceptanceBinding(
            deviceID: request.expectedDeviceID ?? "",
            captureSessionID: request.expectedSessionID ?? "",
            registryID: "", bootSessionID: "")
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
        check("execution_completed", report.completed)
        check("execution_cleanup", report.cleanupAttempted &&
            report.cleanupSucceeded)
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
        if let finalRestore = report.finalRestore {
            guard finalRestore.requested == report.plan.range.center,
                  finalRestore.submitted, finalRestore.verified,
                  finalRestore.failureCode == nil,
                  finalRestore.stableSampleCount >= minimumStopSamples,
                  finalRestore.stableDurationSeconds.isFinite,
                  finalRestore.stableDurationSeconds >= minimumStopDuration,
                  let observed = finalRestore.observed,
                  observed.distance(to: report.plan.range.center) <=
                    restorationToleranceRaw else { return false }
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
public typealias Pocket3USBPanTiltStressExecutorAdapter = USBPanTiltStressExecutorAdapter
public typealias Pocket3USBPanTiltStressHardwareObservation = USBPanTiltStressHardwareObservation
