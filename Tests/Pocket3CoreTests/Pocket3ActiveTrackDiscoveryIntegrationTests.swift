import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 ActiveTrack discovery lifecycle")
struct Pocket3ActiveTrackDiscoveryIntegrationTests {
    private let session = UUID()
    private let peer = UUID()

    private var binding: ContinuousGimbalBinding {
        Pocket3ActiveTrackObservation.bluetoothBinding(sessionID: session)
    }

    private func floatLE(_ value: Float) -> [UInt8] {
        var bits = value.bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Array($0) }
    }

    private func frame(commandID: UInt8, sequence: UInt16, payload: Data,
                       source: UInt8 = 1, destination: UInt8 = 2,
                       flags: UInt8 = 0, commandSet: UInt8 = 2) -> DUMLFrame {
        DUMLFrame(source: source, destination: destination, sequence: sequence,
            flags: flags, commandSet: commandSet, commandID: commandID,
            payload: payload)
    }

    private func packet(_ frame: DUMLFrame) throws -> ValidatedDUMLPacket {
        let encoded = try DUMLCodec.encode(frame)
        return ValidatedDUMLPacket(frameData: encoded, frame: try DUMLCodec.decode(encoded))
    }

    private func subjectFrame(sequence: UInt16, tag: UInt8 = 0x42) throws -> DUMLFrame {
        let payload = Data([0, 0, 0, 0, 0, tag, 1]) +
            Data(floatLE(0.25) + floatLE(0.75) + floatLE(0.2) + floatLE(0.3))
        return frame(commandID: 0x89, sequence: sequence, payload: payload)
    }

    @Test func rebindClearsOldGenerationAndA6NeverReachesTheStore() throws {
        var store = Pocket3ActiveTrackObservationStore(sessionID: session,
            peripheralID: peer, binding: binding)
        let idle = try packet(frame(commandID: 0xA5, sequence: 1,
            payload: Data([0, 0, 0, 0])))
        let accepted = store.receive(idle, sessionID: session, peripheralID: peer,
            binding: binding, paired: true, hostReceivedAt: Date(timeIntervalSince1970: 100),
            uptime: 10)
        #expect(accepted && store.observations.count == 1)

        let a6 = try packet(frame(commandID: 0xA6, sequence: 2,
            payload: Data(repeating: 0, count: 21), source: 2, destination: 1,
            flags: 0x40))
        let acceptedA6 = store.receive(a6, sessionID: session, peripheralID: peer,
            binding: binding, paired: true, hostReceivedAt: Date(timeIntervalSince1970: 101),
            uptime: 11)
        #expect(!acceptedA6)
        #expect(store.observations.count == 1)

        let nextSession = UUID()
        let nextBinding = Pocket3ActiveTrackObservation.bluetoothBinding(
            sessionID: nextSession, generation: 1)
        let rebound = store.bind(sessionID: nextSession, peripheralID: peer,
            binding: nextBinding)
        #expect(rebound)
        #expect(store.observations.isEmpty && store.latestObservation == nil)
        let staleSession = store.receive(idle, sessionID: session, peripheralID: peer,
            binding: binding, paired: true, hostReceivedAt: Date(timeIntervalSince1970: 102),
            uptime: 12)
        #expect(!staleSession)

        let current = try packet(try subjectFrame(sequence: 1))
        let acceptedCurrent = store.receive(current, sessionID: nextSession, peripheralID: peer,
            binding: nextBinding, paired: true, hostReceivedAt: Date(timeIntervalSince1970: 103),
            uptime: 13)
        #expect(acceptedCurrent)
        #expect(store.latest(sessionID: nextSession, peripheralID: peer,
            binding: nextBinding, paired: true, nowUptime: 13)?.generation == 1)
    }

    @Test func statusPublishesFreshTypedCurrentAndBoundedHistoryAndSurvivesJSON() throws {
        var store = Pocket3ActiveTrackObservationStore(sessionID: session,
            peripheralID: peer, binding: binding)
        let idle = try packet(frame(commandID: 0xA5, sequence: 1,
            payload: Data([0, 0, 0, 0])))
        let subject = try packet(try subjectFrame(sequence: 1))
        let acceptedIdle = store.receive(idle, sessionID: session, peripheralID: peer,
            binding: binding, paired: true, hostReceivedAt: Date(timeIntervalSince1970: 200),
            uptime: 20)
        let acceptedSubject = store.receive(subject, sessionID: session, peripheralID: peer,
            binding: binding, paired: true, hostReceivedAt: Date(timeIntervalSince1970: 201),
            uptime: 21)
        #expect(acceptedIdle && acceptedSubject)

        var status = BluetoothDiscoveryStatus(phase: .gattPaired,
            sessionID: session, candidates: [], selectedPeripheralID: peer,
            issueCode: nil, identityVerification: "verified",
            authentication: "protocol_pair_confirmed", fff4NotificationEnabled: true,
            fff5NotificationEnabled: true, fff4Properties: nil, fff5Properties: nil,
            receivedFrames: 2, fragments: [:],
            pairing: BluetoothPairingStatus(phase: .paired, peerReportedPaired: true,
                credentialsAvailable: false, issueCode: nil))
        let freshHistory = store.snapshot(sessionID: session, peripheralID: peer,
            binding: binding, paired: true, nowUptime: 22)
        status.activeTrackHistory = freshHistory
        status.activeTrackObservation = freshHistory.last
        #expect(status.activeTrackHistoryCount == 2)
        #expect(status.activeTrackObservations == freshHistory)

        let context = status.cameraBodyReadOnlyContext(nowUptime: 22)
        #expect(context.paired && context.activeTrackObservation == freshHistory.last)
        #expect(context.activeTrackObservation?.state.isSubjectBox == true)

        let decoded = try JSONDecoder().decode(BluetoothDiscoveryStatus.self,
            from: JSONEncoder().encode(status))
        #expect(decoded.activeTrackObservation == status.activeTrackObservation)
        #expect(decoded.activeTrackHistory == freshHistory)

        // The typed status history is age-filtered by the owner before
        // publication; an old observation cannot leak back through context.
        status.activeTrackHistory = store.snapshot(sessionID: session,
            peripheralID: peer, binding: binding, paired: true, nowUptime: 27)
        status.activeTrackObservation = status.activeTrackHistory.last
        #expect(status.activeTrackHistory.isEmpty &&
            status.cameraBodyReadOnlyContext(nowUptime: 27).activeTrackObservation == nil)
    }

    @Test func olderStatusJSONDefaultsNewTypedFieldsToEmpty() throws {
        let status = BluetoothDiscoveryStatus(phase: .idle, sessionID: session,
            candidates: [], selectedPeripheralID: nil, issueCode: nil,
            identityVerification: "fixture", authentication: "not_performed",
            fff4NotificationEnabled: false, fff5NotificationEnabled: false,
            fff4Properties: nil, fff5Properties: nil, receivedFrames: 0,
            fragments: [:])
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(status)) as? [String: Any])
        object.removeValue(forKey: "activeTrackObservation")
        object.removeValue(forKey: "activeTrackHistory")
        let decoded = try JSONDecoder().decode(BluetoothDiscoveryStatus.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.activeTrackObservation == nil && decoded.activeTrackHistory.isEmpty)
    }
}
