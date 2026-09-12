import Foundation

// MARK: - Evidence-led Pocket 3 advanced-setting inventory

/// Evidence attached to an advanced body setting. These labels distinguish a
/// DJI feature statement from a public protocol capture and from a parser that
/// this package can exercise without a camera.
public enum Pocket3AdvancedSettingEvidence: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable {
    case officialOnly = "official_only"
    case publicReverseEngineering = "public_reverse_engineering"
    case localParser = "local_parser"

    public var capabilityLevel: CapabilityEvidenceLevel {
        switch self {
        case .officialOnly: .officialSpecification
        case .publicReverseEngineering: .publicReverseEngineering
        case .localParser: .softwareFixture
        }
    }
}

public enum Pocket3AdvancedSettingID: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable, Identifiable {
    case medTele = "med_tele"
    case breathingCompensation = "breathing_compensation"
    case sharpness
    case noiseReduction = "noise_reduction"
    case isoLimit = "iso_limit"
    case audioChannel = "audio_channel"
    case vocalBoost = "vocal_boost"
    case selfieFlip = "selfie_flip"

    public var id: String { rawValue }
}

public typealias Pocket3AdvancedSetting = Pocket3AdvancedSettingID

/// A candidate command shape listed in the inventory. The keyed form carries
/// exact request bytes and the exact one-byte SET domain where the reviewed
/// sources establish it. It never creates a command for an unknown PID.
public enum Pocket3AdvancedSettingCommandCandidate: Codable, Sendable,
    Equatable, Hashable {
    case keyedParameter(parameterID: UInt16, getPayload: Data,
                        setValueLength: Int, knownSetValues: [UInt8])
    case medTele(enablePayload: Data, disablePayload: Data)
    case selfieFlip(readParameterID: UInt16, readPayload: Data,
                    togglePayload: Data)
    case unavailable(reason: String)
}

/// A readback candidate may be a strict keyed envelope or an intentionally
/// opaque poll. `nil` valueLength means that the value location/length is not
/// claimed for this PID; callers must retain raw bytes and cannot mark a
/// setting verified from the candidate alone.
public enum Pocket3AdvancedSettingReadbackCandidate: Codable, Sendable,
    Equatable, Hashable {
    case keyedParameter(parameterID: UInt16, valueLength: Int?)
    case opaque(commandSet: UInt8, commandID: UInt8, note: String)
    case unavailable(reason: String)
}

public struct Pocket3AdvancedSettingInventoryEntry: Codable, Sendable,
    Equatable, Hashable, Identifiable {
    public let id: Pocket3AdvancedSettingID
    public let evidence: [Pocket3AdvancedSettingEvidence]
    public let sourceReferences: [String]
    public let availability: CapabilityAvailability
    public let transport: CameraCapabilityTransport
    public let command: Pocket3AdvancedSettingCommandCandidate
    public let readback: Pocket3AdvancedSettingReadbackCandidate

    public var evidenceLevel: CapabilityEvidenceLevel {
        evidence.map(\.capabilityLevel).max() ?? .officialSpecification
    }

    public init(
        id: Pocket3AdvancedSettingID,
        evidence: [Pocket3AdvancedSettingEvidence],
        sourceReferences: [String],
        availability: CapabilityAvailability,
        transport: CameraCapabilityTransport = .bluetoothDatalink,
        command: Pocket3AdvancedSettingCommandCandidate,
        readback: Pocket3AdvancedSettingReadbackCandidate
    ) {
        self.id = id
        self.evidence = evidence
        self.sourceReferences = sourceReferences
        self.availability = availability
        self.transport = transport
        self.command = command
        self.readback = readback
    }
}

/// Static facts are separate from current native-session readiness. A caller
/// can merge this availability with a session gate without promoting a
/// protocol candidate to a product-supported writer.
public enum Pocket3AdvancedSettingInventory {
    public static let kazeSettingsSource =
        "research/2026-09-08/camera-settings/ios/Pocket3Controller/Pocket3CameraSettings.swift"
    public static let openPocketCineCommandSource =
        "https://openpocketcine.app/docs/protocol/commands/"
    public static let openPocketCinePocket3Source =
        "https://openpocketcine.app/docs/protocol/pocket3/"
    public static let djiReleaseNotesSource =
        "https://dl.djicdn.com/downloads/DJI_Osmo_Pocket_3/RN/20250826/DJI_Osmo_Pocket_3_Release_Notes_en.pdf"
    public static let localParserSource =
        "Sources/Pocket3Core/Pocket3AdvancedSettings.swift"

