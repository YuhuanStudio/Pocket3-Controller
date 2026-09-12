import Foundation

/// Capture-confirmed shooting-mode IDs from unsolicited Pocket 3 `02/80`
/// status frames. Unknown future values remain available as `shootingModeRaw`.
public enum Pocket3ShootingMode: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case slowMotion = 0x00
    case video = 0x01
    case timelapse = 0x02
    case photo = 0x05
    case hyperlapse = 0x0A
    case panorama = 0x0C
    case motionlapse = 0x18
    case lowLight = 0x28
}

/// Lifecycle encoded by the recording/transition bits in `02/80` byte 0.
/// The raw byte is retained by `Pocket3BodyRecordingStatus`; values outside
/// the four captured states stay `.unknown`.
public enum Pocket3BodyRecordingLifecycle: Codable, Sendable, Equatable {
    case idle
    case transitioningToIdle
    case recording
    case transitioningToRecording
    case unknown(raw: UInt8)

    public static let starting = Self.transitioningToRecording
    public static let stopping = Self.transitioningToIdle
    public static let transitionRecording = Self.transitioningToRecording
    public static let transitionIdle = Self.transitioningToIdle

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0x01: self = .idle
        case 0x41: self = .transitioningToIdle
        case 0x81: self = .recording
        case 0xC1: self = .transitioningToRecording
        default: self = .unknown(raw: rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .idle: 0x01
        case .transitioningToIdle: 0x41
        case .recording: 0x81
        case .transitioningToRecording: 0xC1
        case .unknown(let raw): raw
        }
    }

    /// The recording bit as received, including for unknown future states.
    public var recordingBit: Bool { rawValue & 0x80 != 0 }
    /// The transition bit as received, including for unknown future states.
    public var transitionBit: Bool { rawValue & 0x40 != 0 }
    public var isRecording: Bool { recordingBit }
    public var isTransitioning: Bool { transitionBit }
}

/// Typed `02/80` byte-0 status. This value describes camera-reported state;
/// it does not imply that a start/stop command was sent or accepted.
public struct Pocket3BodyRecordingStatus: Codable, Sendable, Equatable {
    public let rawValue: UInt8
    public let lifecycle: Pocket3BodyRecordingLifecycle

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
        lifecycle = Pocket3BodyRecordingLifecycle(rawValue: rawValue)
    }

    public var recording: Bool { lifecycle.recordingBit }
    public var transitioning: Bool { lifecycle.transitionBit }
    public var isRecording: Bool { recording }
    public var isTransitioning: Bool { transitioning }
    public var state: Pocket3BodyRecordingLifecycle { lifecycle }
    public var isKnown: Bool {
        if case .unknown = lifecycle { return false }
        return true
    }
}

/// Read-only camera-domain state. It never implies that a record or mode
/// request was sent, and it carries no media, credential or file path.
public struct Pocket3CameraStatusObservation: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let peripheralID: UUID
    public let receivedAt: Date
    public let receivedUptime: TimeInterval
    public let statusByte: UInt8
    public let recording: Bool
    public let transitioning: Bool
    public let videoLike: Bool?
    public let shootingModeRaw: UInt8?
    public let shootingMode: Pocket3ShootingMode?
    public let storageTotalMiB: UInt32?
    public let storageFreeMiB: UInt32?
    public let remainingRecordSeconds: UInt16?
    public let elapsedRecordSeconds: UInt16?
    /// Complete @0 flags word when the status payload includes it.
    public let statusFlagsRaw: UInt32?
    /// @0 bit 30 (`0x4000_0000`), the camera-reported playback bit.
    public let playbackBit: Bool?
    /// State derived from the recording transition bit and playback bit.
    public let mediaSessionState: Pocket3MediaSessionState?

    public init(sessionID: UUID, peripheralID: UUID, receivedAt: Date,
                receivedUptime: TimeInterval, statusByte: UInt8,
                recording: Bool, transitioning: Bool, videoLike: Bool?,
                shootingModeRaw: UInt8?, shootingMode: Pocket3ShootingMode?,
                storageTotalMiB: UInt32?, storageFreeMiB: UInt32?,
                remainingRecordSeconds: UInt16?, elapsedRecordSeconds: UInt16?,
                statusFlagsRaw: UInt32? = nil, playbackBit: Bool? = nil,
                mediaSessionState: Pocket3MediaSessionState? = nil) {
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.receivedAt = receivedAt
        self.receivedUptime = receivedUptime
        self.statusByte = statusByte
        self.recording = recording
        self.transitioning = transitioning
        self.videoLike = videoLike
        self.shootingModeRaw = shootingModeRaw
        self.shootingMode = shootingMode
        self.storageTotalMiB = storageTotalMiB
        self.storageFreeMiB = storageFreeMiB
        self.remainingRecordSeconds = remainingRecordSeconds
        self.elapsedRecordSeconds = elapsedRecordSeconds
        self.statusFlagsRaw = statusFlagsRaw
        self.playbackBit = playbackBit
        self.mediaSessionState = mediaSessionState
    }

    /// Typed lifecycle projection of `statusByte`. Unknown low/status bits
    /// remain available through `recordingStatus.rawValue`.
    public var recordingStatus: Pocket3BodyRecordingStatus {
        Pocket3BodyRecordingStatus(rawValue: statusByte)
    }
    public var bodyRecordingStatus: Pocket3BodyRecordingStatus { recordingStatus }
    public var recordingLifecycle: Pocket3BodyRecordingLifecycle { recordingStatus.lifecycle }
    public var bodyRecordingLifecycle: Pocket3BodyRecordingLifecycle { recordingLifecycle }
    public var recordingState: Pocket3BodyRecordingLifecycle { recordingLifecycle }
    public var bodyRecordingState: Pocket3BodyRecordingLifecycle { recordingLifecycle }
    public var flagsRaw: UInt32? { statusFlagsRaw }
    public var playback: Bool? { playbackBit }
    public var inPlayback: Bool? { playbackBit }
    public var activeStoreTotalMiB: UInt32? { storageTotalMiB }
    public var activeStoreFreeMiB: UInt32? { storageFreeMiB }
    public var mediaState: Pocket3MediaSessionState {
        if let mediaSessionState { return mediaSessionState }
        if statusByte & 0x40 != 0 { return .transition }
        switch statusByte {
        case 0x01, 0x81: return .normal
        default: return .unknown(raw: statusByte)
        }
    }

    public func isFresh(nowUptime: TimeInterval, maximumAge: TimeInterval = 5) -> Bool {
        receivedAt.timeIntervalSinceReferenceDate.isFinite && nowUptime.isFinite && receivedUptime.isFinite && maximumAge.isFinite && maximumAge >= 0 &&
            nowUptime >= receivedUptime && nowUptime - receivedUptime <= maximumAge
    }
}

