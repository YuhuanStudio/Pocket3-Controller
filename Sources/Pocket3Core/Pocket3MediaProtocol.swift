import Foundation

/// Errors raised while validating media protocol values. The media layer is
/// intentionally transport independent: none of these operations opens a
/// socket, starts Bluetooth, joins Wi-Fi, or submits a frame.
public enum Pocket3MediaProtocolError: Error, Codable, Sendable, Equatable {
    case invalidSession
    case invalidGeneration
    case invalidCounter
    case invalidHandle
    case invalidStorage
    case invalidPath
    case invalidRange
    case invalidPayload
    case wrongCommand
    case sessionMismatch
    case generationMismatch
    case counterMismatch
    case tooManyChunks
    case responseTooLarge
    case terminalState
    case invalidClock
}

/// Exact camera identity carried by every media operation. `peripheralID` is
/// optional for callers that only have a native session token, but when it is
/// present it is part of the equality fence as well.
public struct Pocket3MediaSessionIdentity: Codable, Sendable, Equatable,
    Hashable {
    public let sessionID: UUID
    public let peripheralID: UUID?
    public let generation: UInt64

    public init(sessionID: UUID, generation: UInt64,
                peripheralID: UUID? = nil) throws {
        guard generation > 0 else {
            throw Pocket3MediaProtocolError.invalidGeneration
        }
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.generation = generation
    }

    public init(status: NativeCameraSessionStatus) throws {
        guard let sessionID = status.sessionID else {
            throw Pocket3MediaProtocolError.invalidSession
        }
        try self.init(sessionID: sessionID, generation: status.generation,
                      peripheralID: status.peerID)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sessionID: values.decode(UUID.self, forKey: .sessionID),
                      generation: values.decode(UInt64.self, forKey: .generation),
                      peripheralID: values.decodeIfPresent(UUID.self,
                                                          forKey: .peripheralID))
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, peripheralID, generation
    }

    public func matches(sessionID: UUID, generation: UInt64,
                        peripheralID: UUID? = nil) -> Bool {
        self.sessionID == sessionID && self.generation == generation &&
            (self.peripheralID == nil || self.peripheralID == peripheralID)
    }

    public func matches(_ status: NativeCameraSessionStatus) -> Bool {
        guard let sessionID = status.sessionID else { return false }
        return matches(sessionID: sessionID, generation: status.generation,
                       peripheralID: status.peerID)
    }
}

// MARK: - Playback and presence

public enum Pocket3MediaPlaybackOperation: String, Codable, Sendable,
    Equatable, CaseIterable {
    case enter
    case exit
}

/// Pure encoder for `02/0C`: enter `01 01 00 01`, exit `01 01 00 00`.
public struct Pocket3MediaPlaybackCommand: Codable, Sendable, Equatable {
    public static let commandSet: UInt8 = 0x02
    public static let commandID: UInt8 = 0x0C
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x01
    public static let requestFlags: UInt8 = 0x40

    public let identity: Pocket3MediaSessionIdentity
    public let operation: Pocket3MediaPlaybackOperation

    public init(identity: Pocket3MediaSessionIdentity,
                operation: Pocket3MediaPlaybackOperation) {
        self.identity = identity
        self.operation = operation
    }

    public init(sessionID: UUID, peripheralID: UUID? = nil,
                generation: UInt64,
                operation: Pocket3MediaPlaybackOperation) throws {
        try self.init(identity: Pocket3MediaSessionIdentity(
            sessionID: sessionID, generation: generation,
            peripheralID: peripheralID), operation: operation)
    }

    public var command: NativeCameraSessionCommand { .mediaPlayback }

    public var payload: Data {
        operation == .enter
            ? Data([0x01, 0x01, 0x00, 0x01])
            : Data([0x01, 0x01, 0x00, 0x00])
    }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination,
                  sequence: sequence, flags: Self.requestFlags,
                  commandSet: Self.commandSet, commandID: Self.commandID,
                  payload: payload)
    }

    public func nativeFrame(sequence: UInt16) -> NativeCommandFrame {
        NativeCommandFrame(frame: frame(sequence: sequence))
    }
}

public typealias Pocket3MediaPlaybackRequest = Pocket3MediaPlaybackCommand
public typealias Pocket3MediaPlaybackAction = Pocket3MediaPlaybackOperation

extension Pocket3MediaPlaybackCommand {
    public func isCurrent(for status: NativeCameraSessionStatus) -> Bool {
        identity.matches(status)
    }
}

