import CoreVideo
import Testing
@testable import Pocket3Core

@Suite struct FrameEdgeMetricsTests {
    private func buffer(width: Int = 80, height: Int = 64, blackTopBottom: Bool = false) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &output) == kCVReturnSuccess)
        let value = try #require(output)
        CVPixelBufferLockBaseAddress(value, []); defer { CVPixelBufferUnlockBaseAddress(value, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(value)).assumingMemoryBound(to: UInt8.self), bytesPerRow = CVPixelBufferGetBytesPerRow(value)
        for y in 0..<height { for x in 0..<width {
            let p = base.advanced(by: y * bytesPerRow + x * 4)
            let dark = blackTopBottom && (y < 3 || y >= height - 3)
            p[0] = dark ? 0 : 80; p[1] = dark ? 0 : 100; p[2] = dark ? 0 : 120; p[3] = 255
        }}
        return value
    }
    @Test func reportsDarkHorizontalEdgesWithoutRetainingPixels() throws {
        let metrics = try #require(FrameEdgeAnalyzer.measure(buffer(blackTopBottom: true)))
        #expect(metrics.topDarkFraction == 1 && metrics.bottomDarkFraction == 1)
        #expect(metrics.leftDarkFraction < 1 && metrics.rightDarkFraction < 1 && metrics.sampledPixelsPerEdge > 0)
    }
    @Test func rejectsNonBGRA() throws {
        var output: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &output) == kCVReturnSuccess)
        #expect(FrameEdgeAnalyzer.measure(try #require(output)) == nil)
    }
}
