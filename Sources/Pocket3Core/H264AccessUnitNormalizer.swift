import Foundation

/// The two wire representations accepted by ``H264AccessUnitNormalizer``.
public enum H264InputFormat: String, Codable, Sendable, Equatable {
    case annexB
    case avcc
}

/// The bounded memory and output limits used while parsing one access unit.
///
/// The limits apply before any state is changed.  A caller handling data from
/// an untrusted USB endpoint should use a limit appropriate for its negotiated
/// frame size rather than relying on the defaults.
public struct H264AccessUnitLimits: Codable, Sendable, Equatable {
    public static let defaultMaxInputBytes = 8 * 1024 * 1024
    public static let defaultMaxOutputBytes = 8 * 1024 * 1024
    public static let defaultMaxNALBytes = 4 * 1024 * 1024
    public static let defaultMaxNALCount = 256
    public static let defaultMaxParameterSetBytes = 512 * 1024
    public static let defaultMaxCachedParameterSetBytes = 3 * defaultMaxParameterSetBytes

    public let maxInputBytes: Int
    public let maxOutputBytes: Int
    public let maxNALBytes: Int
    public let maxNALCount: Int
    public let maxParameterSetBytes: Int
    public let maxCachedParameterSetBytes: Int

    public static let `default` = H264AccessUnitLimits()

    public init(
        maxInputBytes: Int = H264AccessUnitLimits.defaultMaxInputBytes,
        maxOutputBytes: Int = H264AccessUnitLimits.defaultMaxOutputBytes,
        maxNALBytes: Int = H264AccessUnitLimits.defaultMaxNALBytes,
        maxNALCount: Int = H264AccessUnitLimits.defaultMaxNALCount,
        maxParameterSetBytes: Int = H264AccessUnitLimits.defaultMaxParameterSetBytes,
        maxCachedParameterSetBytes: Int = H264AccessUnitLimits.defaultMaxCachedParameterSetBytes
    ) {
        self.maxInputBytes = maxInputBytes
        self.maxOutputBytes = maxOutputBytes
        self.maxNALBytes = maxNALBytes
        self.maxNALCount = maxNALCount
        self.maxParameterSetBytes = maxParameterSetBytes
        self.maxCachedParameterSetBytes = maxCachedParameterSetBytes
    }

    fileprivate var isValid: Bool {
        maxInputBytes > 0 && maxOutputBytes > 0 && maxNALBytes > 0 &&
            maxNALCount > 0 && maxParameterSetBytes > 0 &&
            maxCachedParameterSetBytes > 0
    }
}

/// Errors raised before an access unit can be handed to a decoder.
public enum H264AccessUnitError: Error, Codable, Sendable, Equatable {
    case invalidLimits
    case emptyInput
    case inputTooLarge
    case malformedAnnexB
    case malformedAVCC
    case mixedFraming
    case emptyNAL
    case tooManyNALUnits
    case nalTooLarge
    case parameterSetTooLarge
    case outputTooLarge
    case invalidNALHeader
}

/// A single validated H.264 NAL unit, including its one-byte NAL header.
public struct H264NALUnit: Sendable, Equatable {
    public let type: UInt8
    public let data: Data

    public var nalType: UInt8 { type }

    fileprivate init(type: UInt8, data: Data) {
        self.type = type
        self.data = data
    }
}

/// Readiness reported by the normalizer.  ``ready`` means that the stream has
/// supplied the parameter sets and an IDR after the latest reset/loss or
/// parameter-set change.  It is a gate for a future decoder, never evidence
/// that VideoToolbox or any other decoder actually produced a frame.
public enum H264DecodeReadiness: String, Codable, Sendable, Equatable {
    case waitingForParameterSets
    case waitingForIDR
    case ready
}

/// The normalized result for one input access unit.
public struct H264NormalizedAccessUnit: Sendable, Equatable {
    /// Four-byte big-endian length-prefixed NAL units suitable for a decoder.
    public let data: Data
    public let nalUnits: [H264NALUnit]
    public let inputFormat: H264InputFormat
    public let readiness: H264DecodeReadiness
    /// This is a parameter-set/IDR gate only; it does not claim actual decode.
    public let isDecodable: Bool
    public let containsIDR: Bool
    public let parameterSetsChanged: Bool

