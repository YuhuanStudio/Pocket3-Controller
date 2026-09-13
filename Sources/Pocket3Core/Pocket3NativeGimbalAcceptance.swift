import Foundation

public enum Pocket3NativeGimbalAcceptancePhase: String, Codable, Sendable,
    Equatable, CaseIterable {
    case dryRun = "dry_run"
    case running
    case completed
    case partial
    case cancelled
    case connectionChanged = "connection_changed"
    case blocked
}

public enum Pocket3NativeGimbalAcceptanceStepKind: String, Codable, Sendable,
    Equatable, CaseIterable {
    case nearPan = "near_pan"
    case midPan = "mid_pan"
    case farPan = "far_pan"
    case nearTilt = "near_tilt"
    case midTilt = "mid_tilt"
    case farTilt = "far_tilt"
    case releaseNeutral = "release_neutral"
    case recenterFE08 = "recenter_fe08"
    case flipFE09 = "flip_fe09"
}

public enum Pocket3NativeGimbalAcceptanceError: Error, Codable, Sendable,
    Equatable {
    case invalidRequest
    case ownerUnavailable
    case ownerNotReady
    case stationIdentityMismatch
    case connectionChanged
    case timeout
    case neutralFailed
}

public protocol Pocket3NativeGimbalAcceptanceClock: Sendable {
    var now: TimeInterval { get }
    func sleep(until deadline: TimeInterval) async throws
}

public struct SystemPocket3NativeGimbalAcceptanceClock:
    Pocket3NativeGimbalAcceptanceClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(until deadline: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline - now)))
    }
}

/// Scalar evidence returned by the already-connected station owner. It is
/// deliberately richer than a Boolean so ACK, telemetry freshness and exact
/// session/identity fences cannot be conflated.
public struct Pocket3NativeGimbalAcceptanceStatus: Codable, Sendable,
    Equatable {
    public let stationBinding: Pocket3StationSessionBinding
    public let lanIdentity: Pocket3StationIdentity
    public let lanOwnerRetained: Bool
    public let nativeBinding: ContinuousGimbalBinding
    public let nativePhase: Pocket3DatalinkPhase
    public let telemetry: Pocket3DatalinkTelemetry?
    public let telemetryFresh: Bool
    public let commandReady: Bool
    public let observedUptime: TimeInterval

    public init(stationBinding: Pocket3StationSessionBinding,
                lanIdentity: Pocket3StationIdentity,
                lanOwnerRetained: Bool,
                nativeBinding: ContinuousGimbalBinding,
                nativePhase: Pocket3DatalinkPhase,
                telemetry: Pocket3DatalinkTelemetry?,
                telemetryFresh: Bool, commandReady: Bool,
                observedUptime: TimeInterval) {
        self.stationBinding = stationBinding
        self.lanIdentity = lanIdentity
        self.lanOwnerRetained = lanOwnerRetained
        self.nativeBinding = nativeBinding
        self.nativePhase = nativePhase
        self.telemetry = telemetry
        self.telemetryFresh = telemetryFresh
        self.commandReady = commandReady
        self.observedUptime = observedUptime
    }

    public func isExact(for request: Pocket3NativeGimbalAcceptanceRequest)
        -> Bool {
        lanOwnerRetained && commandReady && telemetryFresh &&
            stationBinding == request.stationBinding &&
            lanIdentity.matches(request.stationBinding.bleIdentity) &&
            lanIdentity.raw == request.stationBinding.bleIdentity.raw &&
            nativeBinding == request.nativeBinding
    }
}

public struct Pocket3NativeGimbalStopEvidence: Codable, Sendable, Equatable {
    public let neutralSent: Bool
    public let stableTelemetry: Bool
    public let connectionChanged: Bool
    public let telemetryBefore: Pocket3DatalinkTelemetry?
    public let telemetryAfter: Pocket3DatalinkTelemetry?
    public let failureCode: String?

    public init(neutralSent: Bool, stableTelemetry: Bool = false,
                connectionChanged: Bool = false,
                telemetryBefore: Pocket3DatalinkTelemetry? = nil,
                telemetryAfter: Pocket3DatalinkTelemetry? = nil,
                failureCode: String? = nil) {
        self.neutralSent = neutralSent
        self.stableTelemetry = stableTelemetry
        self.connectionChanged = connectionChanged
        self.telemetryBefore = telemetryBefore
        self.telemetryAfter = telemetryAfter
        self.failureCode = failureCode
    }
}

