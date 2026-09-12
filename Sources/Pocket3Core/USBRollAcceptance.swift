import Foundation

/// Developer-only request for the independent USB Roll moving-stop check.
/// `rawValue` is a signed UVC value; omitting it chooses one advertised grid
/// step away from the fresh baseline. No raw value is widened or rounded.
public struct USBRollAcceptanceRequest: Codable, Sendable, Equatable {
    public static let operation = "validation-roll-acceptance"
    public static let defaultMoveSeconds: TimeInterval = 0.6
    public static let maximumMoveSeconds: TimeInterval = 1.2
    public static let defaultPollInterval: TimeInterval = 0.08
    public static let minimumPollInterval: TimeInterval = 0.04
    public static let maximumPollInterval: TimeInterval = 0.25
    public static let defaultTimeout: TimeInterval = 18
    public static let maximumTimeout: TimeInterval = 45
    public static let maximumProgressSamples = 24

    public let expectedDeviceID: String?
    public let expectedSessionID: String?
    public let rawValue: Int?
    public let moveSeconds: TimeInterval
    public let pollInterval: TimeInterval
    public let timeout: TimeInterval
    public let execute: Bool

    public init(expectedDeviceID: String? = nil,
                expectedSessionID: String? = nil,
                rawValue: Int? = nil,
                moveSeconds: TimeInterval = Self.defaultMoveSeconds,
                pollInterval: TimeInterval = Self.defaultPollInterval,
                timeout: TimeInterval = Self.defaultTimeout,
                execute: Bool = false) throws {
        if let expectedDeviceID {
            guard !expectedDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw USBRollAcceptanceRequestError.invalidArguments
            }
        }
        if let expectedSessionID {
            guard !expectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw USBRollAcceptanceRequestError.invalidArguments
            }
        }
        if execute {
            guard let expectedDeviceID, !expectedDeviceID.isEmpty,
                  let expectedSessionID, !expectedSessionID.isEmpty else {
                throw USBRollAcceptanceRequestError.identityRequired
            }
        }
        if let rawValue {
            guard USBRollPolicy.rawRange.contains(rawValue) else {
                throw USBRollAcceptanceRequestError.invalidRawValue
            }
        }
        guard moveSeconds.isFinite, moveSeconds > 0,
              moveSeconds <= Self.maximumMoveSeconds,
              pollInterval.isFinite,
              (Self.minimumPollInterval...Self.maximumPollInterval).contains(pollInterval),
              timeout.isFinite, timeout > 0, timeout <= Self.maximumTimeout,
              moveSeconds + pollInterval <= timeout else {
            throw USBRollAcceptanceRequestError.invalidArguments
        }
        self.expectedDeviceID = expectedDeviceID
        self.expectedSessionID = expectedSessionID
        self.rawValue = rawValue
        self.moveSeconds = moveSeconds
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.execute = execute
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                  "device", "session", "rawValue", "moveSeconds",
                  "pollInterval", "timeout", "execute"
              ]) else {
            throw USBRollAcceptanceRequestError.invalidArguments
        }
        let device = try Self.string(fields["device"])
        let session = try Self.string(fields["session"])
        let raw = try Self.raw(fields["rawValue"])
        let move = try Self.number(fields["moveSeconds"], default: Self.defaultMoveSeconds)
        let poll = try Self.number(fields["pollInterval"], default: Self.defaultPollInterval)
        let timeout = try Self.number(fields["timeout"], default: Self.defaultTimeout)
        let execute = try Self.boolean(fields["execute"])
        try self.init(expectedDeviceID: device, expectedSessionID: session,
                      rawValue: raw, moveSeconds: move, pollInterval: poll,
                      timeout: timeout, execute: execute)
    }

    public init(cliArguments: [String]) throws {
        var device: String?
        var session: String?
        var raw: Int?
        var move = Self.defaultMoveSeconds
        var poll = Self.defaultPollInterval
        var timeout = Self.defaultTimeout
        var execute = false
        var index = 0
        while index < cliArguments.count {
            let argument = cliArguments[index]
            if argument == "--execute" {
                guard !execute else { throw USBRollAcceptanceRequestError.invalidArguments }
                execute = true
                index += 1
                continue
            }
            guard index + 1 < cliArguments.count else {
                throw USBRollAcceptanceRequestError.invalidArguments
            }
            let value = cliArguments[index + 1]
            switch argument {
            case "--device":
                guard device == nil else { throw USBRollAcceptanceRequestError.invalidArguments }
                device = value
            case "--session":
                guard session == nil else { throw USBRollAcceptanceRequestError.invalidArguments }
                session = value
            case "--raw":
                guard raw == nil, let parsed = Int(value) else {
                    throw USBRollAcceptanceRequestError.invalidRawValue
                }
                raw = parsed
            case "--move-seconds":
                guard let parsed = Double(value) else { throw USBRollAcceptanceRequestError.invalidArguments }
                move = parsed
            case "--poll-interval":
                guard let parsed = Double(value) else { throw USBRollAcceptanceRequestError.invalidArguments }
                poll = parsed
            case "--timeout":
                guard let parsed = Double(value) else { throw USBRollAcceptanceRequestError.invalidArguments }
                timeout = parsed
            default:
                throw USBRollAcceptanceRequestError.invalidArguments
            }
            index += 2
        }
        try self.init(expectedDeviceID: device, expectedSessionID: session,
                      rawValue: raw, moveSeconds: move, pollInterval: poll,
                      timeout: timeout, execute: execute)
    }

    public var arguments: JSONValue {
        var fields: [String: JSONValue] = [
            "moveSeconds": .number(moveSeconds),
            "pollInterval": .number(pollInterval),
            "timeout": .number(timeout),
            "execute": .bool(execute)
        ]
        if let expectedDeviceID { fields["device"] = .string(expectedDeviceID) }
        if let expectedSessionID { fields["session"] = .string(expectedSessionID) }
        if let rawValue { fields["rawValue"] = .number(Double(rawValue)) }
        return .object(fields)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "device": .object(["type": .string("string"), "minLength": .number(1)]),
            "session": .object(["type": .string("string"), "minLength": .number(1)]),
            "rawValue": .object(["type": .string("integer"),
                                   "minimum": .number(Double(Int16.min)),
                                   "maximum": .number(Double(Int16.max))]),
            "moveSeconds": .object(["type": .string("number"),
                                     "exclusiveMinimum": .number(0),
                                     "maximum": .number(maximumMoveSeconds)]),
            "pollInterval": .object(["type": .string("number"),
                                      "minimum": .number(minimumPollInterval),
                                      "maximum": .number(maximumPollInterval)]),
            "timeout": .object(["type": .string("number"),
                                 "exclusiveMinimum": .number(0),
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
            throw USBRollAcceptanceRequestError.invalidArguments
        }
        return result
    }

    private static func raw(_ value: JSONValue?) throws -> Int? {
        guard let value else { return nil }
        guard let number = value.number, number.isFinite,
              number.rounded() == number,
              number >= Double(Int16.min), number <= Double(Int16.max) else {
            throw USBRollAcceptanceRequestError.invalidRawValue
        }
        return Int(number)
    }

    private static func number(_ value: JSONValue?, default fallback: Double) throws -> Double {
        guard let value else { return fallback }
        guard let result = value.number, result.isFinite else {
            throw USBRollAcceptanceRequestError.invalidArguments
        }
        return result
    }

    private static func boolean(_ value: JSONValue?) throws -> Bool {
        guard let value else { return false }
        guard let result = value.bool else {
            throw USBRollAcceptanceRequestError.invalidArguments
        }
        return result
    }
}

