import Foundation

/// Developer-only media operations. The service intentionally omits favorite
/// and delete actions; those candidates remain protocol-only and have no
/// executor in this layer.
public enum NativeMediaValidationOperation: String, Codable, Sendable,
    Equatable, CaseIterable {
    case playbackEnter = "playback-enter"
    case playbackExit = "playback-exit"
    case presence
    case list
    case range

    public static let enter = Self.playbackEnter
    public static let exit = Self.playbackExit
    public static let mediaList = Self.list
    public static let downloadRange = Self.range
}

public enum NativeMediaValidationError: Error, Codable, Sendable, Equatable {
    case invalidArguments
    case invalidAction
    case invalidRequestIdentity
    case invalidTimeout
    case invalidRange
    case invalidRoute
    case sessionNotReady
    case missingSessionIdentity
    case baselineRequired
    case executorUnavailable
    case fetcherUnavailable
    case responseTooLarge
    case terminalReadbackMissing
    /// An older media-list cursor is only valid after a fresh, matching
    /// 02/80 playback observation.  This is deliberately distinct from a
    /// transport failure so callers can request a new readback/session.
    case playbackRequired
    case operationInFlight
    case staleTransaction
}

/// Strict JSON/CLI request for one media validation attempt. A list request is
/// always one page (counter + cursor); pagination is driven by a caller that
/// obtains a fresh request and generation rather than by a hidden loop.
public struct NativeMediaValidationRequest: Codable, Sendable, Equatable {
    public static let operation = "validation-wireless-native-media"

    public let action: NativeMediaValidationOperation
    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let counter: UInt8
    public let cursor: UInt32
    public let presenceInterval: TimeInterval
    public let maximumBytes: Int
    public let maximumChunkCount: Int
    public let rangeRequest: Pocket3MediaHTTPRangeRequest?
    public let execute: Bool
    public let timeout: TimeInterval

    public var operationName: NativeMediaValidationOperation { action }