    public static let all: [Pocket3AdvancedSettingInventoryEntry] = [
        .init(id: .medTele,
              evidence: [.officialOnly, .publicReverseEngineering,
                         .localParser],
              sourceReferences: [openPocketCinePocket3Source,
                                 djiReleaseNotesSource, localParserSource],
              availability: .init(write: true,
                                  reason: "Candidate command has no typed body-state readback or persistence proof"),
              command: .medTele(
                enablePayload: Data([0x00, 0x15, 0x00, 0x0D, 0x00, 0x00, 0x00]),
                disablePayload: Data([0x00, 0x15, 0x00, 0x01, 0x00, 0x00, 0x00])),
              readback: .opaque(commandSet: 0x02, commandID: 0xFF,
                                note: "The same opcode has a distinct opaque 34-byte poll; selector semantics are unverified")),
        .init(id: .breathingCompensation,
              evidence: [.officialOnly],
              sourceReferences: [djiReleaseNotesSource,
                                 openPocketCinePocket3Source],
              availability: .unavailable(
                reason: "Official body feature only; no Pocket 3 command or readback schema"),
              command: .unavailable(reason: "No evidenced Pocket 3 opcode"),
              readback: .unavailable(reason: "No evidenced Pocket 3 readback property")),
        .init(id: .sharpness,
              evidence: [.officialOnly],
              sourceReferences: [djiReleaseNotesSource,
                                 openPocketCinePocket3Source],
              availability: .unavailable(
                reason: "Official feature record only; inspected body settings had no typed schema"),
              command: .unavailable(reason: "Do not confuse host UVC processing-unit sharpness with body setting"),
              readback: .unavailable(reason: "No evidenced Pocket 3 readback property")),
        .init(id: .noiseReduction,
              evidence: [.officialOnly],
              sourceReferences: [djiReleaseNotesSource,
                                 openPocketCinePocket3Source],
              availability: .unavailable(
                reason: "Official feature record only; inspected body settings had no typed schema"),
              command: .unavailable(reason: "No evidenced Pocket 3 opcode"),
              readback: .unavailable(reason: "No evidenced Pocket 3 readback property")),
        .init(id: .isoLimit,
              evidence: [.publicReverseEngineering, .localParser],
              sourceReferences: [kazeSettingsSource, openPocketCineCommandSource,
                                 localParserSource],
              availability: .init(read: true, write: true,
                                  reason: "Keyed candidate requires a fresh same-session readback; write is not locally verified"),
              command: .keyedParameter(parameterID: 0x000F,
                                       getPayload: Data([0x00, 0x01, 0x0F, 0x00]),
                                       setValueLength: 1,
                                       knownSetValues: Array(0x01...0x07)),
              readback: .keyedParameter(parameterID: 0x000F, valueLength: nil)),
        .init(id: .audioChannel,
              evidence: [.publicReverseEngineering, .localParser],
              sourceReferences: [kazeSettingsSource, openPocketCineCommandSource,
                                 localParserSource],
              availability: .init(read: true, write: true,
                                  reason: "Keyed candidate requires a fresh same-session readback; raw selector 0x03 remains unknown"),
              command: .keyedParameter(parameterID: 0x0020,
                                       getPayload: Data([0x00, 0x01, 0x20, 0x00]),
                                       setValueLength: 1,
                                       knownSetValues: [0x01, 0x02]),
              readback: .keyedParameter(parameterID: 0x0020, valueLength: nil)),
        .init(id: .vocalBoost,
              evidence: [.publicReverseEngineering, .localParser],
              sourceReferences: [openPocketCineCommandSource, localParserSource],
              availability: .init(read: true, write: true,
                                  reason: "Keyed candidate requires a fresh same-session readback; local hardware result is absent"),
              command: .keyedParameter(parameterID: 0x004C,
                                       getPayload: Data([0x00, 0x01, 0x4C, 0x00]),
                                       setValueLength: 1,
                                       knownSetValues: [0x00, 0x01]),
              readback: .keyedParameter(parameterID: 0x004C, valueLength: nil)),
        .init(id: .selfieFlip,
              evidence: [.publicReverseEngineering, .localParser],
              sourceReferences: [openPocketCineCommandSource,
                                 openPocketCinePocket3Source,
                                 "Sources/Pocket3Core/Pocket3NativeProtocolPhase0.swift",
                                 localParserSource],
              availability: .init(read: true, write: false,
                                  reason: "Body PID 0038 is GET-only in the reviewed catalog; FE09 is a toggle without setting readback"),
              command: .selfieFlip(readParameterID: 0x0038,
                                  readPayload: Data([0x00, 0x01, 0x38, 0x00]),
                                  togglePayload: Data([0xFE, 0x09])),
              readback: .keyedParameter(parameterID: 0x0038, valueLength: nil))
    ]