/// The app-presence payload that holds a native playback session. This value
/// only describes a permitted cadence; it does not schedule or send a
/// keepalive by itself.
public struct Pocket3MediaPresenceHold: Codable, Sendable, Equatable {
    public static let commandSet: UInt8 = 0x00
    public static let commandID: UInt8 = 0x88
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x28
    public static let requestFlags: UInt8 = 0x40
    public static let payload = Data([
        0x17, 0x00, 0x46, 0x23, 0x7C, 0x41, 0x50, 0x50,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x02
    ])
    public static let defaultInterval: TimeInterval = 1

    public let identity: Pocket3MediaSessionIdentity
    public let interval: TimeInterval

    public init(identity: Pocket3MediaSessionIdentity,
                interval: TimeInterval = Self.defaultInterval) throws {
        guard interval.isFinite, interval >= 0.25, interval <= 5 else {
            throw Pocket3MediaProtocolError.invalidClock
        }
        self.identity = identity
        self.interval = interval
    }

    public init(sessionID: UUID, peripheralID: UUID? = nil,
                generation: UInt64,
                interval: TimeInterval = Self.defaultInterval) throws {
        try self.init(identity: Pocket3MediaSessionIdentity(
            sessionID: sessionID, generation: generation,
            peripheralID: peripheralID), interval: interval)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identity: values.decode(Pocket3MediaSessionIdentity.self,
                                              forKey: .identity),
                      interval: values.decode(TimeInterval.self,
                                              forKey: .interval))
    }

    private enum CodingKeys: String, CodingKey { case identity, interval }

    public var command: NativeCameraSessionCommand { .mediaPresence }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination,
                  sequence: sequence, flags: Self.requestFlags,
                  commandSet: Self.commandSet, commandID: Self.commandID,
                  payload: Self.payload)
    }

    public func nativeFrame(sequence: UInt16) -> NativeCommandFrame {
        NativeCommandFrame(frame: frame(sequence: sequence))
    }

    public func isCurrent(for status: NativeCameraSessionStatus) -> Bool {
        identity.matches(status)
    }
}

public typealias Pocket3MediaPresenceCommand = Pocket3MediaPresenceHold

// MARK: - Media list request and cursor

/// One bounded `00/26` media-list page request. Counter is the one-byte value
/// at payload offset 4; cursor is the little-endian u32 at offsets 10...13.
public struct Pocket3MediaListRequest: Codable, Sendable, Equatable {
    public static let commandSet: UInt8 = 0x00
    public static let commandID: UInt8 = 0x26
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x01
    public static let requestFlags: UInt8 = 0x40
    public static let pageSize = 45
    public static let newestSD: UInt32 = 0x0000_0001
    public static let newestInternal: UInt32 = 0x4000_0001
    public static let internalBit: UInt32 = 0x4000_0000

    private static let template = Data([
        0x4A, 0x00, 0x2A, 0x10,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x2D, 0x00, 0x0D, 0x01, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00
    ])
    public static let triggerPayload = Data([
        0x4A, 0x04, 0x0E, 0x10,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00
    ])

    public static func listPayload(counter: UInt8, cursor: UInt32) -> Data {
        var value = Self.template
        value[4] = counter
        value[10] = UInt8(cursor & 0xFF)
        value[11] = UInt8((cursor >> 8) & 0xFF)
        value[12] = UInt8((cursor >> 16) & 0xFF)
        value[13] = UInt8((cursor >> 24) & 0xFF)
        return value
    }

    public let identity: Pocket3MediaSessionIdentity
    public let counter: UInt8
    public let cursor: UInt32

    public init(identity: Pocket3MediaSessionIdentity, counter: UInt8,
                cursor: UInt32) throws {
        guard counter != 0 else {
            throw Pocket3MediaProtocolError.invalidCounter
        }
        self.identity = identity
        self.counter = counter
        self.cursor = cursor
    }

    public init(sessionID: UUID, peripheralID: UUID? = nil,
                generation: UInt64, counter: UInt8, cursor: UInt32) throws {
        try self.init(identity: Pocket3MediaSessionIdentity(
            sessionID: sessionID, generation: generation,
            peripheralID: peripheralID), counter: counter, cursor: cursor)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identity: values.decode(Pocket3MediaSessionIdentity.self,
                                              forKey: .identity),
                      counter: values.decode(UInt8.self, forKey: .counter),
                      cursor: values.decode(UInt32.self, forKey: .cursor))
    }

    private enum CodingKeys: String, CodingKey { case identity, counter, cursor }

    public var command: NativeCameraSessionCommand { .mediaList }

    public var payload: Data {
        Self.listPayload(counter: counter, cursor: cursor)
    }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination,
                  sequence: sequence, flags: Self.requestFlags,
                  commandSet: Self.commandSet, commandID: Self.commandID,
                  payload: payload)
    }

    public func nativeFrame(sequence: UInt16) -> NativeCommandFrame {
        NativeCommandFrame(frame: frame(sequence: sequence))
    }
}

