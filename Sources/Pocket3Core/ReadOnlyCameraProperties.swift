import Foundation

// These types model only the capture-confirmed fields documented in
// research/2026-09-08/camera-settings/docs/CAMERA_SETTINGS_PROTOCOL.md.  Every
// readback keeps the complete property value so an unknown future enum is
// visible to callers without being guessed as a known value.

public enum CameraVideoResolution: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case p1080 = 0x0A
    case p2_7K = 0x2D
    case p4K = 0x10
    case square1080 = 0x69
    case square2160 = 0x6A
    case square3K = 0x6B
    case portrait1080 = 0x42
    case portrait2_7K = 0x43
    case portrait3K = 0x6C
}

public enum CameraFrameRate: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case fps24 = 0x01
    case fps25 = 0x02
    case fps30 = 0x03
    case fps48 = 0x04
    case fps50 = 0x05
    case fps60 = 0x06
    case fps120 = 0x07
    case fps240 = 0x08
}

public enum CameraVideoCompression: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case h264Compatibility = 0x00
    case hevcEfficiency = 0x01
}

public enum CameraSensorAspectRatio: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case landscape = 0x00
    case portrait = 0x01
}

public enum CameraColorProfile: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case normal = 0x00
    case hlg = 0x3C
    case dLogM = 0x3D
}

public enum CameraPhotoFrame: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case sixteenByNine = 0x01
    case oneByOne = 0x03
}

public enum CameraPhotoFormat: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case jpeg = 0x01
    case jpegAndRaw = 0x02
}

public enum CameraPhotoCountdown: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case off = 0x00
    case seconds3 = 0x03
    case seconds5 = 0x05
    case seconds7 = 0x07
}

public enum CameraTimelapseOutput: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case video = 0x00
    case jpegAndVideo = 0x02
    case rawAndVideo = 0x03
}

public enum CameraHyperlapseSpeed: UInt16, Codable, Sendable, Equatable, CaseIterable {
    case auto = 0x00
    case x2 = 0x02
    case x5 = 0x05
    case x10 = 0x0A
    case x15 = 0x0F
    case x30 = 0x1E
}

public enum CameraMotionlapseDirection: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case custom = 0x00
    case leftToRight = 0x01
    case rightToLeft = 0x02
}

public enum CameraPanoramaType: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case degrees180 = 0x05
    case grid3x3 = 0x07
}

public enum CameraPanoramaPhotoFormat: UInt8, Codable, Sendable, Equatable, CaseIterable {
    case raw = 0x01
    case jpeg = 0x03
}

public struct CameraVideoParameters: Codable, Sendable, Equatable {
    public let resolution: CameraVideoResolution?
    public let frameRate: CameraFrameRate?
    public let compression: CameraVideoCompression?
    public let resolutionRaw: UInt8
    public let frameRateRaw: UInt8
    public let compressionRaw: UInt8
    public let raw: Data

    public init(raw: Data, resolutionRaw: UInt8, frameRateRaw: UInt8, compressionRaw: UInt8,
                resolution: CameraVideoResolution? = nil, frameRate: CameraFrameRate? = nil,
                compression: CameraVideoCompression? = nil) {
        self.raw = raw
        self.resolutionRaw = resolutionRaw
        self.frameRateRaw = frameRateRaw
        self.compressionRaw = compressionRaw
        self.resolution = resolution
        self.frameRate = frameRate
        self.compression = compression
    }
}

public struct CameraSensorAspectRatioReadback: Codable, Sendable, Equatable {
    public let aspectRatio: CameraSensorAspectRatio?
    public let rawValue: UInt8
    public let raw: Data

    public init(raw: Data, rawValue: UInt8, aspectRatio: CameraSensorAspectRatio? = nil) {
        self.raw = raw
        self.rawValue = rawValue
        self.aspectRatio = aspectRatio
    }

    public var orientation: CameraSensorAspectRatio? { aspectRatio }
}

public struct CameraImageEffectReadback: Codable, Sendable, Equatable {
    public let colorProfile: CameraColorProfile?
    public let colorRaw: UInt8
    public let whiteBalance: CameraWhiteBalance?
    public let whiteBalanceRaw: UInt8
    public let whiteBalanceKelvinRaw: UInt8?
    public let raw: Data

    public init(raw: Data, colorRaw: UInt8, whiteBalanceRaw: UInt8,
                whiteBalanceKelvinRaw: UInt8? = nil,
                colorProfile: CameraColorProfile? = nil,
                whiteBalance: CameraWhiteBalance? = nil) {
        self.raw = raw
        self.colorRaw = colorRaw
        self.whiteBalanceRaw = whiteBalanceRaw
        self.whiteBalanceKelvinRaw = whiteBalanceKelvinRaw
        self.colorProfile = colorProfile
        self.whiteBalance = whiteBalance
    }
}

