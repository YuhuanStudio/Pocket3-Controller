import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// A compressed video codec understood by ``VideoToolboxAccessUnitDecoder``.
///
/// The decoder accepts caller-owned access-unit bytes only.  It does not open
/// a camera, USB interface, or transport endpoint.
public enum VideoToolboxCodec: String, Codable, Sendable, Equatable, Hashable {
    case h264
    case hevc

    /// H.265 is the codec name commonly used by UVC and camera settings.
    public static var h265: Self { .hevc }

    fileprivate var formatCodecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }

    fileprivate var requiredParameterSetCount: Int {
        switch self {
        case .h264: return 2
        case .hevc: return 3
        }
    }

    fileprivate func parameterSetType(_ data: Data) -> Int? {
        guard !data.isEmpty else { return nil }
        switch self {
        case .h264:
            return Int(data[data.startIndex] & 0x1f)
        case .hevc:
            guard data.count >= 2 else { return nil }
            return Int((data[data.startIndex] & 0x7e) >> 1)
        }
    }

    fileprivate func isValidParameterSet(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        switch self {
        case .h264:
            let header = data[data.startIndex]
            return header & 0x80 == 0 && (1...23).contains(header & 0x1f)
        case .hevc:
            guard data.count >= 2 else { return false }
            let first = data[data.startIndex]
            let second = data[data.index(after: data.startIndex)]
            return first & 0x80 == 0 && second & 0x07 != 0
                && parameterSetType(data).map { (0...47).contains($0) } == true
        }
    }

    fileprivate func isAllowedParameterSetType(_ type: Int) -> Bool {
        switch self {
        case .h264: return type == 7 || type == 8
        case .hevc: return type == 32 || type == 33 || type == 34
        }
    }

    fileprivate func isAllowedNALType(_ type: Int) -> Bool {
        switch self {
        case .h264: return (1...23).contains(type)
        case .hevc: return (0...47).contains(type)
        }
    }
}

/// Compatibility names for clients that use the shorter codec terminology.
public typealias EncodedVideoCodec = VideoToolboxCodec
public typealias VideoCodec = VideoToolboxCodec

/// Bounds applied before parameter-set or access-unit state is changed.
///
/// These limits protect the decoder from a malformed or untrusted stream. A
/// direct UVC reader should choose limits that also fit its negotiated frame
/// size rather than treating the defaults as a transport contract.
public struct VideoToolboxDecoderLimits: Codable, Sendable, Equatable {
    public static let defaultMaxAccessUnitBytes = 8 * 1024 * 1024
    public static let defaultMaxNALBytes = 4 * 1024 * 1024
    public static let defaultMaxNALCount = 256
    public static let defaultMaxParameterSetBytes = 512 * 1024
    public static let defaultMaxParameterSetCount = 8
    public static let defaultMaxCachedParameterSetBytes = 3 * defaultMaxParameterSetBytes
    public static let defaultMaxWidth = 8_192
    public static let defaultMaxHeight = 8_192

    public let maxAccessUnitBytes: Int
    public let maxNALBytes: Int
    public let maxNALCount: Int
    public let maxParameterSetBytes: Int
    public let maxParameterSetCount: Int
    public let maxCachedParameterSetBytes: Int
    public let maxWidth: Int
    public let maxHeight: Int

    public static let `default` = Self()