/// Independent `02/DC` microSD inventory. Pocket 3 currently reports one
/// store, but the raw count is preserved rather than forced to that assumption.
public struct Pocket3StorageObservation: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let peripheralID: UUID
    public let receivedAt: Date
    public let receivedUptime: TimeInterval
    public let storeCount: UInt8
    public let totalMiB: UInt32
    public let freeMiB: UInt32
    public func isFresh(nowUptime: TimeInterval, maximumAge: TimeInterval = 5) -> Bool {
        nowUptime.isFinite && receivedUptime.isFinite && maximumAge.isFinite && maximumAge >= 0 &&
            nowUptime >= receivedUptime && nowUptime - receivedUptime <= maximumAge
    }
}

public enum Pocket3CameraStatusParser {
    /// Pocket 3 Camera(01) → App(02), request/push flags 00, set/cmd 02/80.
    /// A one-byte frame is enough for record state. Extended fields require
    /// the capture-confirmed 58-byte layout and are otherwise left nil.
    public static func parse(_ frame: DUMLFrame, sessionID: UUID, peripheralID: UUID,
                             receivedAt: Date, receivedUptime: TimeInterval) -> Pocket3CameraStatusObservation? {
        guard frame.source == 0x01, frame.destination == 0x02, frame.flags == 0,
              frame.commandSet == 0x02, frame.commandID == 0x80,
              let status = frame.payload.first, receivedUptime.isFinite, receivedUptime >= 0 else { return nil }
        let recording = status & 0x80 != 0, transitioning = status & 0x40 != 0
        let mediaReadback = Pocket3MediaSessionReadback.decode(frame.payload)
        guard frame.payload.count >= 58 else {
            return .init(sessionID: sessionID, peripheralID: peripheralID, receivedAt: receivedAt,
                receivedUptime: receivedUptime, statusByte: status, recording: recording,
                transitioning: transitioning, videoLike: nil, shootingModeRaw: nil, shootingMode: nil,
                storageTotalMiB: nil, storageFreeMiB: nil, remainingRecordSeconds: nil,
                elapsedRecordSeconds: nil,
                statusFlagsRaw: mediaReadback?.flagsRaw,
                playbackBit: mediaReadback?.playback,
                mediaSessionState: mediaReadback?.state)
        }
        let payload = frame.payload
        let modeRaw = payload[57], videoLike = payload[4] == 0x01
        return .init(sessionID: sessionID, peripheralID: peripheralID, receivedAt: receivedAt,
            receivedUptime: receivedUptime, statusByte: status, recording: recording,
            transitioning: transitioning, videoLike: videoLike, shootingModeRaw: modeRaw,
            shootingMode: Pocket3ShootingMode(rawValue: modeRaw),
            storageTotalMiB: u32(payload, 5), storageFreeMiB: u32(payload, 9),
            remainingRecordSeconds: videoLike ? u16(payload, 17) : nil,
            elapsedRecordSeconds: videoLike ? u16(payload, 29) : nil,
            statusFlagsRaw: mediaReadback?.flagsRaw,
            playbackBit: mediaReadback?.playback,
            mediaSessionState: mediaReadback?.state)
    }

    public static func parseStorage(_ frame: DUMLFrame, sessionID: UUID, peripheralID: UUID,
                                    receivedAt: Date, receivedUptime: TimeInterval) -> Pocket3StorageObservation? {
        guard frame.source == 0x01, frame.destination == 0x02, frame.flags == 0,
              frame.commandSet == 0x02, frame.commandID == 0xDC, frame.payload.count >= 22,
              receivedUptime.isFinite, receivedUptime >= 0 else { return nil }
        return .init(sessionID: sessionID, peripheralID: peripheralID, receivedAt: receivedAt,
            receivedUptime: receivedUptime, storeCount: frame.payload[2],
            totalMiB: u32(frame.payload, 6), freeMiB: u32(frame.payload, 10))
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
