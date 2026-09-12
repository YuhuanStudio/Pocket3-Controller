import Foundation

// MARK: - Exposure value domains

/// The two exposure-mode selectors observed for 02/1E.  The raw selector is
/// kept in every readback so a future mode cannot be silently called Auto or
/// Manual.
public enum Pocket3ExposureMode: UInt8, Codable, Sendable, Equatable, Hashable,
    CaseIterable {
    case automatic = 0x01
    case manual = 0x04

    public static let auto = Self.automatic

    public var payload: Data { Data([rawValue, 0x00]) }
}

/// Validation errors are deliberately small and transport-independent. The
/// developer route can map these to JSON/CLI errors in a later slice without
/// giving the pure coordinator any network or UI responsibilities.
public enum Pocket3ExposureValidationError: Error, Codable, Sendable, Equatable {
    case invalidValue
    case invalidRequestIdentity
    case invalidTimeout
    case sessionNotReady
    case missingSessionIdentity
    case baselineRequired
    case invalidBaseline
    case alreadyAtTarget
    case operationInFlight
    case staleTransaction
    case unsupportedMode
    case unsupportedFrameRate
    case cancelled
    case executorUnavailable
}

public struct Pocket3ExposureEV: Codable, Sendable, Equatable, Hashable,
    Comparable {
    public static let minimumThirdStops = -9
    public static let maximumThirdStops = 9

    public let thirdStops: Int

    public init(thirdStops: Int) throws {
        guard Self.minimumThirdStops...Self.maximumThirdStops ~= thirdStops else {
            throw Pocket3ExposureValidationError.invalidValue
        }
        self.thirdStops = thirdStops
    }

    public init(_ thirdStops: Int) throws { try self.init(thirdStops: thirdStops) }

    public init(thirds: Int) throws { try self.init(thirdStops: thirds) }

    public var thirds: Int { thirdStops }

    public var rawValue: UInt8 { UInt8(0x10 + thirdStops) }
    public var payload: Data { Data([rawValue]) }
    public var label: String { String(format: "%+.1f EV", Double(thirdStops) / 3.0) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.thirdStops < rhs.thirdStops
    }

    public static func decode(rawValue: UInt8) -> Self? {
        guard (0x07...0x19).contains(rawValue) else { return nil }
        return try? Self(thirdStops: Int(rawValue) - 0x10)
    }
}

/// 02/2A is a sparse selector.  0x01 and selectors outside this reviewed
/// menu intentionally remain unknown in a readback.  Keeping `rawValue` in
/// the enclosing readback means an unknown selector is still inspectable.
public enum Pocket3ExposureISOIndex: UInt8, Codable, Sendable, Equatable,
    Hashable, CaseIterable {
    case automatic = 0x00
    case iso50 = 0x02
    case iso100 = 0x03
    case iso200 = 0x04
    case iso400 = 0x05
    case iso800 = 0x06
    case iso1600 = 0x07
    case iso3200 = 0x08
    case iso6400 = 0x09

    public static let auto = Self.automatic

    public var iso: Int? {
        switch self {
        case .automatic: nil
        case .iso50: 50
        case .iso100: 100
        case .iso200: 200
        case .iso400: 400
        case .iso800: 800
        case .iso1600: 1600
        case .iso3200: 3200
        case .iso6400: 6400
        }
    }

    public var isoValue: Int? { iso }

    public var label: String {
        iso.map(String.init) ?? "Auto"
    }
}

/// The five fractional 02/28 encodings cannot be produced by rounding an
/// ordinary denominator.  They are represented explicitly and retain their
/// exact seven-byte payload.
public enum Pocket3ExposureSpecialShutter: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable {
    case onePointTwoFive = "1/1.25"
    case onePointSixSeven = "1/1.67"
    case twoPointFive = "1/2.5"
    case sixPointTwoFive = "1/6.25"
    case twelvePointFive = "1/12.5"

    public static let oneTwentyFifth = Self.onePointTwoFive
    public static let oneSixtySeventh = Self.onePointSixSeven

    public var approximateDenominator: Double {
        switch self {
        case .onePointTwoFive: 1.25
        case .onePointSixSeven: 1.67
        case .twoPointFive: 2.5
        case .sixPointTwoFive: 6.25
        case .twelvePointFive: 12.5
        }
    }

    public var payload: Data {
        switch self {
        case .onePointTwoFive:
            Data([0x01, 0x01, 0x80, 0x19, 0x00, 0x00, 0x40])
        case .onePointSixSeven:
            Data([0x01, 0x01, 0x80, 0x43, 0x00, 0x00, 0x40])
        case .twoPointFive:
            Data([0x01, 0x02, 0x80, 0x05, 0x00, 0x00, 0x40])
        case .sixPointTwoFive:
            Data([0x01, 0x06, 0x80, 0x19, 0x00, 0x00, 0x40])
        case .twelvePointFive:
            Data([0x01, 0x0C, 0x80, 0x05, 0x00, 0x00, 0x40])
        }
    }
}

public enum Pocket3ExposureCodecError: Error, Codable, Sendable, Equatable {
    case invalidEV
    case invalidISO
    case invalidShutter
    case malformedReadback
    case unsupportedMode
    case unsupportedFrameRate
}

/// A typed shutter choice. Ordinary choices use an integer reciprocal
/// denominator; the five known fractional choices use exact special bytes.
public enum Pocket3ExposureShutterSelection: Codable, Sendable, Equatable,
    Hashable {
    case denominator(UInt16)
    case special(Pocket3ExposureSpecialShutter)

    private static let supportedDenominators: Set<UInt16> = [
        1, 2, 3, 4, 5, 8, 10, 15, 20, 25, 30, 40, 50, 60, 80, 100,
        120, 160, 200, 240, 320, 400, 500, 640, 800, 1000, 1250, 1600,
        2000, 2500, 3200, 4000, 5000, 6400, 8000
    ]

    public init(denominator: UInt16) throws {
        guard Self.supportedDenominators.contains(denominator) else {
            throw Pocket3ExposureCodecError.invalidShutter
        }
        self = .denominator(denominator)
    }

    public init(special: Pocket3ExposureSpecialShutter) {
        self = .special(special)
    }

    public init(label: String) throws {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "1\"", "1s", "1":
            try self.init(denominator: 1)
        case "1/1.25": self = .special(.onePointTwoFive)
        case "1/1.67": self = .special(.onePointSixSeven)
        case "1/2.5": self = .special(.twoPointFive)
        case "1/6.25": self = .special(.sixPointTwoFive)
        case "1/12.5": self = .special(.twelvePointFive)
        default:
            guard normalized.hasPrefix("1/"),
                  let denominator = UInt16(normalized.dropFirst(2)) else {
                throw Pocket3ExposureValidationError.invalidValue
            }
            try self.init(denominator: denominator)
        }
    }

    public var label: String {
        switch self {
        case .denominator(1): "1\""
        case .denominator(let denominator): "1/\(denominator)"
        case .special(let value): value.rawValue
        }
    }

    public var approximateDenominator: Double {
        switch self {
        case .denominator(let value): Double(value)
        case .special(let value): value.approximateDenominator
        }
    }

    public var payload: Data {
        switch self {
        case .special(let value): return value.payload
        case .denominator(let denominator):
            if denominator == 1 {
                return Data([0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x40])
            }
            let encoded = UInt16(0x8000) | denominator
            return Data([0x01, UInt8(encoded & 0xff), UInt8(encoded >> 8),
                         0x00, 0x00, 0x00, 0x40])
        }
    }

    /// Decodes the complete command payload or the three bytes beginning at
    /// the encoded denominator. The latter is useful when a property parser
    /// has already removed the operation and trailing reserved bytes.
    public static func decode(_ payload: Data) -> Self? {
        let bytes = Array(payload)
        let encoded: [UInt8]
        if bytes.count == 7 {
            guard bytes[0] == 0x01, bytes[4] == 0x00, bytes[5] == 0x00,
                  bytes[6] == 0x40 else { return nil }
            encoded = Array(bytes[1...3])
        } else if bytes.count == 3 {
            encoded = bytes
        } else {
            return nil
        }

        switch encoded {
        case [0x01, 0x00, 0x00]: return .denominator(1)
        case [0x01, 0x80, 0x19]: return .special(.onePointTwoFive)
        case [0x01, 0x80, 0x43]: return .special(.onePointSixSeven)
        case [0x02, 0x80, 0x05]: return .special(.twoPointFive)
        case [0x06, 0x80, 0x19]: return .special(.sixPointTwoFive)
        case [0x0C, 0x80, 0x05]: return .special(.twelvePointFive)
        default:
            guard encoded[2] == 0x00, encoded.count == 3,
                  encoded[0] != 0x00,
                  encoded[1] & 0x80 != 0 else { return nil }
            let denominator = UInt16(encoded[0]) | UInt16(encoded[1] & 0x7f) << 8
            guard Self.supportedDenominators.contains(denominator), denominator != 1 else {
                return nil
            }
            return .denominator(denominator)
        }
    }

    public static func parse(_ payload: Data) -> Self? { decode(payload) }

    public var isSupported: Bool {
        switch self {
        case .denominator(let value): Self.supportedDenominators.contains(value)
        case .special: true
        }
    }
}