    public var normalizedData: Data { data }
    public var hasSPS: Bool { nalUnits.contains { $0.type == 7 } }
    public var hasPPS: Bool { nalUnits.contains { $0.type == 8 } }

    fileprivate init(
        data: Data,
        nalUnits: [H264NALUnit],
        inputFormat: H264InputFormat,
        readiness: H264DecodeReadiness,
        parameterSetsChanged: Bool
    ) {
        self.data = data
        self.nalUnits = nalUnits
        self.inputFormat = inputFormat
        self.readiness = readiness
        self.isDecodable = readiness == .ready
        self.containsIDR = nalUnits.contains { $0.type == 5 }
        self.parameterSetsChanged = parameterSetsChanged
    }
}

/// A pure, bounded Annex-B/AVCC parser and parameter-set readiness state
/// machine.  It performs no I/O and does not perform video decoding.
public struct H264AccessUnitNormalizer: Sendable {
    public let limits: H264AccessUnitLimits

    private var sps: Data?
    private var pps: Data?
    private var spsExtension: Data?
    private var readiness: H264DecodeReadiness

    public init(limits: H264AccessUnitLimits = .default) {
        self.limits = limits
        sps = nil
        pps = nil
        spsExtension = nil
        readiness = .waitingForParameterSets
    }

    /// The cached SPS NAL, including its one-byte NAL header.
    public var cachedSPS: Data? { sps }
    /// The cached PPS NAL, including its one-byte NAL header.
    public var cachedPPS: Data? { pps }
    /// The optional cached SPS extension NAL (type 13), including its header.
    public var cachedSPSExtension: Data? { spsExtension }
    public var decodeReadiness: H264DecodeReadiness { readiness }
    public var isReadyForDecode: Bool { readiness == .ready }
    public var hasParameterSets: Bool { sps != nil && pps != nil }

    /// Normalize one complete access unit transactionally.
    ///
    /// The input must be either a strict Annex-B sequence beginning with a
    /// three- or four-byte start code, or a sequence of strict four-byte
    /// big-endian AVCC length prefixes.  Parsing failure leaves the cached
    /// parameter sets and readiness unchanged.
    public mutating func normalize(_ input: Data) throws -> H264NormalizedAccessUnit {
        guard limits.isValid else { throw H264AccessUnitError.invalidLimits }
        guard !input.isEmpty else { throw H264AccessUnitError.emptyInput }
        guard input.count <= limits.maxInputBytes else { throw H264AccessUnitError.inputTooLarge }

        let bytes = Array(input)
        let parsed = try Self.parse(bytes, limits: limits)
        let result = try updateState(with: parsed.nalUnits, format: parsed.format)
        return result
    }

    public mutating func normalize(_ input: [UInt8]) throws -> H264NormalizedAccessUnit {
        try normalize(Data(input))
    }

    /// An alias useful to a transport that calls each completed unit `append`.
    public mutating func append(_ input: Data) throws -> H264NormalizedAccessUnit {
        try normalize(input)
    }

    /// Clear parameter sets and require SPS, PPS, then IDR again.
    public mutating func reset() {
        sps = nil
        pps = nil
        spsExtension = nil
        readiness = .waitingForParameterSets
    }

    /// Mark a transport loss.  Cached parameter sets remain bounded and can be
    /// reused by the next IDR; if either set is absent, sets are required first.
    public mutating func markLoss() {
        readiness = hasParameterSets ? .waitingForIDR : .waitingForParameterSets
    }

    /// Alias for callers that use `loss` as the transport event name.
    public mutating func noteLoss() { markLoss() }

    private struct ParsedAccessUnit {
        let format: H264InputFormat
        let nalUnits: [H264NALUnit]
    }

    private static func parse(_ bytes: [UInt8], limits: H264AccessUnitLimits) throws -> ParsedAccessUnit {
        if startCodeLength(in: bytes, at: 0) != nil {
            let units = try parseAnnexB(bytes, limits: limits)
            return ParsedAccessUnit(format: .annexB, nalUnits: units)
        }

        let units = try parseAVCC(bytes, limits: limits)
        return ParsedAccessUnit(format: .avcc, nalUnits: units)
    }