/// The separate `4A 04 0E 10` trigger used between media-list requests.
public struct Pocket3MediaListTrigger: Codable, Sendable, Equatable {
    public let identity: Pocket3MediaSessionIdentity

    public init(identity: Pocket3MediaSessionIdentity) {
        self.identity = identity
    }

    public init(sessionID: UUID, peripheralID: UUID? = nil,
                generation: UInt64) throws {
        try self.init(identity: Pocket3MediaSessionIdentity(
            sessionID: sessionID, generation: generation,
            peripheralID: peripheralID))
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(identity: try values.decode(Pocket3MediaSessionIdentity.self,
                                              forKey: .identity))
    }

    private enum CodingKeys: String, CodingKey { case identity }

    public var command: NativeCameraSessionCommand { .mediaList }
    public var payload: Data { Pocket3MediaListRequest.triggerPayload }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Pocket3MediaListRequest.source,
                  destination: Pocket3MediaListRequest.destination,
                  sequence: sequence, flags: Pocket3MediaListRequest.requestFlags,
                  commandSet: Pocket3MediaListRequest.commandSet,
                  commandID: Pocket3MediaListRequest.commandID,
                  payload: payload)
    }

    public func nativeFrame(sequence: UInt16) -> NativeCommandFrame {
        NativeCommandFrame(frame: frame(sequence: sequence))
    }
}

public enum Pocket3MediaListCursor {
    public static let newestSD = Pocket3MediaListRequest.newestSD
    public static let newestInternal = Pocket3MediaListRequest.newestInternal
    public static let videoHandleBase = Pocket3MediaListRequest.internalBit

    public static func oldestVideoHandle(_ handles: [UInt32]) -> UInt32? {
        handles.filter { $0 >= videoHandleBase }.min()
    }

    public static func nextCursor(handles: [UInt32], current: UInt32)
        -> UInt32? {
        handles.filter { $0 >= videoHandleBase && $0 < current }.min()
    }

    public static func hasOlderPage(recordCount: Int, cursor: UInt32?) -> Bool {
        guard let cursor, cursor > 0 else { return false }
        return recordCount >= Pocket3MediaListRequest.pageSize
    }
}

extension Pocket3MediaListRequest {
    public func isCurrent(for status: NativeCameraSessionStatus) -> Bool {
        identity.matches(status)
    }
}

extension Pocket3MediaListTrigger {
    public func isCurrent(for status: NativeCameraSessionStatus) -> Bool {
        identity.matches(status)
    }
}

// MARK: - `00/27` chunks and bounded reassembly

