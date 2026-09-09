import Foundation
import Testing
@testable import Pocket3Core

private final class ManualGimbalClock: ContinuousGimbalClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(to next: TimeInterval) { lock.withLock { precondition(next >= value); value = next } }
    func sleep(until deadline: TimeInterval) async throws {
        while now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try Task.checkCancellation()
    }
}

private actor FakeContinuousTransport: ContinuousGimbalTransport {
    struct Write: Sendable {
        let command: DUMLJoystickCommand
        let lease: ContinuousGimbalLease
        let taskWasCancelled: Bool
    }
    private var binding: ContinuousGimbalBinding
    private var delayNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var writes: [Write] = []
    private(set) var neutralAttempts = 0
    init(binding: ContinuousGimbalBinding) { self.binding = binding }
    func delayNextVelocity() { delayNext = true }
    var hasHeldSend: Bool { held != nil }
    func releaseHeldSend() { let continuation = held; held = nil; continuation?.resume() }
    func changeBinding(_ binding: ContinuousGimbalBinding) { self.binding = binding }
    func send(_ command: DUMLJoystickCommand, lease: ContinuousGimbalLease, permit: OperationPermit) async throws {
        inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        if command.isNeutral { neutralAttempts += 1 }
        if delayNext && !command.isNeutral {
            delayNext = false
            // Deliberately ignores Task cancellation until released. The final
            // permit must still reject this delayed stale velocity write.
            await withCheckedContinuation { held = $0 }
        }
        try permit.perform {
            guard lease.binding == binding else { throw BridgeFailure("session_changed", "Fake transport connection changed") }
            writes.append(Write(command: command, lease: lease, taskWasCancelled: Task.isCancelled))
        }
    }
}

private enum ContinuousTestFailure: Error { case timeout }
private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ContinuousTestFailure.timeout
}
private let fakeBinding = ContinuousGimbalBinding(sessionID: "fake-session", generation: 1)

@Test func continuousLeaseSchedulesLatestVectorAtMostTwentyTimesPerSecond() async throws {
    let clock = ManualGimbalClock(), transport = FakeContinuousTransport(binding: fakeBinding)
    let scheduler = ContinuousGimbalScheduler(transport: transport, clock: clock)
    let lease = try await scheduler.begin(binding: fakeBinding, x: 1, y: 0, speed: 1)
    try await eventually { await transport.writes.count == 1 }
    clock.advance(to: 0.049)
    try await Task.sleep(for: .milliseconds(3))
    #expect(await transport.writes.count == 1)
    clock.advance(to: 0.05)
    try await eventually { await transport.writes.count == 2 }
    try await scheduler.renew(lease, x: -1, y: 0, speed: 0.5)
    clock.advance(to: 0.10)
    try await eventually { await transport.writes.count == 3 }
    let latest = await transport.writes.last
    #expect(latest?.command == (try DUMLJoystickCommand.encode(x: -1, y: 0, speed: 0.5)))
    let stopped = await scheduler.stop(lease)
    #expect(stopped.neutralSent && stopped.matchedLease)
    #expect(await transport.writes.last?.command == .neutral)
    #expect(await transport.maximumInFlight == 1)
    clock.advance(to: 1)
    try await Task.sleep(for: .milliseconds(3))
    #expect(await transport.writes.count == 4)
}

@Test func releaseFencesDelayedVelocityAndNeutralSurvivesCancelledStopCaller() async throws {
    let clock = ManualGimbalClock(), transport = FakeContinuousTransport(binding: fakeBinding)
    await transport.delayNextVelocity()
    let scheduler = ContinuousGimbalScheduler(transport: transport, clock: clock)
    let lease = try await scheduler.begin(binding: fakeBinding, x: 1, y: 0, speed: 1)
    try await eventually { await transport.hasHeldSend }
    let stopping = Task { await scheduler.stop(lease, reason: .focusLost) }
    stopping.cancel()
    try await eventually { await scheduler.status().phase == .stopping }
    #expect(await transport.neutralAttempts == 0) // Must join the existing send first.
    await transport.releaseHeldSend()
    let stopped = await stopping.value
    #expect(stopped.neutralSent && stopped.reason == .focusLost)
    let writes = await transport.writes
    #expect(writes.count == 1 && writes[0].command == .neutral && !writes[0].taskWasCancelled)
    #expect(writes[0].command.payload == Data([0,4,0,0,0,4,0,0x80,0x22,0]))
    #expect(await transport.maximumInFlight == 1)
}

