import Foundation
import Testing
@testable import Pocket3Core

private final class NativeCaptureCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("Native camera capture validation service")
struct NativeCameraCaptureValidationTests {
    private let sessionID = UUID()
    private let peerID = UUID()

    private func readySession() -> NativeCameraSessionStatus {
        var session = NativeCameraSession()
        let generation = session.begin(sessionID: sessionID, peerID: peerID)
        _ = session.markPaired(generation: generation)
        _ = session.markCredentialsAvailable(generation: generation)
        _ = session.observeDatalink(.connecting, generation: generation)
        _ = session.observeDatalink(.ready, generation: generation)
        return session.status
    }

    private func photoRaw(frame: CameraPhotoFrame = .sixteenByNine,
                          format: CameraPhotoFormat = .jpeg,
                          countdown: CameraPhotoCountdown = .off) -> Data {
        var raw = Data(repeating: 0, count: 13)
        raw[1] = frame.rawValue
        raw[3] = format.rawValue
        raw[7] = countdown.rawValue
        return raw
    }

    private func photo(_ raw: Data) -> CameraPhotoParameters {
        CameraPhotoParameters(raw: raw, frameRaw: raw[1], formatRaw: raw[3],
            countdownRaw: raw[7], frame: CameraPhotoFrame(rawValue: raw[1]),
            format: CameraPhotoFormat(rawValue: raw[3]),
            countdown: CameraPhotoCountdown(rawValue: raw[7]))
    }

    private func snapshot(_ session: NativeCameraSessionStatus,
                          photo: CameraPhotoParameters? = nil,
                          status: Pocket3BodyRecordingStatus = .init(rawValue: 0x01),
                          mode: Pocket3ShootingMode = .photo,
                          now: TimeInterval = 10) -> NativeCameraCaptureValidationSnapshot {
        NativeCameraCaptureValidationSnapshot(session: session,
            baseline: Pocket3NativeCameraReadback(
                sessionID: session.sessionID!, generation: session.generation,
                receivedUptime: now, modeRaw: mode.rawValue,
                recordingStatus: status, photo: photo), nowUptime: now)
    }