public enum Pocket3MediaListChunkSubtype: Codable, Sendable, Equatable {
    case data
    case end
    case unknown(raw: UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0x01: self = .data
        case 0x03: self = .end
        default: self = .unknown(raw: rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .data: 0x01
        case .end: 0x03
        case .unknown(let raw): raw
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

/// One `00/27` payload. The first ten bytes are retained exactly, including
/// fields whose semantics are not established; data starts at offset 10.
public struct Pocket3MediaListChunk: Codable, Sendable, Equatable {
    public static let headerLength = 10
    public static let maximumPayloadLength = DUMLCodec.maximumPayloadLength

    public let raw: Data
    public let headerRaw: Data
    public let subtypeRaw: UInt8
    public let counterRaw: UInt8
    public let body: Data

    public init(payload: Data) throws {
        guard payload.count >= Self.headerLength,
              payload.count <= Self.maximumPayloadLength,
              payload[0] == 0x4A else {
            throw Pocket3MediaProtocolError.invalidPayload
        }
        raw = payload
        headerRaw = Data(payload.prefix(Self.headerLength))
        subtypeRaw = payload[1]
        counterRaw = payload[4]
        body = Data(payload.dropFirst(Self.headerLength))
    }

    public init(payload: [UInt8]) throws { try self.init(payload: Data(payload)) }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(payload: values.decode(Data.self, forKey: .raw))
    }

    private enum CodingKeys: String, CodingKey { case raw }

    public static func decode(_ payload: Data) -> Self? {
        try? Self(payload: payload)
    }

    public static func parse(_ payload: Data) -> Self? { decode(payload) }

    public var subtype: Pocket3MediaListChunkSubtype {
        Pocket3MediaListChunkSubtype(rawValue: subtypeRaw)
    }

    public var isData: Bool { subtypeRaw == 0x01 }
    public var isEnd: Bool { subtypeRaw == 0x03 }
    public var isUnknown: Bool { subtype.isUnknown }
    public var unknownRaw: Data? { isUnknown ? raw : nil }

    /// A validated frame route is required before this payload is admitted;
    /// the media payload itself intentionally retains unknown sender metadata.
    public static func decode(frame: DUMLFrame) -> Self? {
        guard frame.commandSet == 0x00, frame.commandID == 0x27 else {
            return nil
        }
        return decode(frame.payload)
    }
}

public struct Pocket3MediaListChunkObservation: Codable, Sendable,
    Equatable {
    public let identity: Pocket3MediaSessionIdentity
    public let receivedUptime: TimeInterval
    public let chunk: Pocket3MediaListChunk

    public init(identity: Pocket3MediaSessionIdentity,
                receivedUptime: TimeInterval,
                chunk: Pocket3MediaListChunk) throws {
        guard receivedUptime.isFinite, receivedUptime >= 0 else {
            throw Pocket3MediaProtocolError.invalidClock
        }
        self.identity = identity
        self.receivedUptime = receivedUptime
        self.chunk = chunk
    }

    public init(sessionID: UUID, peripheralID: UUID? = nil,
                generation: UInt64, receivedUptime: TimeInterval,
                chunk: Pocket3MediaListChunk) throws {
        try self.init(identity: Pocket3MediaSessionIdentity(
            sessionID: sessionID, generation: generation,
            peripheralID: peripheralID), receivedUptime: receivedUptime,
            chunk: chunk)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: values.decode(Pocket3MediaSessionIdentity.self,
                                    forKey: .identity),
            receivedUptime: values.decode(TimeInterval.self,
                                          forKey: .receivedUptime),
            chunk: values.decode(Pocket3MediaListChunk.self, forKey: .chunk))
    }

    private enum CodingKeys: String, CodingKey {
        case identity, receivedUptime, chunk
    }
}

public enum Pocket3MediaListReassemblyPhase: String, Codable, Sendable,
    Equatable, CaseIterable {
    case collecting
    case completed
    case cancelled
    case tornDown
    case failed
}

public enum Pocket3MediaListReassemblyFailure: String, Codable, Sendable,
    Equatable, CaseIterable {
    case invalidClock
    case sessionMismatch
    case generationMismatch
    case counterMismatch
    case tooManyChunks
    case responseTooLarge
    case cancelled
    case tornDown
    case terminalState
    case malformedChunk
}

/// Bounded arrival-order reassembly for a single exact session/generation and
/// list counter. The camera's chunk stream has no independently established
/// record ordering field, so data is concatenated in arrival order. Unknown
/// subtypes remain in `unknownChunks` and never become list bytes.
public struct Pocket3MediaListReassembler: Codable, Sendable, Equatable {
    public static let maximumAssembledBytes = 8 * 1024 * 1024
    public static let maximumChunks = 4096

    public let identity: Pocket3MediaSessionIdentity
    public let counter: UInt8
    public let cursor: UInt32
    public let maximumBytes: Int
    public let maximumChunkCount: Int
    public private(set) var phase: Pocket3MediaListReassemblyPhase = .collecting
    public private(set) var assembledData = Data()
    public private(set) var acceptedChunkCount = 0
    public private(set) var rejectedChunkCount = 0
    public private(set) var unknownChunks: [Pocket3MediaListChunk] = []
    public private(set) var endChunk: Pocket3MediaListChunk?
    public private(set) var failure: Pocket3MediaListReassemblyFailure?
    public private(set) var discardedByteCount = 0

    public init(identity: Pocket3MediaSessionIdentity, counter: UInt8,
                cursor: UInt32 = 0,
                maximumBytes: Int = Self.maximumAssembledBytes,
                maximumChunkCount: Int = Self.maximumChunks) throws {
        guard counter != 0 else {
            throw Pocket3MediaProtocolError.invalidCounter
        }
        guard maximumBytes > 0, maximumBytes <= Self.maximumAssembledBytes,
              maximumChunkCount > 0,
              maximumChunkCount <= Self.maximumChunks else {
            throw Pocket3MediaProtocolError.responseTooLarge
        }
        self.identity = identity
        self.counter = counter
        self.cursor = cursor
        self.maximumBytes = maximumBytes
        self.maximumChunkCount = maximumChunkCount
    }

