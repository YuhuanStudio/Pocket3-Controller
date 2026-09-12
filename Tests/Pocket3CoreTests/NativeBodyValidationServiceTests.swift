import Foundation
import Testing
@testable import Pocket3Core

@Suite("Native body validation service") struct NativeBodyValidationServiceTests {
    private actor CallCounter {
        var value = 0
        func increment() { value += 1 }
        func read() -> Int { value }
    }

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
            generation: session.generation, receivedUptime: uptime, statusByte: statusByte)
    }

    private func videoParameters(resolution: CameraVideoResolution,
                                 frameRate: CameraFrameRate) -> CameraVideoParameters {
        CameraVideoParameters(raw: Data([resolution.rawValue, frameRate.rawValue, 0, 0, 0, 0, 0, 0, 0]),
            resolutionRaw: resolution.rawValue, frameRateRaw: frameRate.rawValue,
            compressionRaw: CameraVideoCompression.h264Compatibility.rawValue,
            resolution: resolution, frameRate: frameRate,
            compression: .h264Compatibility)
    }

    private func capabilities() -> CameraVideoFormatCapabilities {
        // version 1, inner length 4, one legal portrait-1080/30 entry
        CameraVideoFormatCapabilityDecoder.decode(
            Data([1, 4, 0, 1, CameraVideoResolution.portrait1080.rawValue,
                  CameraFrameRate.fps30.rawValue, 0]))!
    }

    private func transaction(for request: NativeCommandTransactionRequest,
                             observedPayload: Data? = nil,
                             generation: UInt64? = nil,
                             end: NativeCommandTransactionEnd = .acknowledged) -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: generation ?? request.generation,
            sessionID: request.sessionID, end: end)
        result.sequence = 0x9001
        result.submitted = true
        result.submittedUptime = 11
        result.responseReceived = end != .timedOut && end != .cancelled && end != .generationChanged
        result.acknowledged = end == .acknowledged || end == .observed
        result.acknowledgedUptime = result.acknowledged ? 11.1 : nil
        result.observedPayload = observedPayload
        result.observed = observedPayload != nil
        result.observedUptime = observedPayload == nil ? nil : 11.2
        result.end = observedPayload == nil ? end : .observed
        result.finishedUptime = 11.3
        return result
    }

    @Test func dryRunBuildsExactRecordRequestWithoutCallingExecutor() async throws {
        let session = readySession()
        let counter = CallCounter()
        let service = NativeBodyValidationService(executor: { _, _ in
            await counter.increment()
            fatalError("dry-run must not call the executor")
        })
        let snapshot = NativeBodyValidationSnapshot(session: session,
            recordingBaseline: lifecycle(session, statusByte: 0x01, at: 10), nowUptime: 10)

        let result = try await service.run(.init(operation: .start), snapshot: snapshot)
        #expect(result.dryRun)
        #expect(result.submissionCount == 0)
        #expect(result.recording?.phase == .awaitingAcknowledgment)
        #expect(result.request.command == .record)
        #expect(result.request.frame.commandSet == 0x02)
        #expect(result.request.frame.commandID == 0x02)
        #expect(result.request.frame.payload == Data([0x01]))
        #expect(await counter.read() == 0)
    }

    @Test func executeCallsInjectedExecutorOnceAndPreservesTerminalEvidence() async throws {
        let session = readySession()
        let counter = CallCounter()
        let adapter = NativeBodyValidationExecutorAdapter { request, _ in
            await counter.increment()
            return transaction(for: request, observedPayload: Data([0x81]))
        }
        let service = NativeBodyValidationService(adapter: adapter)
        let snapshot = NativeBodyValidationSnapshot(session: session,
            recordingBaseline: lifecycle(session, statusByte: 0x01, at: 10), nowUptime: 10)

        let result = try await service.run(.init(operation: .start, execute: true), snapshot: snapshot)
        #expect(!result.dryRun)
        #expect(result.submissionCount == 1)
        #expect(result.recording?.submitted == true)
        #expect(result.recording?.acknowledged == true)
        #expect(result.recording?.observed == true)
        #expect(result.recording?.completed == true)
        #expect(result.failureCode == nil)
        #expect(await counter.read() == 1)
    }

    @Test func executeWithoutOwnerReturnsPlanAndDoesNotPretendToSubmit() async throws {
        let session = readySession()
        let snapshot = NativeBodyValidationSnapshot(session: session,
            recordingBaseline: lifecycle(session, statusByte: 0x01, at: 10), nowUptime: 10)

        let result = try await NativeBodyValidationService().run(
            .init(operation: .start, execute: true), snapshot: snapshot)
        #expect(result.submissionCount == 0)
        #expect(result.recording?.submitted == false)
        #expect(result.recording?.completed == false)
        #expect(result.failureCode == "native_body_executor_unavailable")
    }

    @Test func formatDryRunRequiresFreshBaselineAndIndependentLegalCapability() async throws {
        let session = readySession()
        let target = CameraBodyRecordingFormatCommand(resolution: .portrait1080,
                                                       frameRate: .fps30)
        let baseline = NativeBodyFormatReadback(sessionID: session.sessionID!,
            generation: session.generation, receivedUptime: 20,
            parameters: videoParameters(resolution: .p1080, frameRate: .fps30))
        let snapshot = NativeBodyValidationSnapshot(session: session,
            formatBaseline: baseline, formatCapabilities: capabilities(), nowUptime: 20)

        let result = try await NativeBodyValidationService().run(
            .init(operation: .format, format: target), snapshot: snapshot)
        #expect(result.dryRun)
        #expect(result.submissionCount == 0)
        #expect(result.format?.phase == .awaitingAcknowledgment)
        #expect(result.request.frame.commandSet == 0x02)
        #expect(result.request.frame.commandID == 0x18)
        #expect(result.request.frame.payload == Data([0x42, 0x03, 0, 0, 0]))

        let missingCapability = NativeBodyValidationSnapshot(session: session,
            formatBaseline: baseline, nowUptime: 20)
        do {
            _ = try await NativeBodyValidationService().run(
                .init(operation: .format, format: target), snapshot: missingCapability)
            Issue.record("A format validation without legal capability evidence must fail")
        } catch let error as NativeBodyValidationServiceError {
            #expect(error == .legalCapabilityRequired)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func pairedSessionCannotCrossCommandReadyGate() async throws {
        var session = NativeCameraSession()
        let generation = session.begin(sessionID: UUID(), peerID: UUID())
        _ = session.markPaired(generation: generation)
        let snapshot = NativeBodyValidationSnapshot(session: session.status,
            recordingBaseline: NativeBodyRecordingLifecycleSample(
                sessionID: session.sessionID!, generation: generation,
                receivedUptime: 30, statusByte: 0x01), nowUptime: 30)

        do {
            _ = try await NativeBodyValidationService().run(.init(operation: .start), snapshot: snapshot)
            Issue.record("A paired-only session must not prepare a body command")
        } catch let error as NativeBodyRecordingCoordinatorError {
            #expect(error == .sessionNotReady)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func staleExecutorResultProducesPartialGenerationEvidenceWithoutRetry() async throws {
        let session = readySession()
        let counter = CallCounter()
        let service = NativeBodyValidationService(executor: { request, _ in
            await counter.increment()
            return transaction(for: request, generation: request.generation + 1)
        })
        let snapshot = NativeBodyValidationSnapshot(session: session,
            recordingBaseline: lifecycle(session, statusByte: 0x01, at: 40), nowUptime: 41)

        let result = try await service.run(.init(operation: .start, execute: true), snapshot: snapshot)
        #expect(await counter.read() == 1)
        #expect(result.submissionCount == 1)
        #expect(result.recording?.completed == false)
        #expect(result.recording?.phase == .generationChanged)
        #expect(result.recording?.failureCode == "native_record_stale_transaction")
    }
}
