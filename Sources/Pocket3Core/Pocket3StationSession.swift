import Foundation
import CryptoKit

/// The station-mode BLE operations reviewed for Pocket 3.  These frames are
/// only constructed here; a caller must inject an executor for any write.
public enum Pocket3StationBLEOperation: String, Codable, Sendable,
    Equatable, CaseIterable {
    case networkModeProbe = "07/39_probe"
    case enterStationMode = "07/48_enter"
    case joinNetwork = "07/47_join"
    case leaveStationMode = "07/48_leave"

    public var commandID: UInt8 {
        switch self {
        case .networkModeProbe: 0x39
        case .enterStationMode, .leaveStationMode: 0x48
        case .joinNetwork: 0x47
        }
    }
}

public enum Pocket3StationSessionPhase: String, Codable, Sendable,
    Equatable, CaseIterable {
    case idle
    case probingBLEIdentity = "probing_ble_identity"
    case enteringStationMode = "entering_station_mode"
    case joiningNetwork = "joining_network"
    case settling
    case discoveringLAN = "discovering_lan"
    case verifyingLANIdentity = "verifying_lan_identity"
    case commandReady = "command_ready"
    case stopping
    case cleaningUp = "cleaning_up"
    case cleanupDebt = "cleanup_debt"
    case failed
    case cancelled
}

public enum Pocket3StationSessionError: Error, Codable, Sendable,
    Equatable {
    case invalidBinding
    case invalidCredentials
    case invalidHost
    case busy
    case staleBinding
    case unsupportedReply
    case lanIdentityMismatch
    case lanTransportUnavailable
    case lanDiscoveryNoCandidates
    case lanDiscoveryNoTCPHits
    case lanDiscoveryTimeout
    case cleanupRequired
}

/// Credentials are deliberately memory-only.  This type is not Codable or
/// CustomDebugStringConvertible, so station reports, IPC arguments and logs
/// cannot persist a cleartext password by accidentally encoding this value.
public struct Pocket3StationCredentials: Sendable, Equatable {
    public let ssid: String
    public let password: String

    public init(ssid: String, password: String) throws {
        let ssidBytes = Array(ssid.utf8)
        let passwordBytes = Array(password.utf8)
        guard (1...32).contains(ssidBytes.count),
              (1...63).contains(passwordBytes.count),
              Self.safe(ssid, ssidBytes), Self.safe(password, passwordBytes) else {
            throw Pocket3StationSessionError.invalidCredentials
        }
        self.ssid = ssid
        self.password = password
    }

    private static func safe(_ value: String, _ bytes: [UInt8]) -> Bool {
        bytes.allSatisfy { $0 >= 0x20 && $0 != 0x7f }
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}

/// Exact identity digests are kept opaque. Equality is byte-for-byte between
/// the paired BLE identity and the LAN 07/07 identity; no model/serial guess
/// or normalization is applied. Generic `raw` callers must provide their own
/// privacy-safe bytes; station SSIDs use `init(cameraSSID:)` below.
public struct Pocket3StationIdentity: Codable, Sendable, Equatable {
    public let raw: Data
    public let source: String

    public init(raw: Data, source: String) throws {
        guard !raw.isEmpty, raw.count <= 128,
              !source.isEmpty, source.utf8.count <= 64 else {
            throw Pocket3StationSessionError.invalidBinding
        }
        self.raw = raw
        self.source = source
    }

    /// Creates the privacy-safe identity used by station mode.  The camera's
    /// AP SSID is compared in memory by its SHA-256 digest; neither the SSID
    /// nor the 07/07 packed reply is placed in Codable status/evidence.
    public init(cameraSSID: String) throws {
        let bytes = Array(cameraSSID.utf8)
        guard (1...32).contains(bytes.count),
              bytes.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }),
              !cameraSSID.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw Pocket3StationSessionError.invalidCredentials
        }
        try self.init(raw: Data(SHA256.hash(data: Data(bytes))),
                      source: "camera-ssid-sha256")
    }

    public func matches(_ other: Self) -> Bool { raw == other.raw }
}

public struct Pocket3StationSessionBinding: Codable, Sendable, Equatable {
    public let bleSessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let bleIdentity: Pocket3StationIdentity

    public init(bleSessionID: UUID, peripheralID: UUID, generation: UInt64,
                bleIdentity: Pocket3StationIdentity) throws {
        guard generation != 0 else {
            throw Pocket3StationSessionError.invalidBinding
        }
        self.bleSessionID = bleSessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.bleIdentity = bleIdentity
    }
}