/// The only I/O boundary used by the acceptance coordinator. Production uses
/// `Pocket3StationNativeGimbalOwner`, which wraps the existing Datalink;
/// tests inject a fake owner without opening sockets or BLE.
public protocol Pocket3NativeGimbalAcceptanceOwner: Sendable {
    func status() async -> Pocket3NativeGimbalAcceptanceStatus
    func send(_ input: ContinuousGimbalInput, lease: ContinuousGimbalLease,
              permit: OperationPermit) async throws
    func release(_ lease: ContinuousGimbalLease,
                 permit: OperationPermit) async throws
        -> Pocket3NativeGimbalStopEvidence
    func recenter(permit: OperationPermit) async throws
        -> Pocket3DatalinkActionResult
    func flip(permit: OperationPermit) async throws
        -> Pocket3DatalinkActionResult
    /// Must be cancellation-independent at the owner boundary and attempt a
    /// single neutral cleanup for the exact native binding.
    func failStop() async -> Pocket3NativeGimbalStopEvidence
}

public struct Pocket3NativeGimbalAcceptanceRequest: Codable, Sendable,
    Equatable {
    public static let defaultHoldSeconds: TimeInterval = 0.5
    public static let defaultPumpInterval: TimeInterval = 0.05
    public static let defaultTelemetryTimeout: TimeInterval = 1.5

    public let stationBinding: Pocket3StationSessionBinding
    public let lanEvidence: Pocket3StationLANEvidence
    public let nativeBinding: ContinuousGimbalBinding
    public let holdSeconds: TimeInterval
    public let pumpInterval: TimeInterval
    public let telemetryTimeout: TimeInterval
    public let execute: Bool

    public init(stationBinding: Pocket3StationSessionBinding,
                lanEvidence: Pocket3StationLANEvidence,
                nativeBinding: ContinuousGimbalBinding,
                holdSeconds: TimeInterval = Self.defaultHoldSeconds,
                pumpInterval: TimeInterval = Self.defaultPumpInterval,
                telemetryTimeout: TimeInterval = Self.defaultTelemetryTimeout,
                execute: Bool = false) throws {
        guard lanEvidence.transportReady,
              lanEvidence.identityReplyValidated,
              lanEvidence.identity.matches(stationBinding.bleIdentity),
              lanEvidence.identityRaw == stationBinding.bleIdentity.raw,
              nativeBinding.generation != 0,
              !nativeBinding.sessionID.isEmpty,
              holdSeconds.isFinite, (0.1...2).contains(holdSeconds),
              pumpInterval.isFinite, (0.05...0.2).contains(pumpInterval),
              telemetryTimeout.isFinite, (0.2...3).contains(telemetryTimeout),
              holdSeconds >= pumpInterval else {
            throw Pocket3NativeGimbalAcceptanceError.invalidRequest
        }
        self.stationBinding = stationBinding
        self.lanEvidence = lanEvidence
        self.nativeBinding = nativeBinding
        self.holdSeconds = holdSeconds
        self.pumpInterval = pumpInterval
        self.telemetryTimeout = telemetryTimeout
        self.execute = execute
    }
}

public struct Pocket3NativeGimbalAcceptanceStepResult: Codable, Sendable,
    Equatable {
    public let kind: Pocket3NativeGimbalAcceptanceStepKind
    public let x: Double?
    public let y: Double?
    public let speed: Double?
    public let submittedFrames: Int
    public let acknowledged: Bool
    public let releaseNeutralSent: Bool
    public let telemetryBefore: Pocket3DatalinkTelemetry?
    public let telemetryAfter: Pocket3DatalinkTelemetry?
    public let telemetryObserved: Bool
    public let timedOut: Bool
    public let connectionChanged: Bool
    public let physicalCompletionVerified: Bool
    public let completed: Bool
    public let failureCode: String?

    init(kind: Pocket3NativeGimbalAcceptanceStepKind,
         input: ContinuousGimbalInput? = nil, submittedFrames: Int = 0,
         acknowledged: Bool = false, releaseNeutralSent: Bool = false,
         telemetryBefore: Pocket3DatalinkTelemetry? = nil,
         telemetryAfter: Pocket3DatalinkTelemetry? = nil,
         telemetryObserved: Bool = false, timedOut: Bool = false,
         connectionChanged: Bool = false,
         physicalCompletionVerified: Bool = false, completed: Bool = false,
         failureCode: String? = nil) {
        self.kind = kind
        x = input?.x; y = input?.y; speed = input?.speed
        self.submittedFrames = submittedFrames
        self.acknowledged = acknowledged
        self.releaseNeutralSent = releaseNeutralSent
        self.telemetryBefore = telemetryBefore
        self.telemetryAfter = telemetryAfter
        self.telemetryObserved = telemetryObserved
        self.timedOut = timedOut
        self.connectionChanged = connectionChanged
        self.physicalCompletionVerified = physicalCompletionVerified
        self.completed = completed
        self.failureCode = failureCode
    }
}

