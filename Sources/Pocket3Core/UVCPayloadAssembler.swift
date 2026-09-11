import Foundation

/// The flags carried by a UVC video payload header.
///
/// A UVC 1.0 payload header has a fixed two-byte prefix.  PTS and SCR add
/// four and six bytes respectively; no other optional header fields are
/// accepted by the stage-1 parser.
public struct UVCPayloadHeaderFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let fid = Self(rawValue: 1 << 0)
    public static let eof = Self(rawValue: 1 << 1)
    public static let pts = Self(rawValue: 1 << 2)
    public static let scr = Self(rawValue: 1 << 3)
    public static let stillImage = Self(rawValue: 1 << 5)
    public static let error = Self(rawValue: 1 << 6)
    public static let endOfHeader = Self(rawValue: 1 << 7)

    /// Bits which this parser understands.  Reserved and still-image bits
    /// are rejected instead of being silently interpreted as a video packet.
    public static let recognizedMask: Self = [.fid, .eof, .pts, .scr, .stillImage, .error, .endOfHeader]
}

public enum UVCPayloadError: Error, Equatable, Sendable {
    case invalidMaximumPayloadBytes
    case transferTooShort
    case unsupportedFlags(UInt8)
    case headerLengthMismatch(expected: Int, actual: Int)
    case headerExceedsTransfer(length: Int, transferLength: Int)
    case payloadTooLarge(limit: Int, actual: Int)
}

/// The validated metadata from one complete UVC bulk transfer.
public struct UVCPayloadHeader: Sendable, Equatable {
    public let length: Int
    public let flags: UVCPayloadHeaderFlags
    public let pts: UInt32?
    public let scr: UInt64?

    public var fid: Bool { flags.contains(.fid) }
    public var eof: Bool { flags.contains(.eof) }
    public var hasPTS: Bool { flags.contains(.pts) }
    public var hasSCR: Bool { flags.contains(.scr) }
    public var isError: Bool { flags.contains(.error) }
    public var isStillImage: Bool { flags.contains(.stillImage) }
    public var hasEndOfHeader: Bool { flags.contains(.endOfHeader) }

    public init(length: Int, flags: UVCPayloadHeaderFlags, pts: UInt32? = nil, scr: UInt64? = nil) {
        self.length = length
        self.flags = flags
        self.pts = pts
        self.scr = scr
    }
}

/// One complete UVC payload.  `data` is exactly the bytes after the validated
/// UVC header; it is never searched for another header or decoded here.
public struct UVCPayload: Sendable, Equatable {
    public static let defaultMaximumPayloadBytes = 4 * 1024 * 1024

    public let header: UVCPayloadHeader
    public let data: Data

    public var payload: Data { data }
    public var bytes: Data { data }

    public init(transfer: Data, maximumPayloadBytes: Int = UVCPayload.defaultMaximumPayloadBytes) throws {
        guard maximumPayloadBytes >= 0 else { throw UVCPayloadError.invalidMaximumPayloadBytes }
        guard transfer.count >= 2 else { throw UVCPayloadError.transferTooShort }

        let rawFlags = transfer[1]
        let unknownFlags = rawFlags & ~UVCPayloadHeaderFlags.recognizedMask.rawValue
        guard unknownFlags == 0 else { throw UVCPayloadError.unsupportedFlags(rawFlags) }
        let flags = UVCPayloadHeaderFlags(rawValue: rawFlags)
        let expectedLength = 2 + (flags.contains(.pts) ? 4 : 0) + (flags.contains(.scr) ? 6 : 0)
        let actualLength = Int(transfer[0])
        guard actualLength == expectedLength else {
            throw UVCPayloadError.headerLengthMismatch(expected: expectedLength, actual: actualLength)
        }
        guard actualLength <= transfer.count else {
            throw UVCPayloadError.headerExceedsTransfer(length: actualLength, transferLength: transfer.count)
        }

        let payloadLength = transfer.count - actualLength
        guard payloadLength <= maximumPayloadBytes else {
            throw UVCPayloadError.payloadTooLarge(limit: maximumPayloadBytes, actual: payloadLength)
        }

        var offset = 2
        let pts: UInt32?
        if flags.contains(.pts) {
            pts = UInt32(transfer[offset])
                | (UInt32(transfer[offset + 1]) << 8)
                | (UInt32(transfer[offset + 2]) << 16)
                | (UInt32(transfer[offset + 3]) << 24)
            offset += 4
        } else {
            pts = nil
        }

        let scr: UInt64?
        if flags.contains(.scr) {
            var value: UInt64 = 0
            for index in 0..<6 {
                value |= UInt64(transfer[offset + index]) << UInt64(index * 8)
            }
            scr = value
        } else {
            scr = nil
        }

        header = UVCPayloadHeader(length: actualLength, flags: flags, pts: pts, scr: scr)
        data = Data(transfer.dropFirst(actualLength))
    }