    public static func entry(for id: Pocket3AdvancedSettingID)
        -> Pocket3AdvancedSettingInventoryEntry? {
        all.first { $0.id == id }
    }
}

// MARK: - Strict keyed 02/8E request/readback candidates

public enum Pocket3KeyedParameterError: Error, Codable, Sendable, Equatable {
    case invalidValueLength(expected: Int, actual: Int)
    case invalidPayload
    case unsupportedParameter(UInt16)
    case mismatchedParameter(expected: UInt16, actual: UInt16)
    case unsupportedResponseLength(expected: Int, actual: Int)
}

public enum Pocket3KeyedParameterOperation: String, Codable, Sendable,
    Equatable, CaseIterable {
    case get
    case set
}

/// Exact 02/8E keyed GET/SET envelope. SET requires an explicit expected
/// length, so a caller cannot accidentally send a captured value of a
/// different size under a known PID.
public struct Pocket3KeyedParameterCommand: Codable, Sendable, Equatable,
    Hashable {
    public static let commandSet: UInt8 = 0x02
    public static let commandID: UInt8 = 0x8E
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x01
    public static let requestFlags: UInt8 = 0x40

    public let operation: Pocket3KeyedParameterOperation
    public let parameterID: UInt16
    public let value: Data
    public let expectedValueLength: Int?

    public init(get parameterID: UInt16, expectedValueLength: Int? = nil) throws {
        try Self.validateParameterID(parameterID)
        if let expectedValueLength {
            try Self.validateLength(expectedValueLength)
        }
        operation = .get
        self.parameterID = parameterID
        value = Data()
        self.expectedValueLength = expectedValueLength
    }

    public init(set parameterID: UInt16, value: Data,
                expectedValueLength: Int) throws {
        try Self.validateParameterID(parameterID)
        try Self.validateLength(expectedValueLength)
        guard value.count == expectedValueLength else {
            throw Pocket3KeyedParameterError.invalidValueLength(
                expected: expectedValueLength, actual: value.count)
        }
        operation = .set
        self.parameterID = parameterID
        self.value = value
        self.expectedValueLength = expectedValueLength
    }

    public var payload: Data {
        let low = UInt8(parameterID & 0xFF)
        let high = UInt8(parameterID >> 8)
        switch operation {
        case .get:
            return Data([0x00, 0x01, low, high])
        case .set:
            return Data([0x01, 0x01, low, high, UInt8(value.count)]) + value
        }
    }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination,
                  sequence: sequence, flags: Self.requestFlags,
                  commandSet: Self.commandSet, commandID: Self.commandID,
                  payload: payload)
    }

    public func encodedFrame(sequence: UInt16) throws -> Data {
        try DUMLCodec.encode(frame(sequence: sequence))
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try values.decode(Pocket3KeyedParameterOperation.self,
                                          forKey: .operation)
        let parameterID = try values.decode(UInt16.self, forKey: .parameterID)
        let value = try values.decodeIfPresent(Data.self, forKey: .value) ?? Data()
        let expectedValueLength = try values.decodeIfPresent(
            Int.self, forKey: .expectedValueLength)
        switch operation {
        case .get:
            guard value.isEmpty else {
                throw Pocket3KeyedParameterError.invalidPayload
            }
            try self.init(get: parameterID,
                          expectedValueLength: expectedValueLength)
        case .set:
            guard let expectedValueLength else {
                throw Pocket3KeyedParameterError.invalidPayload
            }
            try self.init(set: parameterID, value: value,
                          expectedValueLength: expectedValueLength)
        }
    }

    public static func isoLimitGet() throws -> Self {
        try Self(get: 0x000F, expectedValueLength: 1)
    }

    public static func isoLimitSet(_ value: Pocket3ISOLimit) throws -> Self {
        try Self(set: 0x000F, value: Data([value.rawValue]),
                 expectedValueLength: 1)
    }

    public static func audioChannelGet() throws -> Self {
        try Self(get: 0x0020, expectedValueLength: 1)
    }

    public static func audioChannelSet(_ value: Pocket3AudioChannel) throws -> Self {
        try Self(set: 0x0020, value: Data([value.rawValue]),
                 expectedValueLength: 1)
    }

    public static func vocalBoostGet() throws -> Self {
        try Self(get: 0x004C, expectedValueLength: 1)
    }

    public static func vocalBoostSet(_ value: Pocket3VocalBoost) throws -> Self {
        try Self(set: 0x004C, value: Data([value.rawValue]),
                 expectedValueLength: 1)
    }

    public static func selfieFlipGet() throws -> Self {
        try Self(get: 0x0038, expectedValueLength: nil)
    }

    private static func validateLength(_ length: Int) throws {
        guard (0...255).contains(length) else {
            throw Pocket3KeyedParameterError.invalidValueLength(
                expected: max(0, min(255, length)), actual: length)
        }
    }

    private static func validateParameterID(_ parameterID: UInt16) throws {
        guard [0x000F, 0x0020, 0x0038, 0x004C].contains(parameterID) else {
            throw Pocket3KeyedParameterError.unsupportedParameter(parameterID)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case operation
        case parameterID
        case value
        case expectedValueLength
    }
}