// MARK: - Mode and frame-rate policy

/// Alias the mode selectors already used by the typed 02/80 camera-status
/// parser. Keeping one raw domain avoids two subtly different “video” enums.
public typealias Pocket3ExposureShootingMode = Pocket3ShootingMode

/// Context is supplied by a fresh mode/format readback. Unknown mode or FPS
/// intentionally rejects shutter validation; the policy must never be
/// generalized from a nearby video mode.
public struct Pocket3ExposureModeContext: Codable, Sendable, Equatable, Hashable {
    public let shootingModeRaw: UInt8?
    public let shootingMode: Pocket3ExposureShootingMode?
    public let frameRateRaw: UInt8?
    public let frameRate: CameraFrameRate?

    public init(shootingModeRaw: UInt8? = nil, frameRateRaw: UInt8? = nil) {
        self.shootingModeRaw = shootingModeRaw
        self.shootingMode = shootingModeRaw.flatMap(Pocket3ExposureShootingMode.init(rawValue:))
        self.frameRateRaw = frameRateRaw
        self.frameRate = frameRateRaw.flatMap(CameraFrameRate.init(rawValue:))
    }

    public init(shootingMode: Pocket3ExposureShootingMode?,
                frameRate: CameraFrameRate? = nil) {
        self.shootingMode = shootingMode
        self.shootingModeRaw = shootingMode?.rawValue
        self.frameRate = frameRate
        self.frameRateRaw = frameRate?.rawValue
    }

    public var frameRateFPS: Int? {
        switch frameRate {
        case .fps24: 24
        case .fps25: 25
        case .fps30: 30
        case .fps48: 48
        case .fps50: 50
        case .fps60: 60
        case .fps120: 120
        case .fps240: 240
        case nil: nil
        }
    }

    public var minimumVideoShutterDenominator: UInt16? {
        guard shootingMode == .video else { return nil }
        return switch frameRate {
        case .fps24, .fps25: 25
        case .fps30: 30
        case .fps48, .fps50: 50
        case .fps60: 60
        case .fps120, .fps240, nil: nil
        }
    }

    public func allows(_ shutter: Pocket3ExposureShutterSelection) -> Bool {
        switch shootingMode {
        case .photo: return true
        case .video:
            guard let minimumVideoShutterDenominator else { return false }
            return shutter.approximateDenominator >= Double(minimumVideoShutterDenominator)
        default: return false
        }
    }
}

// MARK: - Readback and session freshness

/// Typed cam_expo_param readback. The first twenty bytes and their confirmed
/// fields are always retained. Selector/shutter candidates are decoded only
/// when their exact local encodings are recognizable; an unknown raw selector
/// therefore remains visible while never satisfying `matches`.
public struct Pocket3ExposureReadback: Codable, Sendable, Equatable, Hashable {
    public static let minimumRawBytes = 20
    public static let maximumRawBytes = 128

    public let raw: Data
    public let exposureModeRaw: UInt8
    public let exposureMode: Pocket3ExposureMode?
    public let evRaw: UInt8
    public let ev: Pocket3ExposureEV?
    public let selectedISORaw: UInt8
    public let selectedISO: Pocket3ExposureISOIndex?
    public let effectiveISO: UInt32
    public let shutterRaw: Data?
    public let shutter: Pocket3ExposureShutterSelection?

    public init(raw: Data, selectedISORaw: UInt8? = nil,
                shutterRaw: Data? = nil) throws {
        guard raw.count >= Self.minimumRawBytes,
              raw.count <= Self.maximumRawBytes else {
            throw Pocket3ExposureCodecError.malformedReadback
        }
        let bytes = Array(raw)
        self.raw = raw
        exposureModeRaw = bytes[7]
        exposureMode = Pocket3ExposureMode(rawValue: bytes[7])
        evRaw = bytes[6]
        ev = Pocket3ExposureEV.decode(rawValue: bytes[6])
        self.selectedISORaw = selectedISORaw ?? bytes[5]
        selectedISO = Pocket3ExposureISOIndex(rawValue: self.selectedISORaw)
        effectiveISO = UInt32(bytes[16]) | UInt32(bytes[17]) << 8
            | UInt32(bytes[18]) << 16 | UInt32(bytes[19]) << 24

        // The capture exposes the selector at bytes 1...3.  Callers may
        // provide a complete seven-byte candidate when decoding a command
        // response; both forms share the same exact special table.
        let candidate = shutterRaw ?? (raw.count >= 4 ? Data(bytes[1...3]) : nil)
        if let candidate {
            guard candidate.count <= Self.maximumRawBytes else {
                throw Pocket3ExposureCodecError.malformedReadback
            }
            self.shutterRaw = candidate
            self.shutter = Pocket3ExposureShutterSelection.decode(candidate)
        } else {
            self.shutterRaw = nil
            self.shutter = nil
        }
    }

    public static func decode(_ raw: Data, selectedISORaw: UInt8? = nil,
                              shutterRaw: Data? = nil) -> Self? {
        try? Self(raw: raw, selectedISORaw: selectedISORaw,
                  shutterRaw: shutterRaw)
    }

    public static func parse(_ raw: Data, selectedISORaw: UInt8? = nil,
                             shutterRaw: Data? = nil) -> Self? {
        decode(raw, selectedISORaw: selectedISORaw, shutterRaw: shutterRaw)
    }

    public var isUnknownMode: Bool { exposureMode == nil }
    public var isUnknownISO: Bool { selectedISO == nil }
    public var isUnknownShutter: Bool { shutterRaw != nil && shutter == nil }
    public var mode: Pocket3ExposureMode? { exposureMode }
    public var isoIndex: Pocket3ExposureISOIndex? { selectedISO }
    public var unknownSelectedISO: Bool { selectedISO == nil }
    public var unknownSelectedShutter: Bool { isUnknownShutter }

    public func matches(_ target: Pocket3ExposureTarget) -> Bool {
        switch target {
        case .mode(let expected): return exposureMode == expected
        case .ev(let expected):
            return exposureMode == .automatic && ev == expected
        case .iso(let expected):
            guard exposureMode == .manual,
                  selectedISO == expected,
                  selectedISORaw == expected.rawValue else { return false }
            guard expected == .automatic else {
                guard let expectedISO = expected.isoValue else { return false }
                return effectiveISO == UInt32(expectedISO)
            }
            return effectiveISO > 0
        case .shutter(let expected):
            return exposureMode == .manual && shutter == expected
        case .isoLimit: return false
        }
    }
}

