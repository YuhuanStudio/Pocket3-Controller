import Foundation
import Testing
@testable import Pocket3Core

private let poseSession = UUID(), posePeer = UUID()
private func poseFrame(sequence: UInt16 = 1, source: UInt8 = 4, destination: UInt8 = 2,
                       commandSet: UInt8 = 4, commandID: UInt8 = 5,
                       raw: [Int16] = [-125,20,1799], tail: Data = Data()) -> DUMLFrame {
    var bytes = Data()
    for value in raw {
        let bits = UInt16(bitPattern: value)
        bytes.append(UInt8(truncatingIfNeeded: bits)); bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
    }
    bytes.append(tail)
    return DUMLFrame(source: source, destination: destination, sequence: sequence, flags: 0,
                     commandSet: commandSet, commandID: commandID, payload: bytes)
}
private func posePacket(_ frame: DUMLFrame = poseFrame()) throws -> ValidatedDUMLPacket {
    var decoder = DUMLFragmentDecoder()
    let encoded = try DUMLCodec.encode(frame)
    let packets = try decoder.append(encoded, at: 0)
    return try #require(packets.first)
}
private func receivePose(_ store: inout BluetoothPoseStore, packet: ValidatedDUMLPacket,
                         session: UUID = poseSession, peer: UUID = posePeer,
                         paired: Bool = true, time: TimeInterval = 100) -> Bool {
    store.receive(packet, sessionID: session, peripheralID: peer, paired: paired,
                  receivedAt: Date(timeIntervalSince1970: 1000 + time), uptime: time)
}
private func snapshot(_ store: BluetoothPoseStore, time: TimeInterval = 100, paired: Bool = true) -> BluetoothPoseObservation? {
    store.snapshot(sessionID: poseSession, peripheralID: posePeer, paired: paired, nowUptime: time)
}

@Test func bluetoothPoseUsesExistingAxisLayoutAndDeviceReportedUnits() throws {
    var store = BluetoothPoseStore(); store.bind(sessionID: poseSession, peripheralID: posePeer)
    let packet = try posePacket(poseFrame(tail: Data("PRIVATE_TAIL_NOT_IN_STATUS".utf8)))
    let accepted = receivePose(&store, packet: packet)
    #expect(accepted)
    let pose = try #require(snapshot(store))
    #expect(pose.pitchRaw == -125 && pose.rollRaw == 20 && pose.yawRaw == 1799)
    #expect(pose.pitchDegrees == -12.5 && pose.rollDegrees == 2 && pose.yawDegrees == 179.9)
    #expect(pose.unit == .deviceReportedDeciDegrees && pose.calibration == .notCalibratedToUSB)
    let decoded = try #require(BluetoothPoseValues.parse(packet.frame))
    let existingTelemetry = decoded.telemetry(receivedAt: pose.receivedAt)
    #expect(existingTelemetry.pitchDegrees == pose.pitchDegrees && existingTelemetry.rollDegrees == pose.rollDegrees
            && existingTelemetry.yawDegrees == pose.yawDegrees)
    let json = try JSONEncoder().encode(pose)
    let text = String(decoding: json, as: UTF8.self)
    #expect(text.contains("device_reported_deci_degrees") && text.contains("not_calibrated_to_usb"))
    #expect(!text.contains("PRIVATE_TAIL") && !text.contains("frameData") && !text.contains("cameraReady"))
    #expect(try JSONDecoder().decode(BluetoothPoseObservation.self, from: json) == pose)
}

@Test func bluetoothPoseRequiresCurrentPairedPeerAndSession() throws {
    var store = BluetoothPoseStore(); store.bind(sessionID: poseSession, peripheralID: posePeer)
    let packet = try posePacket()
    let unpaired = receivePose(&store, packet: packet, paired: false)
    let oldSession = receivePose(&store, packet: packet, session: UUID())
    let otherPeer = receivePose(&store, packet: packet, peer: UUID())
    #expect(!unpaired && !oldSession && !otherPeer && snapshot(store) == nil)
    let accepted = receivePose(&store, packet: packet)
    #expect(accepted && snapshot(store, paired: false) == nil)
    #expect(store.snapshot(sessionID: UUID(), peripheralID: posePeer, paired: true, nowUptime: 100) == nil)
    #expect(store.snapshot(sessionID: poseSession, peripheralID: UUID(), paired: true, nowUptime: 100) == nil)
}

