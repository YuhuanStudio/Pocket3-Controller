import Foundation

/// Errors raised while handling the fixed UVC 1.0 VideoStreaming controls.
///
/// This type deliberately contains no I/O errors.  It describes only malformed
/// bytes, values outside the local safety bounds, and responses which cannot be
/// associated with the descriptor-backed Pocket 3 mode that was requested.
public enum UVCNegotiationError: Error, Equatable, Sendable, LocalizedError {
    case invalidControlLength(expected: Int, actual: Int)
    case unsupportedFormat(index: UInt8)
    case unsupportedFrame(index: UInt8)
    case unsupportedInterval(formatIndex: UInt8, frameIndex: UInt8, interval: UInt32)
    case responseMismatch(field: String, expected: String, actual: String)
    case sizeOutOfBounds(field: String, value: UInt32, maximum: UInt32)
    case integerOverflow(field: String, value: UInt64)
    case invalidSizeBound(field: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidControlLength(expected, actual):
            return "UVC VS control block must be exactly \(expected) bytes; received \(actual)"
        case let .unsupportedFormat(index):
            return "Pocket 3 H.264 format index \(index) is not supported"
        case let .unsupportedFrame(index):
            return "Pocket 3 H.264 frame index \(index) is not supported"
        case let .unsupportedInterval(formatIndex, frameIndex, interval):
            return "UVC format \(formatIndex), frame \(frameIndex) does not advertise interval \(interval)"
        case let .responseMismatch(field, expected, actual):
            return "UVC response field \(field) changed (expected \(expected), received \(actual))"
        case let .sizeOutOfBounds(field, value, maximum):
            return "UVC \(field) \(value) exceeds the local maximum \(maximum)"
        case let .integerOverflow(field, value):
            return "UVC \(field) value \(value) does not fit the wire integer"
        case let .invalidSizeBound(field):
            return "UVC \(field) maximum must be positive and fit the wire integer"
        }
    }
}

/// Independent upper bounds for the two size fields in a UVC probe/commit
/// block.  The fields are checked separately because a large frame-size value
/// must never make a payload-size check wrap (or vice versa).
public struct UVCProbeCommitSizeBounds: Sendable, Equatable {
    public let maximumVideoFrameSize: UInt32
    public let maximumPayloadTransferSize: UInt32

    /// Conservative limits for the Pocket 3 frame-based H.264 path.  They are
    /// parser safety limits, not claims about a camera's advertised bitrate.
    public static let pocket3H264 = UVCProbeCommitSizeBounds(
        maximumVideoFrameSize: 64 * 1024 * 1024,
        maximumPayloadTransferSize: 4 * 1024 * 1024)

    /// The representable UVC 1.0 wire range, useful when a caller is handling a
    /// device other than the descriptor-backed Pocket 3 catalog.
    public static let wire = UVCProbeCommitSizeBounds(
        maximumVideoFrameSize: UInt32.max,
        maximumPayloadTransferSize: UInt32.max)

    public init(maximumVideoFrameSize: UInt32, maximumPayloadTransferSize: UInt32) {
        self.maximumVideoFrameSize = maximumVideoFrameSize
        self.maximumPayloadTransferSize = maximumPayloadTransferSize
    }

    /// Checked initializer used by callers that obtained limits from a wider
    /// integer representation.  It prevents truncation before validation.
    public init(validatingVideoFrameSize: UInt64, payloadTransferSize: UInt64) throws {
        guard validatingVideoFrameSize > 0, validatingVideoFrameSize <= UInt64(UInt32.max) else {
            if validatingVideoFrameSize > UInt64(UInt32.max) {
                throw UVCNegotiationError.integerOverflow(field: "maximumVideoFrameSize", value: validatingVideoFrameSize)
            }
            throw UVCNegotiationError.invalidSizeBound(field: "maximumVideoFrameSize")
        }
        guard payloadTransferSize > 0, payloadTransferSize <= UInt64(UInt32.max) else {
            if payloadTransferSize > UInt64(UInt32.max) {
                throw UVCNegotiationError.integerOverflow(field: "maximumPayloadTransferSize", value: payloadTransferSize)
            }
            throw UVCNegotiationError.invalidSizeBound(field: "maximumPayloadTransferSize")
        }
        maximumVideoFrameSize = UInt32(validatingVideoFrameSize)
        maximumPayloadTransferSize = UInt32(payloadTransferSize)
    }

