import CoreVideo
import Foundation

/// Privacy-preserving edge luminance summary. It retains no pixels, image data
/// or coordinates beyond four aggregate fractions. A dark edge is a signal for
/// a possible letterbox/pillarbox, never proof of a camera orientation.
public struct FrameEdgeMetrics: Codable, Sendable, Equatable {
    public let topDarkFraction: Double
    public let bottomDarkFraction: Double
    public let leftDarkFraction: Double
    public let rightDarkFraction: Double
    public let sampledPixelsPerEdge: Int
}

public enum FrameEdgeAnalyzer {
    /// Measures only BGRA buffers. Each edge uses a bounded strip (up to 5% of
    /// the relevant dimension) sampled on an 8-pixel grid. `dark` means all
    /// RGB channels are <=16, deliberately avoiding any content retention.
    public static func measure(_ buffer: CVPixelBuffer) -> FrameEdgeMetrics? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width >= 8, height >= 8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer), step = 8
        let horizontalBand = max(1, min(height / 20, 64)), verticalBand = max(1, min(width / 20, 64))
        func fraction(_ xs: StrideTo<Int>, _ ys: StrideTo<Int>) -> (Double, Int) {
            var dark = 0, total = 0
            for y in ys { for x in xs {
                let pixel = base.advanced(by: y * bytesPerRow + x * 4)
                if pixel[0] <= 16 && pixel[1] <= 16 && pixel[2] <= 16 { dark += 1 }
                total += 1
            }}
            return total > 0 ? (Double(dark) / Double(total), total) : (0, 0)
        }
        let top = fraction(stride(from: 0, to: width, by: step), stride(from: 0, to: horizontalBand, by: step))
        let bottom = fraction(stride(from: 0, to: width, by: step), stride(from: max(0, height - horizontalBand), to: height, by: step))
        let left = fraction(stride(from: 0, to: verticalBand, by: step), stride(from: 0, to: height, by: step))
        let right = fraction(stride(from: max(0, width - verticalBand), to: width, by: step), stride(from: 0, to: height, by: step))
        return FrameEdgeMetrics(topDarkFraction: top.0, bottomDarkFraction: bottom.0,
            leftDarkFraction: left.0, rightDarkFraction: right.0,
            sampledPixelsPerEdge: min(min(top.1, bottom.1), min(left.1, right.1)))
    }
}