/// Candidate response envelope seen for 02/8E keyed values. The parser is
/// strict about status, PID, declared value length and total bytes, while
/// keeping all value bytes. A caller still has to supply the expected PID;
/// no PID is inferred from an arbitrary response.
public struct Pocket3KeyedParameterReadback: Codable, Sendable, Equatable,
    Hashable {
    public let raw: Data
    public let statusRaw: UInt8
    public let parameterID: UInt16
    public let valueLengthRaw: UInt8
    public let value: Data

    public init(payload: Data, parameterID expectedParameterID: UInt16,
                expectedValueLength: Int? = nil) throws {
        guard payload.count <= DUMLCodec.maximumPayloadLength,
              payload.count >= 6,
              payload[0] == 0x00, payload[1] == 0x00, payload[2] == 0x01 else {
            throw Pocket3KeyedParameterError.invalidPayload
        }
        let actualParameterID = UInt16(payload[3]) | UInt16(payload[4]) << 8
        guard actualParameterID == expectedParameterID else {
            throw Pocket3KeyedParameterError.mismatchedParameter(
                expected: expectedParameterID, actual: actualParameterID)
        }
        let length = Int(payload[5])
        guard payload.count == 6 + length else {
            throw Pocket3KeyedParameterError.invalidPayload
        }
        if let expectedValueLength, length != expectedValueLength {
            throw Pocket3KeyedParameterError.unsupportedResponseLength(
                expected: expectedValueLength, actual: length)
        }
        raw = payload
        statusRaw = payload[0]
        parameterID = actualParameterID
        valueLengthRaw = payload[5]
        value = Data(payload.dropFirst(6))
    }

    public static func decode(_ payload: Data,
                              parameterID: UInt16,
                              expectedValueLength: Int? = nil) -> Self? {
        try? Self(payload: payload, parameterID: parameterID,
                  expectedValueLength: expectedValueLength)
    }

    public static func parse(_ payload: Data,
                             parameterID: UInt16,
                             expectedValueLength: Int? = nil) -> Self? {
        decode(payload, parameterID: parameterID,
               expectedValueLength: expectedValueLength)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try values.decode(Data.self, forKey: .raw)
        let encodedStatus = try values.decode(UInt8.self, forKey: .statusRaw)
        let encodedParameterID = try values.decode(UInt16.self,
                                                   forKey: .parameterID)
        let encodedLength = try values.decode(UInt8.self,
                                              forKey: .valueLengthRaw)
        let encodedValue = try values.decode(Data.self, forKey: .value)
        let parsed = try Self(payload: raw, parameterID: encodedParameterID,
                              expectedValueLength: Int(encodedLength))
        guard parsed.statusRaw == encodedStatus,
              parsed.valueLengthRaw == encodedLength,
              parsed.value == encodedValue else {
            throw Pocket3KeyedParameterError.invalidPayload
        }
        self = parsed
    }

    private enum CodingKeys: String, CodingKey {
        case raw
        case statusRaw
        case parameterID
        case valueLengthRaw
        case value
    }
}

// MARK: - Typed values with only reviewed one-byte domains

public enum Pocket3ISOLimit: UInt8, Codable, Sendable, Equatable, Hashable,
    CaseIterable {
    case iso100 = 0x01
    case iso200 = 0x02
    case iso400 = 0x03
    case iso800 = 0x04
    case iso1600 = 0x05
    case iso3200 = 0x06
    case iso6400 = 0x07

    public var iso: Int { 100 << Int(rawValue - 1) }
}

public enum Pocket3AudioChannel: UInt8, Codable, Sendable, Equatable,
    Hashable, CaseIterable {
    case mono = 0x01
    case stereo = 0x02
}

