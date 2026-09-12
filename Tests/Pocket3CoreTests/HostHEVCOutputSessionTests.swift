import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Pocket3Core

private final class OutputSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    func signal() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            signaled = true
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if signaled { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private final class OutputSessionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HostHEVCEncodedSample] = []

    func append(_ value: HostHEVCEncodedSample) {
        lock.withLock { values.append(value) }
    }

    var samples: [HostHEVCEncodedSample] { lock.withLock { values } }
}

private final class OutputSessionFakeBackend: @unchecked Sendable,
    HostHEVCEncoderBackend {
    let entered = OutputSessionGate()
    let proceed = OutputSessionGate()
    private let lock = NSLock()
    private var calls = 0
    private var cancels = 0
    private var resets = 0
    private let blockFirst: Bool

    init(blockFirst: Bool = false) { self.blockFirst = blockFirst }

    var encodeCount: Int { lock.withLock { calls } }
    var cancelCount: Int { lock.withLock { cancels } }
    var resetCount: Int { lock.withLock { resets } }

    func encode(_ frame: HostVideoFrame,
                configuration _: HostVideoEncoderConfiguration) async throws
        -> HostHEVCEncodedSample {
        let call = lock.withLock { calls += 1; return calls }
        if blockFirst && call == 1 {
            entered.signal()
            await proceed.wait()
        }
        guard !Task.isCancelled else { throw HostHEVCEncoderError.cancelled }
        let sets = try VideoToolboxParameterSetBundle(codec: .hevc,
            parameterSets: [Data([0x40, 1, 1]), Data([0x42, 1, 1]), Data([0x44, 1, 1])])
        return try HostHEVCEncodedSample(
            parameterSets: sets, accessUnit: Data([0, 0, 0, 2, 0x26, 1]),
            dimensions: CMVideoDimensions(
                width: Int32(CVPixelBufferGetWidth(frame.pixelBuffer)),
                height: Int32(CVPixelBufferGetHeight(frame.pixelBuffer))),
            presentationTimeStamp: frame.presentationTimeStamp,
            duration: frame.duration,
            sessionID: frame.sessionID, generation: frame.generation,
            sequence: frame.sequence, isKeyFrame: true)
    }

    func finish() async {}

    func cancel() async {
        lock.withLock { cancels += 1 }
        proceed.signal()
    }

    func reset() async {
        lock.withLock { resets += 1 }
        proceed.signal()
    }
}

@Suite("Host HEVC output session", .serialized)
struct HostHEVCOutputSessionTests {
    private let configuration = try! HostVideoEncoderConfiguration(
        width: 2, height: 2, frameRate: 30, keyFrameInterval: 30,
        maximumPendingFrames: 2)

