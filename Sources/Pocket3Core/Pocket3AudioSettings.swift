import Foundation

// MARK: - Audio DSP blob (`02/A0` GET, `02/9F` SET)

public enum Pocket3WindNoiseReduction: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case off = 0x18
    case on = 0x1A
}

public enum Pocket3DirectionalAudio: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case all = 0xDA
    case front = 0x3A
    case frontAndBack = 0xBA
}

/// The shared audio-DSP byte at offset 2. Directional values imply wind-on in
/// the captured protocol, so both interpretations remain available.
public enum Pocket3AudioDSPByte2: Codable, Sendable, Equatable {
    case wind(Pocket3WindNoiseReduction)
    case directional(Pocket3DirectionalAudio)
    case unknown(raw: UInt8)

    public init(rawValue: UInt8) {
        if let wind = Pocket3WindNoiseReduction(rawValue: rawValue) {
            self = .wind(wind)
        } else if let directional = Pocket3DirectionalAudio(rawValue: rawValue) {
            self = .directional(directional)
        } else {
            self = .unknown(raw: rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .wind(let value): value.rawValue
        case .directional(let value): value.rawValue
        case .unknown(let raw): raw
        }
    }

    public var wind: Pocket3WindNoiseReduction? {
        switch self {
        case .wind(let value): value
        case .directional(let value): value == .all || value == .front || value == .frontAndBack ? .on : nil
        case .unknown: nil
        }
    }

    public var directional: Pocket3DirectionalAudio? {
        if case .directional(let value) = self { return value }
        return nil
    }

    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

/// Complete bytes returned by the audio-DSP GET. The protocol source used a
/// 26-byte capture, but this model intentionally accepts and retains the
/// actual response length for firmware variants.
public struct Pocket3AudioDSPReadback: Codable, Sendable, Equatable {
    public let raw: Data
    public let statusRaw: UInt8
    public let blob: Data
    public let byte2Raw: UInt8?
    public let byte2: Pocket3AudioDSPByte2?
    public let receivedUptime: TimeInterval

    public init(raw: Data, statusRaw: UInt8, blob: Data, receivedUptime: TimeInterval) {
        self.raw = raw
        self.statusRaw = statusRaw
        self.blob = blob
        byte2Raw = blob.count > 2 ? blob[2] : nil
        byte2 = blob.count > 2 ? Pocket3AudioDSPByte2(rawValue: blob[2]) : nil
        self.receivedUptime = receivedUptime
    }

    /// A successful GET response starts with status `00`; all remaining bytes
    /// are the blob, without a fixed-size truncation. A status-only ACK is not
    /// a usable baseline and therefore returns nil.
    public static func decode(_ payload: Data, receivedUptime: TimeInterval = 0) -> Self? {
        guard payload.count >= 2, payload[0] == 0x00,
              receivedUptime.isFinite, receivedUptime >= 0 else { return nil }
        return Self(raw: payload, statusRaw: payload[0], blob: Data(payload.dropFirst()),
                    receivedUptime: receivedUptime)
    }

    public static func parse(_ payload: Data, receivedUptime: TimeInterval = 0) -> Self? {
        decode(payload, receivedUptime: receivedUptime)
    }

    public static func decode(_ frame: DUMLFrame, receivedUptime: TimeInterval = 0) -> Self? {
        guard frame.source == 0x01, frame.destination == 0x02,
              frame.flags == 0x80 || frame.flags == 0xC0,
              frame.commandSet == 0x02, frame.commandID == 0xA0 else { return nil }
        return decode(frame.payload, receivedUptime: receivedUptime)
    }
}

/// Session-bound GET evidence. A SET command can only be built from this
/// value, a matching binding, and a fresh monotonic timestamp.
public struct Pocket3AudioDSPBaseline: Codable, Sendable, Equatable {
    public let binding: ContinuousGimbalBinding
    public let blob: Data
    public let receivedUptime: TimeInterval
    public let statusRaw: UInt8

    public init(readback: Pocket3AudioDSPReadback, binding: ContinuousGimbalBinding) throws {
        guard readback.statusRaw == 0x00, !readback.blob.isEmpty,
              readback.receivedUptime.isFinite, readback.receivedUptime >= 0 else {
            throw Pocket3AudioDSPError.invalidBaseline
        }
        self.binding = binding
        blob = readback.blob
        receivedUptime = readback.receivedUptime
        statusRaw = readback.statusRaw
    }

    public func isFresh(nowUptime: TimeInterval, maximumAge: TimeInterval = 5) -> Bool {
        nowUptime.isFinite && receivedUptime.isFinite && receivedUptime >= 0
            && maximumAge.isFinite && maximumAge >= 0
            && nowUptime >= receivedUptime && nowUptime - receivedUptime <= maximumAge
    }

    public var byte2Raw: UInt8? { blob.count > 2 ? blob[2] : nil }
    public var byte2: Pocket3AudioDSPByte2? { byte2Raw.map(Pocket3AudioDSPByte2.init(rawValue:)) }
}

public enum Pocket3AudioDSPError: Error, Codable, Sendable, Equatable {
    case invalidBaseline
    case staleBaseline
    case sessionMismatch
    case unsupportedBaselineFields
    case noRequestedChange
    case payloadTooLarge
}

/// Pure `02/A0` GET command. No network, BLE, or Wi-Fi side effect occurs
/// while constructing or encoding this frame.
public struct Pocket3AudioDSPGetCommand: Codable, Sendable, Equatable {
    public static let commandSet: UInt8 = 0x02
    public static let commandID: UInt8 = 0xA0
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x01
    public static let requestFlags: UInt8 = 0x40

    public init() {}
    public var payload: Data { Data() }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination, sequence: sequence,
                  flags: Self.requestFlags, commandSet: Self.commandSet,
                  commandID: Self.commandID, payload: payload)
    }

