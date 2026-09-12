import Foundation

/// Camera-reported media state from the 02/80 flags word. Bit 30 of the
/// little-endian @0 word is the only confirmed playback indicator; the
/// recording transition bit remains a separate intermediate state.
public enum Pocket3MediaSessionState: Codable, Sendable, Equatable, Hashable {
    case normal
    case playback
    case transition
    case unknown(raw: UInt8)

    public static let playbackBitMask: UInt32 = 0x4000_0000
    public var isPlayback: Bool { self == .playback }
    public var isTransitioning: Bool { self == .transition }
    public var rawValue: UInt8 {
        switch self {
        case .normal: 0
        case .playback: 1
        case .transition: 0x40
        case .unknown(let raw): raw
        }
    }
}

public enum Pocket3MediaSessionError: Error, Codable, Sendable, Equatable {
    case invalidPayload
    case invalidClock
    case invalidIdentity
}

/// Typed, bounded 02/80 status. @5/@9 are the active-store capacity fields;
/// they are deliberately not turned into a guessed store selector.
public struct Pocket3MediaSessionReadback: Codable, Sendable, Equatable {
    public static let maximumRawBytes = DUMLCodec.maximumPayloadLength
    public let raw: Data
    public let statusByteRaw: UInt8
    public let status: Pocket3BodyRecordingStatus
    public let flagsRaw: UInt32?
    public let playbackBitRaw: UInt8?
    public let playback: Bool?
    public let activeStoreTotalMiB: UInt32?
    public let activeStoreFreeMiB: UInt32?
    public let state: Pocket3MediaSessionState

    public init(raw: Data) throws {
        guard !raw.isEmpty, raw.count <= Self.maximumRawBytes else {
            throw Pocket3MediaSessionError.invalidPayload
        }
        let bytes = Array(raw)
        self.raw = raw
        statusByteRaw = bytes[0]
        status = Pocket3BodyRecordingStatus(rawValue: bytes[0])
        if bytes.count >= 4 {
            let flags = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 |
                UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            flagsRaw = flags
            let set = (flags & Pocket3MediaSessionState.playbackBitMask) != 0
            playbackBitRaw = set ? 1 : 0
            playback = set
        } else {
            flagsRaw = nil
            playbackBitRaw = nil
            playback = nil
        }
        activeStoreTotalMiB = bytes.count >= 9 ? Self.u32(bytes, 5) : nil
        activeStoreFreeMiB = bytes.count >= 13 ? Self.u32(bytes, 9) : nil
        if playback == true { state = .playback }
        else if bytes[0] & 0x40 != 0 { state = .transition }
        else if bytes[0] == 0x01 || bytes[0] == 0x81 { state = .normal }
        else { state = .unknown(raw: bytes[0]) }
    }

    /// Reconstructs a bounded value from the existing typed camera status
    /// without retaining a second copy of the original packet.
    public init(status: Pocket3CameraStatusObservation) throws {
        guard let flags = status.statusFlagsRaw else {
            try self.init(raw: Data([status.statusByte]))
            return
        }
        var bytes = Data(repeating: 0, count: 13)
        bytes[0] = UInt8(flags & 0xff)
        bytes[1] = UInt8((flags >> 8) & 0xff)
        bytes[2] = UInt8((flags >> 16) & 0xff)
        bytes[3] = UInt8((flags >> 24) & 0xff)
        Self.put(status.storageTotalMiB, into: &bytes, at: 5)
        Self.put(status.storageFreeMiB, into: &bytes, at: 9)
        try self.init(raw: bytes)
    }

