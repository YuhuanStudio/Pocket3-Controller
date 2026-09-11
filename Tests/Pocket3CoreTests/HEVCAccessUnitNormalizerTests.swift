import Foundation
import Testing
@testable import Pocket3Core

@Suite struct HEVCAccessUnitNormalizerTests {
    // HEVC NAL headers are two bytes.  The low three bits of byte 1 are
    // nuh_temporal_id_plus1 and therefore must be non-zero.
    private let vps = Data([0x40, 0x01, 0xaa, 0xbb])
    private let sps = Data([0x42, 0x01, 0xcc, 0xdd])
    private let pps = Data([0x44, 0x01, 0xee, 0xff])
    private let irap = Data([0x26, 0x01, 0x80]) // type 19, CRA_NUT
    private let trail = Data([0x02, 0x01, 0x12]) // type 1, TRAIL_R

    private func annex(_ units: [Data], codes: [Int]? = nil) -> Data {
        let selected = codes ?? Array(repeating: 4, count: units.count)
        precondition(selected.count == units.count)
        var bytes = [UInt8]()
        for (unit, code) in zip(units, selected) {
            precondition(code == 3 || code == 4)
            bytes += code == 3 ? [0, 0, 1] : [0, 0, 0, 1]
            bytes += unit
        }
        return Data(bytes)
    }

    private func hvcc(_ units: [Data]) -> Data {
        var bytes = [UInt8]()
        for unit in units {
            let length = UInt32(unit.count)
            bytes += [UInt8(length >> 24), UInt8(length >> 16), UInt8(length >> 8), UInt8(length)]
            bytes += unit
        }
        return Data(bytes)
    }

    @Test func acceptsMixedThreeAndFourByteAnnexBAndNormalizesAllNALs() throws {
        var normalizer = HEVCAccessUnitNormalizer()
        let input = annex([vps, sps, pps, irap, trail], codes: [3, 4, 3, 4, 3])
        let result = try normalizer.normalize(input)

        #expect(result.inputFormat == .annexB)
        #expect(result.nalUnits.map(\.type) == [32, 33, 34, 19, 1])
        #expect(result.data == hvcc([vps, sps, pps, irap, trail]))
        #expect(result.normalizedData == result.data)
        #expect(result.hasVPS && result.hasSPS && result.hasPPS)
        #expect(result.containsIRAP)
        #expect(result.isDecodable)
        #expect(normalizer.cachedVPS == vps && normalizer.cachedSPS == sps && normalizer.cachedPPS == pps)
    }

    @Test func acceptsStrictHVCCAndReportsSixBitNALTypes() throws {
        var normalizer = HEVCAccessUnitNormalizer()
        let result = try normalizer.normalize(hvcc([vps, sps, pps, irap, trail]))

        #expect(result.inputFormat == .hvcc)
        #expect(result.nalUnits.map(\.nalType) == [32, 33, 34, 19, 1])
        #expect(result.normalizedData == hvcc([vps, sps, pps, irap, trail]))
        #expect(result.readiness == .ready)
    }

