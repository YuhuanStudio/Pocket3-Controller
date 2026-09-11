import Foundation
import Pocket3UVC

struct UVCAttachmentBinding {
    private(set) var registryID: String?
    private var bootSessionID: String?
    mutating func validate(registryID: String?, bootSessionID: String?) throws {
        guard let registryID, !registryID.isEmpty, let bootSessionID, !bootSessionID.isEmpty else {
            throw BridgeFailure("hardware_identity", "無法確認 USB 連接身分")
        }
        if let previous = self.registryID {
            guard previous == registryID && self.bootSessionID == bootSessionID else {
                throw BridgeFailure("uvc_attachment_changed", "USB 連接已改變，請重新連接並驗證控制")
            }
        } else {
            self.registryID = registryID; self.bootSessionID = bootSessionID
        }
    }
}

// Only UVCConnection accesses this pointer, synchronously under actor isolation.
// Its lifetime owner may be destroyed on any executor after the final call ends.
private final class OwnedUVCSession: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { p3_uvc_session_close(pointer) }
}

public actor UVCConnection {
    public let location: UInt32
    private var attachment = UVCAttachmentBinding()
    private var session: OwnedUVCSession?
    private let lifetimePermit = OperationPermit()
    public init(location: UInt32) { self.location = location }
    public nonisolated func invalidate() { lifetimePermit.invalidate() }
    private static func consume(_ raw: UnsafeMutablePointer<CChar>?) throws -> JSONValue {
        guard let raw else { throw BridgeFailure("uvc_memory", "無法取得 USB 控制資料") }
        defer { p3_uvc_free(raw) }
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(String(cString: raw).utf8))
        if let error = v["error"].string { throw BridgeFailure(error, "USB 控制失敗：\(error)") }
        return v
    }
    private func openedSession() throws -> OwnedUVCSession {
        if let session { return session }
        var pointer: OpaquePointer?
        do {
            _ = try Self.consume(p3_uvc_session_open(location, &pointer))
            guard let pointer else { throw BridgeFailure("uvc_session_unavailable", "無法建立 USB 控制連接") }
            let opened = OwnedUVCSession(pointer)
            session = opened
            return opened
        } catch {
            if let pointer { p3_uvc_session_close(pointer) }
            throw error
        }
    }
    public func status() throws -> UVCCapabilities {
        guard lifetimePermit.isValid else { throw BridgeFailure("uvc_connection_closed", "USB 控制連線已結束") }
        let session = try openedSession()
        let capabilities = try Self.consume(p3_uvc_session_status(session.pointer)).decode(UVCCapabilities.self)
        try attachment.validate(registryID: capabilities.registryID, bootSessionID: capabilities.bootSessionID)
        return capabilities
    }
    public func set(_ position: GimbalPosition, permit: OperationPermit? = nil) throws {
        try Task.checkCancellation()
        if attachment.registryID == nil { _ = try status() }
        let session = try openedSession()
        try Task.checkCancellation()
        try lifetimePermit.perform {
            if let permit {
                _ = try permit.perform { try Self.consume(p3_uvc_session_set_position(session.pointer, position.pan, position.tilt)) }
            } else { _ = try Self.consume(p3_uvc_session_set_position(session.pointer, position.pan, position.tilt)) }
        }
    }
    public static func devices() throws -> JSONValue { try consume(p3_uvc_devices()) }
    public static func streamInterfaces(location: UInt32) throws -> JSONValue {
        try consume(p3_uvc_stream_interfaces(location))
    }
    public static func streamOpenDiagnostic(location: UInt32) throws -> JSONValue {
        try consume(p3_uvc_stream_open_diagnostic(location))
    }

    public func zoomStatus() throws -> USBZoomCapabilities {
        guard lifetimePermit.isValid else { throw BridgeFailure("uvc_connection_closed", "USB 控制連線已結束") }
        let opened = try openedSession()
        let result = try Self.consume(p3_uvc_session_zoom_status(opened.pointer)).decode(USBZoomCapabilities.self)
        guard lifetimePermit.isValid else { throw BridgeFailure("uvc_connection_closed", "USB 控制連線已結束") }
        return result
    }

    public func rollStatus() throws -> USBRollCapabilities {
        guard lifetimePermit.isValid else { throw BridgeFailure("uvc_connection_closed", "USB 控制連線已結束") }
        let opened = try openedSession()
        let result = try Self.consume(p3_uvc_session_roll_status(opened.pointer)).decode(USBRollCapabilities.self)
        guard lifetimePermit.isValid else { throw BridgeFailure("uvc_connection_closed", "USB 控制連線已結束") }
        return result
    }

    public func setRoll(rawValue: Int, validUntil: TimeInterval, permit: OperationPermit,
                        connectionPermit: OperationPermit? = nil) throws {
        try Task.checkCancellation()
        guard lifetimePermit.isValid else { throw BridgeFailure("uvc_connection_closed", "USB 控制連線已結束") }
        guard (-32768...32767).contains(rawValue) else { throw BridgeFailure("invalid_roll_value", "USB Roll 原始值須為 signed16 整數") }
        let opened = try openedSession()
        let write = {
            try self.lifetimePermit.perform {
                try permit.perform {
                    guard validUntil.isFinite, ProcessInfo.processInfo.systemUptime <= validUntil else {
                        throw BridgeFailure("roll_timing", "Roll 請求已過期，沒有送出 USB 指令")
                    }
                    return try Self.consume(p3_uvc_session_set_roll(opened.pointer, Int32(rawValue)))
                }
            }
        }
        if let connectionPermit { _ = try connectionPermit.perform(write) }
        else { _ = try write() }
    }

    public func setZoom(rawValue: Int, validUntil: TimeInterval, permit: OperationPermit,
                        connectionPermit: OperationPermit? = nil) throws {
        try Task.checkCancellation()
        guard lifetimePermit.isValid else { throw BridgeFailure("uvc_connection_closed", "USB 控制連線已結束") }
        guard (0...65535).contains(rawValue) else { throw BridgeFailure("invalid_zoom_value", "USB 縮放原始值須為 0–65535") }
        let opened = try openedSession()
        let write = {
            try self.lifetimePermit.perform {
                try permit.perform {
                    guard validUntil.isFinite, ProcessInfo.processInfo.systemUptime <= validUntil else {
                        throw BridgeFailure("zoom_timing", "縮放請求已過期，沒有送出 USB 指令")
                    }
                    return try Self.consume(p3_uvc_session_set_zoom(opened.pointer, UInt32(rawValue)))
                }
            }
        }
        if let connectionPermit { _ = try connectionPermit.perform(write) }
        else { _ = try write() }
    }

    /// Complete two-axis target. Used by bounded trajectory validation; unlike
    /// set(), this path does not perform a GET_CUR before each SET_CUR.
    func setFast(_ position: GimbalPosition, validUntil: TimeInterval, permit: OperationPermit,
                 connectionPermit: OperationPermit? = nil) throws {
        try Task.checkCancellation()
        if attachment.registryID == nil { _ = try status() }
        let session = try openedSession()
        let write = {
            try self.lifetimePermit.perform {
                try permit.perform {
                    guard validUntil.isFinite, ProcessInfo.processInfo.systemUptime <= validUntil else {
                        throw BridgeFailure("trajectory_timing", "位置目標已過期，沒有送出 USB 指令")
                    }
                    return try Self.consume(p3_uvc_session_set_position_fast(session.pointer, position.pan, position.tilt))
                }
            }
        }
        if let connectionPermit { _ = try connectionPermit.perform(write) }
        else { _ = try write() }
    }
}