    public init(
        maxAccessUnitBytes: Int = Self.defaultMaxAccessUnitBytes,
        maxNALBytes: Int = Self.defaultMaxNALBytes,
        maxNALCount: Int = Self.defaultMaxNALCount,
        maxParameterSetBytes: Int = Self.defaultMaxParameterSetBytes,
        maxParameterSetCount: Int = Self.defaultMaxParameterSetCount,
        maxCachedParameterSetBytes: Int = Self.defaultMaxCachedParameterSetBytes,
        maxWidth: Int = Self.defaultMaxWidth,
        maxHeight: Int = Self.defaultMaxHeight
    ) {
        self.maxAccessUnitBytes = maxAccessUnitBytes
        self.maxNALBytes = maxNALBytes
        self.maxNALCount = maxNALCount
        self.maxParameterSetBytes = maxParameterSetBytes
        self.maxParameterSetCount = maxParameterSetCount
        self.maxCachedParameterSetBytes = maxCachedParameterSetBytes
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    fileprivate var isValid: Bool {
        maxAccessUnitBytes > 0 && maxNALBytes > 0 && maxNALCount > 0 &&
            maxParameterSetBytes > 0 && maxParameterSetCount > 0 &&
            maxCachedParameterSetBytes > 0 && maxWidth > 0 && maxHeight > 0
    }
}

public typealias VideoToolboxAccessUnitLimits = VideoToolboxDecoderLimits

/// Errors raised while validating input or creating/using VideoToolbox.
public enum VideoToolboxDecoderError: Error, Sendable, Equatable {
    case invalidLimits
    case invalidParameterSets
    case missingParameterSet
    case tooManyParameterSets
    case parameterSetTooLarge
    case parameterSetsTooLarge
    case emptyAccessUnit
    case accessUnitTooLarge
    case malformedAccessUnit
    case tooManyNALUnits
    case nalTooLarge
    case invalidNALHeader
    case invalidDimensions
    case dimensionMismatch(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
    case formatDescriptionCreationFailed(OSStatus)
    case sessionCreationFailed(OSStatus)
    case blockBufferCreationFailed(OSStatus)
    case blockBufferCopyFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case decodeFailed(OSStatus)
    case outputCallbackFailed(OSStatus)
    case noDecodedPixelBuffer
    case cancelled
    case staleGeneration(expected: UInt64, actual: UInt64)
    case invalidated
}

public typealias VideoToolboxAccessUnitError = VideoToolboxDecoderError

/// A bounded, owned set of H.264 or HEVC parameter-set NAL units.
///
/// Data is copied into the value, and each NAL includes its codec header (one
/// byte for H.264 and two bytes for HEVC). The four-byte lengths used in an
/// access unit are not part of a parameter set.
public struct VideoToolboxParameterSetBundle: Sendable, Equatable {
    public let codec: VideoToolboxCodec
    public let parameterSets: [Data]

    public var sets: [Data] { parameterSets }

    /// The first H.264 sequence parameter set or HEVC sequence parameter set.
    public var sps: Data? {
        parameterSets.first { codec.parameterSetType($0) == 7 || codec.parameterSetType($0) == 33 }
    }

    /// The first H.264 picture parameter set or HEVC picture parameter set.
    public var pps: Data? {
        parameterSets.first { codec.parameterSetType($0) == 8 || codec.parameterSetType($0) == 34 }
    }

    /// The first HEVC video parameter set. H.264 has no VPS.
    public var vps: Data? { parameterSets.first { codec.parameterSetType($0) == 32 } }

    public var h264SPS: Data? { codec == .h264 ? sps : nil }
    public var h264PPS: Data? { codec == .h264 ? pps : nil }
    public var hevcVPS: Data? { codec == .hevc ? vps : nil }
    public var hevcSPS: Data? { codec == .hevc ? sps : nil }
    public var hevcPPS: Data? { codec == .hevc ? pps : nil }

