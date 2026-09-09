import Foundation

public enum DJIUDPPacketType: UInt8, Sendable {
    case handshake = 0x00, status = 0x01, video = 0x02, channel3 = 0x03
    case acknowledgment = 0x04, command = 0x05
}
public enum DJIUDPFramingError: Error, Equatable, Sendable {
    case invalidSize, wrongSession, invalidHeader, invalidRoutingSize
    case unsupportedCommandPacket, peerChannelUnavailable, unexpectedTransmitSequence
}

public struct DJIUDPHeader: Sendable, Equatable {
    public let declaredLength: Int
    public let rawHighFlags: UInt16
    public let sessionID: UInt16
    public let sequence: UInt16
    public let rawPacketType: UInt8
    public let checksum: UInt8
    public var packetType: DJIUDPPacketType? { DJIUDPPacketType(rawValue: rawPacketType) }
}
public struct DJIUDPHeaderQuality: Sendable, Equatable {
    public let declaredLengthMatches: Bool
    public let checksumMatches: Bool
    /// This checks the known outgoing layout. Its acceptance of actual inbound
    /// camera traffic remains to be measured; mismatches are kept for diagnosis.
    public var permitsStateUpdates: Bool { declaredLengthMatches && checksumMatches }
}
public struct DJIUDPDatagram: Sendable, Equatable {
    public let header: DJIUDPHeader
    public let quality: DJIUDPHeaderQuality
    public let payload: Data
}
public struct DJIUDPRoutingHeader: Sendable, Equatable {
    public let peerAcknowledgment: UInt16
    public let sequence: UInt16
    public let reservedWord: UInt32
    public let commandCounter: UInt8
    public let flags: UInt8
    public let routingClass: UInt8
    public let reservedByte: UInt8
}
public struct DJIUDPRoutedCommand: Sendable, Equatable {
    public let routing: DJIUDPRoutingHeader
    public let frame: DUMLFrame
    public let routingSequenceMatchesTransport: Bool
}

/// Pure packet construction/inspection. No sockets, pairing or device actions.
/// See research/2026-09-08/udp-fixtures/PROVENANCE.md for the frozen layout and
/// the distinction between outgoing goldens and unverified inbound strictness.
public enum DJIUDPFraming {
    public static let headerLength = 8
    public static let routingLength = 12
    public static let maximumDatagramLength = 0x3fff
    public static let acknowledgmentPayloadLength = 26

    public static func encode(packetType: DJIUDPPacketType, payload: Data, sessionID: UInt16, sequence: UInt16) throws -> Data {
        guard payload.count <= maximumDatagramLength - headerLength else { throw DJIUDPFramingError.invalidSize }
        let length = UInt16(payload.count + headerLength) | 0x8000
        var bytes = [UInt8](repeating: 0, count: headerLength)
        put(length, in: &bytes, at: 0); put(sessionID, in: &bytes, at: 2); put(sequence, in: &bytes, at: 4)
        bytes[6] = packetType.rawValue; bytes[7] = bytes.prefix(7).reduce(0, ^)
        var result = Data(bytes); result.append(payload)
        return result
    }

    public static func decode(_ data: Data, expectedSessionID: UInt16) throws -> DJIUDPDatagram {
        guard (headerLength...maximumDatagramLength).contains(data.count) else { throw DJIUDPFramingError.invalidSize }
        let bytes = Array(data.prefix(headerLength)) // Normalize Data slice indices before offset reads.
        let word = read16(bytes, at: 0)
        let header = DJIUDPHeader(declaredLength: Int(word & 0x3fff), rawHighFlags: word & 0xc000,
            sessionID: read16(bytes, at: 2), sequence: read16(bytes, at: 4), rawPacketType: bytes[6], checksum: bytes[7])
        guard header.sessionID == expectedSessionID else { throw DJIUDPFramingError.wrongSession }
        let quality = DJIUDPHeaderQuality(declaredLengthMatches: header.declaredLength == data.count,
            checksumMatches: bytes.prefix(7).reduce(0, ^) == header.checksum)
        // Do not silently truncate to the declared length, or throw away the
        // diagnostic header merely because the reference did not validate it.
        // Consumers must check quality; window updates below always do so.
        return DJIUDPDatagram(header: header, quality: quality, payload: Data(data.dropFirst(headerLength)))
    }

