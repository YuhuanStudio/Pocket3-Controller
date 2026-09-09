import Foundation
import Testing
@testable import Pocket3Core

// Shared by the two Roll test files. These fixtures never create a UVC actor,
// enumerate USB, start capture, or load the App.
final class RollTestClock: ContinuousGimbalClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    init(now: TimeInterval = 0) { time = now }
    var now: TimeInterval { lock.withLock { time } }
    func advance(_ amount: TimeInterval) { lock.withLock { time += amount } }
    func sleep(until deadline: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock { time = max(time, deadline) }
        await Task.yield()
    }
}

func rollTestCapabilities(current: Int = -20) -> USBRollCapabilities {
    .init(current: current, minimum: -120, maximum: 86, step: 2, defaultValue: -12, writable: true)
}

actor RollTestIO {
    let clock: RollTestClock
    private let lifetime = OperationPermit()
    private var values: [Int]
    private var readDelays: [Int: TimeInterval] = [:]
    private var writeDelay: TimeInterval = 0
    private var readFailureAt: Int?
    private var validationFailureAt: Int?
    private var capabilityChangeAt: Int?
    private var delayWrite = false
    private var delayRead = false
    private var writeGate: CheckedContinuation<Void, Never>?
    private var readGate: CheckedContinuation<Void, Never>?
    private(set) var writes: [Int] = []
    private(set) var writeDeadlines: [TimeInterval] = []
    private(set) var writeAttempts = 0
    private(set) var reads = 0
    private(set) var validations = 0

    init(clock: RollTestClock, values: [Int]) { self.clock = clock; self.values = values }
    func configure(readDelays: [Int: TimeInterval] = [:], writeDelay: TimeInterval = 0,
                   readFailureAt: Int? = nil, validationFailureAt: Int? = nil,
                   capabilityChangeAt: Int? = nil, delayWrite: Bool = false, delayRead: Bool = false) {
        self.readDelays = readDelays; self.writeDelay = writeDelay
        self.readFailureAt = readFailureAt; self.validationFailureAt = validationFailureAt
        self.capabilityChangeAt = capabilityChangeAt; self.delayWrite = delayWrite; self.delayRead = delayRead
    }
    var writeWaiting: Bool { writeGate != nil }
    var readWaiting: Bool { readGate != nil }
    func releaseWrite() { let gate = writeGate; writeGate = nil; gate?.resume() }
    func releaseRead() { let gate = readGate; readGate = nil; gate?.resume() }
    func invalidate() { lifetime.invalidate() }

    func validate() throws {
        validations += 1
        if validationFailureAt == validations { throw BridgeFailure("session_changed", "Fake service generation changed") }
    }
    func read() async throws -> USBRollCapabilities {
        reads += 1
        if delayRead { delayRead = false; await withCheckedContinuation { readGate = $0 } }
        if readFailureAt == reads { throw BridgeFailure("uvc_roll_read_failed", "Fake Roll read failed") }
        clock.advance(readDelays[reads] ?? 0)
        let current = values.first ?? -20
        if values.count > 1 { values.removeFirst() }
        var capabilities = rollTestCapabilities(current: current)
        if capabilityChangeAt == reads { capabilities.step = 4 }
        return capabilities
    }
    func write(_ value: Int, validUntil: TimeInterval, permit: OperationPermit) async throws {
        writeAttempts += 1; writeDeadlines.append(validUntil)
        if delayWrite { delayWrite = false; await withCheckedContinuation { writeGate = $0 } }
        clock.advance(writeDelay)
        try lifetime.perform {
            try permit.perform {
                guard clock.now.isFinite, clock.now <= validUntil else { throw BridgeFailure("roll_timing", "Fake target expired before final write") }
                writes.append(value)
            }
        }
    }
}