    public static func parse(_ transfer: Data, maximumPayloadBytes: Int = UVCPayload.defaultMaximumPayloadBytes) throws -> Self {
        try Self(transfer: transfer, maximumPayloadBytes: maximumPayloadBytes)
    }

    public static func decode(_ transfer: Data, maximumPayloadBytes: Int = UVCPayload.defaultMaximumPayloadBytes) throws -> Self {
        try Self(transfer: transfer, maximumPayloadBytes: maximumPayloadBytes)
    }
}

public struct UVCAccessUnit: Sendable, Equatable {
    /// The concatenated H.264 bytes from the UVC payloads in this unit.  No
    /// Annex-B or AVCC interpretation is performed at this stage.
    public let data: Data
    public let fid: Bool
    public let pts: UInt32?
    public let scr: UInt64?
    public let endedByEOF: Bool

    public var payload: Data { data }
    public var bytes: Data { data }
    public var byteCount: Int { data.count }
}

public struct UVCAccessUnitAssemblerStatistics: Sendable, Equatable {
    public fileprivate(set) var acceptedPayloads = 0
    public fileprivate(set) var malformedPayloads = 0
    public fileprivate(set) var errorPayloads = 0
    public fileprivate(set) var accumulatorOverflows = 0
    public fileprivate(set) var losses = 0
    public fileprivate(set) var emptyEOFs = 0
    public fileprivate(set) var completedAccessUnits = 0
    public fileprivate(set) var droppedBytes = 0
}

/// Stage-1 UVC access-unit assembly.
///
/// Each call to `append` represents one already-completed bulk transfer and
/// therefore exactly one UVC payload.  The assembler only removes the one
/// validated payload header, joins payload bytes in arrival order, and emits
/// nonempty units at EOF or at a FID transition.  It deliberately does not
/// scan H.264 bytes for nested UVC headers or inspect NAL units.
public struct UVCAccessUnitAssembler: Sendable {
    public static let defaultMaximumPayloadBytes = UVCPayload.defaultMaximumPayloadBytes
    public static let defaultMaximumAccumulatorBytes = 16 * 1024 * 1024

    public let maximumPayloadBytes: Int
    public let maximumAccumulatorBytes: Int
    public private(set) var statistics = UVCAccessUnitAssemblerStatistics()
    public private(set) var requiresCleanRecovery = false

    private var currentFID: Bool?
    private var accumulator = Data()
    private var currentPTS: UInt32?
    private var currentSCR: UInt64?

    public var pendingByteCount: Int { accumulator.count }
    public var hasPendingAccessUnit: Bool { !accumulator.isEmpty }
    public var pendingFID: Bool? { currentFID }