    public init(
        action: NativeMediaValidationOperation,
        expectedSessionID: UUID, peripheralID: UUID, generation: UInt64,
        counter: UInt8 = 1,
        cursor: UInt32 = Pocket3MediaListRequest.newestSD,
        presenceInterval: TimeInterval = Pocket3MediaPresenceHold.defaultInterval,
        maximumBytes: Int = Pocket3MediaListReassembler.maximumAssembledBytes,
        maximumChunkCount: Int = Pocket3MediaListReassembler.maximumChunks,
        rangeRequest: Pocket3MediaHTTPRangeRequest? = nil,
        storage: UInt8? = nil, path: String? = nil,
        rangeStart: UInt64? = nil, rangeEnd: UInt64? = nil,
        execute: Bool = false, timeout: TimeInterval = 3
    ) throws {
        guard generation > 0, timeout.isFinite, timeout > 0,
              timeout <= NativeCommandTransactionRequest.maximumTimeout else {
            throw NativeMediaValidationError.invalidTimeout
        }
        guard maximumBytes > 0,
              maximumBytes <= Pocket3MediaListReassembler.maximumAssembledBytes,
              maximumChunkCount > 0,
              maximumChunkCount <= Pocket3MediaListReassembler.maximumChunks else {
            throw NativeMediaValidationError.invalidRange
        }
        guard presenceInterval.isFinite,
              (0.25...5).contains(presenceInterval) else {
            throw NativeMediaValidationError.invalidArguments
        }

        let resolvedRange: Pocket3MediaHTTPRangeRequest?
        if action == .range {
            if let rangeRequest {
                guard rangeRequest.identity.matches(
                    sessionID: expectedSessionID, generation: generation,
                    peripheralID: peripheralID) else {
                    throw NativeMediaValidationError.invalidRequestIdentity
                }
                resolvedRange = rangeRequest
            } else {
                guard let storage, let path, let rangeStart, let rangeEnd else {
                    throw NativeMediaValidationError.invalidRange
                }
                do {
                    let identity = try Pocket3MediaSessionIdentity(
                        sessionID: expectedSessionID, generation: generation,
                        peripheralID: peripheralID)
                    resolvedRange = try Pocket3MediaHTTPRangeRequest(
                        identity: identity, storage: storage, path: path,
                        range: try Pocket3MediaByteRange(start: rangeStart,
                                                         endInclusive: rangeEnd))
                } catch let error as Pocket3MediaProtocolError {
                    throw error == .invalidRange
                        ? NativeMediaValidationError.invalidRange
                        : NativeMediaValidationError.invalidArguments
                }
            }
        } else {
            guard rangeRequest == nil, storage == nil, path == nil,
                  rangeStart == nil, rangeEnd == nil else {
                throw NativeMediaValidationError.invalidArguments
            }
            resolvedRange = nil
        }

        if action == .list {
            guard counter != 0 else {
                throw NativeMediaValidationError.invalidArguments
            }
        }
        self.action = action
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.counter = counter
        self.cursor = cursor
        self.presenceInterval = presenceInterval
        self.maximumBytes = maximumBytes
        self.maximumChunkCount = maximumChunkCount
        self.rangeRequest = resolvedRange
        self.execute = execute
        self.timeout = timeout
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments else {
            throw NativeMediaValidationError.invalidArguments
        }
        let allowed = Set([
            "action", "expectedSessionID", "peripheralID", "generation",
            "counter", "cursor", "interval", "maximumBytes",
            "maximumChunks", "storage", "path", "start", "end",
            "execute", "timeout"
        ])
        guard Set(fields.keys).isSubset(of: allowed),
              let actionRaw = fields["action"]?.string,
              let action = Self.parseAction(actionRaw),
              let sessionRaw = fields["expectedSessionID"]?.string,
              let expectedSessionID = UUID(uuidString: sessionRaw),
              let peripheralRaw = fields["peripheralID"]?.string,
              let peripheralID = UUID(uuidString: peripheralRaw),
              let generation = Self.uint64(fields["generation"], minimum: 1) else {
            throw NativeMediaValidationError.invalidArguments
        }
        let execute = try Self.boolean(fields["execute"])
        let timeout = try Self.number(fields["timeout"], default: 3,
                                      invalid: .invalidTimeout)
        let counter = try Self.uint8(fields["counter"], default: 1)
        let cursor = try Self.uint32(fields["cursor"],
                                     default: Pocket3MediaListRequest.newestSD)
        let interval = try Self.number(fields["interval"], default: 1,
                                       invalid: .invalidArguments)
        let maximumBytes = try Self.int(fields["maximumBytes"],
                                        default: Pocket3MediaListReassembler.maximumAssembledBytes)
        let maximumChunks = try Self.int(fields["maximumChunks"],
                                         default: Pocket3MediaListReassembler.maximumChunks)
        let storage = try fields["storage"].map { value -> UInt8 in
            guard let raw = Self.uint8(value, minimum: 0, maximum: 1) else {
                throw NativeMediaValidationError.invalidRange
            }
            return raw
        }
        let path = try fields["path"].map { value -> String in
            guard let path = value.string else {
                throw NativeMediaValidationError.invalidRange
            }
            return path
        }
        let rangeStart = try fields["start"].map { value -> UInt64 in
            guard let raw = Self.uint64(value, minimum: 0) else {
                throw NativeMediaValidationError.invalidRange
            }
            return raw
        }
        let rangeEnd = try fields["end"].map { value -> UInt64 in
            guard let raw = Self.uint64(value, minimum: 0) else {
                throw NativeMediaValidationError.invalidRange
            }
            return raw
        }
        try self.init(action: action, expectedSessionID: expectedSessionID,
                      peripheralID: peripheralID, generation: generation,
                      counter: counter, cursor: cursor,
                      presenceInterval: interval, maximumBytes: maximumBytes,
                      maximumChunkCount: maximumChunks, storage: storage,
                      path: path, rangeStart: rangeStart, rangeEnd: rangeEnd,
                      execute: execute, timeout: timeout)
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        let names = [
            "--action": "action", "--session": "expectedSessionID",
            "--peripheral": "peripheralID", "--generation": "generation",
            "--counter": "counter", "--cursor": "cursor",
            "--interval": "interval", "--max-bytes": "maximumBytes",
            "--max-chunks": "maximumChunks", "--storage": "storage",
            "--path": "path", "--start": "start", "--end": "end",
            "--timeout": "timeout"
        ]
        while index < cliArguments.count {
            let argument = cliArguments[index]
            if argument == "--execute" {
                guard fields["execute"] == nil else {
                    throw BridgeFailure("usage", "Duplicate --execute")
                }
                fields["execute"] = .bool(true)
                index += 1
                continue
            }
            guard let key = names[argument], index + 1 < cliArguments.count,
                  fields[key] == nil else {
                throw BridgeFailure("usage",
                    "Unknown, duplicate or incomplete native media option")
            }
            let value = cliArguments[index + 1]
            switch key {
            case "action", "expectedSessionID", "peripheralID", "path":
                fields[key] = .string(value)
            case "interval", "timeout":
                guard let number = Double(value), number.isFinite else {
                    throw BridgeFailure("usage", "Native media timing values must be finite")
                }
                fields[key] = .number(number)
            case "generation", "counter", "cursor", "maximumBytes",
                 "maximumChunks", "storage", "start", "end":
                guard let number = Self.parseNumber(value) else {
                    throw BridgeFailure("usage", "Native media numeric values must be finite")
                }
                fields[key] = .number(number)
            default:
                throw BridgeFailure("usage", "Unknown native media option")
            }
            index += 2
        }
        do {
            try self.init(arguments: .object(fields))
        } catch let error as NativeMediaValidationError {
            throw BridgeFailure("invalid_native_media_request",
                                String(describing: error))
        } catch let error as Pocket3MediaProtocolError {
            throw BridgeFailure("invalid_native_media_request",
                                String(describing: error))
        }
    }

