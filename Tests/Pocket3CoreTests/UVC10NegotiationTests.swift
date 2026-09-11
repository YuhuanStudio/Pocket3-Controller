import Foundation
import Testing
@testable import Pocket3Core

@Suite struct UVC10NegotiationTests {
    private let sample = UVCVideoStreamingControlBlock(
        bmHint: 0x1234,
        formatIndex: 2,
        frameIndex: 5,
        frameInterval: 0x0102_0304,
        keyFrameRate: 0x1122,
        pFrameRate: 0x3344,
        compressionQuality: 0x5566,
        compressionWindowSize: 0x7788,
        delay: 0x99aa,
        maxVideoFrameSize: 0x0203_0405,
        maxPayloadTransferSize: 0x0001_0203)

    @Test func controlBlockUsesExactLittleEndianGoldenBytes() throws {
        let expected = Data([
            0x34, 0x12, 0x02, 0x05,
            0x04, 0x03, 0x02, 0x01,
            0x22, 0x11, 0x44, 0x33,
            0x66, 0x55, 0x88, 0x77,
            0xaa, 0x99,
            0x05, 0x04, 0x03, 0x02,
            0x03, 0x02, 0x01, 0x00,
        ])
        #expect(sample.encodedData == expected)
        #expect(sample.encodedData.count == UVCVideoStreamingControlBlock.byteCount)
        #expect(try UVCVideoStreamingControlBlock(data: expected) == sample)
        #expect(try UVCVideoStreamingControlBlock.decode([UInt8](expected)) == sample)
    }