    @Test func validatesTwoByteHeaderForbiddenBitAndTemporalID() throws {
        var normalizer = HEVCAccessUnitNormalizer()

        #expect(throws: HEVCAccessUnitError.self) {
            try normalizer.normalize(hvcc([Data([0x80, 0x01])]))
        }
        #expect(throws: HEVCAccessUnitError.self) {
            try normalizer.normalize(hvcc([Data([0x40, 0x00])]))
        }
        #expect(throws: HEVCAccessUnitError.self) {
            try normalizer.normalize(hvcc([Data([0x40])]))
        }

        // Type 0 and a non-zero layer ID are valid when the two header rules
        // above hold; validation must not accidentally use H.264's 5-bit mask.
        let typeZero = Data([0x00, 0x01, 0x55])
        let layer = Data([0x41, 0xa1, 0x66]) // type 32, layer ID 0x35
        let result = try normalizer.normalize(hvcc([typeZero, layer]))
        #expect(result.nalUnits.map(\.type) == [0, 32])
    }

    @Test func rejectsMalformedAndMixedFramingWithoutChangingState() throws {
        var normalizer = HEVCAccessUnitNormalizer()

        #expect(throws: HEVCAccessUnitError.self) { try normalizer.normalize(Data()) }
        #expect(throws: HEVCAccessUnitError.self) { try normalizer.normalize(Data([0, 0, 1])) }
        #expect(throws: HEVCAccessUnitError.self) { try normalizer.normalize(annex([vps]) + Data([0, 0, 1])) }
        #expect(throws: HEVCAccessUnitError.self) { try normalizer.normalize(Data([0, 0, 0, 4, 0x40, 0x01])) }
        #expect(throws: HEVCAccessUnitError.self) { try normalizer.normalize(Data([0x80, 0x01])) }
        #expect(throws: HEVCAccessUnitError.self) { try normalizer.normalize(Data([0x40, 0x00])) }
        #expect(normalizer.cachedVPS == nil && normalizer.cachedSPS == nil && normalizer.cachedPPS == nil)

        // A raw zero run that is not a start code remains payload in Annex-B.
        let zeroRun = try normalizer.normalize(annex([Data([0x02, 0x01, 0, 0, 0, 4, 0x55])]))
        #expect(zeroRun.nalUnits.count == 1)

        // A start-code prefix inside a length-prefixed NAL is mixed framing.
        let mixedPayload = Data([0x02, 0x01, 0xaa, 0, 0, 1, 0xbb])
        #expect(throws: HEVCAccessUnitError.self) { try normalizer.normalize(hvcc([mixedPayload])) }
    }

    @Test func rejectsMalformedHVCCLengthsAndTrailingBytes() throws {
        var normalizer = HEVCAccessUnitNormalizer()
        #expect(throws: HEVCAccessUnitError.self) { try normalizer.normalize(Data([0, 0, 0])) }
        #expect(throws: HEVCAccessUnitError.self) { try normalizer.normalize(Data([0, 0, 0, 0])) }
        #expect(throws: HEVCAccessUnitError.self) { try normalizer.normalize(Data([0, 0, 0, 5, 0x40, 0x01])) }
        #expect(throws: HEVCAccessUnitError.self) { try normalizer.normalize(hvcc([irap]) + Data([1])) }
    }

    @Test func parameterSetsThenIRAPGateDecodability() throws {
        var normalizer = HEVCAccessUnitNormalizer()
        let sets = try normalizer.normalize(annex([vps, sps, pps]))
        #expect(!sets.isDecodable && sets.readiness == .waitingForIRAP)
        #expect(normalizer.hasParameterSets)

        let key = try normalizer.normalize(hvcc([trail, irap]))
        #expect(key.isDecodable)
        #expect(key.containsIRAP)
        #expect(normalizer.isReadyForDecode)
    }

    @Test func allIRAPTypesOpenGateAfterAllParameterSets() throws {
        for type in UInt8(16)...UInt8(23) {
            let header = Data([(type << 1), 0x01, 0x7f])
            var normalizer = HEVCAccessUnitNormalizer()
            _ = try normalizer.normalize(hvcc([vps, sps, pps]))
            let result = try normalizer.normalize(hvcc([header]))
            #expect(result.containsIRAP)
            #expect(result.isDecodable)
        }
    }

    @Test func resetAndLossRequireRecoveryAndLossCanReuseCachedSets() throws {
        var normalizer = HEVCAccessUnitNormalizer()
        _ = try normalizer.normalize(annex([vps, sps, pps, irap]))
        #expect(normalizer.isReadyForDecode)

        normalizer.markLoss()
        #expect(normalizer.decodeReadiness == .waitingForIRAP)
        #expect(!(try normalizer.normalize(hvcc([trail]))).isDecodable)
        #expect((try normalizer.normalize(hvcc([irap]))).isDecodable)

        normalizer.reset()
        #expect(normalizer.cachedVPS == nil && normalizer.cachedSPS == nil && normalizer.cachedPPS == nil)
        #expect(!(try normalizer.normalize(annex([irap]))).isDecodable)
        #expect(!(try normalizer.normalize(annex([vps, sps, pps]))).isDecodable)
        #expect((try normalizer.normalize(annex([irap]))).isDecodable)
    }

    @Test func parameterSetChangeInvalidatesUntilIRAPAfterTheChange() throws {
        var normalizer = HEVCAccessUnitNormalizer()
        _ = try normalizer.normalize(hvcc([vps, sps, pps, irap]))

        let changedSPS = Data([0x42, 0x01, 0xcc, 0xde])
        let changed = try normalizer.normalize(annex([changedSPS, pps, trail]))
        #expect(changed.parameterSetsChanged)
        #expect(!changed.isDecodable && changed.readiness == .waitingForIRAP)
        #expect(normalizer.cachedSPS == changedSPS)
        #expect((try normalizer.normalize(hvcc([trail]))).isDecodable == false)
        #expect((try normalizer.normalize(hvcc([irap]))).isDecodable)

        let changedPPS = Data([0x44, 0x01, 0xee, 0x01])
        let irapBeforePPS = try normalizer.normalize(annex([irap, changedPPS]))
        #expect(!irapBeforePPS.isDecodable)
        #expect(normalizer.decodeReadiness == .waitingForIRAP)
        #expect((try normalizer.normalize(annex([irap]))).isDecodable)
    }

    @Test func boundChecksCoverInvalidLimitsInputNALCountNALSizeParameterCacheAndOutput() throws {
        let invalid = HEVCAccessUnitLimits(maxInputBytes: 0)
        var invalidNormalizer = HEVCAccessUnitNormalizer(limits: invalid)
        #expect(throws: HEVCAccessUnitError.invalidLimits) {
            try invalidNormalizer.normalize(hvcc([vps]))
        }

        let smallInput = HEVCAccessUnitLimits(maxInputBytes: 8)
        var inputNormalizer = HEVCAccessUnitNormalizer(limits: smallInput)
        #expect(throws: HEVCAccessUnitError.inputTooLarge) {
            try inputNormalizer.normalize(annex([vps, sps]))
        }

        let smallNAL = HEVCAccessUnitLimits(maxNALBytes: 3)
        var nalNormalizer = HEVCAccessUnitNormalizer(limits: smallNAL)
        #expect(throws: HEVCAccessUnitError.nalTooLarge) {
            try nalNormalizer.normalize(annex([vps]))
        }

        let fewNALs = HEVCAccessUnitLimits(maxNALCount: 3)
        var countNormalizer = HEVCAccessUnitNormalizer(limits: fewNALs)
        #expect(throws: HEVCAccessUnitError.tooManyNALUnits) {
            try countNormalizer.normalize(annex([vps, sps, pps, irap]))
        }

        let smallOutput = HEVCAccessUnitLimits(maxOutputBytes: 6)
        var outputNormalizer = HEVCAccessUnitNormalizer(limits: smallOutput)
        #expect(throws: HEVCAccessUnitError.outputTooLarge) {
            try outputNormalizer.normalize(hvcc([irap]))
        }

        let smallParameter = HEVCAccessUnitLimits(maxParameterSetBytes: 3)
        var parameterNormalizer = HEVCAccessUnitNormalizer(limits: smallParameter)
        #expect(throws: HEVCAccessUnitError.parameterSetTooLarge) {
            try parameterNormalizer.normalize(hvcc([vps]))
        }

        let smallCache = HEVCAccessUnitLimits(maxCachedParameterSetBytes: 11)
        var cacheNormalizer = HEVCAccessUnitNormalizer(limits: smallCache)
        #expect(throws: HEVCAccessUnitError.parameterSetTooLarge) {
            try cacheNormalizer.normalize(hvcc([vps, sps, pps]))
        }
    }

    @Test func malformedUnitDoesNotPartiallyCacheEarlierParameterSets() throws {
        var normalizer = HEVCAccessUnitNormalizer()
        let malformed = annex([vps]) + Data([0, 0, 1])
        #expect(throws: HEVCAccessUnitError.self) { try normalizer.normalize(malformed) }
        #expect(normalizer.cachedVPS == nil && normalizer.cachedSPS == nil && normalizer.cachedPPS == nil)
        #expect(normalizer.decodeReadiness == .waitingForParameterSets)

        _ = try normalizer.normalize(hvcc([vps, sps, pps, irap]))
        let before = normalizer
        let tooLarge = HEVCAccessUnitLimits(maxOutputBytes: 1)
        var failing = HEVCAccessUnitNormalizer(limits: tooLarge)
        _ = before // Keep the successful state check below explicit and local.
        #expect(throws: HEVCAccessUnitError.self) { try failing.normalize(hvcc([vps])) }
        #expect(failing.cachedVPS == nil && failing.cachedSPS == nil && failing.cachedPPS == nil)
    }
}