    public var arguments: JSONValue {
        var fields: [String: JSONValue] = [
            "action": .string(action.rawValue),
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString),
            "generation": .number(Double(generation)),
            "execute": .bool(execute), "timeout": .number(timeout)
        ]
        switch action {
        case .playbackEnter, .playbackExit: break
        case .presence:
            fields["interval"] = .number(presenceInterval)
        case .list:
            fields["counter"] = .number(Double(counter))
            fields["cursor"] = .number(Double(cursor))
            fields["maximumBytes"] = .number(Double(maximumBytes))
            fields["maximumChunks"] = .number(Double(maximumChunkCount))
        case .range:
            if let rangeRequest {
                fields["storage"] = .number(Double(rangeRequest.storage))
                fields["path"] = .string(rangeRequest.path)
                fields["start"] = .number(Double(rangeRequest.range.start))
                fields["end"] = .number(Double(rangeRequest.range.endInclusive))
            }
        }
        return .object(fields)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "action": .object(["type": .string("string"),
                "enum": .array(NativeMediaValidationOperation.allCases.map {
                    .string($0.rawValue)
                })]),
            "expectedSessionID": .object(["type": .string("string")]),
            "peripheralID": .object(["type": .string("string")]),
            "generation": .object(["type": .string("integer"), "minimum": .number(1)]),
            "counter": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(255)]),
            "cursor": .object(["type": .string("integer"), "minimum": .number(0)]),
            "interval": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(5)]),
            "maximumBytes": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(Double(Pocket3MediaListReassembler.maximumAssembledBytes))]),
            "maximumChunks": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(Double(Pocket3MediaListReassembler.maximumChunks))]),
            "storage": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(1)]),
            "path": .object(["type": .string("string")]),
            "start": .object(["type": .string("integer"), "minimum": .number(0)]),
            "end": .object(["type": .string("integer"), "minimum": .number(0)]),
            "execute": .object(["type": .string("boolean")]),
            "timeout": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(5)])
        ]),
        "required": .array([.string("action"), .string("expectedSessionID"),
                             .string("peripheralID"), .string("generation")]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }

    private static func parseAction(_ raw: String) -> NativeMediaValidationOperation? {
        if let action = NativeMediaValidationOperation(rawValue: raw) {
            return action
        }
        switch raw.lowercased() {
        case "enter", "playback": return .playbackEnter
        case "exit", "leave": return .playbackExit
        case "hold", "presence-hold": return .presence
        case "media-list", "list-page": return .list
        case "download", "download-range": return .range
        default: return nil
        }
    }

    private static func boolean(_ value: JSONValue?) throws -> Bool {
        guard let value else { return false }
        guard let result = value.bool else {
            throw NativeMediaValidationError.invalidArguments
        }
        return result
    }

    private static func number(_ value: JSONValue?, default fallback: Double,
                               invalid: NativeMediaValidationError) throws -> Double {
        guard let value else { return fallback }
        guard let result = value.number, result.isFinite else { throw invalid }
        return result
    }

    private static func int(_ value: JSONValue?, default fallback: Int) throws -> Int {
        guard let value else { return fallback }
        guard let number = value.number, number.isFinite,
              number.rounded() == number, let result = Int(exactly: number) else {
            throw NativeMediaValidationError.invalidArguments
        }
        return result
    }

    private static func parseNumber(_ value: String) -> Double? {
        if value.lowercased().hasPrefix("0x"),
           let raw = UInt64(value.dropFirst(2), radix: 16) {
            return Double(raw)
        }
        return Double(value)
    }

    private static func integer(_ value: JSONValue?) -> Int64? {
        if let number = value?.number, number.isFinite,
           number.rounded() == number, let result = Int64(exactly: number) {
            return result
        }
        if let text = value?.string {
            if text.lowercased().hasPrefix("0x"),
               let raw = UInt64(text.dropFirst(2), radix: 16),
               raw <= UInt64(Int64.max) { return Int64(raw) }
            return Int64(text)
        }
        return nil
    }

    private static func uint8(_ value: JSONValue?, default fallback: UInt8)
        throws -> UInt8 {
        guard let value else { return fallback }
        guard let result = uint8(value, minimum: 0, maximum: UInt8.max) else {
            throw NativeMediaValidationError.invalidArguments
        }
        return result
    }

    private static func uint8(_ value: JSONValue?, minimum: UInt8,
                              maximum: UInt8) -> UInt8? {
        guard let raw = integer(value), raw >= Int64(minimum),
              raw <= Int64(maximum) else { return nil }
        return UInt8(exactly: raw)
    }

    private static func uint32(_ value: JSONValue?, default fallback: UInt32)
        throws -> UInt32 {
        guard let value else { return fallback }
        guard let result = uint32(value, minimum: 0, maximum: UInt32.max) else {
            throw NativeMediaValidationError.invalidArguments
        }
        return result
    }

    private static func uint32(_ value: JSONValue?, minimum: UInt32,
                               maximum: UInt32) -> UInt32? {
        guard let raw = integer(value), raw >= Int64(minimum),
              raw <= Int64(maximum) else { return nil }
        return UInt32(exactly: raw)
    }

    private static func uint64(_ value: JSONValue?, minimum: UInt64) -> UInt64? {
        guard let raw = integer(value), raw >= Int64(minimum) else { return nil }
        return UInt64(exactly: raw)
    }
}

/// The route snapshot belongs to the existing native owner. Unknown route
/// state is visible in dry-run output but blocks an explicit execution.
public struct NativeMediaValidationSnapshot: Codable, Sendable, Equatable {
    public let session: NativeCameraSessionStatus
    public let routeStatus: Pocket3DatalinkRouteStatus
    public let nowUptime: TimeInterval
    /// The latest validated 02/80 media state for this exact session and
    /// generation.  It is optional because newest media pages do not require
    /// playback and a caller may not have observed a status frame yet.
    public let mediaSession: Pocket3MediaSessionObservation?

    public init(session: NativeCameraSessionStatus,
                routeStatus: Pocket3DatalinkRouteStatus = .init(
                    state: .legacyUnbound,
                    evidence: "legacy_route_explicit"),
                nowUptime: TimeInterval,
                mediaSession: Pocket3MediaSessionObservation? = nil) {
        self.session = session
        self.routeStatus = routeStatus
        self.nowUptime = nowUptime
        self.mediaSession = mediaSession
    }

    public var currentMediaSession: Pocket3MediaSessionObservation? {
        mediaSession
    }

    public var routeAllowed: Bool {
        switch routeStatus.state {
        case .legacyUnbound, .interfaceBound, .samePrimaryRoute: true
        case .unknown, .interfaceUnavailable, .interfaceNotReady,
             .cameraRouteUnavailable, .defaultRouteChanged: false
        }
    }

    /// HTTP media is stricter than the existing native command route: an
    /// unbound legacy route would let the kernel choose an unrelated default
    /// interface, so only a live, explicitly identified camera interface is
    /// accepted for a range fetch.
    public var rangeRouteAllowed: Bool {
        guard routeAllowed,
              routeStatus.cameraHost == Pocket3MediaHTTPRangeRequest.host,
              let interfaceIndex = routeStatus.interfaceIndex,
              interfaceIndex != 0,
              routeStatus.cameraRouteReachable == true,
              routeStatus.defaultRouteChanged != true,
              routeStatus.samePrimaryRoute != false else { return false }
        return [.interfaceBound, .samePrimaryRoute].contains(routeStatus.state)
    }
}