public struct CameraExposureParameters: Codable, Sendable, Equatable {
    public let evThirdStops: Int?
    public let evRaw: UInt8
    public let exposureMode: CameraExposureMode?
    public let exposureModeRaw: UInt8
    public let effectiveISO: UInt32
    public let raw: Data

    public init(raw: Data, evRaw: UInt8, exposureModeRaw: UInt8, effectiveISO: UInt32,
                evThirdStops: Int? = nil, exposureMode: CameraExposureMode? = nil) {
        self.raw = raw
        self.evRaw = evRaw
        self.exposureModeRaw = exposureModeRaw
        self.effectiveISO = effectiveISO
        self.evThirdStops = evThirdStops
        self.exposureMode = exposureMode
    }
}

public struct CameraLensStateReadback: Codable, Sendable, Equatable {
    public let focusMode: CameraFocusMode?
    public let focusModeRaw: UInt8
    public let raw: Data

    public init(raw: Data, focusModeRaw: UInt8, focusMode: CameraFocusMode? = nil) {
        self.raw = raw
        self.focusModeRaw = focusModeRaw
        self.focusMode = focusMode
    }
}

public struct CameraPhotoParameters: Codable, Sendable, Equatable {
    public let frame: CameraPhotoFrame?
    public let frameRaw: UInt8
    public let format: CameraPhotoFormat?
    public let formatRaw: UInt8
    public let countdown: CameraPhotoCountdown?
    public let countdownRaw: UInt8
    public let raw: Data

    public init(raw: Data, frameRaw: UInt8, formatRaw: UInt8, countdownRaw: UInt8,
                frame: CameraPhotoFrame? = nil, format: CameraPhotoFormat? = nil,
                countdown: CameraPhotoCountdown? = nil) {
        self.raw = raw
        self.frameRaw = frameRaw
        self.formatRaw = formatRaw
        self.countdownRaw = countdownRaw
        self.frame = frame
        self.format = format
        self.countdown = countdown
    }
}

public struct CameraLapseParameters: Codable, Sendable, Equatable {
    public let output: CameraTimelapseOutput?
    public let outputRaw: UInt8
    public let intervalTenths: UInt16
    public let durationSeconds: UInt32
    public let hyperlapseSpeed: CameraHyperlapseSpeed?
    public let hyperlapseSpeedRaw: UInt16
    public let mirroredHyperlapseSpeedRaw: UInt16
    public let raw: Data

    public init(raw: Data, outputRaw: UInt8, intervalTenths: UInt16, durationSeconds: UInt32,
                hyperlapseSpeedRaw: UInt16, mirroredHyperlapseSpeedRaw: UInt16,
                output: CameraTimelapseOutput? = nil,
                hyperlapseSpeed: CameraHyperlapseSpeed? = nil) {
        self.raw = raw
        self.outputRaw = outputRaw
        self.intervalTenths = intervalTenths
        self.durationSeconds = durationSeconds
        self.hyperlapseSpeedRaw = hyperlapseSpeedRaw
        self.mirroredHyperlapseSpeedRaw = mirroredHyperlapseSpeedRaw
        self.output = output
        self.hyperlapseSpeed = hyperlapseSpeed
    }

    public var timelapseOutput: CameraTimelapseOutput? { output }
}

public struct CameraMotionlapseParameters: Codable, Sendable, Equatable {
    public let direction: CameraMotionlapseDirection?
    public let directionRaw: UInt8
    public let previewActive: Bool?
    public let previewActiveRaw: UInt8
    public let waypointCount: UInt8?
    public let waypointCountRaw: UInt8
    public let raw: Data

    public init(raw: Data, directionRaw: UInt8, previewActiveRaw: UInt8, waypointCountRaw: UInt8,
                direction: CameraMotionlapseDirection? = nil,
                previewActive: Bool? = nil, waypointCount: UInt8? = nil) {
        self.raw = raw
        self.directionRaw = directionRaw
        self.previewActiveRaw = previewActiveRaw
        self.waypointCountRaw = waypointCountRaw
        self.direction = direction
        self.previewActive = previewActive
        self.waypointCount = waypointCount
    }

    public var motionlapseDirection: CameraMotionlapseDirection? { direction }
    public var motionlapsePreviewActive: Bool? { previewActive }
    public var motionlapseWaypointCount: UInt8? { waypointCount }
}

public struct CameraPanoramaParameters: Codable, Sendable, Equatable {
    public let panoramaType: CameraPanoramaType?
    public let panoramaTypeRaw: UInt8
    public let photoFormat: CameraPanoramaPhotoFormat?
    public let photoFormatRaw: UInt8
    public let raw: Data

