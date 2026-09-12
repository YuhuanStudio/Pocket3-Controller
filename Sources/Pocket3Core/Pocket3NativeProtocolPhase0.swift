import Foundation

// MARK: - Body recording format (`camcap_video_format`, `02/18`)

/// The aspect encoded by a Pocket 3 body-recording resolution selector. This
/// is independent from USB/UVC capture and from the effective sensor
/// orientation property.
public enum CameraBodyRecordingAspect: String, Codable, Sendable, Equatable, CaseIterable {
    case sixteenByNine = "16:9"
    case oneByOne = "1:1"
    case nineBySixteen = "9:16"
}

public typealias CameraVideoAspect = CameraBodyRecordingAspect
public typealias Pocket3VideoAspect = CameraBodyRecordingAspect

public extension CameraVideoResolution {
    var bodyRecordingAspect: CameraBodyRecordingAspect? {
        switch self {
        case .p1080, .p2_7K, .p4K: .sixteenByNine
        case .square1080, .square2160, .square3K: .oneByOne
        case .portrait1080, .portrait2_7K, .portrait3K: .nineBySixteen
        }
    }

    /// Alias matching the terminology used by the body-format catalog.
    var aspect: CameraBodyRecordingAspect? { bodyRecordingAspect }
}

/// One three-byte `[resolution, fps, flags]` entry from `camcap_video_format`.
/// Unknown selectors and the third byte remain visible to callers.
public struct CameraVideoFormatCapability: Codable, Sendable, Equatable, Hashable {
    public let resolutionRaw: UInt8
    public let frameRateRaw: UInt8
    public let flagsRaw: UInt8
    public let resolution: CameraVideoResolution?
    public let frameRate: CameraFrameRate?
    public let raw: Data

    public init(resolutionRaw: UInt8, frameRateRaw: UInt8, flagsRaw: UInt8 = 0,
                resolution: CameraVideoResolution? = nil,
                frameRate: CameraFrameRate? = nil, raw: Data? = nil) {
        self.resolutionRaw = resolutionRaw
        self.frameRateRaw = frameRateRaw
        self.flagsRaw = flagsRaw
        self.resolution = resolution ?? CameraVideoResolution(rawValue: resolutionRaw)
        self.frameRate = frameRate ?? CameraFrameRate(rawValue: frameRateRaw)
        self.raw = raw ?? Data([resolutionRaw, frameRateRaw, flagsRaw])
    }

    /// Name used by a few protocol notes for the third entry byte.
    public var reservedRaw: UInt8 { flagsRaw }
    public var aspect: CameraBodyRecordingAspect? { resolution?.bodyRecordingAspect }
    public var isKnownResolution: Bool { resolution != nil }
    public var isKnownFrameRate: Bool { frameRate != nil }
    public var isKnown: Bool { isKnownResolution && isKnownFrameRate && flagsRaw == 0 }
}

/// Typed, bounded `camcap_video_format` value:
/// `01 | innerLength:u16LE | count | count × [resolution, fps, flags]`.
/// Bytes after the entries are preserved for future firmware variants.
public struct CameraVideoFormatCapabilities: Codable, Sendable, Equatable {
    public let raw: Data
    public let versionRaw: UInt8
    public let innerLengthRaw: UInt16
    public let entryCountRaw: UInt8
    public let entries: [CameraVideoFormatCapability]
    public let innerTrailing: Data
    public let trailing: Data

    public init(raw: Data, versionRaw: UInt8, innerLengthRaw: UInt16,
                entryCountRaw: UInt8, entries: [CameraVideoFormatCapability],
                innerTrailing: Data = Data(), trailing: Data = Data()) {
        self.raw = raw
        self.versionRaw = versionRaw
        self.innerLengthRaw = innerLengthRaw
        self.entryCountRaw = entryCountRaw
        self.entries = entries
        self.innerTrailing = innerTrailing
        self.trailing = trailing
    }

    public var formats: [CameraVideoFormatCapability] { entries }
    public var knownVersion: Bool { versionRaw == 0x01 }
    public var hasUnknownEntries: Bool { entries.contains { !$0.isKnown } }
    public var knownEntries: [CameraVideoFormatCapability] { entries.filter(\.isKnown) }

