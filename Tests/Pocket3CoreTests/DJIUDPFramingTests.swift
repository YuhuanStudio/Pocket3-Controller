import Foundation
import Testing
@testable import Pocket3Core

// Small frozen transport vectors: Kaze for DJI 341a35de18493ff61f97c93b8b10161a7512aa36,
// Copyright (c) 2026 Brian Merchant, MIT. Full source hashes/license attribution:
// research/2026-09-08/udp-fixtures/PROVENANCE.md.
@Suite("DJI UDP framing and session cursors") struct DJIUDPFramingTests {
    private let session: UInt16 = 0x1234
    private func hex(_ text: String) -> Data {
        let characters = Array(text)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        })
    }
    private func packet(_ type: DJIUDPPacketType, sequence: UInt16 = 0, payload: Data = Data(), sessionID: UInt16 = 0x1234) throws -> DJIUDPDatagram {
        try DJIUDPFraming.decode(DJIUDPFraming.encode(packetType: type, payload: payload, sessionID: sessionID, sequence: sequence), expectedSessionID: sessionID)
    }
    private func fixingHeaderXOR(_ data: Data) -> Data {
        var bytes = Array(data); bytes[7] = bytes.prefix(7).reduce(0, ^); return Data(bytes)
    }
    private func statusPayload(channel: UInt16, video: UInt16, channel3: UInt16, ack: UInt16) -> Data {
        var bytes = [UInt8](repeating: 0, count: 26)
        for (offset, value) in [(0, channel), (2, video), (10, channel3), (16, ack)] {
            bytes[offset] = UInt8(value & 0xff); bytes[offset + 1] = UInt8(value >> 8)
        }
        return Data(bytes)
    }

    @Test func outgoingHeaderMatchesFrozenWireBytes() throws {
        let encoded = try DJIUDPFraming.encode(packetType: .command, payload: Data(repeating: 0, count: 34), sessionID: session, sequence: 0x5678)
        #expect(encoded.prefix(8) == hex("2A803412785605A7"))
        let decoded = try DJIUDPFraming.decode(encoded, expectedSessionID: session)
        #expect(decoded.header.declaredLength == 42)
        #expect(decoded.header.rawHighFlags == 0x8000)
        #expect(decoded.header.sequence == 0x5678 && decoded.header.packetType == .command)
        #expect(decoded.quality.permitsStateUpdates)
    }

    @Test func routingUsesActualPeerAcknowledgmentAndLowCounterByte() throws {
        let encoded = DJIUDPFraming.routingHeader(peerAcknowledgment: 0x1234, sequence: 0x5678, commandCounter: 0x019a)
        #expect(encoded == hex("34127856000000009A010000"))
        let decoded = try DJIUDPFraming.decodeRoutingHeader(encoded)
        #expect(decoded.peerAcknowledgment == 0x1234)
        #expect(decoded.sequence == 0x5678 && decoded.commandCounter == 0x9a)
        #expect(decoded.flags == 1 && decoded.routingClass == 0 && decoded.reservedWord == 0)
        var extended = encoded; extended[4] = 0x11; extended[9] = 0x12; extended[10] = 0x34; extended[11] = 0x56
        let preserved = try DJIUDPFraming.decodeRoutingHeader(extended)
        #expect(preserved.reservedWord == 0x11 && preserved.flags == 0x12 && preserved.routingClass == 0x34 && preserved.reservedByte == 0x56)
        #expect(throws: DJIUDPFramingError.invalidRoutingSize) { try DJIUDPFraming.decodeRoutingHeader(encoded.dropLast()) }
        #expect(throws: DJIUDPFramingError.invalidRoutingSize) { try DJIUDPFraming.decodeRoutingHeader(encoded + Data([0])) }
    }

    @Test func acknowledgmentMatchesFrozenThreeWindowPayload() {
        let bytes = DJIUDPFraming.acknowledgmentPayload(receivedVideoSequence: 0x1111, receivedChannel3Sequence: 0x2222,
            peerAcknowledgedTransmitSequence: 0x3333, lastTransmitSequence: 0x4444)
        #expect(bytes.count == 26)
        #expect(bytes == hex("1111111100000000222222220000000033334444000000000000"))
    }

    @Test func sizeBoundsAndNonzeroSlicesAreHandledBeforeOffsets() throws {
        for length in 0..<8 {
            #expect(throws: DJIUDPFramingError.invalidSize) { try DJIUDPFraming.decode(Data(repeating: 0, count: length), expectedSessionID: session) }
        }
        let maximum = try DJIUDPFraming.encode(packetType: .video, payload: Data(repeating: 0xab, count: 16375), sessionID: session, sequence: 8)
        #expect(maximum.count == 16383)
        #expect(try DJIUDPFraming.decode(maximum, expectedSessionID: session).quality.permitsStateUpdates)
        let wrapped = Data([1, 2, 3]) + maximum
        #expect(try DJIUDPFraming.decode(wrapped.dropFirst(3), expectedSessionID: session).payload.count == 16375)
        #expect(throws: DJIUDPFramingError.invalidSize) { try DJIUDPFraming.decode(maximum + Data([0]), expectedSessionID: session) }
        #expect(throws: DJIUDPFramingError.invalidSize) { try DJIUDPFraming.encode(packetType: .video, payload: Data(repeating: 0, count: 16376), sessionID: session, sequence: 8) }
    }

    @Test func uncertainHeaderPropertiesRemainVisibleButInvalidHeadersCannotAdvanceState() throws {
        let good = try DJIUDPFraming.encode(packetType: .video, payload: hex("7820"), sessionID: session, sequence: 0x2010)
        var window = DJIUDPWindowState(sessionID: session, baseSequence: 0x1000)
        let unchanged = window
        var badXOR = good; badXOR[7] ^= 0xff
        let xorPacket = try DJIUDPFraming.decode(badXOR, expectedSessionID: session)
        #expect(!xorPacket.quality.checksumMatches && xorPacket.quality.declaredLengthMatches)
        #expect(window.observe(xorPacket) == .rejectedHeader && window == unchanged)
        for received in [good.dropLast(), good + Data([0])] {
            let mismatch = try DJIUDPFraming.decode(received, expectedSessionID: session)
            #expect(!mismatch.quality.declaredLengthMatches)
            #expect(window.observe(mismatch) == .rejectedHeader && window == unchanged)
        }
        var alternateFlags = good; alternateFlags[1] = (alternateFlags[1] & 0x3f) | 0xc0
        let unknownFlags = try DJIUDPFraming.decode(fixingHeaderXOR(alternateFlags), expectedSessionID: session)
        #expect(unknownFlags.header.rawHighFlags == 0xc000)
        #expect(unknownFlags.quality.permitsStateUpdates) // High-bit semantics are not assumed to be an inbound validity rule.
    }

    @Test func wrongSessionsUnknownTypesAndShortStatusNeverChangeCursors() throws {
        let good = try DJIUDPFraming.encode(packetType: .status, payload: statusPayload(channel: 0x3000, video: 0x4000, channel3: 0x5000, ack: 0x6000), sessionID: 0xabcd, sequence: 8)
        #expect(throws: DJIUDPFramingError.wrongSession) { try DJIUDPFraming.decode(good, expectedSessionID: session) }
        var window = DJIUDPWindowState(sessionID: session, baseSequence: 0x1000)
        let unchanged = window
        #expect(window.observe(try DJIUDPFraming.decode(good, expectedSessionID: 0xabcd)) == .wrongSession)
        #expect(window == unchanged)
        #expect(window.observe(try packet(.status, payload: hex("ff7f"))) == .shortStatus)
        #expect(window == unchanged)
        #expect(window.observe(try packet(.acknowledgment, payload: Data(repeating: 0xff, count: 26))) == .unsupportedPacketType)
        #expect(window == unchanged)
        var unknown = try DJIUDPFraming.encode(packetType: .video, payload: hex("ff7f"), sessionID: session, sequence: 16)
        unknown[6] = 0xee
        #expect(window.observe(try DJIUDPFraming.decode(fixingHeaderXOR(unknown), expectedSessionID: session)) == .unsupportedPacketType)
        #expect(window == unchanged)
    }

    @Test func peerBootstrapSequenceWrapAndAcknowledgmentsUseDistinctSendRules() throws {
        var window = DJIUDPWindowState(sessionID: session, baseSequence: 0xfff0)
        #expect(throws: DJIUDPFramingError.peerChannelUnavailable) { try window.synchronizeToPeerChannel() }
        #expect(window.observe(try packet(.handshake, payload: hex("f8ff"))) == .accepted(.handshake))
        try window.synchronizeToPeerChannel()
        #expect(window.isSynchronized && window.nextTransmitSequence == 0 && window.cameraChannel == 0xfff8)
        try window.recordSuccessfulSend(sequence: 0, packetType: .command)
        #expect(window.nextTransmitSequence == 8 && window.lastTransmitSequence == 0 && window.transmitLagSlots == 1)
        let beforeBadSend = window
        #expect(throws: DJIUDPFramingError.unexpectedTransmitSequence) { try window.recordSuccessfulSend(sequence: 16, packetType: .command) }
        #expect(window == beforeBadSend)
        let ack = try DJIUDPFraming.decode(window.acknowledgmentPacket(), expectedSessionID: session)
        #expect(ack.header.packetType == .acknowledgment && ack.header.sequence == 0 && ack.payload.count == 26)
        try window.recordSuccessfulSend(sequence: 0, packetType: .acknowledgment)
        #expect(window == beforeBadSend)
        try window.recordSuccessfulSend(sequence: 8, packetType: .command)
        #expect(window.nextTransmitSequence == 16 && window.transmitLagSlots == 2)
    }

    @Test func statusSeedsOnlyUnobservedReceiveChannelsAndUsesActualAckField() throws {
        var window = DJIUDPWindowState(sessionID: session, baseSequence: 0x1000)
        window.observe(try packet(.status, payload: statusPayload(channel: 0x1800, video: 0x2000, channel3: 0x3000, ack: 0x1000)))
        #expect(window.cameraChannel == 0x1800 && window.receivedVideoSequence == 0x2000 && window.receivedChannel3Sequence == 0x3000)
        window.observe(try packet(.video, sequence: 0x2010, payload: hex("0018")))
        window.observe(try packet(.channel3, sequence: 0x3018, payload: hex("0018")))
        window.observe(try packet(.status, payload: statusPayload(channel: 0x1800, video: 0x2008, channel3: 0x3008, ack: 0x1010)))
        #expect(window.receivedVideoSequence == 0x2010 && window.receivedChannel3Sequence == 0x3018)
        #expect(window.peerAcknowledgedTransmitSequence == 0x1010)
        window.observe(try packet(.video, sequence: 0, payload: Data()))
        #expect(window.receivedVideoSequence == 0x2010)
    }

    @Test func routedDUMLUsesExistingCodecAndNeverScansVideoOrChannel3() throws {
        let frame = DUMLFrame(source: 2, destination: 4, sequence: 0xa001, flags: 0, commandSet: 4, commandID: 1, payload: Data([0, 4, 0, 0, 0, 4, 0, 0x80, 0x22, 0]))
        let bytes = try DJIUDPFraming.command(frame: frame, sessionID: session, sequence: 0x5008, peerAcknowledgment: 0x4010, commandCounter: 0x102)
        let datagram = try DJIUDPFraming.decode(bytes, expectedSessionID: session)
        let command = try DJIUDPFraming.routedCommand(in: datagram)
        #expect(command.frame == frame && command.routingSequenceMatchesTransport)
        #expect(command.routing.peerAcknowledgment == 0x4010 && command.routing.commandCounter == 2)
        for type in [DJIUDPPacketType.video, .channel3] {
            let other = try packet(type, sequence: 0x5008, payload: datagram.payload)
            #expect(throws: DJIUDPFramingError.unsupportedCommandPacket) { try DJIUDPFraming.routedCommand(in: other) }
        }
        var damaged = bytes; damaged[damaged.count - 1] ^= 1
        #expect(throws: DUMLCodecError.invalidFrameChecksum) { try DJIUDPFraming.routedCommand(in: DJIUDPFraming.decode(damaged, expectedSessionID: session)) }
        let truncatedRoute = try packet(.command, payload: Data(repeating: 0, count: 11))
        #expect(throws: DJIUDPFramingError.invalidSize) { try DJIUDPFraming.routedCommand(in: truncatedRoute) }
    }
}