/// A command contains the real frame for an injected BLE transport, but is
/// never encoded into the station result.  In particular, the join payload
/// may contain the password and stays inside this in-memory value.
public struct Pocket3StationBLECommand: Sendable, Equatable {
    public let operation: Pocket3StationBLEOperation
    public let frame: DUMLFrame

    init(operation: Pocket3StationBLEOperation, frame: DUMLFrame) {
        self.operation = operation
        self.frame = frame
    }
}

public struct Pocket3StationBLEReply: Sendable, Equatable {
    public let operation: Pocket3StationBLEOperation
    public let sequence: UInt16
    public let payload: Data

    public init(operation: Pocket3StationBLEOperation, sequence: UInt16,
                payload: Data) {
        self.operation = operation
        self.sequence = sequence
        self.payload = payload
    }
}

/// The LAN adapter owns discovery, TCP7001 bootstrap, UDP9004 setup and the
/// 07/07 identity exchange.  This protocol has no concrete network code in
/// this slice; fake implementations make the coordinator testable offline.
public struct Pocket3StationLANEvidence: Codable, Sendable, Equatable {
    public let host: String
    public let tcp7001Connected: Bool
    public let udp9004Connected: Bool
    /// True only after the single existing LAN datalink owner has retained
    /// (or explicitly transferred) TCP/UDP ownership for this binding.
    public let datalinkOwnerRetained: Bool
    public let identity: Pocket3StationIdentity
    public let identityCommand: String
    public let identityRaw: Data
    /// The adapter must set this only after validating the complete 07/07
    /// reply envelope.  Unknown identity bytes remain in `identityRaw`.
    public let identityReplyValidated: Bool
    public let discoveryMode: String
    public let candidatesConsidered: Int
    /// Number of candidates that reached the lightweight TCP stage. The
    /// `candidatesConsidered` value is the number that reached full identity
    /// verification, so a 254-host subnet is never reported as fully probed
    /// when the overall deadline stopped earlier.
    public let tcpCandidatesProbed: Int

    public init(host: String, tcp7001Connected: Bool,
                udp9004Connected: Bool, identity: Pocket3StationIdentity,
                identityRaw: Data, identityCommand: String = "07/07",
                datalinkOwnerRetained: Bool = false,
                identityReplyValidated: Bool = false,
                discoveryMode: String = "explicit_host",
                candidatesConsidered: Int = 1,
                tcpCandidatesProbed: Int? = nil) throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              identityCommand == "07/07", !identityRaw.isEmpty,
              identityRaw.count <= 128,
              !discoveryMode.isEmpty, discoveryMode.utf8.count <= 64,
              (0...256).contains(candidatesConsidered),
              (0...256).contains(tcpCandidatesProbed ??
                (discoveryMode == "explicit_host" ? 0 : candidatesConsidered)) else {
            throw Pocket3StationSessionError.invalidHost
        }
        self.host = host
        self.tcp7001Connected = tcp7001Connected
        self.udp9004Connected = udp9004Connected
        self.datalinkOwnerRetained = datalinkOwnerRetained
        self.identity = identity
        self.identityCommand = identityCommand
        self.identityRaw = identityRaw
        self.identityReplyValidated = identityReplyValidated
        self.discoveryMode = discoveryMode
        self.candidatesConsidered = candidatesConsidered
        self.tcpCandidatesProbed = tcpCandidatesProbed ??
            (discoveryMode == "explicit_host" ? 0 : candidatesConsidered)
    }

    public var transportReady: Bool {
        tcp7001Connected && udp9004Connected && datalinkOwnerRetained
    }
}

public struct Pocket3StationStepEvidence: Codable, Sendable, Equatable {
    public let operation: Pocket3StationBLEOperation
    public let submitted: Bool
    public let responseReceived: Bool
    public let responsePayload: Data?
    public let accepted: Bool
    public let failureCode: String?

    public init(operation: Pocket3StationBLEOperation, submitted: Bool,
                responseReceived: Bool, responsePayload: Data? = nil,
                accepted: Bool, failureCode: String? = nil) {
        self.operation = operation
        self.submitted = submitted
        self.responseReceived = responseReceived
        self.responsePayload = responsePayload.map { Data($0.prefix(128)) }
        self.accepted = accepted
        self.failureCode = failureCode
    }
}

public struct Pocket3StationCleanupDebt: Codable, Sendable, Equatable {
    public let binding: Pocket3StationSessionBinding
    public let reason: String
    public let attempts: Int
    public let retryRequired: Bool