    public init(sessionID: UUID, peripheralID: UUID? = nil,
                generation: UInt64, counter: UInt8, cursor: UInt32 = 0,
                maximumBytes: Int = Self.maximumAssembledBytes,
                maximumChunkCount: Int = Self.maximumChunks) throws {
        try self.init(identity: Pocket3MediaSessionIdentity(
            sessionID: sessionID, generation: generation,
            peripheralID: peripheralID), counter: counter, cursor: cursor,
            maximumBytes: maximumBytes, maximumChunkCount: maximumChunkCount)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let identity = try values.decode(Pocket3MediaSessionIdentity.self,
                                          forKey: .identity)
        let counter = try values.decode(UInt8.self, forKey: .counter)
        let cursor = try values.decode(UInt32.self, forKey: .cursor)
        let maximumBytes = try values.decode(Int.self, forKey: .maximumBytes)
        let maximumChunkCount = try values.decode(Int.self,
                                                  forKey: .maximumChunkCount)
        var state = try Self(identity: identity, counter: counter,
                             cursor: cursor, maximumBytes: maximumBytes,
                             maximumChunkCount: maximumChunkCount)
        let phase = try values.decode(Pocket3MediaListReassemblyPhase.self,
                                      forKey: .phase)
        let assembledData = try values.decode(Data.self, forKey: .assembledData)
        let acceptedChunkCount = try values.decode(Int.self,
                                                   forKey: .acceptedChunkCount)
        let rejectedChunkCount = try values.decode(Int.self,
                                                   forKey: .rejectedChunkCount)
        let unknownChunks = try values.decode([Pocket3MediaListChunk].self,
                                              forKey: .unknownChunks)
        let endChunk = try values.decodeIfPresent(Pocket3MediaListChunk.self,
                                                  forKey: .endChunk)
        let failure = try values.decodeIfPresent(
            Pocket3MediaListReassemblyFailure.self, forKey: .failure)
        let discardedByteCount = try values.decode(Int.self,
                                                   forKey: .discardedByteCount)
        guard acceptedChunkCount >= 0,
              acceptedChunkCount <= maximumChunkCount,
              rejectedChunkCount >= 0, discardedByteCount >= 0,
              unknownChunks.count <= maximumChunkCount,
              assembledData.count <= maximumBytes else {
            throw Pocket3MediaProtocolError.responseTooLarge
        }
        state.phase = phase
        state.assembledData = assembledData
        state.acceptedChunkCount = acceptedChunkCount
        state.rejectedChunkCount = rejectedChunkCount
        state.unknownChunks = unknownChunks
        state.endChunk = endChunk
        state.failure = failure
        state.discardedByteCount = discardedByteCount
        self = state
    }

    private enum CodingKeys: String, CodingKey {
        case identity, counter, cursor, maximumBytes, maximumChunkCount
        case phase, assembledData, acceptedChunkCount, rejectedChunkCount
        case unknownChunks, endChunk, failure, discardedByteCount
    }

    public var isComplete: Bool { phase == .completed }
    public var isTerminal: Bool {
        phase == .completed || phase == .cancelled || phase == .tornDown ||
            phase == .failed
    }
    public var unknownRaw: [Data] { unknownChunks.map(\.raw) }

    public var data: Data { assembledData }
    public var chunkCount: Int { acceptedChunkCount }

    /// Admits one already decoded chunk, checking the exact observation
    /// identity and list counter before mutating reassembly state.
    @discardableResult
    public mutating func ingest(
        _ observation: Pocket3MediaListChunkObservation
    ) throws -> Bool {
        guard phase == .collecting else {
            failure = .terminalState
            rejectedChunkCount += 1
            throw Pocket3MediaProtocolError.terminalState
        }
        guard observation.receivedUptime.isFinite,
              observation.receivedUptime >= 0 else {
            failure = .invalidClock
            phase = .failed
            throw Pocket3MediaProtocolError.invalidClock
        }
        guard identity.matches(sessionID: observation.identity.sessionID,
                               generation: observation.identity.generation,
                               peripheralID: observation.identity.peripheralID) else {
            failure = observation.identity.sessionID != identity.sessionID
                ? .sessionMismatch : .generationMismatch
            rejectedChunkCount += 1
            throw observation.identity.sessionID != identity.sessionID
                ? Pocket3MediaProtocolError.sessionMismatch
                : Pocket3MediaProtocolError.generationMismatch
        }
        guard observation.chunk.counterRaw == counter else {
            failure = .counterMismatch
            rejectedChunkCount += 1
            throw Pocket3MediaProtocolError.counterMismatch
        }
        guard acceptedChunkCount < maximumChunkCount else {
            failure = .tooManyChunks
            phase = .failed
            throw Pocket3MediaProtocolError.tooManyChunks
        }

        acceptedChunkCount += 1
        switch observation.chunk.subtype {
        case .data:
            guard assembledData.count + observation.chunk.body.count <= maximumBytes else {
                failure = .responseTooLarge
                phase = .failed
                throw Pocket3MediaProtocolError.responseTooLarge
            }
            assembledData.append(observation.chunk.body)
        case .end:
            endChunk = observation.chunk
            phase = .completed
        case .unknown:
            unknownChunks.append(observation.chunk)
        }
        return true
    }

