import Foundation
import CryptoKit

/// The bounded result of a passive camera-domain notification window.
///
/// These events preserve wire values for offline protocol discovery. They are
/// deliberately not tracking states, success signals, or camera images.
public struct BluetoothCameraEvent: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let peripheralID: UUID
    public let receivedAt: Date
    public let receivedUptime: TimeInterval
    public let sequence: UInt16
    public let commandID: UInt8
    public let payloadLength: Int
    public let payloadHex: String

    public init(sessionID: UUID, peripheralID: UUID, receivedAt: Date,
                receivedUptime: TimeInterval, sequence: UInt16, commandID: UInt8,
                payloadLength: Int, payloadHex: String) {
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.receivedAt = receivedAt
        self.receivedUptime = receivedUptime
        self.sequence = sequence
        self.commandID = commandID
        self.payloadLength = payloadLength
        self.payloadHex = payloadHex
    }
}

public enum BluetoothCameraEventRecordingEnd: String, Codable, Sendable {
    case windowElapsed
    case sampleLimit
    case cancelled
    case connectionChanged
    case invalidClock
    case finishedEarly
    case failed
}

/// Serializable evidence from one explicitly selected BLE session. The
/// recorder never stores raw frames, credentials, or images after making each
/// bounded event value.
public struct BluetoothCameraEventRecording: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let peripheralID: UUID
    public let startedUptime: TimeInterval
    public let finishedUptime: TimeInterval?
    public let end: BluetoothCameraEventRecordingEnd?
    public let failureCode: String?
    public let acceptedSampleCount: Int
    public let rejectedFrameCount: Int
    public let events: [BluetoothCameraEvent]

    public init(sessionID: UUID, peripheralID: UUID, startedUptime: TimeInterval,
                finishedUptime: TimeInterval?, end: BluetoothCameraEventRecordingEnd?,
                failureCode: String?, acceptedSampleCount: Int,
                rejectedFrameCount: Int, events: [BluetoothCameraEvent]) {
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.startedUptime = startedUptime
        self.finishedUptime = finishedUptime
        self.end = end
        self.failureCode = failureCode
        self.acceptedSampleCount = acceptedSampleCount
        self.rejectedFrameCount = rejectedFrameCount
        self.events = events
    }
}

/// A strict CLI/RPC contract for the passive recorder. It cannot fall back to
/// whichever BLE peer happens to be selected when the request arrives.
public struct BluetoothCameraEventRecordingRequest: Sendable, Equatable {
    public static let operation = "validation-wireless-camera-events"

    public let expectedSessionID: UUID
    public let peripheralID: UUID

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys) == ["expectedSessionID", "peripheralID"],
              let sessionText = fields["expectedSessionID"]?.string,
              let peripheralText = fields["peripheralID"]?.string,
              let session = UUID(uuidString: sessionText),
              let peripheral = UUID(uuidString: peripheralText) else {
            throw BridgeFailure("invalid_camera_event_recording_request",
                "Pass the exact Bluetooth session and peripheral UUIDs; no other arguments are accepted")
        }
        expectedSessionID = session
        peripheralID = peripheral
    }

    public init(cliArguments: [String]) throws {
        guard cliArguments.count == 4 else {
            throw BridgeFailure("usage",
                "pocket3 validation-wireless-camera-events --session BLE-SESSION-UUID --peripheral PERIPHERAL-UUID")
        }
        var fields: [String: JSONValue] = [:]
        for index in stride(from: 0, to: cliArguments.count, by: 2) {
            let key: String
            switch cliArguments[index] {
            case "--session": key = "expectedSessionID"
            case "--peripheral": key = "peripheralID"
            default:
                throw BridgeFailure("usage", "Only --session and --peripheral are accepted for camera event recording")
            }
            guard fields[key] == nil else {
                throw BridgeFailure("usage", "Duplicate camera event recording option")
            }
            fields[key] = .string(cliArguments[index + 1])
        }
        try self.init(arguments: .object(fields))
    }

    public var arguments: JSONValue {
        .object(["expectedSessionID": .string(expectedSessionID.uuidString),
                 "peripheralID": .string(peripheralID.uuidString)])
    }
}

/// A compatibility spelling for callers that name the feature after the
/// recorder instead of the recording report.
public typealias BluetoothCameraEventRecorderRequest = BluetoothCameraEventRecordingRequest

/// Sequence admission is independent from packet payload interpretation. A
/// 16-bit cursor accepts forward progress, including a normal wrap, and
/// rejects duplicate, reordered, and ambiguous half-range values.
public struct BluetoothCameraEventSequenceAdmission: Sendable, Equatable {
    public private(set) var lastAcceptedSequence: UInt16?

    public init(baselineSequence: UInt16? = nil) {
        lastAcceptedSequence = baselineSequence
    }

    public mutating func accept(_ sequence: UInt16) -> Bool {
        if let previous = lastAcceptedSequence {
            let distance = sequence &- previous
            guard distance > 0, distance < 0x8000 else { return false }
        }
        lastAcceptedSequence = sequence
        return true
    }
}

/// Pure admission for already-decoded, CRC-valid DUML packets. The recorder
/// intentionally does not offer a Data/DUMLFrame entry point: callers must
/// obtain a `ValidatedDUMLPacket` from the current BLE transport decoder.
public enum BluetoothCameraEventParser {
    public static let maximumPayloadBytes = 128