    public func validate(_ block: UVCVideoStreamingControlBlock) throws {
        guard block.maxVideoFrameSize <= maximumVideoFrameSize else {
            throw UVCNegotiationError.sizeOutOfBounds(
                field: "maxVideoFrameSize", value: block.maxVideoFrameSize, maximum: maximumVideoFrameSize)
        }
        guard block.maxPayloadTransferSize <= maximumPayloadTransferSize else {
            throw UVCNegotiationError.sizeOutOfBounds(
                field: "maxPayloadTransferSize", value: block.maxPayloadTransferSize, maximum: maximumPayloadTransferSize)
        }
    }
}

/// The UVC 1.0 VS_PROBE_CONTROL / VS_COMMIT_CONTROL wire block.
///
/// UVC 1.0 uses exactly 26 bytes in this device.  The accessors retain the
/// protocol's field names and `encodedData` always writes multi-byte fields in
/// USB little-endian order, regardless of host architecture.
public struct UVCVideoStreamingControlBlock: Sendable, Equatable {
    public static let byteCount = 26

    public let bmHint: UInt16
    public let formatIndex: UInt8
    public let frameIndex: UInt8
    public let frameInterval: UInt32
    public let keyFrameRate: UInt16
    public let pFrameRate: UInt16
    public let compressionQuality: UInt16
    public let compressionWindowSize: UInt16
    public let delay: UInt16
    public let maxVideoFrameSize: UInt32
    public let maxPayloadTransferSize: UInt32

    public init(
        bmHint: UInt16 = 0,
        formatIndex: UInt8,
        frameIndex: UInt8,
        frameInterval: UInt32,
        keyFrameRate: UInt16 = 0,
        pFrameRate: UInt16 = 0,
        compressionQuality: UInt16 = 0,
        compressionWindowSize: UInt16 = 0,
        delay: UInt16 = 0,
        maxVideoFrameSize: UInt32 = 0,
        maxPayloadTransferSize: UInt32 = 0
    ) {
        self.bmHint = bmHint
        self.formatIndex = formatIndex
        self.frameIndex = frameIndex
        self.frameInterval = frameInterval
        self.keyFrameRate = keyFrameRate
        self.pFrameRate = pFrameRate
        self.compressionQuality = compressionQuality
        self.compressionWindowSize = compressionWindowSize
        self.delay = delay
        self.maxVideoFrameSize = maxVideoFrameSize
        self.maxPayloadTransferSize = maxPayloadTransferSize
    }

    /// Construct a block after checking wider integer inputs before narrowing
    /// them to their UVC wire widths.
    public init(
        validatingBmHint: UInt64 = 0,
        validatingFormatIndex: UInt64,
        validatingFrameIndex: UInt64,
        validatingFrameInterval: UInt64,
        validatingKeyFrameRate: UInt64 = 0,
        validatingPFrameRate: UInt64 = 0,
        validatingCompressionQuality: UInt64 = 0,
        validatingCompressionWindowSize: UInt64 = 0,
        validatingDelay: UInt64 = 0,
        validatingMaxVideoFrameSize: UInt64 = 0,
        validatingMaxPayloadTransferSize: UInt64 = 0
    ) throws {
        func u8(_ value: UInt64, _ field: String) throws -> UInt8 {
            guard value <= UInt64(UInt8.max) else {
                throw UVCNegotiationError.integerOverflow(field: field, value: value)
            }
            return UInt8(value)
        }
        func u16(_ value: UInt64, _ field: String) throws -> UInt16 {
            guard value <= UInt64(UInt16.max) else {
                throw UVCNegotiationError.integerOverflow(field: field, value: value)
            }
            return UInt16(value)
        }
        func u32(_ value: UInt64, _ field: String) throws -> UInt32 {
            guard value <= UInt64(UInt32.max) else {
                throw UVCNegotiationError.integerOverflow(field: field, value: value)
            }
            return UInt32(value)
        }

        self.init(
            bmHint: try u16(validatingBmHint, "bmHint"),
            formatIndex: try u8(validatingFormatIndex, "formatIndex"),
            frameIndex: try u8(validatingFrameIndex, "frameIndex"),
            frameInterval: try u32(validatingFrameInterval, "frameInterval"),
            keyFrameRate: try u16(validatingKeyFrameRate, "keyFrameRate"),
            pFrameRate: try u16(validatingPFrameRate, "pFrameRate"),
            compressionQuality: try u16(validatingCompressionQuality, "compressionQuality"),
            compressionWindowSize: try u16(validatingCompressionWindowSize, "compressionWindowSize"),
            delay: try u16(validatingDelay, "delay"),
            maxVideoFrameSize: try u32(validatingMaxVideoFrameSize, "maxVideoFrameSize"),
            maxPayloadTransferSize: try u32(validatingMaxPayloadTransferSize, "maxPayloadTransferSize"))
    }