public struct Pocket3ExposureObservation: Codable, Sendable, Equatable, Hashable {
    public static let maximumAge: TimeInterval = 5
    public static let maximumRawBytes = Pocket3ExposureReadback.maximumRawBytes

    public let sessionID: UUID
    public let generation: UInt64
    public let receivedUptime: TimeInterval
    public let readback: Pocket3ExposureReadback

    public init(sessionID: UUID, generation: UInt64, receivedUptime: TimeInterval,
                readback: Pocket3ExposureReadback) {
        self.sessionID = sessionID
        self.generation = generation
        self.receivedUptime = receivedUptime
        self.readback = readback
    }

    public init?(sessionID: UUID, generation: UInt64, receivedUptime: TimeInterval,
                 raw: Data, selectedISORaw: UInt8? = nil,
                 shutterRaw: Data? = nil) {
        guard let readback = Pocket3ExposureReadback.decode(raw,
            selectedISORaw: selectedISORaw, shutterRaw: shutterRaw) else { return nil }
        self.init(sessionID: sessionID, generation: generation,
                  receivedUptime: receivedUptime, readback: readback)
    }

    public init?(sessionID: UUID, generation: UInt64,
                 observation: CameraSettingsObservation) {
        guard observation.property == .exposure,
              case .exposure(let value) = observation.readOnlyValue else { return nil }
        guard let value = Pocket3ExposureObservation(
            sessionID: sessionID, generation: generation,
            receivedUptime: observation.receivedUptime, raw: value.raw) else {
            return nil
        }
        self = value
    }

    public var raw: Data { readback.raw }
    public var mode: Pocket3ExposureMode? { readback.exposureMode }
    public var isoIndex: Pocket3ExposureISOIndex? { readback.selectedISO }
    public var unknownSelectedISO: Bool { readback.unknownSelectedISO }
    public var unknownSelectedShutter: Bool { readback.unknownSelectedShutter }
    public var exposureMode: Pocket3ExposureMode? { readback.exposureMode }
    public var selectedISO: Pocket3ExposureISOIndex? { readback.selectedISO }
    public var effectiveISO: UInt32 { readback.effectiveISO }
    public var shutter: Pocket3ExposureShutterSelection? { readback.shutter }

    public func isFresh(nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        generation != 0 && receivedUptime.isFinite && receivedUptime >= 0 &&
            nowUptime.isFinite && maximumAge.isFinite && maximumAge >= 0 &&
            nowUptime >= receivedUptime && nowUptime - receivedUptime <= maximumAge &&
            raw.count <= Self.maximumRawBytes
    }

    public func isFresh(session: NativeCameraSessionStatus,
                        nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        sessionID == session.sessionID && generation == session.generation &&
            session.state.satisfies(.commandReady) &&
            isFresh(nowUptime: nowUptime, maximumAge: maximumAge)
    }

    public func matches(_ target: Pocket3ExposureTarget) -> Bool {
        readback.matches(target)
    }
}

public typealias Pocket3ExposureBaseline = Pocket3ExposureObservation
public typealias Pocket3ExposureReadbackObservation = Pocket3ExposureObservation

public struct Pocket3ExposureValidationSnapshot: Codable, Sendable, Equatable {
    public let session: NativeCameraSessionStatus
    public let exposure: Pocket3ExposureObservation?
    public let isoLimit: Pocket3AdvancedSettingObservation?
    public let modeContext: Pocket3ExposureModeContext?
    public let nowUptime: TimeInterval

    public init(session: NativeCameraSessionStatus,
                exposure: Pocket3ExposureObservation? = nil,
                isoLimit: Pocket3AdvancedSettingObservation? = nil,
                modeContext: Pocket3ExposureModeContext? = nil,
                nowUptime: TimeInterval) {
        self.session = session
        self.exposure = exposure
        self.isoLimit = isoLimit
        self.modeContext = modeContext
        self.nowUptime = nowUptime
    }

    /// Label-compatible initializer used by the developer validation tests.
    /// The property names make it explicit that these values are caller
    /// supplied fresh baselines; the initializer still performs no query.
    public init(session: NativeCameraSessionStatus,
                exposureBaseline: Pocket3ExposureObservation? = nil,
                isoLimitBaseline: Pocket3AdvancedSettingObservation? = nil,
                context: Pocket3ExposureModeContext = .init(
                    shootingModeRaw: Pocket3ShootingMode.video.rawValue,
                    frameRateRaw: CameraFrameRate.fps30.rawValue),
                now: TimeInterval = 0) {
        self.init(session: session, exposure: exposureBaseline,
                  isoLimit: isoLimitBaseline, modeContext: context,
                  nowUptime: now)
    }
}

// MARK: - Commands and transaction adapters

public enum Pocket3ExposureTarget: Codable, Sendable, Equatable, Hashable {
    case mode(Pocket3ExposureMode)
    case ev(Pocket3ExposureEV)
    case iso(Pocket3ExposureISOIndex)
    case shutter(Pocket3ExposureShutterSelection)
    case isoLimit(Pocket3ISOLimit)

    public var command: NativeCameraSessionCommand {
        switch self {
        case .isoLimit: .advancedSetting
        default: .exposure
        }
    }

    public var commandID: UInt8 {
        switch self {
        case .mode: 0x1E
        case .ev: 0x2E
        case .iso: 0x2A
        case .shutter: 0x28
        case .isoLimit: 0x8E
        }
    }

    public var isExposurePropertyTarget: Bool {
        if case .isoLimit = self { return false }
        return true
    }
}

public struct Pocket3ManualExposurePreset: Codable, Sendable, Equatable, Hashable {
    public let mode: Pocket3ExposureMode
    public let iso: Pocket3ExposureISOIndex
    public let shutter: Pocket3ExposureShutterSelection

    public init(iso: Pocket3ExposureISOIndex,
                shutter: Pocket3ExposureShutterSelection,
                mode: Pocket3ExposureMode = .manual) {
        self.mode = mode
        self.iso = iso
        self.shutter = shutter
    }

    public var targets: [Pocket3ExposureTarget] {
        [.mode(mode), .iso(iso), .shutter(shutter)]
    }
}

public enum Pocket3ExposureOperation: Codable, Sendable, Equatable, Hashable {
    case mode(Pocket3ExposureMode)
    case ev(Pocket3ExposureEV)
    case iso(Pocket3ExposureISOIndex)
    case shutter(Pocket3ExposureShutterSelection)
    case isoLimit(Pocket3ISOLimit)
    case manualPreset(Pocket3ManualExposurePreset)

    public var targets: [Pocket3ExposureTarget] {
        switch self {
        case .mode(let value): [.mode(value)]
        case .ev(let value): [.ev(value)]
        case .iso(let value): [.iso(value)]
        case .shutter(let value): [.shutter(value)]
        case .isoLimit(let value): [.isoLimit(value)]
        case .manualPreset(let preset): preset.targets
        }
    }
}

public struct Pocket3ExposureCommand: Codable, Sendable, Equatable, Hashable {
    public let target: Pocket3ExposureTarget

    public init(_ target: Pocket3ExposureTarget) throws {
        switch target {
        case .shutter(let value):
            guard value.isSupported else { throw Pocket3ExposureCodecError.invalidShutter }
        default: break
        }
        self.target = target
    }