    public func encodedFrame(sequence: UInt16) throws -> Data {
        try DUMLCodec.encode(frame(sequence: sequence))
    }
}

/// Pure safe audio-DSP patch. Only byte 2 is changed and every other byte of
/// the GET blob is carried through exactly. The API intentionally has no
/// arbitrary-blob SET initializer.
public struct Pocket3AudioDSPSetCommand: Sendable, Equatable {
    public static let commandSet: UInt8 = 0x02
    public static let commandID: UInt8 = 0x9F
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x01
    public static let requestFlags: UInt8 = 0x40

    public let baseline: Pocket3AudioDSPBaseline
    public let binding: ContinuousGimbalBinding
    public let blob: Data
    public let requestedWind: Pocket3WindNoiseReduction?
    public let requestedDirectional: Pocket3DirectionalAudio?

    public init(baseline: Pocket3AudioDSPBaseline, binding: ContinuousGimbalBinding,
                nowUptime: TimeInterval, wind: Pocket3WindNoiseReduction? = nil,
                directional: Pocket3DirectionalAudio? = nil) throws {
        guard baseline.binding == binding else { throw Pocket3AudioDSPError.sessionMismatch }
        guard baseline.isFresh(nowUptime: nowUptime) else { throw Pocket3AudioDSPError.staleBaseline }
        guard wind != nil || directional != nil else { throw Pocket3AudioDSPError.noRequestedChange }
        guard baseline.blob.count > 2,
              let current = baseline.byte2, current.isKnown else {
            throw Pocket3AudioDSPError.unsupportedBaselineFields
        }

        var patched = baseline.blob
        if let wind {
            switch wind {
            case .off:
                patched[2] = Pocket3WindNoiseReduction.off.rawValue
            case .on:
                // Directional values carry wind-on. Preserve the exact
                // direction when only the wind flag is being changed.
                patched[2] = current.directional?.rawValue ?? Pocket3WindNoiseReduction.on.rawValue
            }
        }
        if let directional { patched[2] = directional.rawValue }
        guard patched.count <= DUMLCodec.maximumPayloadLength else {
            throw Pocket3AudioDSPError.payloadTooLarge
        }
        self.baseline = baseline
        self.binding = binding
        blob = patched
        requestedWind = wind
        requestedDirectional = directional
    }

    public var payload: Data { blob }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination, sequence: sequence,
                  flags: Self.requestFlags, commandSet: Self.commandSet,
                  commandID: Self.commandID, payload: payload)
    }

    public func encodedFrame(sequence: UInt16) throws -> Data {
        try DUMLCodec.encode(frame(sequence: sequence))
    }
}

public typealias Pocket3AudioDSPGet = Pocket3AudioDSPGetCommand
public typealias Pocket3AudioDSPSet = Pocket3AudioDSPSetCommand

// MARK: - Product Showcase keyed parameter (`02/8E`, PID `003B`)

public enum Pocket3ProductShowcaseMode: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case off = 0x00
    case on = 0x01

    public static let disabled = Self.off
    public static let enabled = Self.on
}

/// Product Showcase uses the keyed parameter store; it is separate from the
/// AF mode byte (`02/24`) and from the tap-focus sequence.
public enum Pocket3ProductShowcaseCommand: Codable, Sendable, Equatable {
    case get
    case set(Pocket3ProductShowcaseMode)

    public static let commandSet: UInt8 = 0x02
    public static let commandID: UInt8 = 0x8E
    public static let parameterID: UInt16 = 0x003B
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x01
    public static let requestFlags: UInt8 = 0x40

    public static func setEnabled(_ enabled: Bool) -> Self { .set(enabled ? .on : .off) }