    public init(data: Data, bounds: UVCProbeCommitSizeBounds = .pocket3H264) throws {
        guard data.count == Self.byteCount else {
            throw UVCNegotiationError.invalidControlLength(expected: Self.byteCount, actual: data.count)
        }
        self.init(
            bmHint: Self.read16(data, at: 0),
            formatIndex: data[2],
            frameIndex: data[3],
            frameInterval: Self.read32(data, at: 4),
            keyFrameRate: Self.read16(data, at: 8),
            pFrameRate: Self.read16(data, at: 10),
            compressionQuality: Self.read16(data, at: 12),
            compressionWindowSize: Self.read16(data, at: 14),
            delay: Self.read16(data, at: 16),
            maxVideoFrameSize: Self.read32(data, at: 18),
            maxPayloadTransferSize: Self.read32(data, at: 22))
        try bounds.validate(self)
    }

    public init(bytes: [UInt8], bounds: UVCProbeCommitSizeBounds = .pocket3H264) throws {
        try self.init(data: Data(bytes), bounds: bounds)
    }

    public static func decode(_ data: Data, bounds: UVCProbeCommitSizeBounds = .pocket3H264) throws -> Self {
        try Self(data: data, bounds: bounds)
    }

    public static func decode(_ bytes: [UInt8], bounds: UVCProbeCommitSizeBounds = .pocket3H264) throws -> Self {
        try Self(bytes: bytes, bounds: bounds)
    }

    /// The exact 26-byte UVC wire representation.
    public var encodedData: Data {
        var bytes = [UInt8](repeating: 0, count: Self.byteCount)
        Self.write16(bmHint, to: &bytes, at: 0)
        bytes[2] = formatIndex
        bytes[3] = frameIndex
        Self.write32(frameInterval, to: &bytes, at: 4)
        Self.write16(keyFrameRate, to: &bytes, at: 8)
        Self.write16(pFrameRate, to: &bytes, at: 10)
        Self.write16(compressionQuality, to: &bytes, at: 12)
        Self.write16(compressionWindowSize, to: &bytes, at: 14)
        Self.write16(delay, to: &bytes, at: 16)
        Self.write32(maxVideoFrameSize, to: &bytes, at: 18)
        Self.write32(maxPayloadTransferSize, to: &bytes, at: 22)
        return Data(bytes)
    }

    public var data: Data { encodedData }
    public var bytes: [UInt8] { Array(encodedData) }
    public func encode() -> Data { encodedData }
    public func encoded() -> Data { encodedData }

    // Common protocol spelling aliases keep call sites close to the UVC spec.
    public var bFormatIndex: UInt8 { formatIndex }
    public var bFrameIndex: UInt8 { frameIndex }
    public var dwFrameInterval: UInt32 { frameInterval }
    public var wKeyFrameRate: UInt16 { keyFrameRate }
    public var wPFrameRate: UInt16 { pFrameRate }
    public var wCompQuality: UInt16 { compressionQuality }
    public var wCompWindowSize: UInt16 { compressionWindowSize }
    public var wDelay: UInt16 { delay }
    public var dwMaxVideoFrameSize: UInt32 { maxVideoFrameSize }
    public var dwMaxPayloadTransferSize: UInt32 { maxPayloadTransferSize }