    public init(
        codec: VideoToolboxCodec,
        parameterSets: [Data],
        limits: VideoToolboxDecoderLimits = .default
    ) throws {
        guard limits.isValid else { throw VideoToolboxDecoderError.invalidLimits }
        guard parameterSets.count == codec.requiredParameterSetCount else {
            throw VideoToolboxDecoderError.missingParameterSet
        }
        guard parameterSets.count <= limits.maxParameterSetCount else {
            throw VideoToolboxDecoderError.tooManyParameterSets
        }

        var copied: [Data] = []
        copied.reserveCapacity(parameterSets.count)
        var total = 0
        for set in parameterSets {
            guard !set.isEmpty, codec.isValidParameterSet(set) else {
                throw VideoToolboxDecoderError.invalidParameterSets
            }
            guard let type = codec.parameterSetType(set), codec.isAllowedParameterSetType(type) else {
                throw VideoToolboxDecoderError.invalidParameterSets
            }
            guard set.count <= limits.maxParameterSetBytes else {
                throw VideoToolboxDecoderError.parameterSetTooLarge
            }
            guard total <= Int.max - set.count else {
                throw VideoToolboxDecoderError.parameterSetsTooLarge
            }
            total += set.count
            guard total <= limits.maxCachedParameterSetBytes else {
                throw VideoToolboxDecoderError.parameterSetsTooLarge
            }
            copied.append(Data(set))
        }

        let types = Set(copied.compactMap(codec.parameterSetType))
        switch codec {
        case .h264:
            guard types.contains(7), types.contains(8) else {
                throw VideoToolboxDecoderError.missingParameterSet
            }
        case .hevc:
            guard types.contains(32), types.contains(33), types.contains(34) else {
                throw VideoToolboxDecoderError.missingParameterSet
            }
        }
        let order: [Int] = codec == .h264 ? [7, 8] : [32, 33, 34]
        self.codec = codec
        self.parameterSets = order.compactMap { wanted in
            copied.first { codec.parameterSetType($0) == wanted }
        }
    }

    public init(
        h264SPS: Data,
        h264PPS: Data,
        limits: VideoToolboxDecoderLimits = .default
    ) throws {
        try self.init(codec: .h264, parameterSets: [h264SPS, h264PPS], limits: limits)
    }

    public init(
        sps: Data,
        pps: Data,
        limits: VideoToolboxDecoderLimits = .default
    ) throws {
        try self.init(h264SPS: sps, h264PPS: pps, limits: limits)
    }

    public init(
        hevcVPS: Data,
        hevcSPS: Data,
        hevcPPS: Data,
        limits: VideoToolboxDecoderLimits = .default
    ) throws {
        try self.init(codec: .hevc, parameterSets: [hevcVPS, hevcSPS, hevcPPS], limits: limits)
    }

    public init(
        vps: Data,
        sps: Data,
        pps: Data,
        limits: VideoToolboxDecoderLimits = .default
    ) throws {
        try self.init(hevcVPS: vps, hevcSPS: sps, hevcPPS: pps, limits: limits)
    }

    public static func h264(sps: Data, pps: Data, limits: VideoToolboxDecoderLimits = .default) throws -> Self {
        try Self(h264SPS: sps, h264PPS: pps, limits: limits)
    }

    public static func hevc(vps: Data, sps: Data, pps: Data, limits: VideoToolboxDecoderLimits = .default) throws -> Self {
        try Self(hevcVPS: vps, hevcSPS: sps, hevcPPS: pps, limits: limits)
    }
}

public typealias VideoToolboxParameterSets = VideoToolboxParameterSetBundle
public typealias VideoParameterSets = VideoToolboxParameterSetBundle

/// A validated four-byte big-endian length-prefixed access unit.
public struct VideoToolboxAccessUnit: Sendable, Equatable {
    public let codec: VideoToolboxCodec
    public let data: Data
    public let nalCount: Int

    public var bytes: Data { data }
    public var byteCount: Int { data.count }

    public init(
        codec: VideoToolboxCodec,
        data: Data,
        limits: VideoToolboxDecoderLimits = .default
    ) throws {
        let count = try Self.validate(data, codec: codec, limits: limits)
        self.codec = codec
        self.data = Data(data)
        self.nalCount = count
    }

    public init(
        data: Data,
        codec: VideoToolboxCodec,
        limits: VideoToolboxDecoderLimits = .default
    ) throws {
        try self.init(codec: codec, data: data, limits: limits)
    }