    public var payload: Data {
        switch self {
        case .get:
            Data([0x00, 0x01, 0x3B, 0x00])
        case .set(let mode):
            Data([0x01, 0x01, 0x3B, 0x00, 0x02, 0x01, mode.rawValue])
        }
    }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination, sequence: sequence,
                  flags: Self.requestFlags, commandSet: Self.commandSet,
                  commandID: Self.commandID, payload: payload)
    }

    public func encodedFrame(sequence: UInt16) throws -> Data {
        try DUMLCodec.encode(frame(sequence: sequence))
    }
}

public struct Pocket3ProductShowcaseReadback: Codable, Sendable, Equatable {
    public let raw: Data
    public let modeRaw: UInt8
    public let mode: Pocket3ProductShowcaseMode?

    public init(raw: Data, modeRaw: UInt8, mode: Pocket3ProductShowcaseMode? = nil) {
        self.raw = raw; self.modeRaw = modeRaw; self.mode = mode ?? Pocket3ProductShowcaseMode(rawValue: modeRaw)
    }

    /// GET reply: `00 00 01 3B 00 02 01 <mode>`.
    public static func decode(_ payload: Data) -> Self? {
        guard payload.count >= 8,
              payload[0] == 0, payload[1] == 0, payload[2] == 1,
              payload[3] == 0x3B, payload[4] == 0,
              payload[5] == 2, payload[6] == 1 else { return nil }
        return Self(raw: payload, modeRaw: payload[7])
    }

    public static func parse(_ payload: Data) -> Self? { decode(payload) }
}

public typealias Pocket3ProductShowcaseState = Pocket3ProductShowcaseReadback

// MARK: - Color / white-balance typed candidates

/// Pure color-profile candidate (`02/42`). `CameraSettingCommand` remains the
/// canonical existing white-balance encoder; this alias keeps that typed WB
/// API available without introducing a second writer implementation.
public struct Pocket3ColorProfileCommand: Codable, Sendable, Equatable {
    public static let commandSet: UInt8 = 0x02
    public static let commandID: UInt8 = 0x42
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x01
    public static let requestFlags: UInt8 = 0x40
    public let profile: CameraColorProfile

    public init(_ profile: CameraColorProfile) { self.profile = profile }
    public var payload: Data { Data([profile.rawValue]) }
    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination, sequence: sequence,
                  flags: Self.requestFlags, commandSet: Self.commandSet,
                  commandID: Self.commandID, payload: payload)
    }
    public func encodedFrame(sequence: UInt16) throws -> Data { try DUMLCodec.encode(frame(sequence: sequence)) }
}

public typealias Pocket3CameraColorProfileCommand = Pocket3ColorProfileCommand
public typealias Pocket3WhiteBalanceCommand = CameraSettingCommand

/// Typed candidate view of the six-byte `cam_image_effect` readback. It
/// retains both raw selectors while exposing only known color/WB values.
public struct Pocket3ColorWhiteBalanceCandidate: Codable, Sendable, Equatable {
    public let raw: Data
    public let colorRaw: UInt8
    public let color: CameraColorProfile?
    public let whiteBalanceRaw: UInt8
    public let whiteBalance: CameraWhiteBalance?
    public let kelvinRaw: UInt8?

    public init(raw: Data, colorRaw: UInt8, whiteBalanceRaw: UInt8,
                kelvinRaw: UInt8?, color: CameraColorProfile? = nil,
                whiteBalance: CameraWhiteBalance? = nil) {
        self.raw = raw; self.colorRaw = colorRaw; self.whiteBalanceRaw = whiteBalanceRaw; self.kelvinRaw = kelvinRaw
        self.color = color ?? CameraColorProfile(rawValue: colorRaw)
        self.whiteBalance = whiteBalance ?? Self.decodeWhiteBalance(mode: whiteBalanceRaw, kelvinRaw: kelvinRaw)
    }

    public static func decode(_ value: Data) -> Self? {
        guard value.count >= 6 else { return nil }
        let mode = value[4], kelvinRaw: UInt8? = mode == 0x06 ? value[5] : nil
        return Self(raw: value, colorRaw: value[2], whiteBalanceRaw: mode, kelvinRaw: kelvinRaw)
    }

    public static func parse(_ value: Data) -> Self? { decode(value) }

    private static func decodeWhiteBalance(mode: UInt8, kelvinRaw: UInt8?) -> CameraWhiteBalance? {
        switch mode {
        case 0x00: return .automatic
        case 0x06:
            guard let kelvinRaw else { return nil }
            let kelvin = Int(kelvinRaw) * 100
            return (2000...10000).contains(kelvin) ? .customKelvin(kelvin) : nil
        default: return nil
        }
    }
}