    private static func read16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func read32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }

    private static func write16(_ value: UInt16, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func write32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}

public typealias UVCProbeCommitBlock = UVCVideoStreamingControlBlock
public typealias UVCVideoStreamingProbeCommitBlock = UVCVideoStreamingControlBlock

/// One fixed Pocket 3 frame-based H.264 mode obtained from the captured UVC
/// descriptors.  Intervals are in the UVC 100 ns unit and are kept as integers
/// so that 24 fps (416666) is not rounded during negotiation.
public struct Pocket3H264Mode: Sendable, Equatable, Hashable {
    public static let formatIndex: UInt8 = 2
    public static let streamingInterfaceNumber: UInt8 = 1

    public let frameIndex: UInt8
    public let width: UInt16
    public let height: UInt16
    public let frameIntervals100ns: [UInt32]
    public let defaultFrameInterval100ns: UInt32
    public let minimumBitRate: UInt32
    public let maximumBitRate: UInt32

    public init(
        frameIndex: UInt8,
        width: UInt16,
        height: UInt16,
        frameIntervals100ns: [UInt32],
        defaultFrameInterval100ns: UInt32,
        minimumBitRate: UInt32,
        maximumBitRate: UInt32
    ) {
        self.frameIndex = frameIndex
        self.width = width
        self.height = height
        self.frameIntervals100ns = frameIntervals100ns
        self.defaultFrameInterval100ns = defaultFrameInterval100ns
        self.minimumBitRate = minimumBitRate
        self.maximumBitRate = maximumBitRate
    }

    public var formatIndex: UInt8 { Self.formatIndex }
    public var interfaceNumber: UInt8 { Self.streamingInterfaceNumber }
    public var intervals: [UInt32] { frameIntervals100ns }
    public var frameIntervals: [UInt32] { frameIntervals100ns }

    public func supports(interval: UInt32) -> Bool {
        frameIntervals100ns.contains(interval)
    }

    public func makeControlBlock(
        interval: UInt32,
        bmHint: UInt16 = 0,
        keyFrameRate: UInt16 = 0,
        pFrameRate: UInt16 = 0,
        compressionQuality: UInt16 = 0,
        compressionWindowSize: UInt16 = 0,
        delay: UInt16 = 0,
        maxVideoFrameSize: UInt32 = 0,
        maxPayloadTransferSize: UInt32 = 0
    ) throws -> UVCVideoStreamingControlBlock {
        guard supports(interval: interval) else {
            throw UVCNegotiationError.unsupportedInterval(formatIndex: Self.formatIndex, frameIndex: frameIndex, interval: interval)
        }
        let block = UVCVideoStreamingControlBlock(
            bmHint: bmHint, formatIndex: Self.formatIndex, frameIndex: frameIndex,
            frameInterval: interval, keyFrameRate: keyFrameRate, pFrameRate: pFrameRate,
            compressionQuality: compressionQuality, compressionWindowSize: compressionWindowSize,
            delay: delay, maxVideoFrameSize: maxVideoFrameSize,
            maxPayloadTransferSize: maxPayloadTransferSize)
        try UVCProbeCommitSizeBounds.pocket3H264.validate(block)
        return block
    }

    /// Validate a decoded response against the descriptor tuple and local
    /// independent size limits.  Other UVC fields may be device-normalized;
    /// `validateExactResponse` is available when every field must be unchanged.
    public func validateResponse(
        _ response: UVCVideoStreamingControlBlock,
        bounds: UVCProbeCommitSizeBounds = .pocket3H264
    ) throws {
        guard response.formatIndex == Self.formatIndex else {
            throw UVCNegotiationError.responseMismatch(
                field: "formatIndex", expected: String(Self.formatIndex), actual: String(response.formatIndex))
        }
        guard response.frameIndex == frameIndex else {
            throw UVCNegotiationError.responseMismatch(
                field: "frameIndex", expected: String(frameIndex), actual: String(response.frameIndex))
        }
        guard supports(interval: response.frameInterval) else {
            throw UVCNegotiationError.responseMismatch(
                field: "frameInterval", expected: frameIntervals100ns.map(String.init).joined(separator: ","),
                actual: String(response.frameInterval))
        }
        try bounds.validate(response)
    }

