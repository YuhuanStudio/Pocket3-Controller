import Foundation
import Testing
@testable import Pocket3Core

@Suite("Camera body ordinary Video service")
struct CameraBodyRecordingServiceTests {
    private let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let peripheralID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func readySession() -> NativeCameraSessionStatus {
        var session = NativeCameraSession()
        let generation = session.begin(sessionID: sessionID, peerID: peripheralID)
        _ = session.markPaired(generation: generation)
        _ = session.markCredentialsAvailable(generation: generation)
        _ = session.observeDatalink(.connecting, generation: generation)
        _ = session.observeDatalink(.ready, generation: generation)
        return session.status
    }

    private func parameters(
        resolution: CameraVideoResolution = .p1080,
        frameRate: CameraFrameRate = .fps30
    ) -> CameraVideoParameters {
        CameraVideoParameters(
            raw: Data([resolution.rawValue, frameRate.rawValue, 0, 0, 0, 0, 0, 0, 0]),
            resolutionRaw: resolution.rawValue,
            frameRateRaw: frameRate.rawValue,
            compressionRaw: CameraVideoCompression.h264Compatibility.rawValue,
            resolution: resolution, frameRate: frameRate,
            compression: .h264Compatibility)
    }

    private func legalFormats() -> CameraVideoFormatCapabilities {
        CameraVideoFormatCapabilityDecoder.decode(
            Data([1, 4, 0, 1, CameraVideoResolution.portrait1080.rawValue,
                  CameraFrameRate.fps30.rawValue, 0]))!
    }

    private func snapshot(
        mode: Pocket3ShootingMode? = .video,
        now: TimeInterval = 20
    ) -> NativeBodyValidationSnapshot {
        let session = readySession()
        let status = NativeBodyRecordingLifecycleSample(
            sessionID: sessionID, generation: session.generation,
            receivedUptime: now - 0.1, statusByte: 0x01)
        let baseline = NativeBodyFormatReadback(
            sessionID: sessionID, generation: session.generation,
            receivedUptime: now - 0.1,
            parameters: parameters())
        return NativeBodyValidationSnapshot(
            session: session, videoMode: mode,
            recordingBaseline: status, formatBaseline: baseline,
            formatCapabilities: legalFormats(), nowUptime: now)
    }

    private func transaction(
        for request: NativeCommandTransactionRequest,
        observedPayload: Data? = nil
    ) -> NativeCommandTransactionResult {
        var value = NativeCommandTransactionResult(
            id: request.id, command: request.command,
            generation: request.generation, sessionID: request.sessionID,
            end: observedPayload == nil ? .acknowledged : .observed)
        value.sequence = 7
        value.submitted = true; value.submittedUptime = 20.1
        value.responseReceived = true; value.acknowledged = true
        value.acknowledgedUptime = 20.2
        value.observedPayload = observedPayload
        value.observed = observedPayload != nil
        value.observedUptime = observedPayload == nil ? nil : 20.3
        value.finishedUptime = 20.4
        return value
    }