    public static func decode(_ raw: Data) -> Self? { try? Self(raw: raw) }
    public static func parse(_ raw: Data) -> Self? { decode(raw) }
    /// Decodes only a camera status response envelope. The payload parser
    /// remains available for callers that have already validated routing.
    public static func decode(frame: DUMLFrame) -> Self? {
        guard frame.source & 0x1f == 0x01,
              frame.destination & 0x1f == 0x02,
              frame.commandSet == 0x02,
              frame.commandID == 0x80 else { return nil }
        return decode(frame.payload)
    }
    public static func parse(frame: DUMLFrame) -> Self? { decode(frame: frame) }
    public var activeStoreTotal: UInt32? { activeStoreTotalMiB }
    public var activeStoreFree: UInt32? { activeStoreFreeMiB }
    public var playbackBit: Bool? { playback }
    public var inPlayback: Bool? { playback }
    public var transition: Bool { state == .transition }
    public var isKnown: Bool {
        if case .unknown = state { return false }
        return true
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 |
            UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
    private static func put(_ value: UInt32?, into data: inout Data, at: Int) {
        guard let value else { return }
        data[at] = UInt8(value & 0xff)
        data[at + 1] = UInt8((value >> 8) & 0xff)
        data[at + 2] = UInt8((value >> 16) & 0xff)
        data[at + 3] = UInt8((value >> 24) & 0xff)
    }
}

/// Session/generation-bound status evidence used by playback and list policy.
public struct Pocket3MediaSessionObservation: Codable, Sendable, Equatable {
    public static let maximumAge: TimeInterval = 5
    public let sessionID: UUID
    public let peripheralID: UUID?
    public let generation: UInt64
    public let receivedUptime: TimeInterval
    public let readback: Pocket3MediaSessionReadback

    public init(sessionID: UUID, peripheralID: UUID? = nil, generation: UInt64,
                receivedUptime: TimeInterval,
                readback: Pocket3MediaSessionReadback) throws {
        guard generation > 0, receivedUptime.isFinite, receivedUptime >= 0 else {
            throw Pocket3MediaSessionError.invalidIdentity
        }
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.receivedUptime = receivedUptime
        self.readback = readback
    }

    public init?(sessionID: UUID, peripheralID: UUID? = nil, generation: UInt64,
                 receivedUptime: TimeInterval, raw: Data) {
        guard let readback = Pocket3MediaSessionReadback.decode(raw),
              let result = try? Self(sessionID: sessionID,
                  peripheralID: peripheralID, generation: generation,
                  receivedUptime: receivedUptime, readback: readback) else {
            return nil
        }
        self = result
    }

    public init?(status: Pocket3CameraStatusObservation, generation: UInt64) {
        guard let readback = try? Pocket3MediaSessionReadback(status: status),
              let result = try? Self(sessionID: status.sessionID,
                  peripheralID: status.peripheralID, generation: generation,
                  receivedUptime: status.receivedUptime, readback: readback) else {
            return nil
        }
        self = result
    }

