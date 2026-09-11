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
    case videoParameters = "cam_video_param_v2"
    case sensorAspectRatio = "cam_sensor_aspect_ratio"
    case imageEffect = "cam_image_effect"
    case exposure = "cam_expo_param"
    case lensState = "cam_lens_state"
    case photoParameters = "cam_photo_param"
    case lapseParameters = "cam_lapse_param"
    case motionlapseParameters = "cam_motionlapse_params"
    case panoramaParameters = "cam_pano_params"
}
public enum CameraSettingValue: Codable, Sendable, Equatable {
    case whiteBalance(CameraWhiteBalance)
    case focus(CameraFocusMode)
    case autoEV(thirdStops: Int)
    /// Camera-side recording compression. This is a BLE/native camera setting
    /// and is deliberately kept separate from USB/UVC capture format state.
    case videoCompression(CameraVideoCompression)
    public var property: CameraSettingsProperty {
        switch self {
        case .whiteBalance: .imageEffect
        case .focus: .lensState
        case .autoEV: .exposure
        case .videoCompression: .videoParameters
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
    /// Builds the capture-confirmed 02/AB video-compression command. The
    /// enum already restricts the command to H.264 or HEVC, so this helper is
    /// non-throwing; `try` remains source-compatible for callers that use the
    /// throwing factories for all camera settings.
    public static func videoCompression(_ compression: CameraVideoCompression) -> Self {
        // The enum case has the same base name as this convenience factory;
        // the explicit constructor keeps that distinction clear to Swift.
        Self(videoCompression: compression)
    }

    private init(videoCompression compression: CameraVideoCompression) {
        self.value = .videoCompression(compression)
    }

    /// Compression changes need the complete, freshly decoded named-property
    /// value as a submission baseline. The command only carries the codec
    /// selector, so comparing the full readback prevents a stale resolution,
    /// frame-rate, or reserved-byte snapshot from authorizing the write.
    public var requiresExactVideoParametersBaseline: Bool {
        if case .videoCompression = value { return true }
        return false
    }

    public var commandID: UInt8 {
        switch value {
        case .whiteBalance: 0x2c
        case .focus: 0x24
        case .autoEV: 0x2e
        case .videoCompression: 0xab
        }
    }
    public var payload: Data {
        switch value {
        case .whiteBalance(.automatic): Data([0,0,0,0,0])
        case .whiteBalance(.customKelvin(let kelvin)): Data([6,UInt8(kelvin / 100),0,0,0])
        case .focus(let mode): Data([mode.rawValue])
        case .autoEV(let thirds): Data([UInt8(0x10 + thirds)])
        case .videoCompression(let compression): Data([compression.rawValue, 0x00])
        }
    }
    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: 0x02, destination: 0x01, sequence: sequence, flags: 0x40,
                  commandSet: 0x02, commandID: commandID, payload: payload)
    }
    public func encodedFrame(sequence: UInt16) throws -> Data { try DUMLCodec.encode(frame(sequence: sequence)) }
}