public struct NativeMediaValidationRequestEvidence: Codable, Sendable,
    Equatable {
    public let id: UUID
    public let command: NativeCameraSessionCommand
    public let sessionID: UUID?
    public let peripheralID: UUID?
    public let generation: UInt64
    public let frame: NativeCommandFrame
    public let timeout: TimeInterval

    init(_ request: NativeCommandTransactionRequest,
         peripheralID: UUID? = nil) {
        id = request.id
        command = request.command
        sessionID = request.sessionID
        self.peripheralID = peripheralID
        generation = request.generation
        frame = request.frame
        timeout = request.timeout
    }
}

/// A small, serializable view of list progress. It does not include the
/// assembled bytes; a completed page exposes those through mediaIndex.raw.
public struct NativeMediaListValidationEvidence: Codable, Sendable,
    Equatable {
    public let phase: Pocket3MediaListReassemblyPhase
    public let assembledByteCount: Int
    public let acceptedChunkCount: Int
    public let rejectedChunkCount: Int
    public let unknownChunkCount: Int
    public let discardedByteCount: Int
    public let failure: Pocket3MediaListReassemblyFailure?

    init(_ snapshot: NativeMediaListCollectorSnapshot) {
        phase = snapshot.phase
        assembledByteCount = snapshot.assembledByteCount
        acceptedChunkCount = snapshot.acceptedChunkCount
        rejectedChunkCount = snapshot.rejectedChunkCount
        unknownChunkCount = snapshot.unknownChunkCount
        discardedByteCount = snapshot.discardedByteCount
        failure = snapshot.failure
    }
}

public struct NativeMediaRangeValidationResult: Codable, Sendable,
    Equatable {
    public let request: Pocket3MediaHTTPRangeRequest
    public let byteCount: Int
    /// Bytes are returned only by an injected fake/protocol adapter and are
    /// bounded by the request range. The App route supplies no fetcher.
    public let data: Data?

    init(request: Pocket3MediaHTTPRangeRequest, data: Data?) {
        self.request = request
        self.byteCount = data?.count ?? 0
        self.data = data
    }
}

public enum NativeMediaValidationPhase: String, Codable, Sendable,
    Equatable, CaseIterable {
    case dryRun
    case awaitingAcknowledgment
    case awaitingReadback
    case completed
    case routeRejected
    case executorUnavailable
    case fetcherUnavailable
    case timedOut
    case cancelled
    case generationChanged
    case failed
}

public struct NativeMediaValidationResult: Codable, Sendable, Equatable {
    public let action: NativeMediaValidationOperation
    public let executeRequested: Bool
    public let routeStatus: Pocket3DatalinkRouteStatus
    public let request: NativeMediaValidationRequestEvidence?
    public let transaction: NativeCommandTransactionResult?
    public let list: NativeMediaListValidationEvidence?
    public let mediaIndex: Pocket3MediaIndex?
    public let range: NativeMediaRangeValidationResult?
    public let phase: NativeMediaValidationPhase
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let failureCode: String?

    public var dryRun: Bool { !executeRequested }

    /// Typed 02/80 evidence captured by a playback transaction.  The raw
    /// payload remains in `transaction` so an unknown future flag layout is
    /// still inspectable even when no known state can be projected.
    public var mediaSessionReadback: Pocket3MediaSessionReadback? {
        guard let payload = transaction?.observedPayload else { return nil }
        return Pocket3MediaSessionReadback.decode(payload)
    }

    public var playbackReadback: Pocket3MediaSessionReadback? {
        mediaSessionReadback
    }

    /// Session/generation-bound typed playback evidence.  A missing or
    /// malformed payload never becomes an observation merely because an ACK
    /// was received.
    public var mediaSessionObservation: Pocket3MediaSessionObservation? {
        guard let readback = mediaSessionReadback,
              let request,
              let sessionID = request.sessionID,
              let observedUptime = transaction?.observedUptime else {
            return nil
        }
        return try? Pocket3MediaSessionObservation(
            sessionID: sessionID, peripheralID: request.peripheralID,
            generation: request.generation, receivedUptime: observedUptime,
            readback: readback)
    }

    public var playbackObservation: Pocket3MediaSessionObservation? {
        mediaSessionObservation
    }
}

public struct NativeMediaValidationExecutorAdapter: Sendable {
    public typealias Execute = @Sendable (
        _ request: NativeCommandTransactionRequest,
        _ readiness: NativeCameraSessionStatus
    ) async throws -> NativeCommandTransactionResult

    private let body: Execute

    public init(_ body: @escaping Execute) { self.body = body }

    public func execute(_ request: NativeCommandTransactionRequest,
                        readiness: NativeCameraSessionStatus) async throws
        -> NativeCommandTransactionResult {
        try await body(request, readiness)
    }
}

/// Protocol/fake seam for HTTP range downloads. Production code in this
/// batch intentionally injects no implementation, so no URLSession or socket
/// can be reached through the App route.
public protocol NativeMediaHTTPRangeFetching: Sendable {
    func fetch(_ request: Pocket3MediaHTTPRangeRequest,
               readiness: NativeCameraSessionStatus) async throws -> Data
    func fetch(_ request: Pocket3MediaHTTPRangeRequest,
               readiness: NativeCameraSessionStatus,
               timeout: TimeInterval) async throws -> Data
}

public extension NativeMediaHTTPRangeFetching {
    /// Existing fake adapters can remain two-argument closures. Production
    /// transports override this overload so the request timeout reaches the
    /// socket deadline instead of being silently ignored.
    func fetch(_ request: Pocket3MediaHTTPRangeRequest,
               readiness: NativeCameraSessionStatus,
               timeout: TimeInterval) async throws -> Data {
        try await fetch(request, readiness: readiness)
    }
}

