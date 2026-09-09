import Foundation

/// App-defined absolute UVC targets. These are neither DJI joystick commands
/// nor calibrated physical camera coordinates. Reaching a target still needs
/// the normal serialized, cancellable movement and readback verification.
public enum GimbalNavigationPolicy {
    private static let arcSecondsPerDegree = 3600.0
    private static let halfTurn: Int64 = 180 * 3600

    public static func absolute(
        panDegrees: Double? = nil, tiltDegrees: Double? = nil,
        origin: GimbalPosition, capabilities: UVCCapabilities
    ) throws -> GimbalPosition {
        guard panDegrees != nil || tiltDegrees != nil else {
            throw BridgeFailure("invalid_target", "請指定至少一個 USB 目標角度")
        }
        let (minimum, maximum) = try bounds(capabilities)
        let pan = try panDegrees.map { try units($0, minimum: minimum.pan, maximum: maximum.pan) } ?? origin.pan
        let tilt = try tiltDegrees.map { try units($0, minimum: minimum.tilt, maximum: maximum.tilt) } ?? origin.tilt
        // An explicitly supplied target can recover an out-of-range readback.
        // Omitted axes retain their current value and must also be in range.
        return try checked(.init(pan: pan, tilt: tilt), minimum: minimum, maximum: maximum)
    }

    public static func home(capabilities: UVCCapabilities) throws -> GimbalPosition {
        let (minimum, maximum) = try bounds(capabilities)
        guard let target = capabilities.defaultPosition else {
            throw BridgeFailure("default_unavailable", "裝置沒有提供 USB 預設位置")
        }
        return try checked(target, minimum: minimum, maximum: maximum)
    }

    public static func front(capabilities: UVCCapabilities) throws -> GimbalPosition {
        try home(capabilities: capabilities)
    }

    public static func back(capabilities: UVCCapabilities) throws -> GimbalPosition {
        let front = try home(capabilities: capabilities)
        let (minimum, maximum) = try bounds(capabilities)
        // Prefer the same target on every call, independent of current pose.
        // If both fit, numeric proximity is not proof of a valid shorter
        // mechanical path. The App must validate these presets on the device.
        for delta in [halfTurn, -halfTurn] {
            let pan = Int64(front.pan) + delta
            if pan >= Int64(minimum.pan), pan <= Int64(maximum.pan) {
                return GimbalPosition(pan: Int32(pan), tilt: front.tilt)
            }
        }
        throw BridgeFailure("preset_unavailable", "USB 宣告範圍內沒有相隔 180 度的後方目標")
    }

    public static func preset(named name: String, capabilities: UVCCapabilities) throws -> GimbalPosition {
        switch name {
        case "home": try home(capabilities: capabilities)
        case "front": try front(capabilities: capabilities)
        case "back": try back(capabilities: capabilities)
        default: throw BridgeFailure("invalid_preset", "位置須為 home、front 或 back")
        }
    }

    private static func bounds(_ capabilities: UVCCapabilities) throws -> (GimbalPosition, GimbalPosition) {
        guard capabilities.writable, let minimum = capabilities.minimum, let maximum = capabilities.maximum,
              minimum.pan <= maximum.pan, minimum.tilt <= maximum.tilt else {
            throw BridgeFailure("unsupported", "裝置尚未提供有效的 USB 移動範圍")
        }
        return (minimum, maximum)
    }

    private static func units(_ degrees: Double, minimum: Int32, maximum: Int32) throws -> Int32 {
        let scaled = degrees * arcSecondsPerDegree
        guard degrees.isFinite, scaled.isFinite else {
            throw BridgeFailure("invalid_target", "USB 目標角度須為有限數值")
        }
        // Both bounds originate as Int32. Check in Double before either integer
        // conversion, so huge inputs cannot trap and outside values never clamp.
        guard scaled >= Double(minimum), scaled <= Double(maximum) else {
            throw BridgeFailure("limit_reached", "目標超出裝置宣告的 USB 移動範圍")
        }
        let rounded = Int64(scaled.rounded(.toNearestOrAwayFromZero))
        guard rounded >= Int64(minimum), rounded <= Int64(maximum) else {
            throw BridgeFailure("limit_reached", "目標超出裝置宣告的 USB 移動範圍")
        }
        return Int32(rounded)
    }

    private static func checked(_ target: GimbalPosition, minimum: GimbalPosition, maximum: GimbalPosition) throws -> GimbalPosition {
        guard target.pan >= minimum.pan, target.pan <= maximum.pan,
              target.tilt >= minimum.tilt, target.tilt <= maximum.tilt else {
            throw BridgeFailure("limit_reached", "目標超出裝置宣告的 USB 移動範圍")
        }
        return target
    }
}
