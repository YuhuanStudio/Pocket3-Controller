import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 pktType-02 live-view media assembler")
struct Pocket3LiveViewMediaTests {
    private let transportSession: UInt16 = 0x1234

    private let h264SPS = Data([0x67, 0x64, 0x00, 0x1F])
    private let h264PPS = Data([0x68, 0xEE, 0x3C, 0x80])
    private let h264IDR = Data([0x65, 0x88, 0x84])
    private let hevcVPS = Data([0x40, 0x01, 0xAA, 0xBB])
    private let hevcSPS = Data([0x42, 0x01, 0xCC, 0xDD])
    private let hevcPPS = Data([0x44, 0x01, 0xEE, 0xFF])
    private let hevcIRAP = Data([0x26, 0x01, 0x80])

    private func annex(_ units: [Data]) -> Data {
        var bytes = Data()
        for unit in units {
            bytes.append(contentsOf: [0, 0, 0, 1])
            bytes.append(unit)
        }
        return bytes
    }

    private func littleEndian(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }

    private func firstFragment(for media: Data, metadata: Data = Data([
        0x10, 0x20, 0x30, 0x40, 0x78, 0x56, 0x34, 0x12
    ]), prefixCount: Int) -> (Data, Data) {
        var header = Data([0, 0, 1, 0xFF])
        header.append(littleEndian(UInt32(media.count)))
        header.append(metadata)
        let count = min(prefixCount, media.count)
        header.append(media.prefix(count))
        return (header, Data(media.dropFirst(count)))
    }

    private func datagram(_ fragment: Data, sequence: UInt16) throws
        -> DJIUDPDatagram {
        var payload = DJIUDPFraming.routingHeader(
            peerAcknowledgment: 0, sequence: sequence, commandCounter: 1)
        payload.append(fragment)
        let encoded = try DJIUDPFraming.encode(packetType: .video,
            payload: payload, sessionID: transportSession, sequence: sequence)
        return try DJIUDPFraming.decode(encoded,
                                        expectedSessionID: transportSession)
    }

    private func feed(
        _ assembler: inout Pocket3LiveViewMediaAssembler,
        media: Data, firstSequence: UInt16 = 8,
        groupID: UInt32? = 1, prefixCount: Int = 8
    ) throws -> Pocket3LiveViewMediaMessage? {
        let (first, continuation) = firstFragment(for: media,
                                                   prefixCount: prefixCount)
        _ = try assembler.consume(try datagram(first, sequence: firstSequence),
                                  receivedUptime: 10, groupID: groupID)
        guard !continuation.isEmpty else {
            return assembler.pendingAccessUnits.last
        }
        return try assembler.consume(
            datagram(continuation, sequence: firstSequence &+ 8),
            receivedUptime: 10.1, groupID: groupID.map { $0 &+ 1 })
    }