    public func contains(resolutionRaw: UInt8, frameRateRaw: UInt8) -> Bool {
        entries.contains { $0.resolutionRaw == resolutionRaw && $0.frameRateRaw == frameRateRaw }
    }

    public func contains(resolution: CameraVideoResolution, frameRate: CameraFrameRate) -> Bool {
        contains(resolutionRaw: resolution.rawValue, frameRateRaw: frameRate.rawValue)
    }
}

public enum CameraVideoFormatCapabilityDecoder {
    /// Only the captured version-1 envelope is decoded. Unknown entry values
    /// remain typed objects with raw selectors; an unknown envelope version is
    /// left to the legacy opaque readback instead of being misparsed.
    public static func decode(_ value: Data) -> CameraVideoFormatCapabilities? {
        guard value.count >= 5, value.count <= DUMLCodec.maximumPayloadLength else { return nil }
        let bytes = Array(value)
        let innerLength = u16(bytes, 1)
        let bodyEnd = 3 + Int(innerLength)
        guard bytes[0] == 0x01, innerLength >= 2, bodyEnd <= bytes.count else { return nil }
        let body = Array(bytes[3..<bodyEnd])
        let count = Int(body[0])
        guard count > 0, count <= (body.count - 1) / 3 else { return nil }
        var entries: [CameraVideoFormatCapability] = []
        entries.reserveCapacity(count)
        var offset = 1
        for _ in 0..<count {
            entries.append(CameraVideoFormatCapability(
                resolutionRaw: body[offset], frameRateRaw: body[offset + 1], flagsRaw: body[offset + 2],
                raw: Data(body[offset..<(offset + 3)])))
            offset += 3
        }
        return CameraVideoFormatCapabilities(
            raw: value, versionRaw: bytes[0], innerLengthRaw: innerLength,
            entryCountRaw: body[0], entries: entries,
            innerTrailing: Data(body[offset...]), trailing: Data(bytes[bodyEnd...]))
    }

    public static func decode(_ value: [UInt8]) -> CameraVideoFormatCapabilities? { decode(Data(value)) }
    public static func parse(_ value: Data) -> CameraVideoFormatCapabilities? { decode(value) }
    public static func parse(_ value: [UInt8]) -> CameraVideoFormatCapabilities? { decode(value) }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
}

public enum CameraBodySlowMotionMultiplier: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case normal = 0x00
    case x4 = 0x04
    case x8 = 0x08
    public static let none = Self.normal
}

/// Pure encoder for body recording format `02/18`; this never touches the
/// USB/UVC capture format or a transport.
public struct CameraBodyRecordingFormatCommand: Codable, Sendable, Equatable {
    public static let commandSet: UInt8 = 0x02
    public static let commandID: UInt8 = 0x18
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x01
    public static let requestFlags: UInt8 = 0x40

    public let resolution: CameraVideoResolution
    public let frameRate: CameraFrameRate
    public let slowMotionMultiplier: CameraBodySlowMotionMultiplier

    public init(resolution: CameraVideoResolution, frameRate: CameraFrameRate,
                slowMotionMultiplier: CameraBodySlowMotionMultiplier = .normal) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.slowMotionMultiplier = slowMotionMultiplier
    }

    public init?(capability: CameraVideoFormatCapability,
                 slowMotionMultiplier: CameraBodySlowMotionMultiplier = .normal) {
        guard capability.flagsRaw == 0, let resolution = capability.resolution,
              let frameRate = capability.frameRate else { return nil }
        self.init(resolution: resolution, frameRate: frameRate,
                  slowMotionMultiplier: slowMotionMultiplier)
    }

    public var payload: Data {
        Data([resolution.rawValue, frameRate.rawValue, 0, slowMotionMultiplier.rawValue, 0])
    }

    public func isAllowed(by capabilities: CameraVideoFormatCapabilities) -> Bool {
        capabilities.contains(resolution: resolution, frameRate: frameRate)
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

public typealias Pocket3BodyRecordingFormat = CameraBodyRecordingFormatCommand
public typealias Pocket3BodyRecordingCapability = CameraVideoFormatCapability
public typealias Pocket3BodyRecordingCapabilities = CameraVideoFormatCapabilities
public typealias Pocket3CameraVideoFormatCapability = CameraVideoFormatCapability
public typealias Pocket3CameraVideoFormatCapabilities = CameraVideoFormatCapabilities

// MARK: - Gimbal shortcuts and `04/50`

/// Native gimbal shortcuts `04/4C FE08` (recenter) and `FE09` (front/selfie
/// toggle). Encoding a value does not send it or imply physical completion.
public enum Pocket3GimbalShortcut: String, Codable, Sendable, Equatable, CaseIterable {
    case recenter
    case flip

    public static let commandSet: UInt8 = 0x04
    public static let commandID: UInt8 = 0x4C
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x04
    public static let requestFlags: UInt8 = 0x40

    public var payload: Data {
        switch self {
        case .recenter: Data([0xFE, 0x08])
        case .flip: Data([0xFE, 0x09])
        }
    }

    public var wireCode: UInt8 { payload[1] }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination, sequence: sequence,
                  flags: Self.requestFlags, commandSet: Self.commandSet,
                  commandID: Self.commandID, payload: payload)
    }

    public func encodedFrame(sequence: UInt16) throws -> Data {
        try DUMLCodec.encode(frame(sequence: sequence))
    }
}