    fileprivate static func validate(
        _ data: Data,
        codec: VideoToolboxCodec,
        limits: VideoToolboxDecoderLimits
    ) throws -> Int {
        guard limits.isValid else { throw VideoToolboxDecoderError.invalidLimits }
        guard !data.isEmpty else { throw VideoToolboxDecoderError.emptyAccessUnit }
        guard data.count <= limits.maxAccessUnitBytes else {
            throw VideoToolboxDecoderError.accessUnitTooLarge
        }

        var index = data.startIndex
        var count = 0
        while index < data.endIndex {
            guard data.distance(from: index, to: data.endIndex) >= 4 else {
                throw VideoToolboxDecoderError.malformedAccessUnit
            }
            let length = (Int(data[index]) << 24) |
                (Int(data[data.index(index, offsetBy: 1)]) << 16) |
                (Int(data[data.index(index, offsetBy: 2)]) << 8) |
                Int(data[data.index(index, offsetBy: 3)])
            index = data.index(index, offsetBy: 4)
            guard length > 0 else { throw VideoToolboxDecoderError.malformedAccessUnit }
            guard length <= limits.maxNALBytes else { throw VideoToolboxDecoderError.nalTooLarge }
            guard length <= data.distance(from: index, to: data.endIndex) else {
                throw VideoToolboxDecoderError.malformedAccessUnit
            }
            guard count < limits.maxNALCount else { throw VideoToolboxDecoderError.tooManyNALUnits }
            let end = data.index(index, offsetBy: length)
            let header = data[index]
            let type: Int
            switch codec {
            case .h264:
                guard header & 0x80 == 0 else { throw VideoToolboxDecoderError.invalidNALHeader }
                type = Int(header & 0x1f)
            case .hevc:
                let second = length >= 2 ? data[data.index(after: index)] : 0
                guard length >= 2, header & 0x80 == 0, second & 0x07 != 0 else {
                    throw VideoToolboxDecoderError.invalidNALHeader
                }
                type = Int((header & 0x7e) >> 1)
            }
            guard codec.isAllowedNALType(type) else {
                throw VideoToolboxDecoderError.invalidNALHeader
            }
            count += 1
            index = end
        }
        guard count > 0 else { throw VideoToolboxDecoderError.emptyAccessUnit }
        return count
    }
}

public typealias EncodedVideoAccessUnit = VideoToolboxAccessUnit

/// A small shared generation counter used to fence output from a replaced
/// or cancelled decode session.
public final class VideoToolboxGenerationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    public init(initialGeneration: UInt64 = 0) {
        value = initialGeneration
    }

    public var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    public func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value = value == UInt64.max ? 0 : value + 1
        return value
    }

    public func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == generation
    }
}

/// The result of one synchronous decode call.
public struct VideoToolboxDecodeResult: @unchecked Sendable {
    public let status: OSStatus
    public let infoFlags: VTDecodeInfoFlags
    public let pixelBuffer: CVPixelBuffer?
    public let presentationTimeStamp: CMTime
    public let presentationDuration: CMTime
    public let generation: UInt64

    public var imageBuffer: CVImageBuffer? { pixelBuffer }
    public var didProducePixelBuffer: Bool { pixelBuffer != nil }
    public var frameWasDropped: Bool { infoFlags.contains(.frameDropped) }
}

/// Synchronous public-API VideoToolbox decoder for complete H.264/HEVC access
/// units.
///
/// The input must use four-byte big-endian NAL lengths. Parameter sets are
/// supplied once when the decoder is configured and copied into an owned
/// bundle. Each submitted access unit is copied into an owned CMBlockBuffer
/// and CMSampleBuffer before being passed to VideoToolbox. No camera or USB
/// API is used here; a future transport may feed this type after it owns and
/// validates its own endpoint.
public final class VideoToolboxAccessUnitDecoder: @unchecked Sendable {
    public let codec: VideoToolboxCodec
    public let parameterSets: VideoToolboxParameterSetBundle
    public let limits: VideoToolboxDecoderLimits
    public let dimensions: CMVideoDimensions
    public let generationFence: VideoToolboxGenerationFence