    private func transaction(for request: NativeCommandTransactionRequest,
                             observedPayload: Data? = nil,
                             observedUptime: TimeInterval? = nil,
                             end: NativeCommandTransactionEnd = .acknowledged)
        -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: request.generation,
            sessionID: request.sessionID, end: end)
        result.sequence = 0x5001
        result.submitted = true
        result.submittedUptime = 11
        result.responseReceived = true
        result.acknowledged = true
        result.acknowledgedUptime = 11.01
        result.observedPayload = observedPayload
        result.observed = observedPayload != nil
        result.observedUptime = observedUptime
        result.finishedUptime = observedUptime ?? 11.1
        return result
    }

    private func photoPropertyFrame(_ raw: Data) -> DUMLFrame {
        let name = Array(CameraSettingsProperty.photoParameters.rawValue.utf8)
        var bytes: [UInt8] = [2, 6, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        func append16(_ value: Int) {
            bytes += [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
        }
        append16(name.count + raw.count + 10)
        append16(name.count)
        bytes += name
        bytes += [0, 0, 0, 0, 0, 0]
        append16(raw.count)
        bytes += raw
        return DUMLFrame(source: 0x28, destination: 0x02, sequence: 9,
            flags: 0, commandSet: 0, commandID: 0x99, payload: Data(bytes))
    }

    @Test func requestParsesStrictCLIAndRoundTripsTypedTarget() throws {
        let request = try NativeCameraCaptureValidationRequest(cliArguments: [
            "--action", "photo-format", "--session", sessionID.uuidString,
            "--peripheral", peerID.uuidString, "--generation", "3",
            "--value", "jpeg+raw"])
        #expect(request.action == .photoFormat)
        #expect(request.target == .photoFormat(.jpegAndRaw))
        #expect(!request.execute)

        let decoded = try JSONDecoder().decode(
            NativeCameraCaptureValidationRequest.self,
            from: JSONEncoder().encode(request))
        #expect(decoded == request)

        let configuration = try Pocket3TimelapseConfiguration(
            intervalTenths: 50, durationSeconds: 120, output: .jpegAndVideo)
        let configRequest = try NativeCameraCaptureValidationRequest(
            action: .timelapseConfiguration, expectedSessionID: sessionID,
            peripheralID: peerID, generation: 3,
            target: .timelapseConfiguration(configuration))
        let configDecoded = try JSONDecoder().decode(
            NativeCameraCaptureValidationRequest.self,
            from: JSONEncoder().encode(configRequest))
        #expect(configDecoded == configRequest)
    }

    @Test func dryRunPreparesOneRequestWithoutCallingExecutor() async throws {
        let session = readySession()
        let baselinePhoto = photo(photoRaw())
        let request = try NativeCameraCaptureValidationRequest(
            action: .photoFormat, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            target: .photoFormat(.jpegAndRaw))
        let counter = NativeCaptureCallCounter()
        let adapter = NativeCameraCaptureValidationExecutorAdapter { _, _ in
            counter.increment()
            throw CancellationError()
        }
        let result = try await NativeCameraCaptureValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session, photo: baselinePhoto))
        #expect(result.dryRun && !result.executeRequested)
        #expect(result.request?.command == .cameraCapture)
        #expect(result.request?.frame.commandSet == 0x02)
        #expect(result.request?.frame.commandID == 0x16)
        #expect(!result.submitted && !result.completed && counter.count == 0)
        #expect(result.sideEffect == .none)
    }

    @Test func executeCallsTheSingleOwnerOnceAndNeedsMatchingPropertyReadback() async throws {
        let session = readySession()
        let baselinePhoto = photo(photoRaw())
        let request = try NativeCameraCaptureValidationRequest(
            action: .photoFormat, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            target: .photoFormat(.jpegAndRaw), execute: true)
        let counter = NativeCaptureCallCounter()
        let adapter = NativeCameraCaptureValidationExecutorAdapter { request, _ in
            counter.increment()
            let frame = self.photoPropertyFrame(self.photoRaw(format: .jpegAndRaw))
            let observed = request.observationHandler()!(frame)
            return self.transaction(for: request, observedPayload: observed,
                                    observedUptime: 12, end: .observed)
        }
        let result = try await NativeCameraCaptureValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session, photo: baselinePhoto))
        #expect(counter.count == 1)
        #expect(result.executeRequested && result.submitted && result.acknowledged)
        #expect(result.observed && result.completed)
        #expect(result.phase == .completed)
        #expect(result.capture?.readback?.photo?.format == .jpegAndRaw)
    }

    @Test func acknowledgementAloneAndCancellationKeepPartialEvidenceWithoutRetry() async throws {
        let session = readySession()
        let baselinePhoto = photo(photoRaw())
        let request = try NativeCameraCaptureValidationRequest(
            action: .photoShutter, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            target: .photoShutter, execute: true)
        let ackCounter = NativeCaptureCallCounter()
        let ackAdapter = NativeCameraCaptureValidationExecutorAdapter { request, _ in
            ackCounter.increment()
            return self.transaction(for: request)
        }
        let ackResult = try await NativeCameraCaptureValidationService(adapter: ackAdapter).run(
            request, snapshot: snapshot(session, photo: baselinePhoto))
        #expect(ackCounter.count == 1 && ackResult.acknowledged)
        #expect(!ackResult.observed && !ackResult.completed)
        #expect(ackResult.phase == Pocket3NativeCameraCaptureCoordinatorPhase.awaitingReadback)
        #expect(ackResult.sideEffect == NativeCameraCaptureSideEffect.shutterMayCreateMedia)

        let cancelCounter = NativeCaptureCallCounter()
        let cancelAdapter = NativeCameraCaptureValidationExecutorAdapter { _, _ in
            cancelCounter.increment()
            throw CancellationError()
        }
        let cancelResult = try await NativeCameraCaptureValidationService(adapter: cancelAdapter).run(
            request, snapshot: snapshot(session, photo: baselinePhoto))
        #expect(cancelCounter.count == 1 && cancelResult.phase == Pocket3NativeCameraCaptureCoordinatorPhase.cancelled)
        #expect(!cancelResult.completed)
    }

    @Test func recordingSideEffectsAreExplicitAndMissingExecutorNeverSends() async throws {
        let session = readySession()
        let baseline = snapshot(session, photo: photo(photoRaw()),
                                mode: .timelapse)
        let request = try NativeCameraCaptureValidationRequest(
            action: .startTimelapse, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            target: .startTimelapse, execute: true)
        let result = try await NativeCameraCaptureValidationService().run(
            request, snapshot: baseline)
        #expect(result.sideEffect == .recordingStartMayCreateMedia)
        #expect(!result.submitted && !result.completed)
        #expect(result.failureCode == "native_camera_capture_executor_unavailable")
    }

    @Test func foreignGenerationAndStaleBaselineAreRejectedBeforeExecutor() async throws {
        let session = readySession()
        let request = try NativeCameraCaptureValidationRequest(
            action: .photoFormat, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            target: .photoFormat(.jpegAndRaw), execute: true)
        let counter = NativeCaptureCallCounter()
        let adapter = NativeCameraCaptureValidationExecutorAdapter { _, _ in
            counter.increment()
            throw CancellationError()
        }
        let foreignSession = NativeCameraSessionStatus(
            state: .commandReady, generation: session.generation + 1,
            sessionID: sessionID, peerID: peerID)
        await #expect(throws: NativeCameraCaptureValidationError.invalidRequestIdentity) {
            _ = try await NativeCameraCaptureValidationService(adapter: adapter).run(
                request, snapshot: snapshot(foreignSession, photo: photo(photoRaw())))
        }
        #expect(counter.count == 0)

        let stale = NativeCameraCaptureValidationSnapshot(session: session,
            baseline: Pocket3NativeCameraReadback(
                sessionID: sessionID, generation: session.generation,
                receivedUptime: 1, modeRaw: Pocket3ShootingMode.photo.rawValue,
                recordingStatus: .init(rawValue: 0x01), photo: photo(photoRaw())),
            nowUptime: 10)
        await #expect(throws: NativeCameraCaptureValidationError.invalidBaseline) {
            _ = try await NativeCameraCaptureValidationService(adapter: adapter).run(
                request, snapshot: stale)
        }
        #expect(counter.count == 0)
    }

    @Test func modeAwareGateRejectsPhotoWriteOutsidePhotoMode() async throws {
        let session = readySession()
        let request = try NativeCameraCaptureValidationRequest(
            action: .photoFormat, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            target: .photoFormat(.jpegAndRaw), execute: true)
        let counter = NativeCaptureCallCounter()
        let adapter = NativeCameraCaptureValidationExecutorAdapter { _, _ in
            counter.increment()
            throw CancellationError()
        }
        await #expect(throws: NativeCameraCaptureValidationError.invalidValue) {
            _ = try await NativeCameraCaptureValidationService(adapter: adapter).run(
                request, snapshot: snapshot(session, photo: photo(photoRaw()), mode: .video))
        }
        #expect(counter.count == 0)
    }
}