    public init(raw: Data, panoramaTypeRaw: UInt8, photoFormatRaw: UInt8,
                panoramaType: CameraPanoramaType? = nil,
                photoFormat: CameraPanoramaPhotoFormat? = nil) {
        self.raw = raw
        self.panoramaTypeRaw = panoramaTypeRaw
        self.photoFormatRaw = photoFormatRaw
        self.panoramaType = panoramaType
        self.photoFormat = photoFormat
    }

    public var type: CameraPanoramaType? { panoramaType }
}

// Wire-oriented aliases keep the public vocabulary close to the property
// names used by the capture notes while the longer names remain the canonical
// API used by the decoder.
public typealias CameraVideoParam = CameraVideoParameters
public typealias CameraVideoReadback = CameraVideoParameters
public typealias CameraSensorAspectRatioValue = CameraSensorAspectRatioReadback
public typealias CameraSensorAspectReadback = CameraSensorAspectRatioReadback
public typealias CameraPhotoParam = CameraPhotoParameters
public typealias CameraPhotoReadback = CameraPhotoParameters
public typealias CameraLapseParam = CameraLapseParameters
public typealias CameraLapseReadback = CameraLapseParameters
public typealias CameraMotionlapseParams = CameraMotionlapseParameters
public typealias CameraMotionlapseReadback = CameraMotionlapseParameters
public typealias CameraPanoParams = CameraPanoramaParameters
public typealias CameraPanoReadback = CameraPanoramaParameters

/// Typed values from the read-only 00/99 named-property bus.  The associated
/// payload structs retain every byte received from the camera, including
/// bytes whose enum values are not known by this build.
public enum CameraReadOnlyValue: Codable, Sendable, Equatable {
    case videoParameters(CameraVideoParameters)
    case sensorAspectRatio(CameraSensorAspectRatioReadback)
    case imageEffect(CameraImageEffectReadback)
    case exposure(CameraExposureParameters)
    case lensState(CameraLensStateReadback)
    case photoParameters(CameraPhotoParameters)
    case lapseParameters(CameraLapseParameters)
    case motionlapseParameters(CameraMotionlapseParameters)
    case panoramaParameters(CameraPanoramaParameters)

    public var property: CameraSettingsProperty {
        switch self {
        case .videoParameters: .videoParameters
        case .sensorAspectRatio: .sensorAspectRatio
        case .imageEffect: .imageEffect
        case .exposure: .exposure
        case .lensState: .lensState
        case .photoParameters: .photoParameters
        case .lapseParameters: .lapseParameters
        case .motionlapseParameters: .motionlapseParameters
        case .panoramaParameters: .panoramaParameters
        }
    }

    public var raw: Data {
        switch self {
        case .videoParameters(let value): value.raw
        case .sensorAspectRatio(let value): value.raw
        case .imageEffect(let value): value.raw
        case .exposure(let value): value.raw
        case .lensState(let value): value.raw
        case .photoParameters(let value): value.raw
        case .lapseParameters(let value): value.raw
        case .motionlapseParameters(let value): value.raw
        case .panoramaParameters(let value): value.raw
        }
    }

    // Short aliases keep call sites readable without making the wire property
    // names part of the writer API.
    public static func video(_ value: CameraVideoParameters) -> Self { .videoParameters(value) }
    public static func sensor(_ value: CameraSensorAspectRatioReadback) -> Self { .sensorAspectRatio(value) }
    public static func photo(_ value: CameraPhotoParameters) -> Self { .photoParameters(value) }
    public static func lapse(_ value: CameraLapseParameters) -> Self { .lapseParameters(value) }
    public static func motionlapse(_ value: CameraMotionlapseParameters) -> Self { .motionlapseParameters(value) }
    public static func pano(_ value: CameraPanoramaParameters) -> Self { .panoramaParameters(value) }
}