    public static func mode(_ value: Pocket3ExposureMode) -> Self { try! Self(.mode(value)) }
    public static func exposureMode(_ value: Pocket3ExposureMode) -> Self { mode(value) }
    public static func ev(_ value: Pocket3ExposureEV) -> Self { try! Self(.ev(value)) }
    public static func autoEV(thirdStops: Int) throws -> Self {
        try Self(.ev(Pocket3ExposureEV(thirdStops: thirdStops)))
    }
    public static func iso(_ value: Pocket3ExposureISOIndex) -> Self { try! Self(.iso(value)) }
    public static func manualISO(_ value: Pocket3ExposureISOIndex) -> Self { iso(value) }
    public static func shutter(_ value: Pocket3ExposureShutterSelection) throws -> Self {
        try Self(.shutter(value))
    }
    public static func isoLimit(_ value: Pocket3ISOLimit) -> Self {
        try! Self(.isoLimit(value))
    }

    public var commandSet: UInt8 { 0x02 }
    public var commandID: UInt8 { target.commandID }
    public var command: NativeCameraSessionCommand { target.command }
    public var payload: Data {
        switch target {
        case .mode(let value): value.payload
        case .ev(let value): value.payload
        case .iso(let value): Data([value.rawValue])
        case .shutter(let value): value.payload
        case .isoLimit(let value):
            (try? Pocket3KeyedParameterCommand.isoLimitSet(value))?.payload ?? Data()
        }
    }

    public var frameTemplate: NativeCommandFrame {
        // All reviewed payloads are bounded well below DUML's maximum. This
        // initializer is kept non-throwing for callers composing fixtures.
        try! NativeCommandFrame(source: 0x02, destination: 0x01,
            flags: 0x40, commandSet: commandSet, commandID: commandID,
            payload: payload)
    }

    public var frame: NativeCommandFrame { frameTemplate }

    public func frame(sequence: UInt16) -> DUMLFrame { frameTemplate.frame(sequence: sequence) }
}

public extension Pocket3NativeCommandAdapter {
    static func exposure(_ target: Pocket3ExposureTarget,
                         generation: UInt64, sessionID: UUID? = nil,
                         timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        let command = try Pocket3ExposureCommand(target)
        let frame = command.frameTemplate
        return try NativeCommandTransactionRequest(command: target.command,
            generation: generation, sessionID: sessionID, frame: frame,
            timeout: timeout) { response in
                Pocket3ExposureObservationDecoder.payload(from: response,
                                                           target: target)
            }
    }

    static func exposure(_ command: Pocket3ExposureCommand,
                         generation: UInt64, sessionID: UUID? = nil,
                         timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        try exposure(command.target, generation: generation,
                     sessionID: sessionID, timeout: timeout)
    }
}

private enum Pocket3ExposureObservationDecoder {
    static func payload(from frame: DUMLFrame,
                        target: Pocket3ExposureTarget) -> Data? {
        switch target {
        case .isoLimit:
            guard frame.source == 0x01, frame.destination == 0x02,
                  frame.commandSet == 0x02, frame.commandID == 0x8E,
                  Pocket3KeyedParameterReadback.decode(frame.payload,
                      parameterID: 0x000F, expectedValueLength: 1) != nil else {
                return nil
            }
            return frame.payload
        default:
            if frame.source == 0x28, frame.destination == 0x02,
               frame.flags == 0, frame.commandSet == 0,
               frame.commandID == 0x99,
               let push = try? CameraPropertyCodec.decodePush(from: frame),
               push.property == .exposure,
               Pocket3ExposureReadback.decode(push.value) != nil {
                return push.value
            }
            guard frame.source == 0x01, frame.destination == 0x02,
                  frame.commandSet == 0x02,
                  frame.commandID == target.commandID,
                  Pocket3ExposureReadback.decode(frame.payload) != nil else {
                return nil
            }
            return frame.payload
        }
    }
}

// MARK: - Pure coordinator

public enum Pocket3ExposureCoordinatorPhase: String, Codable, Sendable,
    Equatable, CaseIterable {
    case idle
    case noOp
    case awaitingAcknowledgment
    case awaitingReadback
    case awaitingNextStep
    case completed
    case timedOut
    case cancelled
    case generationChanged
    case failed
}

public enum Pocket3ExposureCoordinatorError: Error, Codable, Sendable,
    Equatable {
    case sessionNotReady
    case missingSessionIdentity
    case invalidBaseline
    case missingModeContext
    case unsupportedMode
    case invalidShutterForFrameRate
    case alreadyAtTarget
    case operationInFlight
    case staleTransaction
    case invalidClock
}

public struct Pocket3ExposureStepEvidence: Codable, Sendable, Equatable {
    public let target: Pocket3ExposureTarget
    public let requestID: UUID
    public let request: Pocket3ExposureRequestEvidence
    public let transaction: NativeCommandTransactionResult?
    public let readback: Pocket3ExposureObservation?
    public let completed: Bool

    public init(target: Pocket3ExposureTarget, requestID: UUID,
                request: Pocket3ExposureRequestEvidence,
                transaction: NativeCommandTransactionResult? = nil,
                readback: Pocket3ExposureObservation? = nil,
                completed: Bool = false) {
        self.target = target
        self.requestID = requestID
        self.request = request
        self.transaction = transaction
        self.readback = readback
        self.completed = completed
    }
}

/// Codable evidence for the non-Codable transaction request (the request
/// carries a closure used to decode an ACK response).
public struct Pocket3ExposureRequestEvidence: Codable, Sendable, Equatable {
    public let id: UUID
    public let command: NativeCameraSessionCommand
    public let generation: UInt64
    public let sessionID: UUID?
    public let frame: NativeCommandFrame
    public let timeout: TimeInterval

    public init(_ request: NativeCommandTransactionRequest) {
        id = request.id
        command = request.command
        generation = request.generation
        sessionID = request.sessionID
        frame = request.frame
        timeout = request.timeout
    }
}

public struct Pocket3ExposureResult: Codable, Sendable, Equatable {
    public let operation: Pocket3ExposureOperation
    public let sessionID: UUID
    public let generation: UInt64
    public let phase: Pocket3ExposureCoordinatorPhase
    public let baseline: Pocket3ExposureObservation?
    public let isoLimitBaseline: Pocket3AdvancedSettingObservation?
    public let transaction: NativeCommandTransactionResult?
    public let readback: Pocket3ExposureObservation?
    public let isoLimitReadback: Pocket3AdvancedSettingObservation?
    public let steps: [Pocket3ExposureStepEvidence]
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let noOp: Bool
    public let failureCode: String?

    public var partial: Bool { submitted && !completed }
    public var dryRun: Bool { !submitted && phase != .noOp }
    public var acknowledgedCount: Int { transaction?.acknowledged == true ? 1 : 0 }
}

/// Result returned by the single injected native executor. A response may
/// carry only transport evidence, only one typed readback, or both; the
/// coordinator decides whether that evidence is sufficient for completion.
public struct Pocket3ExposureExecutionResult: Sendable, Equatable {
    public let transaction: NativeCommandTransactionResult
    public let exposureReadback: Pocket3ExposureObservation?
    public let isoLimitReadback: Pocket3AdvancedSettingObservation?

    public init(transaction: NativeCommandTransactionResult,
                exposureReadback: Pocket3ExposureObservation? = nil,
                isoLimitReadback: Pocket3AdvancedSettingObservation? = nil) {
        self.transaction = transaction
        self.exposureReadback = exposureReadback
        self.isoLimitReadback = isoLimitReadback
    }
}

/// A command/readback state machine for the typed exposure candidates. It
/// creates one request per manual-preset step, in mode → ISO → shutter order.
/// Every request is fenced by the exact native session generation and every
/// completion requires ACK plus a fresh matching readback.
public struct Pocket3ExposureCoordinator: Sendable {
    public static let maximumReadbackAge: TimeInterval = 5
    public static let defaultTransactionTimeout: TimeInterval = 3