    private static func parseAnnexB(_ bytes: [UInt8], limits: H264AccessUnitLimits) throws -> [H264NALUnit] {
        guard let firstLength = startCodeLength(in: bytes, at: 0) else {
            throw H264AccessUnitError.malformedAnnexB
        }

        var units: [H264NALUnit] = []
        units.reserveCapacity(min(8, limits.maxNALCount))
        var nalStart = firstLength

        while nalStart < bytes.count {
            guard units.count < limits.maxNALCount else {
                throw H264AccessUnitError.tooManyNALUnits
            }
            guard let nextStart = nextStartCode(in: bytes, from: nalStart) else {
                try appendNAL(bytes[nalStart..<bytes.count], to: &units, limits: limits, annexB: true)
                nalStart = bytes.count
                break
            }

            guard nextStart > nalStart else { throw H264AccessUnitError.emptyNAL }
            try appendNAL(bytes[nalStart..<nextStart], to: &units, limits: limits, annexB: true)
            guard let startLength = startCodeLength(in: bytes, at: nextStart) else {
                throw H264AccessUnitError.malformedAnnexB
            }
            nalStart = nextStart + startLength
            guard nalStart < bytes.count else { throw H264AccessUnitError.emptyNAL }
        }

        guard !units.isEmpty else { throw H264AccessUnitError.emptyNAL }
        return units
    }

    private static func parseAVCC(_ bytes: [UInt8], limits: H264AccessUnitLimits) throws -> [H264NALUnit] {
        var units: [H264NALUnit] = []
        units.reserveCapacity(min(8, limits.maxNALCount))
        var index = 0

        while index < bytes.count {
            guard units.count < limits.maxNALCount else {
                throw H264AccessUnitError.tooManyNALUnits
            }
            guard bytes.count - index >= 4 else { throw H264AccessUnitError.malformedAVCC }
            let length = (Int(bytes[index]) << 24) |
                (Int(bytes[index + 1]) << 16) |
                (Int(bytes[index + 2]) << 8) |
                Int(bytes[index + 3])
            index += 4
            guard length > 0 else { throw H264AccessUnitError.emptyNAL }
            guard length <= limits.maxNALBytes else { throw H264AccessUnitError.nalTooLarge }
            guard length <= bytes.count - index else { throw H264AccessUnitError.malformedAVCC }
            try appendNAL(bytes[index..<(index + length)], to: &units, limits: limits, annexB: false)
            index += length
        }

        guard !units.isEmpty else { throw H264AccessUnitError.emptyInput }
        return units
    }

    private static func appendNAL(
        _ slice: ArraySlice<UInt8>,
        to units: inout [H264NALUnit],
        limits: H264AccessUnitLimits,
        annexB: Bool
    ) throws {
        guard !slice.isEmpty else { throw H264AccessUnitError.emptyNAL }
        guard slice.count <= limits.maxNALBytes else { throw H264AccessUnitError.nalTooLarge }
        let first = slice[slice.startIndex]
        // forbidden_zero_bit must be zero.  Type 0 is reserved, as are the
        // aggregation/fragmentation types that do not represent a bytestream
        // NAL unit in either of the accepted formats.
        guard first & 0x80 == 0, (1...23).contains(first & 0x1f) else {
            if !annexB && looksLikeStartCode(in: slice) {
                throw H264AccessUnitError.mixedFraming
            }
            throw H264AccessUnitError.invalidNALHeader
        }

        // A NAL cannot contain an unescaped start-code prefix. Other zero runs
        // are not enough to prove mixed framing and remain valid EBSP bytes.
        if containsStartCode(in: slice) {
            throw H264AccessUnitError.mixedFraming
        }

        let type = first & 0x1f
        if type == 7 || type == 8 || type == 13,
           slice.count > limits.maxParameterSetBytes {
            throw H264AccessUnitError.parameterSetTooLarge
        }
        units.append(H264NALUnit(type: type, data: Data(slice)))
    }

    private static func startCodeLength(in bytes: [UInt8], at index: Int) -> Int? {
        guard index >= 0, index < bytes.count else { return nil }
        guard bytes.count - index >= 3,
              bytes[index] == 0, bytes[index + 1] == 0 else { return nil }
        if bytes.count - index >= 4, bytes[index + 2] == 0, bytes[index + 3] == 1 { return 4 }
        if bytes[index + 2] == 1 { return 3 }
        return nil
    }