    private func pixelBuffer(_ format: OSType = kCVPixelFormatType_32BGRA)
        throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status: CVReturn
        if format == kCVPixelFormatType_32BGRA {
            status = CVPixelBufferCreate(nil, 2, 2, format,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &buffer)
        } else {
            status = CVPixelBufferCreate(nil, 2, 2, format, nil, &buffer)
        }
        guard status == kCVReturnSuccess, let buffer else {
            throw HostHEVCEncoderError.invalidPixelBuffer
        }
        return buffer
    }

    private func frame(
        sequence: UInt64, sessionID: String = "capture-one", generation: UInt64 = 1,
        format: OSType = kCVPixelFormatType_32BGRA
    ) throws -> HostVideoFrame {
        HostVideoFrame(
            pixelBuffer: try pixelBuffer(format), sessionID: sessionID,
            generation: generation, sequence: sequence,
            presentationTimeStamp: CMTime(value: Int64(sequence), timescale: 30),
            duration: CMTime(value: 1, timescale: 30))
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw HostHEVCOutputSessionError.invalidFreshnessWindow
    }

    @Test func freshBGRAFrameEmitsCopiedHostHVC1WithCapabilityEvidence()
        async throws {
        let backend = OutputSessionFakeBackend()
        let collector = OutputSessionCollector()
        let service = try HostHEVCOutputSession(
            sessionID: "capture-one", generation: 1,
            configuration: configuration, backend: backend,
            maximumInputAgeSeconds: 1, sink: collector.append)

        let evidence = await service.submit(
            try frame(sequence: 1), receivedUptime: 10, nowUptime: 10.1)
        #expect(evidence.disposition == .accepted)
        #expect(evidence.inputPixelFormat == .bgra)
        #expect(abs((evidence.inputAgeSeconds ?? .nan) - 0.1) < 0.000_001)
        try await waitUntil { (await service.snapshot()).capability.verified }

        let snapshot = await service.snapshot()
        #expect(snapshot.capability.transport == .macVideoToolboxHost)
        #expect(snapshot.capability.codec == .hevc)
        #expect(snapshot.capability.codecIdentifier == "hvc1")
        #expect(snapshot.capability.usbWireCodecClaim == nil)
        #expect(snapshot.capability.observedSampleCount == 1)
        #expect(snapshot.lastOutputSequence == 1)
        #expect(collector.samples.count == 1)
        #expect(collector.samples[0].isHostEncoded)
        #expect(collector.samples[0].usbWireCodecClaim == nil)
    }

    @Test func staleOrInvalidFrameNeverReachesBackend() async throws {
        let backend = OutputSessionFakeBackend()
        let service = try HostHEVCOutputSession(
            sessionID: "capture-one", generation: 1,
            configuration: configuration, backend: backend,
            maximumInputAgeSeconds: 0.5)

        let stale = await service.submit(
            try frame(sequence: 1), receivedUptime: 10, nowUptime: 10.6)
        let invalidClock = await service.submit(
            try frame(sequence: 2), receivedUptime: 11, nowUptime: 10)
        let wrongSession = await service.submit(
            try frame(sequence: 3, sessionID: "capture-two"),
            receivedUptime: 10, nowUptime: 10.1)
        #expect(stale.disposition == .inputStale)
        #expect(invalidClock.disposition == .inputClockInvalid)
        #expect(wrongSession.disposition == .staleSession)
        #expect(backend.encodeCount == 0)
    }

    @Test func reconnectFencesOldOutputAndResetsCapabilityIdentity()
        async throws {
        let backend = OutputSessionFakeBackend(blockFirst: true)
        let collector = OutputSessionCollector()
        let service = try HostHEVCOutputSession(
            sessionID: "capture-one", generation: 1,
            configuration: configuration, backend: backend,
            sink: collector.append)

        _ = await service.submit(
            try frame(sequence: 1), receivedUptime: 10, nowUptime: 10.1)
        await backend.entered.wait()
        let reconnected = await service.reconnect(
            sessionID: "capture-two", generation: 2)
        #expect(reconnected.phase == .running)
        #expect(reconnected.sessionID == "capture-two")
        #expect(reconnected.generation == 2)
        #expect(!reconnected.capability.verified)
        #expect(reconnected.capability.observedSampleCount == 0)

        let fresh = await service.submit(
            try frame(sequence: 2, sessionID: "capture-two", generation: 2),
            receivedUptime: 20, nowUptime: 20.1)
        #expect(fresh.disposition == .accepted)
        try await waitUntil { (await service.snapshot()).capability.verified }
        #expect(collector.samples.map(\.sequence) == [2])
        #expect(backend.cancelCount == 1)
        #expect(backend.resetCount == 1)
    }

    @Test func nv12InputAndStopCleanupRemainBounded() async throws {
        let backend = OutputSessionFakeBackend()
        let collector = OutputSessionCollector()
        let service = try HostHEVCOutputSession(
            sessionID: "capture-one", generation: 1,
            configuration: configuration, backend: backend,
            sink: collector.append)

        let accepted = await service.submit(
            try frame(sequence: 1,
                      format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            receivedUptime: 1, nowUptime: 1.01)
        #expect(accepted.disposition == .accepted)
        try await waitUntil { (await service.snapshot()).capability.verified }
        let stopped = await service.stop()
        #expect(stopped.phase == .stopped)
        #expect(stopped.encoder.phase == .stopped)
        #expect(backend.cancelCount == 1)
        let after = await service.submit(
            try frame(sequence: 2), receivedUptime: 2, nowUptime: 2.01)
        #expect(after.disposition == .stopped)
        #expect(collector.samples.count == 1)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
