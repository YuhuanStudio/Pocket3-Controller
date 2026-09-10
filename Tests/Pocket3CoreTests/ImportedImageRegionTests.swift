import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Pocket3Core

private let roiQuadrantColors: [[UInt8]] = [
    [0, 0, 255, 255], [0, 255, 0, 255], // BGRA red / green, top row
    [255, 0, 0, 255], [0, 255, 255, 255] // blue / yellow, bottom row
]

private func roiFrame(width: Int = 8, height: Int = 8, video: Bool = false) throws -> FramePacket {
    var output: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
        &output) == kCVReturnSuccess, let output else { throw BridgeFailure("fixture", "Pixel allocation failed") }
    CVPixelBufferLockBaseAddress(output, [])
    defer { CVPixelBufferUnlockBaseAddress(output, []) }
    let bytes = try #require(CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self))
    let stride = CVPixelBufferGetBytesPerRow(output)
    for y in 0..<height { for x in 0..<width {
        let color = roiQuadrantColors[(y >= height / 2 ? 2 : 0) + (x >= width / 2 ? 1 : 0)]
        for channel in 0..<4 { bytes[y * stride + x * 4 + channel] = color[channel] }
    } }
    var info = FrameInfo(id: "source-frame", sessionID: "import-session", deviceID: "local-evaluation",
        receivedAt: Date(timeIntervalSince1970: 1234), receivedUptime: 5678, presentationTime: video ? 2.375 : 0,
        width: width, height: height)
    info.timestampSource = video ? "local_video_import" : "local_image_import"
    return FramePacket(pixelBuffer: output, info: info)
}

private func roiPixel(_ frame: FramePacket, x: Int, y: Int) throws -> [UInt8] {
    CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly) }
    let bytes = try #require(CVPixelBufferGetBaseAddress(frame.pixelBuffer)?.assumingMemoryBound(to: UInt8.self))
    let start = y * CVPixelBufferGetBytesPerRow(frame.pixelBuffer) + x * 4
    return (0..<4).map { bytes[start + $0] }
}

