import Foundation
import Testing
@testable import Pocket3Core

@Suite("UVC payload parsing and access-unit assembly")
struct UVCPayloadAssemblerTests {
    private func transfer(fid: Bool = false, eof: Bool = false, pts: UInt32? = nil,
                          scr: UInt64? = nil, error: Bool = false, data: Data = Data()) -> Data {
        var flags: UVCPayloadHeaderFlags = []
        if fid { flags.insert(.fid) }
        if eof { flags.insert(.eof) }
        if pts != nil { flags.insert(.pts) }
        if scr != nil { flags.insert(.scr) }
        if error { flags.insert(.error) }
        let length = 2 + (pts == nil ? 0 : 4) + (scr == nil ? 0 : 6)
        var bytes = Data([UInt8(length), flags.rawValue])
        if let pts {
            bytes.append(UInt8(truncatingIfNeeded: pts))
            bytes.append(UInt8(truncatingIfNeeded: pts >> 8))
            bytes.append(UInt8(truncatingIfNeeded: pts >> 16))
            bytes.append(UInt8(truncatingIfNeeded: pts >> 24))
        }
        if let scr {
            for index in 0..<6 { bytes.append(UInt8(truncatingIfNeeded: scr >> UInt64(index * 8))) }
        }
        bytes.append(data)
        return bytes
    }

