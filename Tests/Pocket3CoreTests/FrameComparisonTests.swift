import CoreVideo
import Testing
@testable import Pocket3Core

@Suite struct FrameComparisonTests {
    private func make(_ value: UInt8, width: Int = 32, height: Int = 24) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &output) == kCVReturnSuccess)
        let buffer = try #require(output); CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { for x in 0..<width { let p = base.advanced(by: y * row + x * 4); p[0] = value; p[1] = value; p[2] = value; p[3] = 255 } }
        return buffer
    }
    @Test func identicalFramesHaveZeroDifference() throws {
        let metrics = try FrameComparison.compare(make(80), make(80))
        #expect(metrics.meanAbsoluteLumaDifference == 0 && metrics.darkPixelChangeFraction == 0 && metrics.sampledPixels > 0)
    }
    @Test func changedFramesReportLumaDifferenceWithoutPixels() throws {
        let metrics = try FrameComparison.compare(make(0), make(255))
        #expect(metrics.meanAbsoluteLumaDifference == 255 && metrics.darkPixelChangeFraction == 1)
    }
    @Test func mismatchedFramesAreRejected() throws {
        #expect(throws: FrameComparisonError.dimensionMismatch) { try FrameComparison.compare(make(0), make(0, width: 31)) }
    }
}
