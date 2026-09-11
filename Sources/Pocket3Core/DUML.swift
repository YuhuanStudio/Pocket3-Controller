import Foundation

/// One DUML v1 frame, without BLE fragmentation or Wi-Fi routing headers.
public struct DUMLFrame: Sendable, Equatable {
    public let version: UInt8 = 1
    public let source: UInt8
    public let destination: UInt8
    public let sequence: UInt16
    public let flags: UInt8
    public let commandSet: UInt8
    public let commandID: UInt8
    public let payload: Data

    public init(source: UInt8, destination: UInt8, sequence: UInt16, flags: UInt8,
                commandSet: UInt8, commandID: UInt8, payload: Data = Data()) {
        self.source = source; self.destination = destination; self.sequence = sequence
        self.flags = flags; self.commandSet = commandSet; self.commandID = commandID
        self.payload = payload
    }
}

public enum DUMLCodecError: Error, Equatable, Sendable {
    case invalidSize
    case invalidStart
    case unsupportedVersion
    case lengthMismatch
    case invalidHeaderChecksum
    case invalidFrameChecksum
}

/// Independently implemented from the DUML wire layout and frozen CRC vectors.
/// Protocol provenance: research/2026-09-08/duml-fixtures/PROVENANCE.md.
/// Decode accepts exactly one complete frame; transports must provide bounded
/// reassembly and may not treat an arbitrary BLE notification as a full frame.
public enum DUMLCodec {
    public static let minimumFrameLength = 13
    public static let maximumFrameLength = 1023
    public static let maximumPayloadLength = maximumFrameLength - minimumFrameLength

    public static func encode(_ frame: DUMLFrame) throws -> Data {
        guard frame.payload.count <= maximumPayloadLength else { throw DUMLCodecError.invalidSize }
        let size = minimumFrameLength + frame.payload.count
        var bytes = [UInt8](repeating: 0, count: size)
        bytes[0] = 0x55
        bytes[1] = UInt8(size & 0xff)
        bytes[2] = 0x04 | UInt8(size >> 8)
        bytes[3] = crc8(bytes.prefix(3))
        bytes[4] = frame.source; bytes[5] = frame.destination
        bytes[6] = UInt8(frame.sequence & 0xff); bytes[7] = UInt8(frame.sequence >> 8)
        bytes[8] = frame.flags; bytes[9] = frame.commandSet; bytes[10] = frame.commandID
        bytes.replaceSubrange(11..<(size - 2), with: frame.payload)
        let checksum = crc16(bytes.prefix(size - 2))
        bytes[size - 2] = UInt8(checksum & 0xff); bytes[size - 1] = UInt8(checksum >> 8)
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> DUMLFrame {
        guard (minimumFrameLength...maximumFrameLength).contains(data.count) else { throw DUMLCodecError.invalidSize }
        // Data slices need not start at index zero. Normalize only after the
        // length bound, before indexing any wire field.
        let bytes = Array(data)
        guard bytes[0] == 0x55 else { throw DUMLCodecError.invalidStart }
        guard bytes[2] >> 2 == 1 else { throw DUMLCodecError.unsupportedVersion }
        let declared = Int(bytes[1]) | (Int(bytes[2] & 0x03) << 8)
        guard declared == bytes.count else { throw DUMLCodecError.lengthMismatch }
        guard crc8(bytes.prefix(3)) == bytes[3] else { throw DUMLCodecError.invalidHeaderChecksum }
        let footer = bytes.count - 2
        let expected = UInt16(bytes[footer]) | (UInt16(bytes[footer + 1]) << 8)
        guard crc16(bytes.prefix(footer)) == expected else { throw DUMLCodecError.invalidFrameChecksum }
        // Routing, command and payload interpretation starts only after both
        // checksums and the complete version/length contract passed.
        return DUMLFrame(source: bytes[4], destination: bytes[5],
            sequence: UInt16(bytes[6]) | (UInt16(bytes[7]) << 8), flags: bytes[8],
            commandSet: bytes[9], commandID: bytes[10], payload: Data(bytes[11..<footer]))
    }

    private static let headerTable: [UInt8] = checksumTable(polynomial: 0x8c)
    private static let frameTable: [UInt16] = checksumTable(polynomial: 0x8408)

    private static func checksumTable<T: FixedWidthInteger & UnsignedInteger>(polynomial: T) -> [T] {
        (0..<256).map { index in
            (0..<8).reduce(T(index)) { remainder, _ in
                (remainder >> 1) ^ (remainder & 1 == 0 ? 0 : polynomial)
            }
        }
    }
    static func crc8<Bytes: Sequence>(_ bytes: Bytes) -> UInt8 where Bytes.Element == UInt8 {
        bytes.reduce(UInt8(0x77)) { headerTable[Int($0 ^ $1)] }
    }
    static func crc16<Bytes: Sequence>(_ bytes: Bytes) -> UInt16 where Bytes.Element == UInt8 {
        bytes.reduce(UInt16(0x3692)) { ($0 >> 8) ^ frameTable[Int(($0 ^ UInt16($1)) & 0xff)] }
    }
}

/// Supplied by the receiving transport, never inferred from battery contents.
public enum DUMLTelemetrySource: String, Codable, Sendable { case bluetooth, wifi }
public enum Pocket3ChargingState: String, Codable, Sendable { case unknown, charging, notCharging }

public struct Pocket3BatteryTelemetry: Codable, Sendable, Equatable {
    public let percent: Int
    public let chargingState: Pocket3ChargingState
    /// Exact Pocket 3 `0D/02` byte 32. Unknown future values remain visible
    /// without being converted into a charging or external-power claim.
    public var chargingStateRaw: UInt8? = nil
    public let source: DUMLTelemetrySource
    public let receivedAt: Date

    /// Clock changes, invalid ages and future timestamps never make a sample
    /// current. Transports must separately discard samples from old sessions.
    public func isFresh(now: Date, maxAge: TimeInterval = 5) -> Bool {
        let age = now.timeIntervalSince(receivedAt)
        return maxAge.isFinite && maxAge >= 0 && age.isFinite && age >= 0 && age <= maxAge
    }
}

public enum Pocket3TelemetryParser {
    public static func battery(in data: Data, source: DUMLTelemetrySource, receivedAt: Date) throws -> Pocket3BatteryTelemetry? {
        battery(from: try DUMLCodec.decode(data), source: source, receivedAt: receivedAt)
    }

    /// Accept a previously validated frame. This is Pocket 3-specific; other
    /// DJI battery payloads cannot be parsed solely by sharing command set 0D.
    public static func battery(from frame: DUMLFrame, source: DUMLTelemetrySource, receivedAt: Date) -> Pocket3BatteryTelemetry? {
        guard frame.commandSet == 0x0d, frame.commandID == 0x02,
              (33...DUMLCodec.maximumPayloadLength).contains(frame.payload.count),
              receivedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let payload = Array(frame.payload)
        guard payload[20] <= 100 else { return nil }
        let state: Pocket3ChargingState
        switch payload[32] {
        case 0: state = .notCharging
        case 1: state = .charging
        default: state = .unknown
        }
        // Not charging is not proof of absent external power, especially at
        // high state of charge. No external-power value is manufactured here.
        return Pocket3BatteryTelemetry(percent: Int(payload[20]), chargingState: state,
            chargingStateRaw: payload[32], source: source, receivedAt: receivedAt)
    }
}
