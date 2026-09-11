import Foundation
import Testing
@testable import Pocket3Core

@Suite struct H264AccessUnitNormalizerTests {
    private let sps = Data([0x67, 0x64, 0x00, 0x1f])
    private let pps = Data([0x68, 0xee, 0x3c, 0x80])
    private let idr = Data([0x65, 0x88, 0x84])
    private let pframe = Data([0x41, 0x9a, 0x22])

    private func annex(_ units: [Data], code: Int = 4) -> Data {
        precondition(code == 3 || code == 4)
        var bytes = [UInt8]()
        for unit in units {
            bytes += code == 3 ? [0, 0, 1] : [0, 0, 0, 1]
            bytes += unit
        }
        return Data(bytes)
    }

    private func avcc(_ units: [Data]) -> Data {
        var bytes = [UInt8]()
        for unit in units {
            let length = UInt32(unit.count)
            bytes += [UInt8(length >> 24), UInt8(length >> 16), UInt8(length >> 8), UInt8(length)]
            bytes += unit
        }
        return Data(bytes)
    }

    private func normalized(_ units: [Data]) -> Data { avcc(units) }

    @Test func acceptsThreeAndFourByteAnnexBStartCodesAndNormalizesAllNALs() throws {
        var normalizer = H264AccessUnitNormalizer()
        let three = try normalizer.normalize(annex([sps, pps, idr], code: 3))
        #expect(three.inputFormat == .annexB)
        #expect(three.nalUnits.map(\.type) == [7, 8, 5])
        #expect(three.data == normalized([sps, pps, idr]))
        #expect(three.isDecodable)

        let four = try normalizer.normalize(annex([pframe, Data([0x06, 0x05])], code: 4))
        #expect(four.nalUnits.map(\.type) == [1, 6])
        #expect(four.data == normalized([pframe, Data([0x06, 0x05])]))
        #expect(four.isDecodable)
    }

    @Test func acceptsStrictAVCCAndReportsNALTypes() throws {
        var normalizer = H264AccessUnitNormalizer()
        let result = try normalizer.normalize(avcc([sps, pps, idr, pframe]))
        #expect(result.inputFormat == .avcc)
        #expect(result.nalUnits.map(\.nalType) == [7, 8, 5, 1])
        #expect(result.normalizedData == avcc([sps, pps, idr, pframe]))
        #expect(result.readiness == .ready)
    }

    @Test func rejectsEmptyMalformedAndMixedFramingWithoutChangingState() throws {
        var normalizer = H264AccessUnitNormalizer()
        #expect(throws: H264AccessUnitError.self) { try normalizer.normalize(Data()) }
        #expect(throws: H264AccessUnitError.self) { try normalizer.normalize(Data([0, 0, 1])) }
        #expect(throws: H264AccessUnitError.self) { try normalizer.normalize(annex([sps]) + Data([0, 0, 1])) }
        #expect(throws: H264AccessUnitError.self) { try normalizer.normalize(Data([0, 0, 0, 2, 0x67])) }
        #expect(throws: H264AccessUnitError.self) { try normalizer.normalize(Data([0, 0, 0, 4, 0x67, 0x01])) }
        #expect(throws: H264AccessUnitError.self) { try normalizer.normalize(Data([0x80, 0x01])) }
        #expect(normalizer.cachedSPS == nil && normalizer.cachedPPS == nil)

        // 00 00 00 04 inside one Annex-B NAL is not by itself proof of AVCC;
        // rejecting it would discard valid EBSP zero runs.
        let zeroRun = try normalizer.normalize(annex([Data([0x41, 0, 0, 0, 4, 0x55])]))
        #expect(zeroRun.nalUnits.count == 1)
    }

    @Test func rejectsMalformedAVCCLengthsAndTrailingBytes() throws {
        var normalizer = H264AccessUnitNormalizer()
        #expect(throws: H264AccessUnitError.self) { try normalizer.normalize(Data([0, 0, 0])) }
        #expect(throws: H264AccessUnitError.self) { try normalizer.normalize(Data([0, 0, 0, 0])) }
        #expect(throws: H264AccessUnitError.self) { try normalizer.normalize(Data([0, 0, 0, 5, 0x65])) }
        #expect(throws: H264AccessUnitError.self) { try normalizer.normalize(avcc([idr]) + Data([1])) }
    }

