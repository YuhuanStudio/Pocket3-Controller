import Testing
@testable import Pocket3Core

@Suite struct CaptureOwnershipPolicyTests {
    @Test func happyPathRequiresBothOwnershipFences() throws {
        var policy = CaptureOwnershipPolicy(initialState: .avfoundationRunning)

        let stop = try policy.beginDirectCapture()
        #expect(policy.state == .stoppingAVF)
        #expect(stop.stage == .stoppingAVF)

        let acquire = try policy.avfoundationStopped(stop, evidence: .complete)
        #expect(policy.state == .acquiringDirect)
        #expect(acquire.stage == .acquiringDirect)
        #expect(acquire.generation > stop.generation)
        try policy.directAcquired(acquire)
        #expect(policy.state == .directRunning)
        #expect(policy.activePermit == nil)

        let release = try policy.beginAVFoundationRestart()
        #expect(policy.state == .releasingDirect)
        let restart = try policy.directReleased(release, evidence: .complete)
        #expect(policy.state == .restartingAVF)
        #expect(restart.generation > release.generation)
        try policy.avfoundationRestarted(restart)
        #expect(policy.state == .avfoundationRunning)
        #expect(policy.failure == nil)
    }

    @Test func incompleteEvidenceCannotOpenOrRestartAnOwner() throws {
        var policy = CaptureOwnershipPolicy(initialState: .avfoundationRunning)
        let stop = try policy.beginDirectCapture()

        do {
            _ = try policy.avfoundationStopped(stop,
                evidence: AVFoundationStopEvidence(avfoundationStopped: true, frameQueueDrained: false))
            Issue.record("AVFoundation stop without a drained frame queue was admitted")
        } catch let error as CaptureOwnershipError {
            #expect(error == .evidenceRequired(.avfoundationStoppedAndFrameQueueDrained))
        }
        #expect(policy.state == .stoppingAVF)

        let acquire = try policy.avfoundationStopped(stop, evidence: .complete)
        try policy.directAcquired(acquire)
        let release = try policy.beginAVFoundationRestart()
        do {
            _ = try policy.directReleased(release,
                evidence: DirectCaptureReleaseEvidence(readerStopped: true, pipeReleased: true,
                                                        interfaceReleased: true, objectsReleased: false))
            Issue.record("Direct restart was admitted before all resources were released")
        } catch let error as CaptureOwnershipError {
            #expect(error == .evidenceRequired(.directCaptureReleased))
        }
        #expect(policy.state == .releasingDirect)
    }

    @Test func everyStableAndTransitionStateRejectsASecondOwner() throws {
        var policy = CaptureOwnershipPolicy(initialState: .avfoundationRunning)
        let stop = try policy.beginDirectCapture()
        expectBusy(.stoppingAVF) { _ = try policy.beginDirectCapture() }
        let acquire = try policy.avfoundationStopped(stop, evidence: .complete)
        expectBusy(.acquiringDirect) { _ = try policy.beginDirectCapture() }
        try policy.directAcquired(acquire)
        expectBusy(.directRunning) { _ = try policy.beginDirectCapture() }
        let release = try policy.beginAVFoundationRestart()
        expectBusy(.releasingDirect) { _ = try policy.beginDirectCapture() }
        let restart = try policy.directReleased(release, evidence: .complete)
        expectBusy(.restartingAVF) { _ = try policy.beginDirectCapture() }
        try policy.avfoundationRestarted(restart)
        expectBusy(.avfoundationRunning) { _ = try policy.beginAVFoundationRestart() }

        policy.disconnect()
        expectBusy(.idle) { _ = try policy.beginDirectCapture() }
        try policy.avfoundationStarted()
        #expect(policy.state == .avfoundationRunning)
    }

    @Test func cancellationAtEveryAsyncStageEntersErrorAndFencesCallbacks() throws {
        for stage in CaptureOwnershipStage.allCases {
            var policy = CaptureOwnershipPolicy(initialState: .avfoundationRunning)
            let permit: CaptureOwnershipPermit
            switch stage {
            case .stoppingAVF:
                permit = try policy.beginDirectCapture()
            case .acquiringDirect:
                let stop = try policy.beginDirectCapture()
                permit = try policy.avfoundationStopped(stop, evidence: .complete)
            case .releasingDirect:
                let stop = try policy.beginDirectCapture()
                let acquire = try policy.avfoundationStopped(stop, evidence: .complete)
                try policy.directAcquired(acquire)
                permit = try policy.beginAVFoundationRestart()
            case .restartingAVF:
                let stop = try policy.beginDirectCapture()
                let acquire = try policy.avfoundationStopped(stop, evidence: .complete)
                try policy.directAcquired(acquire)
                let release = try policy.beginAVFoundationRestart()
                permit = try policy.directReleased(release, evidence: .complete)
            }

            try policy.cancel(permit)
            #expect(policy.state == .error)
            #expect(policy.failure == .cancelled(stage))
            #expect(policy.activePermit == nil)
            #expect(policy.generation > permit.generation)

            do {
                switch stage {
                case .stoppingAVF:
                    _ = try policy.avfoundationStopped(permit, evidence: .complete)
                case .acquiringDirect:
                    try policy.directAcquired(permit)
                case .releasingDirect:
                    _ = try policy.directReleased(permit, evidence: .complete)
                case .restartingAVF:
                    try policy.avfoundationRestarted(permit)
                }
                Issue.record("A cancelled \(stage.rawValue) callback changed policy state")
            } catch let error as CaptureOwnershipError {
                #expect(error == .stalePermit)
            }
            #expect(policy.state == .error)
        }
    }

