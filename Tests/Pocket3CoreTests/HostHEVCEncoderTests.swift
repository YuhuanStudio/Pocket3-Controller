import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import Pocket3Core

private final class HostHEVCGate: @unchecked Sendable {
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

private final class HostHEVCCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HostHEVCEncodedSample] = []

    func append(_ value: HostHEVCEncodedSample) {
        lock.withLock { values.append(value) }
    }

    var samples: [HostHEVCEncodedSample] { lock.withLock { values } }
}

private final class FakeHostHEVCBackend: @unchecked Sendable,
    HostHEVCEncoderBackend {
    let firstEntered = HostHEVCGate()
    let firstProceed = HostHEVCGate()
    private let lock = NSLock()
    private var calls = 0
    private var cancellations = 0
    private var resets = 0

    var encodeCount: Int { lock.withLock { calls } }
    var cancelCount: Int { lock.withLock { cancellations } }
    var resetCount: Int { lock.withLock { resets } }

    func encode(_ frame: HostVideoFrame,
                configuration _: HostVideoEncoderConfiguration) async throws
        -> HostHEVCEncodedSample {
        let call = lock.withLock { calls += 1; return calls }
        if call == 1 {
            firstEntered.signal()
            await firstProceed.wait()
        }
        guard !Task.isCancelled else { throw HostHEVCEncoderError.cancelled }
        return try Self.sample(for: frame)
    }

    func finish() async {}

    func cancel() async {
        lock.withLock { cancellations += 1 }
        firstProceed.signal()
    }

    func reset() async {
        lock.withLock { resets += 1 }
        firstProceed.signal()
    }

    private static func sample(for frame: HostVideoFrame)
        throws -> HostHEVCEncodedSample {
        let vps = Data([0x40, 0x01, 0x01])
        let sps = Data([0x42, 0x01, 0x01])
        let pps = Data([0x44, 0x01, 0x01])
        let parameterSets = try VideoToolboxParameterSetBundle(
            codec: .hevc, parameterSets: [vps, sps, pps])
        return try HostHEVCEncodedSample(
            parameterSets: parameterSets,
            accessUnit: Data([0, 0, 0, 2, 0x26, 0x01]),
            dimensions: CMVideoDimensions(width: 2, height: 2),
            presentationTimeStamp: frame.presentationTimeStamp,
            duration: frame.duration,
            sessionID: frame.sessionID, generation: frame.generation,
            sequence: frame.sequence, isKeyFrame: true)
    }
}

@Suite("Host HEVC encoder core", .serialized)
struct HostHEVCEncoderTests {
    private let configuration = try! HostVideoEncoderConfiguration(
        width: 2, height: 2, frameRate: 30, keyFrameInterval: 30,
        maximumPendingFrames: 2)

    private func pixelBuffer() throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, 2, 2, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &value)
        guard status == kCVReturnSuccess, let value else {
            throw HostHEVCEncoderError.invalidPixelBuffer
        }
        return value
    }

    private func frame(sequence: UInt64, generation: UInt64 = 1,
                       sessionID: String = "capture-one") throws -> HostVideoFrame {
        HostVideoFrame(
            pixelBuffer: try pixelBuffer(), sessionID: sessionID,
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
        throw HostHEVCEncoderError.videoToolbox(-1)
    }

    @Test func boundedQueueDropsNewestFrameAndPreservesHostProvenance()
        async throws {
        let backend = FakeHostHEVCBackend()
        let collector = HostHEVCCollector()
        let encoder = HostHEVCEncoder(
            sessionID: "capture-one", generation: 1,
            configuration: configuration, backend: backend,
            output: collector.append)

        #expect((await encoder.submit(try frame(sequence: 1))).disposition == .accepted)
        await backend.firstEntered.wait()
        #expect((await encoder.submit(try frame(sequence: 2))).disposition == .accepted)
        #expect((await encoder.submit(try frame(sequence: 3))).disposition == .accepted)
        let dropped = await encoder.submit(try frame(sequence: 4))
        #expect(dropped.disposition == .droppedBackpressure)

        backend.firstProceed.signal()
        try await waitUntil { await encoder.snapshot().encodedFrames == 3 }
        let snapshot = await encoder.snapshot()
        #expect(snapshot.droppedBackpressure == 1)
        #expect(collector.samples.map(\.sequence) == [1, 2, 3])
        #expect(collector.samples.allSatisfy { $0.isHostEncoded && $0.usbWireCodecClaim == nil })
    }

    @Test func generationResetFencesLateOutputAndAcceptsFreshFrame()
        async throws {
        let backend = FakeHostHEVCBackend()
        let collector = HostHEVCCollector()
        let encoder = HostHEVCEncoder(
            sessionID: "capture-one", generation: 1,
            configuration: configuration, backend: backend,
            output: collector.append)

        _ = await encoder.submit(try frame(sequence: 1))
        await backend.firstEntered.wait()
        await encoder.reset(sessionID: "capture-one", generation: 2)
        backend.firstProceed.signal()
        try await waitUntil { await encoder.snapshot().droppedStaleOutput == 1 }

        let fresh = await encoder.submit(try frame(sequence: 2, generation: 2))
        #expect(fresh.disposition == .accepted)
        try await waitUntil { await encoder.snapshot().encodedFrames == 1 }
        #expect(collector.samples.map(\.sequence) == [2])
        #expect(await encoder.snapshot().generation == 2)
        #expect(backend.resetCount == 1)
    }

    @Test func staleSessionAndGenerationAreRejectedBeforeBackendCall()
        async throws {
        let backend = FakeHostHEVCBackend()
        let encoder = HostHEVCEncoder(
            sessionID: "capture-one", generation: 4,
            configuration: configuration, backend: backend)

        #expect((await encoder.submit(try frame(
            sequence: 1, generation: 4, sessionID: "capture-two"))).disposition == .staleSession)
        #expect((await encoder.submit(try frame(
            sequence: 2, generation: 3))).disposition == .staleGeneration)
        #expect(backend.encodeCount == 0)
    }

    @Test func stopCancelsInFlightFrameAndRejectsFutureFrames() async throws {
        let backend = FakeHostHEVCBackend()
        let collector = HostHEVCCollector()
        let encoder = HostHEVCEncoder(
            sessionID: "capture-one", generation: 1,
            configuration: configuration, backend: backend,
            output: collector.append)

        _ = await encoder.submit(try frame(sequence: 1))
        await backend.firstEntered.wait()
        let stopped = await encoder.stop()
        #expect(stopped.phase == .stopped)
        #expect(backend.cancelCount == 1)
        #expect(collector.samples.isEmpty)
        #expect((await encoder.submit(try frame(sequence: 2))).disposition == .stopped)
    }

    @Test func videoToolboxBackendEncodesSyntheticBGRAAsHostHEVC() async throws {
        let backend = VideoToolboxHostHEVCEncoderBackend()
        let frame = try frame(sequence: 1)
        let sample = try await backend.encode(frame, configuration: configuration)
        #expect(sample.codec == .hevc)
        #expect(sample.transport == .macVideoToolboxHost)
        #expect(sample.isHostEncoded)
        #expect(sample.usbWireCodecClaim == nil)
        #expect(sample.parameterSets.codec == .hevc)
        #expect(sample.accessUnit.isEmpty == false)
        #expect(sample.dimensions.width == 2 && sample.dimensions.height == 2)
        await backend.finish()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
