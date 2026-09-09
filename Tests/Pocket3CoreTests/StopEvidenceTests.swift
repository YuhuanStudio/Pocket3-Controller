import Testing
@testable import Pocket3Core

@Test func stoppingEvidenceRejectsJitterAndOtherAxisMotion() {
    let origin = GimbalPosition(pan: -36000, tilt: -36000)
    let target = GimbalPosition(pan: -18000, tilt: -36000)
    #expect(HardwareValidator.motionProgress(axis: "pan", origin: origin, held: .init(pan: -36360, tilt: -36000), target: target) < 720)
    #expect(HardwareValidator.motionProgress(axis: "pan", origin: origin, held: .init(pan: -36000, tilt: -18000), target: target) == 0)
    #expect(HardwareValidator.motionProgress(axis: "pan", origin: origin, held: .init(pan: -33480, tilt: -36000), target: target) == 2520)
}

@Test func validationOffsetsRejectOverflowAndOutOfRangePositions() throws {
    #expect(throws: BridgeFailure.self) {
        try HardwareValidator.boundedOffset(axis: "pan", delta: 18_000, origin: .init(pan: .max, tilt: 0), minimum: .init(pan: .min, tilt: .min), maximum: .init(pan: .max, tilt: .max))
    }
    let target = try HardwareValidator.boundedOffset(axis: "tilt", delta: 3600, origin: .init(pan: 0, tilt: 0), minimum: .init(pan: -10_000, tilt: -10_000), maximum: .init(pan: 10_000, tilt: 10_000))
    #expect(target == .init(pan: 0, tilt: 3600))
}

private func passingStopTrials() -> [StopTrial] {
    let origin = GimbalPosition(pan: 0, tilt: -28800)
    var trials = [StopTrial]()
    for axis in ["pan", "tilt"] {
        func offset(_ value: Int32) -> GimbalPosition {
            .init(pan: origin.pan + (axis == "pan" ? value : 0),
                  tilt: origin.tilt + (axis == "tilt" ? value : 0))
        }
        for iteration in 0..<3 {
            for delay in [30, 60, 100, 150] {
                let held = offset(delay == 30 ? 0 : delay == 150 ? 18000 : 6120)
                let final = offset(delay == 30 ? 0 : delay == 150 ? 18000 : 6840)
                trials.append(.init(axis: axis, iteration: iteration, delayMS: delay,
                    origin: origin, requested: offset(18000), held: held, final: final,
                    interruptedBeforeTarget: delay < 150, motionWasObserved: delay >= 60,
                    holdResidual: final.distance(to: held), stable: true,
                    restoredPosition: origin, restorationStable: true, restorationResidual: 0))
            }
        }
    }
    return trials
}

@Test func stoppingEvidenceRejectsOneFailedHoldDespiteOtherSuccesses() {
    var trials = passingStopTrials()
    #expect(HardwareValidator.stoppingPassed(trials))
    trials[1].holdResidual = 1800 // Actual v3 hardware failure hidden by a later successful trial.
    trials[1].final.pan = trials[1].held.pan + 1800
    #expect(!HardwareValidator.stoppingPassed(trials))
    trials = passingStopTrials()
    #expect(!HardwareValidator.stoppingPassed(Array(trials.dropLast())))
    for index in trials.indices where trials[index].axis == "tilt" && trials[index].iteration == 2 {
        trials[index].motionWasObserved = false
    }
    #expect(!HardwareValidator.stoppingPassed(trials))
}

@Test func stoppingEvidenceRequiresStableHoldAndStableRestoration() {
    var trials = passingStopTrials()
    trials[1].stable = false // Last readback was near the target but never settled.
    #expect(!HardwareValidator.stoppingPassed(trials))
    trials = passingStopTrials()
    trials[1].restorationStable = false
    #expect(!HardwareValidator.stoppingPassed(trials))
    trials = passingStopTrials()
    trials[1].restoredPosition.pan += 1800
    trials[1].restorationResidual = 1800
    #expect(!HardwareValidator.stoppingPassed(trials))
}

@Test func remainingStopDistanceUsesCommandedAxisAndDirection() {
    let origin = GimbalPosition(pan: 0, tilt: 0)
    let right = GimbalPosition(pan: 18000, tilt: 0)
    #expect(HardwareValidator.remainingDistance(axis: "pan", origin: origin, final: .init(pan: 6840, tilt: 0), target: right) == 11160)
    #expect(HardwareValidator.remainingDistance(axis: "pan", origin: origin, final: .init(pan: 18000, tilt: 18000), target: right) == 0)
    #expect(HardwareValidator.remainingDistance(axis: "pan", origin: origin, final: .init(pan: 25200, tilt: 0), target: right) < 0)
    let left = GimbalPosition(pan: -18000, tilt: 0)
    #expect(HardwareValidator.remainingDistance(axis: "pan", origin: origin, final: .init(pan: -6840, tilt: 0), target: left) == 11160)
    #expect(HardwareValidator.remainingDistance(axis: "pan", origin: origin, final: .init(pan: -25200, tilt: 0), target: left) < 0)
    #expect(HardwareValidator.remainingDistance(axis: "tilt", origin: origin, final: .init(pan: 18000, tilt: 18000), target: .init(pan: 0, tilt: 18000)) == 0)
}

@Test func stoppingProofRechecksCoordinatesInsteadOfTrustingInterruptionFlags() {
    for overshoot in [false, true] {
        var trials = passingStopTrials()
        for index in trials.indices where trials[index].axis == "pan" && trials[index].iteration == 0 {
            // Both look interrupted under max(abs(pan), abs(tilt)) distance:
            // reaching pan with orthogonal drift, or overshooting pan itself.
            let invalid = GimbalPosition(pan: overshoot ? 25200 : 18000,
                                         tilt: overshoot ? -28800 : -10800)
            trials[index].held = invalid
            trials[index].final = invalid
            trials[index].holdResidual = 0
            trials[index].motionWasObserved = true
            trials[index].interruptedBeforeTarget = true
        }
        #expect(!HardwareValidator.stoppingPassed(trials))
    }
}

@Test func settlementTimeoutCannotPassUsingOnlyItsLastNearTargetSample() {
    let target = GimbalPosition(pan: 0, tilt: 0)
    var oscillating = HardwareValidator.Settlement(target: target)
    for index in 0..<35 {
        oscillating.record(.init(pan: index.isMultiple(of: 2) ? 720 : -720, tilt: 0))
    }
    #expect(oscillating.observed.distance(to: target) <= 1080)
    #expect(!oscillating.stable)
    var steady = HardwareValidator.Settlement(target: target)
    for _ in 0..<3 { steady.record(target) }
    #expect(!steady.stable) // Three consecutive stable deltas require four samples.
    steady.record(target)
    #expect(steady.stable)
    steady.record(.init(pan: 1440, tilt: 0))
    #expect(!steady.stable)
}

@Test func positionProofRequiresAllEightyStableTrials() {
    let target = GimbalPosition(pan: 0, tilt: 0)
    var trials = [PositionTrial]()
    for axis in ["pan", "pan-return", "tilt", "tilt-return"] {
        for iteration in 0..<20 {
            trials.append(.init(axis: axis, iteration: iteration, target: target,
                                observed: target, residual: 0, stable: true, passed: true))
        }
    }
    #expect(HardwareValidator.positionsPassed(trials))
    trials[0].stable = false
    #expect(!HardwareValidator.positionsPassed(trials))
    trials[0].stable = true
    #expect(!HardwareValidator.positionsPassed(Array(trials.dropLast())))
    trials[0].iteration = 1
    #expect(!HardwareValidator.positionsPassed(trials))
}