public struct Pocket3NativeGimbalAcceptancePlan: Codable, Sendable, Equatable {
    public let executeRequested: Bool
    public let steps: [Pocket3NativeGimbalAcceptanceStepKind]
    public let holdSeconds: TimeInterval
    public let pumpInterval: TimeInterval
    public let telemetryTimeout: TimeInterval
    public let requiresExactStationOwner: Bool
    public let sendsImages: Bool
    public let changesMacWiFi: Bool

    init(request: Pocket3NativeGimbalAcceptanceRequest) {
        executeRequested = request.execute
        steps = Pocket3NativeGimbalAcceptanceExecutor.movementSteps + [
            .recenterFE08, .flipFE09, .releaseNeutral
        ]
        holdSeconds = request.holdSeconds
        pumpInterval = request.pumpInterval
        telemetryTimeout = request.telemetryTimeout
        requiresExactStationOwner = true
        sendsImages = false
        changesMacWiFi = false
    }
}

public struct Pocket3NativeGimbalAcceptanceResult: Codable, Sendable,
    Equatable {
    public let phase: Pocket3NativeGimbalAcceptancePhase
    public let executeRequested: Bool
    public let plan: Pocket3NativeGimbalAcceptancePlan
    public let initialStatus: Pocket3NativeGimbalAcceptanceStatus?
    public let finalStatus: Pocket3NativeGimbalAcceptanceStatus?
    public let steps: [Pocket3NativeGimbalAcceptanceStepResult]
    public let failStop: Pocket3NativeGimbalStopEvidence?
    public let acknowledged: Bool
    public let telemetryObserved: Bool
    public let completed: Bool
    public let failureCode: String?

    public var dryRun: Bool { !executeRequested }

    init(phase: Pocket3NativeGimbalAcceptancePhase,
         request: Pocket3NativeGimbalAcceptanceRequest,
         initialStatus: Pocket3NativeGimbalAcceptanceStatus?,
         finalStatus: Pocket3NativeGimbalAcceptanceStatus?,
         steps: [Pocket3NativeGimbalAcceptanceStepResult],
         failStop: Pocket3NativeGimbalStopEvidence?, failureCode: String?) {
        self.phase = phase
        executeRequested = request.execute
        plan = Pocket3NativeGimbalAcceptancePlan(request: request)
        self.initialStatus = initialStatus
        self.finalStatus = finalStatus
        self.steps = Array(steps.prefix(16))
        self.failStop = failStop
        let ackSteps = steps.filter {
            $0.kind == .recenterFE08 || $0.kind == .flipFE09
        }
        // 04/01 is notify/no-ACK; only FE08/FE09 contribute to the ACK
        // summary. Submission and neutral transport completion remain typed
        // separately on every movement step.
        acknowledged = !ackSteps.isEmpty && ackSteps.allSatisfy { $0.acknowledged }
        telemetryObserved = steps.contains { $0.telemetryObserved }
        completed = phase == .completed && steps.allSatisfy { $0.completed }
        self.failureCode = failureCode
    }
}

/// Bounded station acceptance executor. It is dry-run unless the request's
/// `execute` flag is explicitly set; the App/CLI remains responsible for its
/// developer validation gate before creating a real owner.
public struct Pocket3NativeGimbalAcceptanceExecutor: Sendable {
    fileprivate static let movementSteps: [Pocket3NativeGimbalAcceptanceStepKind] = [
        .nearPan, .midPan, .farPan, .nearTilt, .midTilt, .farTilt
    ]

    private let owner: (any Pocket3NativeGimbalAcceptanceOwner)?
    private let clock: any Pocket3NativeGimbalAcceptanceClock