    @Test func staleEarlierStageCompletionCannotCompleteLaterStage() throws {
        var policy = CaptureOwnershipPolicy(initialState: .avfoundationRunning)
        let stop = try policy.beginDirectCapture()
        let acquire = try policy.avfoundationStopped(stop, evidence: .complete)
        #expect(throws: CaptureOwnershipError.stalePermit) {
            _ = try policy.avfoundationStopped(stop, evidence: .complete)
        }
        #expect(policy.state == .acquiringDirect)
        try policy.directAcquired(acquire)

        let release = try policy.beginAVFoundationRestart()
        let restart = try policy.directReleased(release, evidence: .complete)
        #expect(throws: CaptureOwnershipError.stalePermit) {
            _ = try policy.directReleased(release, evidence: .complete)
        }
        #expect(policy.state == .restartingAVF)
        try policy.avfoundationRestarted(restart)
        #expect(policy.state == .avfoundationRunning)
    }

    @Test func disconnectInvalidatesAllOutstandingPermitsAndRequiresFreshAVFStart() throws {
        var policy = CaptureOwnershipPolicy(initialState: .avfoundationRunning)
        let stop = try policy.beginDirectCapture()
        let before = policy.generation
        policy.disconnect()

        #expect(policy.state == .idle)
        #expect(policy.failure == .disconnected)
        #expect(policy.generation > before)
        #expect(policy.activePermit == nil)
        #expect(throws: CaptureOwnershipError.stalePermit) {
            _ = try policy.avfoundationStopped(stop, evidence: .complete)
        }

        try policy.avfoundationStarted()
        let fresh = try policy.beginDirectCapture()
        #expect(fresh.generation > stop.generation)
    }

    @Test func failedReleaseRequiresReleaseEvidenceBeforeRestart() throws {
        var policy = try directRunningPolicy()
        let release = try policy.beginAVFoundationRestart()
        try policy.fail(release)
        #expect(policy.state == .error)
        #expect(policy.failure == .operationFailed(.releasingDirect))

        #expect(throws: CaptureOwnershipError.evidenceRequired(.directCaptureReleased)) {
            _ = try policy.retryAVFoundationRestart(after: DirectCaptureReleaseEvidence())
        }
        let restart = try policy.retryAVFoundationRestart(after: .complete)
        #expect(policy.state == .restartingAVF)
        try policy.avfoundationRestarted(restart)
        #expect(policy.state == .avfoundationRunning)
    }

    @Test func failedRestartCanRetryButStaleFailureCannotFinishIt() throws {
        var policy = try directRunningPolicy()
        let release = try policy.beginAVFoundationRestart()
        let restart = try policy.directReleased(release, evidence: .complete)
        try policy.fail(restart)
        #expect(policy.state == .error)
        #expect(policy.failure == .operationFailed(.restartingAVF))

        let retry = try policy.retryAVFoundationRestart()
        #expect(retry.generation > restart.generation)
        #expect(throws: CaptureOwnershipError.stalePermit) {
            try policy.avfoundationRestarted(restart)
        }
        #expect(policy.state == .restartingAVF)
        try policy.avfoundationRestarted(retry)
        #expect(policy.state == .avfoundationRunning)
    }

    @Test func failedDirectAcquisitionRequiresDirectReleaseBeforeAVFRestart() throws {
        var policy = CaptureOwnershipPolicy(initialState: .avfoundationRunning)
        let stop = try policy.beginDirectCapture()
        let acquire = try policy.avfoundationStopped(stop, evidence: .complete)
        try policy.fail(acquire)
        #expect(policy.state == .error)
        #expect(policy.failure == .operationFailed(.acquiringDirect))

        #expect(throws: CaptureOwnershipError.evidenceRequired(.directCaptureReleased)) {
            _ = try policy.retryAVFoundationRestart(after: DirectCaptureReleaseEvidence())
        }
        let restart = try policy.retryAVFoundationRestart(after: .complete)
        try policy.avfoundationRestarted(restart)
        #expect(policy.state == .avfoundationRunning)
    }

    @Test func actorSerializesConcurrentAcquisitionRequests() async throws {
        let coordinator = CaptureOwnershipCoordinator(initialState: .avfoundationRunning)
        let successes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<32 {
                group.addTask {
                    do {
                        _ = try await coordinator.beginDirectCapture()
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(successes.filter { $0 }.count == 1)
        #expect(await coordinator.state() == .stoppingAVF)
    }

    private func directRunningPolicy() throws -> CaptureOwnershipPolicy {
        var policy = CaptureOwnershipPolicy(initialState: .avfoundationRunning)
        let stop = try policy.beginDirectCapture()
        let acquire = try policy.avfoundationStopped(stop, evidence: .complete)
        try policy.directAcquired(acquire)
        return policy
    }

    private func expectBusy(_ state: CaptureOwnershipState,
                            _ body: () throws -> Any) {
        do {
            _ = try body()
            Issue.record("A second owner was admitted in \(state.rawValue)")
        } catch let error as CaptureOwnershipError {
            #expect(error == .busy(state))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
