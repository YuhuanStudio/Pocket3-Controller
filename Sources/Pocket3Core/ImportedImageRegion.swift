import Foundation
import CoreGraphics
import CoreVideo

/// A positive-area rectangle in normalized top-left image coordinates.
/// Invalid values are rejected at construction and decoding, never clamped.
public struct NormalizedImageRegion: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              x >= 0, y >= 0, width > 0, height > 0,
              x < 1, y < 1, width <= 1, height <= 1, x + width <= 1, y + height <= 1 else {
            throw BridgeFailure("invalid_image_region", "Image region must have positive area wholly within normalized 0–1 coordinates")
        }
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    private enum CodingKeys: String, CodingKey { case x, y, width, height }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: values.decode(Double.self, forKey: .x), y: values.decode(Double.self, forKey: .y),
                      width: values.decode(Double.self, forKey: .width), height: values.decode(Double.self, forKey: .height))
    }
    /// Maps a point reported within this crop back onto its original image.
    public func mapToOriginal(_ point: CGPoint) throws -> CGPoint {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else {
            throw BridgeFailure("invalid_image_point", "Image points must use normalized 0–1 coordinates")
        }
        return CGPoint(x: x + Double(point.x) * width, y: y + Double(point.y) * height)
    }
}

/// Crop provenance contains no file path. The source identity and dimensions
/// refer to the original imported frame, including when a crop is cropped again.
public struct ImportedRegionProvenance: Codable, Sendable, Equatable {
    public let sourceFrameID: String
    public let originalWidth: Int
    public let originalHeight: Int
    public let region: NormalizedImageRegion

    public init(sourceFrameID: String, originalWidth: Int, originalHeight: Int, region: NormalizedImageRegion) {
        self.sourceFrameID = sourceFrameID; self.originalWidth = originalWidth
        self.originalHeight = originalHeight; self.region = region
    }
}

public struct ImportedFrameCrop: Sendable {
    public let frame: FramePacket
    /// Actual covered pixels, normalized against the original imported frame.
    public let region: NormalizedImageRegion
}

extension FrameInfo {
    public var isImportedMedia: Bool {
        deviceID == "local-evaluation" && ["local_image_import", "local_video_import"].contains(timestampSource)
    }
}

extension FramePacket {
    /// Crops existing oriented BGRA pixels without scaling or reinterpretation.
    /// Floor/ceil pixel bounds cover the requested rectangle; returned metadata
    /// records those actual bounds rather than pretending fractional pixels exist.
    public func cropImported(to requested: NormalizedImageRegion) throws -> ImportedFrameCrop {
        try Task.checkCancellation()
        guard info.isImportedMedia, !info.mirrored, info.rotationDegrees == 0 else {
            throw BridgeFailure("image_region_source", "Regions can only be applied to oriented local image or video imports")
        }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, width <= Int.max / 4, info.width == width, info.height == height,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(pixelBuffer) else {
            throw BridgeFailure("image_region_pixels", "Imported frame dimensions and BGRA pixels must agree")
        }
        let left = Int(floor(requested.x * Double(width)))
        let top = Int(floor(requested.y * Double(height)))
        let right = Int(ceil((requested.x + requested.width) * Double(width)))
        let bottom = Int(ceil((requested.y + requested.height) * Double(height)))
        guard left >= 0, top >= 0, right <= width, bottom <= height, right > left, bottom > top else {
            throw BridgeFailure("invalid_image_region", "Image region does not cover valid source pixels")
        }
        let cropWidth = right - left, cropHeight = bottom - top
        let rootWidth: Int, rootHeight: Int, rootLeft: Int, rootTop: Int, sourceFrameID: String
        if let prior = info.importedRegion {
            guard prior.originalWidth > 0, prior.originalHeight > 0, !prior.sourceFrameID.isEmpty else {
                throw BridgeFailure("image_region_provenance", "Imported crop provenance is invalid")
            }
            rootWidth = prior.originalWidth; rootHeight = prior.originalHeight
            // Prior crops are integer-pixel bounds. Recover those integers only
            // after checking that metadata really represents the current pixels.
            let px = prior.region.x * Double(rootWidth), py = prior.region.y * Double(rootHeight)
            let pw = prior.region.width * Double(rootWidth), ph = prior.region.height * Double(rootHeight)
            guard abs(px - px.rounded()) < 0.000001, abs(py - py.rounded()) < 0.000001,
                  abs(pw - Double(width)) < 0.000001, abs(ph - Double(height)) < 0.000001,
                  let originalLeft = Int(exactly: px.rounded()), let originalTop = Int(exactly: py.rounded()),
                  width <= rootWidth, height <= rootHeight,
                  originalLeft >= 0, originalTop >= 0,
                  originalLeft <= rootWidth - width, originalTop <= rootHeight - height else {
                throw BridgeFailure("image_region_provenance", "Crop provenance does not match the imported pixels")
            }
            rootLeft = originalLeft + left; rootTop = originalTop + top
            sourceFrameID = prior.sourceFrameID
        } else {
            rootWidth = width; rootHeight = height; rootLeft = left; rootTop = top; sourceFrameID = info.id
        }
        let actual = try NormalizedImageRegion(x: Double(rootLeft) / Double(rootWidth),
            y: Double(rootTop) / Double(rootHeight), width: Double(cropWidth) / Double(rootWidth),
            height: Double(cropHeight) / Double(rootHeight))
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, cropWidth, cropHeight, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &output) == kCVReturnSuccess,
              let output else { throw BridgeFailure("image_region_memory", "Could not allocate cropped image pixels") }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            throw BridgeFailure("image_region_pixels", "Could not read imported pixels")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else {
            throw BridgeFailure("image_region_pixels", "Could not write cropped pixels")
        }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let source = CVPixelBufferGetBaseAddress(pixelBuffer), let destination = CVPixelBufferGetBaseAddress(output) else {
            throw BridgeFailure("image_region_pixels", "Imported pixel storage is unavailable")
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer), destinationStride = CVPixelBufferGetBytesPerRow(output)
        guard sourceStride >= width * 4, destinationStride >= cropWidth * 4 else {
            throw BridgeFailure("image_region_pixels", "Imported pixel rows are too short")
        }
        destination.initializeMemory(as: UInt8.self, repeating: 0, count: CVPixelBufferGetDataSize(output))
        for row in 0..<cropHeight {
            try Task.checkCancellation()
            destination.advanced(by: row * destinationStride).copyMemory(
                from: source.advanced(by: (top + row) * sourceStride + left * 4), byteCount: cropWidth * 4)
        }
        var metadata = info
        metadata.id = UUID().uuidString
        metadata.width = cropWidth; metadata.height = cropHeight
        metadata.outputPixelFormat = "BGRA"
        metadata.importedRegion = .init(sourceFrameID: sourceFrameID, originalWidth: rootWidth,
            originalHeight: rootHeight, region: actual)
        return ImportedFrameCrop(frame: FramePacket(pixelBuffer: output, info: metadata), region: actual)
    }
}