    public init(binding: Pocket3StationSessionBinding, reason: String,
                attempts: Int = 1, retryRequired: Bool = true) {
        self.binding = binding
        self.reason = String(reason.prefix(128))
        self.attempts = max(1, attempts)
        self.retryRequired = retryRequired
    }
}

/// Cleanup debt contains only opaque identity/session metadata.  An App can
/// inject a durable implementation; no credential-bearing value is accepted
/// by this protocol.
public protocol Pocket3StationCleanupDebtStore: Sendable {
    func load() async -> Pocket3StationCleanupDebt?
    func save(_ debt: Pocket3StationCleanupDebt) async
    func clear(_ debt: Pocket3StationCleanupDebt) async
}

public actor Pocket3StationInMemoryCleanupDebtStore:
    Pocket3StationCleanupDebtStore {
    private var value: Pocket3StationCleanupDebt?

    public init(initial: Pocket3StationCleanupDebt? = nil) {
        value = initial
    }

    public func load() async -> Pocket3StationCleanupDebt? { value }
    public func save(_ debt: Pocket3StationCleanupDebt) async { value = debt }
    public func clear(_ debt: Pocket3StationCleanupDebt) async {
        guard value == debt else { return }
        value = nil
    }
}

/// Durable metadata storage for the App.  The encoded value has no SSID or
/// password field, and `clear` is binding-aware so a newer debt cannot be
/// erased by an old cleanup attempt.
public actor Pocket3StationUserDefaultsCleanupDebtStore:
    Pocket3StationCleanupDebtStore {
    public static let defaultKey = "pocket3.station.cleanup-debt.v1"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard,
                key: String = "pocket3.station.cleanup-debt.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() async -> Pocket3StationCleanupDebt? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Pocket3StationCleanupDebt.self,
                                         from: data)
    }

    public func save(_ debt: Pocket3StationCleanupDebt) async {
        guard let data = try? JSONEncoder().encode(debt) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear(_ debt: Pocket3StationCleanupDebt) async {
        guard let current = await load(), current == debt else { return }
        defaults.removeObject(forKey: key)
    }
}

public struct Pocket3StationSessionResult: Codable, Sendable, Equatable {
    public let phase: Pocket3StationSessionPhase
    public let binding: Pocket3StationSessionBinding
    public let steps: [Pocket3StationStepEvidence]
    public let settleSeconds: TimeInterval?
    public let lan: Pocket3StationLANEvidence?
    public let commandReady: Bool
    public let cleanupDebt: Pocket3StationCleanupDebt?
    public let failureCode: String?
    public let provenance: [String]
    public let automaticWiFiAssociation: Bool
    public let credentialsPersisted: Bool

    init(phase: Pocket3StationSessionPhase,
         binding: Pocket3StationSessionBinding,
         steps: [Pocket3StationStepEvidence],
         settleSeconds: TimeInterval?,
         lan: Pocket3StationLANEvidence?, commandReady: Bool,
         cleanupDebt: Pocket3StationCleanupDebt?, failureCode: String?) {
        self.phase = phase
        self.binding = binding
        self.steps = Array(steps.prefix(8))
        self.settleSeconds = settleSeconds
        self.lan = lan
        self.commandReady = commandReady
        self.cleanupDebt = cleanupDebt
        self.failureCode = failureCode
        self.provenance = Pocket3StationProtocol.provenance
        automaticWiFiAssociation = false
        credentialsPersisted = false
    }
}

public protocol Pocket3StationBLEExecutor: Sendable {
    func send(_ command: Pocket3StationBLECommand,
              binding: Pocket3StationSessionBinding) async throws
        -> Pocket3StationBLEReply

    /// Reconnect/revalidate the paired BLE session before cleanup.  A station
    /// transition may drop BLE, so cleanup must never blindly reuse a stale
    /// session.  The returned binding may have a newer session/generation but
    /// must retain the same peripheral and opaque identity.
    func revalidate(_ binding: Pocket3StationSessionBinding) async throws
        -> Pocket3StationSessionBinding
}

public protocol Pocket3StationLANExecutor: Sendable {
    func discoverAndConnect(
        host: String?, binding: Pocket3StationSessionBinding,
        expectedIdentity: Pocket3StationIdentity
    ) async throws -> Pocket3StationLANEvidence

    func close(_ evidence: Pocket3StationLANEvidence,
               binding: Pocket3StationSessionBinding) async
}

public protocol Pocket3StationClock: Sendable {
    func sleep(for duration: TimeInterval) async throws
}

public struct SystemPocket3StationClock: Pocket3StationClock {
    public init() {}
    public func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(duration))
    }
}