    public let sessionID: UUID
    public let generation: UInt64
    public private(set) var phase: Pocket3ExposureCoordinatorPhase = .idle
    public private(set) var operation: Pocket3ExposureOperation?
    public private(set) var request: NativeCommandTransactionRequest?
    public private(set) var transaction: NativeCommandTransactionResult?
    public private(set) var readback: Pocket3ExposureObservation?
    public private(set) var isoLimitReadback: Pocket3AdvancedSettingObservation?
    public private(set) var failureCode: String?
    public private(set) var steps: [Pocket3ExposureStepEvidence] = []

    private var baseline: Pocket3ExposureObservation?
    private var isoLimitBaseline: Pocket3AdvancedSettingObservation?
    private var pendingTargets: [Pocket3ExposureTarget] = []
    private var currentTarget: Pocket3ExposureTarget?
    private var modeContext: Pocket3ExposureModeContext?

    public var nextRequest: NativeCommandTransactionRequest? { request }
    public var plannedTargets: [Pocket3ExposureTarget] {
        (currentTarget.map { [$0] } ?? []) + pendingTargets
    }

    public init(session: NativeCameraSessionStatus,
                modeContext: Pocket3ExposureModeContext? = nil) throws {
        guard session.generation != 0, session.state.satisfies(.commandReady) else {
            throw Pocket3ExposureCoordinatorError.sessionNotReady
        }
        guard let sessionID = session.sessionID else {
            throw Pocket3ExposureCoordinatorError.missingSessionIdentity
        }
        self.sessionID = sessionID
        generation = session.generation
        self.modeContext = modeContext
    }

    @discardableResult
    public mutating func prepare(
        _ operation: Pocket3ExposureOperation,
        snapshot: Pocket3ExposureValidationSnapshot,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        guard phase == .idle else { throw Pocket3ExposureCoordinatorError.operationInFlight }
        guard snapshot.session.sessionID == sessionID,
              snapshot.session.generation == generation,
              snapshot.session.state.satisfies(.commandReady),
              snapshot.nowUptime.isFinite else {
            throw Pocket3ExposureCoordinatorError.invalidBaseline
        }
        self.operation = operation
        self.modeContext = snapshot.modeContext ?? self.modeContext
        self.baseline = snapshot.exposure
        self.isoLimitBaseline = snapshot.isoLimit
        self.failureCode = nil
        self.transaction = nil
        self.readback = nil
        self.isoLimitReadback = nil
        self.steps = []

        pendingTargets = try validatedTargets(operation, snapshot: snapshot)
        if pendingTargets.isEmpty {
            phase = .noOp
            throw Pocket3ExposureCoordinatorError.alreadyAtTarget
        }
        return try prepareNext(snapshot: snapshot, timeout: timeout)
    }

    /// Supplies the newest property snapshot for the next atomic preset
    /// step. The caller may pass the previous successful readback when it is
    /// still fresh; no hidden GET or retry is performed here.
    public mutating func prepareNext(
        snapshot: Pocket3ExposureValidationSnapshot,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        guard phase == .idle || phase == .awaitingNextStep else {
            throw Pocket3ExposureCoordinatorError.operationInFlight
        }
        guard let operation, !pendingTargets.isEmpty,
              snapshot.session.sessionID == sessionID,
              snapshot.session.generation == generation,
              snapshot.session.state.satisfies(.commandReady),
              snapshot.nowUptime.isFinite else {
            throw Pocket3ExposureCoordinatorError.invalidBaseline
        }

        let target = pendingTargets.removeFirst()
        try validateBaseline(for: target, snapshot: snapshot)
        if target.isExposurePropertyTarget { baseline = snapshot.exposure }
        else { isoLimitBaseline = snapshot.isoLimit }
        currentTarget = target
        transaction = nil
        readback = nil
        isoLimitReadback = nil
        failureCode = nil

        if targetMatches(target, snapshot: snapshot) {
            if pendingTargets.isEmpty {
                phase = .noOp
                throw Pocket3ExposureCoordinatorError.alreadyAtTarget
            }
            phase = .awaitingNextStep
            return try prepareNext(snapshot: snapshot, timeout: timeout)
        }

        let command = try Pocket3ExposureCommand(target)
        let request = try NativeCommandTransactionRequest(
            command: target.command, generation: generation, sessionID: sessionID,
            frame: command.frameTemplate, timeout: timeout) { response in
                Pocket3ExposureObservationDecoder.payload(from: response,
                                                           target: target)
            }
        self.request = request
        phase = .awaitingAcknowledgment
        _ = operation
        return request
    }

    /// Applies a transaction and optionally supplies a separately received
    /// typed readback. Passing a readback explicitly avoids guessing an
    /// unconfirmed property offset; `apply(_:)` uses only an adapter-validated
    /// `observedPayload` when one is available.
    @discardableResult
    public mutating func apply(
        _ transaction: NativeCommandTransactionResult,
        readback: Pocket3ExposureObservation? = nil,
        isoLimitReadback: Pocket3AdvancedSettingObservation? = nil,
        nowUptime: TimeInterval? = nil
    ) -> Bool {
        guard let request, let currentTarget,
              request.id == transaction.id,
              transaction.command == currentTarget.command,
              transaction.generation == generation,
              transaction.sessionID == sessionID else {
            failureCode = "native_exposure_stale_transaction"
            phase = .generationChanged
            return false
        }
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            return false
        }
        if let nowUptime, !nowUptime.isFinite {
            self.transaction = transaction
            failureCode = "native_exposure_invalid_clock"
            phase = .failed
            return false
        }
        self.transaction = transaction

        let decodedExposure = readback ?? decodeExposureObservation(
            transaction.observedPayload, transaction: transaction)
        let decodedISOLimit = isoLimitReadback ?? decodeISOLimitObservation(
            transaction.observedPayload, transaction: transaction)
        if currentTarget.isExposurePropertyTarget {
            self.readback = decodedExposure
        } else {
            self.isoLimitReadback = decodedISOLimit
        }

        switch transaction.end {
        case .cancelled:
            failureCode = transaction.failureCode ?? "cancelled"
            phase = .cancelled
            appendEvidence(completed: false)
            return false
        case .generationChanged:
            failureCode = transaction.failureCode ?? "native_exposure_generation_changed"
            phase = .generationChanged
            appendEvidence(completed: false)
            return false
        case .timedOut:
            failureCode = transaction.failureCode ?? "native_exposure_timeout"
            phase = .timedOut
            appendEvidence(completed: false)
            return false
        case .rejected, .failed:
            failureCode = transaction.failureCode ?? "native_exposure_failed"
            phase = .failed
            appendEvidence(completed: false)
            return false
        case .acknowledged, .observed:
            guard transaction.submitted, transaction.acknowledged else {
                failureCode = transaction.failureCode ?? "native_exposure_ack_invalid"
                phase = .failed
                appendEvidence(completed: false)
                return false
            }
        }

