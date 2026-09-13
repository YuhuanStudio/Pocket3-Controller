import Foundation

/// Lifecycle of the bounded direct-UVC reader.  A terminal state never
/// schedules another read; callers must create a new binding after a new
/// owner/generation is admitted.
public enum DirectUVCH264BulkReaderState: String, Codable, Sendable,
    Equatable, CaseIterable {
    case ready
    case reading
    case waitingForPayload = "waiting_for_payload"
    case accessUnitReady = "access_unit_ready"
    case stopped
    case cancelled
    case generationChanged = "generation_changed"
    case failed
}

public enum DirectUVCH264BulkReaderError: Error, LocalizedError, Sendable,
    Equatable {
    case invalidAdmission
    case invalidGeneration
    case ownerMismatch
    case generationMismatch
    case readInFlight
    case transferRequestMismatch(expected: Int, actual: Int)
    case shortTransfer(expected: Int, actual: Int)
    case transferTooLarge(limit: Int, actual: Int)
    case emptyTransfer
    case payloadInvalid(String)
    case payloadErrorFlag
    case incompleteAccessUnit
    case multipleAccessUnits
    case h264Invalid(String)
    case transferLimitReached
    case cancelled
    case stopped
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAdmission: return "direct UVC bulk-reader admission is invalid"
        case .invalidGeneration: return "direct UVC bulk-reader generation is invalid"
        case .ownerMismatch: return "direct UVC bulk-reader owner does not match"
        case .generationMismatch: return "direct UVC bulk-reader generation does not match"
        case .readInFlight: return "direct UVC bulk-reader already has a read in flight"
        case .transferRequestMismatch(let expected, let actual):
            return "direct UVC bulk transfer request size mismatch: expected \(expected), received \(actual)"
        case .shortTransfer(let expected, let actual):
            return "direct UVC bulk transfer was short: expected \(expected), received \(actual)"
        case .transferTooLarge(let limit, let actual):
            return "direct UVC bulk transfer exceeded \(limit) bytes: received \(actual)"
        case .emptyTransfer: return "direct UVC bulk transfer was empty"
        case .payloadInvalid(let reason): return "direct UVC payload is invalid: " + reason
        case .payloadErrorFlag: return "direct UVC payload carried the ERR flag"
        case .incompleteAccessUnit: return "direct UVC access unit ended without EOF"
        case .multipleAccessUnits: return "direct UVC read produced multiple access units without a queue"
        case .h264Invalid(let reason): return "direct UVC H.264 access unit is invalid: " + reason
        case .transferLimitReached: return "direct UVC bulk-reader transfer limit reached"
        case .cancelled: return "direct UVC bulk-reader was cancelled"
        case .stopped: return "direct UVC bulk-reader was stopped"
        case .ioFailed(let reason): return "direct UVC bulk I/O failed: " + reason
        }
    }
}

/// A binding made from one committed negotiation and one exact owner fence.
/// The binding is intentionally separate from the negotiator result so a
/// caller must name the owner and generation that will consume the endpoint.
public struct DirectUVCBulkReaderBinding: Codable, Sendable, Equatable {
    public let ownerID: UUID
    public let generation: UInt64
    public let admission: DirectUVCBulkReaderAdmission

    public init(
        ownerID: UUID,
        generation: UInt64,
        admission: DirectUVCBulkReaderAdmission
    ) throws {
        guard generation > 0,
              admission.admitted,
              admission.interfaceNumber == 1,
              admission.endpointAddress == 0x82,
              !admission.streamReady else {
            if generation == 0 {
                throw DirectUVCH264BulkReaderError.invalidGeneration
            }
            throw DirectUVCH264BulkReaderError.invalidAdmission
        }
        self.ownerID = ownerID
        self.generation = generation
        self.admission = admission
    }