    public init(owner: (any Pocket3NativeGimbalAcceptanceOwner)? = nil,
                clock: any Pocket3NativeGimbalAcceptanceClock =
                    SystemPocket3NativeGimbalAcceptanceClock()) {
        self.owner = owner
        self.clock = clock
    }

    public func run(
        _ request: Pocket3NativeGimbalAcceptanceRequest
    ) async -> Pocket3NativeGimbalAcceptanceResult {
        guard request.execute else {
            return Pocket3NativeGimbalAcceptanceResult(
                phase: .dryRun, request: request, initialStatus: nil,
                finalStatus: nil, steps: [], failStop: nil, failureCode: nil)
        }
        guard let owner else {
            return Pocket3NativeGimbalAcceptanceResult(
                phase: .blocked, request: request, initialStatus: nil,
                finalStatus: nil, steps: [], failStop: nil,
                failureCode: "station_acceptance_owner_unavailable")
        }
        let initial = await owner.status()
        guard initial.isExact(for: request) else {
            return Pocket3NativeGimbalAcceptanceResult(
                phase: .blocked, request: request, initialStatus: initial,
                finalStatus: initial, steps: [], failStop: nil,
                failureCode: "station_acceptance_owner_not_ready")
        }

        var steps: [Pocket3NativeGimbalAcceptanceStepResult] = []
        var finalStatus: Pocket3NativeGimbalAcceptanceStatus? = initial
        do {
            for kind in Self.movementSteps {
                try Task.checkCancellation()
                do {
                    let step = try await movement(kind: kind, request: request,
                                                  owner: owner)
                    steps.append(step)
                    guard step.completed else {
                        throw Pocket3NativeGimbalAcceptanceError.timeout
                    }
                } catch let failure as StepFailure {
                    steps.append(failure.step)
                    throw failure.error
                }
            }

            for kind in [Pocket3NativeGimbalAcceptanceStepKind.recenterFE08,
                         .flipFE09] {
                try Task.checkCancellation()
                do {
                    let step = try await preset(kind: kind, request: request,
                                                owner: owner)
                    steps.append(step)
                    guard step.completed else {
                        throw Pocket3NativeGimbalAcceptanceError.timeout
                    }
                } catch let failure as StepFailure {
                    steps.append(failure.step)
                    throw failure.error
                }
            }

            let stop = await owner.failStop()
            let release = Pocket3NativeGimbalAcceptanceStepResult(
                kind: .releaseNeutral, submittedFrames: 0,
                acknowledged: false,
                releaseNeutralSent: stop.neutralSent,
                telemetryBefore: stop.telemetryBefore,
                telemetryAfter: stop.telemetryAfter,
                telemetryObserved: Self.telemetryChanged(
                    before: stop.telemetryBefore, after: stop.telemetryAfter),
                connectionChanged: stop.connectionChanged,
                completed: stop.neutralSent && !stop.connectionChanged,
                failureCode: stop.failureCode)
            steps.append(release)
            finalStatus = await owner.status()
            guard release.completed else {
                return Pocket3NativeGimbalAcceptanceResult(
                    phase: stop.connectionChanged ? .connectionChanged : .partial,
                    request: request, initialStatus: initial,
                    finalStatus: finalStatus, steps: steps, failStop: stop,
                    failureCode: stop.failureCode ?? "station_acceptance_neutral_failed")
            }
            return Pocket3NativeGimbalAcceptanceResult(
                phase: .completed, request: request, initialStatus: initial,
                finalStatus: finalStatus, steps: steps, failStop: stop,
                failureCode: nil)
        } catch is CancellationError {
            let stop = await owner.failStop()
            finalStatus = await owner.status()
            return Pocket3NativeGimbalAcceptanceResult(
                phase: .cancelled, request: request, initialStatus: initial,
                finalStatus: finalStatus, steps: steps, failStop: stop,
                failureCode: stop.failureCode ?? "station_acceptance_cancelled")
        } catch let error as Pocket3NativeGimbalAcceptanceError {
            let stop = await owner.failStop()
            finalStatus = await owner.status()
            let cancelled = Task.isCancelled
            let connectionChanged = error == .connectionChanged ||
                stop.connectionChanged
            return Pocket3NativeGimbalAcceptanceResult(
                phase: cancelled ? .cancelled :
                    (connectionChanged ? .connectionChanged : .partial),
                request: request, initialStatus: initial,
                finalStatus: finalStatus, steps: steps, failStop: stop,
                failureCode: stop.failureCode ??
                    (cancelled ? "station_acceptance_cancelled" : Self.code(error)))
        } catch {
            let stop = await owner.failStop()
            finalStatus = await owner.status()
            return Pocket3NativeGimbalAcceptanceResult(
                phase: .partial, request: request, initialStatus: initial,
                finalStatus: finalStatus, steps: steps, failStop: stop,
                failureCode: stop.failureCode ?? "station_acceptance_failed")
        }
    }