    @discardableResult
    public mutating func ingest(
        _ chunk: Pocket3MediaListChunk, sessionID: UUID, generation: UInt64,
        peripheralID: UUID? = nil, receivedUptime: TimeInterval
    ) throws -> Bool {
        let observation = try Pocket3MediaListChunkObservation(
            sessionID: sessionID, peripheralID: peripheralID,
            generation: generation, receivedUptime: receivedUptime,
            chunk: chunk)
        return try ingest(observation)
    }

    /// Decode and admit one camera `00/27` frame. Invalid frames are rejected
    /// without any partial byte append.
    @discardableResult
    public mutating func ingest(
        _ frame: DUMLFrame, sessionID: UUID, generation: UInt64,
        peripheralID: UUID? = nil, receivedUptime: TimeInterval
    ) throws -> Bool {
        guard frame.commandSet == 0x00, frame.commandID == 0x27 else {
            failure = .malformedChunk
            rejectedChunkCount += 1
            throw Pocket3MediaProtocolError.wrongCommand
        }
        guard let chunk = try? Pocket3MediaListChunk(payload: frame.payload) else {
            failure = .malformedChunk
            rejectedChunkCount += 1
            throw Pocket3MediaProtocolError.invalidPayload
        }
        return try ingest(chunk, sessionID: sessionID, generation: generation,
                          peripheralID: peripheralID,
                          receivedUptime: receivedUptime)
    }

    /// A non-throwing adapter for event loops that treat a rejected frame as a
    /// normal admission miss. `failure` and the counters retain the reason.
    @discardableResult
    public mutating func ingestPayload(
        _ payload: Data, sessionID: UUID, generation: UInt64,
        peripheralID: UUID? = nil, receivedUptime: TimeInterval
    ) -> Bool {
        guard let chunk = try? Pocket3MediaListChunk(payload: payload) else {
            failure = .malformedChunk
            rejectedChunkCount += 1
            return false
        }
        return (try? ingest(chunk, sessionID: sessionID,
                            generation: generation,
                            peripheralID: peripheralID,
                            receivedUptime: receivedUptime)) ?? false
    }

    public func makePack() throws -> Pocket3MediaListPack {
        guard phase == .completed else {
            throw Pocket3MediaProtocolError.terminalState
        }
        return try Pocket3MediaListPack(identity: identity, counter: counter,
            cursor: cursor, raw: assembledData,
            chunkCount: acceptedChunkCount, unknownChunks: unknownChunks)
    }

    /// Cancellation ends this bounded attempt and preserves already collected
    /// bytes for diagnostics. A caller must create a new assembler to retry.
    public mutating func cancel() {
        guard phase == .collecting else { return }
        phase = .cancelled
        failure = .cancelled
    }

    /// Teardown discards collected media bytes and unknown chunks while
    /// retaining only scalar accounting. Late frames cannot reopen it.
    public mutating func teardown() {
        guard phase != .tornDown else { return }
        discardedByteCount += assembledData.count
        assembledData.removeAll(keepingCapacity: false)
        unknownChunks.removeAll(keepingCapacity: false)
        endChunk = nil
        phase = .tornDown
        failure = .tornDown
    }
}

/// The bounded, still-opaque CompositePack produced by a complete list page.
/// Record TLV semantics are intentionally left for a later evidence-backed
/// layer; every byte and unknown chunk is available to that decoder.
public struct Pocket3MediaListPack: Codable, Sendable, Equatable {
    public let identity: Pocket3MediaSessionIdentity
    public let counter: UInt8
    public let cursor: UInt32
    public let raw: Data
    public let chunkCount: Int
    public let unknownChunks: [Pocket3MediaListChunk]

    public init(identity: Pocket3MediaSessionIdentity, counter: UInt8,
                cursor: UInt32, raw: Data, chunkCount: Int,
                unknownChunks: [Pocket3MediaListChunk] = []) throws {
        guard counter != 0,
              raw.count <= Pocket3MediaListReassembler.maximumAssembledBytes,
              chunkCount > 0,
              chunkCount <= Pocket3MediaListReassembler.maximumChunks,
              unknownChunks.count <= Pocket3MediaListReassembler.maximumChunks else {
            throw Pocket3MediaProtocolError.responseTooLarge
        }
        self.identity = identity
        self.counter = counter
        self.cursor = cursor
        self.raw = raw
        self.chunkCount = chunkCount
        self.unknownChunks = unknownChunks
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: values.decode(Pocket3MediaSessionIdentity.self,
                                    forKey: .identity),
            counter: values.decode(UInt8.self, forKey: .counter),
            cursor: values.decode(UInt32.self, forKey: .cursor),
            raw: values.decode(Data.self, forKey: .raw),
            chunkCount: values.decode(Int.self, forKey: .chunkCount),
            unknownChunks: values.decode([Pocket3MediaListChunk].self,
                                          forKey: .unknownChunks))
    }