/// Decodes the capture-confirmed offsets for one allowlisted property.  A
/// valid-length value with an unknown enum is still returned with its raw code
/// and a nil typed enum.  A value shorter than the capture-confirmed minimum
/// is rejected because indexed fields would otherwise be fabricated.
public enum CameraReadOnlyPropertyDecoder {
    public static func decode(_ property: CameraSettingsProperty, value: Data) -> CameraReadOnlyValue? {
        guard value.count <= DUMLCodec.maximumPayloadLength else { return nil }
        let bytes = Array(value)
        switch property {
        case .videoParameters:
            guard bytes.count >= 9 else { return nil }
            return .videoParameters(CameraVideoParameters(raw: value,
                resolutionRaw: bytes[0], frameRateRaw: bytes[1], compressionRaw: bytes[8],
                resolution: CameraVideoResolution(rawValue: bytes[0]),
                frameRate: CameraFrameRate(rawValue: bytes[1]),
                compression: CameraVideoCompression(rawValue: bytes[8])))

        case .sensorAspectRatio:
            guard bytes.count >= 1 else { return nil }
            return .sensorAspectRatio(CameraSensorAspectRatioReadback(raw: value,
                rawValue: bytes[0], aspectRatio: CameraSensorAspectRatio(rawValue: bytes[0])))

        case .imageEffect:
            guard bytes.count >= 6 else { return nil }
            let balance: CameraWhiteBalance?
            let kelvinRaw: UInt8?
            switch bytes[4] {
            case 0x00:
                balance = .automatic; kelvinRaw = nil
            case 0x06:
                let kelvin = Int(bytes[5]) * 100
                balance = (2000...10000).contains(kelvin) ? .customKelvin(kelvin) : nil
                kelvinRaw = bytes[5]
            default:
                balance = nil; kelvinRaw = nil
            }
            return .imageEffect(CameraImageEffectReadback(raw: value,
                colorRaw: bytes[2], whiteBalanceRaw: bytes[4], whiteBalanceKelvinRaw: kelvinRaw,
                colorProfile: CameraColorProfile(rawValue: bytes[2]), whiteBalance: balance))

        case .exposure:
            guard bytes.count >= 20 else { return nil }
            let evRaw = bytes[6]
            let ev = (0x07...0x19).contains(evRaw) ? Int(evRaw) - 0x10 : nil
            let modeRaw = bytes[7]
            return .exposure(CameraExposureParameters(raw: value,
                evRaw: evRaw, exposureModeRaw: modeRaw, effectiveISO: u32LE(bytes, at: 16),
                evThirdStops: ev, exposureMode: CameraExposureMode(rawValue: modeRaw)))

        case .lensState:
            guard bytes.count >= 1 else { return nil }
            let focus: CameraFocusMode? = switch bytes[0] {
            case 0xB1: .single
            case 0xB2: .continuous
            default: nil
            }
            return .lensState(CameraLensStateReadback(raw: value, focusModeRaw: bytes[0],
                focusMode: focus))

        case .photoParameters:
            guard bytes.count >= 13 else { return nil }
            return .photoParameters(CameraPhotoParameters(raw: value,
                frameRaw: bytes[1], formatRaw: bytes[3], countdownRaw: bytes[7],
                frame: CameraPhotoFrame(rawValue: bytes[1]),
                format: CameraPhotoFormat(rawValue: bytes[3]),
                countdown: CameraPhotoCountdown(rawValue: bytes[7])))

        case .lapseParameters:
            guard bytes.count >= 21 else { return nil }
            let speed = u16LE(bytes, at: 9)
            let mirror = u16LE(bytes, at: 11)
            let typedSpeed = speed == mirror ? CameraHyperlapseSpeed(rawValue: speed) : nil
            return .lapseParameters(CameraLapseParameters(raw: value,
                outputRaw: bytes[0], intervalTenths: u16LE(bytes, at: 1),
                durationSeconds: u32LE(bytes, at: 5), hyperlapseSpeedRaw: speed,
                mirroredHyperlapseSpeedRaw: mirror,
                output: CameraTimelapseOutput(rawValue: bytes[0]), hyperlapseSpeed: typedSpeed))

        case .motionlapseParameters:
            guard bytes.count >= 8 else { return nil }
            let directionRaw = bytes[2]
            let direction = CameraMotionlapseDirection(rawValue: directionRaw)
            let previewRaw = bytes[3]
            let preview: Bool?
            switch previewRaw {
            case 0x00: preview = false
            case 0x80: preview = true
            default: preview = nil
            }
            let countRaw = bytes[7]
            let count = direction == .custom && countRaw <= 4 ? countRaw : nil
            return .motionlapseParameters(CameraMotionlapseParameters(raw: value,
                directionRaw: directionRaw, previewActiveRaw: previewRaw, waypointCountRaw: countRaw,
                direction: direction, previewActive: preview, waypointCount: count))

        case .panoramaParameters:
            guard bytes.count >= 3 else { return nil }
            return .panoramaParameters(CameraPanoramaParameters(raw: value,
                panoramaTypeRaw: bytes[0], photoFormatRaw: bytes[1],
                panoramaType: CameraPanoramaType(rawValue: bytes[0]),
                photoFormat: CameraPanoramaPhotoFormat(rawValue: bytes[1])))
        }
    }
}

private func u16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private func u32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
        UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
}