    private func movement(
        kind: Pocket3NativeGimbalAcceptanceStepKind,
        request: Pocket3NativeGimbalAcceptanceRequest,
        owner: any Pocket3NativeGimbalAcceptanceOwner
    ) async throws -> Pocket3NativeGimbalAcceptanceStepResult {
        let input = try Self.input(for: kind)
        let before = await owner.status()
        guard before.isExact(for: request) else {
            throw StepFailure(
                step: .init(kind: kind, input: input, connectionChanged: true,
                            failureCode: "station_acceptance_connection_changed"),
                error: .connectionChanged)
        }
        let lease = ContinuousGimbalLease(id: UUID(),
                                          binding: request.nativeBinding)
        let permit = OperationPermit()
        var submitted = 0
        let deadline = clock.now + request.holdSeconds
        do {
            while clock.now < deadline {
                try Task.checkCancellation()
                guard (await owner.status()).isExact(for: request) else {
                    throw Pocket3NativeGimbalAcceptanceError.connectionChanged
                }
                try await owner.send(input, lease: lease, permit: permit)
                submitted += 1
                try await clock.sleep(until: min(deadline,
                                                clock.now + request.pumpInterval))
            }
            let stop = try await owner.release(lease, permit: permit)
            let after = await owner.status()
            let telemetryObserved = Self.telemetryChanged(
                before: before.telemetry, after: stop.telemetryAfter ?? after.telemetry)
            let changed = stop.connectionChanged || !after.isExact(for: request)
            return .init(kind: kind, input: input, submittedFrames: submitted,
                         acknowledged: false,
                         releaseNeutralSent: stop.neutralSent,
                         telemetryBefore: before.telemetry,
                         telemetryAfter: stop.telemetryAfter ?? after.telemetry,
                         telemetryObserved: telemetryObserved,
                         connectionChanged: changed,
                         completed: submitted > 0 && stop.neutralSent &&
                            telemetryObserved && !changed,
                         failureCode: stop.failureCode)
        } catch is CancellationError {
            throw StepFailure(
                step: .init(kind: kind, input: input,
                            submittedFrames: submitted,
                            acknowledged: false,
                            connectionChanged: true,
                            failureCode: "station_acceptance_cancelled"),
                error: .timeout)
        } catch let error as Pocket3NativeGimbalAcceptanceError {
            throw StepFailure(
                step: .init(kind: kind, input: input,
                            submittedFrames: submitted,
                            acknowledged: false,
                            connectionChanged: error == .connectionChanged,
                            failureCode: Self.code(error)), error: error)
        } catch {
            throw StepFailure(
                step: .init(kind: kind, input: input,
                            submittedFrames: submitted,
                            acknowledged: false,
                            failureCode: "station_acceptance_send_failed"),
                error: .timeout)
        }
    }