    public static func parse(_ packet: ValidatedDUMLPacket, sessionID: UUID,
                             peripheralID: UUID, receivedAt: Date,
                             receivedUptime: TimeInterval) -> BluetoothCameraEvent? {
        let frame = packet.frame
        guard frame.source == 0x01, frame.destination == 0x02,
              frame.commandSet == 0x02, frame.flags == 0,
              frame.payload.count <= maximumPayloadBytes,
              receivedAt.timeIntervalSinceReferenceDate.isFinite,
              receivedUptime.isFinite, receivedUptime >= 0 else { return nil }
        return BluetoothCameraEvent(sessionID: sessionID, peripheralID: peripheralID,
            receivedAt: receivedAt, receivedUptime: receivedUptime,
            sequence: frame.sequence, commandID: frame.commandID,
            payloadLength: frame.payload.count,
            payloadHex: frame.payload.map { String(format: "%02x", $0) }.joined())
    }
}

/// Bounded passive event recorder for a single paired BLE connection. It has
/// no transport, timer, pairing, subscription, write, retry, Wi-Fi, USB, or
/// tracking interpretation responsibilities. Its owner supplies already
/// decoded packets and owns the lifetime/cancellation of the BLE operation.
public struct BluetoothCameraEventRecorder: Sendable {
    public static let maximumDuration: TimeInterval = 20
    public static let maximumSamples = 512
    public static let maximumPayloadBytes = BluetoothCameraEventParser.maximumPayloadBytes

    public let sessionID: UUID
    public let peripheralID: UUID
    private let startedUptime: TimeInterval
    private var finishedUptime: TimeInterval?
    private var ending: BluetoothCameraEventRecordingEnd?
    private var failureCode: String?
    private var events: [BluetoothCameraEvent] = []
    private var rejectedFrameCount = 0
    private var fingerprints = Set<Data>()
    private var sequenceAdmissions: [UInt8: BluetoothCameraEventSequenceAdmission] = [:]
    private var lastEventUptime: TimeInterval?

    public init(sessionID: UUID, peripheralID: UUID, startedUptime: TimeInterval,
                baselineCommandID: UInt8 = 0x89, baselineSequence: UInt16? = nil) throws {
        guard Self.validTime(startedUptime) else { throw CameraSettingsError.invalidTime }
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.startedUptime = startedUptime
        if let baselineSequence {
            sequenceAdmissions[baselineCommandID] = BluetoothCameraEventSequenceAdmission(baselineSequence: baselineSequence)
        }
    }

    /// Accepts only packets from the exact paired session/peripheral. The
    /// optional characteristic label allows transport owners to enforce the
    /// two current notification channels without making pure tests depend on
    /// CoreBluetooth objects.
    @discardableResult
    public mutating func receive(_ packet: ValidatedDUMLPacket, characteristic: String? = nil,
                                 sessionID: UUID, peripheralID: UUID, paired: Bool,
                                 hostReceivedAt: Date, uptime: TimeInterval) -> Bool {
        guard ending == nil, paired,
              self.sessionID == sessionID, self.peripheralID == peripheralID,
              characteristic.map({ $0 == "FFF4" || $0 == "FFF5" }) != false else { return false }
        guard Self.validTime(uptime), uptime >= (lastEventUptime ?? startedUptime),
              hostReceivedAt.timeIntervalSinceReferenceDate.isFinite else {
            rejectedFrameCount += 1
            _ = finish(at: lastEventUptime ?? startedUptime, reason: .invalidClock)
            return false
        }
        let deadline = startedUptime + Self.maximumDuration
        guard uptime <= deadline else {
            _ = finish(at: min(uptime, deadline), reason: .windowElapsed)
            return false
        }
        guard let event = BluetoothCameraEventParser.parse(packet, sessionID: sessionID,
                peripheralID: peripheralID, receivedAt: hostReceivedAt,
                receivedUptime: uptime) else {
            rejectedFrameCount += 1
            return false
        }
        // Exact frame fingerprints catch replayed notifications even if a
        // future transport emits a frame with an unexpected sequence value.
        let fingerprint = Data(SHA256.hash(data: packet.frameData))
        var admission = sequenceAdmissions[event.commandID] ?? BluetoothCameraEventSequenceAdmission()
        guard !fingerprints.contains(fingerprint), admission.accept(event.sequence) else {
            rejectedFrameCount += 1
            return false
        }
        fingerprints.insert(fingerprint)
        sequenceAdmissions[event.commandID] = admission
        events.append(event)
        lastEventUptime = uptime
        if events.count == Self.maximumSamples {
            _ = finish(at: uptime, reason: .sampleLimit)
        }
        return true
    }

    /// Finishes the window without touching the BLE transport.
    @discardableResult
    public mutating func finish(at uptime: TimeInterval,
                                reason: BluetoothCameraEventRecordingEnd? = nil,
                                failureCode: String? = nil) -> BluetoothCameraEventRecording {
        guard ending == nil else { return result }
        self.failureCode = failureCode.map { String($0.prefix(128)) }
        let last = lastEventUptime ?? startedUptime
        guard Self.validTime(uptime), uptime >= last else {
            ending = .invalidClock
            finishedUptime = last
            return result
        }
        finishedUptime = uptime
        let elapsed = uptime - startedUptime >= Self.maximumDuration
        if reason == .sampleLimit, events.count < Self.maximumSamples {
            ending = .finishedEarly
        } else if reason == .windowElapsed, !elapsed {
            ending = .finishedEarly
        } else {
            ending = reason ?? (elapsed ? .windowElapsed : .finishedEarly)
        }
        return result
    }

    public var result: BluetoothCameraEventRecording {
        BluetoothCameraEventRecording(sessionID: sessionID, peripheralID: peripheralID,
            startedUptime: startedUptime, finishedUptime: finishedUptime,
            end: ending, failureCode: failureCode,
            acceptedSampleCount: events.count, rejectedFrameCount: rejectedFrameCount,
            events: events)
    }

    private static func validTime(_ value: TimeInterval) -> Bool {
        value.isFinite && value >= 0 &&
            (value + maximumDuration).isFinite && value + maximumDuration > value
    }
}