public typealias Pocket3NativeGimbalShortcut = Pocket3GimbalShortcut

public enum Pocket3GimbalShortcutPayload: Codable, Sendable, Equatable {
    case recenter
    case flip
    case unknown(Data)

    public static func decode(_ payload: Data) -> Self? {
        guard payload.count >= 2, payload[0] == 0xFE else { return nil }
        if payload.count == 2, payload[1] == 0x08 { return .recenter }
        if payload.count == 2, payload[1] == 0x09 { return .flip }
        return .unknown(payload)
    }
}

public enum Pocket3GimbalParameter: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case tiltLock = 0x04
    case speed = 0x05
}

public enum Pocket3GimbalMode: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case follow = 0x00
    case tiltLocked = 0x01
    public static let unlocked = Self.follow
    public static let locked = Self.tiltLocked
}

public enum Pocket3GimbalSpeed: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case fast = 0x00
    case `default` = 0x01
    case slow = 0x02
    public static let defaultSpeed = Self.default
    public static let normal = Self.default
}

/// `04/50` GET (`01 04 05`) and captured mode/speed SET shapes.
public enum Pocket3GimbalParameterCommand: Codable, Sendable, Equatable {
    case get
    case setMode(Pocket3GimbalMode)
    case setSpeed(Pocket3GimbalSpeed)

    public static let commandSet: UInt8 = 0x04
    public static let commandID: UInt8 = 0x50
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x04
    public static let requestFlags: UInt8 = 0x40

