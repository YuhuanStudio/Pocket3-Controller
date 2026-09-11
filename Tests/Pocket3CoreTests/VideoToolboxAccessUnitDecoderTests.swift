import Foundation
import Testing
@testable import Pocket3Core

@Suite struct VideoToolboxAccessUnitDecoderTests {
    private func avcc(_ units: [Data]) -> Data {
        var result = Data()
        for unit in units {
            let length = UInt32(unit.count)
            result.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16),
                UInt8(length >> 8), UInt8(length)])
            result.append(unit)
        }
        return result
    }

    @Test func parameterBundlesRequireExactlyCanonicalCodecSets() throws {
        let h264 = try VideoToolboxParameterSetBundle(codec: .h264,
            parameterSets: [Data([0x68,1]), Data([0x67,1])])
        #expect(h264.parameterSets.map { $0[0] & 0x1f } == [7,8])
        let hevc = try VideoToolboxParameterSetBundle(codec: .hevc,
            parameterSets: [Data([0x44,1]), Data([0x40,1]), Data([0x42,1])])
        #expect(hevc.parameterSets.map { ($0[0] >> 1) & 0x3f } == [32,33,34])
        #expect(throws: VideoToolboxDecoderError.self) {
            try VideoToolboxParameterSetBundle(codec: .h264,
                parameterSets: [Data([0x67,1]),Data([0x68,1]),Data([0x6d,1])])
        }
        #expect(throws: VideoToolboxDecoderError.self) {
            try VideoToolboxParameterSetBundle(codec: .hevc,
                parameterSets: [Data([0x40,0]),Data([0x42,1]),Data([0x44,1])])
        }
    }

    @Test func accessUnitsValidateFourByteLengthsCodecHeadersAndBounds() throws {
        let h264 = try VideoToolboxAccessUnit(codec: .h264,
            data: avcc([Data([0x65,1,2]),Data([0x41,3])]))
        #expect(h264.nalCount == 2)
        let hevc = try VideoToolboxAccessUnit(codec: .hevc,
            data: avcc([Data([0x26,1,2]),Data([0x02,1,3])]))
        #expect(hevc.nalCount == 2)
        #expect(throws: VideoToolboxDecoderError.self) {
            try VideoToolboxAccessUnit(codec: .hevc, data: avcc([Data([0x26,0])]))
        }
        #expect(throws: VideoToolboxDecoderError.self) {
            try VideoToolboxAccessUnit(codec: .h264, data: Data([0,0,0,9,0x65]))
        }
        #expect(throws: VideoToolboxDecoderError.self) {
            try VideoToolboxAccessUnit(codec: .h264, data: avcc([Data([0x65,1,2])]),
                limits: .init(maxAccessUnitBytes: 6))
        }
    }

    @Test func generationFenceWrapsAndRejectsStaleValues() {
        let fence = VideoToolboxGenerationFence(initialGeneration: UInt64.max)
        #expect(fence.advance() == 0 && fence.isCurrent(0))
        #expect(fence.advance() == 1 && !fence.isCurrent(0) && fence.currentGeneration == 1)
    }

    @Test func invalidLimitsFailBeforeAnyVideoToolboxSession() {
        #expect(throws: VideoToolboxDecoderError.invalidLimits) {
            try VideoToolboxParameterSetBundle(codec: .h264,
                parameterSets: [Data([0x67,1]),Data([0x68,1])],
                limits: .init(maxParameterSetBytes: 0))
        }
        #expect(throws: VideoToolboxDecoderError.invalidLimits) {
            try VideoToolboxAccessUnit(codec: .h264, data: avcc([Data([0x65,1])]),
                limits: .init(maxNALCount: 0))
        }
    }
}