    @Test func decoderRejectsEveryNon26ByteBlock() {
        for count in [0, 1, 25, 27, 52] {
            #expect(throws: UVCNegotiationError.self) {
                try UVCVideoStreamingControlBlock(data: Data(repeating: 0, count: count))
            }
        }
    }

    @Test func pocket3CatalogMatchesFormat2Frame2Frame4AndFrame5Descriptors() throws {
        #expect(Pocket3H264ModeCatalog.formatIndex == 2)
        #expect(Pocket3H264ModeCatalog.streamingInterfaceNumber == 1)
        #expect(Pocket3H264ModeCatalog.all.map(\.frameIndex) == [2, 4, 5])

        let landscape = try #require(Pocket3H264ModeCatalog.mode(frameIndex: 2))
        #expect(landscape.width == 1920 && landscape.height == 1080)
        #expect(landscape.frameIntervals100ns == [333_333, 400_000, 416_666])

        let portrait = try #require(Pocket3H264ModeCatalog.mode(frameIndex: 4))
        #expect(portrait.width == 1080 && portrait.height == 1920)
        #expect(portrait.frameIntervals100ns == [333_333, 400_000, 416_666])

        let fourK = try #require(Pocket3H264ModeCatalog.mode(frameIndex: 5))
        #expect(fourK.width == 3840 && fourK.height == 2160)
        #expect(fourK.frameIntervals100ns == [166_666, 200_000, 208_333, 333_333, 400_000, 416_666])
        #expect(Pocket3H264ModeCatalog.mode(frameIndex: 1) == nil)
        #expect(Pocket3H264ModeCatalog.mode(frameIndex: 3) == nil)
    }

    @Test func unsupportedFormatFrameAndIntervalCannotBeSelected() {
        #expect(throws: UVCNegotiationError.self) {
            try Pocket3H264ModeCatalog.controlBlock(frameIndex: 2, interval: 166_666)
        }
        #expect(throws: UVCNegotiationError.self) {
            try Pocket3H264ModeCatalog.controlBlock(frameIndex: 6, interval: 333_333)
        }
        let wrongFormat = UVCVideoStreamingControlBlock(formatIndex: 1, frameIndex: 2, frameInterval: 333_333)
        #expect(throws: UVCNegotiationError.self) {
            try Pocket3H264ModeCatalog.validate(wrongFormat)
        }
    }

    @Test func requestMetadataIsFixedToThe26ByteVSInterface1Sequence() {
        let expected: [(UVCVideoStreamingRequest, [UInt8])] = [
            (.getMaxProbe, [0xa1, 0x83, 0x00, 0x01, 0x01, 0x00, 0x1a, 0x00]),
            (.setCurProbe, [0x21, 0x01, 0x00, 0x01, 0x01, 0x00, 0x1a, 0x00]),
            (.getCurProbe, [0xa1, 0x81, 0x00, 0x01, 0x01, 0x00, 0x1a, 0x00]),
            (.setCurCommit, [0x21, 0x01, 0x00, 0x02, 0x01, 0x00, 0x1a, 0x00]),
        ]
        for (request, bytes) in expected {
            #expect(request.interfaceNumber == 1)
            #expect(request.metadata.wLength == 26)
            #expect(request.setupPacket == Data(bytes))
        }
    }

    @Test func descriptorResponseValidationRejectsChangedTupleFields() throws {
        let mode = Pocket3H264ModeCatalog.frame2
        let expected = try mode.makeControlBlock(interval: 333_333)

        for changed in [
            UVCVideoStreamingControlBlock(formatIndex: 1, frameIndex: 2, frameInterval: 333_333),
            UVCVideoStreamingControlBlock(formatIndex: 2, frameIndex: 4, frameInterval: 333_333),
            UVCVideoStreamingControlBlock(formatIndex: 2, frameIndex: 2, frameInterval: 166_666),
        ] {
            #expect(throws: UVCNegotiationError.self) {
                try Pocket3H264Negotiation.validateResponse(
                    changed.encodedData, for: .getCurProbe, mode: mode)
            }
        }

        var normalized = expected
        // A device may normalize non-descriptor fields, so tuple validation
        // remains valid while exact validation rejects the changed field.
        normalized = UVCVideoStreamingControlBlock(
            bmHint: expected.bmHint, formatIndex: expected.formatIndex, frameIndex: expected.frameIndex,
            frameInterval: expected.frameInterval, keyFrameRate: expected.keyFrameRate,
            pFrameRate: expected.pFrameRate, compressionQuality: expected.compressionQuality + 1,
            compressionWindowSize: expected.compressionWindowSize, delay: expected.delay,
            maxVideoFrameSize: expected.maxVideoFrameSize, maxPayloadTransferSize: expected.maxPayloadTransferSize)
        #expect(throws: Never.self) {
            try mode.validateResponse(normalized)
        }
        #expect(throws: UVCNegotiationError.self) {
            try mode.validateExactResponse(normalized, expected: expected)
        }
    }

    @Test func frameAndPayloadSizeBoundsAreIndependent() throws {
        let mode = Pocket3H264ModeCatalog.frame5
        let frameTooLarge = UVCVideoStreamingControlBlock(
            formatIndex: 2, frameIndex: 5, frameInterval: 333_333,
            maxVideoFrameSize: UVCProbeCommitSizeBounds.pocket3H264.maximumVideoFrameSize + 1,
            maxPayloadTransferSize: 512)
        #expect(throws: UVCNegotiationError.self) {
            try mode.validateResponse(frameTooLarge)
        }

        let payloadTooLarge = UVCVideoStreamingControlBlock(
            formatIndex: 2, frameIndex: 5, frameInterval: 333_333,
            maxVideoFrameSize: 512,
            maxPayloadTransferSize: UVCProbeCommitSizeBounds.pocket3H264.maximumPayloadTransferSize + 1)
        #expect(throws: UVCNegotiationError.self) {
            try mode.validateResponse(payloadTooLarge)
        }
    }

    @Test func widerInputsCannotTruncateThroughIntegerOverflow() {
        #expect(throws: UVCNegotiationError.self) {
            try UVCVideoStreamingControlBlock(
                validatingFormatIndex: 2, validatingFrameIndex: 2,
                validatingFrameInterval: UInt64(UInt32.max) + 1)
        }
        #expect(throws: UVCNegotiationError.self) {
            try UVCProbeCommitSizeBounds(
                validatingVideoFrameSize: UInt64(UInt32.max) + 1,
                payloadTransferSize: 512)
        }
        #expect(throws: UVCNegotiationError.self) {
            try UVCProbeCommitSizeBounds(
                validatingVideoFrameSize: 512,
                payloadTransferSize: UInt64(UInt32.max) + 1)
        }
    }
}