    public init(maximumPayloadBytes: Int = Self.defaultMaximumPayloadBytes,
                maximumAccumulatorBytes: Int = Self.defaultMaximumAccumulatorBytes) {
        precondition(maximumPayloadBytes >= 0, "maximumPayloadBytes must be nonnegative")
        precondition(maximumAccumulatorBytes >= 0, "maximumAccumulatorBytes must be nonnegative")
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumAccumulatorBytes = maximumAccumulatorBytes
    }

    /// Consumes one complete transfer and returns any units completed by it.
    /// Malformed payloads, ERR payloads, and size violations are rejected and
    /// clear the current unit.  The next valid payload begins a clean unit.
    @discardableResult
    public mutating func append(_ transfer: Data) -> [UVCAccessUnit] {
        let payload: UVCPayload
        do {
            payload = try UVCPayload(transfer: transfer, maximumPayloadBytes: maximumPayloadBytes)
        } catch {
            statistics.malformedPayloads += 1
            dropCurrent(droppedBytes: accumulator.count)
            requiresCleanRecovery = true
            return []
        }

        if payload.header.isError {
            statistics.errorPayloads += 1
            dropCurrent(droppedBytes: accumulator.count + payload.data.count)
            requiresCleanRecovery = true
            return []
        }

        var completed: [UVCAccessUnit] = []
        if let currentFID, currentFID != payload.header.fid {
            if !accumulator.isEmpty {
                completed.append(finalize(endedByEOF: false))
            } else {
                clearCurrent()
            }
        }

        if currentFID == nil {
            currentFID = payload.header.fid
            currentPTS = payload.header.pts
            currentSCR = payload.header.scr
        } else {
            if currentPTS == nil { currentPTS = payload.header.pts }
            if currentSCR == nil { currentSCR = payload.header.scr }
        }

        guard payload.data.count <= maximumAccumulatorBytes,
              accumulator.count <= maximumAccumulatorBytes - payload.data.count else {
            statistics.accumulatorOverflows += 1
            dropCurrent(droppedBytes: accumulator.count + payload.data.count)
            requiresCleanRecovery = true
            return completed
        }

        accumulator.append(payload.data)
        statistics.acceptedPayloads += 1
        requiresCleanRecovery = false

        guard payload.header.eof else { return completed }
        guard !accumulator.isEmpty else {
            statistics.emptyEOFs += 1
            clearCurrent()
            return completed
        }
        completed.append(finalize(endedByEOF: true))
        return completed
    }

    /// Marks a transfer loss or other discontinuity.  A partial unit is
    /// discarded and the next valid payload starts a new unit.
    public mutating func markLoss() {
        statistics.losses += 1
        dropCurrent(droppedBytes: accumulator.count)
        requiresCleanRecovery = true
    }

    public mutating func reset() {
        let payloadLimit = maximumPayloadBytes
        let accumulatorLimit = maximumAccumulatorBytes
        self = Self(maximumPayloadBytes: payloadLimit, maximumAccumulatorBytes: accumulatorLimit)
    }

    private mutating func finalize(endedByEOF: Bool) -> UVCAccessUnit {
        let unit = UVCAccessUnit(data: accumulator, fid: currentFID ?? false,
                                 pts: currentPTS, scr: currentSCR, endedByEOF: endedByEOF)
        statistics.completedAccessUnits += 1
        clearCurrent()
        return unit
    }

    private mutating func clearCurrent() {
        accumulator.removeAll(keepingCapacity: false)
        currentFID = nil
        currentPTS = nil
        currentSCR = nil
    }

    private mutating func dropCurrent(droppedBytes: Int) {
        statistics.droppedBytes += droppedBytes
        clearCurrent()
    }
}

// Names used by callers that refer to the transport operation rather than the
// UVC object itself.  They intentionally remain aliases of the same pure data
// implementation.
public typealias UVCBulkPayload = UVCPayload
public typealias UVCBulkPayloadAssembler = UVCAccessUnitAssembler
public typealias UVCPayloadAssembler = UVCAccessUnitAssembler
