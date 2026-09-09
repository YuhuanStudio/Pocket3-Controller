import Foundation
@preconcurrency import AVFoundation

/// AVFoundation's camera input representation, before display/JPEG conversion.
public enum CapturePixelFormat: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case automatic, nv12, uyvy

    public var id: String { rawValue }
    public var title: String {
        switch self { case .automatic: "Auto"; case .nv12: "NV12"; case .uyvy: "UYVY" }
    }
    public var mediaSubType: UInt32? {
        switch self {
        case .automatic: nil
        case .nv12: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .uyvy: kCVPixelFormatType_422YpCbCr8
        }
    }
    public var fourCC: String? { mediaSubType.map(Self.fourCCString) }
    public func accepts(mediaSubType: UInt32) -> Bool {
        self.mediaSubType.map { $0 == mediaSubType } ?? true
    }
    public init?(mediaSubType: UInt32) {
        guard let value = Self.allCases.first(where: { $0.mediaSubType == mediaSubType }) else { return nil }
        self = value
    }
    public static func fourCCString(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return String(format: "0x%08x", value) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A video mode advertised by the connected camera. Discovery alone does not
/// establish that the mode can deliver frames over the current USB connection.
public struct CaptureMode: Codable, Hashable, Sendable, Identifiable {
    public let width: Int
    public let height: Int
    public let frameRate: Double

    public init(width: Int, height: Int, frameRate: Double) {
        self.width = width
        self.height = height
        self.frameRate = Self.normalizedFrameRate(frameRate)
    }

    public static let default1080p30 = CaptureMode(width: 1920, height: 1080, frameRate: 30)
    public var id: String { "\(width)x\(height)@\(frameRateLabel)" }
    public var isPortrait: Bool { height > width }
    public var dimensions: String { "\(width) × \(height)" }
    public var frameRateLabel: String {
        // Locale-independent: this string is also part of the persisted mode ID.
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), frameRate)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
    public var compactTitle: String {
        let resolution = width == 3840 && height == 2160 ? "4K" : "\(min(width, height))p"
        return "\(resolution) · \(frameRateLabel) fps"
    }
    public var title: String { "\(dimensions) · \(frameRateLabel) fps" }

    /// AVFoundation's rational durations can expose 30 fps as 30.000030 or
    /// 60 fps as 60.000240. Keep real fractional rates such as 29.97 distinct.
    public static func normalizedFrameRate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return value }
        let thousandth = (value * 1_000).rounded() / 1_000
        if abs(value - thousandth) <= 0.0005 { return thousandth }
        return (value * 1_000_000).rounded() / 1_000_000
    }

    public func supports(minFrameRate: Double, maxFrameRate: Double) -> Bool {
        guard isValid, minFrameRate.isFinite, maxFrameRate.isFinite,
              minFrameRate > 0, maxFrameRate >= minFrameRate else { return false }
        return frameRate >= minFrameRate - 0.001 && frameRate <= maxFrameRate + 0.001
    }

    /// Reads only the exact selected DJI device. No session, permission request,
    /// configuration lock, or USB control write is performed here.
    public static func available(deviceID: String) -> [CaptureMode] {
        uniqueSorted(deviceFormats(deviceID: deviceID).flatMap(modes))
    }

    /// Advertised variants for each resolution/rate, without duplicating mode rows.
    /// Automatic is a selection policy and is never reported as an input variant.
    public static func availableInputFormats(deviceID: String) -> [String: [CapturePixelFormat]] {
        var variants: [String: Set<CapturePixelFormat>] = [:]
        for format in deviceFormats(deviceID: deviceID) {
            guard let pixelFormat = CapturePixelFormat(mediaSubType: CMFormatDescriptionGetMediaSubType(format.formatDescription)) else { continue }
            for mode in modes(format) { variants[mode.id, default: []].insert(pixelFormat) }
        }
        return variants.mapValues { values in [CapturePixelFormat.nv12, .uyvy].filter(values.contains) }
    }

    private static func deviceFormats(deviceID: String) -> [AVCaptureDevice.Format] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        ).devices.first(where: {
            $0.uniqueID == deviceID && $0.modelID.contains("VendorID_11427 ProductID_35")
        })?.formats ?? []
    }

    private static func modes(_ format: AVCaptureDevice.Format) -> [CaptureMode] {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return format.videoSupportedFrameRateRanges.flatMap { range in
            advertisedRates(minimum: range.minFrameRate, maximum: range.maxFrameRate).map {
                CaptureMode(width: Int(dimensions.width), height: Int(dimensions.height), frameRate: $0)
            }
        }
    }

    private var isValid: Bool { width > 0 && height > 0 && frameRate.isFinite && frameRate > 0 }

    /// Fixed-rate ranges contribute their one rate; continuous ranges contribute
    /// their endpoints and standard video rates contained in the advertised range.
    static func advertisedRates(minimum: Double, maximum: Double) -> [Double] {
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else { return [] }
        let standard: [Double] = [15, 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 90, 100, 119.88, 120, 240]
        return Array(Set(([minimum, maximum] + standard.filter {
            $0 >= minimum - 0.0001 && $0 <= maximum + 0.0001
        }).map(normalizedFrameRate))).sorted()
    }

    static func uniqueSorted(_ modes: [CaptureMode]) -> [CaptureMode] {
        Array(Set(modes.filter(\.isValid))).sorted {
            if $0.isPortrait != $1.isPortrait { return !$0.isPortrait }
            if $0.width != $1.width { return $0.width < $1.width }
            if $0.height != $1.height { return $0.height < $1.height }
            return $0.frameRate < $1.frameRate
        }
    }

    private enum CodingKeys: String, CodingKey { case width, height, frameRate }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: try values.decode(Int.self, forKey: .width),
                  height: try values.decode(Int.self, forKey: .height),
                  frameRate: try values.decode(Double.self, forKey: .frameRate))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "A capture mode requires positive dimensions and a finite, positive frame rate."))
        }
    }
}
