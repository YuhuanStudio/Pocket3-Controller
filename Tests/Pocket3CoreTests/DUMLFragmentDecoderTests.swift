import Foundation
import Testing
@testable import Pocket3Core

@Suite struct DUMLFragmentDecoderTests {
    private func frame(sequence: UInt16 = 1, payload: Data = Data([1, 2, 3])) -> DUMLFrame {
        DUMLFrame(source: 2, destination: 7, sequence: sequence, flags: 0,
            commandSet: 0x0d, commandID: 2, payload: payload)
    }

    @Test func arbitraryFragmentBoundariesYieldOnlyWholeValidatedFrames() throws {
        let expected = frame()
        let encoded = try DUMLCodec.encode(expected)
        for split in 1..<encoded.count {
            var decoder = DUMLFragmentDecoder()
            let outcome1 = try decoder.append(encoded.prefix(split), at: 1).isEmpty
            #expect(outcome1)
            let packets = try decoder.append(encoded.dropFirst(split), at: 1.1)
            #expect(packets.count == 1)
            #expect(packets.first?.frame == expected && packets.first?.frameData == encoded)
            #expect(decoder.pendingByteCount == 0)
        }
        var bytewise = DUMLFragmentDecoder()
        var results: [ValidatedDUMLPacket] = []
        for byte in encoded { results += try bytewise.append(Data([byte]), at: 1) }
        #expect(results.count == 1 && results[0].frame == expected)
    }

    @Test func concatenatedFramesAndLeadingGarbageResynchronize() throws {
        let first = try DUMLCodec.encode(frame())
        let second = try DUMLCodec.encode(frame(sequence: 2))
        var decoder = DUMLFragmentDecoder()
        let packets = try decoder.append(Data([0, 0xff, 0x12]) + first + second, at: 1)
        #expect(packets.map(\.frame.sequence) == [1, 2])
        #expect(decoder.statistics.discardedBytes == 3)
        #expect(decoder.statistics.validFrames == 2)
    }

    @Test func badHeaderAndBodyCRCDoNotReachTheCallback() throws {
        let valid = try DUMLCodec.encode(frame())
        var header = valid; header[3] ^= 1
        var body = valid; body[body.count - 1] ^= 1
        var decoder = DUMLFragmentDecoder()
        let packets = try decoder.append(header + body + valid, at: 1)
        #expect(packets.count == 1 && packets.first?.frameData == valid)
        #expect(decoder.statistics.invalidHeaders >= 1)
        #expect(decoder.statistics.invalidFrames >= 1)
    }

    @Test func pendingFragmentsHaveAnAbsoluteDeadlineNotAnIdleDeadline() throws {
        let encoded = try DUMLCodec.encode(frame())
        var decoder = DUMLFragmentDecoder()
        let outcome2 = try decoder.append(encoded.prefix(4), at: 1).isEmpty
        #expect(outcome2)
        let outcome3 = try decoder.append(encoded[4..<6], at: 2.9).isEmpty
        #expect(outcome3)
        let outcome4 = decoder.expire(at: 3)
        #expect(outcome4)
        #expect(decoder.pendingByteCount == 0 && decoder.statistics.expiredFragments == 1)
        let outcome5 = try decoder.append(encoded.dropFirst(6), at: 3.1).isEmpty
        #expect(outcome5)
        let outcome6 = try decoder.append(encoded, at: 3.2).count == 1
        #expect(outcome6)
    }

    @Test func overflowClearsPendingBytesAndRecoveryStartsFresh() throws {
        let encoded = try DUMLCodec.encode(frame())
        var decoder = DUMLFragmentDecoder()
        _ = try decoder.append(encoded.prefix(4), at: 1)
        #expect(throws: DUMLFragmentError.byteBudgetExceeded) {
            try decoder.append(Data(repeating: 0, count: DUMLFragmentDecoder.maximumBufferedBytes), at: 1.1)
        }
        #expect(decoder.pendingByteCount == 0 && decoder.statistics.overflows == 1)
        let outcome7 = try decoder.append(encoded, at: 1.2).count == 1
        #expect(outcome7)
    }

    @Test func twoCharacteristicsCannotCompleteEachOthersPartialFrames() throws {
        let encoded = try DUMLCodec.encode(frame())
        var fff4 = DUMLFragmentDecoder(), fff5 = DUMLFragmentDecoder()
        let outcome8 = try fff4.append(encoded.prefix(6), at: 1).isEmpty
        #expect(outcome8)
        let outcome9 = try fff5.append(encoded.dropFirst(6), at: 1.1).isEmpty
        #expect(outcome9)
        let outcome10 = try fff4.append(encoded.dropFirst(6), at: 1.2).count == 1
        #expect(outcome10)
        #expect(fff5.statistics.validFrames == 0)
    }

    @Test func resetAndInvalidClocksCannotReviveAnOldFragment() throws {
        let encoded = try DUMLCodec.encode(frame())
        var decoder = DUMLFragmentDecoder()
        _ = try decoder.append(encoded.prefix(5), at: 10)
        let outcome11 = decoder.expire(at: 9)
        #expect(outcome11)
        _ = try decoder.append(encoded.prefix(5), at: 10)
        #expect(throws: DUMLFragmentError.invalidClock) { try decoder.append(Data(), at: .nan) }
        #expect(decoder.pendingByteCount == 0)
        decoder.reset()
        #expect(decoder.statistics == DUMLFragmentStatistics())
    }

    @Test func cancellationDropsPendingBytesWithoutCallingItATimeout() throws {
        var decoder = DUMLFragmentDecoder()
        let encoded = try DUMLCodec.encode(frame())
        _ = try decoder.append(encoded.prefix(5), at: 1)
        decoder.discardPending()
        #expect(decoder.pendingByteCount == 0)
        #expect(decoder.statistics.discardedBytes == 5)
        #expect(decoder.statistics.expiredFragments == 0)
    }
}