public enum Pocket3VocalBoost: UInt8, Codable, Sendable, Equatable, Hashable,
    CaseIterable {
    case off = 0x00
    case on = 0x01
}

public enum Pocket3MedTeleState: String, Codable, Sendable, Equatable,
    Hashable, CaseIterable {
    case disabled
    case enabled
}

public enum Pocket3SelfieFlipState: UInt8, Codable, Sendable, Equatable,
    Hashable, CaseIterable {
    case off = 0x00
    case on = 0x01
}

public enum Pocket3AdvancedSettingValue: Codable, Sendable, Equatable,
    Hashable {
    case isoLimit(Pocket3ISOLimit)
    case audioChannel(Pocket3AudioChannel)
    case vocalBoost(Pocket3VocalBoost)
    case selfieFlip(Pocket3SelfieFlipState)
    case unknown(Data)

    public var rawValue: UInt8? {
        switch self {
        case .isoLimit(let value): value.rawValue
        case .audioChannel(let value): value.rawValue
        case .vocalBoost(let value): value.rawValue
        case .selfieFlip(let value): value.rawValue
        case .unknown: nil
        }
    }
}

public struct Pocket3AdvancedSettingReadback: Codable, Sendable,
    Equatable, Hashable {
    public let setting: Pocket3AdvancedSettingID
    public let keyed: Pocket3KeyedParameterReadback
    public let typedValue: Pocket3AdvancedSettingValue?

    public init(setting: Pocket3AdvancedSettingID,
                keyed: Pocket3KeyedParameterReadback) {
        self.setting = setting
        self.keyed = keyed
        switch setting {
        case .isoLimit:
            typedValue = keyed.value.count == 1
                ? Pocket3ISOLimit(rawValue: keyed.value[0]).map(Pocket3AdvancedSettingValue.isoLimit)
                : nil
        case .audioChannel:
            typedValue = keyed.value.count == 1
                ? Pocket3AudioChannel(rawValue: keyed.value[0]).map(Pocket3AdvancedSettingValue.audioChannel)
                : nil
        case .vocalBoost:
            typedValue = keyed.value.count == 1
                ? Pocket3VocalBoost(rawValue: keyed.value[0]).map(Pocket3AdvancedSettingValue.vocalBoost)
                : nil
        case .selfieFlip:
            typedValue = keyed.value.count == 1
                ? Pocket3SelfieFlipState(rawValue: keyed.value[0]).map(Pocket3AdvancedSettingValue.selfieFlip)
                : nil
        default:
            typedValue = .unknown(keyed.value)
        }
    }

    public static func decode(_ payload: Data,
                              setting: Pocket3AdvancedSettingID,
                              expectedValueLength: Int? = nil) -> Self? {
        let pid: UInt16
        switch setting {
        case .isoLimit: pid = 0x000F
        case .audioChannel: pid = 0x0020
        case .vocalBoost: pid = 0x004C
        case .selfieFlip: pid = 0x0038
        default: return nil
        }
        guard let keyed = Pocket3KeyedParameterReadback.decode(
            payload, parameterID: pid, expectedValueLength: expectedValueLength) else {
            return nil
        }
        return Self(setting: setting, keyed: keyed)
    }

    public var raw: Data { keyed.raw }
    public var value: Data { keyed.value }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let setting = try values.decode(Pocket3AdvancedSettingID.self,
                                        forKey: .setting)
        let keyed = try values.decode(Pocket3KeyedParameterReadback.self,
                                      forKey: .keyed)
        let encodedTypedValue = try values.decodeIfPresent(
            Pocket3AdvancedSettingValue.self, forKey: .typedValue)
        let canonical = Self(setting: setting, keyed: keyed)
        guard encodedTypedValue == canonical.typedValue else {
            throw Pocket3KeyedParameterError.invalidPayload
        }
        self = canonical
    }

    private enum CodingKeys: String, CodingKey {
        case setting
        case keyed
        case typedValue
    }
}

public enum Pocket3AdvancedSettingTarget: Codable, Sendable, Equatable,
    Hashable {
    case isoLimit(Pocket3ISOLimit)
    case audioChannel(Pocket3AudioChannel)
    case vocalBoost(Pocket3VocalBoost)

    public var setting: Pocket3AdvancedSettingID {
        switch self {
        case .isoLimit: .isoLimit
        case .audioChannel: .audioChannel
        case .vocalBoost: .vocalBoost
        }
    }

    public var value: Pocket3AdvancedSettingValue {
        switch self {
        case .isoLimit(let value): .isoLimit(value)
        case .audioChannel(let value): .audioChannel(value)
        case .vocalBoost(let value): .vocalBoost(value)
        }
    }
}