    private func preset(
        kind: Pocket3NativeGimbalAcceptanceStepKind,
        request: Pocket3NativeGimbalAcceptanceRequest,
        owner: any Pocket3NativeGimbalAcceptanceOwner
    ) async throws -> Pocket3NativeGimbalAcceptanceStepResult {
        let before = await owner.status()
        guard before.isExact(for: request) else {
            throw StepFailure(
                step: .init(kind: kind, connectionChanged: true,
                            failureCode: "station_acceptance_connection_changed"),
                error: .connectionChanged)
        }
        do {
            let action: Pocket3DatalinkActionResult
            if kind == .recenterFE08 {
                action = try await owner.recenter(permit: OperationPermit())
            } else {
                action = try await owner.flip(permit: OperationPermit())
            }
            let telemetry = try await waitForTelemetry(
                before: before, request: request, owner: owner)
            let changed = telemetry.connectionChanged
            return .init(kind: kind, acknowledged: action.requestAccepted,
                         telemetryBefore: before.telemetry,
                         telemetryAfter: telemetry.status.telemetry,
                         telemetryObserved: telemetry.observed,
                         timedOut: !telemetry.observed,
                         connectionChanged: changed,
                         // Telemetry is scalar evidence only; no physical
                         // angle/flip completion is inferred from an ACK.
                         physicalCompletionVerified: false,
                         completed: action.requestAccepted && telemetry.observed &&
                            !changed,
                         failureCode: action.requestAccepted ? nil :
                            "station_acceptance_action_rejected")
        } catch is CancellationError {
            throw StepFailure(
                step: .init(kind: kind, connectionChanged: true,
                            failureCode: "station_acceptance_cancelled"),
                error: .connectionChanged)
        } catch let error as Pocket3NativeGimbalAcceptanceError {
            throw StepFailure(
                step: .init(kind: kind,
                            connectionChanged: error == .connectionChanged,
                            failureCode: Self.code(error)), error: error)
        } catch {
            throw StepFailure(
                step: .init(kind: kind, failureCode: "station_acceptance_action_failed"),
                error: .timeout)
        }
    }

    private struct TelemetryWait: Sendable {
        let status: Pocket3NativeGimbalAcceptanceStatus
        let observed: Bool
        let connectionChanged: Bool
    }

    private func waitForTelemetry(
        before: Pocket3NativeGimbalAcceptanceStatus,
        request: Pocket3NativeGimbalAcceptanceRequest,
        owner: any Pocket3NativeGimbalAcceptanceOwner
    ) async throws -> TelemetryWait {
        let deadline = clock.now + request.telemetryTimeout
        var latest = before
        while clock.now < deadline {
            try Task.checkCancellation()
            latest = await owner.status()
            guard latest.stationBinding == request.stationBinding,
                  latest.nativeBinding == request.nativeBinding,
                  latest.lanIdentity.raw == request.stationBinding.bleIdentity.raw,
                  latest.lanOwnerRetained, latest.commandReady else {
                return TelemetryWait(status: latest, observed: false,
                                     connectionChanged: true)
            }
            if Self.telemetryChanged(before: before.telemetry,
                                     after: latest.telemetry) && latest.telemetryFresh {
                return TelemetryWait(status: latest, observed: true,
                                     connectionChanged: false)
            }
            try await clock.sleep(until: min(deadline,
                                            clock.now + request.pumpInterval))
        }
        return TelemetryWait(status: latest, observed: false,
                             connectionChanged: false)
    }

    private static func input(
        for kind: Pocket3NativeGimbalAcceptanceStepKind
    ) throws -> ContinuousGimbalInput {
        switch kind {
        case .nearPan: return try .init(x: 0.2, y: 0, speed: 0.25)
        case .midPan: return try .init(x: 0.5, y: 0, speed: 0.5)
        case .farPan: return try .init(x: 0.9, y: 0, speed: 0.75)
        case .nearTilt: return try .init(x: 0, y: 0.2, speed: 0.25)
        case .midTilt: return try .init(x: 0, y: 0.5, speed: 0.5)
        case .farTilt: return try .init(x: 0, y: 0.9, speed: 0.75)
        default: throw Pocket3NativeGimbalAcceptanceError.invalidRequest
        }
    }

    private static func telemetryChanged(
        before: Pocket3DatalinkTelemetry?,
        after: Pocket3DatalinkTelemetry?
    ) -> Bool {
        guard let after else { return false }
        guard let before else { return true }
        return after.receivedAt > before.receivedAt
    }

    private static func code(_ error: Pocket3NativeGimbalAcceptanceError)
        -> String {
        switch error {
        case .invalidRequest: "station_acceptance_invalid_request"
        case .ownerUnavailable: "station_acceptance_owner_unavailable"
        case .ownerNotReady: "station_acceptance_owner_not_ready"
        case .stationIdentityMismatch: "station_acceptance_identity_mismatch"
        case .connectionChanged: "station_acceptance_connection_changed"
        case .timeout: "station_acceptance_timeout"
        case .neutralFailed: "station_acceptance_neutral_failed"
        }
    }

    private struct StepFailure: Error {
        let step: Pocket3NativeGimbalAcceptanceStepResult
        let error: Pocket3NativeGimbalAcceptanceError
    }
}