        phase = .awaitingReadback
        if currentTarget.isExposurePropertyTarget, let decodedExposure {
            _ = observe(decodedExposure, nowUptime: nowUptime ?? decodedExposure.receivedUptime)
        } else if !currentTarget.isExposurePropertyTarget, let decodedISOLimit {
            _ = observe(isoLimit: decodedISOLimit,
                         nowUptime: nowUptime ?? decodedISOLimit.receivedUptime)
        }
        return phase == .completed
    }

    @discardableResult
    public mutating func apply(_ execution: Pocket3ExposureExecutionResult,
                               nowUptime: TimeInterval? = nil) -> Bool {
        apply(execution.transaction, readback: execution.exposureReadback,
              isoLimitReadback: execution.isoLimitReadback, nowUptime: nowUptime)
    }

    /// Records a fresh, typed exposure property after an ACK. Manual presets
    /// remain in `.awaitingNextStep` after one matching step so the caller can
    /// explicitly provide the next fresh baseline.
    @discardableResult
    public mutating func observe(_ observation: Pocket3ExposureObservation,
                                 nowUptime: TimeInterval) -> Bool {
        guard let target = currentTarget, target.isExposurePropertyTarget,
              let baseline,
              observation.sessionID == sessionID,
              observation.generation == generation,
              observation.isFresh(nowUptime: nowUptime,
                                  maximumAge: Self.maximumReadbackAge),
              observation.receivedUptime > baseline.receivedUptime,
              phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            return false
        }
        if let submitted = transaction?.submittedUptime,
           observation.receivedUptime <= submitted { return false }
        self.readback = observation
        guard transaction?.acknowledged == true else { return false }
        guard observation.matches(target) else {
            failureCode = observation.readback.isUnknownISO ||
                observation.readback.isUnknownShutter ||
                observation.readback.isUnknownMode
                ? "native_exposure_selected_readback_unknown"
                : "native_exposure_readback_mismatch"
            phase = .awaitingReadback
            return false
        }
        appendEvidence(completed: true)
        if pendingTargets.isEmpty {
            phase = .completed
        } else {
            phase = .awaitingNextStep
        }
        failureCode = nil
        return phase == .completed
    }

    @discardableResult
    public mutating func observe(
        isoLimit observation: Pocket3AdvancedSettingObservation,
        nowUptime: TimeInterval
    ) -> Bool {
        guard let target = currentTarget, case .isoLimit(let expected) = target,
              let baseline = isoLimitBaseline,
              observation.sessionID == sessionID,
              observation.generation == generation,
              observation.isFresh(nowUptime: nowUptime,
                                  maximumAge: Self.maximumReadbackAge),
              observation.receivedUptime > baseline.receivedUptime,
              phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            return false
        }
        if let submitted = transaction?.submittedUptime,
           observation.receivedUptime <= submitted { return false }
        isoLimitReadback = observation
        guard transaction?.acknowledged == true else { return false }
        guard observation.matches(.isoLimit(expected)) else {
            failureCode = observation.typedValue == nil
                ? "native_exposure_selected_readback_unknown"
                : "native_exposure_readback_mismatch"
            phase = .awaitingReadback
            return false
        }
        appendEvidence(completed: true)
        phase = .completed
        failureCode = nil
        return true
    }

    @discardableResult
    public mutating func cancel(generation callbackGeneration: UInt64) -> Bool {
        guard callbackGeneration == generation,
              phase == .awaitingAcknowledgment || phase == .awaitingReadback ||
                phase == .awaitingNextStep else { return false }
        phase = .cancelled
        failureCode = "cancelled"
        return true
    }

    @discardableResult
    public mutating func blockExecution(reason: String) -> Bool {
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback ||
            phase == .awaitingNextStep else { return false }
        phase = .failed
        failureCode = String(reason.prefix(128))
        return true
    }

    public var result: Pocket3ExposureResult? {
        guard let operation else { return nil }
        return Pocket3ExposureResult(operation: operation, sessionID: sessionID,
            generation: generation, phase: phase, baseline: baseline,
            isoLimitBaseline: isoLimitBaseline, transaction: transaction,
            readback: readback, isoLimitReadback: isoLimitReadback,
            steps: steps, requested: true,
            submitted: transaction?.submitted == true,
            acknowledged: transaction?.acknowledged == true,
            observed: readback != nil || isoLimitReadback != nil,
            completed: phase == .completed, noOp: phase == .noOp,
            failureCode: failureCode)
    }

    private func validatedTargets(_ operation: Pocket3ExposureOperation,
                                  snapshot: Pocket3ExposureValidationSnapshot)
        throws -> [Pocket3ExposureTarget] {
        guard snapshot.exposure != nil || snapshot.isoLimit != nil else {
            throw Pocket3ExposureCoordinatorError.invalidBaseline
        }
        if case .manualPreset(let preset) = operation {
            guard preset.mode == .manual,
                  let baseline = snapshot.exposure,
                  baseline.sessionID == sessionID,
                  baseline.generation == generation,
                  baseline.isFresh(nowUptime: snapshot.nowUptime,
                                   maximumAge: Self.maximumReadbackAge),
                  baseline.readback.exposureMode != nil else {
                throw Pocket3ExposureCoordinatorError.invalidBaseline
            }
            guard let context = snapshot.modeContext, context.allows(preset.shutter) else {
                throw snapshot.modeContext?.shootingMode == .video
                    ? Pocket3ExposureCoordinatorError.invalidShutterForFrameRate
                    : Pocket3ExposureCoordinatorError.missingModeContext
            }
            var presetTargets = preset.targets
            if baseline.readback.exposureMode == .manual {
                presetTargets.removeFirst()
            }
            return presetTargets.filter { !targetMatches($0, snapshot: snapshot) }
        }
        var targets = operation.targets
        for target in targets {
            try validateBaseline(for: target, snapshot: snapshot)
        }
        // Filter only known current matches. Unknown selectors cannot be a
        // no-op because `targetMatches` returns false for them.
        targets = targets.filter { !targetMatches($0, snapshot: snapshot) }
        return targets
    }

    private func validateBaseline(for target: Pocket3ExposureTarget,
                                  snapshot: Pocket3ExposureValidationSnapshot) throws {
        if target.isExposurePropertyTarget {
            guard let baseline = snapshot.exposure,
                  baseline.sessionID == sessionID,
                  baseline.generation == generation,
                  baseline.isFresh(nowUptime: snapshot.nowUptime,
                                   maximumAge: Self.maximumReadbackAge) else {
                throw Pocket3ExposureCoordinatorError.invalidBaseline
            }
            switch target {
            case .ev:
                guard baseline.readback.exposureMode == .automatic else {
                    throw Pocket3ExposureCoordinatorError.unsupportedMode
                }
            case .iso, .shutter:
                guard baseline.readback.exposureMode == .manual else {
                    throw Pocket3ExposureCoordinatorError.unsupportedMode
                }
            case .mode, .isoLimit: break
            }
            if case .shutter(let shutter) = target {
                guard let context = snapshot.modeContext else {
                    throw Pocket3ExposureCoordinatorError.missingModeContext
                }
                guard context.allows(shutter) else {
                    throw context.shootingMode == .video
                        ? Pocket3ExposureCoordinatorError.invalidShutterForFrameRate
                        : Pocket3ExposureCoordinatorError.unsupportedMode
                }
            }
        } else {
            guard let baseline = snapshot.isoLimit,
                  baseline.setting == .isoLimit,
                  baseline.sessionID == sessionID,
                  baseline.generation == generation,
                  baseline.isFresh(nowUptime: snapshot.nowUptime,
                                   maximumAge: Self.maximumReadbackAge) else {
                throw Pocket3ExposureCoordinatorError.invalidBaseline
            }
        }
    }

    private func targetMatches(_ target: Pocket3ExposureTarget,
                               snapshot: Pocket3ExposureValidationSnapshot) -> Bool {
        switch target {
        case .isoLimit(let expected):
            snapshot.isoLimit?.matches(.isoLimit(expected)) == true
        default:
            snapshot.exposure?.matches(target) == true
        }
    }

    private mutating func appendEvidence(completed: Bool) {
        guard let target = currentTarget, let request else { return }
        steps.append(Pocket3ExposureStepEvidence(target: target,
            requestID: request.id, request: .init(request), transaction: transaction,
            readback: readback, completed: completed))
    }

    private func decodeExposureObservation(_ payload: Data?,
                                           transaction: NativeCommandTransactionResult)
        -> Pocket3ExposureObservation? {
        guard let payload,
              let uptime = transaction.observedUptime ?? transaction.finishedUptime,
              let readback = Pocket3ExposureReadback.decode(payload) else { return nil }
        return Pocket3ExposureObservation(sessionID: sessionID, generation: generation,
            receivedUptime: uptime, readback: readback)
    }

    private func decodeISOLimitObservation(_ payload: Data?,
                                           transaction: NativeCommandTransactionResult)
        -> Pocket3AdvancedSettingObservation? {
        guard let payload,
              let uptime = transaction.observedUptime ?? transaction.finishedUptime,
              let readback = Pocket3AdvancedSettingReadback.decode(
                  payload, setting: .isoLimit, expectedValueLength: 1) else { return nil }
        return Pocket3AdvancedSettingObservation(sessionID: sessionID,
            generation: generation, receivedUptime: uptime, readback: readback)
    }
}