/// Session-bound raw/typed readback. Typed value is optional by design: a
/// response with an unknown shape or selector remains evidence, but cannot
/// authorize a no-op or a completed write.
public struct Pocket3AdvancedSettingObservation: Codable, Sendable,
    Equatable, Hashable {
    public static let maximumAge: TimeInterval = 5

    public let setting: Pocket3AdvancedSettingID
    public let sessionID: UUID
    public let generation: UInt64
    public let receivedUptime: TimeInterval
    public let readback: Pocket3AdvancedSettingReadback

    public init(sessionID: UUID, generation: UInt64,
                receivedUptime: TimeInterval,
                readback: Pocket3AdvancedSettingReadback) {
        self.setting = readback.setting
        self.sessionID = sessionID
        self.generation = generation
        self.receivedUptime = receivedUptime
        self.readback = readback
    }

    public init?(sessionID: UUID, generation: UInt64,
                 receivedUptime: TimeInterval,
                 setting: Pocket3AdvancedSettingID,
                 payload: Data, expectedValueLength: Int? = nil) {
        guard let readback = Pocket3AdvancedSettingReadback.decode(
            payload, setting: setting, expectedValueLength: expectedValueLength) else {
            return nil
        }
        self.init(sessionID: sessionID, generation: generation,
                  receivedUptime: receivedUptime, readback: readback)
    }

    public var typedValue: Pocket3AdvancedSettingValue? { readback.typedValue }
    public var raw: Data { readback.raw }

    public func isFresh(nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        generation != 0 && receivedUptime.isFinite && receivedUptime >= 0 &&
            nowUptime.isFinite && maximumAge.isFinite && maximumAge >= 0 &&
            nowUptime >= receivedUptime &&
            nowUptime - receivedUptime <= maximumAge &&
            raw.count <= DUMLCodec.maximumPayloadLength
    }

    public func isFresh(session: NativeCameraSessionStatus,
                        nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        sessionID == session.sessionID && generation == session.generation &&
            session.state.satisfies(.commandReady) &&
            isFresh(nowUptime: nowUptime, maximumAge: maximumAge)
    }

    public func matches(_ target: Pocket3AdvancedSettingTarget) -> Bool {
        setting == target.setting && typedValue == target.value
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let setting = try values.decode(Pocket3AdvancedSettingID.self,
                                        forKey: .setting)
        let sessionID = try values.decode(UUID.self, forKey: .sessionID)
        let generation = try values.decode(UInt64.self, forKey: .generation)
        let receivedUptime = try values.decode(TimeInterval.self,
                                                forKey: .receivedUptime)
        let readback = try values.decode(Pocket3AdvancedSettingReadback.self,
                                         forKey: .readback)
        guard readback.setting == setting else {
            throw Pocket3KeyedParameterError.invalidPayload
        }
        self.init(sessionID: sessionID, generation: generation,
                  receivedUptime: receivedUptime, readback: readback)
    }

    private enum CodingKeys: String, CodingKey {
        case setting
        case sessionID
        case generation
        case receivedUptime
        case readback
    }
}

// MARK: - Fresh one-shot candidate transaction contract

public enum Pocket3AdvancedSettingCoordinatorPhase: String, Codable,
    Sendable, Equatable, CaseIterable {
    case idle
    case noOp
    case awaitingAcknowledgment
    case awaitingReadback
    case completed
    case timedOut
    case cancelled
    case generationChanged
    case failed
}

public enum Pocket3AdvancedSettingCoordinatorError: Error, Codable,
    Sendable, Equatable {
    case sessionNotReady
    case missingSessionIdentity
    case invalidBaseline
    case alreadyAtTarget
    case unsupportedTarget
    case operationInFlight
    case invalidClock
}

public struct Pocket3AdvancedSettingResult: Codable, Sendable, Equatable {
    public let target: Pocket3AdvancedSettingTarget
    public let sessionID: UUID
    public let generation: UInt64
    public let phase: Pocket3AdvancedSettingCoordinatorPhase
    public let baseline: Pocket3AdvancedSettingObservation
    public let transaction: NativeCommandTransactionResult?
    public let readback: Pocket3AdvancedSettingObservation?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let noOp: Bool
    public let failureCode: String?
}

