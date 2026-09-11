import Foundation
import Testing
@testable import Pocket3Core

@Suite struct BluetoothCameraSettingsStoreTests {
    private let session = UUID(), peer = UUID()
    private func value(_ property: CameraSettingsProperty) -> Data {
        switch property {
        case .lensState: return Data([0xb2]) + Data(repeating: 0, count: 46)
        case .imageEffect: return Data(repeating: 0, count: 16)
        case .exposure:
            var bytes = Data(repeating: 0, count: 44); bytes[6] = 0x10; bytes[7] = 1; return bytes
        case .videoParameters: return Data(repeating: 0, count: 9)
        case .sensorAspectRatio: return Data([0])
        case .photoParameters: return Data(repeating: 0, count: 13)
        case .lapseParameters: return Data(repeating: 0, count: 21)
        case .motionlapseParameters: return Data(repeating: 0, count: 8)
        case .panoramaParameters: return Data(repeating: 0, count: 3)
        }
    }
    private func packet(_ property: CameraSettingsProperty = .lensState, sequence: UInt16 = 1, transaction: UInt32 = 1,
                        value supplied: Data? = nil, name suppliedName: String? = nil,
                        source: UInt8 = 0x28, destination: UInt8 = 2, flags: UInt8 = 0) throws -> ValidatedDUMLPacket {
        let name = suppliedName ?? property.rawValue, contents = supplied ?? value(property)
        var bytes: [UInt8] = [2,6,0,0]
        bytes += [UInt8(truncatingIfNeeded: transaction), UInt8(truncatingIfNeeded: transaction >> 8),
                  UInt8(truncatingIfNeeded: transaction >> 16), UInt8(truncatingIfNeeded: transaction >> 24),0,0,0]
        func append16(_ number: Int) { bytes += [UInt8(number & 255), UInt8((number >> 8) & 255)] }
        append16(name.utf8.count + contents.count + 10); append16(name.utf8.count)
        bytes.append(contentsOf: name.utf8); bytes += [0,0,0,0,0,0]; append16(contents.count)
        bytes.append(contentsOf: contents)
        let frame = DUMLFrame(source: source, destination: destination, sequence: sequence, flags: flags,
                              commandSet: 0, commandID: 0x99, payload: Data(bytes))
        var decoder = DUMLFragmentDecoder()
        let packets = try decoder.append(DUMLCodec.encode(frame), at: 0)
        return try #require(packets.first)
    }
    private func store() -> BluetoothCameraSettingsStore {
        var store = BluetoothCameraSettingsStore(); store.bind(sessionID: session, peripheralID: peer); return store
    }
    private func receive(_ store: inout BluetoothCameraSettingsStore, _ packet: ValidatedDUMLPacket,
                         at time: TimeInterval, paired: Bool = true) -> Bool {
        store.receive(packet, sessionID: session, peripheralID: peer, paired: paired, uptime: time)
    }
    private func snapshot(_ store: BluetoothCameraSettingsStore, at time: TimeInterval, paired: Bool = true) -> [CameraSettingsObservation] {
        store.snapshot(sessionID: session, peripheralID: peer, paired: paired, nowUptime: time)
    }

    @Test func threePairedPropertiesUseExistingDecodersAndBLEBindingOnly() throws {
        var store = store()
        for (index, property) in [CameraSettingsProperty.lensState, .imageEffect, .exposure].enumerated() {
            let accepted = receive(&store, try packet(property, sequence: UInt16(500 - index * 200)), at: 100 + Double(index) * 0.1)
            #expect(accepted)
        }
        let observations = snapshot(store, at: 100.2)
        #expect(observations.map(\.property) == [.lensState,.imageEffect,.exposure])
        #expect(observations[0].value == .focus(.continuous))
        #expect(observations[1].value == .whiteBalance(.automatic))
        #expect(observations[2].value == .autoEV(thirdStops: 0) && observations[2].exposureMode == .automatic)
        #expect(observations.allSatisfy { $0.binding == .init(sessionID: "ble:\(session.uuidString)", generation: 0) })
        #expect(snapshot(store, at: 100.2, paired: false).isEmpty)
    }

    @Test func identicalReplayCannotRefreshOrReviveFiveSecondObservation() throws {
        var store = store()
        let original = try packet(sequence: 100, transaction: 1)
        let first = receive(&store, original, at: 100)
        let duplicate = receive(&store, original, at: 104)
        #expect(first && !duplicate)
        #expect(snapshot(store, at: 105).count == 1)
        #expect(snapshot(store, at: 105.001).isEmpty)
        let oldAfterExpiry = receive(&store, original, at: 106)
        #expect(!oldAfterExpiry && snapshot(store, at: 106).isEmpty)
        let sameValueNewPacket = receive(&store, try packet(sequence: 101, transaction: 2), at: 106)
        #expect(sameValueNewPacket && snapshot(store, at: 106).first?.receivedUptime == 106)
    }

    @Test func sparsePropertiesRebaseAfterExpiryWithoutGlobalSequenceInterference() throws {
        var store = store()
        let lens = receive(&store, try packet(.lensState, sequence: 1000), at: 100)
        let unrelated = receive(&store, try packet(.imageEffect, sequence: 65500), at: 101)
        let nextLens = receive(&store, try packet(.lensState, sequence: 1001, transaction: 2), at: 102)
        let recentBackwards = receive(&store, try packet(.lensState, sequence: 5, transaction: 3), at: 103)
        let afterExpiry = receive(&store, try packet(.lensState, sequence: 5, transaction: 3), at: 108)
        #expect(lens && unrelated && nextLens && !recentBackwards && afterExpiry)
        let current = try #require(snapshot(store, at: 108).first)
        #expect(current.property == .lensState && current.transactionID == 3 && current.receivedUptime == 108)
    }