/// Adapter over the existing Pocket3Datalink owner. No socket or transport is
/// created here; callers pass the exact link returned by station discovery.
public final class Pocket3StationNativeGimbalOwner:
    Pocket3NativeGimbalAcceptanceOwner, @unchecked Sendable {
    private let link: Pocket3Datalink
    private let stationBinding: Pocket3StationSessionBinding
    private let lanEvidence: Pocket3StationLANEvidence
    private let nativeBinding: ContinuousGimbalBinding

    public init(link: Pocket3Datalink,
                stationBinding: Pocket3StationSessionBinding,
                lanEvidence: Pocket3StationLANEvidence,
                nativeBinding: ContinuousGimbalBinding) throws {
        guard lanEvidence.transportReady,
              lanEvidence.identityReplyValidated,
              lanEvidence.identity.matches(stationBinding.bleIdentity),
              lanEvidence.identityRaw == stationBinding.bleIdentity.raw,
              nativeBinding.generation != 0, !nativeBinding.sessionID.isEmpty else {
            throw Pocket3NativeGimbalAcceptanceError.stationIdentityMismatch
        }
        self.link = link
        self.stationBinding = stationBinding
        self.lanEvidence = lanEvidence
        self.nativeBinding = nativeBinding
    }

    public func status() async -> Pocket3NativeGimbalAcceptanceStatus {
        let status = await link.status()
        let telemetryFresh = status.telemetry != nil &&
            (status.lastTelemetryAge ?? .infinity) <= Pocket3Datalink.maximumTelemetryAge
        return Pocket3NativeGimbalAcceptanceStatus(
            stationBinding: stationBinding, lanIdentity: lanEvidence.identity,
            lanOwnerRetained: lanEvidence.datalinkOwnerRetained,
            nativeBinding: nativeBinding, nativePhase: status.phase,
            telemetry: status.telemetry, telemetryFresh: telemetryFresh,
            commandReady: status.phase == .ready && status.binding == nativeBinding,
            observedUptime: ProcessInfo.processInfo.systemUptime)
    }

    public func send(_ input: ContinuousGimbalInput,
                     lease: ContinuousGimbalLease,
                     permit: OperationPermit) async throws {
        try await requireReady()
        try await link.send(input, lease: lease, permit: permit)
    }

    public func release(_ lease: ContinuousGimbalLease,
                        permit: OperationPermit) async throws
        -> Pocket3NativeGimbalStopEvidence {
        let before = await status()
        guard before.commandReady, before.nativeBinding == lease.binding else {
            throw Pocket3NativeGimbalAcceptanceError.connectionChanged
        }
        do {
            try await link.send(ContinuousGimbalInput.neutral,
                                lease: lease, permit: permit)
            let after = await status()
            return Pocket3NativeGimbalStopEvidence(
                neutralSent: true,
                connectionChanged: !after.commandReady,
                telemetryBefore: before.telemetry,
                telemetryAfter: after.telemetry)
        } catch {
            return Pocket3NativeGimbalStopEvidence(
                neutralSent: false,
                connectionChanged: true,
                telemetryBefore: before.telemetry,
                telemetryAfter: (await status()).telemetry,
                failureCode: "station_acceptance_release_failed")
        }
    }

    public func recenter(permit: OperationPermit) async throws
        -> Pocket3DatalinkActionResult {
        try await requireReady()
        return try await link.recenter(binding: nativeBinding, permit: permit)
    }

    public func flip(permit: OperationPermit) async throws
        -> Pocket3DatalinkActionResult {
        try await requireReady()
        return try await link.flip(binding: nativeBinding, permit: permit)
    }

    public func failStop() async -> Pocket3NativeGimbalStopEvidence {
        let result = await link.neutralAndVerify(binding: nativeBinding)
        return Pocket3NativeGimbalStopEvidence(
            neutralSent: result.neutralSent,
            stableTelemetry: result.stableTelemetry,
            connectionChanged: result.connectionChanged,
            telemetryAfter: result.finalTelemetry,
            failureCode: result.failure)
    }

    private func requireReady() async throws {
        let current = await status()
        guard current.lanOwnerRetained,
              current.commandReady,
              current.stationBinding == stationBinding,
              current.lanIdentity.raw == stationBinding.bleIdentity.raw,
              current.nativeBinding == nativeBinding else {
            throw Pocket3NativeGimbalAcceptanceError.connectionChanged
        }
    }
}