    public var payload: Data {
        switch self {
        case .get: Data([1, 4, 5])
        case .setMode(let mode): Data([0, 4, 1, mode.rawValue])
        case .setSpeed(let speed): Data([0, 5, 1, speed.rawValue])
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

public typealias Pocket3Gimbal040x50Command = Pocket3GimbalParameterCommand

/// Known GET reply: `00 01 04 01 <mode> 05 01 <speed>`. Raw selectors are
/// retained when a firmware sends values outside the current enum.
public struct Pocket3GimbalParameterReadback: Codable, Sendable, Equatable {
    public let raw: Data
    public let modeRaw: UInt8
    public let speedRaw: UInt8
    public let mode: Pocket3GimbalMode?
    public let speed: Pocket3GimbalSpeed?

    public init(raw: Data, modeRaw: UInt8, speedRaw: UInt8,
                mode: Pocket3GimbalMode? = nil, speed: Pocket3GimbalSpeed? = nil) {
        self.raw = raw
        self.modeRaw = modeRaw
        self.speedRaw = speedRaw
        self.mode = mode ?? Pocket3GimbalMode(rawValue: modeRaw)
        self.speed = speed ?? Pocket3GimbalSpeed(rawValue: speedRaw)
    }

    public static func decode(_ payload: Data) -> Self? {
        guard payload.count >= 8, payload[0] == 0, payload[1] == 1,
              payload[2] == 4, payload[3] == 1,
              payload[5] == 5, payload[6] == 1 else { return nil }
        return Self(raw: payload, modeRaw: payload[4], speedRaw: payload[7])
    }

    public static func parse(_ payload: Data) -> Self? { decode(payload) }
}

public typealias Pocket3GimbalParameters = Pocket3GimbalParameterReadback

// MARK: - ActiveTrack A5/A6/89

/// Normalized center/size rectangle used by A5/A6/89. Values are validated at
/// construction time; decoder failures retain their original payload in an
/// unknown case instead of fabricating a rectangle.
public struct Pocket3TrackingBox: Codable, Sendable, Equatable, Hashable {
    public let centerX: Double
    public let centerY: Double
    public let width: Double
    public let height: Double

    public init(centerX: Double, centerY: Double, width: Double, height: Double) throws {
        guard Self.isValid(centerX: centerX, centerY: centerY, width: width, height: height) else {
            throw Pocket3NativeProtocolError.invalidTrackingBox
        }
        // The wire stores these fields as float32. Canonicalizing at this
        // boundary gives stable equality between a fixture and its decode.
        let values = [Float(centerX), Float(centerY), Float(width), Float(height)]
        guard values.allSatisfy(\.isFinite),
              Self.isValid(centerX: Double(values[0]), centerY: Double(values[1]),
                           width: Double(values[2]), height: Double(values[3])) else {
            throw Pocket3NativeProtocolError.invalidTrackingBox
        }
        self.centerX = Double(values[0]); self.centerY = Double(values[1])
        self.width = Double(values[2]); self.height = Double(values[3])
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let centerX = try values.decode(Double.self, forKey: .centerX)
        let centerY = try values.decode(Double.self, forKey: .centerY)
        let width = try values.decode(Double.self, forKey: .width)
        let height = try values.decode(Double.self, forKey: .height)
        try self.init(centerX: centerX, centerY: centerY, width: width, height: height)
    }

    fileprivate init(uncheckedCenterX x: Double, centerY y: Double, width: Double, height: Double) {
        centerX = x; centerY = y; self.width = width; self.height = height
    }

    public var minX: Double { centerX - width / 2 }
    public var minY: Double { centerY - height / 2 }
    public var maxX: Double { centerX + width / 2 }
    public var maxY: Double { centerY + height / 2 }

    public static func isValid(centerX: Double, centerY: Double, width: Double, height: Double,
                               minimumSide: Double = 0.02) -> Bool {
        minimumSide.isFinite && minimumSide > 0 && minimumSide <= 1
            && centerX.isFinite && centerY.isFinite && width.isFinite && height.isFinite
            && (0...1).contains(centerX) && (0...1).contains(centerY)
            && width >= minimumSide && width <= 1
            && height >= minimumSide && height <= 1
            && centerX - width / 2 >= 0 && centerX + width / 2 <= 1
            && centerY - height / 2 >= 0 && centerY + height / 2 <= 1
    }

    private enum CodingKeys: String, CodingKey {
        case centerX, centerY, width, height
    }
}

public enum Pocket3TrackingPollState: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case idle = 0
    case locked = 1
}

/// Pure encoder for A6 set/clear and A5 poll requests.
public enum Pocket3TrackingCommand: Codable, Sendable, Equatable {
    case setBox(id: UInt16, box: Pocket3TrackingBox)
    case clearBox
    case poll

    public static let commandSet: UInt8 = 0x02
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x01
    public static let requestFlags: UInt8 = 0x40

    public var commandID: UInt8 {
        switch self { case .poll: 0xA5; case .setBox, .clearBox: 0xA6 }
    }

    public var payload: Data {
        switch self {
        case .setBox(let id, let box):
            return Data([1, 0, 0, UInt8(truncatingIfNeeded: id), UInt8(truncatingIfNeeded: id >> 8)])
                + Data(floatLE(box.centerX) + floatLE(box.centerY) + floatLE(box.width) + floatLE(box.height))
        case .clearBox: return Data(repeating: 0, count: 21)
        case .poll: return Data([0])
        }
    }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination, sequence: sequence,
                  flags: Self.requestFlags, commandSet: Self.commandSet,
                  commandID: commandID, payload: payload)
    }

    public func encodedFrame(sequence: UInt16) throws -> Data { try DUMLCodec.encode(frame(sequence: sequence)) }

    private func floatLE(_ value: Double) -> [UInt8] {
        var bits = Float(value).bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Array($0) }
    }
}