/// Pure coordinator for the reviewed one-byte keyed candidates. It requires
/// a caller-supplied typed readback length because the public sources do not
/// establish one universal 02/8E response envelope for every PID. The
/// coordinator therefore never guesses a field location and sends once at
/// most; ACK alone remains pending until a matching fresh readback arrives.
public struct Pocket3AdvancedSettingCoordinator: Sendable {
    public static let maximumReadbackAge: TimeInterval = 5
    public static let defaultTransactionTimeout: TimeInterval = 3

    public let sessionID: UUID
    public let generation: UInt64
    public private(set) var phase: Pocket3AdvancedSettingCoordinatorPhase = .idle
    public private(set) var target: Pocket3AdvancedSettingTarget?
    public private(set) var request: NativeCommandTransactionRequest?
    public private(set) var transaction: NativeCommandTransactionResult?
    public private(set) var readback: Pocket3AdvancedSettingObservation?
    public private(set) var failureCode: String?

    private var baseline: Pocket3AdvancedSettingObservation?

    public init(session: NativeCameraSessionStatus) throws {
        guard session.generation != 0, session.state.satisfies(.commandReady) else {
            throw Pocket3AdvancedSettingCoordinatorError.sessionNotReady
        }
        guard let sessionID = session.sessionID else {
            throw Pocket3AdvancedSettingCoordinatorError.missingSessionIdentity
        }
        self.sessionID = sessionID
        generation = session.generation
    }

    public mutating func prepare(
        _ target: Pocket3AdvancedSettingTarget,
        baseline: Pocket3AdvancedSettingObservation,
        nowUptime: TimeInterval,
        timeout: TimeInterval = Self.defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        guard phase == .idle else {
            throw Pocket3AdvancedSettingCoordinatorError.operationInFlight
        }
        guard baseline.setting == target.setting,
              baseline.sessionID == sessionID,
              baseline.generation == generation,
              baseline.isFresh(nowUptime: nowUptime,
                               maximumAge: Self.maximumReadbackAge),
              baseline.typedValue != nil else {
            throw Pocket3AdvancedSettingCoordinatorError.invalidBaseline
        }
        self.target = target
        self.baseline = baseline
        transaction = nil
        readback = nil
        request = nil
        failureCode = nil

        if baseline.matches(target) {
            phase = .noOp
            throw Pocket3AdvancedSettingCoordinatorError.alreadyAtTarget
        }

        let keyed: Pocket3KeyedParameterCommand
        switch target {
        case .isoLimit(let value): keyed = try .isoLimitSet(value)
        case .audioChannel(let value): keyed = try .audioChannelSet(value)
        case .vocalBoost(let value): keyed = try .vocalBoostSet(value)
        }
        let frame = NativeCommandFrame(frame: keyed.frame(sequence: 0))
        let parameterID = keyed.parameterID
        let request = try NativeCommandTransactionRequest(
            command: .advancedSetting, generation: generation,
            sessionID: sessionID, frame: frame, timeout: timeout) { response in
                guard response.source == frame.destination,
                      response.destination == frame.source,
                      response.flags == 0x80 || response.flags == 0xC0,
                      response.commandSet == frame.commandSet,
                      response.commandID == frame.commandID,
                      Pocket3KeyedParameterReadback.decode(
                        response.payload, parameterID: parameterID) != nil else {
                    return nil
                }
                return response.payload
            }
        self.request = request
        phase = .awaitingAcknowledgment
        return request
    }

    @discardableResult
    public mutating func apply(_ transaction: NativeCommandTransactionResult,
                               nowUptime: TimeInterval? = nil) -> Bool {
        guard let request, let target, let baseline,
              request.id == transaction.id,
              transaction.command == .advancedSetting,
              transaction.generation == generation,
              transaction.sessionID == sessionID else {
            failureCode = "pocket3_advanced_setting_stale_transaction"
            phase = .generationChanged
            return false
        }
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            if self.transaction == nil { self.transaction = transaction }
            return false
        }
        self.transaction = transaction
        if let nowUptime, !nowUptime.isFinite {
            failureCode = "pocket3_advanced_setting_invalid_clock"
            phase = .failed
            return false
        }
        switch transaction.end {
        case .cancelled:
            failureCode = transaction.failureCode ?? "cancelled"
            phase = .cancelled
            return false
        case .generationChanged:
            failureCode = transaction.failureCode ?? "pocket3_advanced_setting_generation_changed"
            phase = .generationChanged
            return false
        case .timedOut:
            failureCode = transaction.failureCode ?? "pocket3_advanced_setting_timeout"
            phase = .timedOut
            return false
        case .rejected, .failed:
            failureCode = transaction.failureCode ?? "pocket3_advanced_setting_failed"
            phase = .failed
            return false
        case .acknowledged, .observed:
            guard transaction.acknowledged else {
                failureCode = transaction.failureCode ?? "pocket3_advanced_setting_ack_invalid"
                phase = .failed
                return false
            }
        }