public enum MotionPolicy {
    public static let maxStep: Int32 = 3600
    public static let readbackTolerance: Int64 = 720
    public static func target(direction: String, origin: GimbalPosition, capabilities: UVCCapabilities) throws -> GimbalPosition {
        guard capabilities.writable, let min = capabilities.minimum, let max = capabilities.maximum else { throw BridgeFailure("unsupported", "裝置尚未提供可用的移動範圍") }
        guard origin.pan >= min.pan, origin.pan <= max.pan, origin.tilt >= min.tilt, origin.tilt <= max.tilt else { throw BridgeFailure("invalid_readback", "USB 目前位置超出裝置宣告的範圍") }
        var pan = Int64(origin.pan), tilt = Int64(origin.tilt)
        switch direction {
        case "left": pan -= Int64(maxStep)
        case "right": pan += Int64(maxStep)
        case "up": tilt += Int64(maxStep)
        case "down": tilt -= Int64(maxStep)
        default: throw BridgeFailure("invalid_direction", "方向須為 left、right、up 或 down")
        }
        guard pan >= Int64(min.pan), pan <= Int64(max.pan), tilt >= Int64(min.tilt), tilt <= Int64(max.tilt) else { throw BridgeFailure("limit_reached", "已到達目前允許的移動範圍") }
        return GimbalPosition(pan: Int32(pan), tilt: Int32(tilt))
    }
}
