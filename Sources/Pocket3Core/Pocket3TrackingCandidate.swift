import Foundation

/// Passive evidence for command IDs used by a newer Osmo implementation for
/// subject tracking. These bytes are not yet identified as Pocket 3 tracking
/// and never become a public tracking state or motor command by themselves.
public struct Pocket3TrackingCandidateFrame: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let peripheralID: UUID
    public let receivedAt: Date
    public let receivedUptime: TimeInterval
    public let commandID: UInt8
    public let payloadLength: Int
    public let payloadHex: String
    public let evidence: String

    public init(sessionID: UUID, peripheralID: UUID, receivedAt: Date,
                receivedUptime: TimeInterval, commandID: UInt8, payloadLength: Int,
                payloadHex: String,
                evidence: String = "cross_model_passive_candidate_unverified_on_pocket3") {
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.receivedAt = receivedAt
        self.receivedUptime = receivedUptime
        self.commandID = commandID
        self.payloadLength = payloadLength
        self.payloadHex = payloadHex
        self.evidence = evidence
    }
}

public enum Pocket3TrackingCandidateParser {
    public static let candidateCommandIDs: Set<UInt8> = [0x89, 0xA5, 0xA6]
    public static let maximumPayloadBytes = 64

    public static func parse(_ frame: DUMLFrame, sessionID: UUID, peripheralID: UUID,
                             receivedAt: Date, receivedUptime: TimeInterval) -> Pocket3TrackingCandidateFrame? {
        guard frame.source == 0x01, frame.destination == 0x02, frame.flags == 0,
              frame.commandSet == 0x02, candidateCommandIDs.contains(frame.commandID),
              !frame.payload.isEmpty, frame.payload.count <= maximumPayloadBytes,
              receivedUptime.isFinite, receivedUptime >= 0 else { return nil }
        return .init(sessionID: sessionID, peripheralID: peripheralID,
            receivedAt: receivedAt, receivedUptime: receivedUptime,
            commandID: frame.commandID, payloadLength: frame.payload.count,
            payloadHex: frame.payload.map { String(format: "%02x", $0) }.joined())
    }
}