    public var raw: Data { readback.raw }
    public var state: Pocket3MediaSessionState { readback.state }
    public var playback: Bool? { readback.playback }
    public var activeStoreTotalMiB: UInt32? { readback.activeStoreTotalMiB }
    public var activeStoreFreeMiB: UInt32? { readback.activeStoreFreeMiB }
    public func isFresh(nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        generation > 0 && receivedUptime.isFinite && receivedUptime >= 0 &&
            nowUptime.isFinite && maximumAge.isFinite && maximumAge >= 0 &&
            nowUptime >= receivedUptime && nowUptime - receivedUptime <= maximumAge &&
            raw.count <= Pocket3MediaSessionReadback.maximumRawBytes
    }
    public func isFresh(session: NativeCameraSessionStatus,
                        nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        guard let sessionID = session.sessionID else { return false }
        return self.sessionID == sessionID &&
            (peripheralID == nil || peripheralID == session.peerID) &&
            generation == session.generation &&
            session.state.satisfies(.commandReady) &&
            isFresh(nowUptime: nowUptime, maximumAge: maximumAge)
    }
}

public typealias Pocket3MediaStatusReadback = Pocket3MediaSessionReadback
public typealias Pocket3MediaStatusObservation = Pocket3MediaSessionObservation
public typealias Pocket3MediaPlaybackReadback = Pocket3MediaSessionReadback

/// Only older cursors require an explicitly confirmed playback bit.
public enum Pocket3MediaListPlaybackPolicy {
    public static func requiresPlayback(cursor: UInt32) -> Bool {
        cursor != Pocket3MediaListRequest.newestSD &&
            cursor != Pocket3MediaListRequest.newestInternal
    }
    public static func allows(cursor: UInt32,
                              session: Pocket3MediaSessionObservation?) -> Bool {
        guard requiresPlayback(cursor: cursor) else { return true }
        return session?.state == .playback
    }
}

public extension Pocket3MediaListRequest {
    var requiresPlayback: Bool {
        Pocket3MediaListPlaybackPolicy.requiresPlayback(cursor: cursor)
    }
    func isAllowed(mediaSession: Pocket3MediaSessionObservation?,
                   nowUptime: TimeInterval) -> Bool {
        guard requiresPlayback else { return true }
        guard let mediaSession,
              mediaSession.sessionID == identity.sessionID,
              mediaSession.generation == identity.generation,
              (identity.peripheralID == nil ||
               identity.peripheralID == mediaSession.peripheralID),
              mediaSession.isFresh(nowUptime: nowUptime) else { return false }
        return mediaSession.state == .playback
    }
}

public enum Pocket3MediaPresenceHoldLifecycle: String, Codable, Sendable,
    Equatable, CaseIterable {
    case idle, holding, expired, cancelled
}

/// Presence lifecycle bookkeeping only; the transport owns actual 00/88 I/O.
public struct Pocket3MediaPresenceHoldState: Codable, Sendable, Equatable {
    public static let defaultMaximumAge: TimeInterval = 2.5
    public let identity: Pocket3MediaSessionIdentity
    public let interval: TimeInterval
    public private(set) var lifecycle: Pocket3MediaPresenceHoldLifecycle
    public private(set) var lastBeatUptime: TimeInterval?

    public init(identity: Pocket3MediaSessionIdentity,
                interval: TimeInterval = Pocket3MediaPresenceHold.defaultInterval,
                lifecycle: Pocket3MediaPresenceHoldLifecycle = .idle,
                lastBeatUptime: TimeInterval? = nil) throws {
        guard interval.isFinite, interval >= 0.25, interval <= 5,
              lastBeatUptime.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw Pocket3MediaSessionError.invalidClock
        }
        self.identity = identity; self.interval = interval
        self.lifecycle = lifecycle; self.lastBeatUptime = lastBeatUptime
    }

    @discardableResult public mutating func begin(at uptime: TimeInterval) -> Bool {
        guard uptime.isFinite, uptime >= 0 else { return false }
        lifecycle = .holding; lastBeatUptime = uptime; return true
    }
    @discardableResult public mutating func beat(at uptime: TimeInterval) -> Bool {
        guard lifecycle == .holding, uptime.isFinite, uptime >= 0,
              lastBeatUptime.map({ uptime >= $0 }) ?? false else { return false }
        lastBeatUptime = uptime; return true
    }
    @discardableResult public mutating func expire(at uptime: TimeInterval,
        maximumAge: TimeInterval = Self.defaultMaximumAge) -> Bool {
        guard lifecycle == .holding, let lastBeatUptime,
              uptime.isFinite, maximumAge.isFinite, maximumAge >= 0,
              uptime >= lastBeatUptime, uptime - lastBeatUptime > maximumAge else {
            return false
        }
        lifecycle = .expired; return true
    }
    @discardableResult public mutating func cancel() -> Bool {
        guard lifecycle == .holding else { return false }
        lifecycle = .cancelled; return true
    }
    public func isFresh(nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.defaultMaximumAge) -> Bool {
        lifecycle == .holding && lastBeatUptime.map {
            nowUptime.isFinite && maximumAge.isFinite && maximumAge >= 0 &&
                nowUptime >= $0 && nowUptime - $0 <= maximumAge
        } == true
    }
}

public typealias Pocket3MediaSessionStatus = Pocket3MediaSessionState
