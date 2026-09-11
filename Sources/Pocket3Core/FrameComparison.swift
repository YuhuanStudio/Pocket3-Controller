import CoreVideo
import Foundation

/// Privacy-preserving comparison of two in-memory BGRA frames. It retains no
/// pixels or camera images and makes no claim about scene identity; callers
/// use it as a bounded change signal before requesting a higher-level model.
public struct FrameComparisonMetrics: Codable, Sendable, Equatable {
    public let meanAbsoluteLumaDifference: Double
    public let darkPixelChangeFraction: Double
    public let sampledPixels: Int
}

public enum FrameComparisonError: Error, Sendable, Equatable {
    case unsupportedPixelFormat
    case dimensionMismatch
    case inaccessiblePixels
}

public enum FrameComparison {
    /// Samples a maximum 256×256 grid. Luma uses integer BT.601 coefficients;
    /// `darkPixelChangeFraction` reports samples that cross a 16-level luma
    /// difference, not a semantic scene-change classification.
    public static func compare(_ first: CVPixelBuffer, _ second: CVPixelBuffer) throws -> FrameComparisonMetrics {
        guard CVPixelBufferGetPixelFormatType(first) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(second) == kCVPixelFormatType_32BGRA else { throw FrameComparisonError.unsupportedPixelFormat }
        let width = CVPixelBufferGetWidth(first), height = CVPixelBufferGetHeight(first)
        guard width == CVPixelBufferGetWidth(second), height == CVPixelBufferGetHeight(second), width > 0, height > 0 else {
            throw FrameComparisonError.dimensionMismatch
        }
        CVPixelBufferLockBaseAddress(first, .readOnly); CVPixelBufferLockBaseAddress(second, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(first, .readOnly); CVPixelBufferUnlockBaseAddress(second, .readOnly) }
        guard let a = CVPixelBufferGetBaseAddress(first)?.assumingMemoryBound(to: UInt8.self),
              let b = CVPixelBufferGetBaseAddress(second)?.assumingMemoryBound(to: UInt8.self) else { throw FrameComparisonError.inaccessiblePixels }
        let strideA = CVPixelBufferGetBytesPerRow(first), strideB = CVPixelBufferGetBytesPerRow(second)
        let xStep = max(1, (width + 255) / 256), yStep = max(1, (height + 255) / 256)
        var totalDifference = 0, changed = 0, samples = 0
        for y in stride(from: 0, to: height, by: yStep) { for x in stride(from: 0, to: width, by: xStep) {
            let p = a.advanced(by: y * strideA + x * 4), q = b.advanced(by: y * strideB + x * 4)
            let lumaA = (77 * Int(p[2]) + 150 * Int(p[1]) + 29 * Int(p[0])) >> 8
            let lumaB = (77 * Int(q[2]) + 150 * Int(q[1]) + 29 * Int(q[0])) >> 8
            let difference = abs(lumaA - lumaB)
            totalDifference += difference; if difference >= 16 { changed += 1 }; samples += 1
        }}
        return FrameComparisonMetrics(meanAbsoluteLumaDifference: Double(totalDifference) / Double(samples),
            darkPixelChangeFraction: Double(changed) / Double(samples), sampledPixels: samples)
    }
}

/// Metadata-only result for comparing two fresh frames from one capture
/// session. No frame bytes, thumbnails or image paths are retained.
public struct FrameComparisonObservation: Codable, Sendable, Equatable {
    public let sessionID: String
    public let firstFrameID: String
    public let secondFrameID: String
    public let intervalSeconds: Double
    public let metrics: FrameComparisonMetrics
}