/// Pure station protocol codec.  The BLE transport must still add its
/// existing exact session/peer/sequence/CRC fence before writing.
public enum Pocket3StationProtocol {
    public static let commandSet: UInt8 = 0x07
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x07
    public static let requestFlags: UInt8 = 0x40
    /// OpenPocketCine's physical station transition uses a bounded settle
    /// window of about ten seconds before credentials are submitted.  This is
    public static let settleSeconds: TimeInterval = 10
    public static let provenance: [String] = [
        "OpenPocketCine@9b30b93572797c94db5ad9236fb746410f8d761f",
        "station-sequence:BLE-07/39→07/48→settle→07/47→LAN-07/07"
    ]

    public static func networkModeProbe(sequence: UInt16)
        -> Pocket3StationBLECommand {
        command(operation: .networkModeProbe, commandID: 0x39,
                payload: Data([0x00]), sequence: sequence)
    }

    public static func enterStationMode(sequence: UInt16)
        -> Pocket3StationBLECommand {
        command(operation: .enterStationMode, commandID: 0x48,
                payload: Data([0x01]), sequence: sequence)
    }

    public static func leaveStationMode(sequence: UInt16)
        -> Pocket3StationBLECommand {
        command(operation: .leaveStationMode, commandID: 0x48,
                payload: Data([0x00]), sequence: sequence)
    }

    public static func joinNetwork(
        credentials: Pocket3StationCredentials, sequence: UInt16
    ) -> Pocket3StationBLECommand {
        var payload = packString(credentials.ssid)
        payload.append(contentsOf: packString(credentials.password))
        return command(operation: .joinNetwork, commandID: 0x47,
                       payload: payload, sequence: sequence)
    }

    public static func accepted(_ reply: Pocket3StationBLEReply) -> Bool {
        switch reply.operation {
        case .networkModeProbe:
            // E0 is the reviewed Pocket 3 missing-getter response. No other
            // status is upgraded to station identity evidence.
            return reply.payload == Data([0xE0])
        case .enterStationMode, .leaveStationMode:
            return reply.payload == Data([0x00])
        case .joinNetwork:
            return reply.payload == Data([0x00, 0x00])
        }
    }

    /// Extracts the only identity field currently evidenced for LAN 07/07:
    /// a zero status followed by one bounded packed camera AP SSID.  Any
    /// unknown/trailing envelope is rejected instead of being normalized.
    public static func cameraSSIDIdentity(from replyPayload: Data)
        -> Pocket3StationIdentity? {
        guard replyPayload.first == 0 else { return nil }
        let bytes = Array(replyPayload.dropFirst())
        guard let count = bytes.first.map(Int.init),
              (1...32).contains(count), bytes.count == count + 1,
              let ssid = String(bytes: bytes.dropFirst(), encoding: .utf8),
              let identity = try? Pocket3StationIdentity(cameraSSID: ssid) else {
            return nil
        }
        return identity
    }

    /// Admits only the three reviewed request shapes.  The BLE adapter uses
    /// this before writing, so an executor cannot smuggle an unreviewed
    /// opcode or payload through the station coordinator.
    public static func isValidRequest(_ command: Pocket3StationBLECommand)
        -> Bool {
        let frame = command.frame
        guard frame.source == source, frame.destination == destination,
              frame.flags == requestFlags, frame.commandSet == commandSet else {
            return false
        }
        switch command.operation {
        case .networkModeProbe:
            return frame.commandID == 0x39 && frame.payload == Data([0x00])
        case .enterStationMode:
            return frame.commandID == 0x48 && frame.payload == Data([0x01])
        case .leaveStationMode:
            return frame.commandID == 0x48 && frame.payload == Data([0x00])
        case .joinNetwork:
            guard frame.commandID == 0x47,
                  let first = unpackString(frame.payload, at: 0,
                                           maximumBytes: 32),
                  let second = unpackString(frame.payload, at: first.next,
                                            maximumBytes: 63) else {
                return false
            }
            return second.next == frame.payload.count
        }
    }

    /// FFF5 is the reviewed outbound station writer. Reply notifications may
    /// arrive on either subscribed DUML characteristic, so inbound admission
    /// is limited to the existing FFF4/FFF5 pair.
    public static func isValidReplyCharacteristic(_ characteristic: String)
        -> Bool {
        characteristic == "FFF4" || characteristic == "FFF5"
    }

    private static func command(
        operation: Pocket3StationBLEOperation, commandID: UInt8,
        payload: Data, sequence: UInt16
    ) -> Pocket3StationBLECommand {
        Pocket3StationBLECommand(operation: operation, frame: DUMLFrame(
            source: source, destination: destination, sequence: sequence,
            flags: requestFlags, commandSet: commandSet,
            commandID: commandID, payload: payload))
    }