    @Test func parameterSetsThenIDRGateDecodabilityAndCacheExtension() throws {
        var normalizer = H264AccessUnitNormalizer()
        let sets = try normalizer.normalize(annex([sps, pps]))
        #expect(!sets.isDecodable && sets.readiness == .waitingForIDR)
        #expect(normalizer.cachedSPS == sps && normalizer.cachedPPS == pps)

        let spsExtension = Data([0x6d, 0x01, 0x02])
        let key = try normalizer.normalize(avcc([spsExtension, idr]))
        #expect(key.isDecodable)
        #expect(normalizer.cachedSPSExtension == spsExtension)
        #expect(normalizer.isReadyForDecode)
    }

    @Test func resetAndLossRequireRecoveryAndLossCanReuseCachedSets() throws {
        var normalizer = H264AccessUnitNormalizer()
        _ = try normalizer.normalize(annex([sps, pps, idr]))
        #expect(normalizer.isReadyForDecode)

        normalizer.markLoss()
        #expect(normalizer.decodeReadiness == .waitingForIDR)
        #expect(!(try normalizer.normalize(avcc([pframe]))).isDecodable)
        #expect((try normalizer.normalize(avcc([idr]))).isDecodable)

        normalizer.reset()
        #expect(normalizer.cachedSPS == nil && normalizer.cachedPPS == nil)
        #expect(!(try normalizer.normalize(annex([idr]))).isDecodable)
        #expect(!(try normalizer.normalize(annex([sps, pps]))).isDecodable)
        #expect((try normalizer.normalize(annex([idr]))).isDecodable)
    }

    @Test func parameterSetChangeInvalidatesUntilIDRAfterTheChange() throws {
        var normalizer = H264AccessUnitNormalizer()
        _ = try normalizer.normalize(avcc([sps, pps, idr]))

        let changedSPS = Data([0x67, 0x64, 0x00, 0x20])
        let changed = try normalizer.normalize(annex([changedSPS, pps, pframe]))
        #expect(changed.parameterSetsChanged)
        #expect(!changed.isDecodable && changed.readiness == .waitingForIDR)
        #expect(normalizer.cachedSPS == changedSPS)
        #expect((try normalizer.normalize(avcc([pframe]))).isDecodable == false)
        #expect((try normalizer.normalize(avcc([idr]))).isDecodable)

        let changedPPS = Data([0x68, 0xee, 0x3c, 0x81])
        let IDRBeforePPS = try normalizer.normalize(annex([idr, changedPPS]))
        #expect(!IDRBeforePPS.isDecodable)
        #expect(normalizer.decodeReadiness == .waitingForIDR)
        #expect((try normalizer.normalize(annex([idr]))).isDecodable)
    }

    @Test func boundChecksCoverInputNALCountNALSizeParameterCacheAndOutput() throws {
        let smallInput = H264AccessUnitLimits(maxInputBytes: 8)
        var inputNormalizer = H264AccessUnitNormalizer(limits: smallInput)
        #expect(throws: H264AccessUnitError.self) { try inputNormalizer.normalize(annex([sps, pps])) }

        let smallNAL = H264AccessUnitLimits(maxNALBytes: 2)
        var nalNormalizer = H264AccessUnitNormalizer(limits: smallNAL)
        #expect(throws: H264AccessUnitError.self) { try nalNormalizer.normalize(annex([sps])) }

        let fewNALs = H264AccessUnitLimits(maxNALCount: 2)
        var countNormalizer = H264AccessUnitNormalizer(limits: fewNALs)
        #expect(throws: H264AccessUnitError.self) { try countNormalizer.normalize(annex([sps, pps, idr])) }

        let smallOutput = H264AccessUnitLimits(maxOutputBytes: 6)
        var outputNormalizer = H264AccessUnitNormalizer(limits: smallOutput)
        #expect(throws: H264AccessUnitError.self) { try outputNormalizer.normalize(avcc([idr])) }

        let smallParameter = H264AccessUnitLimits(maxParameterSetBytes: 2)
        var parameterNormalizer = H264AccessUnitNormalizer(limits: smallParameter)
        #expect(throws: H264AccessUnitError.self) { try parameterNormalizer.normalize(avcc([sps])) }
    }

    @Test func malformedUnitDoesNotPartiallyCacheEarlierParameterSets() throws {
        var normalizer = H264AccessUnitNormalizer()
        let malformed = annex([sps]) + Data([0, 0, 1])
        #expect(throws: H264AccessUnitError.self) { try normalizer.normalize(malformed) }
        #expect(normalizer.cachedSPS == nil && normalizer.cachedPPS == nil)
        #expect(normalizer.decodeReadiness == .waitingForParameterSets)
    }
}