public typealias Pocket3ActiveTrackCommand = Pocket3TrackingCommand

public enum Pocket3TrackingBoxCommandPayload: Codable, Sendable, Equatable {
    case setBox(id: UInt16, box: Pocket3TrackingBox)
    case clearBox
    case unknown(Data)

    public static func decode(_ payload: Data) -> Self? {
        guard payload.count <= DUMLCodec.maximumPayloadLength else { return nil }
        if payload.count == 21, payload.allSatisfy({ $0 == 0 }) { return .clearBox }
        guard payload.count == 21 else { return .unknown(payload) }
        guard payload[0] == 1, payload[1] == 0, payload[2] == 0 else { return .unknown(payload) }
        let id = UInt16(payload[3]) | UInt16(payload[4]) << 8
        guard let box = decodeBox(payload, offset: 5) else { return .unknown(payload) }
        return .setBox(id: id, box: box)
    }

    public static func parse(_ payload: Data) -> Self? { decode(payload) }
}

/// A5 reply state: `00 01 00 00` locked, `00 00 00 00` idle. A locked reply
/// may omit its box while the camera is acquiring it.
public struct Pocket3TrackingPollReadback: Codable, Sendable, Equatable {
    public let raw: Data
    public let stateRaw: UInt8
    public let state: Pocket3TrackingPollState?
    public let box: Pocket3TrackingBox?

    public init(raw: Data, stateRaw: UInt8, state: Pocket3TrackingPollState? = nil,
                box: Pocket3TrackingBox? = nil) {
        self.raw = raw; self.stateRaw = stateRaw
        self.state = state ?? Pocket3TrackingPollState(rawValue: stateRaw)
        self.box = box
    }

    public static func decode(_ payload: Data) -> Self? {
        guard payload.count >= 4, payload[0] == 0, payload[2] == 0, payload[3] == 0 else { return nil }
        let box = payload[1] == 1 && payload.count >= 20 ? decodeBox(payload, offset: 4) : nil
        return Self(raw: payload, stateRaw: payload[1], box: box)
    }

    public static func parse(_ payload: Data) -> Self? { decode(payload) }
}

/// 02/89 live push: five zero bytes, tag, reserved byte, then four f32 LE
/// center/size values at offset 7.
public struct Pocket3TrackingLiveSubject: Codable, Sendable, Equatable {
    public let raw: Data
    public let tagRaw: UInt8
    public let reservedRaw: UInt8
    public let box: Pocket3TrackingBox

    public init(raw: Data, tagRaw: UInt8, reservedRaw: UInt8, box: Pocket3TrackingBox) {
        self.raw = raw; self.tagRaw = tagRaw; self.reservedRaw = reservedRaw; self.box = box
    }

    public static func decode(_ payload: Data) -> Self? {
        guard payload.count >= 23, payload.prefix(5).allSatisfy({ $0 == 0 }),
              let box = decodeBox(payload, offset: 7) else { return nil }
        return Self(raw: payload, tagRaw: payload[5], reservedRaw: payload[6], box: box)
    }

    public static func parse(_ payload: Data) -> Self? { decode(payload) }
}

public enum Pocket3TrackingFrameDecoder {
    public static func decodePollReply(_ frame: DUMLFrame) -> Pocket3TrackingPollReadback? {
        guard frame.source == 1, frame.destination == 2,
              frame.flags == 0x80 || frame.flags == 0xC0,
              frame.commandSet == 2, frame.commandID == 0xA5 else { return nil }
        return Pocket3TrackingPollReadback.decode(frame.payload)
    }

    public static func decodeBoxCommand(_ frame: DUMLFrame) -> Pocket3TrackingBoxCommandPayload? {
        guard frame.source == 2, frame.destination == 1, frame.flags == 0x40,
              frame.commandSet == 2, frame.commandID == 0xA6 else { return nil }
        return Pocket3TrackingBoxCommandPayload.decode(frame.payload)
    }

    public static func decodeLiveSubject(_ frame: DUMLFrame) -> Pocket3TrackingLiveSubject? {
        guard frame.source == 1, frame.destination == 2, frame.flags == 0,
              frame.commandSet == 2, frame.commandID == 0x89 else { return nil }
        return Pocket3TrackingLiveSubject.decode(frame.payload)
    }
}