    private static func nextStartCode(in bytes: [UInt8], from index: Int) -> Int? {
        guard index < bytes.count else { return nil }
        var cursor = index
        while cursor < bytes.count {
            if startCodeLength(in: bytes, at: cursor) != nil { return cursor }
            cursor += 1
        }
        return nil
    }

    private static func containsStartCode(in slice: ArraySlice<UInt8>) -> Bool {
        guard slice.count >= 3 else { return false }
        let bytes = Array(slice)
        return nextStartCode(in: bytes, from: 0) != nil
    }

    private static func looksLikeStartCode(in slice: ArraySlice<UInt8>) -> Bool {
        guard slice.count >= 3 else { return false }
        let bytes = Array(slice)
        return startCodeLength(in: bytes, at: 0) != nil
    }

    private mutating func updateState(
        with units: [H264NALUnit],
        format: H264InputFormat
    ) throws -> H264NormalizedAccessUnit {
        var nextSPS = sps
        var nextPPS = pps
        var nextExtension = spsExtension
        var changed = false
        var nextReadiness = readiness

        // NAL ordering matters.  An IDR only repairs readiness when both
        // parameter sets have already been observed in this state.  A later
        // parameter-set NAL in the same AU invalidates it again.
        for unit in units {
            switch unit.type {
            case 7:
                let didChange = nextSPS != unit.data
                if didChange { changed = true }
                nextSPS = unit.data
                if didChange {
                    nextReadiness = (nextSPS != nil && nextPPS != nil) ? .waitingForIDR : .waitingForParameterSets
                }
            case 8:
                let didChange = nextPPS != unit.data
                if didChange { changed = true }
                nextPPS = unit.data
                if didChange {
                    nextReadiness = (nextSPS != nil && nextPPS != nil) ? .waitingForIDR : .waitingForParameterSets
                }
            case 13:
                let didChange = nextExtension != unit.data
                if didChange { changed = true }
                nextExtension = unit.data
                if didChange {
                    nextReadiness = (nextSPS != nil && nextPPS != nil) ? .waitingForIDR : .waitingForParameterSets
                }
            case 5:
                if nextSPS != nil && nextPPS != nil { nextReadiness = .ready }
            default:
                break
            }
        }

        let (spsAndPPS, firstOverflow) = (nextSPS?.count ?? 0).addingReportingOverflow(nextPPS?.count ?? 0)
        let (cachedBytes, secondOverflow) = spsAndPPS.addingReportingOverflow(nextExtension?.count ?? 0)
        guard !firstOverflow && !secondOverflow,
              cachedBytes <= limits.maxCachedParameterSetBytes else {
            throw H264AccessUnitError.parameterSetTooLarge
        }

        let outputSize = try Self.normalizedSize(for: units, limit: limits.maxOutputBytes)
        var output = Data()
        output.reserveCapacity(outputSize)
        for unit in units {
            let length = UInt32(unit.data.count)
            output.append(UInt8((length >> 24) & 0xff))
            output.append(UInt8((length >> 16) & 0xff))
            output.append(UInt8((length >> 8) & 0xff))
            output.append(UInt8(length & 0xff))
            output.append(unit.data)
        }

        sps = nextSPS
        pps = nextPPS
        spsExtension = nextExtension
        readiness = nextReadiness
        return H264NormalizedAccessUnit(
            data: output,
            nalUnits: units,
            inputFormat: format,
            readiness: nextReadiness,
            parameterSetsChanged: changed
        )
    }

    private static func normalizedSize(for units: [H264NALUnit], limit: Int) throws -> Int {
        var total = 0
        for unit in units {
            guard unit.data.count <= Int.max - 4,
                  total <= Int.max - 4 - unit.data.count else {
                throw H264AccessUnitError.outputTooLarge
            }
            total += 4 + unit.data.count
            guard total <= limit else { throw H264AccessUnitError.outputTooLarge }
        }
        return total
    }
}

/// Compatibility name for transport code that calls a completed unit an AU.
public typealias H264AccessUnit = H264NormalizedAccessUnit
