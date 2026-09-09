import Foundation
import Testing
@testable import Pocket3Core

@Test func validationSettlementRejectsASequenceOfSmallStepsThatKeepsDrifting() {
    var result = HardwareValidator.Settlement(target: .init(pan: 0, tilt: 0))
    for pan: Int32 in [-1080, -720, -360, 0] { result.record(.init(pan: pan, tilt: 0)) }
    #expect(!result.stable)
    for _ in 0..<4 { result.record(.init(pan: 0, tilt: 0)) }
    #expect(result.stable)
}

@Test func validationAcceptanceRejectsWrongTargetGeometryAndMissingMeasuredOrigins() async throws {
    let valid = try await ValidationTransportFixture().run()
    #expect(HardwareValidator.accepts(valid))
    var noOp = valid
    noOp.positionTrials[0].target = valid.original
    noOp.positionTrials[0].observed = valid.original
    noOp.positionTrials[0].residual = 0
    #expect(HardwareValidator.positionsPassed(noOp.positionTrials))
    #expect(!HardwareValidator.accepts(noOp))
    var wrongStop = valid
    wrongStop.stopTrials[0].requested.pan += 3600
    #expect(!HardwareValidator.accepts(wrongStop))
    var missing = valid
    missing.stopTrials[0].motionOrigin = nil
    #expect(!HardwareValidator.accepts(missing))
}

@Test func validationStopMotionMustBeRelativeToItsFreshMeasuredOrigin() async throws {
    var report = try await ValidationTransportFixture().run()
    for index in report.stopTrials.indices {
        // The old fixed origin may differ from the actual starting pose.
        // Holding that same measured pose is not observed movement.
        report.stopTrials[index].motionOrigin = report.stopTrials[index].held
        report.stopTrials[index].motionWasObserved = true
    }
    #expect(!HardwareValidator.stoppingPassed(report.stopTrials))
    #expect(!HardwareValidator.accepts(report))
}