    public func validateResponse(
        _ responseData: Data,
        bounds: UVCProbeCommitSizeBounds = .pocket3H264
    ) throws -> UVCVideoStreamingControlBlock {
        let response = try UVCVideoStreamingControlBlock(data: responseData, bounds: bounds)
        try validateResponse(response, bounds: bounds)
        return response
    }

    /// Validate a response whose every field must remain equal to the block
    /// sent by the caller.  This is intentionally stricter than descriptor
    /// tuple validation and is useful for GET_CUR/COMMIT acknowledgements.
    public func validateExactResponse(
        _ response: UVCVideoStreamingControlBlock,
        expected: UVCVideoStreamingControlBlock,
        bounds: UVCProbeCommitSizeBounds = .pocket3H264
    ) throws {
        try validateResponse(response, bounds: bounds)
        let fields: [(String, String, String)] = [
            ("bmHint", String(expected.bmHint), String(response.bmHint)),
            ("formatIndex", String(expected.formatIndex), String(response.formatIndex)),
            ("frameIndex", String(expected.frameIndex), String(response.frameIndex)),
            ("frameInterval", String(expected.frameInterval), String(response.frameInterval)),
            ("keyFrameRate", String(expected.keyFrameRate), String(response.keyFrameRate)),
            ("pFrameRate", String(expected.pFrameRate), String(response.pFrameRate)),
            ("compressionQuality", String(expected.compressionQuality), String(response.compressionQuality)),
            ("compressionWindowSize", String(expected.compressionWindowSize), String(response.compressionWindowSize)),
            ("delay", String(expected.delay), String(response.delay)),
            ("maxVideoFrameSize", String(expected.maxVideoFrameSize), String(response.maxVideoFrameSize)),
            ("maxPayloadTransferSize", String(expected.maxPayloadTransferSize), String(response.maxPayloadTransferSize)),
        ]
        if let mismatch = fields.first(where: { $0.1 != $0.2 }) {
            throw UVCNegotiationError.responseMismatch(field: mismatch.0, expected: mismatch.1, actual: mismatch.2)
        }
    }
}

/// Exact descriptor-backed H.264 modes for Pocket 3 format 2.
public enum Pocket3H264ModeCatalog {
    public static let formatIndex: UInt8 = Pocket3H264Mode.formatIndex
    public static let streamingInterfaceNumber: UInt8 = Pocket3H264Mode.streamingInterfaceNumber

    public static let frame2 = Pocket3H264Mode(
        frameIndex: 2, width: 1920, height: 1080,
        frameIntervals100ns: [333_333, 400_000, 416_666],
        defaultFrameInterval100ns: 333_333,
        minimumBitRate: 32_000_000, maximumBitRate: 96_000_000)

    public static let frame4 = Pocket3H264Mode(
        frameIndex: 4, width: 1080, height: 1920,
        frameIntervals100ns: [333_333, 400_000, 416_666],
        defaultFrameInterval100ns: 333_333,
        minimumBitRate: 32_000_000, maximumBitRate: 96_000_000)

    public static let frame5 = Pocket3H264Mode(
        frameIndex: 5, width: 3840, height: 2160,
        frameIntervals100ns: [166_666, 200_000, 208_333, 333_333, 400_000, 416_666],
        defaultFrameInterval100ns: 333_333,
        minimumBitRate: 111_974_400, maximumBitRate: 223_948_800)

    public static let all: [Pocket3H264Mode] = [frame2, frame4, frame5]
    public static let modes: [Pocket3H264Mode] = all

    public static func mode(frameIndex: UInt8) -> Pocket3H264Mode? {
        all.first { $0.frameIndex == frameIndex }
    }

    public static func mode(width: UInt16, height: UInt16) -> Pocket3H264Mode? {
        all.first { $0.width == width && $0.height == height }
    }