public struct NativeMediaHTTPRangeFetcherAdapter: NativeMediaHTTPRangeFetching,
    Sendable {
    public typealias Fetch = @Sendable (
        _ request: Pocket3MediaHTTPRangeRequest,
        _ readiness: NativeCameraSessionStatus
    ) async throws -> Data

    private let body: Fetch

    public init(_ body: @escaping Fetch) { self.body = body }

    public func fetch(_ request: Pocket3MediaHTTPRangeRequest,
                      readiness: NativeCameraSessionStatus) async throws -> Data {
        try await body(request, readiness)
    }
}

/// The closure captured by a list transaction receives every 00/27 frame
/// until it returns a two-byte terminal marker. It keeps the large page out of
/// NativeCommandTransactionResult.observedPayload, whose evidence field is
/// intentionally bounded to one DUML payload.
public final class NativeMediaListObservationCollector: @unchecked Sendable {
    public static let terminalMarker: UInt8 = 0x4D
    public static let successMarker: UInt8 = 0x01
    public static let failureMarker: UInt8 = 0x00

    private let lock = NSLock()
    private let identity: Pocket3MediaSessionIdentity
    private var reassembler: Pocket3MediaListReassembler
    private var terminalPayload: Data?
    private var collectorFailure: Pocket3MediaListReassemblyFailure?

    public init(identity: Pocket3MediaSessionIdentity, counter: UInt8,
                cursor: UInt32,
                maximumBytes: Int = Pocket3MediaListReassembler.maximumAssembledBytes,
                maximumChunkCount: Int = Pocket3MediaListReassembler.maximumChunks)
        throws {
        self.identity = identity
        reassembler = try Pocket3MediaListReassembler(
            identity: identity, counter: counter, cursor: cursor,
            maximumBytes: maximumBytes, maximumChunkCount: maximumChunkCount)
    }

    /// Returns nil for a data/unknown chunk so the existing datalink owner
    /// continues receiving. End or malformed input returns a compact marker.
    public func observe(_ frame: DUMLFrame,
                        receivedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> Data? {
        lock.withLock {
            if let terminalPayload { return terminalPayload }
            guard frame.commandSet == 0x00, frame.commandID == 0x27 else {
                return fail(.malformedChunk)
            }
            guard let chunk = try? Pocket3MediaListChunk(payload: frame.payload) else {
                return fail(.malformedChunk)
            }
            do {
                try reassembler.ingest(chunk,
                    sessionID: identity.sessionID,
                    generation: identity.generation,
                    peripheralID: identity.peripheralID,
                    receivedUptime: receivedUptime)
            } catch {
                return fail(reassembler.failure ?? .malformedChunk)
            }
            if reassembler.phase == .completed {
                terminalPayload = Data([Self.terminalMarker, Self.successMarker])
            }
            return terminalPayload
        }
    }

    public func pack() -> Pocket3MediaListPack? {
        lock.withLock { try? reassembler.makePack() }
    }

    public func snapshot() -> NativeMediaListCollectorSnapshot {
        lock.withLock {
            NativeMediaListCollectorSnapshot(
                phase: reassembler.phase,
                assembledByteCount: reassembler.assembledData.count,
                acceptedChunkCount: reassembler.acceptedChunkCount,
                rejectedChunkCount: reassembler.rejectedChunkCount,
                unknownChunkCount: reassembler.unknownChunks.count,
                discardedByteCount: reassembler.discardedByteCount,
                failure: collectorFailure ?? reassembler.failure)
        }
    }

    public func cancel() { lock.withLock { reassembler.cancel() } }

    public func teardown() { lock.withLock { reassembler.teardown() } }

    private func fail(_ failure: Pocket3MediaListReassemblyFailure) -> Data {
        collectorFailure = failure
        // Keep the reassembler in a terminal state for late-frame rejection.
        // Its own ingest methods already set detailed failures for decoded
        // chunks; malformed frame errors have no corresponding ingest call.
        if reassembler.phase == .collecting {
            reassembler.cancel()
        }
        terminalPayload = Data([Self.terminalMarker, Self.failureMarker])
        return terminalPayload!
    }
}

public struct NativeMediaListCollectorSnapshot: Codable, Sendable,
    Equatable {
    public let phase: Pocket3MediaListReassemblyPhase
    public let assembledByteCount: Int
    public let acceptedChunkCount: Int
    public let rejectedChunkCount: Int
    public let unknownChunkCount: Int
    public let discardedByteCount: Int
    public let failure: Pocket3MediaListReassemblyFailure?
}

/// Developer-only media service. The command adapter is the current
/// Pocket3Datalink owner; this type never joins Wi-Fi, retries, or schedules
/// pagination. Range execution requires a separately validated explicit
/// interface route and an injected fetcher.
public struct NativeMediaValidationService: Sendable {
    public static let defaultTimeout: TimeInterval = 3

    private let executor: NativeMediaValidationExecutorAdapter?
    private let rangeFetcher: (any NativeMediaHTTPRangeFetching)?

    public init(
        adapter: NativeMediaValidationExecutorAdapter? = nil,
        rangeFetcher: (any NativeMediaHTTPRangeFetching)? = nil
    ) {
        executor = adapter
        self.rangeFetcher = rangeFetcher
    }

    public init(
        executor: NativeMediaValidationExecutorAdapter.Execute?,
        rangeFetcher: (any NativeMediaHTTPRangeFetching)? = nil
    ) {
        if let executor {
            self.executor = NativeMediaValidationExecutorAdapter(executor)
        } else {
            self.executor = nil
        }
        self.rangeFetcher = rangeFetcher
    }