    @Test func payloadHeaderUsesStrictLengthAndLittleEndianOptionalFields() throws {
        let packet = transfer(fid: true, eof: true, pts: 0x78563412,
                              scr: 0x0000_F6E5_D4C3_B2A1, data: Data([0xaa, 0xbb]))
        let decoded = try UVCPayload.parse(packet)
        #expect(decoded.header.length == 12)
        #expect(decoded.header.flags == [.fid, .eof, .pts, .scr])
        #expect(decoded.header.fid && decoded.header.eof && decoded.header.hasPTS && decoded.header.hasSCR)
        #expect(decoded.header.pts == 0x78563412)
        #expect(decoded.header.scr == 0x0000_F6E5_D4C3_B2A1)
        #expect(decoded.data == Data([0xaa, 0xbb]))

        #expect(throws: UVCPayloadError.headerLengthMismatch(expected: 2, actual: 1)) {
            try UVCPayload.parse(Data([1, 0]))
        }
        #expect(throws: UVCPayloadError.headerLengthMismatch(expected: 6, actual: 2)) {
            try UVCPayload.parse(Data([2, UVCPayloadHeaderFlags.pts.rawValue]))
        }
        #expect(throws: UVCPayloadError.headerExceedsTransfer(length: 6, transferLength: 2)) {
            try UVCPayload.parse(Data([6, UVCPayloadHeaderFlags.pts.rawValue]))
        }
        #expect(throws: UVCPayloadError.unsupportedFlags(0x10)) {
            try UVCPayload.parse(Data([2, 0x10]))
        }
        let standardFlags = try UVCPayload.parse(Data([2,
            UVCPayloadHeaderFlags.stillImage.rawValue | UVCPayloadHeaderFlags.endOfHeader.rawValue]))
        #expect(standardFlags.header.isStillImage && standardFlags.header.hasEndOfHeader)
    }

    @Test func eachBulkCompletionIsOnePayloadAndFragmentationOnlyJoinsPayloadBytes() {
        var assembler = UVCAccessUnitAssembler()
        let nestedHeaderBytes = Data([2, 0x01, 0xde, 0xad])
        #expect(assembler.append(transfer(data: Data([0x00, 0x00]) + nestedHeaderBytes)).isEmpty)
        let completed = assembler.append(transfer(eof: true, data: Data([0xbe, 0xef])))
        #expect(completed.count == 1)
        #expect(completed[0].data == Data([0x00, 0x00, 2, 1, 0xde, 0xad, 0xbe, 0xef]))
        #expect(completed[0].endedByEOF && completed[0].fid == false)
        #expect(assembler.pendingByteCount == 0)
    }

    @Test func fidTransitionPublishesNonemptyPriorUnitWithoutEOF() {
        var assembler = UVCAccessUnitAssembler()
        _ = assembler.append(transfer(data: Data([1, 2])))
        let transition = assembler.append(transfer(fid: true, data: Data([3])))
        #expect(transition.count == 1)
        #expect(transition[0].data == Data([1, 2]))
        #expect(!transition[0].endedByEOF && transition[0].fid == false)
        #expect(assembler.pendingFID == true && assembler.pendingByteCount == 1)

        let second = assembler.append(transfer(fid: true, eof: true, data: Data([4])))
        #expect(second.count == 1 && second[0].data == Data([3, 4]))
        #expect(second[0].endedByEOF && second[0].fid)
    }

    @Test func errorPayloadDropsPartialUnitAndNextValidPayloadRecoversCleanly() {
        var assembler = UVCAccessUnitAssembler()
        _ = assembler.append(transfer(data: Data([0xa1])))
        #expect(assembler.append(transfer(error: true, data: Data([0xb2]))).isEmpty)
        #expect(assembler.pendingByteCount == 0 && assembler.requiresCleanRecovery)
        let recovered = assembler.append(transfer(eof: true, data: Data([0xc3])))
        #expect(recovered.count == 1 && recovered[0].data == Data([0xc3]))
        #expect(!assembler.requiresCleanRecovery)
        #expect(assembler.statistics.errorPayloads == 1)
    }

    @Test func malformedAndPerPayloadOverflowClearAccumulator() {
        var malformed = UVCAccessUnitAssembler(maximumPayloadBytes: 8, maximumAccumulatorBytes: 8)
        _ = malformed.append(transfer(data: Data([1, 2])))
        #expect(malformed.append(Data([1, 0])).isEmpty)
        #expect(malformed.pendingByteCount == 0 && malformed.statistics.malformedPayloads == 1)
        let recovered = malformed.append(transfer(eof: true, data: Data([3])))
        #expect(recovered.count == 1 && recovered[0].data == Data([3]))

        var oversized = UVCAccessUnitAssembler(maximumPayloadBytes: 2, maximumAccumulatorBytes: 8)
        #expect(oversized.append(transfer(data: Data([1, 2, 3]))).isEmpty)
        #expect(oversized.pendingByteCount == 0 && oversized.statistics.malformedPayloads == 1)
        #expect(oversized.append(transfer(eof: true, data: Data([4]))).count == 1)

        var accumulated = UVCAccessUnitAssembler(maximumPayloadBytes: 8, maximumAccumulatorBytes: 3)
        _ = accumulated.append(transfer(data: Data([1, 2])))
        #expect(accumulated.append(transfer(eof: true, data: Data([3, 4]))).isEmpty)
        #expect(accumulated.pendingByteCount == 0 && accumulated.requiresCleanRecovery)
        let recoveredAccumulator = accumulated.append(transfer(eof: true, data: Data([5])))
        #expect(recoveredAccumulator.count == 1 && recoveredAccumulator[0].data == Data([5]))
        #expect(accumulated.statistics.accumulatorOverflows == 1)
    }

    @Test func resetAndLossDropPartialBytesWithoutRevivingThem() {
        var assembler = UVCAccessUnitAssembler()
        _ = assembler.append(transfer(data: Data([1, 2])))
        assembler.reset()
        #expect(assembler.pendingByteCount == 0 && assembler.statistics == UVCAccessUnitAssemblerStatistics())
        #expect(assembler.append(transfer(eof: true, data: Data([3]))).first?.data == Data([3]))

        _ = assembler.append(transfer(data: Data([4])))
        assembler.markLoss()
        #expect(assembler.pendingByteCount == 0 && assembler.requiresCleanRecovery)
        let recovered = assembler.append(transfer(eof: true, data: Data([5])))
        #expect(recovered.count == 1 && recovered[0].data == Data([5]))
        #expect(assembler.statistics.losses == 1)
    }

    @Test func emptyEOFNeverPublishesAnEmptyAccessUnit() {
        var assembler = UVCAccessUnitAssembler()
        #expect(assembler.append(transfer(eof: true)).isEmpty)
        #expect(assembler.statistics.emptyEOFs == 1)
        _ = assembler.append(transfer(data: Data([1])))
        let completed = assembler.append(transfer(eof: true))
        #expect(completed.count == 1 && completed[0].data == Data([1]))
        #expect(completed[0].endedByEOF)
    }
}