    public static func routingHeader(peerAcknowledgment: UInt16, sequence: UInt16, commandCounter: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: routingLength)
        put(peerAcknowledgment, in: &bytes, at: 0); put(sequence, in: &bytes, at: 2)
        bytes[8] = UInt8(truncatingIfNeeded: commandCounter); bytes[9] = 1
        return Data(bytes)
    }
    public static func decodeRoutingHeader(_ data: Data) throws -> DJIUDPRoutingHeader {
        guard data.count == routingLength else { throw DJIUDPFramingError.invalidRoutingSize }
        let b = Array(data)
        let reserved = UInt32(b[4]) | (UInt32(b[5]) << 8) | (UInt32(b[6]) << 16) | (UInt32(b[7]) << 24)
        return DJIUDPRoutingHeader(peerAcknowledgment: read16(b, at: 0), sequence: read16(b, at: 2),
            reservedWord: reserved, commandCounter: b[8], flags: b[9], routingClass: b[10], reservedByte: b[11])
    }

    public static func command(frame: DUMLFrame, sessionID: UInt16, sequence: UInt16, peerAcknowledgment: UInt16, commandCounter: UInt64) throws -> Data {
        var payload = routingHeader(peerAcknowledgment: peerAcknowledgment, sequence: sequence, commandCounter: commandCounter)
        payload.append(try DUMLCodec.encode(frame))
        return try encode(packetType: .command, payload: payload, sessionID: sessionID, sequence: sequence)
    }
    /// Only the established type-05 routing envelope is decoded as a command.
    /// Type-02 is video; type-03 has a receive cursor but no assumed payload
    /// schema here. Neither is scanned for incidental DUML bytes.
    public static func routedCommand(in datagram: DJIUDPDatagram) throws -> DJIUDPRoutedCommand {
        guard datagram.quality.permitsStateUpdates else { throw DJIUDPFramingError.invalidHeader }
        guard datagram.header.packetType == .command else { throw DJIUDPFramingError.unsupportedCommandPacket }
        guard datagram.payload.count >= routingLength + DUMLCodec.minimumFrameLength else { throw DJIUDPFramingError.invalidSize }
        let routing = try decodeRoutingHeader(Data(datagram.payload.prefix(routingLength)))
        let frame = try DUMLCodec.decode(Data(datagram.payload.dropFirst(routingLength)))
        return DJIUDPRoutedCommand(routing: routing, frame: frame, routingSequenceMatchesTransport: routing.sequence == datagram.header.sequence)
    }

    public static func acknowledgmentPayload(receivedVideoSequence: UInt16, receivedChannel3Sequence: UInt16,
                                             peerAcknowledgedTransmitSequence: UInt16, lastTransmitSequence: UInt16) -> Data {
        var bytes = [UInt8](repeating: 0, count: acknowledgmentPayloadLength)
        for offset in [0, 2] { put(receivedVideoSequence, in: &bytes, at: offset) }
        for offset in [8, 10] { put(receivedChannel3Sequence, in: &bytes, at: offset) }
        put(peerAcknowledgedTransmitSequence, in: &bytes, at: 16); put(lastTransmitSequence, in: &bytes, at: 18)
        return Data(bytes)
    }

    fileprivate static func read16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
    private static func put(_ value: UInt16, in bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xff); bytes[offset + 1] = UInt8(value >> 8)
    }
}

public enum DJIUDPObservation: Sendable, Equatable {
    case accepted(DJIUDPPacketType), rejectedHeader, wrongSession, unsupportedPacketType, shortStatus
}