public typealias Pocket3NativeExposureCoordinator = Pocket3ExposureCoordinator
public typealias Pocket3NativeExposureReadback = Pocket3ExposureReadback
public typealias Pocket3NativeExposureObservation = Pocket3ExposureObservation

// MARK: - Developer validation adapter (pure/fake-test boundary)

public enum NativeExposureValidationOperation: String, Codable, Sendable,
    Equatable, CaseIterable {
    case mode
    case ev
    case iso
    case shutter
    case isoLimit = "iso-limit"
    case manualPreset = "manual-preset"
}

public struct NativeExposureValidationRequest: Codable, Sendable, Equatable {
    public let action: NativeExposureValidationOperation
    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let value: String?
    public let iso: String?
    public let shutter: String?
    public let execute: Bool
    public let timeout: TimeInterval

    public init(action: NativeExposureValidationOperation,
                expectedSessionID: UUID, peripheralID: UUID,
                generation: UInt64, value: String? = nil,
                iso: String? = nil, shutter: String? = nil,
                execute: Bool = false, timeout: TimeInterval = 3) throws {
        guard generation > 0, timeout.isFinite, timeout > 0,
              timeout <= NativeCommandTransactionRequest.maximumTimeout else {
            throw Pocket3ExposureValidationError.invalidTimeout
        }
        switch action {
        case .mode:
            guard let value, Self.parseMode(value) != nil,
                  iso == nil, shutter == nil else {
                throw Pocket3ExposureValidationError.invalidValue
            }
        case .ev:
            guard let value, Self.parseEV(value) != nil,
                  iso == nil, shutter == nil else {
                throw Pocket3ExposureValidationError.invalidValue
            }
        case .iso:
            guard let value = value ?? iso, Self.parseISO(value) != nil,
                  shutter == nil else { throw Pocket3ExposureValidationError.invalidValue }
        case .shutter:
            guard let value = value ?? shutter, Self.parseShutter(value) != nil,
                  iso == nil else { throw Pocket3ExposureValidationError.invalidValue }
        case .isoLimit:
            guard let value, Self.parseISOLimit(value) != nil,
                  iso == nil, shutter == nil else {
                throw Pocket3ExposureValidationError.invalidValue
            }
        case .manualPreset:
            guard value == nil, let iso, let shutter,
                  Self.parseISO(iso) != nil, Self.parseShutter(shutter) != nil else {
                throw Pocket3ExposureValidationError.invalidValue
            }
        }
        self.action = action
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.value = value
        self.iso = iso
        self.shutter = shutter
        self.execute = execute
        self.timeout = timeout
    }

    public var operation: Pocket3ExposureOperation? {
        switch action {
        case .mode: return value.flatMap(Self.parseMode).map(Pocket3ExposureOperation.mode)
        case .ev: return value.flatMap(Self.parseEV).map(Pocket3ExposureOperation.ev)
        case .iso:
            guard let raw = value ?? iso, let parsed = Self.parseISO(raw) else { return nil }
            return .iso(parsed)
        case .shutter:
            guard let raw = value ?? shutter, let parsed = Self.parseShutter(raw) else { return nil }
            return .shutter(parsed)
        case .isoLimit:
            guard let value, let parsed = Self.parseISOLimit(value) else { return nil }
            return .isoLimit(parsed)
        case .manualPreset:
            guard let iso, let shutter,
                  let parsedISO = Self.parseISO(iso),
                  let parsedShutter = Self.parseShutter(shutter) else { return nil }
            return .manualPreset(.init(iso: parsedISO, shutter: parsedShutter))
        }
    }

    public var typedOperation: Pocket3ExposureOperation? { operation }

    private static func parseMode(_ value: String) -> Pocket3ExposureMode? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto", "automatic": .automatic
        case "manual": .manual
        default: nil
        }
    }

    private static func parseEV(_ value: String) -> Pocket3ExposureEV? {
        guard let number = Double(value), number.isFinite,
              (number * 3).rounded() == number * 3 else { return nil }
        return try? Pocket3ExposureEV(thirdStops: Int((number * 3).rounded()))
    }

    private static func parseISO(_ value: String) -> Pocket3ExposureISOIndex? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw == "auto" || raw == "automatic" { return .automatic }
        guard let iso = Int(raw) else { return nil }
        return Pocket3ExposureISOIndex.allCases.first { $0.iso == iso }
    }

    private static func parseISOLimit(_ value: String) -> Pocket3ISOLimit? {
        guard let iso = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Pocket3ISOLimit.allCases.first { $0.iso == iso }
    }

    private static func parseShutter(_ value: String) -> Pocket3ExposureShutterSelection? {
        try? Pocket3ExposureShutterSelection(label: value)
    }
}

public typealias Pocket3ExposureValidationRequest = NativeExposureValidationRequest
public typealias NativeExposureValidationError = Pocket3ExposureValidationError

public struct NativeExposureValidationExecutorAdapter: Sendable {
    public typealias Execute = @Sendable (
        _ request: NativeCommandTransactionRequest,
        _ readiness: NativeCameraSessionStatus
    ) async throws -> Pocket3ExposureExecutionResult

    private let body: Execute

    public init(_ body: @escaping Execute) { self.body = body }

    public func execute(_ request: NativeCommandTransactionRequest,
                        readiness: NativeCameraSessionStatus) async throws
        -> Pocket3ExposureExecutionResult {
        try await body(request, readiness)
    }
}

public enum NativeExposureValidationPhase: String, Codable, Sendable,
    Equatable, CaseIterable {
    case dryRun
    case noOp
    case awaitingAcknowledgment
    case awaitingReadback
    case completed
    case timedOut
    case cancelled
    case generationChanged
    case failed
}

public struct NativeExposureValidationResult: Codable, Sendable, Equatable {
    public let action: NativeExposureValidationOperation
    public let executeRequested: Bool
    public let operation: Pocket3ExposureOperation
    public let request: Pocket3ExposureRequestEvidence?
    public let transaction: NativeCommandTransactionResult?
    public let steps: [Pocket3ExposureStepEvidence]
    public let exposureReadback: Pocket3ExposureObservation?
    public let isoLimitReadback: Pocket3AdvancedSettingObservation?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let noOp: Bool
    public let phase: NativeExposureValidationPhase
    public let failureCode: String?

    public var dryRun: Bool { !executeRequested }
    public var partial: Bool { submitted && !completed }
    public var acknowledgedCount: Int {
        steps.reduce(0) { $0 + ($1.transaction?.acknowledged == true ? 1 : 0) }
    }
}

