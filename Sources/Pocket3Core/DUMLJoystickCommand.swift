import Foundation

public enum DUMLJoystickError: Error, Equatable, Sendable {
    case nonFiniteInput
    case invalidSpeed
}

/// Pocket 3 command 04/01 payload, independently encoded from the pinned Kaze
/// protocol description (341a35de18493ff61f97c93b8b10161a7512aa36).
/// This is a joystick value, not an angular position or calibrated degrees/sec.
/// Sender/receiver addressing is verified in the same pinned DumlTransport.swift
/// sendDuml implementation; see research/2026-09-08/kaze/PROVENANCE.md.
/// The Pocket 3 center/notify/no-ACK shape is cross-checked against
/// OpenPocketCine Commands.swift at 9b30b93572797c94db5ad9236fb746410f8d761f.
/// The conservative default range remains the small BLE probe range. The
/// native UDP product path opts into `encodeNativeUDP`, whose wider range is
/// kept explicit so a BLE probe cannot accidentally become a full-range
/// motion command.
/// This does not include BLE/Wi-Fi routing, fragmentation, or a live connection.
public struct DUMLJoystickCommand: Sendable, Equatable {
    public static let commandSet: UInt8 = 0x04
    public static let commandID: UInt8 = 0x01
    public static let receiverType: UInt8 = 0x04
    public static let receiverInstance: UInt8 = 0
    public static let commandType: UInt8 = 0
    public static let sender: UInt8 = 0x02
    public static let center: UInt16 = 1024
    /// Conservative range used by the fixed BLE probe and legacy callers.
    /// This is a native joystick unit, not degrees or a calibrated physical
    /// speed.
    public static let maximumOffset = 330
    /// Full range reserved for the native UDP product control path.
    public static let nativeUDPMaximumOffset = 550
    public static let deadzone = 0.06

    public let pitch: UInt16
    public let yaw: UInt16
    public static let neutral = Self(pitch: center, yaw: center)
    public var isNeutral: Bool { self == Self.neutral }
    public var payload: Data {
        Data([UInt8(pitch & 0xff), UInt8(pitch >> 8), 0, 0,
              UInt8(yaw & 0xff), UInt8(yaw >> 8), 0, 0x80, 0x22, 0])
    }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.sender, destination: (Self.receiverInstance << 5) | Self.receiverType,
                  sequence: sequence, flags: Self.commandType << 5,
                  commandSet: Self.commandSet, commandID: Self.commandID, payload: payload)
    }
    public func encodedFrame(sequence: UInt16) throws -> Data {
        try DUMLCodec.encode(frame(sequence: sequence))
    }

    /// Screen coordinates: right is +x; down is +y. Values outside the unit
    /// circle are radially clamped. Speed is a normalized scale in 0...1.
    public static func encode(x: Double, y: Double, speed: Double) throws -> Self {
        try encode(x: x, y: y, speed: speed, maximumOffset: maximumOffset)
    }

    /// Encodes the wider center±550 range used by the native UDP product
    /// route. Keeping this opt-in prevents the BLE evidence probe from
    /// silently changing amplitude when the shared value encoder evolves.
    public static func encodeNativeUDP(x: Double, y: Double, speed: Double) throws -> Self {
        try encode(x: x, y: y, speed: speed, maximumOffset: nativeUDPMaximumOffset)
    }

    private static func encode(x: Double, y: Double, speed: Double,
                               maximumOffset: Int) throws -> Self {
        guard x.isFinite, y.isFinite, speed.isFinite else { throw DUMLJoystickError.nonFiniteInput }
        guard (0...1).contains(speed) else { throw DUMLJoystickError.invalidSpeed }
        var horizontal = x, vertical = y
        let scale = max(abs(horizontal), abs(vertical))
        // Scale first so even finite Double.greatestFiniteMagnitude vectors
        // cannot overflow while normalizing a diagonal drag.
        if scale > 1 {
            horizontal /= scale; vertical /= scale
            let length = hypot(horizontal, vertical)
            horizontal /= length; vertical /= length
        }
        var length = hypot(horizontal, vertical)
        if length > 1 { horizontal /= length; vertical /= length; length = 1 }
        guard length > deadzone, speed > 0 else { return .neutral }
        let magnitude = (length - deadzone) / (1 - deadzone) * speed * Double(maximumOffset)
        let yawOffset = Int((horizontal / length * magnitude).rounded())
        let pitchOffset = Int((vertical / length * magnitude).rounded())
        return Self(pitch: UInt16(Int(center) - pitchOffset), yaw: UInt16(Int(center) + yawOffset))
    }
}
