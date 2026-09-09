import CoreVideo
import CoreImage
import ImageIO
import Foundation

extension FramePacket {
    /// Bounded image import for repeatable local evaluation. It never opens a
    /// camera or follows image metadata as a file or network instruction.
    public static func fixture(at url: URL) throws -> FramePacket {
        let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard properties.isRegularFile == true, (properties.fileSize ?? .max) <= 8_000_000 else { throw BridgeFailure("fixture_size", "評測圖片必須是 8 MB 以下的檔案") }
        return try fixture(data: Data(contentsOf: url))
    }
    public static func fixture(data: Data) throws -> FramePacket {
        guard data.count <= 8_000_000 else { throw BridgeFailure("fixture_size", "評測圖片不得超過 8 MB") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1920] as CFDictionary) else { throw BridgeFailure("fixture_image", "無法解碼評測圖片") }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer else { throw BridgeFailure("fixture_memory", "無法建立評測影格") }
        CIContext(options: [.cacheIntermediates: false]).render(CIImage(cgImage: image), to: buffer)
        let id = UUID().uuidString
        var info = FrameInfo(id: id, sessionID: "fixture-" + id, deviceID: "local-evaluation", receivedAt: Date(), receivedUptime: ProcessInfo.processInfo.systemUptime, presentationTime: 0, width: image.width, height: image.height)
        info.timestampSource = "local_image_import"
        return FramePacket(pixelBuffer: buffer, info: info)
    }
}
