import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 native camera capture coordinators") struct Pocket3NativeCameraCaptureTests {
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

    private func photo(_ frame: CameraPhotoFrame = .sixteenByNine,
                       format: CameraPhotoFormat = .jpeg,
                       countdown: CameraPhotoCountdown = .off,
                       at uptime: TimeInterval,
                       status: NativeCameraSessionStatus) -> CameraPhotoParameters {
        var raw = Data(repeating: 0, count: 13)
        raw[1] = frame.rawValue; raw[3] = format.rawValue; raw[7] = countdown.rawValue
        return CameraPhotoParameters(raw: raw, frameRaw: frame.rawValue,
            formatRaw: format.rawValue, countdownRaw: countdown.rawValue,
            frame: frame, format: format, countdown: countdown)
    }

    private func lapse(output: CameraTimelapseOutput = .video,
                       interval: UInt16 = 50, duration: UInt32 = 300,
                       speed: CameraHyperlapseSpeed? = nil,
                       at uptime: TimeInterval,
                       status: NativeCameraSessionStatus) -> CameraLapseParameters {
        var raw = Data(repeating: 0, count: 21)
        raw[0] = output.rawValue
        raw[1] = UInt8(interval & 0xff); raw[2] = UInt8(interval >> 8)
        raw[5] = UInt8(duration & 0xff); raw[6] = UInt8((duration >> 8) & 0xff)
        raw[7] = UInt8((duration >> 16) & 0xff); raw[8] = UInt8(duration >> 24)
        let rawSpeed = speed?.rawValue ?? 0
        raw[9] = UInt8(rawSpeed & 0xff); raw[10] = UInt8(rawSpeed >> 8)
        raw[11] = UInt8(rawSpeed & 0xff); raw[12] = UInt8(rawSpeed >> 8)
        return CameraLapseParameters(raw: raw, outputRaw: output.rawValue,
            intervalTenths: interval, durationSeconds: duration,
            hyperlapseSpeedRaw: rawSpeed, mirroredHyperlapseSpeedRaw: rawSpeed,
            output: output, hyperlapseSpeed: speed)
    }

    private func motion(_ direction: CameraMotionlapseDirection = .custom,
                        count: UInt8 = 0, status: NativeCameraSessionStatus) -> CameraMotionlapseParameters {
        var raw = Data(repeating: 0, count: 8)
        raw[2] = direction.rawValue; raw[3] = 0; raw[7] = count
        return CameraMotionlapseParameters(raw: raw, directionRaw: direction.rawValue,
            previewActiveRaw: 0, waypointCountRaw: count,
            direction: direction, previewActive: false, waypointCount: count)
    }

    private func panorama(_ type: CameraPanoramaType = .degrees180,
                          format: CameraPanoramaPhotoFormat = .raw,
                          status: NativeCameraSessionStatus) -> CameraPanoramaParameters {
        CameraPanoramaParameters(raw: Data([type.rawValue, format.rawValue, 0]),
            panoramaTypeRaw: type.rawValue, photoFormatRaw: format.rawValue,
            panoramaType: type, photoFormat: format)
    }

    private func baseline(_ status: NativeCameraSessionStatus,
                          mode: Pocket3ShootingMode,
                          at uptime: TimeInterval = 10,
                          recording: UInt8? = 0x01,
                          photo: CameraPhotoParameters? = nil,
                          lapse: CameraLapseParameters? = nil,
                          motion: CameraMotionlapseParameters? = nil,
                          panorama: CameraPanoramaParameters? = nil) -> Pocket3NativeCameraReadback {
        Pocket3NativeCameraReadback(sessionID: status.sessionID!, generation: status.generation,
            receivedUptime: uptime, modeRaw: mode.rawValue,
            recordingStatus: recording.map(Pocket3BodyRecordingStatus.init(rawValue:)),
            photo: photo, lapse: lapse, motionlapse: motion, panorama: panorama)
    }

    private func transaction(for request: NativeCommandTransactionRequest,
                             observedPayload: Data? = nil,
                             end: NativeCommandTransactionEnd = .acknowledged,
                             submittedAt: TimeInterval = 11,
                             observedAt: TimeInterval = 12) -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: request.generation,
            sessionID: request.sessionID, end: end)
        result.sequence = 0x5501; result.submitted = true
        result.submittedUptime = submittedAt
        result.responseReceived = end != .timedOut && end != .cancelled && end != .generationChanged
        result.acknowledged = end == .acknowledged || end == .observed
        result.acknowledgedUptime = result.acknowledged ? observedAt : nil
        result.observedPayload = observedPayload
        result.observed = observedPayload != nil
        result.observedUptime = observedPayload == nil ? nil : observedAt
        result.end = observedPayload == nil ? end : .observed
        result.finishedUptime = observedAt
        return result
    }

    private func statusFrame(mode: Pocket3ShootingMode, recording: UInt8,
                             sequence: UInt16 = 1) -> DUMLFrame {
        var payload = Data(repeating: 0, count: 58)
        payload[0] = recording; payload[57] = mode.rawValue
        return DUMLFrame(source: 1, destination: 2, sequence: sequence,
            flags: 0, commandSet: 2, commandID: 0x80, payload: payload)
    }

    private func propertyFrame(_ property: CameraSettingsProperty,
                               value: Data, sequence: UInt16 = 1) -> DUMLFrame {
        var bytes: [UInt8] = [2, 6, 0, 0,
            1, 0, 0, 0, 0, 0, 0]
        func append16(_ value: Int) {
            bytes += [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
        }
        let name = Array(property.rawValue.utf8)
        append16(name.count + value.count + 10)
        append16(name.count)
        bytes += name; bytes += [0, 0, 0, 0, 0, 0]
        append16(value.count); bytes += value
        return DUMLFrame(source: 0x28, destination: 2, sequence: sequence,
            flags: 0, commandSet: 0, commandID: 0x99, payload: Data(bytes))
    }

    @Test func knownProtocolCommandsEncodeExactPocket3Payloads() throws {
        let mode = Pocket3NativeCameraCommand(.setMode(.timelapse))
        #expect(mode.commandSet == 2 && mode.commandID == 0xE1 && mode.payload == Data([2]))
        #expect(Pocket3NativeCameraCommand(.photoFrame(.oneByOne)).payload == Data([0, 3]))
        #expect(Pocket3NativeCameraCommand(.photoFormat(.jpegAndRaw)).payload == Data([2]))
        #expect(Pocket3NativeCameraCommand(.photoCountdown(.seconds5)).payload == Data([0, 1, 5, 0, 0, 0]))
        #expect(Pocket3NativeCameraCommand(.photoShutter).payload == Data([1]))
        #expect(Pocket3NativeCameraCommand(.panoramaType(.grid3x3)).payload == Data([7]))
        #expect(Pocket3NativeCameraCommand(.panoramaFormat(.raw)).payload == Data([1, 0]))
        #expect(Pocket3NativeCameraCommand(.panoramaShutter).payload == Data([7]))

        let timelapse = try Pocket3TimelapseConfiguration(intervalTenths: 50,
            durationSeconds: 300, output: .jpegAndVideo)
        #expect(Pocket3NativeCameraCommand(.timelapseConfiguration(timelapse)).payload ==
                Data([4, 0, 2, 50, 0, 44, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        #expect(Pocket3NativeCameraCommand(.hyperlapseSpeed(.x5)).payload ==
                Data([0x0B, 0, 0, 5] + Array(repeating: 0, count: 12)))
        let motion = try Pocket3MotionlapseConfiguration(slot: 1,
            intervalTenths: 50, durationSeconds: 300,
            pitchTenths: 3, rollTenths: 2, yawTenths: 1)
        #expect(Pocket3NativeCameraCommand(.motionlapseConfiguration(motion)).payload ==
                Data([5, 5, 0, 50, 0, 44, 1, 0, 0, 1, 0, 2, 0, 3, 0, 0]))
        #expect(Pocket3NativeCameraCommand(.startTimelapse).payload == Data([1]))
        #expect(Pocket3NativeCameraCommand(.stopTimelapse).payload == Data([0]))
    }

    @Test func modeWriterUsesKnownValidatedModesAndMatchingStatus() throws {
        let status = readySession()
        let original = baseline(status, mode: .video)
        var coordinator = try Pocket3NativeCameraCaptureCoordinator(session: status)
        let request = try coordinator.prepare(.setMode(.timelapse), baseline: original, nowUptime: 10)
        #expect(request.command == .cameraCapture)
        #expect(request.frame.commandSet == 2 && request.frame.commandID == 0xE1)
        _ = coordinator.apply(transaction(for: request), nowUptime: 11)
        #expect(coordinator.phase == .awaitingReadback)

        let observed = request.observedPayload(from: statusFrame(mode: .timelapse, recording: 0x01))
        #expect(observed != nil)
        let completed = coordinator.apply(transaction(for: request, observedPayload: observed), nowUptime: 12)
        #expect(completed && coordinator.result?.completed == true)

        var unsupported = try Pocket3NativeCameraCaptureCoordinator(session: status)
        do {
            _ = try unsupported.prepare(.setMode(.photo), baseline: original, nowUptime: 10)
            Issue.record("Only the capture-confirmed Timelapse/Motionlapse mode writer is allowed")
        } catch let error as Pocket3NativeCameraProtocolError {
            #expect(error == .unsupportedModeWrite)
        }
    }

    @Test func photoSettingsRequirePhotoModeAndMatchingNamedPropertyReadback() throws {
        let status = readySession()
        let initialPhoto = photo(at: 10, status: status)
        let original = baseline(status, mode: .photo, photo: initialPhoto)
        var coordinator = try Pocket3NativeCameraCaptureCoordinator(session: status)
        let request = try coordinator.prepare(.photoFrame(.oneByOne), baseline: original, nowUptime: 10)
        #expect(request.frame.commandID == 0x12 && request.frame.payload == Data([0, 3]))
        _ = coordinator.apply(transaction(for: request), nowUptime: 11)
        let selected = photo(.oneByOne, at: 12, status: status)
        let push = propertyFrame(.photoParameters, value: selected.raw)
        let observedPayload = request.observedPayload(from: push)
        #expect(observedPayload != nil)
        let completed = coordinator.apply(transaction(for: request,
            observedPayload: observedPayload), nowUptime: 12)
        #expect(completed)
        #expect(coordinator.result?.readback?.photo?.frame == .oneByOne)

        var wrongMode = try Pocket3NativeCameraCaptureCoordinator(session: status)
        let videoBaseline = baseline(status, mode: .video, photo: nil)
        do {
            _ = try wrongMode.prepare(.photoFormat(.jpegAndRaw), baseline: videoBaseline, nowUptime: 10)
            Issue.record("Photo settings must be mode-aware")
        } catch let error as Pocket3NativeCameraProtocolError {
            #expect(error == .invalidModeCombination)
        }
    }

    @Test func unknownPhotoEnumIsRetainedButCannotCompleteAndKnownValueCanFollow() throws {
        let status = readySession()
        let initial = photo(at: 10, status: status)
        var coordinator = try Pocket3NativeCameraCaptureCoordinator(session: status)
        let request = try coordinator.prepare(.photoFormat(.jpegAndRaw),
            baseline: baseline(status, mode: .photo, photo: initial), nowUptime: 10)
        _ = coordinator.apply(transaction(for: request), nowUptime: 11)

        var unknownRaw = Data(repeating: 0, count: 13)
        unknownRaw[1] = 1; unknownRaw[3] = 0xEE; unknownRaw[7] = 0
        let unknown = Pocket3NativeCameraReadback(sessionID: sessionID,
            generation: status.generation, receivedUptime: 12,
            photo: CameraPhotoParameters(raw: unknownRaw, frameRaw: 1,
                formatRaw: 0xEE, countdownRaw: 0,
                frame: .sixteenByNine, format: nil, countdown: .off))
        let unknownObserved = coordinator.observe(unknown, nowUptime: 12)
        #expect(!unknownObserved)
        #expect(coordinator.result?.readback?.photo?.format == nil)
        #expect(coordinator.phase == Pocket3NativeCameraCaptureCoordinatorPhase.awaitingReadback)

        let matching = photo(.sixteenByNine, format: .jpegAndRaw, at: 13, status: status)
        let known = NativeCameraReadbackFactory.photo(status: status, value: matching, at: 13)
        let knownObserved = coordinator.observe(known, nowUptime: 13)
        #expect(knownObserved)
    }

    @Test func noOpDoesNotCreatePhotoRequestAndPanoramaUsesExactFormatAndShutter() throws {
        let status = readySession()
        let currentPhoto = photo(.oneByOne, at: 20, status: status)
        var noOp = try NativeCoordinatorForPhotoFrame.make(status: status, photo: currentPhoto)
        do {
            _ = try noOp.prepare()
            Issue.record("A photo frame no-op must not create a request")
        } catch let error as Pocket3NativeCameraProtocolError {
            #expect(error == .alreadyAtTarget)
        }
        #expect(noOp.coordinator.phase == .noOp && noOp.coordinator.request == nil)

        let panoBaseline = baseline(status, mode: .panorama,
            at: 30, panorama: panorama(.degrees180, format: .raw, status: status))
        var pano = try Pocket3NativeCameraCaptureCoordinator(session: status)
        let formatRequest = try pano.prepare(.panoramaFormat(.jpeg), baseline: panoBaseline, nowUptime: 30)
        #expect(formatRequest.frame.commandID == 0xE7 && formatRequest.frame.payload == Data([3, 0]))
        _ = pano.apply(transaction(for: formatRequest), nowUptime: 31)
        let selected = panorama(.degrees180, format: .jpeg, status: status)
        let push = propertyFrame(.panoramaParameters, value: selected.raw)
        let observed = formatRequest.observedPayload(from: push)
        let panoCompleted = pano.apply(transaction(for: formatRequest,
            observedPayload: observed, observedAt: 32), nowUptime: 32)
        #expect(panoCompleted)

        var shutter = try Pocket3NativeCameraCaptureCoordinator(session: status)
        let shutterRequest = try shutter.prepare(.panoramaShutter, baseline: panoBaseline, nowUptime: 30)
        #expect(shutterRequest.frame.commandID == 1 && shutterRequest.frame.payload == Data([7]))
        _ = shutter.apply(transaction(for: shutterRequest), nowUptime: 31)
        let statusPayload = shutterRequest.observedPayload(from: statusFrame(mode: .panorama, recording: 1))
        let shutterCompleted = shutter.apply(transaction(for: shutterRequest,
            observedPayload: statusPayload, observedAt: 32), nowUptime: 32)
        #expect(shutterCompleted)
    }

    @Test func timelapseConfigurationAndLifecycleRequireModeAwareFreshReadback() throws {
        let status = readySession()
        let initialLapse = lapse(at: 40, status: status)
        let initial = baseline(status, mode: .timelapse, at: 40,
            recording: 0x01, lapse: initialLapse)
        let target = try Pocket3TimelapseConfiguration(intervalTenths: 100,
            durationSeconds: 600, output: .jpegAndVideo)
        var configuration = try Pocket3NativeCameraCaptureCoordinator(session: status)
        let request = try configuration.prepare(.timelapseConfiguration(target),
            baseline: initial, nowUptime: 40)
        #expect(request.frame.commandID == 0x6C)
        _ = configuration.apply(transaction(for: request), nowUptime: 41)
        let selected = lapse(output: .jpegAndVideo, interval: 100,
            duration: 600, at: 42, status: status)
        let push = propertyFrame(.lapseParameters, value: selected.raw)
        let observed = request.observedPayload(from: push)
        let configurationCompleted = configuration.apply(transaction(for: request,
            observedPayload: observed, observedAt: 42), nowUptime: 42)
        #expect(configurationCompleted)

        var start = try Pocket3NativeCameraCaptureCoordinator(session: status)
        let startRequest = try start.prepare(.startTimelapse, baseline: initial, nowUptime: 40)
        #expect(startRequest.frame.commandID == 2 && startRequest.frame.payload == Data([1]))
        _ = start.apply(transaction(for: startRequest), nowUptime: 41)
        let startStatus = startRequest.observedPayload(from: statusFrame(mode: .timelapse, recording: 0x81))
        let startCompleted = start.apply(transaction(for: startRequest,
            observedPayload: startStatus, observedAt: 42), nowUptime: 42)
        #expect(startCompleted)

        var invalidMode = try NativeCoordinatorForPhotoFrame.make(status: status,
            photo: photo(at: 40, status: status))
        do {
            _ = try invalidMode.coordinator.prepare(.startTimelapse,
                baseline: baseline(status, mode: .photo, at: 40, photo: photo(at: 40, status: status)), nowUptime: 40)
            Issue.record("Timelapse lifecycle must reject Photo mode")
        } catch let error as Pocket3NativeCameraProtocolError {
            #expect(error == .invalidModeCombination)
        }
    }

    @Test func hyperlapseAndMotionlapse02x6CConfigUseMatchingReadbacks() throws {
        let status = readySession()
        let hyperBaseline = baseline(status, mode: .hyperlapse, at: 50,
            lapse: lapse(speed: .x5, at: 50, status: status))
        var hyper = try Pocket3NativeCameraCaptureCoordinator(session: status)
        let hyperRequest = try hyper.prepare(.hyperlapseSpeed(.x10),
            baseline: hyperBaseline, nowUptime: 50)
        #expect(hyperRequest.frame.commandID == 0x6C)
        _ = hyper.apply(transaction(for: hyperRequest), nowUptime: 51)
        let selected = lapse(speed: .x10, at: 52, status: status)
        let hyperObserved = hyperRequest.observedPayload(from:
            propertyFrame(.lapseParameters, value: selected.raw))
        let hyperCompleted = hyper.apply(transaction(for: hyperRequest,
            observedPayload: hyperObserved, observedAt: 52), nowUptime: 52)
        #expect(hyperCompleted)

        let motionBaseline = baseline(status, mode: .motionlapse, at: 60,
            motion: motion(.custom, count: 0, status: status))
        let point = try Pocket3MotionlapseConfiguration(slot: 1,
            intervalTenths: 50, durationSeconds: 300,
            pitchTenths: 3, rollTenths: 2, yawTenths: 1)
        var motionCoordinator = try Pocket3NativeCameraCaptureCoordinator(session: status)
        let motionRequest = try motionCoordinator.prepare(.motionlapseConfiguration(point),
            baseline: motionBaseline, nowUptime: 60)
        #expect(motionRequest.frame.commandID == 0x6C)
        _ = motionCoordinator.apply(transaction(for: motionRequest), nowUptime: 61)
        let updated = motion(.custom, count: 1, status: status)
        let motionObserved = motionRequest.observedPayload(from:
            propertyFrame(.motionlapseParameters, value: updated.raw))
        let motionCompleted = motionCoordinator.apply(transaction(for: motionRequest,
            observedPayload: motionObserved, observedAt: 62), nowUptime: 62)
        #expect(motionCompleted)
    }

    @Test func staleGenerationAndUnknownModeNeverBecomeCompleted() throws {
        let status = readySession()
        let unknown = Pocket3NativeCameraReadback(sessionID: sessionID,
            generation: status.generation, receivedUptime: 70, modeRaw: 0x23,
            recordingStatus: Pocket3BodyRecordingStatus(rawValue: 1))
        var coordinator = try Pocket3NativeCameraCaptureCoordinator(session: status)
        do {
            _ = try coordinator.prepare(.setMode(.timelapse), baseline: unknown, nowUptime: 70)
            Issue.record("Unknown mode readback must not authorize a mode write")
        } catch let error as Pocket3NativeCameraProtocolError {
            #expect(error == .invalidModeCombination)
        }

        let original = baseline(status, mode: .photo, at: 70,
            photo: photo(at: 70, status: status))
        let request = try coordinator.prepare(.photoFormat(.jpegAndRaw),
            baseline: original, nowUptime: 70)
        var stale = transaction(for: request)
        stale.generation += 1
        let staleApplied = coordinator.apply(stale, nowUptime: 71)
        #expect(!staleApplied)
        #expect(coordinator.phase == .generationChanged)
    }

    private struct NativeCoordinatorForPhotoFrame {
        var coordinator: Pocket3NativeCameraCaptureCoordinator
        let status: NativeCameraSessionStatus
        let photo: CameraPhotoParameters

        static func make(status: NativeCameraSessionStatus,
                         photo: CameraPhotoParameters = CameraPhotoParameters(
                            raw: Data(repeating: 0, count: 13), frameRaw: 1,
                            formatRaw: 1, countdownRaw: 0,
                            frame: .sixteenByNine, format: .jpeg, countdown: .off)) throws -> Self {
            let coordinator = try Pocket3NativeCameraCaptureCoordinator(session: status)
            return Self(coordinator: coordinator, status: status, photo: photo)
        }

        mutating func prepare() throws -> NativeCommandTransactionRequest {
            try coordinator.prepare(.photoFrame(.oneByOne),
                baseline: NativeCoordinatorForPhotoFrame.baseline(status: status,
                    photo: photo), nowUptime: 20)
        }

        private static func baseline(status: NativeCameraSessionStatus,
                                     photo: CameraPhotoParameters) -> Pocket3NativeCameraReadback {
            Pocket3NativeCameraReadback(sessionID: status.sessionID!,
                generation: status.generation, receivedUptime: 20,
                modeRaw: Pocket3ShootingMode.photo.rawValue,
                recordingStatus: Pocket3BodyRecordingStatus(rawValue: 1), photo: photo)
        }
    }

    private struct NativeCameraReadbackFactory {
        static func photo(status: NativeCameraSessionStatus,
                          value: CameraPhotoParameters,
                          at uptime: TimeInterval) -> Pocket3NativeCameraReadback {
            Pocket3NativeCameraReadback(sessionID: status.sessionID!,
                generation: status.generation, receivedUptime: uptime,
                photo: value)
        }
    }
}