public typealias Pocket3TrackingPoll = Pocket3TrackingPollReadback
public typealias Pocket3TrackingLivePush = Pocket3TrackingLiveSubject

// MARK: - Native zoom (`02/B8`)

public enum Pocket3NativeZoomPayload: Codable, Sendable, Equatable {
    case absoluteLens(position: UInt16)
    case relativeSlew(value: UInt16)
    case stop
    case unknown(Data)

    public static func decode(_ payload: Data) -> Self? {
        guard payload.count <= DUMLCodec.maximumPayloadLength else { return nil }
        let bytes = Array(payload)
        if bytes.count == 4, bytes[0] == 0x0A, bytes[1] == 0x4E {
            return .absoluteLens(position: UInt16(bytes[2]) | UInt16(bytes[3]) << 8)
        }
        if bytes.count == 4, bytes[0] == 0x03, bytes[1] == 0 {
            return .relativeSlew(value: UInt16(bytes[2]) | UInt16(bytes[3]) << 8)
        }
        if bytes == [0xFF, 0, 0, 0] { return .stop }
        return .unknown(payload)
    }

    public static func parse(_ payload: Data) -> Self? { decode(payload) }
}

public enum Pocket3NativeZoomError: Error, Equatable, Sendable {
    case invalidLensPosition
    case invalidSlewValue
}

public struct Pocket3NativeZoomCommand: Codable, Sendable, Equatable {
    public static let commandSet: UInt8 = 0x02
    public static let commandID: UInt8 = 0xB8
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x01
    public static let requestFlags: UInt8 = 0x40
    public static let minimumLensPosition: UInt16 = 100
    public static let maximumLensPosition: UInt16 = 3_000
    public static let maximumSlewValue: UInt16 = 3_000

    public let action: Pocket3NativeZoomPayload

    public init(absoluteLens position: UInt16) throws {
        guard Self.validLensPosition(position) else { throw Pocket3NativeZoomError.invalidLensPosition }
        action = .absoluteLens(position: position)
    }

    public init(relativeSlew value: UInt16) throws {
        guard value <= Self.maximumSlewValue else { throw Pocket3NativeZoomError.invalidSlewValue }
        action = .relativeSlew(value: value)
    }

    public init(stop: Void = ()) { action = .stop }
    public static var stop: Self { Self() }
    public static func absolute(_ value: UInt16) throws -> Self { try Self(absoluteLens: value) }
    public static func relative(_ value: UInt16) throws -> Self { try Self(relativeSlew: value) }

    public static func validLensPosition(_ value: UInt16) -> Bool {
        (minimumLensPosition...maximumLensPosition).contains(value)
    }

    public var payload: Data {
        switch action {
        case .absoluteLens(let value): return Data([0x0A, 0x4E, UInt8(value & 0xFF), UInt8(value >> 8)])
        case .relativeSlew(let value): return Data([3, 0, UInt8(value & 0xFF), UInt8(value >> 8)])
        case .stop: return Data([0xFF, 0, 0, 0])
        case .unknown: return Data()
        }
    }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination, sequence: sequence,
                  flags: Self.requestFlags, commandSet: Self.commandSet,
                  commandID: Self.commandID, payload: payload)
    }

    public func encodedFrame(sequence: UInt16) throws -> Data { try DUMLCodec.encode(frame(sequence: sequence)) }
}

public typealias Pocket3NativeZoom = Pocket3NativeZoomCommand
public typealias Pocket3ZoomPayload = Pocket3NativeZoomPayload

// MARK: - Tap AF sequence

public enum Pocket3TapFocusStep: String, Codable, Sendable, Equatable, CaseIterable {
    case prepareAE
    case point
    case hintAE
    case commitMetering

    public var commandID: UInt8 {
        switch self { case .prepareAE: 0x22; case .point: 0x30; case .hintAE: 0x68; case .commitMetering: 0x32 }
    }
}