@Test func bluetoothPoseFiveSecondFreshnessCannotBeExtendedByDuplicateOrOldSequences() throws {
    var store = BluetoothPoseStore(); store.bind(sessionID: poseSession, peripheralID: posePeer)
    let first = receivePose(&store, packet: try posePacket(poseFrame(sequence: 0xffff)))
    let duplicate = receivePose(&store, packet: try posePacket(poseFrame(sequence: 0xffff)), time: 104)
    let older = receivePose(&store, packet: try posePacket(poseFrame(sequence: 0xfffe)), time: 104)
    #expect(first && !duplicate && !older)
    #expect(snapshot(store, time: 105) != nil)
    #expect(snapshot(store, time: 105.001) == nil)
    #expect(snapshot(store, time: 99) == nil && snapshot(store, time: .nan) == nil)
    let wrap = receivePose(&store, packet: try posePacket(poseFrame(sequence: 0)), time: 106)
    let halfRange = receivePose(&store, packet: try posePacket(poseFrame(sequence: 0x8000)), time: 107)
    #expect(wrap && !halfRange && snapshot(store, time: 106)?.sequence == 0)
}

@Test func bluetoothPoseRejectsInvalidClockWithoutConsumingSequence() throws {
    var store = BluetoothPoseStore(); store.bind(sessionID: poseSession, peripheralID: posePeer)
    let initial = receivePose(&store, packet: try posePacket(poseFrame(sequence: 10)))
    let packet = try posePacket(poseFrame(sequence: 11))
    let backwards = receivePose(&store, packet: packet, time: 99)
    let sameTime = receivePose(&store, packet: packet, time: 100)
    let notFinite = receivePose(&store, packet: packet, time: .infinity)
    let badDate = store.receive(packet, sessionID: poseSession, peripheralID: posePeer, paired: true,
                                receivedAt: Date(timeIntervalSince1970: .nan), uptime: 101)
    #expect(initial && !backwards && !sameTime && !notFinite && !badDate)
    // Wall clock adjustment must not replace the monotonic freshness clock.
    let current = store.receive(packet, sessionID: poseSession, peripheralID: posePeer, paired: true,
                                receivedAt: Date(timeIntervalSince1970: 0), uptime: 101)
    #expect(current && snapshot(store, time: 101)?.sequence == 11)
}

@Test func bluetoothPoseClearAndRebindRejectOldCallbacksAndResetSequenceBaseline() throws {
    var store = BluetoothPoseStore(); store.bind(sessionID: poseSession, peripheralID: posePeer)
    let old = try posePacket(poseFrame(sequence: 300))
    _ = receivePose(&store, packet: old)
    store.clear()
    #expect(snapshot(store) == nil)
    let afterClear = receivePose(&store, packet: old, time: 101)
    #expect(!afterClear)
    let session = UUID(), peer = UUID()
    store.bind(sessionID: session, peripheralID: peer)
    let late = receivePose(&store, packet: old, time: 102)
    let current = receivePose(&store, packet: try posePacket(poseFrame(sequence: 1)), session: session, peer: peer, time: 102)
    #expect(!late && current)
    let pose = store.snapshot(sessionID: session, peripheralID: peer, paired: true, nowUptime: 102)
    #expect(pose?.sequence == 1 && pose?.sessionID == session && pose?.peripheralID == peer)
}

@Test func bluetoothPoseRejectsWrongHeaderTruncationAndImplausibleRawAngles() throws {
    let invalid = [poseFrame(source: 5), poseFrame(destination: 3), poseFrame(commandSet: 7),
                   poseFrame(commandID: 0x27), poseFrame(raw: [1,2]),
                   poseFrame(raw: [.min,0,0]), poseFrame(raw: [0,3601,0])]
    for frame in invalid { #expect(BluetoothPoseValues.parse(frame) == nil) }
    var store = BluetoothPoseStore(); store.bind(sessionID: poseSession, peripheralID: posePeer)
    for frame in invalid {
        let accepted = receivePose(&store, packet: try posePacket(frame))
        #expect(!accepted && snapshot(store) == nil)
    }
    let valid = receivePose(&store, packet: try posePacket(poseFrame(raw: [-3600,0,3600])))
    #expect(valid)
}

@Test func bluetoothPoseOnlyReceivesCRCValidatedReassembledFrames() throws {
    let encoded = try DUMLCodec.encode(poseFrame())
    var corrupt = encoded; corrupt[corrupt.count - 1] ^= 1
    var badDecoder = DUMLFragmentDecoder()
    let invalidPackets = try badDecoder.append(corrupt, at: 0)
    #expect(invalidPackets.isEmpty)
    var decoder = DUMLFragmentDecoder()
    let split = encoded.count / 2
    let prefix = try decoder.append(Data(encoded.prefix(split)), at: 0)
    #expect(prefix.isEmpty)
    let packets = try decoder.append(Data(encoded.dropFirst(split)), at: 0.1)
    var store = BluetoothPoseStore(); store.bind(sessionID: poseSession, peripheralID: posePeer)
    let packet = try #require(packets.first)
    let accepted = receivePose(&store, packet: packet)
    #expect(accepted && snapshot(store)?.sequence == 1)
}
