import Foundation
import CryptoKit

public enum BluetoothFocusPointRecordingEnd: String, Codable, Sendable {
    case windowElapsed, sampleLimit, cancelled, connectionChanged, invalidClock, finishedEarly, failed
}

/// Historical samples keep their original host timestamps; requesting this
/// report cannot refresh a sample or confirm a setting/optical AF operation.
public struct BluetoothFocusPointRecording: Codable, Sendable {
    public let sessionID: UUID
    public let peripheralID: UUID
    public let querySequence: UInt16
    public let subscriptionTransactionID: UInt32
    public let startedUptime: TimeInterval
    public let submittedUptime: TimeInterval?
    public let finishedUptime: TimeInterval?
    public let end: BluetoothFocusPointRecordingEnd?
    public let failureCode: String?
    public let ackHeader: BluetoothDUMLHeader?
    public let ackUptime: TimeInterval?
    public let acceptedPropertyCount: Int
    public let invalidCandidateCount: Int
    public let observations: [BluetoothFocusPointObservation]
}

/// No transport, timers, discovery, setters or retry. A future session owner
/// may submit the existing subscription once and feed CRC-validated packets.
/// At most 64 distinct named pushes, including invalid candidates, are admitted
/// over 12 seconds. Other properties/credentials are never stored or exported.
public struct BluetoothFocusPointRecorder: Sendable {
    public static let maximumDuration: TimeInterval = 12
    public static let maximumProperties = 64
    public let sessionID: UUID
    public let peripheralID: UUID
    public let querySequence: UInt16
    public let subscriptionTransactionID: UInt32
    private let startedUptime: TimeInterval
    private var submittedUptime: TimeInterval?
    private var finishedUptime: TimeInterval?
    private var ending: BluetoothFocusPointRecordingEnd?
    private var failureCode: String?
    private var ackHeader: BluetoothDUMLHeader?
    private var ackUptime: TimeInterval?
    private var acceptedPropertyCount = 0
    private var invalidCandidateCount = 0
    private var observations: [BluetoothFocusPointObservation] = []
    private var fingerprints = Set<Data>()
    private var lastSequence: UInt16?
    private var lastEventUptime: TimeInterval?
    private var latestObservation: BluetoothFocusPointObservation?

    public init(sessionID: UUID, peripheralID: UUID, sequence: UInt16,
                transactionID: UInt32, startedUptime: TimeInterval) throws {
        guard Self.validTime(startedUptime) else { throw CameraSettingsError.invalidTime }
        self.sessionID = sessionID; self.peripheralID = peripheralID; querySequence = sequence
        subscriptionTransactionID = transactionID; self.startedUptime = startedUptime
    }

    public var request: DUMLFrame {
        CameraPropertyCodec.subscription(.lensState, transactionID: subscriptionTransactionID, sequence: querySequence)
    }

    /// Call only in the transport's final connection/operation permit, directly
    /// before its single local write. This pure type never sends the request.
    public mutating func submitted(at uptime: TimeInterval) throws {
        guard submittedUptime == nil, ending == nil, Self.validTime(uptime), uptime >= startedUptime else {
            throw BridgeFailure("focus_recording_submission", "The lens subscription may be submitted only once in its recording window")
        }
        submittedUptime = uptime; lastEventUptime = uptime
    }