/// The four capture-confirmed tap-AF writes. This object only builds frames;
/// ACK pacing/credit waits remain in the existing BluetoothTapFocusProbe.
public struct Pocket3TapFocusSequence: Codable, Sendable, Equatable {
    public static let commandSet: UInt8 = 2
    public static let source: UInt8 = 2
    public static let destination: UInt8 = 1
    public static let requestFlags: UInt8 = 0x40

    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw Pocket3NativeProtocolError.invalidTapFocusCoordinate
        }
        self.x = x; self.y = y
    }

    public func payload(for step: Pocket3TapFocusStep) -> Data {
        switch step {
        case .prepareAE: return Data([2])
        case .point: return Data(floatLE(x) + floatLE(y) + [UInt8](repeating: 0, count: 13))
        case .hintAE: return Data([8])
        case .commitMetering:
            return Data([0, 2, 1, 0] + floatLE(x) + floatLE(y) + [UInt8](repeating: 0, count: 8))
        }
    }

    public func frame(for step: Pocket3TapFocusStep, sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination, sequence: sequence,
                  flags: Self.requestFlags, commandSet: Self.commandSet,
                  commandID: step.commandID, payload: payload(for: step))
    }

    /// Datalink source uses one running sequence for the burst.
    public func frames(sequence: UInt16) -> [DUMLFrame] {
        Pocket3TapFocusStep.allCases.map { frame(for: $0, sequence: sequence) }
    }

    /// BLE callers can provide four distinct sequence IDs.
    public func frames(sequences: [UInt16]) throws -> [DUMLFrame] {
        guard sequences.count == 4, Set(sequences).count == 4 else {
            throw Pocket3NativeProtocolError.invalidTapFocusSequence
        }
        return Array(zip(Pocket3TapFocusStep.allCases, sequences)).map { frame(for: $0.0, sequence: $0.1) }
    }

    public func encodedFrames(sequence: UInt16) throws -> [Data] {
        try frames(sequence: sequence).map { try DUMLCodec.encode($0) }
    }

    public func encodedFrames(sequences: [UInt16]) throws -> [Data] {
        try frames(sequences: sequences).map { try DUMLCodec.encode($0) }
    }

    private func floatLE(_ value: Double) -> [UInt8] {
        var bits = Float(value).bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Array($0) }
    }
}

public typealias Pocket3NativeTapFocusSequence = Pocket3TapFocusSequence

public enum Pocket3NativeProtocolError: Error, Equatable, Sendable {
    case invalidTrackingBox
    case invalidTapFocusCoordinate
    case invalidTapFocusSequence
}

// MARK: - Existing opaque capability bridge

public extension CameraReadOnlyPropertyDecoder {
    static func decodeVideoFormatCapabilities(_ value: Data) -> CameraVideoFormatCapabilities? {
        CameraVideoFormatCapabilityDecoder.decode(value)
    }

    static func decodeBodyRecordingCapabilities(_ value: Data) -> CameraVideoFormatCapabilities? {
        decodeVideoFormatCapabilities(value)
    }
}

public extension CameraOpaqueCapabilityReadback {
    var typedVideoFormatCapabilities: CameraVideoFormatCapabilities? {
        CameraVideoFormatCapabilityDecoder.decode(raw)
    }

    var bodyRecordingCapabilities: CameraVideoFormatCapabilities? { typedVideoFormatCapabilities }
}

public extension CameraReadOnlyValue {
    var typedVideoFormatCapabilities: CameraVideoFormatCapabilities? {
        guard case .videoFormatCapabilities(let value) = self else { return nil }
        return value.typedVideoFormatCapabilities
    }
}

// MARK: - Internal byte helpers

private func floatLE(_ bytes: [UInt8], at offset: Int) -> Double? {
    guard offset >= 0, offset + 4 <= bytes.count else { return nil }
    let bits = UInt32(bytes[offset])
        | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
    let value = Float(bitPattern: bits)
    guard value.isFinite else { return nil }
    return Double(value)
}

private func decodeBox(_ data: Data, offset: Int, minimumSide: Double = 0.02) -> Pocket3TrackingBox? {
    let bytes = Array(data)
    guard let x = floatLE(bytes, at: offset), let y = floatLE(bytes, at: offset + 4),
          let width = floatLE(bytes, at: offset + 8), let height = floatLE(bytes, at: offset + 12),
          Pocket3TrackingBox.isValid(centerX: x, centerY: y, width: width, height: height,
                                     minimumSide: minimumSide) else { return nil }
    return Pocket3TrackingBox(uncheckedCenterX: x, centerY: y, width: width, height: height)
}