    public init(
        ownerID: UUID,
        generation: UInt64,
        negotiation: DirectUVCNegotiationResult
    ) throws {
        guard negotiation.committed, negotiation.completed,
              negotiation.steps.count == DirectUVCNegotiator.requiredSequence.count,
              negotiation.steps.map(\.request) == DirectUVCNegotiator.requiredSequence,
              negotiation.steps.allSatisfy({ $0.submitted && $0.validated }) else {
            throw DirectUVCH264BulkReaderError.invalidAdmission
        }
        try self.init(
            ownerID: ownerID, generation: generation,
            admission: negotiation.bulkReaderAdmission)
    }

    public func matches(ownerID: UUID, generation: UInt64) -> Bool {
        self.ownerID == ownerID && self.generation == generation
    }
}

public extension DirectUVCNegotiationResult {
    /// Creates the exact owner/generation fence required before a bulk reader
    /// can be constructed.  The returned binding still does not claim that a
    /// stream has produced bytes.
    func bulkReaderBinding(ownerID: UUID, generation: UInt64)
        throws -> DirectUVCBulkReaderBinding {
        try DirectUVCBulkReaderBinding(
            ownerID: ownerID, generation: generation, negotiation: self)
    }
}

public extension DirectUVCSessionResult {
    /// Convenience bridge from the existing session result.  The caller must
    /// supply the owner token associated with its already-owned VS interface.
    func bulkReaderBinding(ownerID: UUID) throws -> DirectUVCBulkReaderBinding {
        guard negotiated, generation > 0, let negotiation else {
            throw DirectUVCH264BulkReaderError.invalidAdmission
        }
        return try negotiation.bulkReaderBinding(
            ownerID: ownerID, generation: generation)
    }
}

public enum DirectUVCBulkTransferStatus: String, Codable, Sendable,
    Equatable, CaseIterable {
    case complete
    case short
}

/// One injectable bulk-IN completion.  `requestedByteCount` is the size the
/// reader asked the adapter to use; a completed USB transfer may contain fewer
/// bytes as long as the adapter marks it `complete`.  A transport-level short
/// status is fail-stop for this first reader slice.
public struct DirectUVCBulkTransfer: Codable, Sendable, Equatable {
    public let requestedByteCount: Int
    public let data: Data
    public let status: DirectUVCBulkTransferStatus

    public init(
        requestedByteCount: Int,
        data: Data,
        status: DirectUVCBulkTransferStatus = .complete
    ) {
        self.requestedByteCount = requestedByteCount
        self.data = Data(data)
        self.status = status
    }

    public var actualByteCount: Int { data.count }
}

/// Public-API transport seam for one bounded bulk-IN operation.  There is no
/// resubmit method: a reader call maps to exactly one adapter call.
public protocol DirectUVCBulkReaderIO: Sendable {
    func readBulkIn(maximumBytes: Int) async throws -> DirectUVCBulkTransfer
    func cancelBulkIn() async
}

public struct DirectUVCPayloadEvidence: Codable, Sendable, Equatable {
    public let transferByteCount: Int
    public let headerLength: Int
    public let flagsRaw: UInt8
    public let fid: Bool
    public let eof: Bool
    public let pts: UInt32?
    public let scr: UInt64?

    fileprivate init(payload: UVCPayload, transferByteCount: Int) {
        self.transferByteCount = transferByteCount
        self.headerLength = payload.header.length
        self.flagsRaw = payload.header.flags.rawValue
        self.fid = payload.header.fid
        self.eof = payload.header.eof
        self.pts = payload.header.pts
        self.scr = payload.header.scr
    }
}

/// Bounded evidence for one assembled H.264 AU.  The raw and normalized bytes
/// are retained only within the caller's negotiated assembler/normalizer
/// limits; no image or decoder is involved here.
public struct DirectUVCH264AccessUnitEvidence: Codable, Sendable,
    Equatable {
    public let data: Data
    public let fid: Bool
    public let pts: UInt32?
    public let scr: UInt64?
    public let endedByEOF: Bool
    public let normalizedData: Data?
    public let readiness: H264DecodeReadiness?
    public let containsIDR: Bool
    public let parameterSetsChanged: Bool

    fileprivate init(
        accessUnit: UVCAccessUnit,
        normalized: H264NormalizedAccessUnit?
    ) {
        self.data = Data(accessUnit.data)
        self.fid = accessUnit.fid
        self.pts = accessUnit.pts
        self.scr = accessUnit.scr
        self.endedByEOF = accessUnit.endedByEOF
        self.normalizedData = normalized.map { Data($0.data) }
        self.readiness = normalized?.readiness
        self.containsIDR = normalized?.containsIDR ?? false
        self.parameterSetsChanged = normalized?.parameterSetsChanged ?? false
    }
}