    public func run(_ request: NativeMediaValidationRequest,
                    snapshot: NativeMediaValidationSnapshot) async throws
        -> NativeMediaValidationResult {
        guard request.expectedSessionID == snapshot.session.sessionID,
              request.peripheralID == snapshot.session.peerID,
              request.generation == snapshot.session.generation else {
            throw NativeMediaValidationError.invalidRequestIdentity
        }
        guard snapshot.nowUptime.isFinite else {
            throw NativeMediaValidationError.invalidTimeout
        }
        guard snapshot.session.generation != 0,
              snapshot.session.state.satisfies(.commandReady) else {
            throw NativeMediaValidationError.sessionNotReady
        }

        // The newest page cursors are available in normal camera mode. An
        // older cursor is an explicit playback operation and must be fenced
        // by a fresh status frame from this exact session and generation.
        // Dry-run still builds the request for inspection without requiring
        // an unproven transition.
        if request.action == .list, request.execute,
           request.cursor != Pocket3MediaListRequest.newestSD,
           request.cursor != Pocket3MediaListRequest.newestInternal {
            guard let mediaSession = snapshot.mediaSession,
                  mediaSession.sessionID == request.expectedSessionID,
                  mediaSession.peripheralID == request.peripheralID,
                  mediaSession.generation == request.generation,
                  mediaSession.isFresh(nowUptime: snapshot.nowUptime),
                  mediaSession.state == .playback else {
                throw NativeMediaValidationError.playbackRequired
            }
        }

        if request.action == .range {
            return try await runRange(request, snapshot: snapshot)
        }

        let collector: NativeMediaListObservationCollector?
        if request.action == .list {
            let identity = try Pocket3MediaSessionIdentity(
                sessionID: request.expectedSessionID,
                generation: request.generation,
                peripheralID: request.peripheralID)
            collector = try NativeMediaListObservationCollector(
                identity: identity, counter: request.counter,
                cursor: request.cursor, maximumBytes: request.maximumBytes,
                maximumChunkCount: request.maximumChunkCount)
        } else {
            collector = nil
        }

        let nativeRequest = try makeRequest(request, collector: collector)
        guard request.execute else {
            return result(request: request, nativeRequest: nativeRequest,
                          transaction: nil, collector: collector,
                          routeStatus: snapshot.routeStatus,
                          phase: .dryRun, failureCode: nil)
        }
        guard snapshot.routeAllowed else {
            return result(request: request, nativeRequest: nativeRequest,
                          transaction: nil, collector: collector,
                          routeStatus: snapshot.routeStatus,
                          phase: .routeRejected,
                          failureCode: "native_media_route_invalid")
        }
        guard let executor else {
            return result(request: request, nativeRequest: nativeRequest,
                          transaction: nil, collector: collector,
                          routeStatus: snapshot.routeStatus,
                          phase: .executorUnavailable,
                          failureCode: "native_media_executor_unavailable")
        }

        do {
            // Exactly one invocation. No retry or trigger fallback is hidden
            // here; a caller must start a new, explicitly identified attempt.
            let transaction = try await executor.execute(nativeRequest,
                readiness: snapshot.session)
            return result(request: request, nativeRequest: nativeRequest,
                          transaction: transaction, collector: collector,
                          routeStatus: snapshot.routeStatus,
                          phase: phase(for: transaction, collector: collector,
                                       action: request.action),
                          failureCode: failureCode(for: transaction,
                                                   collector: collector))
        } catch is CancellationError {
            collector?.cancel()
            return result(request: request, nativeRequest: nativeRequest,
                          transaction: partial(nativeRequest, end: .cancelled,
                                               failureCode: "cancelled"),
                          collector: collector,
                          routeStatus: snapshot.routeStatus, phase: .cancelled,
                          failureCode: "cancelled")
        } catch let error as NativeCommandTransactionError {
            collector?.cancel()
            let end: NativeCommandTransactionEnd = error == .staleGeneration
                ? .generationChanged : .failed
            let code = mediaFailureCode(error)
            return result(request: request, nativeRequest: nativeRequest,
                          transaction: partial(nativeRequest, end: end,
                                               failureCode: code),
                          collector: collector,
                          routeStatus: snapshot.routeStatus,
                          phase: end == .generationChanged
                              ? .generationChanged : .failed,
                          failureCode: code)
        } catch {
            collector?.cancel()
            let code = "native_media_executor_failed"
            return result(request: request, nativeRequest: nativeRequest,
                          transaction: partial(nativeRequest, end: .failed,
                                               failureCode: code),
                          collector: collector,
                          routeStatus: snapshot.routeStatus, phase: .failed,
                          failureCode: code)
        }
    }

