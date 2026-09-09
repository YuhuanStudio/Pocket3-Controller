import Foundation
import Testing
@testable import Pocket3Core

private func approachCapabilities(_ position: GimbalPosition) -> UVCCapabilities {
    .init(location: 1, position: position, minimum: .init(pan: -126000, tilt: -324000),
          maximum: .init(pan: 774000, tilt: 324000), step: .init(pan: 3600, tilt: 3600),
          writable: true, controls: ["pan-tilt-abs"], uvcVersion: 256)
}

@Test func usbPresetApproachReachesDistantFrontBackAndMultiAxisTargetsWithoutOvershoot() throws {
    let cases: [(GimbalPosition, GimbalPosition)] = [
        (.init(pan: 0, tilt: 0), .init(pan: 648000, tilt: 0)),
        (.init(pan: 648000, tilt: 0), .init(pan: 0, tilt: 0)),
        (.init(pan: -100000, tilt: 250000), .init(pan: 700000, tilt: -300000)),
        (.init(pan: 50000, tilt: -20000), .init(pan: 51000, tilt: -18000))
    ]
    for (origin, target) in cases {
        var approach = try USBTargetApproach(target: target, capabilities: approachCapabilities(origin), now: 0)
        var observed = origin, reached = false
        for tick in 1...1200 {
            let now = Double(tick) * 0.05
            let next = try approach.advance(observed: observed, observedAt: now, now: now)
            #expect(next.distance(to: observed) <= 7200)
            #expect((min(observed.pan, target.pan)...max(observed.pan, target.pan)).contains(next.pan))
            #expect((min(observed.tilt, target.tilt)...max(observed.tilt, target.tilt)).contains(next.tilt))
            observed = next // Deterministic fake device follows each target.
            if observed == target { reached = true; break }
        }
        #expect(reached)
    }
}

@Test func usbPresetApproachStalledFeedbackCannotAccumulateLargeJump() throws {
    let origin = GimbalPosition(pan: 0, tilt: 0), target = GimbalPosition(pan: 648000, tilt: 300000)
    var approach = try USBTargetApproach(target: target, capabilities: approachCapabilities(origin), now: 0)
    for tick in 1...300 {
        let now = Double(tick) * 0.05
        let next = try approach.advance(observed: origin, observedAt: now, now: now)
        #expect(next.distance(to: origin) <= 7200)
        #expect(next.pan <= target.pan && next.tilt <= target.tilt)
    }
}

@Test func usbPresetApproachReversesFromActualFeedbackAfterExternalCrossing() throws {
    let origin = GimbalPosition(pan: 0, tilt: 0), target = GimbalPosition(pan: 20000, tilt: -20000)
    var approach = try USBTargetApproach(target: target, capabilities: approachCapabilities(origin), now: 0)
    _ = try approach.advance(observed: origin, observedAt: 0.05, now: 0.05)
    let crossed = GimbalPosition(pan: 30000, tilt: -30000)
    let reversed = try approach.advance(observed: crossed, observedAt: 0.10, now: 0.10)
    #expect(reversed.pan < crossed.pan && reversed.pan >= target.pan)
    #expect(reversed.tilt > crossed.tilt && reversed.tilt <= target.tilt)
    #expect(reversed.distance(to: crossed) <= 7200)
}

@Test func usbPresetApproachNearTargetUsesExactRawValueAndRebuildsAfterDwell() throws {
    let target = GimbalPosition(pan: 6121, tilt: -29881)
    let origin = GimbalPosition(pan: target.pan - 720, tilt: target.tilt + 720)
    var approach = try USBTargetApproach(target: target, capabilities: approachCapabilities(origin), now: 0)
    let exact = try approach.advance(observed: origin, observedAt: 0.05, now: 0.05)
    #expect(exact == target)
    let held = try approach.advance(observed: target, observedAt: 100, now: 100)
    #expect(held == target)
    let drifted = GimbalPosition(pan: target.pan - 10000, tilt: target.tilt)
    let reset = try approach.advance(observed: drifted, observedAt: 101, now: 101)
    #expect(reset == drifted) // New planner must not integrate the dwell time.
    let next = try approach.advance(observed: drifted, observedAt: 101.05, now: 101.05)
    #expect(next.pan > drifted.pan && next.pan < target.pan && next.tilt == target.tilt)
    #expect(next.distance(to: drifted) <= 7200)
}

@Test func usbPresetApproachRejectsInvalidTargetAndStaleFeedbackEvenNearTarget() throws {
    let origin = GimbalPosition(pan: 0, tilt: 0), caps = approachCapabilities(origin)
    #expect(throws: USBTargetApproach.Failure.invalidTarget) {
        try USBTargetApproach(target: .init(pan: 774001, tilt: 0), capabilities: caps, now: 0)
    }
    var approach = try USBTargetApproach(target: origin, capabilities: caps, now: 0)
    #expect(throws: USBPositionTrajectory.Failure.staleFeedback) {
        try approach.advance(observed: origin, observedAt: 0, now: 1)
    }
    #expect(throws: USBPositionTrajectory.Failure.invalidFeedback) {
        try approach.advance(observed: origin, observedAt: .nan, now: 1)
    }
}