public struct DirectUVCH264BulkReaderResult: Codable, Sendable, Equatable {
    public let state: DirectUVCH264BulkReaderState
    public let ownerID: UUID
    public let generation: UInt64
    public let transferCount: Int
    public let totalBytes: Int
    public let payload: DirectUVCPayloadEvidence?
    public let accessUnit: DirectUVCH264AccessUnitEvidence?
    public let failureCode: String?

    public var accessUnitReady: Bool { accessUnit != nil }
    public var decodeReady: Bool {
        accessUnit?.readiness == .ready
    }
}

/// Bounded production core for direct UVC bulk-IN H.264.  This actor owns one
/// assembler and one normalizer for one exact binding.  It never retries a
/// failed completion and never performs ownership, seize, alternate-setting,
/// or hardware operations.
public actor DirectUVCH264BulkReader {
    public static let defaultMaximumTransferBytes = 4 * 1024 * 1024
    public static let defaultMaximumTransferCount = 4096

    public let binding: DirectUVCBulkReaderBinding
    public let maximumTransferBytes: Int
    public let maximumTransferCount: Int

    private let io: any DirectUVCBulkReaderIO
    private var assembler: UVCAccessUnitAssembler
    private var normalizer: H264AccessUnitNormalizer
    private var state: DirectUVCH264BulkReaderState = .ready
    private var transferCount = 0
    private var totalBytes = 0

    public init(
        binding: DirectUVCBulkReaderBinding,
        io: any DirectUVCBulkReaderIO,
        maximumTransferBytes: Int = DirectUVCH264BulkReader.defaultMaximumTransferBytes,
        maximumTransferCount: Int = DirectUVCH264BulkReader.defaultMaximumTransferCount,
        maximumAccumulatorBytes: Int = UVCAccessUnitAssembler.defaultMaximumAccumulatorBytes,
        normalizerLimits: H264AccessUnitLimits = .default
    ) throws {
        guard maximumTransferBytes > 2,
              maximumTransferBytes <= Self.defaultMaximumTransferBytes,
              maximumTransferCount > 0,
              maximumTransferCount <= Self.defaultMaximumTransferCount,
              maximumAccumulatorBytes > 0,
              maximumAccumulatorBytes >= maximumTransferBytes else {
            throw DirectUVCH264BulkReaderError.invalidAdmission
        }
        self.binding = binding
        self.io = io
        self.maximumTransferBytes = maximumTransferBytes
        self.maximumTransferCount = maximumTransferCount
        self.assembler = UVCAccessUnitAssembler(
            maximumPayloadBytes: maximumTransferBytes,
            maximumAccumulatorBytes: maximumAccumulatorBytes)
        self.normalizer = H264AccessUnitNormalizer(limits: normalizerLimits)
    }

    public func status() -> DirectUVCH264BulkReaderResult {
        result()
    }

    /// Reads exactly one adapter completion.  A completed transfer may be a
    /// fragment and therefore return without an access unit; callers can make
    /// another bounded call while the reader remains non-terminal.
    @discardableResult
    public func readNext(ownerID: UUID, generation: UInt64)
        async -> DirectUVCH264BulkReaderResult {
        guard binding.ownerID == ownerID else {
            return await fail(.ownerMismatch, terminal: .generationChanged)
        }
        guard binding.generation == generation else {
            return await fail(.generationMismatch, terminal: .generationChanged)
        }
        guard !Task.isCancelled else {
            return await cancelInternal()
        }
        guard state != .stopped, state != .cancelled,
              state != .generationChanged, state != .failed else {
            return result(failure: terminalFailureCode())
        }
        guard state != .reading else {
            return result(failure: code(.readInFlight))
        }
        guard transferCount < maximumTransferCount else {
            return await fail(.transferLimitReached, terminal: .failed)
        }

        state = .reading
        let transfer: DirectUVCBulkTransfer
        do {
            transfer = try await io.readBulkIn(
                maximumBytes: maximumTransferBytes)
        } catch is CancellationError {
            return await cancelInternal()
        } catch {
            if state == .reading {
                state = .failed
                resetAssembly()
                return result(failure: code(.ioFailed(
                    String(String(describing: error).prefix(128)))))
            }
            return result(failure: terminalFailureCode())
        }

        // `cancel`/`invalidate` can re-enter this actor while the adapter is
        // suspended.  Their terminal state fences this late completion.
        guard state == .reading else {
            return result(failure: terminalFailureCode())
        }
        guard transfer.requestedByteCount == maximumTransferBytes else {
            return await fail(
                .transferRequestMismatch(
                    expected: maximumTransferBytes,
                    actual: transfer.requestedByteCount), terminal: .failed)
        }
        guard transfer.status == .complete else {
            return await fail(
                .shortTransfer(expected: maximumTransferBytes,
                               actual: transfer.actualByteCount),
                terminal: .failed)
        }
        guard !transfer.data.isEmpty else {
            return await fail(.emptyTransfer, terminal: .failed)
        }
        guard transfer.data.count <= maximumTransferBytes else {
            return await fail(
                .transferTooLarge(limit: maximumTransferBytes,
                                  actual: transfer.data.count),
                terminal: .failed)
        }

        transferCount += 1
        totalBytes += transfer.data.count

        let payload: UVCPayload
        do {
            payload = try UVCPayload(
                transfer: transfer.data,
                maximumPayloadBytes: maximumTransferBytes)
        } catch {
            return await fail(
                .payloadInvalid(String(String(describing: error).prefix(128))),
                terminal: .failed,
                payload: nil)
        }
        let payloadEvidence = DirectUVCPayloadEvidence(
            payload: payload, transferByteCount: transfer.data.count)
        guard !payload.header.isError else {
            return await fail(.payloadErrorFlag, terminal: .failed,
                               payload: payloadEvidence)
        }

        let units = assembler.append(transfer.data)
        guard !assembler.requiresCleanRecovery else {
            return await fail(.payloadInvalid("assembler_recovery_required"),
                               terminal: .failed, payload: payloadEvidence)
        }
        guard units.count <= 1 else {
            return await fail(.multipleAccessUnits, terminal: .failed,
                               payload: payloadEvidence)
        }
        guard let unit = units.first else {
            state = .waitingForPayload
            return result(payload: payloadEvidence)
        }
        guard unit.endedByEOF else {
            return await fail(.incompleteAccessUnit, terminal: .failed,
                               payload: payloadEvidence,
                               accessUnit: DirectUVCH264AccessUnitEvidence(
                                accessUnit: unit, normalized: nil))
        }

        let normalized: H264NormalizedAccessUnit
        do {
            normalized = try normalizer.normalize(unit.data)
        } catch {
            return await fail(
                .h264Invalid(String(String(describing: error).prefix(128))),
                terminal: .failed, payload: payloadEvidence,
                accessUnit: DirectUVCH264AccessUnitEvidence(
                    accessUnit: unit, normalized: nil))
        }
        state = .accessUnitReady
        return result(
            payload: payloadEvidence,
            accessUnit: DirectUVCH264AccessUnitEvidence(
                accessUnit: unit, normalized: normalized))
    }

    public func read(ownerID: UUID, generation: UInt64)
        async -> DirectUVCH264BulkReaderResult {
        await readNext(ownerID: ownerID, generation: generation)
    }

    /// Cancels the current adapter operation and permanently fences this
    /// reader.  A new generation must construct a new reader.
    public func cancel() async -> DirectUVCH264BulkReaderResult {
        await cancelInternal()
    }

    /// Releases this reader without claiming that a stream was established.
    public func stop() async -> DirectUVCH264BulkReaderResult {
        guard state != .stopped else { return result(failure: code(.stopped)) }
        state = .stopped
        resetAssembly()
        await io.cancelBulkIn()
        return result(failure: code(.stopped))
    }

    /// Fences a late completion when the owner or generation changes.  The
    /// supplied identity is deliberately checked against the original exact
    /// binding; a mismatch is terminal and cannot be repaired in place.
    public func invalidate(ownerID: UUID, generation: UInt64)
        async -> DirectUVCH264BulkReaderResult {
        guard binding.matches(ownerID: ownerID, generation: generation) else {
            state = .generationChanged
            resetAssembly()
            await io.cancelBulkIn()
            return result(failure: code(.generationMismatch))
        }
        return result()
    }

    public func disconnect() async -> DirectUVCH264BulkReaderResult {
        await invalidate(ownerID: UUID(), generation: 0)
    }

    private func cancelInternal() async -> DirectUVCH264BulkReaderResult {
        if state != .cancelled {
            state = .cancelled
            resetAssembly()
            await io.cancelBulkIn()
        }
        return result(failure: code(.cancelled))
    }

    private func fail(
        _ error: DirectUVCH264BulkReaderError,
        terminal: DirectUVCH264BulkReaderState,
        payload: DirectUVCPayloadEvidence? = nil,
        accessUnit: DirectUVCH264AccessUnitEvidence? = nil
    ) async -> DirectUVCH264BulkReaderResult {
        state = terminal
        resetAssembly()
        return result(payload: payload, accessUnit: accessUnit,
                      failure: code(error))
    }

    private func result(
        payload: DirectUVCPayloadEvidence? = nil,
        accessUnit: DirectUVCH264AccessUnitEvidence? = nil,
        failure: String? = nil
    ) -> DirectUVCH264BulkReaderResult {
        DirectUVCH264BulkReaderResult(
            state: state, ownerID: binding.ownerID,
            generation: binding.generation, transferCount: transferCount,
            totalBytes: totalBytes, payload: payload,
            accessUnit: accessUnit, failureCode: failure)
    }

    private func resetAssembly() {
        assembler.reset()
        normalizer.reset()
    }

    private func terminalFailureCode() -> String? {
        switch state {
        case .cancelled: return code(.cancelled)
        case .stopped: return code(.stopped)
        case .generationChanged: return code(.generationMismatch)
        case .failed: return "direct_uvc_bulk_reader_failed"
        default: return nil
        }
    }

    private func code(_ error: DirectUVCH264BulkReaderError) -> String {
        switch error {
        case .invalidAdmission: return "direct_uvc_bulk_admission_invalid"
        case .invalidGeneration: return "direct_uvc_bulk_generation_invalid"
        case .ownerMismatch: return "direct_uvc_bulk_owner_mismatch"
        case .generationMismatch: return "direct_uvc_bulk_generation_mismatch"
        case .readInFlight: return "direct_uvc_bulk_read_in_flight"
        case .transferRequestMismatch: return "direct_uvc_bulk_request_size_mismatch"
        case .shortTransfer: return "direct_uvc_bulk_short_transfer"
        case .transferTooLarge: return "direct_uvc_bulk_transfer_too_large"
        case .emptyTransfer: return "direct_uvc_bulk_empty_transfer"
        case .payloadInvalid: return "direct_uvc_bulk_payload_invalid"
        case .payloadErrorFlag: return "direct_uvc_bulk_payload_error_flag"
        case .incompleteAccessUnit: return "direct_uvc_bulk_access_unit_incomplete"
        case .multipleAccessUnits: return "direct_uvc_bulk_multiple_access_units"
        case .h264Invalid: return "direct_uvc_bulk_h264_invalid"
        case .transferLimitReached: return "direct_uvc_bulk_transfer_limit"
        case .cancelled: return "direct_uvc_bulk_cancelled"
        case .stopped: return "direct_uvc_bulk_stopped"
        case .ioFailed: return "direct_uvc_bulk_io_failed"
        }
    }
}