public enum USBRollAcceptanceRequestError: Error, Codable, Sendable, Equatable {
    case invalidArguments
    case identityRequired
    case invalidRawValue
}

/// The capture session and device identity supplied by the already-running
/// USB owner. Registry/boot IDs are retained when status exposes them, while
/// device/session remain the required fence for every acceptance operation.
public struct USBRollAcceptanceBinding: Codable, Sendable, Equatable, Hashable {
    public let deviceID: String
    public let captureSessionID: String
    public let registryID: String?
    public let bootSessionID: String?

    public init(deviceID: String, captureSessionID: String,
                registryID: String? = nil, bootSessionID: String? = nil) {
        self.deviceID = deviceID
        self.captureSessionID = captureSessionID
        self.registryID = registryID
        self.bootSessionID = bootSessionID
    }

    public var isComplete: Bool {
        !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !captureSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct USBRollAcceptanceProgressSample: Codable, Sendable, Equatable, Hashable {
    public let elapsed: TimeInterval
    public let phase: String
    public let observedRaw: Int
    public let targetRaw: Int
    public let minimumRaw: Int
    public let maximumRaw: Int
    public let stepRaw: Int
    public let sessionID: String
    public let deviceID: String

    public init(elapsed: TimeInterval, phase: String, observedRaw: Int,
                targetRaw: Int, minimumRaw: Int, maximumRaw: Int, stepRaw: Int,
                sessionID: String, deviceID: String) {
        self.elapsed = elapsed
        self.phase = phase
        self.observedRaw = observedRaw
        self.targetRaw = targetRaw
        self.minimumRaw = minimumRaw
        self.maximumRaw = maximumRaw
        self.stepRaw = stepRaw
        self.sessionID = sessionID
        self.deviceID = deviceID
    }
}

public struct USBRollAcceptanceRestoreEvidence: Codable, Sendable, Equatable, Hashable {
    public let requestedRaw: Int
    public let observedRaw: Int?
    public let submitted: Bool
    public let verified: Bool
    public let stableSampleCount: Int
    public let stableDurationSeconds: TimeInterval
    public let failureCode: String?

    public init(requestedRaw: Int, observedRaw: Int? = nil,
                submitted: Bool, verified: Bool, stableSampleCount: Int = 0,
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

public struct USBRollAcceptanceReconnectEvidence: Codable, Sendable, Equatable, Hashable {
    public let oldBinding: USBRollAcceptanceBinding
    public let newBinding: USBRollAcceptanceBinding?
    public let oldOperationStopped: Bool
    public let oldOperationSuppressed: Bool
    public let newSessionReady: Bool
    public let failureCode: String?

    public init(oldBinding: USBRollAcceptanceBinding,
                newBinding: USBRollAcceptanceBinding? = nil,
                oldOperationStopped: Bool, oldOperationSuppressed: Bool,
                newSessionReady: Bool, failureCode: String? = nil) {
        self.oldBinding = oldBinding
        self.newBinding = newBinding
        self.oldOperationStopped = oldOperationStopped
        self.oldOperationSuppressed = oldOperationSuppressed
        self.newSessionReady = newSessionReady
        self.failureCode = failureCode
    }
}

public struct USBRollAcceptancePlan: Codable, Sendable, Equatable, Hashable {
    public static let currentVersion = 1
    public static let currentProfile = "usb_roll_moving_stop_restore_v1"

    public let version: Int
    public let profile: String
    public let stages: [String]
    public let signedRawMinimum: Int
    public let signedRawMaximum: Int
    public let maximumMoveSeconds: TimeInterval
    public let stopStableWindowSeconds: TimeInterval
    public let maximumProgressSamples: Int
    public let hardwareExecutionEnabled: Bool
    public let cameraImagesStored: Bool

    public init(version: Int = Self.currentVersion,
                profile: String = Self.currentProfile,
                stages: [String] = [
                    "fresh_binding_and_roll_baseline",
                    "one_signed_raw_move_with_in_flight_progress",
                    "stop_and_stable_roll_readback",
                    "restore_original_raw_value",
                    "reconnect_old_session_fence"
                ], signedRawMinimum: Int = Int(Int16.min),
                signedRawMaximum: Int = Int(Int16.max),
                maximumMoveSeconds: TimeInterval = USBRollAcceptanceRequest.maximumMoveSeconds,
                stopStableWindowSeconds: TimeInterval = 0.8,
                maximumProgressSamples: Int = USBRollAcceptanceRequest.maximumProgressSamples,
                hardwareExecutionEnabled: Bool = false,
                cameraImagesStored: Bool = false) {
        self.version = version
        self.profile = profile
        self.stages = stages
        self.signedRawMinimum = signedRawMinimum
        self.signedRawMaximum = signedRawMaximum
        self.maximumMoveSeconds = maximumMoveSeconds
        self.stopStableWindowSeconds = stopStableWindowSeconds
        self.maximumProgressSamples = maximumProgressSamples
        self.hardwareExecutionEnabled = hardwareExecutionEnabled
        self.cameraImagesStored = cameraImagesStored
    }
}

public struct USBRollAcceptanceReport: Codable, Sendable, Equatable {
    public let version: Int
    public let profile: String
    public let phase: String
    public let completed: Bool
    public let expectedDeviceID: String?
    public let expectedSessionID: String?
    public let initialBinding: USBRollAcceptanceBinding?
    public let baseline: USBRollCapabilities?
    public let targetRaw: Int?
    public let progress: [USBRollAcceptanceProgressSample]
    public let stop: USBRollStopResult?
    public let restore: USBRollAcceptanceRestoreEvidence?
    public let reconnect: USBRollAcceptanceReconnectEvidence?
    public let finalBinding: USBRollAcceptanceBinding?
    public let cameraImagesStored: Bool
    public let physicalMotionVerified: Bool
    public let failureCode: String?
    public let plan: USBRollAcceptancePlan

    public init(version: Int = USBRollAcceptancePlan.currentVersion,
                profile: String = USBRollAcceptancePlan.currentProfile,
                phase: String, completed: Bool,
                expectedDeviceID: String?, expectedSessionID: String?,
                initialBinding: USBRollAcceptanceBinding? = nil,
                baseline: USBRollCapabilities? = nil, targetRaw: Int? = nil,
                progress: [USBRollAcceptanceProgressSample] = [],
                stop: USBRollStopResult? = nil,
                restore: USBRollAcceptanceRestoreEvidence? = nil,
                reconnect: USBRollAcceptanceReconnectEvidence? = nil,
                finalBinding: USBRollAcceptanceBinding? = nil,
                cameraImagesStored: Bool = false,
                physicalMotionVerified: Bool = false,
                failureCode: String? = nil,
                plan: USBRollAcceptancePlan = USBRollAcceptancePlan()) {
        self.version = version
        self.profile = profile
        self.phase = phase
        self.completed = completed
        self.expectedDeviceID = expectedDeviceID
        self.expectedSessionID = expectedSessionID
        self.initialBinding = initialBinding
        self.baseline = baseline
        self.targetRaw = targetRaw
        self.progress = progress
        self.stop = stop
        self.restore = restore
        self.reconnect = reconnect
        self.finalBinding = finalBinding
        self.cameraImagesStored = cameraImagesStored
        self.physicalMotionVerified = physicalMotionVerified
        self.failureCode = failureCode
        self.plan = plan
    }
}

public struct USBRollAcceptanceEvaluation: Codable, Sendable, Equatable {
    public let version: Int
    public let profile: String
    public let metricsPassed: Bool
    public let checks: [String: Bool]
    public let failureCode: String?
    public let cameraImagesStored: Bool
    public let physicalMotionVerified: Bool

    public init(version: Int, profile: String, metricsPassed: Bool,
                checks: [String: Bool], failureCode: String?,
                cameraImagesStored: Bool, physicalMotionVerified: Bool) {
        self.version = version
        self.profile = profile
        self.metricsPassed = metricsPassed
        self.checks = checks
        self.failureCode = failureCode
        self.cameraImagesStored = cameraImagesStored
        self.physicalMotionVerified = physicalMotionVerified
    }
}

public struct USBRollAcceptanceExecutorAdapter: Sendable {
    public typealias ReadCapabilities = @Sendable () async throws -> USBRollCapabilities
    public typealias StartMove = @Sendable (_ rawValue: Int, _ expectedSessionID: String) -> Task<USBRollResult, Error>
    public typealias Stop = @Sendable () async throws -> USBRollStopResult
    public typealias ReadBinding = @Sendable () async throws -> USBRollAcceptanceBinding
    public typealias Reconnect = @Sendable (_ oldBinding: USBRollAcceptanceBinding,
                                             _ oldTargetRaw: Int,
                                             _ request: USBRollAcceptanceRequest) async throws
        -> USBRollAcceptanceReconnectEvidence

    let readCapabilities: ReadCapabilities
    let startMove: StartMove
    let stop: Stop
    let readBinding: ReadBinding
    let reconnect: Reconnect

    public init(readCapabilities: @escaping ReadCapabilities,
                startMove: @escaping StartMove,
                stop: @escaping Stop,
                readBinding: @escaping ReadBinding,
                reconnect: @escaping Reconnect) {
        self.readCapabilities = readCapabilities
        self.startMove = startMove
        self.stop = stop
        self.readBinding = readBinding
        self.reconnect = reconnect
    }
}

public enum USBRollAcceptanceExecutor {
    public static let minimumProgressSamples = 2
    public static let stopStableWindowSeconds: TimeInterval = 0.8
    public static let maximumProgressElapsedSlack: TimeInterval = 0.25

    public static func dryRun(_ request: USBRollAcceptanceRequest) -> USBRollAcceptanceReport {
        USBRollAcceptanceReport(phase: "dry_run", completed: false,
            expectedDeviceID: request.expectedDeviceID,
            expectedSessionID: request.expectedSessionID,
            plan: USBRollAcceptancePlan(hardwareExecutionEnabled: false))
    }

    public static func targetRaw(_ requested: Int?, baseline: USBRollCapabilities) throws -> Int {
        guard baseline.minimum != nil, baseline.maximum != nil,
              baseline.step != nil else {
            throw BridgeFailure("roll_acceptance_baseline_invalid",
                "Roll baseline must expose a signed range and positive step")
        }
        if let requested {
            try USBRollPolicy.validate(requested, capabilities: baseline)
            guard requested != baseline.current else {
                throw BridgeFailure("roll_acceptance_noop",
                    "Roll acceptance target must differ from its fresh baseline")
            }
            return requested
        }
        guard let low = baseline.minimum, let high = baseline.maximum,
              let step = baseline.step else {
            throw BridgeFailure("roll_acceptance_baseline_invalid",
                "Roll baseline must expose a signed range and positive step")
        }
        let positive = Int64(baseline.current) + Int64(step)
        if positive <= Int64(high) {
            let value = Int(positive)
            try USBRollPolicy.validate(value, capabilities: baseline)
            return value
        }
        let negative = Int64(baseline.current) - Int64(step)
        guard negative >= Int64(low) else {
            throw BridgeFailure("roll_acceptance_no_target",
                "Roll baseline has no adjacent signed step inside its range")
        }
        let value = Int(negative)
        try USBRollPolicy.validate(value, capabilities: baseline)
        return value
    }

    public static func evaluate(_ report: USBRollAcceptanceReport) -> USBRollAcceptanceEvaluation {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) { checks[name] = value }

        check("schema", report.version == USBRollAcceptancePlan.currentVersion &&
            report.profile == USBRollAcceptancePlan.currentProfile)
        check("metrics_only", !report.cameraImagesStored && !report.physicalMotionVerified)
        check("initial_binding", report.initialBinding?.isComplete == true)
        check("baseline", report.baseline.flatMap { try? USBRollPolicy.validate($0.current, capabilities: $0) } != nil)
        let targetValid: Bool
        if let baseline = report.baseline, let target = report.targetRaw {
            targetValid = (try? USBRollPolicy.validate(target, capabilities: baseline)) != nil &&
                target != baseline.current
        } else { targetValid = false }
        check("signed_target", targetValid)
        check("in_flight_progress", progressPassed(report))
        check("stop_stable_window", stopPassed(report))
        check("restore", restorePassed(report))
        check("reconnect_session_fence", reconnectPassed(report))
        check("final_binding", report.finalBinding?.isComplete == true &&
            report.reconnect?.newBinding == report.finalBinding)

        let passed = checks.values.allSatisfy { $0 }
        let failure = passed ? nil : checks.first(where: { !$0.value })?.key
        return USBRollAcceptanceEvaluation(version: report.version,
            profile: report.profile, metricsPassed: passed, checks: checks,
            failureCode: failure, cameraImagesStored: report.cameraImagesStored,
            physicalMotionVerified: report.physicalMotionVerified)
    }

    public static func execute(
        _ request: USBRollAcceptanceRequest,
        adapter: USBRollAcceptanceExecutorAdapter,
        clock: any ContinuousGimbalClock = SystemContinuousGimbalClock()
    ) async -> USBRollAcceptanceReport {
        guard request.execute else { return dryRun(request) }
        var binding: USBRollAcceptanceBinding?
        var baseline: USBRollCapabilities?
        var target: Int?
        var progress: [USBRollAcceptanceProgressSample] = []
        var stopResult: USBRollStopResult?
        var restore: USBRollAcceptanceRestoreEvidence?
        var reconnect: USBRollAcceptanceReconnectEvidence?
        var finalBinding: USBRollAcceptanceBinding?
        var failureCode: String?
        var phase = "baseline"
        var moveTask: Task<USBRollResult, Error>?
        let runStarted = clock.now

        do {
            guard runStarted.isFinite else { throw BridgeFailure("roll_acceptance_timing", "Roll acceptance clock is invalid") }
            let initial = try await adapter.readBinding()
            guard initial.isComplete,
                  initial.deviceID == request.expectedDeviceID,
                  initial.captureSessionID == request.expectedSessionID else {
                throw BridgeFailure("roll_acceptance_session_changed",
                    "Roll acceptance requires the exact current device and capture session")
            }
            binding = initial
            let fresh = try await adapter.readCapabilities()
            baseline = fresh
            let chosen = try targetRaw(request.rawValue, baseline: fresh)
            target = chosen
            phase = "moving"
            let moveStarted = clock.now
            let deadline = runStarted + request.timeout
            guard moveStarted.isFinite, moveStarted <= deadline else {
                throw BridgeFailure("roll_acceptance_timeout", "Roll acceptance exceeded its bound before the move")
            }
            moveTask = adapter.startMove(chosen, initial.captureSessionID)
            let moveDeadline = min(deadline, moveStarted + request.moveSeconds)
            while clock.now < moveDeadline && progress.count < USBRollAcceptanceRequest.maximumProgressSamples {
                try Task.checkCancellation()
                let now = clock.now
                let current = try await adapter.readCapabilities()
                guard current.minimum == fresh.minimum,
                      current.maximum == fresh.maximum,
                      current.step == fresh.step,
                      current.writable,
                      current.current >= current.minimum ?? Int.min,
                      current.current <= current.maximum ?? Int.max else {
                    throw BridgeFailure("roll_acceptance_capabilities_changed",
                        "Roll range or step changed during the moving trial")
                }
                progress.append(USBRollAcceptanceProgressSample(
                    elapsed: max(0, now - moveStarted), phase: "moving",
                    observedRaw: current.current, targetRaw: chosen,
                    minimumRaw: current.minimum ?? Int(Int16.min),
                    maximumRaw: current.maximum ?? Int(Int16.max),
                    stepRaw: current.step ?? 0,
                    sessionID: initial.captureSessionID, deviceID: initial.deviceID))
                let next = min(moveDeadline, now + request.pollInterval)
                try await clock.sleep(until: next)
            }
            phase = "stopping"
            stopResult = try await adapter.stop()
            var movementError: Error?
            if let moveTask {
                do { _ = try await moveTask.value }
                catch { movementError = error }
            }
            guard stopResult?.verified == true else {
                if let movementError, let bridge = movementError as? BridgeFailure,
                   bridge.code == "session_changed" {
                    throw bridge
                }
                throw BridgeFailure("roll_acceptance_stop_unverified",
                    "Moving Roll stop did not produce a stable exact readback")
            }
            guard clock.now - runStarted <= request.timeout else {
                throw BridgeFailure("roll_acceptance_timeout", "Roll acceptance exceeded its bound")
            }
            phase = "restoring"
            let original = fresh.current
            let restoreTask = adapter.startMove(original, initial.captureSessionID)
            do {
                let result = try await restoreTask.value
                restore = USBRollAcceptanceRestoreEvidence(
                    requestedRaw: original, observedRaw: result.observed,
                    submitted: result.accepted, verified: result.verified,
                    stableSampleCount: result.sampleCount,
                    stableDurationSeconds: result.stableDurationSeconds,
                    failureCode: result.verified ? nil : "roll_acceptance_restore_unverified")
            } catch is CancellationError {
                restore = USBRollAcceptanceRestoreEvidence(
                    requestedRaw: original, submitted: true, verified: false,
                    failureCode: "cancelled")
                throw CancellationError()
            } catch let error as BridgeFailure {
                restore = USBRollAcceptanceRestoreEvidence(
                    requestedRaw: original, submitted: true, verified: false,
                    failureCode: error.code)
                throw error
            } catch {
                restore = USBRollAcceptanceRestoreEvidence(
                    requestedRaw: original, submitted: true, verified: false,
                    failureCode: "roll_acceptance_restore_failed")
                throw error
            }
            guard restore?.verified == true else {
                throw BridgeFailure("roll_acceptance_restore_unverified",
                    "Original Roll raw value was not stably restored")
            }
            phase = "reconnecting"
            reconnect = try await adapter.reconnect(initial, chosen, request)
            guard reconnect?.oldOperationStopped == true,
                  reconnect?.oldOperationSuppressed == true,
                  reconnect?.newSessionReady == true else {
                throw BridgeFailure("roll_acceptance_reconnect_unverified",
                    "Old Roll session was not fenced or the new session was not ready")
            }
            finalBinding = try await adapter.readBinding()
            guard let finalBinding,
                  finalBinding == reconnect?.newBinding else {
                throw BridgeFailure("roll_acceptance_reconnect_unverified",
                    "Final Roll binding does not match the reconnected session")
            }
            phase = "completed"
        } catch is CancellationError {
            failureCode = "cancelled"
            phase = "cancelled"
        } catch let error as BridgeFailure {
            failureCode = error.code
            phase = "failed"
        } catch {
            failureCode = "roll_acceptance_failed"
            phase = "failed"
        }

        // A failure during moving still receives one bounded Stop attempt. It
        // is cleanup evidence and never retries the original target SET.
        if phase == "failed" || phase == "cancelled", moveTask != nil,
           stopResult == nil {
            stopResult = try? await adapter.stop()
        }
        return USBRollAcceptanceReport(phase: phase, completed: phase == "completed",
            expectedDeviceID: request.expectedDeviceID,
            expectedSessionID: request.expectedSessionID,
            initialBinding: binding, baseline: baseline, targetRaw: target,
            progress: progress, stop: stopResult, restore: restore,
            reconnect: reconnect, finalBinding: finalBinding,
            failureCode: failureCode,
            plan: USBRollAcceptancePlan(hardwareExecutionEnabled: true))
    }

    private static func progressPassed(_ report: USBRollAcceptanceReport) -> Bool {
        guard let baseline = report.baseline, let target = report.targetRaw,
              let binding = report.initialBinding,
              report.progress.count >= minimumProgressSamples,
              report.progress.count <= USBRollAcceptanceRequest.maximumProgressSamples else { return false }
        let direction = target > baseline.current ? 1 : -1
        var previous = baseline.current
        var previousElapsed = -Double.ulpOfOne
        for value in report.progress {
            guard value.phase == "moving", value.sessionID == binding.captureSessionID,
                  value.deviceID == binding.deviceID,
                  value.elapsed.isFinite, value.elapsed >= 0,
                  value.elapsed > previousElapsed,
                  value.elapsed <= USBRollAcceptanceRequest.maximumMoveSeconds + maximumProgressElapsedSlack,
                  value.minimumRaw == baseline.minimum,
                  value.maximumRaw == baseline.maximum,
                  value.stepRaw == baseline.step else { return false }
            guard (value.observedRaw - previous) * direction >= 0 else { return false }
            previous = value.observedRaw
            previousElapsed = value.elapsed
        }
        return true
    }

    private static func stopPassed(_ report: USBRollAcceptanceReport) -> Bool {
        guard let stop = report.stop else { return false }
        return stop.submitted && stop.verified && stop.failure == nil &&
            stop.target != nil && stop.observed == stop.target &&
            stop.sampleCount >= 3 &&
            stop.stableDurationSeconds >= stopStableWindowSeconds - 1e-9
    }

    private static func restorePassed(_ report: USBRollAcceptanceReport) -> Bool {
        guard let baseline = report.baseline, let restore = report.restore else { return false }
        return restore.requestedRaw == baseline.current && restore.submitted &&
            restore.verified && restore.failureCode == nil &&
            restore.observedRaw == baseline.current &&
            restore.stableSampleCount >= 3 &&
            restore.stableDurationSeconds >= USBRollReadbackVerifierMinimums.minimumDuration - 1e-9
    }

    private static func reconnectPassed(_ report: USBRollAcceptanceReport) -> Bool {
        guard let reconnect = report.reconnect,
              reconnect.oldBinding.isComplete,
              let newBinding = reconnect.newBinding,
              newBinding.isComplete,
              newBinding != reconnect.oldBinding,
              reconnect.oldOperationStopped,
              reconnect.oldOperationSuppressed,
              reconnect.newSessionReady,
              reconnect.failureCode == nil else { return false }
        return true
    }
}

/// The existing Roll verifier's minimum exact window is intentionally kept in
/// one place. This tiny namespace avoids exposing another mutable verifier.
private enum USBRollReadbackVerifierMinimums {
    static let minimumDuration: TimeInterval = 0.2
}

public typealias Pocket3USBRollAcceptanceRequest = USBRollAcceptanceRequest
public typealias Pocket3USBRollAcceptanceReport = USBRollAcceptanceReport