    private static func packString(_ value: String) -> Data {
        var result = Data([UInt8(value.utf8.count)])
        result.append(contentsOf: value.utf8)
        return result
    }

    private static func unpackString(_ payload: Data, at offset: Int,
                                     maximumBytes: Int)
        -> (value: String, next: Int)? {
        guard payload.indices.contains(offset) else { return nil }
        let count = Int(payload[offset])
        let start = offset + 1, end = start + count
        guard count > 0, count <= maximumBytes,
              end <= payload.count else { return nil }
        let bytes = payload[start..<end]
        guard let value = String(bytes: bytes, encoding: .utf8),
              bytes.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return (value, end)
    }

}

/// Safe App/CLI input.  It contains no SSID/password fields; a future UI
/// executor can construct `Pocket3StationCredentials` in memory and pass it
/// directly to the coordinator.
public struct Pocket3StationValidationRequest: Codable, Sendable,
    Equatable {
    public static let operation = "validation-wireless-station-session"
    public static let maximumHostBytes = 253

    public let expectedSessionID: UUID
    public let expectedPeripheralID: UUID
    public let generation: UInt64
    public let host: String?
    public let execute: Bool

    public init(expectedSessionID: UUID, expectedPeripheralID: UUID,
                generation: UInt64, host: String? = nil,
                execute: Bool = false) throws {
        guard generation != 0,
              host.map({ !$0.isEmpty && $0.utf8.count <= Self.maximumHostBytes })
                ?? true else {
            throw Pocket3StationSessionError.invalidHost
        }
        self.expectedSessionID = expectedSessionID
        self.expectedPeripheralID = expectedPeripheralID
        self.generation = generation
        self.host = host
        self.execute = execute
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                  "expectedSessionID", "expectedPeripheralID", "generation",
                  "host", "execute"
              ]),
              let session = fields["expectedSessionID"]?.string
                .flatMap(UUID.init(uuidString:)),
              let peer = fields["expectedPeripheralID"]?.string
                .flatMap(UUID.init(uuidString:)),
              let generationNumber = fields["generation"]?.number,
              generationNumber.isFinite,
              generationNumber.rounded() == generationNumber,
              let generation = UInt64(exactly: generationNumber),
              fields["host"] == nil || fields["host"]?.string != nil,
              fields["execute"] == nil || fields["execute"]?.bool != nil else {
            throw Pocket3StationSessionError.invalidBinding
        }
        try self.init(expectedSessionID: session,
                      expectedPeripheralID: peer, generation: generation,
                      host: fields["host"]?.string,
                      execute: fields["execute"]?.bool ?? false)
    }

    public init(cliArguments: [String]) throws {
        var session: UUID?, peer: UUID?, generation: UInt64?, host: String?
        var execute = false
        var index = 0
        while index < cliArguments.count {
            let option = cliArguments[index]
            if option == "--execute" {
                guard !execute else { throw Pocket3StationSessionError.invalidBinding }
                execute = true; index += 1; continue
            }
            guard index + 1 < cliArguments.count else {
                throw Pocket3StationSessionError.invalidBinding
            }
            let value = cliArguments[index + 1]
            switch option {
            case "--session":
                guard session == nil else { throw Pocket3StationSessionError.invalidBinding }
                session = UUID(uuidString: value)
            case "--peripheral":
                guard peer == nil else { throw Pocket3StationSessionError.invalidBinding }
                peer = UUID(uuidString: value)
            case "--generation":
                guard generation == nil, let parsed = UInt64(value) else {
                    throw Pocket3StationSessionError.invalidBinding
                }
                generation = parsed
            case "--host":
                guard host == nil else { throw Pocket3StationSessionError.invalidBinding }
                host = value
            default: throw Pocket3StationSessionError.invalidBinding
            }
            index += 2
        }
        guard let session, let peer, let generation else {
            throw Pocket3StationSessionError.invalidBinding
        }
        try self.init(expectedSessionID: session,
                      expectedPeripheralID: peer, generation: generation,
                      host: host, execute: execute)
    }

    public var arguments: JSONValue {
        var fields: [String: JSONValue] = [
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "expectedPeripheralID": .string(expectedPeripheralID.uuidString),
            "generation": .number(Double(generation)),
            "execute": .bool(execute)
        ]
        if let host { fields["host"] = .string(host) }
        return .object(fields)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "expectedSessionID": .object([
                "type": .string("string"), "minLength": .number(1)
            ]),
            "expectedPeripheralID": .object([
                "type": .string("string"), "minLength": .number(1)
            ]),
            "generation": .object([
                "type": .string("integer"), "minimum": .number(1)
            ]),
            "host": .object([
                "type": .string("string"), "minLength": .number(1),
                "maxLength": .number(Double(maximumHostBytes))
            ]),
            "execute": .object(["type": .string("boolean")])
        ]),
        "required": .array([
            .string("expectedSessionID"), .string("expectedPeripheralID"),
            .string("generation")
        ]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }
}

