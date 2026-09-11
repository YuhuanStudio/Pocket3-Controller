import Foundation

/// A pose reported by the explicitly paired BLE peer. The axis names and
/// scale follow the existing Pocket 3 probe parser. They are not calibrated
/// physical/world angles or an association with the USB camera's coordinates.
public struct BluetoothPoseObservation: Codable, Sendable, Equatable {
    public enum RawUnit: String, Codable, Sendable { case deviceReportedDeciDegrees = "device_reported_deci_degrees" }
    public enum Calibration: String, Codable, Sendable { case notCalibratedToUSB = "not_calibrated_to_usb" }
    public static let maximumAge: TimeInterval = 5
    public let sessionID: UUID
    public let peripheralID: UUID
    public let sequence: UInt16
    public let pitchRaw: Int16
    public let rollRaw: Int16
    public let yawRaw: Int16
    /// Capture-documented optional bytes whose complete enum/bit meanings are
    /// not established. They are diagnostics only and never authorize motion.
    public let modeStatusRaw: UInt8?
    public let limitStatusRaw: UInt8?
    public let receivedAt: Date
    public let receivedUptime: TimeInterval
    public let unit: RawUnit
    public let calibration: Calibration
    public var pitchDegrees: Double { Double(pitchRaw) / 10 }
    public var rollDegrees: Double { Double(rollRaw) / 10 }
    public var yawDegrees: Double { Double(yawRaw) / 10 }

    init(sessionID: UUID, peripheralID: UUID, sequence: UInt16, values: BluetoothPoseValues,
         receivedAt: Date, receivedUptime: TimeInterval) {
        self.sessionID = sessionID; self.peripheralID = peripheralID; self.sequence = sequence
        pitchRaw = values.pitch; rollRaw = values.roll; yawRaw = values.yaw
        modeStatusRaw = values.modeStatusRaw; limitStatusRaw = values.limitStatusRaw
        self.receivedAt = receivedAt; self.receivedUptime = receivedUptime
        unit = .deviceReportedDeciDegrees; calibration = .notCalibratedToUSB
    }
    public func isFresh(nowUptime: TimeInterval) -> Bool {
        receivedUptime.isFinite && receivedUptime >= 0 && receivedAt.timeIntervalSinceReferenceDate.isFinite
            && nowUptime.isFinite && nowUptime >= receivedUptime
            && nowUptime - receivedUptime <= Self.maximumAge
    }
}

/// Extracted without changing the existing BLE probe/recenter layout:
/// source04 → App, 04/05, signed little-endian pitch/roll/yaw at 0/2/4,
/// device-reported 0.1-degree units. The existing admission limit is retained.
struct BluetoothPoseValues: Sendable {
    let pitch: Int16
    let roll: Int16
    let yaw: Int16
    let modeStatusRaw: UInt8?
    let limitStatusRaw: UInt8?

    static func parse(_ frame: DUMLFrame) -> Self? {
        guard frame.source == 0x04, frame.destination & 0x1f == 0x02,
              frame.commandSet == 0x04, frame.commandID == 0x05,
              (6...DUMLCodec.maximumPayloadLength).contains(frame.payload.count) else { return nil }
        let bytes = Array(frame.payload)
        func raw(_ offset: Int) -> Int16 { Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8) }
        let result = Self(pitch: raw(0), roll: raw(2), yaw: raw(4),
            modeStatusRaw: bytes.count > 6 ? bytes[6] : nil,
            limitStatusRaw: bytes.count > 10 ? bytes[10] : nil)
        guard [result.pitch, result.roll, result.yaw].allSatisfy({ abs(Int($0)) <= 3600 }) else { return nil }
        return result
    }
    func telemetry(receivedAt: Date) -> Pocket3DatalinkTelemetry {
        Pocket3DatalinkTelemetry(pitchDegrees: Double(pitch) / 10, rollDegrees: Double(roll) / 10,
                                yawDegrees: Double(yaw) / 10, receivedAt: receivedAt)
    }
}

/// No I/O or callbacks. Only a new CRC-validated frame from this exact paired
/// session can refresh the observation; duplicate frames cannot extend age.
struct BluetoothPoseStore {
    private var sessionID: UUID?
    private var peripheralID: UUID?
    private var admission = NativeBLETelemetrySequenceAdmission()
    private var latest: BluetoothPoseObservation?

    mutating func clear() {
        sessionID = nil; peripheralID = nil; latest = nil
        admission = NativeBLETelemetrySequenceAdmission()
    }
    mutating func bind(sessionID: UUID, peripheralID: UUID) {
        clear(); self.sessionID = sessionID; self.peripheralID = peripheralID
    }
    @discardableResult
    mutating func receive(_ packet: ValidatedDUMLPacket, sessionID: UUID, peripheralID: UUID,
                          paired: Bool, receivedAt: Date, uptime: TimeInterval) -> Bool {
        guard self.sessionID == sessionID, self.peripheralID == peripheralID, paired,
              uptime.isFinite, uptime >= 0, receivedAt.timeIntervalSinceReferenceDate.isFinite,
              latest == nil || uptime > latest!.receivedUptime,
              let values = BluetoothPoseValues.parse(packet.frame), admission.accept(packet.frame) != nil else { return false }
        latest = BluetoothPoseObservation(sessionID: sessionID, peripheralID: peripheralID,
            sequence: packet.frame.sequence, values: values, receivedAt: receivedAt, receivedUptime: uptime)
        return true
    }
    func snapshot(sessionID: UUID, peripheralID: UUID?, paired: Bool, nowUptime: TimeInterval) -> BluetoothPoseObservation? {
        guard paired, self.sessionID == sessionID, self.peripheralID == peripheralID,
              let latest, latest.isFresh(nowUptime: nowUptime) else { return nil }
        return latest
    }
}