    private func runRange(
        _ request: NativeMediaValidationRequest,
        snapshot: NativeMediaValidationSnapshot
    ) async throws -> NativeMediaValidationResult {
        guard let rangeRequest = request.rangeRequest,
              rangeRequest.isCurrent(for: snapshot.session) else {
            throw NativeMediaValidationError.invalidRequestIdentity
        }
        guard request.execute else {
            return NativeMediaValidationResult(
                action: request.action, executeRequested: false,
                routeStatus: snapshot.routeStatus, request: nil,
                transaction: nil, list: nil, mediaIndex: nil,
                range: NativeMediaRangeValidationResult(
                    request: rangeRequest, data: nil), phase: .dryRun,
                requested: true, submitted: false, acknowledged: false,
                observed: false, completed: false, failureCode: nil)
        }
        guard snapshot.rangeRouteAllowed else {
            return NativeMediaValidationResult(
                action: request.action, executeRequested: true,
                routeStatus: snapshot.routeStatus, request: nil,
                transaction: nil, list: nil, mediaIndex: nil,
                range: NativeMediaRangeValidationResult(
                    request: rangeRequest, data: nil), phase: .routeRejected,
                requested: true, submitted: false, acknowledged: false,
                observed: false, completed: false,
                failureCode: "native_media_http_route_invalid")
        }
        guard let rangeFetcher else {
            return NativeMediaValidationResult(
                action: request.action, executeRequested: true,
                routeStatus: snapshot.routeStatus, request: nil,
                transaction: nil, list: nil, mediaIndex: nil,
                range: NativeMediaRangeValidationResult(
                    request: rangeRequest, data: nil), phase: .fetcherUnavailable,
                requested: true, submitted: false, acknowledged: false,
                observed: false, completed: false,
                failureCode: "native_media_range_fetcher_unavailable")
        }
        do {
            let data = try await rangeFetcher.fetch(
                rangeRequest, readiness: snapshot.session,
                timeout: request.timeout)
            guard UInt64(data.count) <= rangeRequest.range.length else {
                return NativeMediaValidationResult(
                    action: request.action, executeRequested: true,
                    routeStatus: snapshot.routeStatus, request: nil,
                    transaction: nil, list: nil, mediaIndex: nil,
                    range: NativeMediaRangeValidationResult(
                        request: rangeRequest, data: nil), phase: .failed,
                    requested: true, submitted: true, acknowledged: false,
                    observed: false, completed: false,
                    failureCode: "native_media_range_response_too_large")
            }
            return NativeMediaValidationResult(
                action: request.action, executeRequested: true,
                routeStatus: snapshot.routeStatus, request: nil,
                transaction: nil, list: nil, mediaIndex: nil,
                range: NativeMediaRangeValidationResult(
                    request: rangeRequest, data: data), phase: .completed,
                requested: true, submitted: true, acknowledged: false,
                observed: true, completed: true, failureCode: nil)
        } catch is CancellationError {
            return NativeMediaValidationResult(
                action: request.action, executeRequested: true,
                routeStatus: snapshot.routeStatus, request: nil,
                transaction: nil, list: nil, mediaIndex: nil,
                range: NativeMediaRangeValidationResult(
                    request: rangeRequest, data: nil), phase: .cancelled,
                requested: true, submitted: true, acknowledged: false,
                observed: false, completed: false, failureCode: "cancelled")
        } catch let error as NativeMediaHTTPRangeFetcherError {
            return NativeMediaValidationResult(
                action: request.action, executeRequested: true,
                routeStatus: snapshot.routeStatus, request: nil,
                transaction: nil, list: nil, mediaIndex: nil,
                range: NativeMediaRangeValidationResult(
                    request: rangeRequest, data: nil), phase: .failed,
                requested: true, submitted: true, acknowledged: false,
                observed: false, completed: false,
                failureCode: error.failureCode)
        } catch {
            return NativeMediaValidationResult(
                action: request.action, executeRequested: true,
                routeStatus: snapshot.routeStatus, request: nil,
                transaction: nil, list: nil, mediaIndex: nil,
                range: NativeMediaRangeValidationResult(
                    request: rangeRequest, data: nil), phase: .failed,
                requested: true, submitted: true, acknowledged: false,
                observed: false, completed: false,
                failureCode: "native_media_range_fetcher_failed")
        }
    }

    private func makeRequest(
        _ request: NativeMediaValidationRequest,
        collector: NativeMediaListObservationCollector?
    ) throws -> NativeCommandTransactionRequest {
        let frame: NativeCommandFrame
        switch request.action {
        case .playbackEnter:
            let command = try Pocket3MediaPlaybackCommand(
                sessionID: request.expectedSessionID,
                peripheralID: request.peripheralID,
                generation: request.generation, operation: .enter)
            frame = command.nativeFrame(sequence: 0)
        case .playbackExit:
            let command = try Pocket3MediaPlaybackCommand(
                sessionID: request.expectedSessionID,
                peripheralID: request.peripheralID,
                generation: request.generation, operation: .exit)
            frame = command.nativeFrame(sequence: 0)
        case .presence:
            let command = try Pocket3MediaPresenceHold(
                sessionID: request.expectedSessionID,
                peripheralID: request.peripheralID,
                generation: request.generation,
                interval: request.presenceInterval)
            frame = command.nativeFrame(sequence: 0)
        case .list:
            let command = try Pocket3MediaListRequest(
                sessionID: request.expectedSessionID,
                peripheralID: request.peripheralID,
                generation: request.generation,
                counter: request.counter, cursor: request.cursor)
            frame = command.nativeFrame(sequence: 0)
        case .range:
            throw NativeMediaValidationError.invalidAction
        }
        if let collector {
            return try NativeCommandTransactionRequest(
                command: request.action == .list ? .mediaList
                    : command(for: request.action),
                generation: request.generation,
                sessionID: request.expectedSessionID, frame: frame,
                timeout: request.timeout) { [collector] frame in
                    collector.observe(frame)
                }
        }
        if [.playbackEnter, .playbackExit].contains(request.action) {
            // 02/0C is ACKed separately from the camera's unsolicited 02/80
            // status. Only the latter is a terminal readback candidate;
            // every other frame leaves the transaction at ACK-only evidence.
            return try NativeCommandTransactionRequest(
                command: command(for: request.action),
                generation: request.generation,
                sessionID: request.expectedSessionID, frame: frame,
                timeout: request.timeout) { frame in
                    guard frame.source & 0x1f == 0x01,
                          frame.destination & 0x1f == 0x02,
                          frame.commandSet == 0x02,
                          frame.commandID == 0x80,
                          let readback = Pocket3MediaSessionReadback.decode(
                              frame: frame) else { return nil }
                    return readback.raw
                }
        }
        return try NativeCommandTransactionRequest(
            command: command(for: request.action),
            generation: request.generation,
            sessionID: request.expectedSessionID, frame: frame,
            timeout: request.timeout)
    }

    private func command(for action: NativeMediaValidationOperation)
        -> NativeCameraSessionCommand {
        switch action {
        case .playbackEnter, .playbackExit: .mediaPlayback
        case .presence: .mediaPresence
        case .list: .mediaList
        case .range: .mediaList
        }
    }

