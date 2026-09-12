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

private final class ManualPocket3LiveViewClock: @unchecked Sendable,
    Pocket3LiveViewClock {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval = 0) { self.value = value }
    var now: TimeInterval { lock.withLock { value } }
    func advance(to value: TimeInterval) { lock.withLock { self.value = value } }
}

private final class FakePocket3LiveViewMediaSource: @unchecked Sendable,
    Pocket3LiveViewMediaSource {
    private let lock = NSLock()
    private var latest: Pocket3LiveViewMediaObservation?
    private var attached: [UInt64] = []
    private var flushed: [UInt64] = []

    var attachGenerations: [UInt64] { lock.withLock { attached } }
    var flushGenerations: [UInt64] { lock.withLock { flushed } }

    func attach(generation: UInt64) {
        lock.withLock { attached.append(generation); latest = nil }
    }

    func flush(generation: UInt64) {
        lock.withLock { flushed.append(generation); latest = nil }
    }

    func latestMediaObservation() -> Pocket3LiveViewMediaObservation? {
        lock.withLock { latest }
    }

    func publish(_ observation: Pocket3LiveViewMediaObservation) {
        lock.withLock { latest = observation }
    }
}

private final class AsyncPocket3LiveViewSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    func signal() {
        let value = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            signaled = true
            let value = continuation
            continuation = nil
            return value
        }
        value?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if signaled { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private class FakePocket3LiveViewCommandExecutor: @unchecked Sendable,
    Pocket3LiveViewCommandExecutor {
    private let lock = NSLock()
    private var requests: [NativeCommandTransactionRequest] = []

    var commandKinds: [Pocket3LiveViewSessionCommandKind] {
        lock.withLock {
            requests.compactMap { request in
                switch request.command {
                case .livePreviewHint: return .preEnableHint
                case .livePreviewEnable: return .enable
                case .livePreviewIDR: return .requestIDR
                default: return nil
                }
            }
        }
    }

    var requestCount: Int { lock.withLock { requests.count } }

    func execute(
        _ request: NativeCommandTransactionRequest,
        readiness: NativeCameraSessionStatus
    ) async throws -> NativeCommandTransactionResult {
        lock.withLock { requests.append(request) }
        var result = NativeCommandTransactionResult(
            id: request.id, command: request.command,
            generation: request.generation, sessionID: request.sessionID,
            end: .acknowledged)
        result.sequence = 1
        result.submitted = true
        result.responseReceived = true
        result.acknowledged = true
        result.responseStatus = 0
        return result
    }
}

private final class BlockingPocket3LiveViewCommandExecutor:
    FakePocket3LiveViewCommandExecutor, @unchecked Sendable {
    let entered = AsyncPocket3LiveViewSignal()
    let release = AsyncPocket3LiveViewSignal()

    override func execute(
        _ request: NativeCommandTransactionRequest,
        readiness: NativeCameraSessionStatus
    ) async throws -> NativeCommandTransactionResult {
        entered.signal()
        await release.wait()
        return try await super.execute(request, readiness: readiness)
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

    private func readyNativeSession() -> NativeCameraSessionStatus {
        var native = NativeCameraSession()
        let generation = native.begin(sessionID: UUID(), peerID: UUID())
        _ = native.markPaired(generation: generation)
        _ = native.markCredentialsAvailable(generation: generation)
        _ = native.beginDatalinkHandshake(generation: generation)
        _ = native.markCommandReady(generation: generation)
        return native.status
    }

    private func mediaObservation(
        generation: UInt64,
        messageID: UInt64 = 1,
        ready: Bool,
        randomAccess: Bool,
        uptime: TimeInterval
    ) -> Pocket3LiveViewMediaObservation {
        Pocket3LiveViewMediaObservation(
            generation: generation, messageID: messageID,
            codec: .h264, codecReady: ready,
            hasRandomAccessPoint: randomAccess, receivedUptime: uptime)
    }

    @Test func sessionCoordinatorIngestsBeforeSingleEnableAndWaitsForIDR() async throws {
        let source = FakePocket3LiveViewMediaSource()
        let executor = FakePocket3LiveViewCommandExecutor()
        let clock = ManualPocket3LiveViewClock()
        let coordinator = try Pocket3LiveViewSessionCoordinator(
            mediaSource: source, executor: executor, clock: clock)
        let session = readyNativeSession()

        let started = try coordinator.begin(session: session, nowUptime: 0)
        #expect(started.phase == .ingesting)
        #expect(source.attachGenerations == [session.generation])
        #expect(executor.requestCount == 0)
        do {
            _ = try await coordinator.enableIfReady(nowUptime: 0)
            Issue.record("Enable bypassed the ingest barrier")
        } catch Pocket3LiveViewSessionCoordinatorError.ingestRequired {
        }

        source.publish(mediaObservation(generation: session.generation,
                                        ready: false, randomAccess: false,
                                        uptime: 0))
        #expect(coordinator.ingestLatestMedia(nowUptime: 0))
        let result = try await coordinator.enableIfReady(nowUptime: 0)
        #expect(result.enable?.kind == .enable)
        #expect(result.idr?.kind == .requestIDR)
        #expect(executor.commandKinds == [.enable, .requestIDR])
        #expect(result.phase == .waitingForCodec)
        #expect(result.enable?.accepted == true)
        #expect(result.idr?.accepted == true)

        source.publish(mediaObservation(generation: session.generation,
                                        messageID: 2, ready: true,
                                        randomAccess: true, uptime: 0.1))
        #expect(coordinator.ingestLatestMedia(nowUptime: 0.1))
        let ready = coordinator.snapshot(nowUptime: 0.1)
        #expect(ready.phase == .ready)
        #expect(ready.codecReady && ready.firstRandomAccessObserved)
        #expect(ready.enableSendCount == 1)
        #expect(ready.idrRequestSendCount == 1)

        do {
            _ = try await coordinator.enableIfReady(nowUptime: 0.2)
            Issue.record("A second live-view enable was allowed")
        } catch Pocket3LiveViewSessionCoordinatorError.busy {
        }
    }

    @Test func optionalHintAndWatchdogNeverResendAfterStall() async throws {
        let source = FakePocket3LiveViewMediaSource()
        let executor = FakePocket3LiveViewCommandExecutor()
        let clock = ManualPocket3LiveViewClock()
        let coordinator = try Pocket3LiveViewSessionCoordinator(
            mediaSource: source, executor: executor,
            clock: clock,
            configuration: Pocket3LiveViewSessionConfiguration(
                sendPreEnableHint: true, warningAfter: 1,
                degradedAfter: 2, stalledAfter: 3))
        let session = readyNativeSession()
        _ = try coordinator.begin(session: session, nowUptime: 0)
        source.publish(mediaObservation(generation: session.generation,
                                        ready: false, randomAccess: false,
                                        uptime: 0))
        #expect(coordinator.ingestLatestMedia(nowUptime: 0))
        _ = try await coordinator.enableIfReady(nowUptime: 0)
        #expect(executor.commandKinds == [.preEnableHint, .enable, .requestIDR])

        let warning = coordinator.tick(nowUptime: 1.1)
        #expect(warning.phase == .warning)
        #expect(warning.stallStage == .warning)
        let stalled = coordinator.tick(nowUptime: 3.1)
        #expect(stalled.phase == .stalled)
        #expect(stalled.stallStage == .stalled)
        #expect(executor.requestCount == 3)
        _ = coordinator.tick(nowUptime: 6.2)
        #expect(executor.requestCount == 3)
    }

    @Test func cancellationDisconnectAndCooldownFenceOldGeneration() async throws {
        let source = FakePocket3LiveViewMediaSource()
        let executor = BlockingPocket3LiveViewCommandExecutor()
        let clock = ManualPocket3LiveViewClock()
        let coordinator = try Pocket3LiveViewSessionCoordinator(
            mediaSource: source, executor: executor, clock: clock)
        let session = readyNativeSession()
        _ = try coordinator.begin(session: session, nowUptime: 0)
        source.publish(mediaObservation(generation: session.generation,
                                        ready: false, randomAccess: false,
                                        uptime: 0))
        #expect(coordinator.ingestLatestMedia(nowUptime: 0))

        let enable = Task { try await coordinator.enableIfReady(nowUptime: 0) }
        await executor.entered.wait()
        let cancelled = coordinator.cancel(generation: session.generation,
                                            nowUptime: 0.1)
        #expect(cancelled.phase == .cancelled)
        executor.release.signal()
        let cancelledResult = try await enable.value
        #expect(cancelledResult.phase == .cancelled)
        #expect(executor.commandKinds == [.enable])
        #expect(source.flushGenerations == [session.generation])

        do {
            _ = try coordinator.begin(session: session, nowUptime: 1)
            Issue.record("Coordinator bypassed the multi-second cooldown")
        } catch Pocket3LiveViewSessionCoordinatorError.cooldown {
        }
        let disconnected = coordinator.disconnect(
            generation: session.generation, nowUptime: 4)
        #expect(disconnected.phase == .disconnected)
    }
}
