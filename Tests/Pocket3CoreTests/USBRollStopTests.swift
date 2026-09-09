import Foundation
import Testing
@testable import Pocket3Core

private func runRollStop(_ io: RollTestIO, clock: RollTestClock) async -> USBRollStopResult {
    await USBRollStopOperation.perform(read: { try await io.read() },
        write: { try await io.write($0, validUntil: $1, permit: $2) }, clock: clock)
}

@Test func rollStopHoldsFreshCurrentNotDefaultAndRequiresLongExactWindow() async {
    let clock = RollTestClock(), io = RollTestIO(clock: clock, values: [-18])
    let result = await runRollStop(io, clock: clock)
    #expect(result.submitted && result.verified && result.target == -18 && result.observed == -18)
    #expect(result.target != rollTestCapabilities().defaultValue)
    #expect(result.toleranceRaw == 0 && result.sampleCount >= 3 && result.stableDurationSeconds >= 0.8 - 1e-9)
    #expect(await io.writes == [-18])
    #expect(await io.writeAttempts == 1)
    #expect(await io.writeDeadlines == [0.10])
    #expect(await io.reads == result.sampleCount + 1)
}

@Test func rollStopAcceptsFreshReadAtHundredMillisecondsButRejectsOlderRead() async {
    let clock = RollTestClock(), exact = RollTestIO(clock: clock, values: [-18])
    await exact.configure(readDelays: [1: 0.10])
    let accepted = await runRollStop(exact, clock: clock)
    #expect(accepted.submitted && accepted.verified)
    #expect(await exact.writes == [-18])
    let staleClock = RollTestClock(), stale = RollTestIO(clock: staleClock, values: [-18])
    await stale.configure(readDelays: [1: 0.1001])
    let rejected = await runRollStop(stale, clock: staleClock)
    #expect(!rejected.submitted && !rejected.verified && rejected.failure == "roll_stop_feedback_stale")
    #expect(await stale.writes.isEmpty)
}

@Test func rollStopFailsWhenDeviceKeepsMovingOrDiffersByOneRawUnit() async {
    for values in [[-18,-18,-18,-18,-16,-14,-12], [-18,-17]] {
        let clock = RollTestClock(), io = RollTestIO(clock: clock, values: values)
        let result = await runRollStop(io, clock: clock)
        #expect(result.submitted && !result.verified && result.failure == "roll_stop_unverified")
        #expect(result.target == -18 && result.toleranceRaw == 0)
        #expect(await io.writes == [-18])
        #expect(await io.writeAttempts == 1)
    }
}

@Test func rollStopReadFailureBeforeOrAfterHoldCannotBecomeVerified() async {
    for index in [1,2] {
        let clock = RollTestClock(), io = RollTestIO(clock: clock, values: [-18])
        await io.configure(readFailureAt: index)
        let result = await runRollStop(io, clock: clock)
        #expect(!result.verified && result.failure == "uvc_roll_read_failed")
        #expect(result.submitted == (index == 2))
        #expect(await io.writes.count == index - 1)
        #expect(await io.writeAttempts == index - 1)
    }
}

@Test func rollStopRejectsCapabilityChangeAndStaleOrBackwardsVerificationRead() async {
    for delay in [0.101, -0.01] {
        let clock = RollTestClock(), io = RollTestIO(clock: clock, values: [-18])
        await io.configure(readDelays: [2: delay])
        let result = await runRollStop(io, clock: clock)
        #expect(result.submitted && !result.verified && result.failure == "roll_stop_feedback_stale")
        #expect(await io.writes == [-18])
    }
    let clock = RollTestClock(), io = RollTestIO(clock: clock, values: [-18])
    await io.configure(capabilityChangeAt: 2)
    let changed = await runRollStop(io, clock: clock)
    #expect(changed.submitted && !changed.verified && changed.failure == "roll_capabilities_changed")
    #expect(await io.writeAttempts == 1)
}

@Test func rollStopFreshPermitCannotBypassRevokedConnectionOrExpiredWrite() async {
    for invalidate in [true, false] {
        let clock = RollTestClock(), io = RollTestIO(clock: clock, values: [-18])
        if invalidate { await io.invalidate() }
        else { await io.configure(writeDelay: 0.101) }
        let result = await runRollStop(io, clock: clock)
        #expect(!result.submitted && !result.verified)
        #expect(result.failure == (invalidate ? "cancelled" : "roll_timing"))
        #expect(await io.writeAttempts == 1)
        #expect(await io.writes.isEmpty)
    }
}

@Test func rollStopCombiningPreservesZoomAndRequiresEveryControlToBeVerified() throws {
    let pose = GimbalPosition(pan: 6120, tilt: -29880)
    for zoomVerified in [false, true] {
        for rollVerified in [false, true] {
            let zoom = USBZoomStopResult(submitted: true, target: 147, observed: 146,
                verified: zoomVerified, sampleCount: 11, toleranceRaw: 1, stableDurationSeconds: 0.8)
            let prior = MotionResult(id: "same-stop", accepted: true, completed: zoomVerified, verified: zoomVerified,
                verification: "pan_and_zoom_fixture", target: pose, observed: pose, message: "Fixture", zoomStop: zoom)
            let roll = USBRollStopResult(submitted: true, target: -18, observed: -18, verified: rollVerified,
                sampleCount: 11, stableDurationSeconds: 0.8)
            let combined = USBRollStopResult.combining(prior, roll: roll)
            #expect(combined.id == prior.id && combined.target == pose && combined.observed == pose)
            #expect(combined.zoomStop == zoom && combined.rollStop == roll)
            #expect(combined.verified == (zoomVerified && rollVerified))
            #expect(combined.completed == (zoomVerified && rollVerified) && combined.accepted)
            let decoded = try JSONDecoder().decode(MotionResult.self, from: JSONEncoder().encode(combined))
            #expect(decoded.rollStop == roll && decoded.zoomStop == zoom)
        }
    }
    let panFailure = MotionResult(id: "pan-failed", accepted: true, completed: false, verified: false,
        verification: "pan_unconfirmed", target: pose, observed: nil, message: "Fixture")
    let rollSuccess = USBRollStopResult(submitted: true, target: -18, observed: -18, verified: true)
    #expect(!USBRollStopResult.combining(panFailure, roll: rollSuccess).verified)
    let unchanged = USBRollStopResult.combining(panFailure, roll: nil)
    #expect(unchanged.id == panFailure.id && unchanged.rollStop == nil && !unchanged.verified)
}