    private func result(
        request: NativeMediaValidationRequest,
        nativeRequest: NativeCommandTransactionRequest,
        transaction: NativeCommandTransactionResult?,
        collector: NativeMediaListObservationCollector?,
        routeStatus: Pocket3DatalinkRouteStatus,
        phase: NativeMediaValidationPhase,
        failureCode: String?
    ) -> NativeMediaValidationResult {
        let listEvidence = collector.map {
            NativeMediaListValidationEvidence($0.snapshot())
        }
        let pack = collector?.pack()
        let index = pack.flatMap { try? Pocket3MediaIndex(pack: $0) }
        let observed = transaction?.observed == true
        let acknowledged = transaction?.acknowledged == true
        let submitted = transaction?.submitted == true
        let completed: Bool
        switch request.action {
        case .list:
            // Some Pocket firmware streams 00/27 start/data/end without a
            // separate 00/26 ACK. The terminal chunk is the list's observed
            // completion evidence in that case; do not turn the transport's
            // ACK wait timeout into a false list failure.
            completed = transaction?.observed == true && index != nil
        case .playbackEnter, .playbackExit:
            completed = playbackTerminalState(
                action: request.action, transaction: transaction)
        case .presence:
            completed = transaction?.completed == true
        case .range: completed = false
        }
        let effectiveFailure: String?
        if failureCode != nil {
            effectiveFailure = failureCode
        } else if request.action == .list && !completed, transaction != nil {
            effectiveFailure = transaction?.failureCode
                ?? "native_media_list_terminal_readback_missing"
        } else if [.playbackEnter, .playbackExit].contains(request.action),
                  transaction != nil, !completed {
            effectiveFailure = transaction?.failureCode
                ?? "native_media_playback_readback_missing"
        } else {
            effectiveFailure = nil
        }
        return NativeMediaValidationResult(
            action: request.action, executeRequested: request.execute,
            routeStatus: routeStatus,
            request: NativeMediaValidationRequestEvidence(nativeRequest,
                peripheralID: request.peripheralID),
            transaction: transaction, list: listEvidence,
            mediaIndex: index, range: nil, phase: phase,
            requested: true, submitted: submitted,
            acknowledged: acknowledged, observed: observed,
            completed: completed, failureCode: effectiveFailure)
    }

    private func phase(
        for transaction: NativeCommandTransactionResult,
        collector: NativeMediaListObservationCollector?,
        action: NativeMediaValidationOperation
    ) -> NativeMediaValidationPhase {
        switch transaction.end {
        case .cancelled: return .cancelled
        case .generationChanged: return .generationChanged
        case .timedOut:
            if collector?.pack() != nil && transaction.observed { return .completed }
            // An ACK without its 02/80 status remains explicitly pending;
            // callers may request a fresh readback at their own boundary.
            if [.playbackEnter, .playbackExit].contains(action),
               transaction.acknowledged { return .awaitingReadback }
            return .timedOut
        case .rejected, .failed: return .failed
        case .acknowledged:
            if collector != nil { return .awaitingReadback }
            return [.playbackEnter, .playbackExit].contains(action)
                ? .awaitingReadback : .completed
        case .observed:
            if [.playbackEnter, .playbackExit].contains(action) {
                return playbackTerminalState(action: action,
                    transaction: transaction) ? .completed : .awaitingReadback
            }
            return collector?.pack() == nil ? .failed : .completed
        }
    }

    private func playbackTerminalState(
        action: NativeMediaValidationOperation,
        transaction: NativeCommandTransactionResult?
    ) -> Bool {
        guard let transaction,
              transaction.acknowledged,
              transaction.observed,
              let payload = transaction.observedPayload,
              let readback = Pocket3MediaSessionReadback.decode(payload),
              let observedUptime = transaction.observedUptime else {
            return false
        }
        // A frame queued before this command is not proof that the command
        // changed the camera. The transaction owner supplies host receive
        // times for this freshness fence.
        if let submittedUptime = transaction.submittedUptime,
           !observedUptime.isFinite || observedUptime <= submittedUptime {
            return false
        }
        guard observedUptime.isFinite, observedUptime >= 0 else { return false }
        switch action {
        case .playbackEnter: return readback.state == .playback
        case .playbackExit: return readback.state == .normal
        default: return false
        }
    }

    private func failureCode(
        for transaction: NativeCommandTransactionResult,
        collector: NativeMediaListObservationCollector?
    ) -> String? {
        if let failureCode = transaction.failureCode {
            if collector?.pack() != nil, transaction.observed,
               transaction.end == .timedOut {
                return nil
            }
            return failureCode
        }
        if collector != nil, collector?.pack() == nil,
           transaction.end == .observed {
            return "native_media_list_decode_failed"
        }
        return nil
    }

    private func partial(_ request: NativeCommandTransactionRequest,
                         end: NativeCommandTransactionEnd,
                         failureCode: String)
        -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: request.generation,
            sessionID: request.sessionID, end: end)
        result.failureCode = failureCode
        return result
    }

    private func mediaFailureCode(_ error: NativeCommandTransactionError)
        -> String {
        switch error {
        case .invalidPayload: "native_media_invalid_payload"
        case .invalidTimeout: "native_media_invalid_timeout"
        case .commandNotReady: "native_media_command_not_ready"
        case .staleGeneration: "native_media_generation_changed"
        case .datalinkUnavailable: "native_media_datalink_unavailable"
        case .nativeBusy: "native_media_busy"
        }
    }
}

public typealias Pocket3NativeMediaValidationRequest = NativeMediaValidationRequest
public typealias Pocket3NativeMediaValidationResult = NativeMediaValidationResult
public typealias Pocket3NativeMediaValidationService = NativeMediaValidationService
public typealias Pocket3NativeMediaHTTPRangeFetcherAdapter = NativeMediaHTTPRangeFetcherAdapter