@Suite struct ImportedImageRegionTests {
    @Test func allFourColoredQuadrantsUseTopLeftCoordinatesWithoutFlipping() throws {
        let source = try roiFrame()
        for (index, origin) in [(0, CGPoint(x: 0, y: 0)), (1, CGPoint(x: 0.5, y: 0)),
                                (2, CGPoint(x: 0, y: 0.5)), (3, CGPoint(x: 0.5, y: 0.5))] {
            let region = try NormalizedImageRegion(x: Double(origin.x), y: Double(origin.y), width: 0.5, height: 0.5)
            let crop = try source.cropImported(to: region)
            #expect(crop.frame.info.width == 4 && crop.frame.info.height == 4)
            #expect(crop.region == region)
            for y in 0..<4 { for x in 0..<4 { #expect(try roiPixel(crop.frame, x: x, y: y) == roiQuadrantColors[index]) } }
        }
        #expect(try roiPixel(source, x: 0, y: 0) == roiQuadrantColors[0]) // Source is unchanged.
        #expect(try roiPixel(source, x: 7, y: 7) == roiQuadrantColors[3])
    }

    @Test func fractionalRegionReportsActualCoveringPixelsAndMapsMarker() throws {
        let source = try roiFrame()
        let crop = try source.cropImported(to: .init(x: 0.2, y: 0.1, width: 0.35, height: 0.45))
        // floor(1.6, 0.8) .. ceil(4.4, 4.4) -> x1..5, y0..5.
        #expect(crop.frame.info.width == 4 && crop.frame.info.height == 5)
        #expect(crop.region == (try .init(x: 0.125, y: 0, width: 0.5, height: 0.625)))
        #expect(try roiPixel(crop.frame, x: 0, y: 0) == roiQuadrantColors[0])
        #expect(try roiPixel(crop.frame, x: 3, y: 0) == roiQuadrantColors[1])
        #expect(try roiPixel(crop.frame, x: 0, y: 4) == roiQuadrantColors[2])
        #expect(try roiPixel(crop.frame, x: 3, y: 4) == roiQuadrantColors[3])
        #expect(try crop.region.mapToOriginal(.init(x: 0.5, y: 0.5)) == .init(x: 0.375, y: 0.3125))
        #expect(try crop.region.mapToOriginal(.init(x: 0, y: 0)) == .init(x: 0.125, y: 0))
        #expect(try crop.region.mapToOriginal(.init(x: 1, y: 1)) == .init(x: 0.625, y: 0.625))
    }

    @Test func videoIdentityTimeAndOriginalProvenanceSurviveNestedCrops() throws {
        let source = try roiFrame(video: true)
        let first = try source.cropImported(to: .init(x: 0.5, y: 0, width: 0.5, height: 1))
        let second = try first.frame.cropImported(to: .init(x: 0, y: 0.5, width: 1, height: 0.5))
        let info = second.frame.info
        #expect(info.id != source.info.id && info.id != first.frame.info.id)
        #expect(info.sessionID == source.info.sessionID && info.deviceID == source.info.deviceID)
        #expect(info.receivedAt == source.info.receivedAt && info.receivedUptime == source.info.receivedUptime)
        #expect(info.presentationTime == 2.375 && info.timestampSource == "local_video_import")
        #expect(info.width == 4 && info.height == 4)
        #expect(info.importedRegion?.sourceFrameID == source.info.id)
        #expect(info.importedRegion?.originalWidth == 8 && info.importedRegion?.originalHeight == 8)
        #expect(second.region == (try .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
        #expect(info.importedRegion?.region == second.region)
        #expect(try second.region.mapToOriginal(.init(x: 0.5, y: 0.5)) == .init(x: 0.75, y: 0.75))
        #expect(try roiPixel(second.frame, x: 0, y: 0) == roiQuadrantColors[3])
    }

    @Test func portraitPixelsAndRightBottomFractionalBoundsRemainValid() throws {
        let source = try roiFrame(width: 6, height: 12)
        let crop = try source.cropImported(to: .init(x: 5.0 / 6.0, y: 0.5, width: 1.0 / 6.0, height: 0.5))
        #expect(crop.frame.info.width == 1 && crop.frame.info.height == 6)
        #expect(try roiPixel(crop.frame, x: 0, y: 0) == roiQuadrantColors[3])
        #expect(try crop.region.mapToOriginal(.init(x: 1, y: 1)) == .init(x: 1, y: 1))
    }

    @Test func invalidRegionsAndDecodedCoordinatesAreRejectedWithoutClamping() throws {
        let invalid: [(Double, Double, Double, Double)] = [
            (-0.01, 0, 0.5, 0.5), (0, -0.01, 0.5, 0.5), (0, 0, 0, 1), (0, 0, 1, 0),
            (0, 0, -1, 1), (0.8, 0, 0.3, 1), (0, 0.9, 1, 0.2), (1, 0, 0.1, 1),
            (.nan, 0, 1, 1), (0, .infinity, 1, 1), (0, 0, .infinity, 1), (0, 0, 1, -.infinity),
            (200, 100, 300, 400)
        ]
        for (x, y, width, height) in invalid {
            #expect(throws: BridgeFailure.self) { try NormalizedImageRegion(x: x, y: y, width: width, height: height) }
        }
        for json in [#"{"x":0,"y":0,"width":0,"height":1}"#,
                     #"{"x":0.8,"y":0,"width":0.3,"height":1}"#] {
            #expect(throws: BridgeFailure.self) { try JSONDecoder().decode(NormalizedImageRegion.self, from: Data(json.utf8)) }
        }
        let region = try NormalizedImageRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        for point in [CGPoint(x: -0.1, y: 0), .init(x: 0, y: 1.1), .init(x: CGFloat.nan, y: 0), .init(x: 500, y: 500)] {
            #expect(throws: BridgeFailure.self) { try region.mapToOriginal(point) }
        }
    }

    @Test func croppingRejectsLiveCameraMismatchedPixelsAndInvalidPriorProvenance() throws {
        let source = try roiFrame()
        let region = try NormalizedImageRegion(x: 0, y: 0, width: 0.5, height: 0.5)
        var camera = source.info; camera.timestampSource = "host_callback_and_avfoundation_pts"; camera.deviceID = "pocket3"
        #expect(throws: BridgeFailure.self) { try FramePacket(pixelBuffer: source.pixelBuffer, info: camera).cropImported(to: region) }
        var mismatched = source.info; mismatched.width = 16
        #expect(throws: BridgeFailure.self) { try FramePacket(pixelBuffer: source.pixelBuffer, info: mismatched).cropImported(to: region) }
        var unrotated = source.info; unrotated.rotationDegrees = 90
        #expect(throws: BridgeFailure.self) { try FramePacket(pixelBuffer: source.pixelBuffer, info: unrotated).cropImported(to: region) }
        var invalid = source.info
        invalid.importedRegion = .init(sourceFrameID: "other", originalWidth: 8, originalHeight: 8, region: region)
        #expect(throws: BridgeFailure.self) { try FramePacket(pixelBuffer: source.pixelBuffer, info: invalid).cropImported(to: region) }
    }

    @Test func legacyFrameJSONAndCropJSONRetainOptionalPathFreeProvenance() throws {
        let original = try roiFrame()
        let encoded = try JSONEncoder().encode(original.info)
        #expect(try JSONDecoder().decode(FrameInfo.self, from: encoded).importedRegion == nil)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("importedRegion"))
        let crop = try original.cropImported(to: .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        let bytes = try JSONEncoder().encode(crop.frame.info)
        let decoded = try JSONDecoder().decode(FrameInfo.self, from: bytes)
        #expect(decoded.importedRegion == crop.frame.info.importedRegion)
        #expect(decoded.sessionID == original.info.sessionID && decoded.id != original.info.id)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("/Users/"))
    }

    @Test func realPNGImportKeepsQuadrantDirectionWhenCropped() throws {
        let source = try roiFrame()
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        let canvas = try #require(context)
        let target = try #require(canvas.data?.assumingMemoryBound(to: UInt8.self))
        for y in 0..<8 { for x in 0..<8 {
            let pixel = try roiPixel(source, x: x, y: y)
            for channel in 0..<4 { target[y * 32 + x * 4 + channel] = pixel[channel] }
        } }
        let image = try #require(canvas.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let imported = try FramePacket.fixture(data: bytes as Data)
        let upperRight = try imported.cropImported(to: .init(x: 0.5, y: 0, width: 0.5, height: 0.5))
        let lowerLeft = try imported.cropImported(to: .init(x: 0, y: 0.5, width: 0.5, height: 0.5))
        #expect(try roiPixel(upperRight.frame, x: 1, y: 1) == roiQuadrantColors[1])
        #expect(try roiPixel(lowerLeft.frame, x: 1, y: 1) == roiQuadrantColors[2])
    }
}
