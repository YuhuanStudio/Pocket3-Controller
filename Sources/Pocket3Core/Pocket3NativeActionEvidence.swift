import Foundation

/// Evidence levels for a native candidate command.  These values describe
/// what the owner observed; they do not claim that the camera supports the
/// action or that an ACK caused a physical change.
public enum Pocket3NativeActionEvidenceLevel: String, Codable, Sendable,
    Equatable, CaseIterable {
    case notAttempted
    case noCorrelatedReply
    case commandRejected
    case acknowledgedNoPhysicalEvidence
    case physicalEvidenceWithoutReply
    case physicalEvidence
    case invalidReply
    case cancelled
    case connectionChanged
}

/// Bounded evidence for one candidate command.  The expected command set,
/// command ID and payload are retained so a missing reply can be distinguished
/// from a correlated NACK or an ACK with no physical/readback evidence.
public struct Pocket3NativeActionEvidenceReport: Codable, Sendable,
    Equatable {
    public let commandSet: UInt8
    public let commandID: UInt8
    public let requestPayload: Data
    public let submitted: Bool
    public let responseReceived: Bool
    public let responseStatusRaw: UInt8?
    public let acknowledged: Bool
    public let readbackObserved: Bool
    public let physicalEvidence: Bool
    public let level: Pocket3NativeActionEvidenceLevel

    public init(commandSet: UInt8, commandID: UInt8, requestPayload: Data,
                submitted: Bool = false, responseReceived: Bool = false,
                responseStatusRaw: UInt8? = nil, acknowledged: Bool = false,
                readbackObserved: Bool = false,
                physicalEvidence: Bool = false,
                cancelled: Bool = false,
                connectionChanged: Bool = false,
                level: Pocket3NativeActionEvidenceLevel? = nil) {
        self.commandSet = commandSet
        self.commandID = commandID
        self.requestPayload = requestPayload
        self.submitted = submitted
        self.responseReceived = responseReceived
        self.responseStatusRaw = responseStatusRaw
        self.acknowledged = acknowledged
        self.readbackObserved = readbackObserved
        self.physicalEvidence = physicalEvidence
        self.level = level ?? Self.classify(
            submitted: submitted, responseReceived: responseReceived,
            responseStatusRaw: responseStatusRaw,
            acknowledged: acknowledged, physicalEvidence: physicalEvidence,
            cancelled: cancelled, connectionChanged: connectionChanged)
    }

    /// Candidate evidence for a reviewed FE08/FE09 shortcut. Constructing
    /// this value is inspection only and never submits the frame.
    public init(shortcut: Pocket3GimbalShortcut) {
        self.init(commandSet: Pocket3GimbalShortcut.commandSet,
                  commandID: Pocket3GimbalShortcut.commandID,
                  requestPayload: shortcut.payload)
    }

    public var commandAccepted: Bool? {
        guard responseReceived else { return nil }
        return acknowledged
    }

    /// `true` means the response reached the expected command envelope; it is
    /// intentionally independent from physical completion.
    public var transportReached: Bool? {
        switch level {
        case .commandRejected, .acknowledgedNoPhysicalEvidence,
             .physicalEvidence, .invalidReply:
            return responseReceived
        case .physicalEvidenceWithoutReply:
            return nil
        case .notAttempted, .noCorrelatedReply, .cancelled,
             .connectionChanged:
            return nil
        }
    }

    /// Classifies only the supplied evidence. A missing reply is not promoted
    /// to “unsupported”; callers can report `noCorrelatedReply` and retain the
    /// transport distinction for a later, separately authorized probe.
    public static func classify(
        submitted: Bool,
        responseReceived: Bool,
        responseStatusRaw: UInt8?,
        acknowledged: Bool,
        physicalEvidence: Bool,
        cancelled: Bool = false,
        connectionChanged: Bool = false
    ) -> Pocket3NativeActionEvidenceLevel {
        if connectionChanged { return .connectionChanged }
        if cancelled { return .cancelled }
        guard submitted else { return .notAttempted }
        if !responseReceived {
            return physicalEvidence ? .physicalEvidenceWithoutReply
                : .noCorrelatedReply
        }
        guard let responseStatusRaw else { return .invalidReply }
        guard acknowledged, responseStatusRaw == 0 else {
            return .commandRejected
        }
        return physicalEvidence ? .physicalEvidence
            : .acknowledgedNoPhysicalEvidence
    }

    public static func summarize(
        _ reports: [Pocket3NativeActionEvidenceReport]
    ) -> Pocket3NativeActionEvidenceLevel {
        guard !reports.isEmpty else { return .notAttempted }
        if reports.contains(where: { $0.level == .connectionChanged }) {
            return .connectionChanged
        }
        if reports.contains(where: { $0.level == .cancelled }) {
            return .cancelled
        }
        if reports.contains(where: { $0.level == .commandRejected }) {
            return .commandRejected
        }
        if reports.contains(where: { $0.level == .invalidReply }) {
            return .invalidReply
        }
        if reports.contains(where: { $0.level == .noCorrelatedReply }) {
            return .noCorrelatedReply
        }
        if reports.contains(where: { $0.level == .physicalEvidence }) {
            return .physicalEvidence
        }
        if reports.contains(where: {
            $0.level == .physicalEvidenceWithoutReply
        }) {
            return .physicalEvidenceWithoutReply
        }
        if reports.contains(where: {
            $0.level == .acknowledgedNoPhysicalEvidence
        }) {
            return .acknowledgedNoPhysicalEvidence
        }
        return .notAttempted
    }
}

/// The existing FE08 probe has no FE09 executor. This API exposes both
/// reviewed native shortcut envelopes for offline validation without making
/// either one writable from the general UI.
public enum Pocket3NativeGimbalShortcutEvidence {
    public static func candidate(
        _ shortcut: Pocket3GimbalShortcut
    ) -> Pocket3NativeActionEvidenceReport {
        Pocket3NativeActionEvidenceReport(shortcut: shortcut)
    }

    public static func decodeCandidate(
        _ frame: DUMLFrame
    ) -> Pocket3GimbalShortcut? {
        guard frame.source == Pocket3GimbalShortcut.source,
              frame.destination == Pocket3GimbalShortcut.destination,
              frame.commandSet == Pocket3GimbalShortcut.commandSet,
              frame.commandID == Pocket3GimbalShortcut.commandID else {
            return nil
        }
        switch Pocket3GimbalShortcutPayload.decode(frame.payload) {
        case .recenter: return .recenter
        case .flip: return .flip
        case .unknown, nil: return nil
        }
    }
}

public typealias Pocket3NativeCommandEvidence = Pocket3NativeActionEvidenceReport
public typealias Pocket3NativeEvidenceLevel = Pocket3NativeActionEvidenceLevel