/// Pure validation service used by fake tests today. It accepts one injected
/// executor and never opens a link, fetches a baseline, retries, or performs
/// an automatic cleanup write. App/CLI routing belongs to a later slice.
public struct NativeExposureValidationService: Sendable {
    private let adapter: NativeExposureValidationExecutorAdapter?

    public init(adapter: NativeExposureValidationExecutorAdapter? = nil) {
        self.adapter = adapter
    }

    public func run(_ request: NativeExposureValidationRequest,
                    snapshot: Pocket3ExposureValidationSnapshot) async throws
        -> NativeExposureValidationResult {
        guard request.expectedSessionID == snapshot.session.sessionID,
              request.peripheralID == snapshot.session.peerID,
              request.generation == snapshot.session.generation else {
            throw Pocket3ExposureValidationError.invalidRequestIdentity
        }
        guard let operation = request.operation else {
            throw Pocket3ExposureValidationError.invalidValue
        }
        guard snapshot.nowUptime.isFinite else {
            throw Pocket3ExposureValidationError.invalidTimeout
        }
        let needsExposure: Bool = operation.targets.contains { $0.isExposurePropertyTarget }
        if needsExposure && snapshot.exposure == nil {
            throw Pocket3ExposureValidationError.baselineRequired
        }
        if !needsExposure && snapshot.isoLimit == nil {
            throw Pocket3ExposureValidationError.baselineRequired
        }

        var coordinator: Pocket3ExposureCoordinator
        do {
            coordinator = try Pocket3ExposureCoordinator(session: snapshot.session,
                modeContext: snapshot.modeContext)
        } catch Pocket3ExposureCoordinatorError.sessionNotReady {
            throw Pocket3ExposureValidationError.sessionNotReady
        } catch Pocket3ExposureCoordinatorError.missingSessionIdentity {
            throw Pocket3ExposureValidationError.missingSessionIdentity
        } catch {
            throw Pocket3ExposureValidationError.invalidBaseline
        }

        let first: NativeCommandTransactionRequest
        do {
            first = try coordinator.prepare(operation, snapshot: snapshot,
                                            timeout: request.timeout)
        } catch Pocket3ExposureCoordinatorError.alreadyAtTarget {
            return makeResult(request: request, operation: operation,
                coordinator: coordinator, phase: .noOp)
        } catch Pocket3ExposureCoordinatorError.unsupportedMode {
            throw Pocket3ExposureValidationError.unsupportedMode
        } catch Pocket3ExposureCoordinatorError.missingModeContext,
                Pocket3ExposureCoordinatorError.invalidShutterForFrameRate {
            throw Pocket3ExposureValidationError.unsupportedFrameRate
        } catch Pocket3ExposureCoordinatorError.invalidBaseline {
            throw Pocket3ExposureValidationError.invalidBaseline
        } catch {
            throw Pocket3ExposureValidationError.invalidValue
        }

        guard request.execute else {
            let drySteps = try coordinator.plannedTargets.map { target in
                let nativeRequest = try Pocket3NativeCommandAdapter.exposure(target,
                    generation: snapshot.session.generation,
                    sessionID: snapshot.session.sessionID,
                    timeout: request.timeout)
                return Pocket3ExposureStepEvidence(target: target,
                    requestID: nativeRequest.id,
                    request: .init(nativeRequest))
            }
            return NativeExposureValidationResult(action: request.action,
                executeRequested: false, operation: operation,
                request: .init(first), transaction: nil, steps: drySteps,
                exposureReadback: nil, isoLimitReadback: nil, requested: true,
                submitted: false, acknowledged: false, observed: false,
                completed: false, noOp: false, phase: .dryRun,
                failureCode: nil)
        }

        guard let adapter else {
            _ = coordinator.blockExecution(reason: "native_exposure_executor_unavailable")
            return makeResult(request: request, operation: operation,
                coordinator: coordinator, phase: .failed)
        }

        var current = first
        while true {
            do {
                let execution = try await adapter.execute(current,
                    readiness: snapshot.session)
                let receivedAt = execution.transaction.finishedUptime
                    ?? execution.transaction.observedUptime ?? snapshot.nowUptime
                _ = coordinator.apply(execution, nowUptime: receivedAt)
                guard coordinator.phase == .awaitingNextStep else { break }
                let nextSnapshot = Pocket3ExposureValidationSnapshot(
                    session: snapshot.session,
                    exposure: execution.exposureReadback ?? coordinator.readback ?? snapshot.exposure,
                    isoLimit: execution.isoLimitReadback ?? coordinator.isoLimitReadback ?? snapshot.isoLimit,
                    modeContext: snapshot.modeContext,
                    nowUptime: receivedAt)
                current = try coordinator.prepareNext(snapshot: nextSnapshot,
                                                      timeout: request.timeout)
            } catch is CancellationError {
                let cancelled = partial(current, end: .cancelled, code: "cancelled")
                _ = coordinator.apply(cancelled, nowUptime: nil)
                break
            } catch let error as NativeCommandTransactionError {
                let end: NativeCommandTransactionEnd = error == .staleGeneration
                    ? .generationChanged : .failed
                let failed = partial(current, end: end,
                                     code: failureCode(error))
                _ = coordinator.apply(failed, nowUptime: nil)
                break
            } catch {
                let failed = partial(current, end: .failed,
                                     code: "native_exposure_executor_failed")
                _ = coordinator.apply(failed, nowUptime: nil)
                break
            }
        }
        return makeResult(request: request, operation: operation,
                          coordinator: coordinator,
                          phase: map(coordinator.phase))
    }

    private func makeResult(request: NativeExposureValidationRequest,
                            operation: Pocket3ExposureOperation,
                            coordinator: Pocket3ExposureCoordinator,
                            phase: NativeExposureValidationPhase)
        -> NativeExposureValidationResult {
        let result = coordinator.result
        return NativeExposureValidationResult(action: request.action,
            executeRequested: request.execute, operation: operation,
            request: coordinator.request.map(Pocket3ExposureRequestEvidence.init),
            transaction: result?.transaction, steps: result?.steps ?? [],
            exposureReadback: result?.readback,
            isoLimitReadback: result?.isoLimitReadback, requested: true,
            submitted: result?.submitted == true,
            acknowledged: result?.acknowledged == true,
            observed: result?.observed == true,
            completed: result?.completed == true, noOp: result?.noOp == true,
            phase: phase, failureCode: result?.failureCode)
    }

    private func partial(_ request: NativeCommandTransactionRequest,
                         end: NativeCommandTransactionEnd,
                         code: String) -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: request.generation,
            sessionID: request.sessionID, end: end)
        result.failureCode = code
        return result
    }

    private func map(_ phase: Pocket3ExposureCoordinatorPhase)
        -> NativeExposureValidationPhase {
        switch phase {
        case .idle: .failed
        case .noOp: .noOp
        case .awaitingAcknowledgment: .awaitingAcknowledgment
        case .awaitingReadback, .awaitingNextStep: .awaitingReadback
        case .completed: .completed
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .generationChanged: .generationChanged
        case .failed: .failed
        }
    }

    private func failureCode(_ error: NativeCommandTransactionError) -> String {
        switch error {
        case .invalidPayload: "native_exposure_invalid_payload"
        case .invalidTimeout: "native_exposure_invalid_timeout"
        case .commandNotReady: "native_exposure_command_not_ready"
        case .staleGeneration: "native_exposure_generation_changed"
        case .datalinkUnavailable: "native_exposure_datalink_unavailable"
        case .nativeBusy: "native_exposure_busy"
        }
    }
}

public typealias Pocket3NativeExposureValidationRequest = NativeExposureValidationRequest
public typealias Pocket3NativeExposureValidationResult = NativeExposureValidationResult
public typealias Pocket3NativeExposureValidationService = NativeExposureValidationService
