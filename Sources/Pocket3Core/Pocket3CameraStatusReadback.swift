import Foundation

/// Capture-confirmed shooting-mode IDs from unsolicited Pocket 3 `02/80`
/// status frames. Unknown future values remain available as `shootingModeRaw`.
public enum Pocket3ShootingMode: UInt8, Codable, Sendable, CaseIterable {
    case slowMotion = 0x00
    case video = 0x01
    case timelapse = 0x02
    case photo = 0x05
    case hyperlapse = 0x0A
    case panorama = 0x0C
    case motionlapse = 0x18
    case lowLight = 0x28
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

    public func isFresh(nowUptime: TimeInterval, maximumAge: TimeInterval = 5) -> Bool {
        nowUptime.isFinite && receivedUptime.isFinite && maximumAge.isFinite && maximumAge >= 0 &&
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
        guard frame.payload.count >= 58 else {
            return .init(sessionID: sessionID, peripheralID: peripheralID, receivedAt: receivedAt,
                receivedUptime: receivedUptime, statusByte: status, recording: recording,
                transitioning: transitioning, videoLike: nil, shootingModeRaw: nil, shootingMode: nil,
                storageTotalMiB: nil, storageFreeMiB: nil, remainingRecordSeconds: nil,
                elapsedRecordSeconds: nil)
        }
        let payload = frame.payload
        let modeRaw = payload[57], videoLike = payload[4] == 0x01
        return .init(sessionID: sessionID, peripheralID: peripheralID, receivedAt: receivedAt,
            receivedUptime: receivedUptime, statusByte: status, recording: recording,
            transitioning: transitioning, videoLike: videoLike, shootingModeRaw: modeRaw,
            shootingMode: Pocket3ShootingMode(rawValue: modeRaw),
            storageTotalMiB: u32(payload, 5), storageFreeMiB: u32(payload, 9),
            remainingRecordSeconds: videoLike ? u16(payload, 17) : nil,
            elapsedRecordSeconds: u16(payload, 29))
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