    public static func mode(frameIndex: UInt8, interval: UInt32) throws -> Pocket3H264Mode {
        guard let mode = mode(frameIndex: frameIndex) else {
            throw UVCNegotiationError.unsupportedFrame(index: frameIndex)
        }
        guard mode.supports(interval: interval) else {
            throw UVCNegotiationError.unsupportedInterval(formatIndex: formatIndex, frameIndex: frameIndex, interval: interval)
        }
        return mode
    }

    public static func mode(width: UInt16, height: UInt16, interval: UInt32) throws -> Pocket3H264Mode {
        guard let mode = mode(width: width, height: height) else {
            throw UVCNegotiationError.unsupportedInterval(formatIndex: formatIndex, frameIndex: 0, interval: interval)
        }
        guard mode.supports(interval: interval) else {
            throw UVCNegotiationError.unsupportedInterval(formatIndex: formatIndex, frameIndex: mode.frameIndex, interval: interval)
        }
        return mode
    }

    public static func validate(_ block: UVCVideoStreamingControlBlock) throws -> Pocket3H264Mode {
        guard block.formatIndex == formatIndex else {
            throw UVCNegotiationError.unsupportedFormat(index: block.formatIndex)
        }
        let mode = try mode(frameIndex: block.frameIndex, interval: block.frameInterval)
        try mode.validateResponse(block)
        return mode
    }

    public static func controlBlock(
        frameIndex: UInt8,
        interval: UInt32,
        bmHint: UInt16 = 0,
        keyFrameRate: UInt16 = 0,
        pFrameRate: UInt16 = 0,
        compressionQuality: UInt16 = 0,
        compressionWindowSize: UInt16 = 0,
        delay: UInt16 = 0,
        maxVideoFrameSize: UInt32 = 0,
        maxPayloadTransferSize: UInt32 = 0
    ) throws -> UVCVideoStreamingControlBlock {
        let mode = try mode(frameIndex: frameIndex, interval: interval)
        return try mode.makeControlBlock(
            interval: interval, bmHint: bmHint, keyFrameRate: keyFrameRate,
            pFrameRate: pFrameRate, compressionQuality: compressionQuality,
            compressionWindowSize: compressionWindowSize, delay: delay,
            maxVideoFrameSize: maxVideoFrameSize, maxPayloadTransferSize: maxPayloadTransferSize)
    }
}

public typealias Pocket3H264Modes = Pocket3H264ModeCatalog
public typealias Pocket3H264ModeCatalogEntry = Pocket3H264Mode

public enum UVCVideoStreamingControlSelector: UInt16, Sendable, Equatable {
    case probe = 0x0100
    case commit = 0x0200
}

/// Setup-packet metadata for one UVC class-interface request.  This is data
/// only; a transport can turn `setupBytes` into its platform-specific request.
public struct UVCControlRequestMetadata: Sendable, Equatable {
    public let bmRequestType: UInt8
    public let bRequest: UInt8
    public let wValue: UInt16
    public let wIndex: UInt16
    public let wLength: UInt16

    public init(bmRequestType: UInt8, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, wLength: UInt16) {
        self.bmRequestType = bmRequestType
        self.bRequest = bRequest
        self.wValue = wValue
        self.wIndex = wIndex
        self.wLength = wLength
    }

    public var interfaceNumber: UInt8 { UInt8(truncatingIfNeeded: wIndex) }
    public var setupBytes: Data {
        Data([
            bmRequestType, bRequest,
            UInt8(truncatingIfNeeded: wValue), UInt8(truncatingIfNeeded: wValue >> 8),
            UInt8(truncatingIfNeeded: wIndex), UInt8(truncatingIfNeeded: wIndex >> 8),
            UInt8(truncatingIfNeeded: wLength), UInt8(truncatingIfNeeded: wLength >> 8),
        ])
    }
}

/// The only four VS control requests used by stage 1.  All metadata is fixed
/// to the Pocket 3's UVC 1.0 VS interface (number 1) and 26-byte block.
public enum UVCVideoStreamingRequest: String, CaseIterable, Sendable {
    case getMaxProbe
    case setCurProbe
    case getCurProbe
    case setCurCommit

