import Foundation

/// Independently implemented from fixed Kaze source/capture facts. See
/// research/2026-09-08/camera-settings/PROVENANCE.md (MIT reference sources).
public enum CameraWhiteBalance: Codable, Sendable, Equatable {
    case automatic
    case customKelvin(Int)
}
public enum CameraFocusMode: UInt8, Codable, Sendable, Equatable {
    case single = 0x01, continuous = 0x02
}
/// Readback only; no exposure-mode writer is exposed by this first settings API.
public enum CameraExposureMode: UInt8, Codable, Sendable, Equatable {
    case automatic = 0x01, manual = 0x04
}
public enum CameraSettingsProperty: String, Codable, Sendable, Hashable, CaseIterable {
    case imageEffect = "cam_image_effect"
    case exposure = "cam_expo_param"
    case lensState = "cam_lens_state"
}
public enum CameraSettingValue: Codable, Sendable, Equatable {
    case whiteBalance(CameraWhiteBalance)
    case focus(CameraFocusMode)
    case autoEV(thirdStops: Int)
    public var property: CameraSettingsProperty {
        switch self {
        case .whiteBalance: .imageEffect
        case .focus: .lensState
        case .autoEV: .exposure
        }
    }
}
public enum CameraSettingsError: Error, Sendable, Equatable {
    case invalidWhiteBalance, invalidEV, invalidTime, invalidSession
    case noFreshBaseline, exposureNotAutomatic, busy, wrongSession
    case unknownRequest, requestExpired, invalidTransition, baselineChanged
}

/// A validated setting request body. Codable decoding also revalidates ranges;
/// malformed JSON cannot bypass construction and reach a narrowing integer cast.
public struct CameraSettingCommand: Codable, Sendable, Equatable {
    public let value: CameraSettingValue
    public init(_ value: CameraSettingValue) throws {
        switch value {
        case .whiteBalance(.customKelvin(let kelvin)):
            guard (2000...10000).contains(kelvin), kelvin.isMultiple(of: 100) else { throw CameraSettingsError.invalidWhiteBalance }
        case .autoEV(let thirds):
            guard (-9...9).contains(thirds) else { throw CameraSettingsError.invalidEV }
        default: break
        }
        self.value = value
    }
    public init(from decoder: Decoder) throws { try self.init(CameraSettingValue(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }

    public static func whiteBalance(kelvin: Double) throws -> Self {
        guard kelvin.isFinite, (2000...10000).contains(kelvin), kelvin.rounded() == kelvin else {
            throw CameraSettingsError.invalidWhiteBalance
        }
        return try Self(.whiteBalance(.customKelvin(Int(kelvin))))
    }
    public static func autoEV(thirdStops: Double) throws -> Self {
        guard thirdStops.isFinite, (-9...9).contains(thirdStops), thirdStops.rounded() == thirdStops else {
            throw CameraSettingsError.invalidEV
        }
        return try Self(.autoEV(thirdStops: Int(thirdStops)))
    }
    public var commandID: UInt8 {
        switch value { case .whiteBalance: 0x2c; case .focus: 0x24; case .autoEV: 0x2e }
    }
    public var payload: Data {
        switch value {
        case .whiteBalance(.automatic): Data([0,0,0,0,0])
        case .whiteBalance(.customKelvin(let kelvin)): Data([6,UInt8(kelvin / 100),0,0,0])
        case .focus(let mode): Data([mode.rawValue])
        case .autoEV(let thirds): Data([UInt8(0x10 + thirds)])
        }
    }
    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: 0x02, destination: 0x01, sequence: sequence, flags: 0x40,
                  commandSet: 0x02, commandID: commandID, payload: payload)
    }
    public func encodedFrame(sequence: UInt16) throws -> Data { try DUMLCodec.encode(frame(sequence: sequence)) }
}
