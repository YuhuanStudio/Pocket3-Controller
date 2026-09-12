import Foundation
import Testing
@testable import Pocket3Core

private final class RecordingPocket3LiveViewDecoder: @unchecked Sendable,
    Pocket3LiveViewDecoder {
    private let lock = NSLock()
    private var decodeCount = 0
    private var resetValues: [UInt64] = []
    private let entered: DispatchSemaphore?
    private let release: DispatchSemaphore?

    init(blocking: Bool = false) {
        if blocking {
            entered = DispatchSemaphore(value: 0)
            release = DispatchSemaphore(value: 0)
        } else {
            entered = nil
            release = nil
        }
    }

    var calls: Int { lock.withLock { decodeCount } }
    var resets: [UInt64] { lock.withLock { resetValues } }

    func waitUntilDecodeEntered() -> Bool {
        entered?.wait(timeout: .now() + 1) == .success
    }

    func releaseDecode() { release?.signal() }

    func decode(_ request: Pocket3LiveViewDecodeRequest)
        throws -> Pocket3LiveViewDecodedFrame {
        entered?.signal()
        if let release {
            _ = release.wait(timeout: .now() + 1)
        }
        lock.withLock { decodeCount += 1 }
        return Pocket3LiveViewDecodedFrame(status: 0)
    }

    func reset(generation: UInt64) {
        lock.withLock { resetValues.append(generation) }
    }
}

@Suite("Pocket 3 live-view sink and decoder service")
struct Pocket3LiveViewDecoderTests {
    private let session: UInt16 = 0x3344
    private let sps = Data([0x67, 0x64, 0x00, 0x1f])
    private let pps = Data([0x68, 0xee, 0x3c, 0x80])
    private let idr = Data([0x65, 0x88, 0x84])

    private func annex(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { result, unit in
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(unit)
        }
    }

    private func littleEndian(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
              UInt8((value >> 16) & 0xff), UInt8(value >> 24)])
    }

    private func datagram(_ media: Data, sequence: UInt16 = 8)
        throws -> DJIUDPDatagram {
        var fragment = Data([0, 0, 1, 0xff])
        fragment.append(littleEndian(UInt32(media.count)))
        fragment.append(Data(repeating: 0, count: 8))
        fragment.append(media)
        var payload = DJIUDPFraming.routingHeader(
            peerAcknowledgment: 0, sequence: sequence, commandCounter: 1)
        payload.append(fragment)
        let encoded = try DJIUDPFraming.encode(
            packetType: .video, payload: payload,
            sessionID: session, sequence: sequence)
        return try DJIUDPFraming.decode(encoded, expectedSessionID: session)
    }

    private func message(media: Data, sequence: UInt16 = 8)
        throws -> Pocket3LiveViewMediaMessage {
        var assembler = try Pocket3LiveViewMediaAssembler(sessionID: session)
        guard let result = try assembler.consume(
            datagram(media, sequence: sequence), receivedUptime: 10) else {
            throw Pocket3LiveViewDecoderError.invalidInput
        }
        return result
    }

    @Test func readinessGateAndGenerationFenceAreVisibleInEvidence() throws {
        let decoder = RecordingPocket3LiveViewDecoder()
        let service = try Pocket3LiveViewDecodeService(
            decoder: decoder, generation: 1)
        let waiting = try message(media: annex([sps, pps]))
        let ready = try message(media: annex([sps, pps, idr]))

        let skipped = service.submit(waiting)
        #expect(skipped.disposition == .skippedNotReady)
        #expect(!skipped.decoderSubmitted)
        #expect(decoder.calls == 0)

        let queued = service.submit(ready)
        #expect(queued.disposition == .queued)
        #expect(!queued.decoderSubmitted)
        #expect(service.waitUntilIdle(timeout: 1))
        let decoded = try #require(service.dequeueEvidence())
        #expect(decoded.disposition == .decoded)
        #expect(decoded.decoderSubmitted)
        #expect(!decoded.didProduceFrame)
        #expect(decoded.parameterSetRebuilt)
        #expect(decoder.calls == 1)

        _ = try service.reset(to: 2)
        let stale = service.submit(ready, expectedGeneration: 1)
        #expect(stale.disposition == .droppedStaleGeneration)
        #expect(decoder.calls == 1)
        #expect(decoder.resets.contains(2))
    }

    @Test func decodeQueueAppliesBoundedBackpressureWithoutRetry() throws {
        let decoder = RecordingPocket3LiveViewDecoder(blocking: true)
        let service = try Pocket3LiveViewDecodeService(
            decoder: decoder, generation: 1,
            limits: Pocket3LiveViewDecodeServiceLimits(
                maximumPendingMessages: 1, maximumEvidence: 4))
        let ready = try message(media: annex([sps, pps, idr]))

        #expect(service.submit(ready).disposition == .queued)
        #expect(decoder.waitUntilDecodeEntered())
        #expect(service.submit(ready).disposition == .queued)
        let dropped = service.submit(ready)
        #expect(dropped.disposition == .droppedBackpressure)
        #expect(!dropped.decoderSubmitted)
        #expect(decoder.calls == 0)

        decoder.releaseDecode()
        decoder.releaseDecode()
        #expect(service.waitUntilIdle(timeout: 1))
        #expect(decoder.calls == 2)
        #expect(service.statistics().queueDropCount == 1)
    }

    @Test func mediaSinkFlushesAndRejectsLateGenerationPackets() throws {
        let decoder = RecordingPocket3LiveViewDecoder()
        let service = try Pocket3LiveViewDecodeService(
            decoder: decoder, generation: 1)
        let sink = try Pocket3LiveViewMediaSink(
            sessionID: session, generation: 1, decoderService: service)
        let media = annex([sps, pps, idr])

        sink.receive(try datagram(media), generation: 1)
        #expect(service.waitUntilIdle(timeout: 1))
        let evidence = try #require(sink.dequeueDecodeEvidence())
        #expect(evidence.disposition == .decoded)
        #expect(decoder.calls == 1)

        sink.flush(generation: 1)
        sink.receive(try datagram(media, sequence: 16), generation: 1)
        #expect(sink.staleDatagrams == 1)
        #expect(decoder.calls == 1)

        sink.attach(generation: 2)
        sink.receive(try datagram(media, sequence: 24), generation: 1)
        #expect(sink.staleDatagrams == 1)
        sink.receive(try datagram(media, sequence: 32), generation: 2)
        #expect(service.waitUntilIdle(timeout: 1))
        #expect(decoder.calls == 2)
    }
}
