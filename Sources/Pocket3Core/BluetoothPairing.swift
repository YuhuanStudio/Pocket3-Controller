import Foundation

public enum BluetoothPairingPhase: String, Codable, Sendable {
    case idle, arming, waking, awaitingPairingReply, awaitingApproval
    case paired, retrievingCredentials, credentialsReady, failed, cancelled
}
public enum BluetoothCredentialReplyClassification: String, Codable, Sendable {
    case accepted, missingStatus, statusFailure, missingLength, emptyValue
    case lengthExceedsMaximum, truncated, invalidUTF8, controlCharacters
}
/// Only shape/status diagnostics. No payload, string, or declared secret length.
public struct BluetoothCredentialReplyDiagnostic: Codable, Sendable {
    public let classification: BluetoothCredentialReplyClassification
    public let payloadByteCount: Int
    public let statusSucceeded: Bool?
    public let hasLengthField: Bool
    public let declaredLengthFits: Bool?
    public let declaredLengthAllowed: Bool?
}
public struct BluetoothPairingStatus: Codable, Sendable {
    public let phase: BluetoothPairingPhase
    public let peerReportedPaired: Bool
    public let credentialsAvailable: Bool
    public let issueCode: String?
    public var credentialAccessFailed = false
    public var ssidReply: BluetoothCredentialReplyDiagnostic?
    public var passwordReply: BluetoothCredentialReplyDiagnostic?
}

/// Delivered only through the explicit credential callback, never status/JSON.
public struct BluetoothWiFiCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let ssid: String
    public let password: String
    public let sessionID: UUID
    public let peripheralID: UUID
    public var description: String { "BluetoothWiFiCredentials(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["credentials": "<redacted>"]) }
}
public struct BluetoothBatteryObservation: Codable, Sendable {
    public let sessionID: UUID
    public let peripheralID: UUID
    public let telemetry: Pocket3BatteryTelemetry
}

enum BluetoothBatteryTelemetryParser {
    static func parse(_ frame: DUMLFrame, receivedAt: Date) -> Pocket3BatteryTelemetry? {
        // Actual BLE header observed in ble-pair-first-failure.json. Command
        // set 0D does not imply that the DUML source address is also 0D.
        guard frame.source == 0x05, frame.destination == 0x02 else { return nil }
        return Pocket3TelemetryParser.battery(from: frame, source: .bluetooth, receivedAt: receivedAt)
    }
}

/// Independently encoded protocol constants from Kaze for DJI revision
/// 341a35de18493ff61f97c93b8b10161a7512aa36, Pocket3Commands.swift.
enum BluetoothPairingCommands {
    static func request(set: UInt8, command: UInt8, destination: UInt8, sequence: UInt16, payload: Data = Data()) -> DUMLFrame {
        DUMLFrame(source: 2, destination: destination, sequence: sequence, flags: 0x40,
            commandSet: set, commandID: command, payload: payload)
    }
    static func pairing(identifier: String, sequence: UInt16) throws -> DUMLFrame {
        guard identifier.utf8.count == 32, identifier.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
            throw BridgeFailure("bluetooth_client_identifier", "Use a persistent 32-character hexadecimal application identifier.")
        }
        var payload = Data([32]); payload.append(contentsOf: identifier.utf8)
        payload.append(contentsOf: [4, 0x6f, 0x73, 0x6d, 0x6f])
        return request(set: 7, command: 0x45, destination: 7, sequence: sequence, payload: payload)
    }
    static var applicationInfo: Data {
        var data = Data(repeating: 0, count: 62)
        data[1] = 0x41; data[2] = 0x50; data[3] = 0x50
        data[41] = 2; data[50] = 2; data[51] = 8
        return data
    }
    static func acknowledgment(_ frame: DUMLFrame) -> DUMLFrame? {
        guard frame.flags == 0x40, frame.destination == 2 else { return nil }
        // Observed on the selected Pocket 3, firmware 01.06.10.04:
        // source 0x48 asks app endpoint 0x02 for 00/81 registration. This is
        // an exact addition, not permission to ACK other 0x48 commands.
        let observedRegistration = frame.source == 0x48 && frame.commandSet == 0 && frame.commandID == 0x81
        let knownRouting = [UInt8(7), 0xf0, 0x1c].contains(frame.source)
            && [UInt8(0), 7, 0x53].contains(frame.commandSet)
        guard observedRegistration || knownRouting else { return nil }
        return DUMLFrame(source: frame.destination, destination: frame.source, sequence: frame.sequence,
            flags: 0xc0, commandSet: frame.commandSet, commandID: frame.commandID,
            payload: frame.commandSet == 0 && frame.commandID == 0x81 ? applicationInfo : frame.payload)
    }
    static func packedString(_ payload: Data, maximumBytes: Int) -> String? {
        inspectPackedString(payload, maximumBytes: maximumBytes).value
    }
    static func inspectPackedString(_ payload: Data, maximumBytes: Int) -> (value: String?, diagnostic: BluetoothCredentialReplyDiagnostic) {
        let bytes = Array(payload)
        let hasLength = bytes.count >= 2
        let statusSucceeded = bytes.first.map { $0 == 0 }
        let fits: Bool? = hasLength ? bytes.count >= Int(bytes[1]) + 2 : nil
        let allowed: Bool? = hasLength ? bytes[1] > 0 && Int(bytes[1]) <= maximumBytes : nil
        func result(_ classification: BluetoothCredentialReplyClassification, value: String? = nil) -> (String?, BluetoothCredentialReplyDiagnostic) {
            (value, BluetoothCredentialReplyDiagnostic(classification: classification,
                payloadByteCount: bytes.count, statusSucceeded: statusSucceeded,
                hasLengthField: hasLength, declaredLengthFits: fits, declaredLengthAllowed: allowed))
        }
        guard !bytes.isEmpty else { return result(.missingStatus) }
        guard statusSucceeded == true else { return result(.statusFailure) }
        guard hasLength else { return result(.missingLength) }
        let count = Int(bytes[1])
        guard count > 0 else { return result(.emptyValue) }
        guard allowed == true else { return result(.lengthExceedsMaximum) }
        guard fits == true else { return result(.truncated) }
        guard let value = String(bytes: bytes[2..<(count + 2)], encoding: .utf8) else { return result(.invalidUTF8) }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return result(.controlCharacters) }
        return result(.accepted, value: value)
    }
}

