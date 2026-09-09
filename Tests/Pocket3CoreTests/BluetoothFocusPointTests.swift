import Foundation
import Testing
@testable import Pocket3Core

@Suite struct BluetoothFocusPointTests {
    private let session = UUID(), peer = UUID()
    private func hex(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        return Data(stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(decoding: bytes[$0..<($0 + 2)], as: UTF8.self), radix: 16)!
        })
    }
    private func value(x: Float = 0.25, y: Float = 0.75, mode: UInt8 = 0xb2, count: Int = 47) -> Data {
        var bytes: [UInt8] = [mode]
        for bits in [x.bitPattern, y.bitPattern] {
            bytes += (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        }
        return Data(bytes + [UInt8](repeating: 0, count: max(0, count - 9)))
    }
    private func packet(sequence: UInt16 = 1, transaction: UInt32 = 77, value contents: Data? = nil,
                        source: UInt8 = 0x28, destination: UInt8 = 2, flags: UInt8 = 0,
                        name: String = "cam_lens_state", commandSet: UInt8 = 0, commandID: UInt8 = 0x99) throws -> ValidatedDUMLPacket {
        let contents = contents ?? value()
        var bytes: [UInt8] = [2,6,0,0]
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: transaction >> ($0 * 8)) }
        bytes += [0,0,0]
        func append16(_ n: Int) { bytes += [UInt8(n & 255), UInt8((n >> 8) & 255)] }
        append16(name.utf8.count + contents.count + 10); append16(name.utf8.count)
        bytes += name.utf8; bytes += [0,0,0,0,0,0]; append16(contents.count); bytes += contents
        let frame = DUMLFrame(source: source, destination: destination, sequence: sequence, flags: flags,
                              commandSet: commandSet, commandID: commandID, payload: Data(bytes))
        var decoder = DUMLFragmentDecoder()
        let packets = try decoder.append(DUMLCodec.encode(frame), at: 0)
        return try #require(packets.first)
    }
    private func recorder() throws -> BluetoothFocusPointRecorder {
        try BluetoothFocusPointRecorder(sessionID: session, peripheralID: peer, sequence: 60000,
                                        transactionID: 0x11223344, startedUptime: 100)
    }
    private func receive(_ recorder: inout BluetoothFocusPointRecorder, _ packet: ValidatedDUMLPacket,
                         at uptime: TimeInterval, characteristic: String = "FFF4") -> Bool {
        recorder.receive(packet, characteristic: characteristic, sessionID: session, peripheralID: peer,
                         paired: true, hostReceivedAt: Date(timeIntervalSinceReferenceDate: uptime), uptime: uptime)
    }
    private func latest(_ recorder: BluetoothFocusPointRecorder, at uptime: TimeInterval) -> BluetoothFocusPointObservation? {
        recorder.latest(sessionID: session, peripheralID: peer, paired: true, nowUptime: uptime)
    }

    @Test func recorded47ByteValuesDecodeWithoutClaimingCalibratedCoordinates() throws {
        // Local artifact: hardware-roll-2026-09-09/properties/cam_lens_state.json.
        // This replays bytes offline; it is not a body-tap or setter test.
        let bytes = hex("b2f140713ef134f13e00d9006403d900000005060c06300282062a0201000000000000000000009411000094110000")
        let point = try #require(LensPointCandidate.decode(bytes))
        #expect(point.rawModeCode == 0xb2 && point.valueLength == 47)
        #expect(point.xCandidate == 0.23559929430484772 && point.yCandidate == 0.47110703587532043)
        #expect(point.valuePrefixHex == "b2f140713ef134f13e" && point.calibration == .unverified)
        let center = try #require(LensPointCandidate.decode(hex("b200ffff3e00ffff3e")))
        #expect(center.xCandidate == 0.49999237060546875 && center.yCandidate == center.xCandidate)
    }

    @Test func minimumSemanticLengthSlicesAndUnknownModeRemainExplicit() throws {
        for count in [9,47,64,67,90] {
            let bytes = value(mode: 0x7f, count: count)
            let sliced = (Data([1,2,3]) + bytes).dropFirst(3)
            let point = try #require(LensPointCandidate.decode(sliced))
            #expect(point.valueLength == count && point.rawModeCode == 0x7f)
            #expect(point.xCandidate == 0.25 && point.yCandidate == 0.75 && point.calibration == .unverified)
        }
        for count in 0..<9 { #expect(LensPointCandidate.decode(Data(value().prefix(count))) == nil) }
        for bad: Float in [-0.001,1.001,.nan,.infinity,-.infinity] {
            #expect(LensPointCandidate.decode(value(x: bad)) == nil)
            #expect(LensPointCandidate.decode(value(y: bad)) == nil)
        }
        #expect(LensPointCandidate.decode(value(x: 0, y: 1)) != nil)
    }

    @Test func candidateCodableRevalidatesRawPrefixNumbersAndCalibration() throws {
        let point = try #require(LensPointCandidate.decode(value()))
        let encoded = try JSONEncoder().encode(point)
        #expect(try JSONDecoder().decode(LensPointCandidate.self, from: encoded) == point)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (key, invalid): (String, Any) in [("xCandidate", 0.8), ("valueLength", 8),
                                             ("rawModeCode", 0xb1), ("calibration", "calibrated"),
                                             ("valuePrefixHex", "b2")] {
            var tampered = fields; tampered[key] = invalid
            let data = try JSONSerialization.data(withJSONObject: tampered)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(LensPointCandidate.self, from: data) }
        }
    }

    @Test func oneKnownSubscriptionCollectsMultiplePushesAndSeparatesAck() throws {
        var recorder = try recorder()
        let frame = recorder.request
        #expect(frame.source == 2 && frame.destination == 0x28 && frame.flags == 0x40)
        #expect(frame.commandSet == 0 && frame.commandID == 0x99 && frame.payload.count == 33)
        #expect(try DUMLCodec.encode(frame).count == 46)
        try recorder.submitted(at: 100)
        #expect(throws: BridgeFailure.self) { try recorder.submitted(at: 100.1) }
        let ack = receive(&recorder, try packet(sequence: 60000, flags: 0xc0), at: 100.1)
        #expect(!ack && recorder.result.ackHeader?.sequence == 60000 && recorder.result.observations.isEmpty)
        let first = receive(&recorder, try packet(sequence: 30, transaction: 8), at: 100.2)
        let second = receive(&recorder, try packet(sequence: 31, transaction: 9, value: value(x: 0.75, y: 0.25, count: 67)), at: 100.4)
        #expect(first && second && recorder.result.observations.count == 2)
        let observed = try #require(latest(recorder, at: 100.5))
        #expect(observed.sequence == 31 && observed.propertyTransactionID == 9)
        #expect(observed.sessionID == session && observed.peripheralID == peer)
        #expect(observed.receivedUptime == 100.4 && observed.hostReceivedAt == Date(timeIntervalSinceReferenceDate: 100.4))
        #expect(observed.candidate.valueLength == 67 && observed.candidate.xCandidate == 0.75)
        let finished = recorder.finish(at: 112)
        #expect(finished.end == .windowElapsed && finished.observations.count == 2)
    }

    @Test func freshValueRequiresExactPeerSessionPairingAndFiveSecondHostAge() throws {
        var recorder = try recorder(); try recorder.submitted(at: 100)
        _ = receive(&recorder, try packet(), at: 101)
        let observed = try #require(latest(recorder, at: 106))
        #expect(latest(recorder, at: 106.0001) == nil && latest(recorder, at: 100.9) == nil)
        #expect(!observed.isFresh(sessionID: UUID(), peripheralID: peer, paired: true, nowUptime: 102))
        #expect(!observed.isFresh(sessionID: session, peripheralID: UUID(), paired: true, nowUptime: 102))
        #expect(!observed.isFresh(sessionID: session, peripheralID: nil, paired: true, nowUptime: 102))
        #expect(!observed.isFresh(sessionID: session, peripheralID: peer, paired: false, nowUptime: 102))
        #expect(latest(recorder, at: .nan) == nil && latest(recorder, at: .infinity) == nil)
        let snapshot = recorder.result
        _ = receive(&recorder, try packet(sequence: 2), at: 107)
        #expect(snapshot.observations.count == 1 && snapshot.observations[0].receivedUptime == 101)
        #expect(latest(recorder, at: 107)?.receivedUptime == 107)
    }

    @Test func duplicateSameSequenceAndBackwardsSequenceCannotRefreshAge() throws {
        var recorder = try recorder(); try recorder.submitted(at: 100)
        let first = try packet(sequence: 65535, transaction: 1)
        _ = receive(&recorder, first, at: 100.1)
        let duplicate = receive(&recorder, first, at: 105)
        let sameSequence = receive(&recorder, try packet(sequence: 65535, transaction: 2), at: 105.1)
        let backwards = receive(&recorder, try packet(sequence: 65534, transaction: 3), at: 105.2)
        #expect(!duplicate && !sameSequence && !backwards)
        #expect(latest(recorder, at: 105.2) == nil)
        let wrapped = receive(&recorder, try packet(sequence: 0, transaction: 4), at: 106)
        #expect(wrapped && recorder.result.observations.count == 2)
    }

    @Test func foreignRoutesAndInvalidNewValuesNeverExposeAnOldCandidateAsCurrent() throws {
        var recorder = try recorder(); try recorder.submitted(at: 100)
        let rejected = try [packet(source: 0x48), packet(destination: 0x22), packet(flags: 0x40),
                            packet(commandSet: 7, commandID: 0x0e), packet(name: "wifi_password"),
                            packet(name: "cam_image_effect"), packet(name: "cam_lens_state_extra")]
        for packet in rejected {
            let accepted = receive(&recorder, packet, at: 100.1)
            #expect(!accepted)
        }
        let foreignPeer = recorder.receive(try packet(), characteristic: "FFF4", sessionID: session, peripheralID: UUID(), paired: true, hostReceivedAt: Date(), uptime: 100.1)
        let foreignSession = recorder.receive(try packet(), characteristic: "FFF4", sessionID: UUID(), peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 100.1)
        let wrongCharacteristic = receive(&recorder, try packet(), at: 100.1, characteristic: "FFF3")
        #expect(!foreignPeer && !foreignSession && !wrongCharacteristic && recorder.result.acceptedPropertyCount == 0)
        _ = receive(&recorder, try packet(sequence: 1), at: 100.2)
        let invalid = receive(&recorder, try packet(sequence: 2, value: Data([0xb2])), at: 100.3)
        #expect(invalid && recorder.result.invalidCandidateCount == 1)
        #expect(latest(recorder, at: 100.4) == nil && recorder.result.observations.count == 1)
        let json = String(decoding: try JSONEncoder().encode(recorder.result), as: UTF8.self)
        #expect(!json.contains("wifi_password") && !json.contains("frameData") && !json.contains("cam_image_effect"))
    }

    @Test func cancellationConnectionRetirementAndClockRollbackFreezeHistory() throws {
        for reason in [BluetoothFocusPointRecordingEnd.cancelled, .connectionChanged] {
            var recorder = try recorder(); try recorder.submitted(at: 100)
            _ = receive(&recorder, try packet(), at: 101)
            let final = recorder.finish(at: 102, reason: reason)
            let late = receive(&recorder, try packet(sequence: 2), at: 103)
            let repeated = recorder.finish(at: 104)
            #expect(!late && latest(recorder, at: 103) == nil)
            #expect(repeated.end == reason && repeated.finishedUptime == final.finishedUptime)
        }
        var recorder = try recorder(); try recorder.submitted(at: 100)
        _ = receive(&recorder, try packet(), at: 101)
        let rollback = receive(&recorder, try packet(sequence: 2), at: 100.9)
        #expect(!rollback && recorder.result.end == .invalidClock && latest(recorder, at: 102) == nil)
        #expect(recorder.result.finishedUptime == 101)
        _ = try JSONEncoder().encode(recorder.result)
    }

    @Test func recorderBoundsAllNamedValuesAndDoesNotClaimEarlyWindowCompletion() throws {
        var recorder = try recorder(); try recorder.submitted(at: 100)
        for index in 0..<64 {
            let accepted = receive(&recorder, try packet(sequence: UInt16(index), transaction: UInt32(index)), at: 100.1 + Double(index) * 0.1)
            #expect(accepted)
        }
        let overLimit = receive(&recorder, try packet(sequence: 65), at: 110)
        #expect(!overLimit && recorder.result.end == .sampleLimit && recorder.result.observations.count == 64)
        var expired = try self.recorder(); try expired.submitted(at: 100)
        let tooLate = receive(&expired, try packet(), at: 112.01)
        #expect(!tooLate && expired.result.end == .windowElapsed && expired.result.acceptedPropertyCount == 0)
        var early = try self.recorder(); try early.submitted(at: 100)
        let final = early.finish(at: 101, reason: .windowElapsed)
        #expect(final.end == .finishedEarly)
        for bad in [Double.nan, .infinity, -1, .greatestFiniteMagnitude] {
            #expect(throws: CameraSettingsError.self) {
                try BluetoothFocusPointRecorder(sessionID: session, peripheralID: peer, sequence: 1, transactionID: 1, startedUptime: bad)
            }
        }
    }
}