    private enum CodingKeys: String, CodingKey {
        case identity, counter, cursor, raw, chunkCount, unknownChunks
    }

    public var declaredRecordCount: UInt32? {
        guard raw.count >= 4 else { return nil }
        return UInt32(raw[0]) | UInt32(raw[1]) << 8 |
            UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
    }

    public var headerCount: UInt32? { declaredRecordCount }
    public var data: Data { raw }

    public var unknownRaw: [Data] { unknownChunks.map(\.raw) }
}

public typealias Pocket3MediaChunkAssembler = Pocket3MediaListReassembler
public typealias Pocket3MediaListChunkAssembler = Pocket3MediaListReassembler
public typealias Pocket3MediaCompositePack = Pocket3MediaListPack
public typealias Pocket3MediaListCommand = Pocket3MediaListRequest

// MARK: - HTTP `/v2` range model

public struct Pocket3MediaByteRange: Codable, Sendable, Equatable, Hashable {
    public static let maximumLength: UInt64 = 8 * 1024 * 1024

    public let start: UInt64
    public let endInclusive: UInt64

    public init(start: UInt64, endInclusive: UInt64) throws {
        guard endInclusive >= start,
              endInclusive - start < Self.maximumLength else {
            throw Pocket3MediaProtocolError.invalidRange
        }
        self.start = start
        self.endInclusive = endInclusive
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: values.decode(UInt64.self, forKey: .start),
                      endInclusive: values.decode(UInt64.self,
                                                  forKey: .endInclusive))
    }

    private enum CodingKeys: String, CodingKey { case start, endInclusive }

    public var length: UInt64 { endInclusive - start + 1 }
    public var headerValue: String { "bytes=\(start)-\(endInclusive)" }
}

/// A fully bounded GET model for camera SoftAP `/v2`. It only constructs a
/// URL and headers; there is no URLSession/executor here and no Wi-Fi action.
public struct Pocket3MediaHTTPRangeRequest: Codable, Sendable, Equatable {
    public static let scheme = "http"
    public static let host = "192.168.2.1"
    public static let port = 80
    public static let endpoint = "/v2"
    public static let maximumPathBytes = 1024

    public let identity: Pocket3MediaSessionIdentity
    public let storage: UInt8
    public let path: String
    public let range: Pocket3MediaByteRange

    public init(identity: Pocket3MediaSessionIdentity, storage: UInt8,
                path: String, range: Pocket3MediaByteRange) throws {
        guard storage == 0 || storage == 1 else {
            throw Pocket3MediaProtocolError.invalidStorage
        }
        guard Self.isSafePath(path) else {
            throw Pocket3MediaProtocolError.invalidPath
        }
        self.identity = identity
        self.storage = storage
        self.path = path
        self.range = range
    }

    public init(sessionID: UUID, peripheralID: UUID? = nil,
                generation: UInt64, storage: UInt8, path: String,
                range: Pocket3MediaByteRange) throws {
        try self.init(identity: Pocket3MediaSessionIdentity(
            sessionID: sessionID, generation: generation,
            peripheralID: peripheralID), storage: storage, path: path,
            range: range)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: values.decode(Pocket3MediaSessionIdentity.self,
                                    forKey: .identity),
            storage: values.decode(UInt8.self, forKey: .storage),
            path: values.decode(String.self, forKey: .path),
            range: values.decode(Pocket3MediaByteRange.self, forKey: .range))
    }

    private enum CodingKeys: String, CodingKey {
        case identity, storage, path, range
    }

    public var method: String { "GET" }
    public var rangeHeader: String { range.headerValue }
    public var headers: [String: String] { ["Range": rangeHeader] }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.port = Self.port
        components.path = Self.endpoint
        components.queryItems = [
            URLQueryItem(name: "storage", value: String(storage)),
            URLQueryItem(name: "path", value: path)
        ]
        return components.url
    }

    public func isCurrent(for status: NativeCameraSessionStatus) -> Bool {
        identity.matches(status)
    }

    private static func isSafePath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumPathBytes,
              !path.hasPrefix("/"), !path.hasPrefix("\\") else {
            return false
        }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) else {
            return false
        }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == ".." }
    }
}

public typealias Pocket3MediaHTTPRange = Pocket3MediaHTTPRangeRequest
public typealias Pocket3MediaDownloadRequest = Pocket3MediaHTTPRangeRequest

// MARK: - Favorite and delete candidates

