import Foundation

public struct ContinuousGimbalBinding: Sendable, Equatable, Codable {
    public let sessionID: String
    public let generation: UInt64
    public init(sessionID: String, generation: UInt64) { self.sessionID = sessionID; self.generation = generation }
}
public struct ContinuousGimbalLease: Sendable, Equatable, Codable {
    public let id: UUID
    public let binding: ContinuousGimbalBinding
    /// Exact preparation ticket for transports that require a separate manual
    /// authorization. It never authorizes a different gesture or connection.
    public let authorizationID: UUID?
    public init(id: UUID, binding: ContinuousGimbalBinding, authorizationID: UUID? = nil) {
        self.id = id; self.binding = binding; self.authorizationID = authorizationID
    }
}
public enum ContinuousGimbalError: Error, Equatable, Sendable {
    case busy, invalidSession, invalidDuration, staleLease
}
public enum ContinuousGimbalStopReason: String, Codable, Sendable {
    case released, focusLost, cancelled, leaseExpired, durationExpired, transportFailure, invalidInput
}
public struct ContinuousGimbalStopResult: Sendable, Equatable, Codable {
    public let lease: ContinuousGimbalLease
    public let reason: ContinuousGimbalStopReason
    public let matchedLease: Bool
    /// Confirms only transport completion of the neutral command, not a
    /// physically verified stop. Camera telemetry is still required for that.
    public let neutralSent: Bool
    public let failure: String?
}
public struct ContinuousGimbalSchedulerStatus: Sendable {
    public enum Phase: String, Sendable, Equatable { case idle, active, stopping }
    public let phase: Phase
    public let lease: ContinuousGimbalLease?
    public let completedCommandSends: Int
    public let lastStop: ContinuousGimbalStopResult?
}

/// A transport must reject stale connection bindings immediately before its
/// final write, inside permit.perform { ... }. Waiting/reassembly belongs
/// before that fenced write. It must not redirect a bound request to a new
/// connection. Every send must finish on cancellation or a bounded transport
/// deadline: neutral cannot overlap a still-in-flight velocity send.
/// No live Bluetooth, Wi-Fi, or UVC implementation is supplied here.
public protocol ContinuousGimbalTransport: Sendable {
    func send(_ command: DUMLJoystickCommand, lease: ContinuousGimbalLease, permit: OperationPermit) async throws
}

public protocol ContinuousGimbalClock: Sendable {
    var now: TimeInterval { get }
    func sleep(until deadline: TimeInterval) async throws
}
public struct SystemContinuousGimbalClock: ContinuousGimbalClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(until deadline: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline - now)))
    }
}

