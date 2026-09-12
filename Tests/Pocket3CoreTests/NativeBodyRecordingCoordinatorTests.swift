import Foundation
import Testing
@testable import Pocket3Core

@Suite("Native body recording coordinator") struct NativeBodyRecordingCoordinatorTests {
    private func readySession() -> NativeCameraSessionStatus {
        var session = NativeCameraSession()
        let generation = session.begin(sessionID: UUID(), peerID: UUID())
        _ = session.markPaired(generation: generation)
        _ = session.markCredentialsAvailable(generation: generation)
        _ = session.observeDatalink(.connecting, generation: generation)
        _ = session.observeDatalink(.ready, generation: generation)
        return session.status
    }

    private func lifecycle(_ session: NativeCameraSessionStatus,
                           statusByte: UInt8, at uptime: TimeInterval) -> NativeBodyRecordingLifecycleSample {
        NativeBodyRecordingLifecycleSample(sessionID: session.sessionID!,
            generation: session.generation, receivedUptime: uptime,
            statusByte: statusByte)
    }

    private func transaction(for request: NativeCommandTransactionRequest,
                             end: NativeCommandTransactionEnd = .acknowledged,
                             submittedAt: TimeInterval = 11,
                             responseAt: TimeInterval = 11.1,
                             observedPayload: Data? = nil) -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: request.generation,
            sessionID: request.sessionID)
        result.sequence = 0x9001
        result.submitted = true; result.submittedUptime = submittedAt
        result.responseReceived = end != .timedOut && end != .cancelled && end != .generationChanged
        result.acknowledged = end == .acknowledged || end == .observed
        result.acknowledgedUptime = result.acknowledged ? responseAt : nil
        result.observedPayload = observedPayload
        result.observed = observedPayload != nil
        result.observedUptime = observedPayload == nil ? nil : responseAt
        result.end = end; result.finishedUptime = responseAt
        return result
    }

    private func videoParameters(resolution: CameraVideoResolution,
                                 frameRate: CameraFrameRate) -> CameraVideoParameters {
        CameraVideoParameters(raw: Data([resolution.rawValue, frameRate.rawValue, 0, 0, 0, 0, 0, 0, 0]),
            resolutionRaw: resolution.rawValue, frameRateRaw: frameRate.rawValue,
            compressionRaw: CameraVideoCompression.h264Compatibility.rawValue,
            resolution: resolution, frameRate: frameRate,
            compression: .h264Compatibility)
    }

    private func formatReadback(_ session: NativeCameraSessionStatus,
                                resolution: CameraVideoResolution,
                                frameRate: CameraFrameRate,
                                at uptime: TimeInterval) -> NativeBodyFormatReadback {
        NativeBodyFormatReadback(sessionID: session.sessionID!, generation: session.generation,
            receivedUptime: uptime, parameters: videoParameters(resolution: resolution, frameRate: frameRate))
    }

    @Test func startRequiresTerminalRecordingStateAfterPositiveAck() throws {
        let session = readySession()
        var coordinator = try NativeBodyRecordingCoordinator(session: session)
        let baseline = lifecycle(session, statusByte: 0x01, at: 10)
        let request = try coordinator.prepareRecord(.start, baseline: baseline, nowUptime: 10)
        #expect(request.command == .record)
        #expect(request.frame.commandSet == 2 && request.frame.commandID == 2)
        #expect(request.frame.payload == Data([1]))
        #expect(coordinator.phase == .awaitingAcknowledgment)

        let ack = transaction(for: request)
        let appliedAck = coordinator.apply(ack, nowUptime: 11.1)
        #expect(!appliedAck)
        #expect(coordinator.phase == .awaitingReadback)
        #expect(coordinator.result?.acknowledged == true)
        #expect(coordinator.result?.observed == false)
        #expect(coordinator.result?.completed == false)

        let transition = lifecycle(session, statusByte: 0xC1, at: 11.2)
        let observedTransition = coordinator.observe(transition, nowUptime: 11.2)
        #expect(!observedTransition)
        #expect(coordinator.phase == .awaitingReadback)
        let terminal = lifecycle(session, statusByte: 0x81, at: 11.3)
        let observedTerminal = coordinator.observe(terminal, nowUptime: 11.3)
        #expect(observedTerminal)
        #expect(coordinator.phase == .completed)
        #expect(coordinator.result?.observed == true && coordinator.result?.completed == true)
    }

    @Test func stopUsesIdleTerminalStateAndTransitionIsNotCompletion() throws {
        let session = readySession()
        var coordinator = try NativeBodyRecordingCoordinator(session: session)
        let baseline = lifecycle(session, statusByte: 0x81, at: 20)
        let request = try coordinator.prepareRecord(.stop, baseline: baseline, nowUptime: 20)
        #expect(request.frame.payload == Data([0]))
        let ack = transaction(for: request, submittedAt: 21, responseAt: 21.1)
        let appliedAck = coordinator.apply(ack, nowUptime: 21.1)
        #expect(!appliedAck)
        let observedTransition = coordinator.observe(lifecycle(session, statusByte: 0x41, at: 21.2), nowUptime: 21.2)
        #expect(!observedTransition)
        let observedTerminal = coordinator.observe(lifecycle(session, statusByte: 0x01, at: 21.3), nowUptime: 21.3)
        #expect(observedTerminal)
        #expect(coordinator.result?.lifecycle?.status.lifecycle == .idle)
    }

    @Test func matchingReadbackCanCompleteFromTheTransactionObservation() throws {
        let session = readySession()
        var coordinator = try NativeBodyRecordingCoordinator(session: session)
        let baseline = lifecycle(session, statusByte: 0x01, at: 30)
        let request = try coordinator.prepareRecord(.start, baseline: baseline, nowUptime: 30)
        let observed = transaction(for: request, end: .observed,
            submittedAt: 31, responseAt: 31.2, observedPayload: Data([0x81]))
        let applied = coordinator.apply(observed, nowUptime: 31.2)
        #expect(applied)
        #expect(coordinator.result?.submitted == true)
        #expect(coordinator.result?.acknowledged == true)
        #expect(coordinator.result?.observed == true)
        #expect(coordinator.result?.completed == true)
    }

    @Test func staleSessionOrGenerationReadbackCannotComplete() throws {
        let session = readySession()
        var coordinator = try NativeBodyRecordingCoordinator(session: session)
        let baseline = lifecycle(session, statusByte: 0x01, at: 40)
        let request = try coordinator.prepareRecord(.start, baseline: baseline, nowUptime: 40)
        let ack = transaction(for: request, submittedAt: 41, responseAt: 41.1)
        _ = coordinator.apply(ack, nowUptime: 41.1)

        let wrongSession = NativeBodyRecordingLifecycleSample(sessionID: UUID(),
            generation: session.generation, receivedUptime: 41.2, statusByte: 0x81)
        let wrongSessionAccepted = coordinator.observe(wrongSession, nowUptime: 41.2)
        #expect(!wrongSessionAccepted)
        let wrongGeneration = NativeBodyRecordingLifecycleSample(sessionID: session.sessionID!,
            generation: session.generation + 1, receivedUptime: 41.2, statusByte: 0x81)
        let wrongGenerationAccepted = coordinator.observe(wrongGeneration, nowUptime: 41.2)
        #expect(!wrongGenerationAccepted)
        let oldSample = lifecycle(session, statusByte: 0x81, at: 40)
        let oldSampleAccepted = coordinator.observe(oldSample, nowUptime: 41.2)
        #expect(!oldSampleAccepted)
        #expect(coordinator.phase == .awaitingReadback)
    }

    @Test func ackAloneTimeoutAndCancellationNeverReportCompleted() throws {
        let session = readySession()
        var timeoutCoordinator = try NativeBodyRecordingCoordinator(session: session)
        let baseline = lifecycle(session, statusByte: 0x01, at: 50)
        let timeoutRequest = try timeoutCoordinator.prepareRecord(.start, baseline: baseline, nowUptime: 50)
        var timedOut = transaction(for: timeoutRequest, end: .timedOut, submittedAt: 51, responseAt: 54)
        timedOut.failureCode = "native_command_timeout"
        let timeoutApplied = timeoutCoordinator.apply(timedOut, nowUptime: 54)
        #expect(!timeoutApplied)
        #expect(timeoutCoordinator.phase == .timedOut)
        #expect(timeoutCoordinator.result?.submitted == true && timeoutCoordinator.result?.completed == false)

        var cancelledCoordinator = try NativeBodyRecordingCoordinator(session: session)
        let cancelRequest = try cancelledCoordinator.prepareRecord(.start, baseline: baseline, nowUptime: 50)
        let cancelAccepted = cancelledCoordinator.cancel(generation: session.generation)
        #expect(cancelAccepted)
        #expect(cancelledCoordinator.phase == .cancelled)
        var cancelled = transaction(for: cancelRequest, end: .cancelled, submittedAt: 51, responseAt: 51.1)
        cancelled.failureCode = "cancelled"
        let cancelledApplied = cancelledCoordinator.apply(cancelled, nowUptime: 51.1)
        #expect(!cancelledApplied)
        #expect(cancelledCoordinator.phase == .cancelled || cancelledCoordinator.phase == .generationChanged)
        #expect(cancelledCoordinator.result?.completed == false)
    }

    @Test func sameCurrentStateIsRejectedAsNoOp() throws {
        let session = readySession()
        var coordinator = try NativeBodyRecordingCoordinator(session: session)
        let baseline = lifecycle(session, statusByte: 0x81, at: 60)
        #expect(throws: NativeBodyRecordingCoordinatorError.alreadyAtTarget) {
            try coordinator.prepareRecord(.start, baseline: baseline, nowUptime: 60)
        }
    }

    @Test func formatAckAloneCannotCompleteAndMatchingVideoParameterReadbackCan() throws {
        let session = readySession()
        var coordinator = try NativeBodyFormatCoordinator(session: session)
        let baseline = formatReadback(session, resolution: .p1080, frameRate: .fps30, at: 70)
        let target = CameraBodyRecordingFormatCommand(resolution: .portrait1080, frameRate: .fps30)
        let request = try coordinator.prepare(target, baseline: baseline, nowUptime: 70)
        #expect(request.command == .bodyFormat)
        #expect(request.frame.commandSet == 2 && request.frame.commandID == 0x18)
        #expect(request.frame.payload == Data([0x42, 0x03, 0, 0, 0]))

        let ack = transaction(for: request, submittedAt: 71, responseAt: 71.1)
        let appliedAck = coordinator.apply(ack, nowUptime: 71.1)
        #expect(!appliedAck)
        #expect(coordinator.phase == .awaitingReadback)
        #expect(coordinator.result?.acknowledged == true && coordinator.result?.completed == false)

        let legalButNotSelected = NativeBodyFormatReadback(sessionID: session.sessionID!,
            generation: session.generation, receivedUptime: 71.2,
            capabilities: CameraVideoFormatCapabilityDecoder.decode(
                Data([1, 4, 0, 1, 0x42, 0x03, 0]))!)
        let legalObserved = coordinator.observe(legalButNotSelected, nowUptime: 71.2)
        #expect(!legalObserved)
        let matching = formatReadback(session, resolution: .portrait1080, frameRate: .fps30, at: 71.3)
        let matchingObserved = coordinator.observe(matching, nowUptime: 71.3)
        #expect(matchingObserved)
        #expect(coordinator.result?.observed == true && coordinator.result?.completed == true)
    }

    @Test func formatPreparationRequiresKnownLegalEvidenceAndRejectsStaleReadback() throws {
        let session = readySession()
        var missingEvidence = try NativeBodyFormatCoordinator(session: session)
        let target = CameraBodyRecordingFormatCommand(resolution: .portrait1080, frameRate: .fps30)
        #expect(throws: NativeBodyFormatCoordinatorError.missingCapabilityEvidence) {
            try missingEvidence.prepare(target, baseline: nil, nowUptime: 80)
        }

        var coordinator = try NativeBodyFormatCoordinator(session: session)
        let baseline = formatReadback(session, resolution: .p1080, frameRate: .fps30, at: 80)
        let request = try coordinator.prepare(target, baseline: baseline, nowUptime: 80)
        let ack = transaction(for: request, submittedAt: 81, responseAt: 81.1)
        _ = coordinator.apply(ack, nowUptime: 81.1)
        let stale = formatReadback(session, resolution: .portrait1080, frameRate: .fps30, at: 80)
        let staleObserved = coordinator.observe(stale, nowUptime: 81.2)
        #expect(!staleObserved)
        #expect(coordinator.phase == .awaitingReadback)
    }
}