/// Strict candidate encoder for `02/BF` favorite/star. It has no executor and
/// intentionally exposes only the exact payload plus session evidence.
public struct Pocket3MediaFavoriteCommand: Codable, Sendable, Equatable {
    public static let commandSet: UInt8 = 0x02
    public static let commandID: UInt8 = 0xBF
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x01
    public static let requestFlags: UInt8 = 0x40

    public let identity: Pocket3MediaSessionIdentity
    public let handle: UInt32
    public let counter: UInt32
    public let on: Bool

    public init(identity: Pocket3MediaSessionIdentity, handle: UInt32,
                on: Bool, counter: UInt32) throws {
        guard handle != 0 else { throw Pocket3MediaProtocolError.invalidHandle }
        guard counter != 0 else { throw Pocket3MediaProtocolError.invalidCounter }
        self.identity = identity
        self.handle = handle
        self.counter = counter
        self.on = on
    }

    public init(sessionID: UUID, peripheralID: UUID? = nil,
                generation: UInt64, handle: UInt32, on: Bool,
                counter: UInt32) throws {
        try self.init(identity: Pocket3MediaSessionIdentity(
            sessionID: sessionID, generation: generation,
            peripheralID: peripheralID), handle: handle, on: on,
            counter: counter)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: values.decode(Pocket3MediaSessionIdentity.self,
                                    forKey: .identity),
            handle: values.decode(UInt32.self, forKey: .handle),
            on: values.decode(Bool.self, forKey: .on),
            counter: values.decode(UInt32.self, forKey: .counter))
    }

    private enum CodingKeys: String, CodingKey {
        case identity, handle, counter, on
    }

    public var command: NativeCameraSessionCommand { .mediaFavorite }

    public var payload: Data {
        Data([0x01, 0x01]) + littleEndian(handle) + littleEndian(counter) +
            Data([0x00, on ? 0x01 : 0x00, 0x00, 0x00, 0x00])
    }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination,
                  sequence: sequence, flags: Self.requestFlags,
                  commandSet: Self.commandSet, commandID: Self.commandID,
                  payload: payload)
    }

    public func nativeFrame(sequence: UInt16) -> NativeCommandFrame {
        NativeCommandFrame(frame: frame(sequence: sequence))
    }
}

public typealias Pocket3MediaStarCommand = Pocket3MediaFavoriteCommand

extension Pocket3MediaFavoriteCommand {
    public func isCurrent(for status: NativeCameraSessionStatus) -> Bool {
        identity.matches(status)
    }
}

/// Strict destructive `00/28` encoder only. No transaction adapter or
/// executor is exposed in Phase 0; callers must not re-send this candidate.
public struct Pocket3MediaDeleteCommand: Codable, Sendable, Equatable {
    public static let commandSet: UInt8 = 0x00
    public static let commandID: UInt8 = 0x28
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x01
    public static let requestFlags: UInt8 = 0x40

    public let identity: Pocket3MediaSessionIdentity
    public let handle: UInt32
    public let counter: UInt32

    public init(identity: Pocket3MediaSessionIdentity, handle: UInt32,
                counter: UInt32) throws {
        guard handle != 0 else { throw Pocket3MediaProtocolError.invalidHandle }
        guard counter != 0 else { throw Pocket3MediaProtocolError.invalidCounter }
        self.identity = identity
        self.handle = handle
        self.counter = counter
    }

    public init(sessionID: UUID, peripheralID: UUID? = nil,
                generation: UInt64, handle: UInt32, counter: UInt32) throws {
        try self.init(identity: Pocket3MediaSessionIdentity(
            sessionID: sessionID, generation: generation,
            peripheralID: peripheralID), handle: handle, counter: counter)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: values.decode(Pocket3MediaSessionIdentity.self,
                                    forKey: .identity),
            handle: values.decode(UInt32.self, forKey: .handle),
            counter: values.decode(UInt32.self, forKey: .counter))
    }

    private enum CodingKeys: String, CodingKey { case identity, handle, counter }

    public var payload: Data {
        Data([0x01]) + littleEndian(handle) + littleEndian(counter) +
            Data([0x00]) + littleEndian(1) + Data([0x01, 0x01, 0x00, 0x00])
    }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination,
                  sequence: sequence, flags: Self.requestFlags,
                  commandSet: Self.commandSet, commandID: Self.commandID,
                  payload: payload)
    }

    public func nativeFrame(sequence: UInt16) -> NativeCommandFrame {
        NativeCommandFrame(frame: frame(sequence: sequence))
    }
}

public typealias Pocket3MediaDeleteCandidate = Pocket3MediaDeleteCommand

extension Pocket3MediaDeleteCommand {
    public func isCurrent(for status: NativeCameraSessionStatus) -> Bool {
        identity.matches(status)
    }
}

private func littleEndian(_ value: UInt32) -> Data {
    Data([
        UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)
    ])
}