public struct Pocket3StationDryRunPlan: Codable, Sendable, Equatable {
    public let operation: String
    public let steps: [String]
    public let executeRequested: Bool
    public let automaticWiFiAssociation: Bool
    public let credentialsPersisted: Bool
    public let commandReadyRequiresExactIdentity: Bool

    init(request: Pocket3StationValidationRequest) {
        operation = Pocket3StationValidationRequest.operation
        steps = [
            "BLE exact session/peer/generation",
            "07/39 00 → exact E0 missing-getter",
            "07/48 01 → exact 00",
            "bounded station settle",
            "07/47 packed SSID/password → exact 0000",
            "optional host override or bounded primary /24 discovery",
            "TCP7001 preprobe ≤24 concurrent, keep ≤8 hits",
            "full TCP7001 + UDP9004 + LAN 07/07 identity",
            "LAN 07/07 identity exact match",
            "07/48 00 cleanup"
        ]
        executeRequested = request.execute
        automaticWiFiAssociation = false
        credentialsPersisted = false
        commandReadyRequiresExactIdentity = true
    }
}

public enum Pocket3StationValidationService {
    public static func dryRun(
        _ request: Pocket3StationValidationRequest
    ) -> Pocket3StationDryRunPlan {
        Pocket3StationDryRunPlan(request: request)
    }
}