    @discardableResult
    public mutating func receive(_ packet: ValidatedDUMLPacket, characteristic: String,
        sessionID: UUID, peripheralID: UUID, paired: Bool, hostReceivedAt: Date, uptime: TimeInterval) -> Bool {
        guard ending == nil, let submittedUptime, paired,
              self.sessionID == sessionID, self.peripheralID == peripheralID,
              characteristic == "FFF4" || characteristic == "FFF5" else { return false }
        let frame = packet.frame
        guard frame.source == 0x28, frame.destination == 2, frame.commandSet == 0,
              frame.commandID == 0x99 else { return false }
        guard Self.validTime(uptime), uptime >= (lastEventUptime ?? submittedUptime),
              hostReceivedAt.timeIntervalSinceReferenceDate.isFinite else {
            _ = finish(at: lastEventUptime ?? submittedUptime, reason: .invalidClock)
            return false
        }
        guard uptime <= submittedUptime + Self.maximumDuration else {
            _ = finish(at: uptime)
            return false
        }
        if ackHeader == nil, frame.sequence == querySequence, frame.flags == 0x80 || frame.flags == 0xc0 {
            ackHeader = BluetoothDUMLHeader(direction: "received", characteristic: characteristic,
                source: frame.source, destination: frame.destination, sequence: frame.sequence,
                flags: frame.flags, commandSet: frame.commandSet, commandID: frame.commandID)
            ackUptime = uptime; lastEventUptime = uptime
            return false // An ACK with a named-looking payload is still not a push.
        }
        guard frame.flags == 0, let push = try? CameraPropertyCodec.decodePush(from: frame),
              push.property == .lensState else { return false }
        let fingerprint = Data(SHA256.hash(data: packet.frameData))
        guard !fingerprints.contains(fingerprint) else { return false }
        if let previous = lastSequence {
            let distance = frame.sequence &- previous
            guard (distance > 0 && distance < 0x8000),
                  uptime > (lastEventUptime ?? submittedUptime) else { return false }
        }
        fingerprints.insert(fingerprint); lastSequence = frame.sequence; lastEventUptime = uptime
        acceptedPropertyCount += 1
        if let candidate = LensPointCandidate.decode(push.value) {
            let observation = BluetoothFocusPointObservation(sessionID: sessionID, peripheralID: peripheralID,
                sequence: frame.sequence, propertyTransactionID: push.transactionID, candidate: candidate,
                hostReceivedAt: hostReceivedAt, receivedUptime: uptime)
            observations.append(observation); latestObservation = observation
        } else {
            invalidCandidateCount += 1
            // Do not present the previous point as the current valid value
            // after a newer lens push explicitly has no valid candidate.
            latestObservation = nil
        }
        if acceptedPropertyCount == Self.maximumProperties { _ = finish(at: uptime, reason: .sampleLimit) }
        return true
    }

    public func latest(sessionID: UUID, peripheralID: UUID?, paired: Bool,
                       nowUptime: TimeInterval) -> BluetoothFocusPointObservation? {
        guard ending != .cancelled, ending != .connectionChanged, ending != .invalidClock, ending != .failed,
              let latestObservation,
              latestObservation.isFresh(sessionID: sessionID, peripheralID: peripheralID,
                                        paired: paired, nowUptime: nowUptime) else { return nil }
        return latestObservation
    }

    @discardableResult
    public mutating func finish(at uptime: TimeInterval,
                               reason: BluetoothFocusPointRecordingEnd? = nil,
                               failureCode: String? = nil) -> BluetoothFocusPointRecording {
        guard ending == nil else { return result }
        self.failureCode = failureCode.map { String($0.prefix(128)) }
        let last = lastEventUptime ?? startedUptime
        guard Self.validTime(uptime), uptime >= last else {
            ending = .invalidClock; finishedUptime = last
            return result
        }
        finishedUptime = uptime
        let elapsed = submittedUptime.map { uptime - $0 >= Self.maximumDuration } == true
        if reason == .sampleLimit, acceptedPropertyCount < Self.maximumProperties { ending = .finishedEarly }
        else if reason == .windowElapsed, !elapsed { ending = .finishedEarly }
        else { ending = reason ?? (elapsed ? .windowElapsed : .finishedEarly) }
        return result
    }

    public var result: BluetoothFocusPointRecording {
        BluetoothFocusPointRecording(sessionID: sessionID, peripheralID: peripheralID,
            querySequence: querySequence, subscriptionTransactionID: subscriptionTransactionID,
            startedUptime: startedUptime, submittedUptime: submittedUptime, finishedUptime: finishedUptime,
            end: ending, failureCode: failureCode, ackHeader: ackHeader, ackUptime: ackUptime,
            acceptedPropertyCount: acceptedPropertyCount, invalidCandidateCount: invalidCandidateCount,
            observations: observations)
    }

    private static func validTime(_ value: TimeInterval) -> Bool {
        value.isFinite && value >= 0 && (value + maximumDuration).isFinite && value + maximumDuration > value
    }
}