    private let lock = NSLock()
    private var formatDescription: CMVideoFormatDescription
    private var session: VTDecompressionSession?
    private var invalidated = false

    public init(
        codec: VideoToolboxCodec,
        parameterSets: VideoToolboxParameterSetBundle,
        dimensions expectedDimensions: CMVideoDimensions? = nil,
        limits: VideoToolboxDecoderLimits = .default,
        generationFence: VideoToolboxGenerationFence = VideoToolboxGenerationFence()
    ) throws {
        guard limits.isValid else { throw VideoToolboxDecoderError.invalidLimits }
        guard parameterSets.codec == codec else { throw VideoToolboxDecoderError.invalidParameterSets }
        guard parameterSets.parameterSets.count <= limits.maxParameterSetCount else {
            throw VideoToolboxDecoderError.tooManyParameterSets
        }
        guard parameterSets.parameterSets.allSatisfy({ $0.count <= limits.maxParameterSetBytes }) else {
            throw VideoToolboxDecoderError.parameterSetTooLarge
        }
        guard parameterSets.parameterSets.reduce(0, { partial, set in partial <= Int.max - set.count ? partial + set.count : Int.max }) <= limits.maxCachedParameterSetBytes else {
            throw VideoToolboxDecoderError.parameterSetsTooLarge
        }

        let description = try Self.makeFormatDescription(codec: codec, parameterSets: parameterSets)
        let actual = CMVideoFormatDescriptionGetDimensions(description)
        let width = Int(actual.width)
        let height = Int(actual.height)
        guard width > 0, height > 0, width <= limits.maxWidth, height <= limits.maxHeight else {
            throw VideoToolboxDecoderError.invalidDimensions
        }
        if let expectedDimensions {
            let expectedWidth = Int(expectedDimensions.width)
            let expectedHeight = Int(expectedDimensions.height)
            guard expectedWidth > 0, expectedHeight > 0,
                  expectedWidth <= limits.maxWidth, expectedHeight <= limits.maxHeight else {
                throw VideoToolboxDecoderError.invalidDimensions
            }
            guard expectedWidth == width, expectedHeight == height else {
                throw VideoToolboxDecoderError.dimensionMismatch(
                    expectedWidth: expectedWidth, expectedHeight: expectedHeight,
                    actualWidth: width, actualHeight: height)
            }
        }

        self.codec = codec
        self.parameterSets = parameterSets
        self.limits = limits
        self.dimensions = actual
        self.formatDescription = description
        self.generationFence = generationFence
    }

    public convenience init(
        codec: VideoToolboxCodec,
        parameters: VideoToolboxParameterSetBundle,
        dimensions expectedDimensions: CMVideoDimensions? = nil,
        limits: VideoToolboxDecoderLimits = .default,
        generationFence: VideoToolboxGenerationFence = VideoToolboxGenerationFence()
    ) throws {
        try self.init(codec: codec, parameterSets: parameters, dimensions: expectedDimensions,
                      limits: limits, generationFence: generationFence)
    }

    public convenience init(
        codec: VideoToolboxCodec,
        parameterSets: VideoToolboxParameterSetBundle,
        width: Int,
        height: Int,
        limits: VideoToolboxDecoderLimits = .default,
        generationFence: VideoToolboxGenerationFence = VideoToolboxGenerationFence()
    ) throws {
        try self.init(codec: codec, parameterSets: parameterSets,
                      dimensions: CMVideoDimensions(width: Int32(width), height: Int32(height)),
                      limits: limits, generationFence: generationFence)
    }

