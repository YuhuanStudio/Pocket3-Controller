import Foundation

/// The two wire representations accepted by ``HEVCAccessUnitNormalizer``.
public enum HEVCInputFormat: String, Codable, Sendable, Equatable {
    case annexB
    case hvcc

    /// A compatibility spelling for callers that use the H.264 name for
    /// length-prefixed NAL units.  HEVC length-prefixed samples are HVCC.
    public static var avcc: Self { .hvcc }
}

/// The bounded memory and output limits used while parsing one HEVC access
/// unit.  All limits are checked before this normalizer changes state.
public struct HEVCAccessUnitLimits: Codable, Sendable, Equatable {
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

    public static let `default` = HEVCAccessUnitLimits()

    public init(
        maxInputBytes: Int = HEVCAccessUnitLimits.defaultMaxInputBytes,
        maxOutputBytes: Int = HEVCAccessUnitLimits.defaultMaxOutputBytes,
        maxNALBytes: Int = HEVCAccessUnitLimits.defaultMaxNALBytes,
        maxNALCount: Int = HEVCAccessUnitLimits.defaultMaxNALCount,
        maxParameterSetBytes: Int = HEVCAccessUnitLimits.defaultMaxParameterSetBytes,
        maxCachedParameterSetBytes: Int = HEVCAccessUnitLimits.defaultMaxCachedParameterSetBytes
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
public enum HEVCAccessUnitError: Error, Codable, Sendable, Equatable {
    case invalidLimits
    case emptyInput
    case inputTooLarge
    case malformedAnnexB
    case malformedHVCC
    case mixedFraming
    case emptyNAL
    case tooManyNALUnits
    case nalTooLarge
    case parameterSetTooLarge
    case outputTooLarge
    case invalidNALHeader

    /// Compatibility spelling for code that uses the H.264 error name.
    public static var malformedAVCC: Self { .malformedHVCC }
    /// A format-neutral spelling for a malformed length-prefixed sample.
    public static var malformedLengthPrefixed: Self { .malformedHVCC }
}

/// A single validated HEVC NAL unit, including its two-byte NAL header.
public struct HEVCNALUnit: Sendable, Equatable {
    public let type: UInt8
    public let data: Data

    public var nalType: UInt8 { type }

    fileprivate init(type: UInt8, data: Data) {
        self.type = type
        self.data = data
    }
}

/// Readiness reported by the normalizer.  ``ready`` means that the stream has
/// supplied VPS, SPS, and PPS, followed by an IRAP NAL (type 16...23) after
/// the latest reset/loss or parameter-set change.  It is a gate for a future
/// decoder and does not claim that any decoder produced a frame.
public enum HEVCDecodeReadiness: String, Codable, Sendable, Equatable {
    case waitingForParameterSets
    case waitingForIRAP
    case ready

    /// A compatibility spelling for consumers that use the shorter IDR gate
    /// terminology.  HEVC readiness accepts every IRAP type, not just CRA.
    public static var waitingForIDR: Self { .waitingForIRAP }
}

/// The normalized result for one input access unit.
public struct HEVCNormalizedAccessUnit: Sendable, Equatable {
    /// Four-byte big-endian length-prefixed NAL units suitable for a decoder.
    public let data: Data
    public let nalUnits: [HEVCNALUnit]
    public let inputFormat: HEVCInputFormat
    public let readiness: HEVCDecodeReadiness
    /// This is a parameter-set/IRAP gate only; it does not claim actual decode.
    public let isDecodable: Bool
    public let containsIRAP: Bool
    public let parameterSetsChanged: Bool

    public var normalizedData: Data { data }
    public var hasVPS: Bool { nalUnits.contains { $0.type == 32 } }
    public var hasSPS: Bool { nalUnits.contains { $0.type == 33 } }
    public var hasPPS: Bool { nalUnits.contains { $0.type == 34 } }
    public var containsRandomAccessPoint: Bool { containsIRAP }

    fileprivate init(
        data: Data,
        nalUnits: [HEVCNALUnit],
        inputFormat: HEVCInputFormat,
        readiness: HEVCDecodeReadiness,
        parameterSetsChanged: Bool
    ) {
        self.data = data
        self.nalUnits = nalUnits
        self.inputFormat = inputFormat
        self.readiness = readiness
        self.isDecodable = readiness == .ready
        self.containsIRAP = nalUnits.contains { (16...23).contains($0.type) }
        self.parameterSetsChanged = parameterSetsChanged
    }
}

/// A pure, bounded Annex-B/HVCC parser and parameter-set readiness state
/// machine.  It performs no I/O and does not perform video decoding.
public struct HEVCAccessUnitNormalizer: Sendable {
    public let limits: HEVCAccessUnitLimits

    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var readiness: HEVCDecodeReadiness

    public init(limits: HEVCAccessUnitLimits = .default) {
        self.limits = limits
        vps = nil
        sps = nil
        pps = nil
        readiness = .waitingForParameterSets
    }

    /// The cached VPS NAL, including its two-byte NAL header.
    public var cachedVPS: Data? { vps }
    /// The cached SPS NAL, including its two-byte NAL header.
    public var cachedSPS: Data? { sps }
    /// The cached PPS NAL, including its two-byte NAL header.
    public var cachedPPS: Data? { pps }
    public var decodeReadiness: HEVCDecodeReadiness { readiness }
    public var isReadyForDecode: Bool { readiness == .ready }
    public var hasParameterSets: Bool { vps != nil && sps != nil && pps != nil }

    /// Normalize one complete access unit transactionally.
    ///
    /// The input must be either a strict Annex-B sequence beginning with a
    /// three- or four-byte start code, or a sequence of strict four-byte
    /// big-endian HVCC length prefixes.  Parsing or bound failures leave the
    /// cached parameter sets and readiness unchanged.
    public mutating func normalize(_ input: Data) throws -> HEVCNormalizedAccessUnit {
        guard limits.isValid else { throw HEVCAccessUnitError.invalidLimits }
        guard !input.isEmpty else { throw HEVCAccessUnitError.emptyInput }
        guard input.count <= limits.maxInputBytes else { throw HEVCAccessUnitError.inputTooLarge }

        let bytes = Array(input)
        let parsed = try Self.parse(bytes, limits: limits)
        return try updateState(with: parsed.nalUnits, format: parsed.format)
    }

    public mutating func normalize(_ input: [UInt8]) throws -> HEVCNormalizedAccessUnit {
        try normalize(Data(input))
    }

    /// An alias useful to a transport that calls each completed unit `append`.
    public mutating func append(_ input: Data) throws -> HEVCNormalizedAccessUnit {
        try normalize(input)
    }

    /// Clear parameter sets and require VPS, SPS, PPS, then an IRAP again.
    public mutating func reset() {
        vps = nil
        sps = nil
        pps = nil
        readiness = .waitingForParameterSets
    }

    /// Mark a transport loss.  Cached parameter sets remain bounded and can
    /// be reused by the next IRAP; if any set is absent, sets are required.
    public mutating func markLoss() {
        readiness = hasParameterSets ? .waitingForIRAP : .waitingForParameterSets
    }

    /// Alias for callers that use `loss` as the transport event name.
    public mutating func noteLoss() { markLoss() }

    private struct ParsedAccessUnit {
        let format: HEVCInputFormat
        let nalUnits: [HEVCNALUnit]
    }

    private static func parse(_ bytes: [UInt8], limits: HEVCAccessUnitLimits) throws -> ParsedAccessUnit {
        if startCodeLength(in: bytes, at: 0) != nil {
            let units = try parseAnnexB(bytes, limits: limits)
            return ParsedAccessUnit(format: .annexB, nalUnits: units)
        }

        let units = try parseHVCC(bytes, limits: limits)
        return ParsedAccessUnit(format: .hvcc, nalUnits: units)
    }

    private static func parseAnnexB(_ bytes: [UInt8], limits: HEVCAccessUnitLimits) throws -> [HEVCNALUnit] {
        guard let firstLength = startCodeLength(in: bytes, at: 0) else {
            throw HEVCAccessUnitError.malformedAnnexB
        }

        var units: [HEVCNALUnit] = []
        units.reserveCapacity(min(8, limits.maxNALCount))
        var nalStart = firstLength

        while nalStart < bytes.count {
            guard units.count < limits.maxNALCount else {
                throw HEVCAccessUnitError.tooManyNALUnits
            }
            guard let nextStart = nextStartCode(in: bytes, from: nalStart) else {
                try appendNAL(bytes[nalStart..<bytes.count], to: &units, limits: limits, annexB: true)
                nalStart = bytes.count
                break
            }

            guard nextStart > nalStart else { throw HEVCAccessUnitError.emptyNAL }
            try appendNAL(bytes[nalStart..<nextStart], to: &units, limits: limits, annexB: true)
            guard let startLength = startCodeLength(in: bytes, at: nextStart) else {
                throw HEVCAccessUnitError.malformedAnnexB
            }
            nalStart = nextStart + startLength
            guard nalStart < bytes.count else { throw HEVCAccessUnitError.emptyNAL }
        }

        guard !units.isEmpty else { throw HEVCAccessUnitError.emptyNAL }
        return units
    }

    private static func parseHVCC(_ bytes: [UInt8], limits: HEVCAccessUnitLimits) throws -> [HEVCNALUnit] {
        var units: [HEVCNALUnit] = []
        units.reserveCapacity(min(8, limits.maxNALCount))
        var index = 0

        while index < bytes.count {
            guard units.count < limits.maxNALCount else {
                throw HEVCAccessUnitError.tooManyNALUnits
            }
            guard bytes.count - index >= 4 else { throw HEVCAccessUnitError.malformedHVCC }
            let length = (Int(bytes[index]) << 24) |
                (Int(bytes[index + 1]) << 16) |
                (Int(bytes[index + 2]) << 8) |
                Int(bytes[index + 3])
            index += 4
            guard length > 0 else { throw HEVCAccessUnitError.emptyNAL }
            guard length <= limits.maxNALBytes else { throw HEVCAccessUnitError.nalTooLarge }
            guard length <= bytes.count - index else { throw HEVCAccessUnitError.malformedHVCC }
            try appendNAL(bytes[index..<(index + length)], to: &units, limits: limits, annexB: false)
            index += length
        }

        guard !units.isEmpty else { throw HEVCAccessUnitError.emptyInput }
        return units
    }

    private static func appendNAL(
        _ slice: ArraySlice<UInt8>,
        to units: inout [HEVCNALUnit],
        limits: HEVCAccessUnitLimits,
        annexB: Bool
    ) throws {
        guard !slice.isEmpty else { throw HEVCAccessUnitError.emptyNAL }
        guard slice.count <= limits.maxNALBytes else { throw HEVCAccessUnitError.nalTooLarge }
        guard slice.count >= 2 else { throw HEVCAccessUnitError.invalidNALHeader }

        let first = slice[slice.startIndex]
        let second = slice[slice.startIndex + 1]
        // forbidden_zero_bit must be zero and nuh_temporal_id_plus1 must be
        // non-zero.  The latter is the low three bits of the second header
        // byte.  All six-bit NAL types and layer IDs are syntactically valid.
        guard first & 0x80 == 0, second & 0x07 != 0 else {
            if !annexB && looksLikeStartCode(in: slice) {
                throw HEVCAccessUnitError.mixedFraming
            }
            throw HEVCAccessUnitError.invalidNALHeader
        }

        // A length-prefixed NAL cannot contain an unescaped start-code prefix;
        // otherwise this is likely Annex-B mixed into HVCC.  In Annex-B the
        // scanner above treats such a prefix as the next NAL boundary.
        if containsStartCode(in: slice) {
            throw HEVCAccessUnitError.mixedFraming
        }

        let type = (first >> 1) & 0x3f
        if (type == 32 || type == 33 || type == 34),
           slice.count > limits.maxParameterSetBytes {
            throw HEVCAccessUnitError.parameterSetTooLarge
        }
        units.append(HEVCNALUnit(type: type, data: Data(slice)))
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
        with units: [HEVCNALUnit],
        format: HEVCInputFormat
    ) throws -> HEVCNormalizedAccessUnit {
        var nextVPS = vps
        var nextSPS = sps
        var nextPPS = pps
        var changed = false
        var nextReadiness = readiness

        // NAL ordering matters.  An IRAP repairs readiness only when all
        // parameter sets have already been observed in this state.  A later
        // parameter-set NAL in the same AU invalidates it again.
        for unit in units {
            switch unit.type {
            case 32:
                let didChange = nextVPS != unit.data
                if didChange { changed = true }
                nextVPS = unit.data
                if didChange {
                    nextReadiness = (nextVPS != nil && nextSPS != nil && nextPPS != nil)
                        ? .waitingForIRAP : .waitingForParameterSets
                }
            case 33:
                let didChange = nextSPS != unit.data
                if didChange { changed = true }
                nextSPS = unit.data
                if didChange {
                    nextReadiness = (nextVPS != nil && nextSPS != nil && nextPPS != nil)
                        ? .waitingForIRAP : .waitingForParameterSets
                }
            case 34:
                let didChange = nextPPS != unit.data
                if didChange { changed = true }
                nextPPS = unit.data
                if didChange {
                    nextReadiness = (nextVPS != nil && nextSPS != nil && nextPPS != nil)
                        ? .waitingForIRAP : .waitingForParameterSets
                }
            default:
                if (16...23).contains(unit.type),
                   nextVPS != nil && nextSPS != nil && nextPPS != nil {
                    nextReadiness = .ready
                }
            }
        }

        let (vpsAndSPS, firstOverflow) = (nextVPS?.count ?? 0).addingReportingOverflow(nextSPS?.count ?? 0)
        let (vpsSPSAndPPS, secondOverflow) = vpsAndSPS.addingReportingOverflow(nextPPS?.count ?? 0)
        guard !firstOverflow && !secondOverflow,
              vpsSPSAndPPS <= limits.maxCachedParameterSetBytes else {
            throw HEVCAccessUnitError.parameterSetTooLarge
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

        vps = nextVPS
        sps = nextSPS
        pps = nextPPS
        readiness = nextReadiness
        return HEVCNormalizedAccessUnit(
            data: output,
            nalUnits: units,
            inputFormat: format,
            readiness: nextReadiness,
            parameterSetsChanged: changed
        )
    }

    private static func normalizedSize(for units: [HEVCNALUnit], limit: Int) throws -> Int {
        var total = 0
        for unit in units {
            guard unit.data.count <= Int.max - 4,
                  total <= Int.max - 4 - unit.data.count else {
                throw HEVCAccessUnitError.outputTooLarge
            }
            total += 4 + unit.data.count
            guard total <= limit else { throw HEVCAccessUnitError.outputTooLarge }
        }
        return total
    }
}

/// Compatibility name for transport code that calls a completed unit an AU.
public typealias HEVCAccessUnit = HEVCNormalizedAccessUnit

// H.265 spellings are aliases so callers can use either common codec name.
public typealias H265InputFormat = HEVCInputFormat
public typealias H265AccessUnitLimits = HEVCAccessUnitLimits
public typealias H265AccessUnitError = HEVCAccessUnitError
public typealias H265NALUnit = HEVCNALUnit
public typealias H265DecodeReadiness = HEVCDecodeReadiness
public typealias H265NormalizedAccessUnit = HEVCNormalizedAccessUnit
public typealias H265AccessUnitNormalizer = HEVCAccessUnitNormalizer
public typealias H265AccessUnit = HEVCAccessUnit