struct BluetoothPairingUpdate {
    var acknowledgment: DUMLFrame?
    var confirmedPairing = false
    var credentials: (ssid: String, password: String)?
}

/// Pure per-GATT-session workflow. It never scans, sends bytes, or persists secrets.
struct BluetoothPairingSession: Sendable {
    private(set) var phase: BluetoothPairingPhase = .arming
    private(set) var paired = false
    private var peerReportedPaired = false
    private var credentialAccessFailed = false
    private(set) var credentialsAvailable = false
    private(set) var issueCode: String?
    private let identifier: String
    private let pairOnly: Bool
    private var sequence: UInt16
    private var pairSequence: UInt16?
    private var ssidSequence: UInt16?
    private var passwordSequence: UInt16?
    private var ssid: String?
    private var password: String?
    private var ssidDiagnostic: BluetoothCredentialReplyDiagnostic?
    private var passwordDiagnostic: BluetoothCredentialReplyDiagnostic?
    var status: BluetoothPairingStatus {
        .init(phase: phase, peerReportedPaired: peerReportedPaired, credentialsAvailable: credentialsAvailable,
              issueCode: issueCode, credentialAccessFailed: credentialAccessFailed,
              ssidReply: ssidDiagnostic, passwordReply: passwordDiagnostic)
    }
    init(clientIdentifier: String, initialSequence: UInt16, pairOnly: Bool = false) throws {
        _ = try BluetoothPairingCommands.pairing(identifier: clientIdentifier, sequence: initialSequence)
        identifier = clientIdentifier; sequence = initialSequence; self.pairOnly = pairOnly
    }
    private mutating func next() -> UInt16 { defer { sequence &+= 1 }; return sequence }
    mutating func armSucceeded() -> DUMLFrame? {
        guard phase == .arming else { return nil }
        phase = .waking
        return BluetoothPairingCommands.request(set: 0, command: 0x2b, destination: 0xf0,
            sequence: next(), payload: Data([4, 0]))
    }
    mutating func pairingRequest() throws -> DUMLFrame? {
        guard phase == .waking else { return nil }
        let id = next(); pairSequence = id; phase = .awaitingPairingReply
        return try BluetoothPairingCommands.pairing(identifier: identifier, sequence: id)
    }
    mutating func credentialRequests() -> [(delay: TimeInterval, frame: DUMLFrame)] {
        guard paired, phase == .retrievingCredentials, ssidSequence == nil else { return [] }
        let wake = BluetoothPairingCommands.request(set: 0x53, command: 0x10, destination: 0x1c,
            sequence: next(), payload: Data([0, 0, 0, 0]))
        let ssidID = next(), passwordID = next()
        ssidSequence = ssidID; passwordSequence = passwordID
        return [(0.1, wake),
                (0.9, BluetoothPairingCommands.request(set: 7, command: 7, destination: 7, sequence: ssidID)),
                (1.4, BluetoothPairingCommands.request(set: 7, command: 0x0e, destination: 7, sequence: passwordID))]
    }
    mutating func keepalive() -> DUMLFrame? {
        guard paired, [.paired, .retrievingCredentials, .credentialsReady].contains(phase) else { return nil }
        return BluetoothPairingCommands.request(set: 0, command: 0x2b, destination: 0xf0,
            sequence: next(), payload: Data([1, 1]))
    }
    mutating func receive(_ frame: DUMLFrame) -> BluetoothPairingUpdate {
        guard ![.failed, .cancelled, .idle].contains(phase) else { return .init() }
        var update = BluetoothPairingUpdate(acknowledgment: BluetoothPairingCommands.acknowledgment(frame))
        guard frame.source == 7, frame.destination == 2, frame.commandSet == 7 else { return update }
        let response = frame.flags == 0x80 || frame.flags == 0xc0
        if frame.commandID == 0x45, response, frame.sequence == pairSequence,
           [.awaitingPairingReply, .awaitingApproval].contains(phase) {
            let bytes = Array(frame.payload)
            guard bytes.count >= 2, bytes[0] == 0 else { fail("bluetooth_pairing_rejected"); return update }
            switch bytes[1] {
            case 1: confirm(); update.confirmedPairing = true
            case 2: phase = .awaitingApproval
            default: fail("bluetooth_pairing_status_unknown")
            }
        } else if frame.commandID == 0x46,
                  (frame.flags == 0x40 || (response && frame.sequence == pairSequence)),
                  [.awaitingPairingReply, .awaitingApproval].contains(phase) {
            confirm(); update.confirmedPairing = true
        } else if paired, phase == .retrievingCredentials, response {
            if frame.commandID == 7, frame.sequence == ssidSequence {
                let decoded = BluetoothPairingCommands.inspectPackedString(frame.payload, maximumBytes: 32)
                ssidDiagnostic = decoded.diagnostic
                guard let value = decoded.value else { fail("bluetooth_ssid_reply_invalid"); return update }
                ssid = value
            } else if frame.commandID == 0x0e, frame.sequence == passwordSequence {
                let decoded = BluetoothPairingCommands.inspectPackedString(frame.payload, maximumBytes: 64)
                passwordDiagnostic = decoded.diagnostic
                guard let value = decoded.value else { fail("bluetooth_password_reply_invalid"); return update }
                password = value
            }
            if let ssid, let password {
                update.credentials = (ssid, password)
                self.ssid = nil; self.password = nil
                phase = .credentialsReady; credentialsAvailable = true
            }
        }
        return update
    }
    mutating func reserveProbeSequences() -> [UInt16]? {
        guard paired, [.paired, .credentialsReady].contains(phase) else { return nil }
        var values: [UInt16] = []
        for _ in 0..<5 { values.append(next()) }
        return values
    }
    mutating func reserveReadinessSequence() -> UInt16? {
        guard paired, [.paired, .credentialsReady].contains(phase) else { return nil }
        return next()
    }
    private mutating func confirm() { paired = true; peerReportedPaired = true; phase = pairOnly ? .paired : .retrievingCredentials }
    mutating func fail(_ issue: String) {
        if phase == .retrievingCredentials { credentialAccessFailed = true }
        phase = .failed; issueCode = issue; clearSecrets()
    }
    mutating func cancel() { phase = .cancelled; clearSecrets() }
    private mutating func clearSecrets() {
        ssid = nil; password = nil; pairSequence = nil; ssidSequence = nil; passwordSequence = nil
        credentialsAvailable = false; paired = false
    }
}

