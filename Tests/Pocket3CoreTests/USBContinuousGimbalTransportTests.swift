import Foundation
import Testing
@testable import Pocket3Core

private final class USBFakeClock: ContinuousGimbalClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 10
    var now: TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    func sleep(until deadline: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock { time = max(time, deadline) }
        await Task.yield()
    }
}

private let usbBinding = ContinuousGimbalBinding(sessionID: "usb-fake", generation: 7)
private func usbLease() -> ContinuousGimbalLease { .init(id: UUID(), binding: usbBinding) }
private func usbCaps(_ position: GimbalPosition) -> UVCCapabilities {
    .init(location: 1, position: position, minimum: .init(pan: -126000, tilt: -324000),
          maximum: .init(pan: 774000, tilt: 324000), step: .init(pan: 3600, tilt: 3600),
          writable: true, controls: ["pan-tilt-abs"], uvcVersion: 256)
}

private actor USBFakeIO {
    struct WriteRecord: Sendable { let position: GimbalPosition; let cancelled: Bool }
    let clock: USBFakeClock
    private(set) var starts = 0, reads = 0, stops = 0, maxInFlight = 0
    private(set) var writes: [WriteRecord] = []
    private(set) var owner: ContinuousGimbalLease?
    private var position = GimbalPosition(pan: 6120, tilt: -29880)
    private var inFlight = 0
    private var failStart = false, blockStart = false, blockWrite = false
    private var startGate: CheckedContinuation<Void, Never>?
    private var writeGate: CheckedContinuation<Void, Never>?
    private var readDelay: TimeInterval = 0, writeDelay: TimeInterval = 0
    private var unstable = false
    private var continuationAllowed = true
    private let connectionPermit = OperationPermit()
    init(clock: USBFakeClock) { self.clock = clock }
    func configure(failStart: Bool = false, blockStart: Bool = false, blockWrite: Bool = false,
                   readDelay: TimeInterval = 0, writeDelay: TimeInterval = 0, unstable: Bool = false) {
        self.failStart = failStart; self.blockStart = blockStart; self.blockWrite = blockWrite
        self.readDelay = readDelay; self.writeDelay = writeDelay; self.unstable = unstable
    }
    var startWaiting: Bool { startGate != nil }
    var writeWaiting: Bool { writeGate != nil }
    func releaseStart() { let gate = startGate; startGate = nil; gate?.resume() }
    func releaseWrite() { let gate = writeGate; writeGate = nil; gate?.resume() }
    func setPosition(_ value: GimbalPosition) { position = value }
    func setContinuationAllowed(_ allowed: Bool) { continuationAllowed = allowed }
    func revokeConnection() { connectionPermit.invalidate() }
    func continueGesture(_ lease: ContinuousGimbalLease) throws {
        guard owner == lease, continuationAllowed else { throw BridgeFailure("preview_stale", "Fake preview unavailable") }
    }
    private func enter() { inFlight += 1; maxInFlight = max(maxInFlight, inFlight) }
    func start(_ lease: ContinuousGimbalLease, permit: OperationPermit) async throws {
        starts += 1; enter(); defer { inFlight -= 1 }
        if failStart { throw BridgeFailure("start_refused", "Fake claim refused") }
        try permit.perform { owner = lease }
        // Model a service commit whose successful return is delayed; the
        // transport must still notice ownership when Stop arrived meanwhile.
        if blockStart { blockStart = false; await withCheckedContinuation { startGate = $0 } }
    }
    func read(_ lease: ContinuousGimbalLease) async throws -> USBContinuousGimbalFeedback {
        reads += 1; enter(); defer { inFlight -= 1 }
        guard owner == lease else { throw BridgeFailure("owner_changed", "Wrong fake owner") }
        let observedAt = clock.now
        clock.advance(readDelay)
        let sample = unstable ? GimbalPosition(pan: position.pan + (reads.isMultiple(of: 2) ? 1000 : -1000), tilt: position.tilt) : position
        return .init(capabilities: usbCaps(sample), observedAt: observedAt)
    }
    func write(_ target: GimbalPosition, lease: ContinuousGimbalLease, validUntil: TimeInterval, permit: OperationPermit) async throws {
        enter(); defer { inFlight -= 1 }
        if blockWrite { blockWrite = false; await withCheckedContinuation { writeGate = $0 } }
        clock.advance(writeDelay)
        try connectionPermit.perform {
            try permit.perform {
                guard owner == lease else { throw BridgeFailure("owner_changed", "Wrong fake owner") }
                guard clock.now <= validUntil else { throw BridgeFailure("trajectory_timing", "Expired fake target") }
                writes.append(.init(position: target, cancelled: Task.isCancelled)); position = target
            }
        }
    }
    func stopped(_ lease: ContinuousGimbalLease, result: MotionResult) {
        #expect(owner == lease)
        owner = nil; stops += 1
    }
}