@Test func heartbeatWatchdogExpiresWhileVelocityTransportIsSuspended() async throws {
    let clock = ManualGimbalClock(), transport = FakeContinuousTransport(binding: fakeBinding)
    await transport.delayNextVelocity()
    let scheduler = ContinuousGimbalScheduler(transport: transport, clock: clock)
    let lease = try await scheduler.begin(binding: fakeBinding, x: 0, y: -1, speed: 1)
    try await eventually { await transport.hasHeldSend }
    clock.advance(to: 0.251)
    try await eventually { await scheduler.status().phase == .stopping }
    do {
        try await scheduler.renew(lease, x: 0, y: -1, speed: 1)
        Issue.record("Expired lease accepted a late heartbeat")
    } catch { #expect(error as? ContinuousGimbalError == .staleLease) }
    await transport.releaseHeldSend()
    try await eventually { await scheduler.status().phase == .idle }
    let stopped = await scheduler.status().lastStop
    #expect(stopped?.reason == .leaseExpired && stopped?.neutralSent == true)
    #expect(await transport.writes.count == 1)
    #expect(await transport.writes.first?.command == .neutral)
}

@Test func explicitStopRejectsNewLeaseUntilOldNeutralHasFinished() async throws {
    let clock = ManualGimbalClock(), transport = FakeContinuousTransport(binding: fakeBinding)
    await transport.delayNextVelocity()
    let scheduler = ContinuousGimbalScheduler(transport: transport, clock: clock)
    let lease = try await scheduler.begin(binding: fakeBinding, x: 1, y: 0, speed: 1)
    try await eventually { await transport.hasHeldSend }
    let stopping = Task { await scheduler.stop(lease) }
    try await eventually { await scheduler.status().phase == .stopping }
    do {
        _ = try await scheduler.begin(binding: fakeBinding, x: 0, y: -1, speed: 1)
        Issue.record("A new lease overlapped old stop cleanup")
    } catch { #expect(error as? ContinuousGimbalError == .busy) }
    await transport.releaseHeldSend(); _ = await stopping.value
}

@Test func timedLeaseEndsAtDurationDespiteContinuedManualRenewal() async throws {
    let clock = ManualGimbalClock(), transport = FakeContinuousTransport(binding: fakeBinding)
    let scheduler = ContinuousGimbalScheduler(transport: transport, clock: clock)
    let lease = try await scheduler.begin(binding: fakeBinding, x: 1, y: 0, speed: 1, maximumDuration: 0.1)
    try await eventually { await transport.writes.count == 1 }
    clock.advance(to: 0.05)
    try await scheduler.renew(lease, x: 1, y: 0, speed: 1)
    clock.advance(to: 0.101)
    try await eventually { await scheduler.status().phase == .idle }
    let stopped = await scheduler.status().lastStop
    #expect(stopped?.reason == .durationExpired && stopped?.neutralSent == true)
}

@Test func invalidDragStopsThePreviousVelocityInsteadOfRenewingIt() async throws {
    let clock = ManualGimbalClock(), transport = FakeContinuousTransport(binding: fakeBinding)
    let scheduler = ContinuousGimbalScheduler(transport: transport, clock: clock)
    let lease = try await scheduler.begin(binding: fakeBinding, x: 1, y: 0, speed: 1)
    try await eventually { await transport.writes.count == 1 }
    do {
        try await scheduler.renew(lease, x: .nan, y: 0, speed: 1)
        Issue.record("Non-finite drag input was accepted")
    } catch { #expect(error as? DUMLJoystickError == .nonFiniteInput) }
    try await eventually { await scheduler.status().phase == .idle }
    #expect(await scheduler.status().lastStop?.reason == .invalidInput)
    #expect(await transport.writes.last?.command == .neutral)
}

@Test func oldBindingCannotSendNeutralOrVelocityToReplacementConnection() async throws {
    let clock = ManualGimbalClock(), transport = FakeContinuousTransport(binding: fakeBinding)
    await transport.delayNextVelocity()
    let scheduler = ContinuousGimbalScheduler(transport: transport, clock: clock)
    let old = try await scheduler.begin(binding: fakeBinding, x: 1, y: 0, speed: 1)
    try await eventually { await transport.hasHeldSend }
    let replacement = ContinuousGimbalBinding(sessionID: "fake-session", generation: 2)
    await transport.changeBinding(replacement)
    let stopping = Task { await scheduler.stop(old, reason: .cancelled) }
    try await eventually { await scheduler.status().phase == .stopping }
    await transport.releaseHeldSend()
    let failed = await stopping.value
    #expect(!failed.neutralSent && failed.failure == "session_changed")
    #expect(await transport.writes.isEmpty)
    let current = try await scheduler.begin(binding: replacement, x: -1, y: 0, speed: 1)
    try await eventually { await transport.writes.count == 1 }
    _ = await scheduler.stop(old) // An old callback must not stop the new lease.
    #expect(await scheduler.status().lease == current)
    #expect(await transport.writes.count == 1)
    #expect((await scheduler.stop(current)).neutralSent)
}

@Test func timedLeaseRejectsUnboundedDurationsBeforeAnyTransportSend() async {
    let transport = FakeContinuousTransport(binding: fakeBinding)
    let scheduler = ContinuousGimbalScheduler(transport: transport, clock: ManualGimbalClock())
    for value in [Double.nan, .infinity, -1, 0, 5.001] {
        do {
            _ = try await scheduler.begin(binding: fakeBinding, x: 1, y: 0, speed: 1, maximumDuration: value)
            Issue.record("Invalid timed control duration was accepted")
        } catch { #expect(error as? ContinuousGimbalError == .invalidDuration) }
    }
    #expect(await transport.writes.isEmpty)
}

private actor FakeContinuousInputTransport: ContinuousGimbalInputTransport {
    struct Write: Sendable {
        let input: ContinuousGimbalInput
        let lease: ContinuousGimbalLease
        let taskWasCancelled: Bool
    }
    private let binding: ContinuousGimbalBinding
    private var delayNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var writes: [Write] = []
    private(set) var neutralAttempts = 0
    init(binding: ContinuousGimbalBinding) { self.binding = binding }
    func delayNextInput() { delayNext = true }
    var hasHeldSend: Bool { held != nil }
    func releaseHeldSend() { let continuation = held; held = nil; continuation?.resume() }
    func send(_ input: ContinuousGimbalInput, lease: ContinuousGimbalLease, permit: OperationPermit) async throws {
        inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        if input.isNeutral { neutralAttempts += 1 }
        if delayNext && !input.isNeutral {
            delayNext = false
            await withCheckedContinuation { held = $0 }
        }
        try permit.perform {
            guard lease.binding == binding else { throw BridgeFailure("session_changed", "Fake input binding changed") }
            writes.append(Write(input: input, lease: lease, taskWasCancelled: Task.isCancelled))
        }
    }
}

@Test func continuousInputPreservesFiniteValuesAndExistingValidationErrors() throws {
    let input = try ContinuousGimbalInput(x: .greatestFiniteMagnitude, y: -.greatestFiniteMagnitude, speed: 0.000001)
    #expect(input.x == .greatestFiniteMagnitude && input.y == -.greatestFiniteMagnitude)
    #expect(input.speed == 0.000001 && !input.isNeutral)
    #expect(ContinuousGimbalInput.neutral.x == 0 && ContinuousGimbalInput.neutral.y == 0)
    #expect(ContinuousGimbalInput.neutral.speed == 0 && ContinuousGimbalInput.neutral.isNeutral)
    let zeroSpeed = try ContinuousGimbalInput(x: 100, y: -100, speed: 0)
    #expect(zeroSpeed.isNeutral && zeroSpeed.x == 100 && zeroSpeed.y == -100)
    for value in [Double.nan, .infinity, -.infinity] {
        for (x, y, speed) in [(value, 0.0, 1.0), (0.0, value, 1.0), (0.0, 0.0, value)] {
            do {
                _ = try ContinuousGimbalInput(x: x, y: y, speed: speed)
                Issue.record("Non-finite input was accepted")
            } catch { #expect(error as? DUMLJoystickError == .nonFiniteInput) }
        }
    }
    for speed in [-0.001, 1.001] {
        do {
            _ = try ContinuousGimbalInput(x: 1, y: 0, speed: speed)
            Issue.record("Out-of-range speed was accepted")
        } catch { #expect(error as? DUMLJoystickError == .invalidSpeed) }
    }
}

@Test func inputTransportReceivesUnquantizedLatestInputAndExplicitNeutral() async throws {
    let clock = ManualGimbalClock(), transport = FakeContinuousInputTransport(binding: fakeBinding)
    let scheduler = ContinuousGimbalScheduler(inputTransport: transport, clock: clock)
    let original = try ContinuousGimbalInput(x: 1.23456789012345, y: -0.87654321098765, speed: 0.000001)
    // This signal disappears in DUML UInt16 quantization; the input transport
    // must receive it intact so it can apply a different device's motion curve.
    let quantized = try DUMLJoystickCommand.encode(x: original.x, y: original.y, speed: original.speed)
    #expect(quantized == .neutral && !original.isNeutral)
    let lease = try await scheduler.begin(binding: fakeBinding, x: original.x, y: original.y, speed: original.speed)
    try await eventually { await transport.writes.count == 1 }
    #expect(await transport.writes.first?.input == original)
    let latest = try ContinuousGimbalInput(x: -0.98765432109876, y: 0.12345678901234, speed: 0.31415926535897)
    try await scheduler.renew(lease, x: latest.x, y: latest.y, speed: latest.speed)
    clock.advance(to: 0.05)
    try await eventually { await transport.writes.count == 2 }
    #expect(await transport.writes.last?.input == latest)
    let stopped = await scheduler.stop(lease)
    #expect(stopped.neutralSent)
    #expect(await transport.writes.last?.input == .neutral)
    #expect(await transport.writes.last?.lease == lease)
}

@Test func inputTransportReleaseFencesDelayedInputBeforeIndependentNeutral() async throws {
    let clock = ManualGimbalClock(), transport = FakeContinuousInputTransport(binding: fakeBinding)
    await transport.delayNextInput()
    let scheduler = ContinuousGimbalScheduler(inputTransport: transport, clock: clock)
    let lease = try await scheduler.begin(binding: fakeBinding, x: 0, y: 1, speed: 0.7)
    try await eventually { await transport.hasHeldSend }
    let stopping = Task { await scheduler.stop(lease, reason: .released) }
    stopping.cancel()
    try await eventually { await scheduler.status().phase == .stopping }
    #expect(await transport.neutralAttempts == 0)
    await transport.releaseHeldSend()
    let stopped = await stopping.value
    let writes = await transport.writes
    #expect(stopped.neutralSent && stopped.reason == .released)
    #expect(writes.count == 1 && writes[0].input == .neutral && !writes[0].taskWasCancelled)
    #expect(await transport.maximumInFlight == 1)
}

@Test func invalidInputTransportRenewalStopsWithoutSendingInvalidSpeed() async throws {
    let clock = ManualGimbalClock(), transport = FakeContinuousInputTransport(binding: fakeBinding)
    let scheduler = ContinuousGimbalScheduler(inputTransport: transport, clock: clock)
    do {
        _ = try await scheduler.begin(binding: fakeBinding, x: .infinity, y: 0, speed: 1)
        Issue.record("Non-finite begin was accepted")
    } catch { #expect(error as? DUMLJoystickError == .nonFiniteInput) }
    #expect(await transport.writes.isEmpty)
    let lease = try await scheduler.begin(binding: fakeBinding, x: 1, y: 0, speed: 0.5)
    try await eventually { await transport.writes.count == 1 }
    do {
        try await scheduler.renew(lease, x: 1, y: 0, speed: 1.001)
        Issue.record("Invalid speed renewed a live lease")
    } catch { #expect(error as? DUMLJoystickError == .invalidSpeed) }
    try await eventually { await scheduler.status().phase == .idle }
    #expect(await scheduler.status().lastStop?.reason == .invalidInput)
    let writes = await transport.writes
    #expect(writes.count == 2 && writes.last?.input == .neutral)
}

private actor ExplicitStopInputTransport: ContinuousGimbalInputTransport {
    struct Write: Sendable {
        let input: ContinuousGimbalInput
        let lease: ContinuousGimbalLease
    }
    private var retired = Set<UUID>()
    private var delayStop = false
    private var heldStop: CheckedContinuation<Void, Never>?
    private(set) var writes: [Write] = []
    private(set) var stopInvocations = 0
    private(set) var stoppedLeases: [ContinuousGimbalLease] = []
    private(set) var stopTaskWasCancelled = false
    func delayNextStop() { delayStop = true }
    var hasHeldStop: Bool { heldStop != nil }
    func releaseHeldStop() { let continuation = heldStop; heldStop = nil; continuation?.resume() }
    func send(_ input: ContinuousGimbalInput, lease: ContinuousGimbalLease, permit: OperationPermit) async throws {
        try permit.perform {
            guard lease.binding == fakeBinding, !retired.contains(lease.id) else {
                throw BridgeFailure("session_changed", "Input lease has retired")
            }
            writes.append(Write(input: input, lease: lease))
        }
    }
    func stop(lease: ContinuousGimbalLease, permit: OperationPermit) async throws {
        stopInvocations += 1
        if delayStop {
            delayStop = false
            await withCheckedContinuation { heldStop = $0 }
        }
        try permit.perform {
            guard lease.binding == fakeBinding, !retired.contains(lease.id) else {
                throw BridgeFailure("session_changed", "Stop lease has retired")
            }
            retired.insert(lease.id)
            stoppedLeases.append(lease)
            stopTaskWasCancelled = Task.isCancelled
        }
    }
}

@Test func zeroInputRenewalHoldsWithoutRetiringGestureLease() async throws {
    let clock = ManualGimbalClock(), transport = ExplicitStopInputTransport()
    let scheduler = ContinuousGimbalScheduler(inputTransport: transport, clock: clock)
    let lease = try await scheduler.begin(binding: fakeBinding, x: 1, y: 0, speed: 0.5)
    try await eventually { await transport.writes.count == 1 }
    try await scheduler.renew(lease, x: 0, y: 0, speed: 0.5)
    clock.advance(to: 0.05)
    try await eventually { await transport.writes.count == 2 }
    #expect(await transport.writes.last?.input.isNeutral == true)
    #expect(await transport.stopInvocations == 0)
    let holding = await scheduler.status()
    #expect(holding.phase == .active && holding.lease == lease)
    try await scheduler.renew(lease, x: -1, y: 0, speed: 0.5)
    clock.advance(to: 0.10)
    try await eventually { await transport.writes.count == 3 }
    #expect(await transport.writes.last?.input.x == -1)
    let stopped = await scheduler.stop(lease)
    #expect(stopped.neutralSent && stopped.matchedLease)
    #expect(await transport.stoppedLeases == [lease])
    #expect(await transport.writes.count == 3) // Explicit stop, not another zero send.
}

@Test func concurrentReleaseInvokesExplicitTransportStopExactlyOnce() async throws {
    let clock = ManualGimbalClock(), transport = ExplicitStopInputTransport()
    let scheduler = ContinuousGimbalScheduler(inputTransport: transport, clock: clock)
    let lease = try await scheduler.begin(binding: fakeBinding, x: 1, y: 0, speed: 1)
    try await eventually { await transport.writes.count == 1 }
    await transport.delayNextStop()
    let first = Task { await scheduler.stop(lease, reason: .released) }
    try await eventually { await transport.hasHeldStop }
    let duplicate = Task { await scheduler.stop(lease, reason: .focusLost) }
    first.cancel()
    #expect(await scheduler.status().phase == .stopping)
    #expect(await transport.stopInvocations == 1)
    await transport.releaseHeldStop()
    let result = await first.value, repeated = await duplicate.value
    #expect(result == repeated && result.neutralSent && result.reason == .released)
    #expect(await transport.stopInvocations == 1)
    #expect(await transport.stoppedLeases == [lease])
    #expect(await transport.stopTaskWasCancelled == false)
    #expect(await transport.writes.count == 1)
}

@Test func retiredGestureStopDoesNotCallTransportOrStopReplacementLease() async throws {
    let clock = ManualGimbalClock(), transport = ExplicitStopInputTransport()
    let scheduler = ContinuousGimbalScheduler(inputTransport: transport, clock: clock)
    let old = try await scheduler.begin(binding: fakeBinding, x: 1, y: 0, speed: 0.5)
    try await eventually { await transport.writes.count == 1 }
    _ = await scheduler.stop(old)
    let current = try await scheduler.begin(binding: fakeBinding, x: -1, y: 0, speed: 0.5)
    try await eventually { await transport.writes.count == 2 }
    _ = await scheduler.stop(old, reason: .focusLost)
    #expect(await transport.stoppedLeases == [old])
    #expect(await transport.stopInvocations == 1)
    #expect(await scheduler.status().lease == current)
    try await scheduler.renew(current, x: 0, y: -1, speed: 0.5)
    clock.advance(to: 0.05)
    try await eventually { await transport.writes.count == 3 }
    #expect(await transport.writes.last?.lease == current)
    _ = await scheduler.stop(current)
    #expect(await transport.stoppedLeases == [old, current])
    #expect(await transport.stopInvocations == 2)
}

@Test func preparationTicketReachesInputAndExplicitStopWithoutReplacement() async throws {
    let clock = ManualGimbalClock(), transport = ExplicitStopInputTransport()
    let scheduler = ContinuousGimbalScheduler(inputTransport: transport, clock: clock)
    let ticket = UUID()
    let lease = try await scheduler.begin(binding: fakeBinding, x: 1, y: 0, speed: 0.5, authorizationID: ticket)
    #expect(lease.authorizationID == ticket)
    try await eventually { await transport.writes.count == 1 }
    #expect(await transport.writes.first?.lease.authorizationID == ticket)
    try await scheduler.renew(lease, x: 0, y: 0, speed: 0.5)
    clock.advance(to: 0.05)
    try await eventually { await transport.writes.count == 2 }
    #expect(await transport.writes.last?.lease == lease)
    let stopped = await scheduler.stop(lease)
    #expect(stopped.lease.authorizationID == ticket)
    #expect(await transport.stoppedLeases == [lease])

    let nextTicket = UUID()
    let next = try await scheduler.begin(binding: fakeBinding, x: -1, y: 0, speed: 0.5, authorizationID: nextTicket)
    try await eventually { await transport.writes.count == 3 }
    _ = await scheduler.stop(lease)
    #expect(await scheduler.status().lease?.authorizationID == nextTicket)
    #expect(await transport.stopInvocations == 1)
    _ = await scheduler.stop(next)
    #expect(await transport.stoppedLeases.map(\.authorizationID) == [ticket, nextTicket])
}

@Test func leaseAuthorizationDefaultsToNilAndSurvivesCodableRoundTrip() throws {
    let id = UUID()
    let legacy = ContinuousGimbalLease(id: id, binding: fakeBinding)
    #expect(legacy.authorizationID == nil)
    // A persisted lease from before authorization tickets has no optional key.
    let oldJSON: [String: Any] = ["id": id.uuidString,
        "binding": ["sessionID": fakeBinding.sessionID, "generation": fakeBinding.generation]]
    let oldData = try JSONSerialization.data(withJSONObject: oldJSON)
    let decodedLegacy = try JSONDecoder().decode(ContinuousGimbalLease.self, from: oldData)
    #expect(decodedLegacy == legacy)
    let authorized = ContinuousGimbalLease(id: id, binding: fakeBinding, authorizationID: UUID())
    let decoded = try JSONDecoder().decode(ContinuousGimbalLease.self, from: JSONEncoder().encode(authorized))
    #expect(decoded == authorized && decoded != legacy)
}