/// One exact-session station provisioning attempt.  The actor intentionally
/// has no default BLE or LAN implementation: only an injected executor can
/// produce a command-ready result.
public actor Pocket3StationSessionCoordinator {
    public let binding: Pocket3StationSessionBinding
    private let ble: any Pocket3StationBLEExecutor
    private let lan: any Pocket3StationLANExecutor
    private let clock: any Pocket3StationClock
    private let debtStore: any Pocket3StationCleanupDebtStore
    private var phase: Pocket3StationSessionPhase = .idle
    private var steps: [Pocket3StationStepEvidence] = []
    private var settleSeconds: TimeInterval?
    private var lanEvidence: Pocket3StationLANEvidence?
    private var debt: Pocket3StationCleanupDebt?
    private var failureCode: String?
    private var stationModeEntered = false
    private var lanClosed = false
    private var debtLoaded = false
    private var sequence: UInt16

    public init(binding: Pocket3StationSessionBinding,
                ble: any Pocket3StationBLEExecutor,
                lan: any Pocket3StationLANExecutor,
                clock: any Pocket3StationClock = SystemPocket3StationClock(),
                debtStore: any Pocket3StationCleanupDebtStore =
                    Pocket3StationUserDefaultsCleanupDebtStore(),
                initialSequence: UInt16 = 0x8100) {
        self.binding = binding
        self.ble = ble
        self.lan = lan
        self.clock = clock
        self.debtStore = debtStore
        sequence = initialSequence
    }

    public func status() -> Pocket3StationSessionResult {
        result()
    }

    public func start(credentials: Pocket3StationCredentials,
                      host: String? = nil) async -> Pocket3StationSessionResult {
        await loadDebtIfNeeded()
        guard phase == .idle || phase == .failed || phase == .cancelled,
              debt == nil else {
            phase = .failed
            failureCode = "station_session_busy_or_cleanup_debt"
            return result()
        }
        phase = .probingBLEIdentity
        steps = []; settleSeconds = nil; lanEvidence = nil; lanClosed = false
        failureCode = nil; stationModeEntered = false
        do {
            try await perform(.networkModeProbe) { sequence in
                Pocket3StationProtocol.networkModeProbe(sequence: sequence)
            } validate: { Pocket3StationProtocol.accepted($0) }

            phase = .enteringStationMode
            try await perform(.enterStationMode) { sequence in
                Pocket3StationProtocol.enterStationMode(sequence: sequence)
            } validate: { Pocket3StationProtocol.accepted($0) }
            stationModeEntered = true

            phase = .settling
            let started = ProcessInfo.processInfo.systemUptime
            try await clock.sleep(for: Pocket3StationProtocol.settleSeconds)
            let ended = ProcessInfo.processInfo.systemUptime
            settleSeconds = ended.isFinite && started.isFinite
                ? max(0, ended - started) : Pocket3StationProtocol.settleSeconds

            phase = .joiningNetwork
            try await perform(.joinNetwork) { sequence in
                Pocket3StationProtocol.joinNetwork(
                    credentials: credentials, sequence: sequence)
            } validate: { Pocket3StationProtocol.accepted($0) }

            phase = .discoveringLAN
            let evidence = try await lan.discoverAndConnect(
                host: host, binding: binding, expectedIdentity: binding.bleIdentity)
            lanEvidence = evidence
            phase = .verifyingLANIdentity
            guard evidence.transportReady else {
                throw Pocket3StationSessionError.lanTransportUnavailable
            }
            guard evidence.identityReplyValidated,
                  evidence.identityCommand == "07/07",
                  evidence.identity.matches(binding.bleIdentity),
                  evidence.identityRaw == binding.bleIdentity.raw else {
                throw Pocket3StationSessionError.lanIdentityMismatch
            }
            phase = .commandReady
            return result()
        } catch is CancellationError {
            failureCode = "station_session_cancelled"
            await cleanupAfterFailure()
            phase = debt == nil ? .cancelled : .cleanupDebt
            if debt != nil { failureCode = "station_cleanup_debt" }
            return result()
        } catch {
            failureCode = Self.code(error)
            await cleanupAfterFailure()
            phase = debt == nil ? .failed : .cleanupDebt
            if debt != nil { failureCode = "station_cleanup_debt" }
            return result()
        }
    }

    /// Stops the LAN link and explicitly leaves station mode. Cleanup is one
    /// attempt only; a failed exit becomes debt for an explicit retry.
    public func stop() async -> Pocket3StationSessionResult {
        guard phase == .commandReady || phase == .cleanupDebt else {
            return result()
        }
        if phase == .cleanupDebt {
            await closeLANIfNeeded()
            return await retryCleanup()
        }
        phase = .stopping
        await closeLANIfNeeded()
        await cleanupAfterFailure()
        phase = debt == nil ? .idle : .cleanupDebt
        failureCode = debt == nil ? nil : "station_cleanup_debt"
        return result()
    }

    /// Retry only the 07/48 00 cleanup after revalidating BLE.  No
    /// provisioning command or network association is repeated.
    public func retryCleanup() async -> Pocket3StationSessionResult {
        await loadDebtIfNeeded()
        guard let existing = debt else { return result() }
        guard existing.binding.peripheralID == binding.peripheralID,
              existing.binding.bleIdentity.matches(binding.bleIdentity) else {
            failureCode = "station_cleanup_stale_binding"
            phase = .cleanupDebt
            return result()
        }
        phase = .cleaningUp
        do {
            let candidate = try await revalidatedCleanupBinding(
                from: existing.binding)
            if await sendLeaveMode(using: candidate) {
                debt = nil; stationModeEntered = false; failureCode = nil
                phase = .idle
                await debtStore.clear(existing)
            } else {
                await recordCleanupDebt(binding: candidate,
                                        reason: "station_leave_mode_failed",
                                        attempts: existing.attempts + 1)
                phase = .cleanupDebt; failureCode = "station_cleanup_debt"
            }
        } catch {
            await recordCleanupDebt(binding: existing.binding,
                                    reason: "station_cleanup_revalidation_failed",
                                    attempts: existing.attempts + 1)
            phase = .cleanupDebt; failureCode = "station_cleanup_debt"
        }
        return result()
    }

    private func perform(
        _ operation: Pocket3StationBLEOperation,
        build: (UInt16) -> Pocket3StationBLECommand,
        validate: (Pocket3StationBLEReply) -> Bool
    ) async throws {
        let command = build(sequence)
        sequence &+= 1
        let reply: Pocket3StationBLEReply
        do {
            reply = try await ble.send(command, binding: binding)
        } catch {
            steps.append(.init(operation: operation, submitted: true,
                               responseReceived: false, accepted: false,
                               failureCode: Self.code(error)))
            throw error
        }
        let accepted = reply.operation == operation && validate(reply)
        steps.append(.init(operation: operation, submitted: true,
                           responseReceived: true,
                           responsePayload: reply.payload,
                           accepted: accepted,
                           failureCode: accepted ? nil : "station_reply_rejected"))
        guard accepted else { throw Pocket3StationSessionError.unsupportedReply }
    }

    private func cleanupAfterFailure() async {
        await closeLANIfNeeded()
        guard stationModeEntered else { return }
        phase = .cleaningUp
        let previousBinding = debt?.binding ?? binding
        do {
            let candidate = try await revalidatedCleanupBinding(
                from: previousBinding)
            if await sendLeaveMode(using: candidate) {
                stationModeEntered = false
                if let debt { await debtStore.clear(debt) }
                debt = nil
            } else {
                await recordCleanupDebt(binding: candidate,
                                        reason: "station_leave_mode_failed",
                                        attempts: debt?.attempts ?? 1)
            }
        } catch {
            await recordCleanupDebt(binding: previousBinding,
                                    reason: "station_cleanup_revalidation_failed",
                                    attempts: debt?.attempts ?? 1)
        }
    }

    private func revalidatedCleanupBinding(
        from expected: Pocket3StationSessionBinding
    ) async throws -> Pocket3StationSessionBinding {
        let candidate = try await ble.revalidate(expected)
        guard candidate.peripheralID == expected.peripheralID,
              candidate.bleIdentity.matches(expected.bleIdentity),
              candidate.generation >= expected.generation else {
            throw Pocket3StationSessionError.staleBinding
        }
        return candidate
    }

    private func sendLeaveMode(using cleanupBinding: Pocket3StationSessionBinding)
        async -> Bool {
        let command = Pocket3StationProtocol.leaveStationMode(sequence: sequence)
        sequence &+= 1
        do {
            let reply = try await ble.send(command, binding: cleanupBinding)
            let accepted = reply.operation == .leaveStationMode &&
                Pocket3StationProtocol.accepted(reply)
            steps.append(.init(operation: .leaveStationMode, submitted: true,
                               responseReceived: true,
                               responsePayload: reply.payload,
                               accepted: accepted,
                               failureCode: accepted ? nil : "station_reply_rejected"))
            return accepted
        } catch {
            steps.append(.init(operation: .leaveStationMode, submitted: true,
                               responseReceived: false, accepted: false,
                               failureCode: Self.code(error)))
            return false
        }
    }

    private func closeLANIfNeeded() async {
        guard !lanClosed, let lanEvidence else { return }
        lanClosed = true
        await lan.close(lanEvidence, binding: binding)
    }

    private func loadDebtIfNeeded() async {
        guard !debtLoaded else { return }
        debtLoaded = true
        guard let stored = await debtStore.load() else { return }
        debt = stored
        phase = .cleanupDebt
        failureCode = "station_cleanup_debt"
    }

    private func recordCleanupDebt(binding: Pocket3StationSessionBinding,
                                   reason: String, attempts: Int) async {
        let value = Pocket3StationCleanupDebt(binding: binding, reason: reason,
                                              attempts: attempts)
        debt = value
        await debtStore.save(value)
    }

    private func result() -> Pocket3StationSessionResult {
        Pocket3StationSessionResult(
            phase: phase, binding: binding, steps: steps,
            settleSeconds: settleSeconds, lan: lanEvidence,
            commandReady: phase == .commandReady && stationModeEntered &&
                debt == nil && lanEvidence?.identityReplyValidated == true &&
                lanEvidence?.datalinkOwnerRetained == true,
            cleanupDebt: debt, failureCode: failureCode)
    }

    private static func code(_ error: Error) -> String {
        if error is CancellationError { return "station_session_cancelled" }
        switch error {
        case Pocket3StationSessionError.invalidBinding: return "station_invalid_binding"
        case Pocket3StationSessionError.invalidCredentials: return "station_invalid_credentials"
        case Pocket3StationSessionError.invalidHost: return "station_invalid_host"
        case Pocket3StationSessionError.busy: return "station_busy"
        case Pocket3StationSessionError.staleBinding: return "station_stale_binding"
        case Pocket3StationSessionError.unsupportedReply: return "station_reply_rejected"
        case Pocket3StationSessionError.lanIdentityMismatch: return "station_lan_identity_mismatch"
        case Pocket3StationSessionError.lanTransportUnavailable: return "station_lan_transport_unavailable"
        case Pocket3StationSessionError.lanDiscoveryNoCandidates:
            return "station_lan_discovery_no_candidates"
        case Pocket3StationSessionError.lanDiscoveryNoTCPHits:
            return "station_lan_discovery_no_tcp_hits"
        case Pocket3StationSessionError.lanDiscoveryTimeout:
            return "station_lan_discovery_timeout"
        case Pocket3StationSessionError.cleanupRequired: return "station_cleanup_debt"
        default: return String(String(describing: error).prefix(128))
        }
    }
}

public typealias Pocket3StationCoordinator = Pocket3StationSessionCoordinator
