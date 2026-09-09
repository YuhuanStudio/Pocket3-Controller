import Testing
@testable import Pocket3Core

private func trajectoryCapabilities(position: GimbalPosition = .init(pan: 360, tilt: -9360)) -> UVCCapabilities {
    UVCCapabilities(location: 0x01100000, position: position,
        minimum: .init(pan: -126000, tilt: -324000), maximum: .init(pan: 774000, tilt: 324000),
        step: .init(pan: 3600, tilt: 3600), writable: true, controls: ["pan-tilt-abs"], uvcVersion: 256)
}

@Test func usbTrajectoryMovesAcrossZeroWithoutWaitingAtEveryTarget() throws {
    let capabilities = trajectoryCapabilities(position: .init(pan: 360, tilt: -360))
    var trajectory = try USBPositionTrajectory(capabilities: capabilities, now: 0)
    var observed = capabilities.position
    var targets: [GimbalPosition] = []
    for tick in 1...10 {
        let now = Double(tick) * 0.05
        let target = try trajectory.advance(x: 0, y: -1, speed: 0.5, now: now, observed: observed, observedAt: now)
        targets.append(target); observed = target
    }
    #expect(targets.allSatisfy { $0.pan == capabilities.position.pan })
    #expect(targets.last!.tilt > 0)
    #expect(zip(targets, targets.dropFirst()).allSatisfy { $1.tilt > $0.tilt })
    #expect(targets[0].tilt - capabilities.position.tilt < targets[4].tilt - targets[3].tilt)
}

@Test func usbTrajectoryStalledFeedbackCannotAccumulateDistantTargets() throws {
    let capabilities = trajectoryCapabilities()
    var trajectory = try USBPositionTrajectory(capabilities: capabilities, now: 0)
    for tick in 1...200 {
        let now = Double(tick) * 0.05
        let target = try trajectory.advance(x: 1, y: 0, speed: 1, now: now,
            observed: capabilities.position, observedAt: now)
        #expect(target.pan <= capabilities.position.pan + 7200)
    }
    let held = try trajectory.advance(x: 0, y: 0, speed: 1, now: 10.05,
        observed: .init(pan: 720, tilt: -9360), observedAt: 10.05)
    #expect(held == GimbalPosition(pan: 720, tilt: -9360))
}

@Test func usbTrajectoryReleaseHoldsReadbackInsteadOfCentreOrSubmittedTarget() throws {
    let capabilities = trajectoryCapabilities()
    var trajectory = try USBPositionTrajectory(capabilities: capabilities, now: 0)
    let target = try trajectory.advance(x: 1, y: 0, speed: 1, now: 0.05,
        observed: capabilities.position, observedAt: 0.05)
    #expect(target != capabilities.position)
    let held = try trajectory.advance(x: 0, y: 0, speed: 1, now: 0.10,
        observed: capabilities.position, observedAt: 0.10)
    #expect(held == capabilities.position)
}

@Test func usbTrajectoryLateTickAndStaleFeedbackDoNotCatchUp() throws {
    let capabilities = trajectoryCapabilities()
    var late = try USBPositionTrajectory(capabilities: capabilities, now: 0)
    #expect(throws: USBPositionTrajectory.Failure.delayedTick) {
        try late.advance(x: 1, y: 0, speed: 1, now: 1, observed: capabilities.position, observedAt: 1)
    }
    var stale = try USBPositionTrajectory(capabilities: capabilities, now: 1)
    #expect(throws: USBPositionTrajectory.Failure.staleFeedback) {
        try stale.advance(x: 1, y: 0, speed: 1, now: 1.05, observed: capabilities.position, observedAt: 0.7)
    }
}

@Test func usbTrajectoryDeviceLimitsDoNotWrapAndReverseRemainsPossible() throws {
    let position = GimbalPosition(pan: 774000, tilt: -324000)
    var trajectory = try USBPositionTrajectory(capabilities: trajectoryCapabilities(position: position), now: 0)
    let limit = try trajectory.advance(x: 1, y: 1, speed: 1, now: 0.05, observed: position, observedAt: 0.05)
    #expect(limit == position)
    let reversed = try trajectory.advance(x: -1, y: -1, speed: 1, now: 0.10, observed: position, observedAt: 0.10)
    #expect(reversed.pan < position.pan && reversed.tilt > position.tilt)
}

@Test func usbTrajectoryExtremeFiniteVectorIsBoundedAndNonfiniteRejected() throws {
    let capabilities = trajectoryCapabilities()
    var trajectory = try USBPositionTrajectory(capabilities: capabilities, now: 0)
    let target = try trajectory.advance(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude,
        speed: 1, now: 0.05, observed: capabilities.position, observedAt: 0.05)
    #expect(target.pan > capabilities.position.pan && target.tilt < capabilities.position.tilt)
    #expect(target.distance(to: capabilities.position) < 3600)
    #expect(throws: DUMLJoystickError.nonFiniteInput) {
        try trajectory.advance(x: .nan, y: 0, speed: 1, now: 0.10, observed: capabilities.position, observedAt: 0.10)
    }
}

@Test func usbTrajectoryFreshFeedbackAheadDoesNotPullBackAnActiveOrIdleAxis() throws {
    let capabilities = trajectoryCapabilities()
    let advanced = GimbalPosition(pan: 4000, tilt: -8000)
    var right = try USBPositionTrajectory(capabilities: capabilities, now: 0)
    let rightTarget = try right.advance(x: 1, y: 0, speed: 1, now: 0.05, observed: advanced, observedAt: 0.05)
    #expect(rightTarget.pan >= advanced.pan && rightTarget.tilt == advanced.tilt)
    var up = try USBPositionTrajectory(capabilities: capabilities, now: 0)
    let upTarget = try up.advance(x: 0, y: -1, speed: 1, now: 0.05, observed: advanced, observedAt: 0.05)
    #expect(upTarget.pan == advanced.pan && upTarget.tilt >= advanced.tilt)
}

@Test func usbTrajectoryRunningReversalWithdrawsOldLeadImmediately() throws {
    let capabilities = trajectoryCapabilities()
    var trajectory = try USBPositionTrajectory(capabilities: capabilities, now: 0)
    var observed = capabilities.position
    for tick in 1...10 {
        let now = Double(tick) * 0.05
        observed = try trajectory.advance(x: 1, y: 0, speed: 1, now: now, observed: observed, observedAt: now)
    }
    let reversed = try trajectory.advance(x: -1, y: 0, speed: 1, now: 0.55, observed: observed, observedAt: 0.55)
    #expect(reversed.pan < observed.pan && reversed.tilt == observed.tilt)
}

@Test func usbTrajectoryReversalAfterLeadClampDiscardsTheUnreachedTarget() throws {
    let capabilities = trajectoryCapabilities()
    var trajectory = try USBPositionTrajectory(capabilities: capabilities, now: 0)
    for tick in 1...40 {
        let now = Double(tick) * 0.05
        _ = try trajectory.advance(x: 1, y: 0, speed: 1, now: now, observed: capabilities.position, observedAt: now)
    }
    let reversed = try trajectory.advance(x: -1, y: 0, speed: 1, now: 2.05,
        observed: capabilities.position, observedAt: 2.05)
    #expect(reversed.pan < capabilities.position.pan)
}