private actor ValidationTransportFixture {
    let permit: OperationPermit
    var position = GimbalPosition(pan: 0, tilt: 0)
    var pendingTarget: GimbalPosition?
    var writes: [GimbalPosition] = []
    var cleanupWrites: [GimbalPosition] = []
    var reads = 0
    let faultAtWrite: Int?
    let cancelAtWrite: Int?
    let invalidateOnCancel: Bool
    let movingStops: Bool
    let failingRead: Int?
    let changedIdentityFromRead: Int?
    let failCleanupWrite: Bool
    let invalidateAtCleanupWrite: Bool

    init(permit: OperationPermit = OperationPermit(), faultAtWrite: Int? = nil,
         cancelAtWrite: Int? = nil, invalidateOnCancel: Bool = false, movingStops: Bool = true,
         failingRead: Int? = nil, changedIdentityFromRead: Int? = nil, failCleanupWrite: Bool = false, invalidateAtCleanupWrite: Bool = false) {
        self.permit = permit; self.faultAtWrite = faultAtWrite; self.cancelAtWrite = cancelAtWrite
        self.invalidateOnCancel = invalidateOnCancel; self.movingStops = movingStops
        self.failingRead = failingRead; self.changedIdentityFromRead = changedIdentityFromRead
        self.failCleanupWrite = failCleanupWrite; self.invalidateAtCleanupWrite = invalidateAtCleanupWrite
    }
    func status() throws -> UVCCapabilities {
        reads += 1
        if reads == failingRead { throw BridgeFailure("fixture_read_failure", "Read failed") }
        return UVCCapabilities(location: 1, position: position, minimum: .init(pan: -36000, tilt: -36000),
            maximum: .init(pan: 36000, tilt: 36000), writable: true, controls: [], uvcVersion: 1,
            registryID: changedIdentityFromRead.map { reads >= $0 ? "other" : "registry" } ?? "registry",
            bootSessionID: "boot")
    }
    func set(_ target: GimbalPosition) throws {
        try permit.perform {
            writes.append(target)
            pendingTarget = nil
            if target.pan == 18000 || target.tilt == 18000 { pendingTarget = target }
            else { position = target }
            if writes.count == faultAtWrite {
                position = .init(pan: target.pan + 1800, tilt: target.tilt)
                pendingTarget = nil
            }
        }
        if writes.count == cancelAtWrite {
            if invalidateOnCancel { permit.invalidate() }
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    func hold(_ target: GimbalPosition) throws {
        if invalidateAtCleanupWrite { permit.invalidate() }
        try permit.perform {
            if failCleanupWrite { throw BridgeFailure("fixture_hold_failure", "Hold failed") }
            cleanupWrites.append(target)
            position = target; pendingTarget = nil
        }
    }
    func sleep(_ milliseconds: Int) throws {
        try Task.checkCancellation()
        if let pendingTarget, milliseconds != 80, movingStops, milliseconds >= 60 {
            position = .init(pan: pendingTarget.pan == 18000 ? 7200 : 0,
                             tilt: pendingTarget.tilt == 18000 ? 7200 : 0)
        }
    }
    nonisolated var io: HardwareValidator.IO {
        .init(status: { try await self.status() }, set: { try await self.set($0) },
              hold: { try await self.hold($0) }, sleep: { try await self.sleep($0) })
    }
    func run() async throws -> HardwareValidationReport {
        try await HardwareValidator.run(io: io, deviceID: "fixture", permit: permit)
    }
}

@Test func validationV5CompletesAllTrialsIncludingAnUnmovingEarlyHold() async throws {
    let fixture = ValidationTransportFixture()
    let report = try await fixture.run()
    #expect(report.version == 5)
    #expect(report.profile == "finite_absolute_pan_tilt_positive_offsets_v1")
    #expect(report.positionTrials.count == 80)
    #expect(report.stopTrials.count == 24)
    #expect(report.stopTrials.first?.motionWasObserved == false)
    #expect(report.positionPassed && report.stopPassed && report.restored)
    #expect(report.failedStage == nil && report.cleanup == nil)
    #expect(report.cancelled == false)
    #expect(report.images.isEmpty)
    #expect(await fixture.writes.count == 152)
    #expect(await fixture.cleanupWrites.isEmpty)
}

@Test func validationV5FailedTargetHoldsFreshCurrentWithoutReturningToOrigin() async throws {
    let fixture = ValidationTransportFixture(faultAtWrite: 1)
    let report = try await fixture.run()
    #expect(report.failedStage == "position.pan.0")
    #expect(report.failureCode == "validation_position_unsettled")
    #expect(report.positionTrials.count == 1)
    #expect(report.stopTrials.isEmpty)
    #expect(!report.positionPassed && !report.stopPassed && !report.restored)
    #expect(await fixture.writes == [.init(pan: 3600, tilt: 0)])
    #expect(await fixture.cleanupWrites == [.init(pan: 5400, tilt: 0)])
    #expect(report.cleanup?.target == .init(pan: 5400, tilt: 0))
    #expect(report.cleanup?.writeSubmitted == true)
    #expect(report.cleanup?.stable == true)
    #expect(report.final == .init(pan: 5400, tilt: 0))
}

@Test func validationV5FailedPositionReturnCannotStartAnotherTrial() async throws {
    let fixture = ValidationTransportFixture(faultAtWrite: 2)
    let report = try await fixture.run()
    #expect(report.failedStage == "position.pan-return.0")
    #expect(report.positionTrials.count == 2)
    #expect(await fixture.writes.count == 2)
    #expect(await fixture.cleanupWrites == [.init(pan: 1800, tilt: 0)])
    #expect(!report.restored)
}

@Test func validationV5FailedStopHoldDoesNotSendTheReturnCommand() async throws {
    let fixture = ValidationTransportFixture(faultAtWrite: 42)
    let report = try await fixture.run()
    #expect(report.failedStage == "stop.pan.0.30.hold")
    #expect(report.failureCode == "validation_hold_unsettled")
    #expect(report.positionTrials.count == 40)
    #expect(report.stopTrials.count == 1)
    #expect(report.stopTrials.first?.restorationStable == false)
    #expect(await fixture.writes.count == 42)
    #expect(await fixture.cleanupWrites == [.init(pan: 1800, tilt: 0)])
}

@Test func validationV5FailedStopReturnStopsTheNextDelayTrial() async throws {
    let fixture = ValidationTransportFixture(faultAtWrite: 43)
    let report = try await fixture.run()
    #expect(report.failedStage == "stop.pan.0.30.return")
    #expect(report.failureCode == "validation_return_unsettled")
    #expect(report.stopTrials.count == 1)
    #expect(report.stopTrials.first?.restorationStable == false)
    #expect(await fixture.writes.count == 43)
    #expect(await fixture.cleanupWrites.count == 1)
}

@Test func validationV5UnmovingGroupStopsOnlyAfterFourVerifiedHolds() async throws {
    let fixture = ValidationTransportFixture(movingStops: false)
    let report = try await fixture.run()
    #expect(report.failedStage == "stop.pan.0.interruption")
    #expect(report.failureCode == "validation_no_interrupted_motion")
    #expect(report.stopTrials.count == 4)
    #expect(report.stopTrials.allSatisfy { $0.stable && $0.restorationStable })
    #expect(report.positionTrials.count == 40)
    #expect(await fixture.writes.count == 52)
    #expect(await fixture.cleanupWrites.count == 1)
    #expect(!report.stopPassed && !report.positionPassed && !report.restored)
}

@Test func validationV5ReadFailureStillMakesOneIndependentCurrentHold() async throws {
    let fixture = ValidationTransportFixture(failingRead: 6)
    let report = try await fixture.run()
    #expect(report.failureCode == "fixture_read_failure")
    #expect(report.positionTrials.isEmpty)
    #expect(await fixture.writes.count == 1)
    #expect(await fixture.cleanupWrites == [.init(pan: 3600, tilt: 0)])
    #expect(report.cleanup?.stable == true)
}

@Test func validationV5TaskCancellationAloneDoesNotCancelCleanup() async throws {
    let fixture = ValidationTransportFixture(cancelAtWrite: 1)
    let task = Task { try await fixture.run() }
    let report = try await task.value
    #expect(report.cancelled == true)
    #expect(report.failureCode == "cancelled")
    #expect(await fixture.writes.count == 1)
    #expect(await fixture.cleanupWrites == [.init(pan: 3600, tilt: 0)])
    #expect(report.cleanup?.writeSubmitted == true)
    #expect(report.cleanup?.stable == true)
}

@Test func validationV5GlobalStopPermitFencesIndependentCleanup() async throws {
    let fixture = ValidationTransportFixture(cancelAtWrite: 1, invalidateOnCancel: true)
    let task = Task { try await fixture.run() }
    let report = try await task.value
    #expect(report.cancelled == true)
    #expect(await fixture.writes.count == 1)
    #expect(await fixture.cleanupWrites.isEmpty)
    #expect(report.cleanup?.attempted == false)
    #expect(report.cleanup?.writeSubmitted == false)
    #expect(report.cleanup?.failureCode == "cancelled")
}

@Test func validationV5ChangedAttachmentCannotReceiveCleanupHold() async throws {
    let fixture = ValidationTransportFixture(changedIdentityFromRead: 6)
    let report = try await fixture.run()
    #expect(report.failureCode == "uvc_attachment_changed")
    #expect(report.cleanup?.failureCode == "uvc_attachment_changed")
    #expect(report.cleanup?.attempted == false)
    #expect(report.cleanup?.writeSubmitted == false)
    #expect(await fixture.writes.count == 1)
    #expect(await fixture.cleanupWrites.isEmpty)
}

@Test func validationV5CleanupWriteFailureIsReportedWithoutRetryOrRestore() async throws {
    let fixture = ValidationTransportFixture(faultAtWrite: 1, failCleanupWrite: true)
    let report = try await fixture.run()
    #expect(report.failureCode == "validation_position_unsettled")
    #expect(report.cleanup?.attempted == true)
    #expect(report.cleanup?.writeSubmitted == false)
    #expect(report.cleanup?.stable == false)
    #expect(report.cleanup?.failureCode == "fixture_hold_failure")
    #expect(await fixture.writes.count == 1)
    #expect(await fixture.cleanupWrites.isEmpty)
}

@Test func validationV5PermitInvalidationAfterCleanupReadFencesFinalWrite() async throws {
    let fixture = ValidationTransportFixture(faultAtWrite: 1, invalidateAtCleanupWrite: true)
    let report = try await fixture.run()
    #expect(report.cleanup?.target == .init(pan: 5400, tilt: 0))
    #expect(report.cleanup?.attempted == true)
    #expect(report.cleanup?.writeSubmitted == false)
    #expect(report.cleanup?.failureCode == "cancelled")
    #expect(await fixture.writes.count == 1)
    #expect(await fixture.cleanupWrites.isEmpty)
}

@Test func validationV5AcceptanceRejectsLegacyPartialCancelledAndRecoveredReports() async throws {
    let valid = try await ValidationTransportFixture().run()
    #expect(HardwareValidator.accepts(valid))
    var report = valid
    report.version = 4
    #expect(!HardwareValidator.accepts(report))
    report = valid; report.profile = nil
    #expect(!HardwareValidator.accepts(report))
    report = valid; report.profile = "continuous_motion"
    #expect(!HardwareValidator.accepts(report))
    report = valid; report.positionTrials.removeLast()
    #expect(!HardwareValidator.accepts(report))
    report = valid; report.stopTrials.removeLast()
    #expect(!HardwareValidator.accepts(report))
    report = valid; report.cancelled = true
    #expect(!HardwareValidator.accepts(report))
    report = valid; report.cancelled = nil
    #expect(!HardwareValidator.accepts(report))
    report = valid; report.failedStage = "final"
    #expect(!HardwareValidator.accepts(report))
    report = valid; report.failureCode = "validation_final_drift"
    #expect(!HardwareValidator.accepts(report))
    report = valid
    report.cleanup = .init(attempted: true, writeSubmitted: true, target: report.original,
                           observed: report.original, stable: true, residual: 0)
    #expect(!HardwareValidator.accepts(report))
    report = valid; report.final.pan += 1800
    #expect(!HardwareValidator.accepts(report))
}