    @Test func requestRoundTripsAndFormatIsRequiredOnlyForFormatAction() throws {
        let request = try CameraBodyRecordingRequest(
            action: .format, expectedSessionID: sessionID,
            peripheralID: peripheralID, generation: 1,
            format: .init(resolution: .portrait1080, frameRate: .fps30),
            execute: true)
        let decoded = try JSONDecoder().decode(
            CameraBodyRecordingRequest.self,
            from: JSONEncoder().encode(request))
        #expect(decoded == request)
        let cli = try CameraBodyRecordingRequest(cliArguments: [
            "--action", "start", "--session", sessionID.uuidString,
            "--peripheral", peripheralID.uuidString, "--generation", "1"
        ])
        #expect(cli.action == .start && !cli.execute)
        #expect(throws: CameraBodyRecordingRequestError.formatRequired) {
            try CameraBodyRecordingRequest(
                action: .format, expectedSessionID: sessionID,
                peripheralID: peripheralID, generation: 1)
        }
        #expect(throws: CameraBodyRecordingRequestError.invalidFormat) {
            try CameraBodyRecordingRequest(
                action: .start, expectedSessionID: sessionID,
                peripheralID: peripheralID, generation: 1,
                format: .init(resolution: .p1080, frameRate: .fps30))
        }
    }

    @Test func executeSendsOnceAndRequiresMatchingTerminalReadback() async throws {
        let counter = CallCounter()
        let adapter = NativeBodyValidationExecutorAdapter { request, _ in
            await counter.increment()
            let payload: Data?
            if request.command == .record { payload = Data([0x81]) }
            else {
                payload = Data([1]) + parameters(
                    resolution: .portrait1080, frameRate: .fps30).raw
            }
            return transaction(for: request, observedPayload: payload)
        }
        let service = CameraBodyRecordingService(adapter: adapter)
        let start = try CameraBodyRecordingRequest(
            action: .start, expectedSessionID: sessionID,
            peripheralID: peripheralID, generation: 1, execute: true)
        let startResult = try await service.run(start, snapshot: snapshot())
        #expect(startResult.submitted && startResult.acknowledged)
        #expect(startResult.observed && startResult.completed)
        #expect(await counter.read() == 1)

        let format = try CameraBodyRecordingRequest(
            action: .format, expectedSessionID: sessionID,
            peripheralID: peripheralID, generation: 1,
            format: .init(resolution: .portrait1080, frameRate: .fps30),
            execute: false)
        let dryResult = try await service.run(format, snapshot: snapshot())
        #expect(dryResult.dryRun && !dryResult.submitted)
        #expect(await counter.read() == 1)
    }

    @Test func nonVideoAndStaleSessionFailBeforeTheOwnerIsCalled() async throws {
        let counter = CallCounter()
        let service = CameraBodyRecordingService(
            adapter: NativeBodyValidationExecutorAdapter { _, _ in
                await counter.increment()
                return NativeCommandTransactionResult(
                    id: UUID(), command: .record, generation: 1)
            })
        let request = try CameraBodyRecordingRequest(
            action: .stop, expectedSessionID: sessionID,
            peripheralID: peripheralID, generation: 1, execute: true)
        do {
            _ = try await service.run(request,
                snapshot: snapshot(mode: .photo))
            Issue.record("Ordinary Video service accepted a photo-mode baseline")
        } catch let error as CameraBodyRecordingServiceError {
            #expect(error == .videoModeRequired)
        }
        #expect(await counter.read() == 0)

        let stale = try CameraBodyRecordingRequest(
            action: .stop, expectedSessionID: UUID(),
            peripheralID: peripheralID, generation: 1, execute: true)
        do {
            _ = try await service.run(stale, snapshot: snapshot())
            Issue.record("Stale native identity reached the owner")
        } catch let error as CameraBodyRecordingServiceError {
            #expect(error == .invalidRequestIdentity)
        }
        #expect(await counter.read() == 0)
    }

    @Test func failedExecuteRunsOwnerCleanupWithoutRetryingTheCommand() async throws {
        let counter = CallCounter()
        let cleanup = CallCounter()
        let adapter = NativeBodyValidationExecutorAdapter { request, _ in
            await counter.increment()
            return transaction(for: request) // ACK only: no terminal 02/80
        }
        let service = CameraBodyRecordingService(adapter: adapter, cleanup: {
            await cleanup.increment()
            return true
        })
        let request = try CameraBodyRecordingRequest(
            action: .start, expectedSessionID: sessionID,
            peripheralID: peripheralID, generation: 1, execute: true)
        let result = try await service.run(request, snapshot: snapshot())
        #expect(result.submitted && !result.completed)
        #expect(result.cleanupAttempted && result.cleanupSucceeded)
        #expect(await counter.read() == 1)
        #expect(await cleanup.read() == 1)
    }

    private actor CallCounter {
        private(set) var value = 0
        func increment() { value += 1 }
        func read() -> Int { value }
    }
}