        phase = .awaitingReadback
        if let payload = transaction.observedPayload,
           let observedUptime = transaction.observedUptime ?? nowUptime,
           let observed = Pocket3AdvancedSettingObservation(
               sessionID: sessionID, generation: generation,
               receivedUptime: observedUptime, setting: target.setting,
               payload: payload, expectedValueLength: 1),
           observed.isFresh(nowUptime: nowUptime ?? observedUptime,
                           maximumAge: Self.maximumReadbackAge),
           observed.receivedUptime > baseline.receivedUptime,
           observed.matches(target) {
            readback = observed
            phase = .completed
            failureCode = nil
            return true
        }
        return false
    }

    @discardableResult
    public mutating func observe(_ observation: Pocket3AdvancedSettingObservation,
                                 nowUptime: TimeInterval) -> Bool {
        guard let target, let baseline,
              phase == .awaitingReadback,
              transaction?.acknowledged == true,
              observation.sessionID == sessionID,
              observation.generation == generation,
              observation.setting == target.setting,
              observation.isFresh(nowUptime: nowUptime,
                                  maximumAge: Self.maximumReadbackAge),
              observation.receivedUptime > baseline.receivedUptime,
              observation.matches(target) else { return false }
        readback = observation
        phase = .completed
        failureCode = nil
        return true
    }

    @discardableResult
    public mutating func cancel(reason: String = "cancelled") -> Bool {
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            return false
        }
        failureCode = reason
        phase = .cancelled
        return true
    }

    @discardableResult
    public mutating func blockExecution(reason: String) -> Bool {
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            return false
        }
        failureCode = String(reason.prefix(128))
        phase = .failed
        return true
    }

    public var result: Pocket3AdvancedSettingResult? {
        guard let target, let baseline else { return nil }
        return Pocket3AdvancedSettingResult(
            target: target, sessionID: sessionID, generation: generation,
            phase: phase, baseline: baseline, transaction: transaction,
            readback: readback, requested: true,
            submitted: transaction?.submitted == true,
            acknowledged: transaction?.acknowledged == true,
            observed: readback != nil, completed: phase == .completed,
            noOp: phase == .noOp, failureCode: failureCode)
    }
}

public typealias Pocket3NativeAdvancedSettingCoordinator = Pocket3AdvancedSettingCoordinator
public typealias Pocket3NativeAdvancedSettingTarget = Pocket3AdvancedSettingTarget
public typealias Pocket3NativeAdvancedSettingReadback = Pocket3AdvancedSettingReadback

// MARK: - Candidate commands whose schema is known but whose writer gate stays explicit

public struct Pocket3MedTeleCommand: Codable, Sendable, Equatable, Hashable {
    public static let commandSet: UInt8 = 0x02
    public static let commandID: UInt8 = 0xFF
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x01
    public static let requestFlags: UInt8 = 0x40

    public let state: Pocket3MedTeleState

    public init(_ state: Pocket3MedTeleState) { self.state = state }

    public var payload: Data {
        switch state {
        case .enabled: Data([0x00, 0x15, 0x00, 0x0D, 0x00, 0x00, 0x00])
        case .disabled: Data([0x00, 0x15, 0x00, 0x01, 0x00, 0x00, 0x00])
        }
    }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination,
                  sequence: sequence, flags: Self.requestFlags,
                  commandSet: Self.commandSet, commandID: Self.commandID,
                  payload: payload)
    }

    public func encodedFrame(sequence: UInt16) throws -> Data {
        try DUMLCodec.encode(frame(sequence: sequence))
    }
}

public typealias Pocket3MedTeleSettingCommand = Pocket3MedTeleCommand

/// The reviewed catalog exposes Selfie Flip state as a keyed GET and the
/// action as a separate FE09 toggle. The latter is intentionally not a
/// setting writer because it has no matching body-state completion contract.
public struct Pocket3SelfieFlipCommand: Codable, Sendable, Equatable, Hashable {
    public static let toggle = Pocket3GimbalShortcut.flip

    public static func get() throws -> Pocket3KeyedParameterCommand {
        try .selfieFlipGet()
    }

    public static func toggleFrame(sequence: UInt16) -> DUMLFrame {
        Pocket3GimbalShortcut.flip.frame(sequence: sequence)
    }
}
