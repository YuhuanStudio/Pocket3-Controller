import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 ActiveTrack read-only observations")
struct Pocket3ActiveTrackObservationTests {
    private let session = UUID()
    private let peer = UUID()
    private var binding: ContinuousGimbalBinding {
        ContinuousGimbalBinding(sessionID: "ble:\(session.uuidString)", generation: 7)
    }

    private func floatLE(_ value: Float) -> [UInt8] {
        var bits = value.bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Array($0) }
    }

    private func boxPayload(_ box: Pocket3TrackingBox) -> Data {
        Data(floatLE(Float(box.centerX)) + floatLE(Float(box.centerY)) +
             floatLE(Float(box.width)) + floatLE(Float(box.height)))
    }

    private func frame(commandID: UInt8, payload: Data, sequence: UInt16 = 1,
                       flags: UInt8 = 0, source: UInt8 = 1,
                       destination: UInt8 = 2, commandSet: UInt8 = 2) -> DUMLFrame {
        DUMLFrame(source: source, destination: destination, sequence: sequence,
                  flags: flags, commandSet: commandSet, commandID: commandID,
                  payload: payload)
    }

    private func packet(_ frame: DUMLFrame) throws -> ValidatedDUMLPacket {
        let encoded = try DUMLCodec.encode(frame)
        return ValidatedDUMLPacket(frameData: encoded, frame: try DUMLCodec.decode(encoded))
    }

    private func a5(_ payload: Data, sequence: UInt16 = 1,
                    flags: UInt8 = 0) -> DUMLFrame {
        frame(commandID: 0xA5, payload: payload, sequence: sequence, flags: flags)
    }

    private func a89(_ box: Pocket3TrackingBox, sequence: UInt16 = 1,
                     tag: UInt8 = 0x19, reserved: UInt8 = 0x01) -> DUMLFrame {
        frame(commandID: 0x89,
              payload: Data([0, 0, 0, 0, 0, tag, reserved]) + boxPayload(box),
              sequence: sequence)
    }

    @Test func decoderMapsIdleLockedAndSubjectBoxWithoutInferringOrientation() throws {
        let box = try Pocket3TrackingBox(centerX: 0.31, centerY: 0.67,
                                         width: 0.22, height: 0.34)
        let idle = try #require(Pocket3ActiveTrackObservation(
            frame: a5(Data([0, 0, 0, 0])), sessionID: session,
            peripheralID: peer, binding: binding, receivedAt: Date(timeIntervalSince1970: 20),
            receivedUptime: 10))
        #expect(idle.state == .idle && idle.statusRaw == 0)
        #expect(idle.generation == 7 && idle.box == nil)

        let locked = try #require(Pocket3ActiveTrackObservation(
            frame: a5(Data([0, 1, 0, 0]) + boxPayload(box), flags: 0xC0),
            sessionID: session, peripheralID: peer, binding: binding,
            receivedAt: Date(timeIntervalSince1970: 21), receivedUptime: 11))
        #expect(locked.state == .locked(box: box))
        #expect(locked.box == box && locked.statusRaw == 1)

        let subject = try #require(Pocket3ActiveTrackObservation(
            frame: a89(box, sequence: 4, tag: 0x42, reserved: 0xFE),
            sessionID: session, peripheralID: peer, binding: binding,
            receivedAt: Date(timeIntervalSince1970: 22), receivedUptime: 12))
        #expect(subject.state == .subjectBox(box))
        #expect(subject.tagRaw == 0x42 && subject.reservedRaw == 0xFE)
        #expect(subject.payloadRaw.count == 23)
        // The four values are exposed in the wire's order and no axis flip or
        // coordinate-system claim is made by this model.
        #expect(subject.box?.centerX == box.centerX)
        #expect(subject.box?.centerY == box.centerY)
    }

    @Test func unknownAndMalformedValuesRetainTheWholeRawPayloadAndRejectA6() throws {
        let unknown = Data([0, 0xFE, 0, 0, 0xA5, 0x00])
        let observation = try #require(Pocket3ActiveTrackObservation(
            frame: a5(unknown, sequence: 5), sessionID: session, peripheralID: peer,
            binding: binding, receivedAt: Date(timeIntervalSince1970: 30), receivedUptime: 2))
        #expect(observation.state == .unknown(commandID: 0xA5, raw: unknown))
        #expect(observation.statusRaw == 0xFE && observation.payloadRaw == unknown)

        let malformedSubject = Data([0, 0, 0, 0, 0, 0x42, 0x01])
        let malformed = try #require(Pocket3ActiveTrackObservation(
            frame: frame(commandID: 0x89, payload: malformedSubject, sequence: 6),
            sessionID: session, peripheralID: peer, binding: binding,
            receivedAt: Date(timeIntervalSince1970: 31), receivedUptime: 3))
        #expect(malformed.state == .unknown(commandID: 0x89, raw: malformedSubject))
        #expect(malformed.tagRaw == 0x42 && malformed.reservedRaw == 0x01)

        let malformedLocked = try #require(Pocket3ActiveTrackObservation(
            frame: a5(Data([0, 1, 0, 0, 0xFF]), sequence: 7), sessionID: session,
            peripheralID: peer, binding: binding, receivedAt: Date(timeIntervalSince1970: 32),
            receivedUptime: 4))
        #expect(malformedLocked.state == .unknown(commandID: 0xA5,
                                                  raw: Data([0, 1, 0, 0, 0xFF])))

        #expect(Pocket3ActiveTrackObservation(
            frame: frame(commandID: 0xA6, payload: Data(repeating: 0, count: 21),
                         flags: 0x40, source: 2, destination: 1, commandSet: 2),
            sessionID: session, peripheralID: peer, binding: binding,
            receivedAt: Date(), receivedUptime: 5) == nil)
        #expect(Pocket3ActiveTrackObservation(
            frame: frame(commandID: 0x89, payload: Data([0]), source: 2,
                         destination: 1), sessionID: session, peripheralID: peer,
            binding: binding, receivedAt: Date(), receivedUptime: 5) == nil)
    }

    @Test func freshnessAndCodableRoundTripRequireExactIdentityAndGeneration() throws {
        let box = try Pocket3TrackingBox(centerX: 0.5, centerY: 0.5,
                                         width: 0.25, height: 0.25)
        let value = try #require(Pocket3ActiveTrackObservation(
            frame: a89(box), sessionID: session, peripheralID: peer, binding: binding,
            receivedAt: Date(timeIntervalSince1970: 40), receivedUptime: 10))
        #expect(value.isFresh(nowUptime: 10) && value.isFresh(nowUptime: 15))
        #expect(!value.isFresh(nowUptime: 15.001) && !value.isFresh(nowUptime: 9.9))
        #expect(value.isFresh(sessionID: session, peripheralID: peer,
                             binding: binding, paired: true, nowUptime: 12))
        #expect(!value.isFresh(sessionID: session, peripheralID: peer,
                               binding: ContinuousGimbalBinding(sessionID: binding.sessionID,
                                                                generation: 8), paired: true,
                               nowUptime: 12))
        #expect(!value.isFresh(sessionID: UUID(), peripheralID: peer,
                               binding: binding, paired: true, nowUptime: 12))
        #expect(!value.isFresh(sessionID: session, peripheralID: nil,
                               binding: binding, paired: true, nowUptime: 12))
        #expect(!value.isFresh(sessionID: session, peripheralID: peer,
                               binding: binding, paired: false, nowUptime: 12))

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Pocket3ActiveTrackObservation.self, from: data)
        #expect(decoded == value)
    }

    @Test func storeRejectsForeignGenerationsAndReplaysWhilePublishingFreshHistory() throws {
        let firstBinding = binding
        var store = Pocket3ActiveTrackObservationStore(sessionID: session,
            peripheralID: peer, binding: firstBinding)
        #expect(store.receive(try packet(a5(Data([0, 0, 0, 0]), sequence: 10)),
            sessionID: session, peripheralID: peer, binding: firstBinding, paired: true,
            hostReceivedAt: Date(timeIntervalSince1970: 50), uptime: 10))
        #expect(store.latest(sessionID: session, peripheralID: peer, binding: firstBinding,
                             paired: true, nowUptime: 12)?.state == .idle)

        // A new sequence carrying the exact same payload is an unchanged
        // replay and does not refresh freshness or history.
        #expect(!store.receive(try packet(a5(Data([0, 0, 0, 0]), sequence: 11)),
            sessionID: session, peripheralID: peer, binding: firstBinding, paired: true,
            hostReceivedAt: Date(timeIntervalSince1970: 51), uptime: 11))
        #expect(store.observations.count == 1)
        #expect(store.latest(sessionID: session, peripheralID: peer, binding: firstBinding,
                             paired: true, nowUptime: 15.001) == nil)

        let wrongGeneration = ContinuousGimbalBinding(sessionID: firstBinding.sessionID,
                                                       generation: 8)
        #expect(!store.receive(try packet(a5(Data([0, 1, 0, 0]), sequence: 12)),
            sessionID: session, peripheralID: peer, binding: wrongGeneration, paired: true,
            hostReceivedAt: Date(timeIntervalSince1970: 52), uptime: 12))
        #expect(!store.receive(try packet(a5(Data([0, 1, 0, 0]), sequence: 13)),
            sessionID: UUID(), peripheralID: peer, binding: firstBinding, paired: true,
            hostReceivedAt: Date(timeIntervalSince1970: 53), uptime: 13))
        #expect(!store.receive(try packet(a5(Data([0, 1, 0, 0]), sequence: 14)),
            sessionID: session, peripheralID: peer, binding: firstBinding, paired: false,
            hostReceivedAt: Date(timeIntervalSince1970: 54), uptime: 14))

        let secondBinding = ContinuousGimbalBinding(sessionID: firstBinding.sessionID,
                                                     generation: 9)
        _ = store.bind(sessionID: session, peripheralID: peer, binding: secondBinding)
        let box = try Pocket3TrackingBox(centerX: 0.3, centerY: 0.6,
                                         width: 0.2, height: 0.25)
        #expect(store.receive(try packet(a89(box, sequence: 1)), sessionID: session,
            peripheralID: peer, binding: secondBinding, paired: true,
            hostReceivedAt: Date(timeIntervalSince1970: 60), uptime: 20))
        #expect(store.latest(sessionID: session, peripheralID: peer, binding: secondBinding,
                             paired: true, nowUptime: 20)?.generation == 9)
        #expect(store.observations.count == 1)
    }

    @Test func recorderAndCandidateSnapshotsExposeTypedA5A89ButNeverA6() throws {
        let box = try Pocket3TrackingBox(centerX: 0.25, centerY: 0.75,
                                         width: 0.18, height: 0.24)
        var recorder = try BluetoothCameraEventRecorder(sessionID: session,
            peripheralID: peer, startedUptime: 1)
        let poll = try packet(a5(Data([0, 0, 0, 0]), sequence: 1))
        let subject = try packet(a89(box, sequence: 1))
        let writeLike = try packet(frame(commandID: 0xA6,
            payload: Data(repeating: 0, count: 21), sequence: 1))
        let acceptedPoll = recorder.receive(poll, sessionID: session, peripheralID: peer,
                                            paired: true, hostReceivedAt: Date(), uptime: 1.1)
        let acceptedSubject = recorder.receive(subject, sessionID: session, peripheralID: peer,
                                               paired: true, hostReceivedAt: Date(), uptime: 1.2)
        let acceptedWriteLike = recorder.receive(writeLike, sessionID: session, peripheralID: peer,
                                                 paired: true, hostReceivedAt: Date(), uptime: 1.3)
        #expect(acceptedPoll && acceptedSubject && acceptedWriteLike)
        let recording = recorder.finish(at: 2, reason: .finishedEarly)
        let typed = recording.activeTrackObservations(binding: binding)
        #expect(typed.count == 2)
        #expect(typed.map(\.commandID) == [0xA5, 0x89])
        #expect(typed[0].state == .idle && typed[1].state == .subjectBox(box))
        #expect(recording.latestActiveTrackObservation(binding: binding)?.commandID == 0x89)

        var store = Pocket3ActiveTrackObservationStore(sessionID: session,
            peripheralID: peer, binding: binding)
        for event in recording.events {
            _ = store.ingest(event, binding: binding)
        }
        #expect(store.latest(sessionID: session, peripheralID: peer, binding: binding,
                             paired: true, nowUptime: 2)?.commandID == 0x89)
        #expect(recording.events.contains { $0.commandID == 0xA6 &&
            $0.activeTrackObservation == nil })
    }

    @Test func cameraBodyStatusContextFencesTypedTrackToCurrentPairAndCapabilities() throws {
        let box = try Pocket3TrackingBox(centerX: 0.4, centerY: 0.4,
                                         width: 0.2, height: 0.2)
        let trackFrame = a89(box, sequence: 3)
        let candidate = try #require(Pocket3TrackingCandidateParser.parse(
            trackFrame, sessionID: session, peripheralID: peer,
            receivedAt: Date(timeIntervalSince1970: 70), receivedUptime: 10))
        let format = CameraVideoFormatCapabilities(raw: Data([1, 4, 0, 1, 0x42, 0x03, 0]),
            versionRaw: 1, innerLengthRaw: 4, entryCountRaw: 1, entries: [])
        let setting = CameraSettingsObservation(property: .videoFormatCapabilities,
            value: nil, readOnlyValue: .videoFormatCapabilities(
                CameraOpaqueCapabilityReadback(raw: format.raw)), exposureMode: nil,
            transactionID: 1,
            binding: Pocket3ActiveTrackObservation.bluetoothBinding(sessionID: session),
            receivedUptime: 10)
        let cameraStatus = Pocket3CameraStatusObservation(sessionID: session,
            peripheralID: peer, receivedAt: Date(timeIntervalSince1970: 70),
            receivedUptime: 10, statusByte: 0x81, recording: true,
            transitioning: false, videoLike: true, shootingModeRaw: 1,
            shootingMode: .video, storageTotalMiB: nil, storageFreeMiB: nil,
            remainingRecordSeconds: nil, elapsedRecordSeconds: nil)
        let pairing = BluetoothPairingStatus(phase: .paired,
            peerReportedPaired: true, credentialsAvailable: false, issueCode: nil)
        let status = BluetoothDiscoveryStatus(phase: .gattPaired, sessionID: session,
            candidates: [], selectedPeripheralID: peer, issueCode: nil,
            identityVerification: "verified", authentication: "protocol_pair_confirmed",
            fff4NotificationEnabled: true, fff5NotificationEnabled: true,
            fff4Properties: nil, fff5Properties: nil, receivedFrames: 1,
            fragments: [:], pairing: pairing, cameraSettingsObservations: [setting],
            cameraStatus: cameraStatus, trackingCandidates: [candidate])

        let context = status.cameraBodyReadOnlyContext(nowUptime: 12)
        #expect(context.paired && context.peripheralID == peer)
        #expect(context.cameraStatus?.recordingStatus.lifecycle == .recording)
        #expect(context.bodyRecordingCapabilities?.raw == format.raw)
        #expect(context.activeTrackObservation?.state == .subjectBox(box))
        #expect(status.activeTrackObservation(nowUptime: 16) == nil)
        #expect(status.cameraBodyReadOnlyContext(nowUptime: 12,
            paired: false).activeTrackObservation == nil)
    }
}