    public var currentGeneration: UInt64 { generationFence.currentGeneration }
    public var generation: UInt64 { currentGeneration }
    public var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }
    public var isValid: Bool { !isInvalidated }

    /// Decode one complete access unit synchronously.
    ///
    /// With no asynchronous decode flags, VideoToolbox invokes the output
    /// handler before this method returns. The optional expected generation is
    /// checked both before submission and after the callback; callers can use
    /// it to reject output after a transport reset or cancellation.
    public func decode(
        _ accessUnit: Data,
        presentationTimeStamp: CMTime = .zero,
        duration: CMTime = .invalid,
        expectedGeneration: UInt64? = nil
    ) throws -> VideoToolboxDecodeResult {
        let parsed = try VideoToolboxAccessUnit(codec: codec, data: accessUnit, limits: limits)
        return try decode(parsed, presentationTimeStamp: presentationTimeStamp,
                          duration: duration, expectedGeneration: expectedGeneration)
    }

    public func decode(
        _ accessUnit: VideoToolboxAccessUnit,
        presentationTimeStamp: CMTime = .zero,
        duration: CMTime = .invalid,
        expectedGeneration: UInt64? = nil
    ) throws -> VideoToolboxDecodeResult {
        guard accessUnit.codec == codec else { throw VideoToolboxDecoderError.invalidNALHeader }
        guard accessUnit.data.count <= limits.maxAccessUnitBytes else {
            throw VideoToolboxDecoderError.accessUnitTooLarge
        }

        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { throw VideoToolboxDecoderError.invalidated }
        let submittedGeneration = generationFence.currentGeneration
        if let expectedGeneration, expectedGeneration != submittedGeneration {
            throw VideoToolboxDecoderError.staleGeneration(expected: expectedGeneration, actual: submittedGeneration)
        }

        let session = try ensureSessionLocked()
        let blockBuffer = try Self.makeOwnedBlockBuffer(accessUnit.data)
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid)
        var sampleSize = accessUnit.data.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sampleBuffer else {
            throw VideoToolboxDecoderError.sampleBufferCreationFailed(sampleStatus)
        }

        let output = DecodeOutputState()
        var infoFlags: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: &infoFlags
        ) { status, callbackFlags, imageBuffer, _, pts, callbackDuration in
            output.receive(status: status, infoFlags: callbackFlags, imageBuffer: imageBuffer,
                           presentationTimeStamp: pts, presentationDuration: callbackDuration)
        }
        guard decodeStatus == noErr else {
            throw VideoToolboxDecoderError.decodeFailed(decodeStatus)
        }
        let actualGeneration = generationFence.currentGeneration
        guard actualGeneration == submittedGeneration else {
            throw VideoToolboxDecoderError.staleGeneration(expected: submittedGeneration, actual: actualGeneration)
        }
        guard let callback = output.snapshot() else {
            throw VideoToolboxDecoderError.noDecodedPixelBuffer
        }
        let combinedFlags = infoFlags.union(callback.infoFlags)
        if callback.status != noErr {
            throw VideoToolboxDecoderError.outputCallbackFailed(callback.status)
        }
        guard let pixelBuffer = callback.imageBuffer else {
            return VideoToolboxDecodeResult(
                status: callback.status,
                infoFlags: combinedFlags,
                pixelBuffer: nil,
                presentationTimeStamp: callback.presentationTimeStamp,
                presentationDuration: callback.presentationDuration,
                generation: submittedGeneration)
        }
        guard CVPixelBufferGetWidth(pixelBuffer) == Int(dimensions.width),
              CVPixelBufferGetHeight(pixelBuffer) == Int(dimensions.height) else {
            throw VideoToolboxDecoderError.dimensionMismatch(
                expectedWidth: Int(dimensions.width), expectedHeight: Int(dimensions.height),
                actualWidth: CVPixelBufferGetWidth(pixelBuffer), actualHeight: CVPixelBufferGetHeight(pixelBuffer))
        }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            throw VideoToolboxDecoderError.invalidDimensions
        }
        return VideoToolboxDecodeResult(
            status: callback.status,
            infoFlags: combinedFlags,
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: callback.presentationTimeStamp,
            presentationDuration: callback.presentationDuration,
            generation: submittedGeneration)
    }

    /// Invalidate the current session and advance the fence. Parameter sets
    /// remain available so the next decode can lazily create a fresh session.
    @discardableResult
    public func reset() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        invalidateSessionLocked()
        return generationFence.advance()
    }

    /// Cancel the current decode lifecycle. Since the initial decoder path is
    /// synchronous, cancellation fences the session for subsequent calls and
    /// releases it deterministically.
    @discardableResult
    public func cancel() -> UInt64 { reset() }

    /// Permanently invalidate the decoder. All later decode calls fail with
    /// ``VideoToolboxDecoderError/invalidated``.
    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { return }
        invalidated = true
        invalidateSessionLocked()
        _ = generationFence.advance()
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    private func ensureSessionLocked() throws -> VTDecompressionSession {
        if let session { return session }
        let attributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(dimensions.width),
            kCVPixelBufferHeightKey: Int(dimensions.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes,
            decompressionSessionOut: &created)
        guard status == noErr, let created else {
            throw VideoToolboxDecoderError.sessionCreationFailed(status)
        }
        session = created
        return created
    }

    private func invalidateSessionLocked() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
    }

    private static func makeFormatDescription(
        codec: VideoToolboxCodec,
        parameterSets: VideoToolboxParameterSetBundle
    ) throws -> CMVideoFormatDescription {
        var flattened = Data()
        var offsets: [Int] = []
        offsets.reserveCapacity(parameterSets.parameterSets.count)
        for set in parameterSets.parameterSets {
            offsets.append(flattened.count)
            flattened.append(set)
        }
        var pointers = [UnsafePointer<UInt8>](repeating: UnsafePointer(bitPattern: 1)!, count: parameterSets.parameterSets.count)
        let sizes = parameterSets.parameterSets.map(\.count)
        var description: CMVideoFormatDescription?
        let status = flattened.withUnsafeBytes { raw in
            guard let address = raw.baseAddress else { return OSStatus(-12780) }
            let base = address.assumingMemoryBound(to: UInt8.self)
            for index in pointers.indices { pointers[index] = base.advanced(by: offsets[index]) }
            return pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    guard let pointerBase = pointerBuffer.baseAddress,
                          let sizeBase = sizeBuffer.baseAddress else { return OSStatus(-12780) }
                    switch codec {
                    case .h264:
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: nil,
                            parameterSetCount: pointers.count,
                            parameterSetPointers: pointerBase,
                            parameterSetSizes: sizeBase,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description)
                    case .hevc:
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: nil,
                            parameterSetCount: pointers.count,
                            parameterSetPointers: pointerBase,
                            parameterSetSizes: sizeBase,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &description)
                    }
                }
            }
        }
        guard status == noErr, let description else {
            throw VideoToolboxDecoderError.formatDescriptionCreationFailed(status)
        }
        return description
    }

    private static func makeOwnedBlockBuffer(_ data: Data) throws -> CMBlockBuffer {
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer)
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw VideoToolboxDecoderError.blockBufferCreationFailed(createStatus)
        }
        let copyStatus = data.withUnsafeBytes { raw in
            guard let address = raw.baseAddress else { return OSStatus(-12780) }
            return CMBlockBufferReplaceDataBytes(
                with: address,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw VideoToolboxDecoderError.blockBufferCopyFailed(copyStatus)
        }
        return blockBuffer
    }
}

public typealias VideoToolboxDecoder = VideoToolboxAccessUnitDecoder
public typealias AccessUnitDecoder = VideoToolboxAccessUnitDecoder

private final class DecodeOutputState: @unchecked Sendable {
    struct Value: @unchecked Sendable {
        let status: OSStatus
        let infoFlags: VTDecodeInfoFlags
        let imageBuffer: CVPixelBuffer?
        let presentationTimeStamp: CMTime
        let presentationDuration: CMTime
    }

    private let lock = NSLock()
    private var value: Value?

    func snapshot() -> Value? { lock.withLock { value } }

    func receive(
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        presentationDuration: CMTime
    ) {
        lock.lock()
        defer { lock.unlock() }
        value = Value(
            status: status,
            infoFlags: infoFlags,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            presentationDuration: presentationDuration)
    }
}