func runRollSet(_ io: RollTestIO, clock: RollTestClock, target: Int = -18,
                before: USBRollCapabilities = rollTestCapabilities(), permit: OperationPermit = OperationPermit()) async throws -> USBRollResult {
    try await USBRollSetOperation.perform(rawValue: target, before: before, permit: permit,
        validate: { try await io.validate() }, read: { try await io.read() },
        write: { try await io.write($0, validUntil: $1, permit: $2) }, clock: clock)
}

private func rollEventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw BridgeFailure("fake_wait_timeout", "Roll fake did not reach its gate")
}

@Test func rollPolicyPreservesSigned16AndRejectsNarrowingOrFractions() throws {
    #expect(try USBRollPolicy.rawValue(-32768) == -32768)
    #expect(try USBRollPolicy.rawValue(32767) == 32767)
    #expect(try USBRollPolicy.rawValue(-18) == -18)
    for input in [-32769, 32768, -18.5, Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
        do { _ = try USBRollPolicy.rawValue(input); Issue.record("Invalid signed Roll input was accepted") }
        catch { #expect((error as? BridgeFailure)?.code == "invalid_roll_value") }
    }
}

@Test func rollPolicyUsesDeviceBoundsAndMinimumAnchoredPositiveStep() throws {
    let caps = rollTestCapabilities()
    for value in [-120, -18, 0, 86] { try USBRollPolicy.validate(value, capabilities: caps) }
    let fullSigned = USBRollCapabilities(current: 0, minimum: -32768, maximum: 32767,
        step: 1, defaultValue: nil, writable: true)
    try USBRollPolicy.validate(-32768, capabilities: fullSigned)
    try USBRollPolicy.validate(32767, capabilities: fullSigned)
    for value in [-122, 88, Int.min, Int.max] {
        do { try USBRollPolicy.validate(value, capabilities: caps); Issue.record("Out-of-range Roll accepted") }
        catch { #expect((error as? BridgeFailure)?.code == "uvc_roll_out_of_range") }
    }
    do { try USBRollPolicy.validate(-19, capabilities: caps); Issue.record("Off-grid Roll was rounded") }
    catch { #expect((error as? BridgeFailure)?.code == "uvc_roll_step_mismatch") }
    let shifted = USBRollCapabilities(current: -3, minimum: -3, maximum: 9, step: 4, defaultValue: 1, writable: true)
    for value in [-3,1,5,9] { try USBRollPolicy.validate(value, capabilities: shifted) }
    #expect(throws: BridgeFailure.self) { try USBRollPolicy.validate(0, capabilities: shifted) }
    for step in [Int?.none, 0, -1, 32768] {
        var invalid = caps; invalid.step = step
        do { try USBRollPolicy.validate(-18, capabilities: invalid); Issue.record("Missing/nonpositive/oversized step accepted") }
        catch { #expect((error as? BridgeFailure)?.code == "uvc_roll_step_unavailable") }
    }
}

@Test func rollPolicyRejectsReadonlyMissingRangeAndInvalidCurrentOrDefault() throws {
    var invalid: [USBRollCapabilities] = []
    var caps = rollTestCapabilities(); caps.minimum = nil; invalid.append(caps)
    caps = rollTestCapabilities(); caps.maximum = -121; invalid.append(caps)
    caps = rollTestCapabilities(); caps.current = 87; invalid.append(caps)
    caps = rollTestCapabilities(); caps.defaultValue = -121; invalid.append(caps)
    caps = rollTestCapabilities(); caps.minimum = Int.min; invalid.append(caps)
    for capabilities in invalid {
        do { try USBRollPolicy.validate(-18, capabilities: capabilities); Issue.record("Invalid Roll capability accepted") }
        catch { #expect((error as? BridgeFailure)?.code == "uvc_roll_limits_unavailable") }
    }
    caps = rollTestCapabilities(); caps.writable = false
    do { try USBRollPolicy.validate(-18, capabilities: caps); Issue.record("Readonly Roll accepted") }
    catch { #expect((error as? BridgeFailure)?.code == "uvc_roll_read_only") }
    caps = rollTestCapabilities(); caps.defaultValue = nil
    try USBRollPolicy.validate(-18, capabilities: caps) // No invented default is needed to set a valid target.
}

@Test func rollReadbackRequiresThreeExactSamplesAndAtLeastPointTwoSeconds() throws {
    var verifier = try USBRollReadbackVerifier(target: -18, capabilities: rollTestCapabilities())
    let first = try verifier.observe(rollTestCapabilities(current: -18), at: 0)
    let second = try verifier.observe(rollTestCapabilities(current: -18), at: 0.1)
    let third = try verifier.observe(rollTestCapabilities(current: -18), at: 0.2)
    #expect(!first && !second && third && verifier.sampleCount == 3)
    var fast = try USBRollReadbackVerifier(target: -18, capabilities: rollTestCapabilities())
    for time in [0.0,0.01,0.02] {
        let settled = try fast.observe(rollTestCapabilities(current: -18), at: time)
        #expect(!settled)
    }
    let oneRawOff = try verifier.observe(rollTestCapabilities(current: -17), at: 0.3)
    #expect(!oneRawOff && verifier.stableDurationSeconds == 0) // Zoom's tolerance must not leak into Roll.
    let restarted = try verifier.observe(rollTestCapabilities(current: -18), at: 0.4)
    #expect(!restarted && verifier.stableDurationSeconds == 0)
}

@Test func rollReadbackRejectsChangedCapabilitiesAndNonadvancingClock() throws {
    for time in [Double.nan, .infinity, 0.0, -1.0] {
        var verifier = try USBRollReadbackVerifier(target: -18, capabilities: rollTestCapabilities())
        _ = try verifier.observe(rollTestCapabilities(current: -18), at: 0)
        do { _ = try verifier.observe(rollTestCapabilities(current: -18), at: time); Issue.record("Invalid Roll clock accepted") }
        catch { #expect((error as? BridgeFailure)?.code == "roll_feedback_stale") }
    }
    var changes: [USBRollCapabilities] = []
    var caps = rollTestCapabilities(current: -18); caps.minimum = -118; changes.append(caps)
    caps = rollTestCapabilities(current: -18); caps.maximum = 84; changes.append(caps)
    caps = rollTestCapabilities(current: -18); caps.step = 4; changes.append(caps)
    caps = rollTestCapabilities(current: -18); caps.defaultValue = 0; changes.append(caps)
    caps = rollTestCapabilities(current: -18); caps.writable = false; changes.append(caps)
    caps = rollTestCapabilities(current: 87); changes.append(caps)
    for changed in changes {
        var verifier = try USBRollReadbackVerifier(target: -18, capabilities: rollTestCapabilities())
        do { _ = try verifier.observe(changed, at: 0); Issue.record("Changed Roll capability accepted") }
        catch { #expect((error as? BridgeFailure)?.code == "roll_capabilities_changed") }
    }
}

@Test func rollSetSendsOnceThenWaitsForExactStableReadback() async throws {
    let clock = RollTestClock(), io = RollTestIO(clock: clock, values: [-20,-18,-18,-18,-18])
    let result = try await runRollSet(io, clock: clock)
    #expect(result.accepted && result.completed && result.verified && result.observed == -18)
    #expect(result.toleranceRaw == 0 && result.sampleCount >= 3 && result.stableDurationSeconds >= 0.2)
    #expect(await io.writes == [-18])
    #expect(await io.writeAttempts == 1)
    #expect(await io.reads == result.sampleCount)
    #expect(await io.writeDeadlines == [0.25])
}

@Test func rollSetTimeoutDoesNotResendAndReturnsUnconfirmedEvidence() async throws {
    let clock = RollTestClock(), io = RollTestIO(clock: clock, values: [-20])
    let result = try await runRollSet(io, clock: clock)
    #expect(result.accepted && !result.completed && !result.verified && result.observed == -20)
    #expect(result.toleranceRaw == 0 && result.sampleCount > 0 && result.sampleCount <= 40)
    #expect(clock.now >= 3 && clock.now < 3.1)
    #expect(await io.writes == [-18])
    #expect(await io.writeAttempts == 1)
}

@Test func rollSetExpiredFinalWriteAndStaleReadAreNotRetried() async {
    for slowWrite in [true, false] {
        let clock = RollTestClock(), io = RollTestIO(clock: clock, values: [-18])
        await io.configure(readDelays: slowWrite ? [:] : [1: 0.101], writeDelay: slowWrite ? 0.251 : 0)
        do { _ = try await runRollSet(io, clock: clock); Issue.record("Expired Roll I/O accepted") }
        catch { #expect((error as? BridgeFailure)?.code == (slowWrite ? "roll_timing" : "roll_feedback_stale")) }
        #expect(await io.writeAttempts == 1)
        #expect(await io.writes.count == (slowWrite ? 0 : 1))
    }
}

@Test func rollSetCancellationAtWriteOrReadGateNeverResends() async throws {
    for beforeWrite in [true, false] {
        let clock = RollTestClock(), io = RollTestIO(clock: clock, values: [-18])
        await io.configure(delayWrite: beforeWrite, delayRead: !beforeWrite)
        let task = Task { try await runRollSet(io, clock: clock) }
        try await rollEventually {
            if beforeWrite { return await io.writeWaiting }
            return await io.readWaiting
        }
        task.cancel()
        if beforeWrite { await io.releaseWrite() } else { await io.releaseRead() }
        do { _ = try await task.value; Issue.record("Cancelled Roll completed") }
        catch { #expect(error is CancellationError) }
        #expect(await io.writeAttempts == 1)
        #expect(await io.writes.count == (beforeWrite ? 0 : 1))
        #expect(await io.reads == (beforeWrite ? 0 : 1))
    }
}

@Test func rollSetValidationAndInvalidClockFailBeforeUnsafeWork() async {
    for index in [1,2] {
        let clock = RollTestClock(), io = RollTestIO(clock: clock, values: [-18])
        await io.configure(validationFailureAt: index)
        do { _ = try await runRollSet(io, clock: clock); Issue.record("Changed generation accepted") }
        catch { #expect((error as? BridgeFailure)?.code == "session_changed") }
        #expect(await io.writes.count == index - 1)
        #expect(await io.reads == 0)
    }
    let clock = RollTestClock(now: .nan), io = RollTestIO(clock: clock, values: [-18])
    do { _ = try await runRollSet(io, clock: clock); Issue.record("Invalid initial clock accepted") }
    catch { #expect((error as? BridgeFailure)?.code == "roll_timing") }
    #expect(await io.writeAttempts == 0)
}

@Test func rollAutomationNeedsIndependentRollValidationAndExplicitAccess() throws {
    let previouslyVerifiedPan = MotionResult(accepted: true, completed: true, verified: true,
        verification: "pan_tilt_only", target: .init(pan: 0, tilt: 0), observed: .init(pan: 0, tilt: 0), message: "Pan-only fixture")
    #expect(previouslyVerifiedPan.verified)
    do {
        try USBRollPolicy.authorize(origin: .automation, access: .control, rollStopValidated: false)
        Issue.record("Pan-only evidence incorrectly authorized Roll")
    } catch { #expect((error as? BridgeFailure)?.code == "roll_not_validated") }
    for access in [AccessMode.manual, .observe] {
        do { try USBRollPolicy.authorize(origin: .automation, access: access, rollStopValidated: true); Issue.record("Roll bypassed user access") }
        catch { #expect((error as? BridgeFailure)?.code == "roll_denied") }
    }
    try USBRollPolicy.authorize(origin: .manual, access: .manual, rollStopValidated: false)
    try USBRollPolicy.authorize(origin: .automation, access: .control, rollStopValidated: true)
}