/// Single-owner mutable cursor state, matching the known Pocket 3 arrival-order
/// interpretation. It is not a packet retransmission or reliable-window engine.
public struct DJIUDPWindowState: Sendable, Equatable {
    public let sessionID: UInt16
    public let baseSequence: UInt16
    public private(set) var cameraChannel: UInt16
    public private(set) var nextTransmitSequence: UInt16 = 0
    public private(set) var lastTransmitSequence: UInt16
    public private(set) var peerAcknowledgedTransmitSequence: UInt16
    public private(set) var receivedVideoSequence: UInt16
    public private(set) var receivedChannel3Sequence: UInt16
    public private(set) var hasObservedPeerChannel = false
    public private(set) var isSynchronized = false
    private var hasReceivedVideo = false
    private var hasReceivedChannel3 = false
    public var transmitLagSlots: UInt16 { (lastTransmitSequence &- peerAcknowledgedTransmitSequence) / 8 }

    public init(sessionID: UInt16, baseSequence: UInt16) {
        self.sessionID = sessionID; self.baseSequence = baseSequence
        cameraChannel = baseSequence; lastTransmitSequence = baseSequence
        peerAcknowledgedTransmitSequence = baseSequence
        receivedVideoSequence = baseSequence; receivedChannel3Sequence = baseSequence
    }
    public mutating func synchronizeToPeerChannel() throws {
        guard hasObservedPeerChannel else { throw DJIUDPFramingError.peerChannelUnavailable }
        nextTransmitSequence = cameraChannel &+ 8
        lastTransmitSequence = cameraChannel; peerAcknowledgedTransmitSequence = cameraChannel
        isSynchronized = true
    }
    /// Call only after a serialized sender confirms local send acceptance.
    /// This advances a send cursor, not proof of delivery or physical action.
    public mutating func recordSuccessfulSend(sequence: UInt16, packetType: DJIUDPPacketType) throws {
        if packetType == .acknowledgment {
            guard sequence == 0 else { throw DJIUDPFramingError.unexpectedTransmitSequence }
            return // ACKs use sequence zero and do not consume a send slot.
        }
        guard sequence == nextTransmitSequence else { throw DJIUDPFramingError.unexpectedTransmitSequence }
        if packetType != .handshake { lastTransmitSequence = sequence }
        nextTransmitSequence = sequence &+ 8
    }
    @discardableResult
    public mutating func observe(_ datagram: DJIUDPDatagram) -> DJIUDPObservation {
        guard datagram.header.sessionID == sessionID else { return .wrongSession }
        guard datagram.quality.permitsStateUpdates else { return .rejectedHeader }
        guard let type = datagram.header.packetType, type != .acknowledgment else { return .unsupportedPacketType }
        // A status packet needs the complete 26-byte status body before any
        // cursor (including cameraChannel) may change.
        guard type != .status || datagram.payload.count >= 26 else { return .shortStatus }
        let payload = Array(datagram.payload)
        if payload.count >= 2 {
            let channel = DJIUDPFraming.read16(payload, at: 0)
            if channel != 0 { cameraChannel = channel; hasObservedPeerChannel = true }
        }
        if datagram.header.sequence != 0 {
            switch type {
            case .video: receivedVideoSequence = datagram.header.sequence; hasReceivedVideo = true
            case .channel3: receivedChannel3Sequence = datagram.header.sequence; hasReceivedChannel3 = true
            default: break
            }
        }
        if type == .status {
            let video = DJIUDPFraming.read16(payload, at: 2)
            let channel3 = DJIUDPFraming.read16(payload, at: 10)
            let ack = DJIUDPFraming.read16(payload, at: 16)
            if !hasReceivedVideo && video != 0 { receivedVideoSequence = video }
            if !hasReceivedChannel3 && channel3 != 0 { receivedChannel3Sequence = channel3 }
            if ack != 0 { peerAcknowledgedTransmitSequence = ack }
        }
        return .accepted(type)
    }
    public func acknowledgmentPacket() throws -> Data {
        try DJIUDPFraming.encode(packetType: .acknowledgment,
            payload: DJIUDPFraming.acknowledgmentPayload(receivedVideoSequence: receivedVideoSequence,
                receivedChannel3Sequence: receivedChannel3Sequence, peerAcknowledgedTransmitSequence: peerAcknowledgedTransmitSequence,
                lastTransmitSequence: lastTransmitSequence), sessionID: sessionID, sequence: 0)
    }
}