enum BluetoothWriteQueueError: Error, Equatable { case overflow, expired, invalidMTU }
/// Whole validated frames are queued; fragments from distinct frames never interleave.
struct BluetoothWriteQueue: Sendable {
    static let maximumBytes = 8192
    static let maximumFrames = 64
    static let timeout: TimeInterval = 5
    private struct Entry: Sendable { var data: Data; var offset = 0; let queuedAt: TimeInterval }
    private var entries: [Entry] = []
    private(set) var byteCount = 0
    private(set) var completedFrame: DUMLFrame?
    var isEmpty: Bool { entries.isEmpty }
    mutating func enqueue(_ data: Data, at now: TimeInterval) throws {
        _ = try DUMLCodec.decode(data)
        guard now.isFinite, now >= 0, entries.count < Self.maximumFrames,
              data.count <= Self.maximumBytes - byteCount else { throw BluetoothWriteQueueError.overflow }
        entries.append(Entry(data: Data(Array(data)), queuedAt: now)); byteCount += data.count
    }
    func checkDeadline(at now: TimeInterval) throws {
        guard let first = entries.first else { return }
        guard now.isFinite, now >= first.queuedAt, now - first.queuedAt < Self.timeout else { throw BluetoothWriteQueueError.expired }
    }
    mutating func nextFragment(maximumBytes: Int, at now: TimeInterval) throws -> Data? {
        completedFrame = nil
        guard maximumBytes > 0, maximumBytes <= 65_536 else { throw BluetoothWriteQueueError.invalidMTU }
        try checkDeadline(at: now)
        guard !entries.isEmpty else { return nil }
        let count = min(maximumBytes, entries[0].data.count - entries[0].offset)
        let fragment = Data(entries[0].data[entries[0].offset..<(entries[0].offset + count)])
        entries[0].offset += count; byteCount -= count
        if entries[0].offset == entries[0].data.count {
            completedFrame = try DUMLCodec.decode(entries[0].data)
            entries.removeFirst()
        }
        return fragment
    }
    mutating func reset() { entries.removeAll(keepingCapacity: false); byteCount = 0; completedFrame = nil }
}