private func usbTransport(_ io: USBFakeIO, clock: USBFakeClock) -> USBContinuousGimbalTransport {
    .init(binding: usbBinding, onStart: { try await io.start($0, permit: $1) },
          onContinue: { try await io.continueGesture($0) },
          read: { try await io.read($0) },
          write: { try await io.write($0, lease: $1, validUntil: $2, permit: $3) },
          onStop: { await io.stopped($0, result: $1) }, clock: clock)
}
private func usbEventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw BridgeFailure("fake_wait_timeout", "Fake operation did not reach its gate")
}
private func usbRight() throws -> ContinuousGimbalInput { try .init(x: 1, y: 0, speed: 0.5) }

@Test func usbContinuousUsesOneFreshReadAndWritePerTickAndZeroDoesNotRetire() async throws {
    let clock = USBFakeClock(), io = USBFakeIO(clock: clock), lease = usbLease(), permit = OperationPermit()
    let transport = usbTransport(io, clock: clock)
    for _ in 0..<4 { try await transport.send(usbRight(), lease: lease, permit: permit); clock.advance(0.05) }
    let moving = await io.writes
    #expect(moving.count == 4 && moving[3].position.pan > moving[0].position.pan)
    #expect(await io.reads == 4)
    #expect(await io.starts == 1)
    let externallyMoved = GimbalPosition(pan: 6501, tilt: -29431)
    await io.setPosition(externallyMoved)
    try await transport.send(.neutral, lease: lease, permit: permit)
    #expect(await io.writes.last?.position == externallyMoved)
    #expect(await io.reads == 5)
    #expect(await io.stops == 0)
    try await transport.send(usbRight(), lease: lease, permit: permit)
    clock.advance(0.05)
    try await transport.send(usbRight(), lease: lease, permit: permit)
    #expect(await io.writes.last!.position.pan > externallyMoved.pan)
    let readsBeforeStop = await io.reads
    try await transport.stop(lease: lease, permit: OperationPermit())
    #expect(await io.reads == readsBeforeStop + 4) // Fresh hold plus three post-hold samples.
    #expect(await io.stops == 1)
    #expect(await io.maxInFlight == 1)
    #expect(await transport.lastStop?.verified == true)
    do { try await transport.send(usbRight(), lease: lease, permit: OperationPermit()); Issue.record("Retired lease revived") }
    catch { #expect(error as? ContinuousGimbalError == .staleLease) }
    let next = usbLease()
    try await transport.send(usbRight(), lease: next, permit: OperationPermit())
    try await transport.stop(lease: next, permit: OperationPermit())
    #expect(await io.starts == 2)
    #expect(await io.stops == 2)
}

@Test func usbContinuousStopBeforeClaimPermanentlyRetiresWithoutTouchingHardware() async throws {
    let clock = USBFakeClock(), io = USBFakeIO(clock: clock), lease = usbLease()
    let transport = usbTransport(io, clock: clock)
    try await transport.stop(lease: lease, permit: OperationPermit())
    do { try await transport.send(usbRight(), lease: lease, permit: OperationPermit()); Issue.record("Unstarted retired lease revived") }
    catch { #expect(error as? ContinuousGimbalError == .staleLease) }
    #expect(await io.starts == 0)
    #expect(await io.reads == 0)
    #expect(await io.writes.isEmpty)
    #expect(await io.stops == 0)
    #expect(await transport.lastStop?.verification == "no_active_usb_motion")
}

@Test func usbContinuousFailedClaimNeverHoldsOrReleasesAnotherOwner() async throws {
    let clock = USBFakeClock(), io = USBFakeIO(clock: clock), lease = usbLease()
    let transport = usbTransport(io, clock: clock)
    await io.configure(failStart: true)
    do { try await transport.send(usbRight(), lease: lease, permit: OperationPermit()); Issue.record("Failed claim succeeded") }
    catch { #expect((error as? BridgeFailure)?.code == "start_refused") }
    try await transport.stop(lease: lease, permit: OperationPermit())
    #expect(await io.reads == 0)
    #expect(await io.writes.isEmpty)
    #expect(await io.stops == 0)
}

@Test func usbContinuousStopDuringSuccessfulClaimStillReleasesClaimWithIndependentHold() async throws {
    let clock = USBFakeClock(), io = USBFakeIO(clock: clock), lease = usbLease()
    let transport = usbTransport(io, clock: clock), permit = OperationPermit()
    await io.configure(blockStart: true)
    let send = Task { try await transport.send(usbRight(), lease: lease, permit: permit) }
    try await usbEventually { await io.startWaiting }
    let stopping = Task { try await transport.stop(lease: lease, permit: OperationPermit()) }
    stopping.cancel()
    try await Task.sleep(for: .milliseconds(5))
    #expect(await io.writes.isEmpty)
    #expect(await io.stops == 0)
    await io.releaseStart()
    _ = await send.result
    try await stopping.value
    #expect(await io.writes.count == 1)
    #expect(await io.writes[0].cancelled == false)
    #expect(await io.stops == 1)
    #expect(await io.owner == nil)
    #expect(await io.maxInFlight == 1)
    #expect(await transport.lastStop?.verified == true)
}

@Test func usbContinuousStopJoinsAndFencesQueuedWriteBeforeHold() async throws {
    let clock = USBFakeClock(), io = USBFakeIO(clock: clock), lease = usbLease()
    let transport = usbTransport(io, clock: clock), permit = OperationPermit()
    await io.configure(blockWrite: true)
    let send = Task { try await transport.send(usbRight(), lease: lease, permit: permit) }
    try await usbEventually { await io.writeWaiting }
    do { try await transport.send(usbRight(), lease: usbLease(), permit: OperationPermit()); Issue.record("Overlapping gesture accepted") }
    catch { #expect(error as? ContinuousGimbalError == .busy) }
    let stopping = Task { try await transport.stop(lease: lease, permit: OperationPermit()) }
    try await Task.sleep(for: .milliseconds(5))
    #expect(await io.writes.isEmpty)
    await io.releaseWrite(); _ = await send.result; try await stopping.value
    #expect(await io.writes.count == 1)
    #expect(await io.maxInFlight == 1)
    #expect(await io.stops == 1)
}

@Test func usbContinuousRejectsStaleReadAndTargetExpiredAtFinalWrite() async throws {
    for slowRead in [true, false] {
        let clock = USBFakeClock(), io = USBFakeIO(clock: clock), lease = usbLease()
        let transport = usbTransport(io, clock: clock)
        await io.configure(readDelay: slowRead ? 0.26 : 0, writeDelay: slowRead ? 0 : 0.11)
        do { try await transport.send(usbRight(), lease: lease, permit: OperationPermit()); Issue.record("Expired target sent") }
        catch { #expect((error as? BridgeFailure)?.code == (slowRead ? "usb_feedback_stale" : "trajectory_timing")) }
        #expect(await io.writes.isEmpty)
        await io.configure()
        try await transport.stop(lease: lease, permit: OperationPermit())
        #expect(await io.stops == 1)
        #expect(await io.writes.count == 1)
    }
}

@Test func usbContinuousStopFailureReleasesOwnerAndRetiresLease() async throws {
    for unstable in [true, false] {
        let clock = USBFakeClock(), io = USBFakeIO(clock: clock), lease = usbLease()
        let transport = usbTransport(io, clock: clock)
        try await transport.send(usbRight(), lease: lease, permit: OperationPermit())
        await io.configure(readDelay: unstable ? 0 : 0.11, unstable: unstable)
        do { try await transport.stop(lease: lease, permit: OperationPermit()); Issue.record("Unverified stop succeeded") }
        catch { #expect((error as? BridgeFailure)?.code == (unstable ? "usb_stop_unverified" : "usb_feedback_stale")) }
        #expect(await io.stops == 1)
        #expect(await io.owner == nil)
        #expect(await transport.lastStop?.verified == false)
        let writes = await io.writes.count
        _ = try? await transport.stop(lease: lease, permit: OperationPermit())
        #expect(await io.writes.count == writes)
        #expect(await io.stops == 1)
        do { try await transport.send(usbRight(), lease: lease, permit: OperationPermit()); Issue.record("Failed stop lease revived") }
        catch { #expect(error as? ContinuousGimbalError == .staleLease) }
    }
}

@Test func usbContinuousRejectsReplacementBindingBeforeClaim() async throws {
    let clock = USBFakeClock(), io = USBFakeIO(clock: clock)
    let transport = usbTransport(io, clock: clock)
    let wrong = ContinuousGimbalLease(id: UUID(), binding: .init(sessionID: "usb-fake", generation: 8))
    do { try await transport.send(usbRight(), lease: wrong, permit: OperationPermit()); Issue.record("Replacement binding accepted") }
    catch { #expect(error as? ContinuousGimbalError == .invalidSession) }
    #expect(await io.starts == 0)
    #expect(await io.writes.isEmpty)
}

@Test func usbContinuousPreviewFailureBlocksMotionButDoesNotBlockStopHold() async throws {
    let clock = USBFakeClock(), io = USBFakeIO(clock: clock), lease = usbLease()
    let transport = usbTransport(io, clock: clock)
    try await transport.send(usbRight(), lease: lease, permit: OperationPermit())
    await io.setContinuationAllowed(false)
    do { try await transport.send(usbRight(), lease: lease, permit: OperationPermit()); Issue.record("Motion continued with stale preview") }
    catch { #expect((error as? BridgeFailure)?.code == "preview_stale") }
    #expect(await io.reads == 1)
    #expect(await io.writes.count == 1)
    try await transport.stop(lease: lease, permit: OperationPermit())
    #expect(await io.writes.count == 2)
    #expect(await io.stops == 1)
    #expect(await transport.lastStop?.verified == true)
}

@Test func usbContinuousRevokedConnectionRejectsFreshNeutralPermit() async throws {
    let clock = USBFakeClock(), io = USBFakeIO(clock: clock), lease = usbLease()
    let transport = usbTransport(io, clock: clock)
    try await transport.send(usbRight(), lease: lease, permit: OperationPermit())
    #expect(await io.writes.count == 1)
    await io.revokeConnection()
    do {
        try await transport.stop(lease: lease, permit: OperationPermit())
        Issue.record("Fresh stop permit bypassed revoked connection lifetime")
    } catch { #expect((error as? BridgeFailure)?.code == "cancelled") }
    #expect(await io.writes.count == 1)
    #expect(await io.stops == 1)
    #expect(await transport.lastStop?.accepted == false)
    #expect(await transport.lastStop?.verified == false)
}