    @Test func firstHeaderAndCrossGroupContinuationPreserveRawMetadata() throws {
        let media = annex([h264SPS, h264PPS, h264IDR])
        var assembler = try Pocket3LiveViewMediaAssembler(
            sessionID: transportSession)
        let maybeMessage = try feed(&assembler, media: media, prefixCount: 7)
        let message = try #require(maybeMessage)
        #expect(message.data == media)
        #expect(message.declaredLength == media.count)
        #expect(message.firstHeader.metadata == Data([
            0x10, 0x20, 0x30, 0x40, 0x78, 0x56, 0x34, 0x12
        ]))
        #expect(message.timestampCounter == 0x12345678)
        #expect(message.fragmentCount == 2)
        #expect(message.groupIDs == [1, 2])
        #expect(message.crossedGroupBoundary)
        #expect(message.codec == VideoToolboxCodec.h264)
        #expect(message.nalTypes == [7, 8, 5])
        #expect(message.containsIDR && message.isDecoderReady)
        #expect(message.videoToolboxInputValidated)
        #expect(message.normalizedData != nil)
        #expect(assembler.statistics.crossGroupContinuationCount == 1)
    }

    @Test func hevcParameterSetsAndIRAPOpenCodecGate() throws {
        let media = annex([hevcVPS, hevcSPS, hevcPPS, hevcIRAP])
        var assembler = try Pocket3LiveViewMediaAssembler(
            sessionID: transportSession, generation: 7)
        let maybeMessage = try feed(&assembler, media: media, prefixCount: 9)
        let message = try #require(maybeMessage)
        #expect(message.codec == VideoToolboxCodec.hevc)
        #expect(message.nalTypes == [32, 33, 34, 19])
        #expect(message.containsIRAP)
        #expect(message.isDecoderReady)
        #expect(message.decodeReadiness == Pocket3LiveViewDecodeReadiness.ready)
        #expect(message.videoToolboxInputValidated)
        #expect(message.generation == 7)
    }

    @Test func reorderAndSequenceLossDoNotCompleteStalePartial() throws {
        let media = annex([h264SPS, h264PPS, h264IDR])
        var assembler = try Pocket3LiveViewMediaAssembler(
            sessionID: transportSession)
        let (first, continuation) = firstFragment(for: media, prefixCount: 5)
        #expect(try assembler.consume(try datagram(first, sequence: 8),
                                      receivedUptime: 10) == nil)
        #expect(try assembler.consume(try datagram(first, sequence: 8),
                                      receivedUptime: 10.01) == nil)
        #expect(assembler.statistics.reorderedPacketCount == 1)
        #expect(try assembler.consume(try datagram(continuation, sequence: 24),
                                      receivedUptime: 10.1) == nil)
        #expect(!assembler.hasPartialMessage)
        #expect(assembler.statistics.lostPacketCount > 0)
        #expect(assembler.statistics.droppedPartialMessageCount > 0)

        let (replacement, _) = firstFragment(for: media, prefixCount: media.count)
        let maybeComplete = try assembler.consume(
            try datagram(replacement, sequence: 32), receivedUptime: 10.2)
        let complete = try #require(maybeComplete)
        #expect(complete.codec == VideoToolboxCodec.h264 && complete.isDecoderReady)
    }

    @Test func resetAndGenerationFenceRejectLatePackets() throws {
        let media = annex([h264SPS, h264PPS, h264IDR])
        var assembler = try Pocket3LiveViewMediaAssembler(
            sessionID: transportSession, generation: 3)
        let (first, _) = firstFragment(for: media, prefixCount: 4)
        _ = try assembler.consume(try datagram(first, sequence: 8),
                                  receivedUptime: 10)
        try assembler.reset(to: 4)
        #expect(assembler.generation == 4 && !assembler.hasPartialMessage)
        #expect(assembler.statistics.receivedPacketCount == 0)
        #expect(throws: Pocket3LiveViewMediaError.invalidGeneration) {
            try assembler.consume(try datagram(first, sequence: 8),
                                  receivedUptime: 10,
                                  expectedGeneration: 3)
        }
        _ = try assembler.consume(try datagram(first, sequence: 8),
                                 receivedUptime: 10,
                                 expectedGeneration: 4)
        #expect(assembler.hasPartialMessage)
        assembler.teardown()
        #expect(throws: Pocket3LiveViewMediaError.terminated) {
            try assembler.consume(try datagram(first, sequence: 16),
                                  receivedUptime: 10.1)
        }
    }

    @Test func declaredLengthOverrunAndPartialAgeAreBounded() throws {
        let media = annex([h264SPS, h264PPS, h264IDR])
        var assembler = try Pocket3LiveViewMediaAssembler(
            sessionID: transportSession,
            limits: Pocket3LiveViewMediaLimits(
                maximumMessageBytes: 64, maximumFragmentBytes: 64,
                maximumPartialAge: 0.5, maximumQueuedMessages: 2,
                maximumQueuedBytes: 512))
        var first = Data([0, 0, 1, 0xFF])
        first.append(littleEndian(UInt32(media.count)))
        first.append(Data(repeating: 0, count: 8))
        first.append(media.prefix(4))
        _ = try assembler.consume(try datagram(first, sequence: 8),
                                  receivedUptime: 10)
        #expect(try assembler.consume(
            try datagram(Data(media.dropFirst(4)), sequence: 16),
            receivedUptime: 10.6) == nil)
        #expect(!assembler.hasPartialMessage)

        var overrun = Data([0, 0, 1, 0xFF])
        overrun.append(littleEndian(1))
        overrun.append(Data(repeating: 0, count: 8))
        overrun.append(media.prefix(2))
        #expect(throws: Pocket3LiveViewMediaError.fragmentOverrun) {
            try assembler.consume(try datagram(overrun, sequence: 24),
                                  receivedUptime: 11)
        }
        #expect(!assembler.hasPartialMessage)
    }

    @Test func queueIsBoundedAndDequeueIsDeterministic() throws {
        let media = annex([h264SPS, h264PPS, h264IDR])
        var assembler = try Pocket3LiveViewMediaAssembler(
            sessionID: transportSession,
            limits: Pocket3LiveViewMediaLimits(
                maximumQueuedMessages: 1, maximumQueuedBytes: 512))
        let first = try feed(&assembler, media: media, firstSequence: 8,
                             prefixCount: media.count)
        let second = try feed(&assembler, media: media, firstSequence: 16,
                              prefixCount: media.count)
        #expect(first != nil && second != nil)
        #expect(assembler.pendingAccessUnitCount == 1)
        #expect(assembler.statistics.queueDropCount == 1)
        #expect(assembler.dequeue()?.messageID == second?.messageID)
        #expect(assembler.dequeue() == nil)
    }

    @Test func malformedPacketAndUnknownCodecRetainBoundedEvidence() throws {
        var assembler = try Pocket3LiveViewMediaAssembler(
            sessionID: transportSession)
        #expect(throws: Pocket3LiveViewMediaError.wrongPacketType) {
            let payload = DJIUDPFraming.routingHeader(
                peerAcknowledgment: 0, sequence: 8, commandCounter: 1)
            let encoded = try DJIUDPFraming.encode(packetType: .channel3,
                payload: payload, sessionID: transportSession, sequence: 8)
            try assembler.consume(try DJIUDPFraming.decode(
                encoded, expectedSessionID: transportSession),
                receivedUptime: 10)
        }
        let unknown = Data([0, 0, 0, 1, 0x0F, 0x01, 0x02])
        let maybeMessage = try feed(&assembler, media: unknown, prefixCount: unknown.count)
        let message = try #require(maybeMessage)
        #expect(message.codec == nil && message.decodeReadiness == Pocket3LiveViewDecodeReadiness.unknown)
        #expect(message.normalizationError == "codec_unknown")
        #expect(message.metadata.count == 8 && message.firstHeader.raw.count == 16)
        #expect(assembler.statistics.codecDetectionFailureCount == 1)
    }
}