/// An exclusive manual joystick lease with a 20 Hz upper send rate and a
/// separate heartbeat watchdog. The watchdog keeps working while a transport
/// send is suspended. UI release/focus loss must call stop for the exact lease.
public actor ContinuousGimbalScheduler {
    public static let sendInterval: TimeInterval = 0.05
    public static let heartbeatTimeout: TimeInterval = 0.25
    public static let maximumTimedDuration: TimeInterval = 5

    private struct Active {
        let lease: ContinuousGimbalLease
        let permit: OperationPermit
        let durationDeadline: TimeInterval?
        var heartbeatDeadline: TimeInterval
        var input: ContinuousGimbalInput
    }
    private let transport: any ContinuousGimbalInputTransport
    private let clock: any ContinuousGimbalClock
    private var active: Active?
    private var worker: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var stoppingLease: ContinuousGimbalLease?
    private var cleanup: Task<ContinuousGimbalStopResult, Never>?
    private var completedCommandSends = 0
    private var lastStop: ContinuousGimbalStopResult?

    public init(transport: any ContinuousGimbalTransport, clock: any ContinuousGimbalClock = SystemContinuousGimbalClock()) {
        self.transport = DUMLContinuousGimbalInputAdapter(transport: transport); self.clock = clock
    }

    public init(inputTransport: any ContinuousGimbalInputTransport, clock: any ContinuousGimbalClock = SystemContinuousGimbalClock()) {
        self.transport = inputTransport; self.clock = clock
    }

    /// Every lease requires heartbeat renewal within 250 ms, including timed
    /// leases. Nil duration is for a held manual control. A future timed/MCP
    /// request owner must supply <= 5 seconds and renew only while still active.
    public func begin(binding: ContinuousGimbalBinding, x: Double, y: Double, speed: Double,
                      authorizationID: UUID? = nil,
                      maximumDuration: TimeInterval? = nil) throws -> ContinuousGimbalLease {
        try Task.checkCancellation()
        guard active == nil && cleanup == nil else { throw ContinuousGimbalError.busy }
        guard !binding.sessionID.isEmpty else { throw ContinuousGimbalError.invalidSession }
        if let maximumDuration {
            guard maximumDuration.isFinite, maximumDuration > 0, maximumDuration <= Self.maximumTimedDuration else {
                throw ContinuousGimbalError.invalidDuration
            }
        }
        let input = try ContinuousGimbalInput(x: x, y: y, speed: speed)
        let lease = ContinuousGimbalLease(id: UUID(), binding: binding, authorizationID: authorizationID)
        let now = clock.now
        active = Active(lease: lease, permit: OperationPermit(), durationDeadline: maximumDuration.map { now + $0 },
                        heartbeatDeadline: now + Self.heartbeatTimeout, input: input)
        completedCommandSends = 0
        worker = Task.detached(priority: .userInitiated) { await self.drive(lease) }
        watchdog = Task.detached(priority: .userInitiated) { await self.watch(lease) }
        return lease
    }

    /// Updates direction/speed and renews the manual heartbeat. Expired leases
    /// cannot be resurrected by a late drag event or old window callback.
    public func renew(_ lease: ContinuousGimbalLease, x: Double, y: Double, speed: Double) throws {
        try Task.checkCancellation()
        guard var current = active, current.lease == lease else { throw ContinuousGimbalError.staleLease }
        if let reason = expiration(current) {
            _ = initiateStop(lease, reason: reason)
            throw ContinuousGimbalError.staleLease
        }
        do { current.input = try ContinuousGimbalInput(x: x, y: y, speed: speed) }
        catch { _ = initiateStop(lease, reason: .invalidInput); throw error }
        current.heartbeatDeadline = clock.now + Self.heartbeatTimeout
        active = current
    }

    /// This method intentionally completes cleanup even if its caller is
    /// cancelled. Neutral is sent from a separate uncancelled task, after the
    /// sole in-flight velocity operation has terminated.
    public func stop(_ lease: ContinuousGimbalLease, reason: ContinuousGimbalStopReason = .released) async -> ContinuousGimbalStopResult {
        if let cleanup = initiateStop(lease, reason: reason) { return await cleanup.value }
        if let lastStop, lastStop.lease == lease { return lastStop }
        return ContinuousGimbalStopResult(lease: lease, reason: reason, matchedLease: false, neutralSent: false, failure: nil)
    }

    public func status() -> ContinuousGimbalSchedulerStatus {
        ContinuousGimbalSchedulerStatus(phase: active != nil ? .active : cleanup != nil ? .stopping : .idle,
            lease: active?.lease ?? stoppingLease, completedCommandSends: completedCommandSends, lastStop: lastStop)
    }

    private func expiration(_ current: Active) -> ContinuousGimbalStopReason? {
        let now = clock.now
        if let duration = current.durationDeadline, now >= duration { return .durationExpired }
        return now >= current.heartbeatDeadline ? .leaseExpired : nil
    }

    private func drive(_ lease: ContinuousGimbalLease) async {
        while let current = active, current.lease == lease {
            if let reason = expiration(current) { _ = initiateStop(lease, reason: reason); return }
            do {
                try Task.checkCancellation()
                let started = clock.now
                try await transport.send(current.input, lease: lease, permit: current.permit)
                guard active?.lease == lease else { return }
                completedCommandSends += 1
                // Never catch up by bursting queued commands after a slow send.
                try await clock.sleep(until: max(clock.now, started + Self.sendInterval))
            } catch {
                // Do not await our own cleanup: it must join this worker first.
                _ = initiateStop(lease, reason: error is CancellationError ? .cancelled : .transportFailure)
                return
            }
        }
    }

    private func watch(_ lease: ContinuousGimbalLease) async {
        while let current = active, current.lease == lease {
            let deadline = min(current.heartbeatDeadline, current.durationDeadline ?? .infinity)
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let latest = active, latest.lease == lease else { return }
            if let reason = expiration(latest) { _ = initiateStop(lease, reason: reason); return }
        }
    }

    private func initiateStop(_ lease: ContinuousGimbalLease, reason: ContinuousGimbalStopReason) -> Task<ContinuousGimbalStopResult, Never>? {
        if stoppingLease == lease { return cleanup }
        guard let current = active, current.lease == lease else { return nil }
        current.permit.invalidate() // Fence every future nonneutral write first.
        active = nil; stoppingLease = lease
        watchdog?.cancel(); watchdog = nil
        worker?.cancel()
        let pending = worker; worker = nil
        let transport = self.transport
        let task = Task.detached(priority: .userInitiated) { () -> ContinuousGimbalStopResult in
            await pending?.value
            let result: ContinuousGimbalStopResult
            do {
                try await transport.stop(lease: lease, permit: OperationPermit())
                result = ContinuousGimbalStopResult(lease: lease, reason: reason, matchedLease: true, neutralSent: true, failure: nil)
            } catch {
                result = ContinuousGimbalStopResult(lease: lease, reason: reason, matchedLease: true, neutralSent: false,
                                                    failure: (error as? BridgeFailure)?.code ?? "neutral_transport_failed")
            }
            await self.finished(result)
            return result
        }
        cleanup = task
        return task
    }

    private func finished(_ result: ContinuousGimbalStopResult) {
        guard stoppingLease == result.lease else { return }
        lastStop = result; stoppingLease = nil; cleanup = nil
    }
}