    @Test func explicitReadResetAdmitsNewReplyButPreservesReplayHistoryAndAge() throws {
        var store = store()
        let original = try packet(sequence: 500, transaction: 1)
        _ = receive(&store, original, at: 100)
        let next = try packet(sequence: 4, transaction: 99)
        let rejected = receive(&store, next, at: 101)
        let reset = store.resetAdmission(for: .lensState, sessionID: session, peripheralID: peer, at: 101)
        #expect(!rejected && reset && snapshot(store, at: 101).first?.receivedUptime == 100)
        let replay = receive(&store, original, at: 101.1)
        let newReply = receive(&store, next, at: 101.2)
        #expect(!replay && newReply)
        #expect(snapshot(store, at: 101.2).first?.transactionID == 99)
        #expect(store.retainedFingerprintCount == 2)

        var expiredWindow = self.store()
        _ = receive(&expiredWindow, original, at: 100)
        _ = expiredWindow.resetAdmission(for: .lensState, sessionID: session, peripheralID: peer, at: 101)
        let expired = receive(&expiredWindow, next, at: 103.1)
        #expect(!expired)
    }

    @Test func unknownValueReplacesKnownStateAndMalformedOrOtherRoutesDoNotLeak() throws {
        var store = store()
        _ = receive(&store, try packet(sequence: 1), at: 100)
        let unknown = receive(&store, try packet(sequence: 2, transaction: 2, value: Data([0])), at: 101)
        #expect(unknown && snapshot(store, at: 101).first?.value == nil)
        let secret = Data("PRIVATE_CAMERA_CREDENTIAL".utf8)
        let rejected = try [packet(sequence: 3, flags: 0xc0), packet(sequence: 3, source: 0x48),
            packet(sequence: 3, destination: 0x22), packet(sequence: 3, value: secret, name: "wifi_password"),
            packet(sequence: 3, value: secret, name: "cam_lens_state_extra"),
            packet(sequence: 3, value: Data(repeating: 0, count: 65)),
            packet(.imageEffect, sequence: 3, value: Data([0,0,0,0,6]))]
        for packet in rejected {
            let accepted = receive(&store, packet, at: 102)
            #expect(!accepted)
        }
        let values = snapshot(store, at: 102)
        #expect(values.count == 1 && values[0].receivedUptime == 101 && values[0].value == nil)
        let json = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        #expect(!json.contains("PRIVATE_CAMERA_CREDENTIAL") && !json.contains("valueHex") && !json.contains("frameData"))
    }

    @Test func fingerprintsAreBoundedAndClearReleasesAllSessionState() throws {
        var store = store()
        for index in 1...100 {
            for property in [CameraSettingsProperty.lensState, .imageEffect, .exposure] {
                let accepted = receive(&store, try packet(property, sequence: UInt16(index), transaction: UInt32(index)), at: Double(index))
                #expect(accepted)
            }
        }
        #expect(store.retainedFingerprintCount == 3 * BluetoothCameraSettingsStore.maximumFingerprintsPerProperty)
        #expect(snapshot(store, at: 100).count == 3)
        store.clear()
        #expect(store.retainedFingerprintCount == 0 && snapshot(store, at: 100).isEmpty)
        let late = receive(&store, try packet(), at: 101)
        #expect(!late)
    }

    @Test func bindingPairingAndClockFencesRejectLateOrForeignPackets() throws {
        var store = store()
        let first = try packet(sequence: 10)
        let unpaired = receive(&store, first, at: 100, paired: false)
        let wrongPeer = store.receive(first, sessionID: session, peripheralID: UUID(), paired: true, uptime: 100)
        let wrongSession = store.receive(first, sessionID: UUID(), peripheralID: peer, paired: true, uptime: 100)
        #expect(!unpaired && !wrongPeer && !wrongSession)
        _ = receive(&store, first, at: 100)
        for time in [99.0, -1, Double.nan, .infinity] {
            let accepted = receive(&store, try packet(sequence: 11, transaction: 2), at: time)
            #expect(!accepted)
        }
        #expect(snapshot(store, at: 99).isEmpty && snapshot(store, at: .nan).isEmpty)
        let resetForeign = store.resetAdmission(for: .lensState, sessionID: UUID(), peripheralID: peer, at: 101)
        #expect(!resetForeign)
        let replacement = UUID()
        store.bind(sessionID: replacement, peripheralID: peer)
        let old = receive(&store, first, at: 101)
        let current = store.receive(first, sessionID: replacement, peripheralID: peer, paired: true, uptime: 101)
        #expect(!old && current)
        let values = store.snapshot(sessionID: replacement, peripheralID: peer, paired: true, nowUptime: 101)
        #expect(values.first?.binding.sessionID == "ble:\(replacement.uuidString)")
    }

    @Test func discoverySnapshotDefaultsNewObservationArrayWhenReadingOlderJSON() throws {
        let status = BluetoothDiscoveryStatus(phase: .gattPaired, sessionID: session, candidates: [], selectedPeripheralID: peer,
            issueCode: nil, identityVerification: "unverified_candidate", authentication: "protocol_pair_confirmed",
            fff4NotificationEnabled: true, fff5NotificationEnabled: true, fff4Properties: nil, fff5Properties: nil,
            receivedFrames: 0, fragments: [:])
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        legacy.removeValue(forKey: "cameraSettingsObservations")
        let decoded = try JSONDecoder().decode(BluetoothDiscoveryStatus.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.cameraSettingsObservations.isEmpty && decoded.sessionID == session)
    }
}