    public static let getMax = Self.getMaxProbe
    public static let setProbe = Self.setCurProbe
    public static let getProbe = Self.getCurProbe
    public static let setCommit = Self.setCurCommit

    public var metadata: UVCControlRequestMetadata {
        switch self {
        case .getMaxProbe:
            return UVCControlRequestMetadata(
                bmRequestType: 0xa1, bRequest: 0x83,
                wValue: UVCVideoStreamingControlSelector.probe.rawValue,
                wIndex: 1, wLength: UInt16(UVCVideoStreamingControlBlock.byteCount))
        case .setCurProbe:
            return UVCControlRequestMetadata(
                bmRequestType: 0x21, bRequest: 0x01,
                wValue: UVCVideoStreamingControlSelector.probe.rawValue,
                wIndex: 1, wLength: UInt16(UVCVideoStreamingControlBlock.byteCount))
        case .getCurProbe:
            return UVCControlRequestMetadata(
                bmRequestType: 0xa1, bRequest: 0x81,
                wValue: UVCVideoStreamingControlSelector.probe.rawValue,
                wIndex: 1, wLength: UInt16(UVCVideoStreamingControlBlock.byteCount))
        case .setCurCommit:
            return UVCControlRequestMetadata(
                bmRequestType: 0x21, bRequest: 0x01,
                wValue: UVCVideoStreamingControlSelector.commit.rawValue,
                wIndex: 1, wLength: UInt16(UVCVideoStreamingControlBlock.byteCount))
        }
    }

    public var request: UVCControlRequestMetadata { metadata }
    public var setupPacket: Data { metadata.setupBytes }
    public var interfaceNumber: UInt8 { metadata.interfaceNumber }
}

public typealias UVCVideoStreamingRequestMetadata = UVCControlRequestMetadata
public typealias UVCProbeCommitRequest = UVCVideoStreamingRequest

/// Pure stage-1 response validation helpers.  Request metadata is exposed so a
/// future transport can sequence these operations without embedding protocol
/// constants in I/O code.
public enum Pocket3H264Negotiation {
    public static let controlBlockLength = UVCVideoStreamingControlBlock.byteCount
    public static let interfaceNumber = Pocket3H264Mode.streamingInterfaceNumber

    public static func validateResponse(
        _ responseData: Data,
        for request: UVCVideoStreamingRequest,
        mode: Pocket3H264Mode,
        bounds: UVCProbeCommitSizeBounds = .pocket3H264
    ) throws -> UVCVideoStreamingControlBlock {
        let response = try UVCVideoStreamingControlBlock(data: responseData, bounds: bounds)
        try validateResponse(response, for: request, mode: mode, bounds: bounds)
        return response
    }

    public static func validateResponse(
        _ response: UVCVideoStreamingControlBlock,
        for request: UVCVideoStreamingRequest,
        mode: Pocket3H264Mode,
        bounds: UVCProbeCommitSizeBounds = .pocket3H264
    ) throws {
        guard request.metadata.wLength == UVCVideoStreamingControlBlock.byteCount else {
            throw UVCNegotiationError.invalidControlLength(
                expected: UVCVideoStreamingControlBlock.byteCount, actual: Int(request.metadata.wLength))
        }
        guard request.interfaceNumber == Pocket3H264Mode.streamingInterfaceNumber else {
            throw UVCNegotiationError.responseMismatch(
                field: "interfaceNumber", expected: String(Pocket3H264Mode.streamingInterfaceNumber), actual: String(request.interfaceNumber))
        }
        try mode.validateResponse(response, bounds: bounds)
    }

    public static func validateExactResponse(
        _ responseData: Data,
        for request: UVCVideoStreamingRequest,
        mode: Pocket3H264Mode,
        expected: UVCVideoStreamingControlBlock,
        bounds: UVCProbeCommitSizeBounds = .pocket3H264
    ) throws -> UVCVideoStreamingControlBlock {
        let response = try validateResponse(responseData, for: request, mode: mode, bounds: bounds)
        try mode.validateExactResponse(response, expected: expected, bounds: bounds)
        return response
    }
}
