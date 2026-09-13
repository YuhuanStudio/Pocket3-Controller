import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Pocket3Core

private final class ProductOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HostHEVCEncodedSample] = []

    func append(_ value: HostHEVCEncodedSample) {
        lock.withLock { values.append(value) }
    }

    var samples: [HostHEVCEncodedSample] { lock.withLock { values } }
}

private final class ProductOutputBackend: @unchecked Sendable,
    HostHEVCEncoderBackend {
    private let lock = NSLock()
    private var calls = 0
    private var cancellations = 0
    private var resets = 0
    private let fails: Bool

    init(fails: Bool = false) { self.fails = fails }

    var encodeCount: Int { lock.withLock { calls } }
    var cancelCount: Int { lock.withLock { cancellations } }
    var resetCount: Int { lock.withLock { resets } }

    func encode(_ frame: HostVideoFrame,
                configuration _: HostVideoEncoderConfiguration) async throws
        -> HostHEVCEncodedSample {
        lock.withLock { calls += 1 }
        if fails { throw HostHEVCEncoderError.backendUnavailable }
        let sets = try VideoToolboxParameterSetBundle(codec: .hevc,
            parameterSets: [Data([0x40, 1]), Data([0x42, 1]), Data([0x44, 1])])
        return try HostHEVCEncodedSample(
            parameterSets: sets,
            accessUnit: Data([0, 0, 0, 2, 0x26, 1]),
            dimensions: CMVideoDimensions(width: 2, height: 2),
            presentationTimeStamp: frame.presentationTimeStamp,
            duration: frame.duration,
            sessionID: frame.sessionID,
            generation: frame.generation,
            sequence: frame.sequence,
            isKeyFrame: true)
    }

    func finish() async {}

    func cancel() async {
        lock.withLock { cancellations += 1 }
    }

    func reset() async {
        lock.withLock { resets += 1 }
    }
}

@Suite("Host HEVC product output", .serialized)
struct HostHEVCProductOutputTests {
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

    private func frame(
        sequence: UInt64,
        sessionID: String = "capture-one",
        generation: UInt64 = 1
    ) throws -> HostVideoFrame {
        HostVideoFrame(
            pixelBuffer: try pixelBuffer(),
            sessionID: sessionID,
            generation: generation,
            sequence: sequence,
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
        throw HostHEVCProductOutputError.outputNotRunning
    }

    @Test func selectionContractIsExplicitAndPreservesBGRAPreview() async throws {
        let backend = ProductOutputBackend()
        let service = try HostHEVCProductOutputService(
            configuration: configuration,
            backendFactory: { backend })

        let initial = await service.status()
        #expect(initial.selection == .bgraPreview)
        #expect(initial.phase == .bgraPreview)
        #expect(initial.capability.transport == nil)
        #expect(initial.capability.codecIdentifier == nil)
        #expect(initial.capability.supportsConcurrentBGRAPreview)
        #expect(!initial.capability.automaticFallback)
        #expect(initial.capability.usbWireCodecClaim == nil)

        let unselected = await service.submit(
            try frame(sequence: 1), receivedUptime: 1, nowUptime: 1.01)
        #expect(unselected.disposition == .notSelected)
        #expect(backend.encodeCount == 0)

        let selected = try await service.select(.hostHEVC)
        #expect(selected.selection == .hostHEVC)
        #expect(selected.phase == .idle)
        #expect(selected.capability.transport == .macVideoToolboxHost)
        #expect(selected.capability.codec == .hevc)
        #expect(selected.capability.codecIdentifier == "hvc1")
        #expect(selected.capability.supportsConcurrentBGRAPreview)
        #expect(!selected.capability.automaticFallback)
        #expect(selected.capability.usbWireCodecClaim == nil)
    }

    @Test func explicitStartSubmitsHostSamplesWithBoundedSinkLifecycle()
        async throws {
        let backend = ProductOutputBackend()
        let collector = ProductOutputCollector()
        let service = try HostHEVCProductOutputService(
            configuration: configuration,
            maximumInputAgeSeconds: 1,
            backendFactory: { backend })
        _ = try await service.select(.hostHEVC)
        let started = try await service.startHostHEVC(
            sessionID: "capture-one", generation: 1, sink: collector.append)
        #expect(started.phase == .running)
        #expect(started.sinkAttached)
        #expect(started.consumer == .localSampleEvidence)
        #expect(!started.capability.verified)

        let submitted = await service.submit(
            try frame(sequence: 2), receivedUptime: 10, nowUptime: 10.1)
        #expect(submitted.selection == .hostHEVC)
        #expect(submitted.disposition == .accepted)
        #expect(submitted.sessionEvidence?.disposition == .accepted)
        try await waitUntil { (await service.status()).capability.verified }

        let running = await service.status()
        #expect(running.isRunning)
        #expect(running.capability.transport == .macVideoToolboxHost)
        #expect(running.capability.codecIdentifier == "hvc1")
        #expect(running.capability.observedSampleCount == 1)
        #expect(running.consumer == .localSampleEvidence)
        #expect(running.capability.usbWireCodecClaim == nil)
        #expect(collector.samples.count == 1)
        #expect(collector.samples[0].isHostEncoded)

        let cancelled = await service.cancel()
        #expect(cancelled.selection == .hostHEVC)
        #expect(cancelled.phase == .cancelled)
        #expect(!cancelled.sinkAttached)
        #expect(cancelled.capability.verified)
        #expect(backend.cancelCount == 1)
        let after = await service.submit(
            try frame(sequence: 3), receivedUptime: 11, nowUptime: 11.1)
        #expect(after.disposition == .stopped)
        #expect(collector.samples.count == 1)
    }

    @Test func reconnectRequiresExactIdentityAndFencesOldSelection()
        async throws {
        let backend = ProductOutputBackend()
        let collector = ProductOutputCollector()
        let service = try HostHEVCProductOutputService(
            configuration: configuration,
            backendFactory: { backend })
        _ = try await service.select(.hostHEVC)
        _ = try await service.startHostHEVC(
            sessionID: "capture-one", generation: 1, sink: collector.append)

        await #expect(throws: HostHEVCProductOutputError.staleSession) {
            try await service.reconnect(
                expectedSessionID: "wrong-session", expectedGeneration: 1,
                newSessionID: "capture-two", newGeneration: 2)
        }
        await #expect(throws: HostHEVCProductOutputError.staleGeneration) {
            try await service.reconnect(
                expectedSessionID: "capture-one", expectedGeneration: 9,
                newSessionID: "capture-two", newGeneration: 2)
        }
        #expect(backend.resetCount == 0)

        let reconnected = try await service.reconnect(
            expectedSessionID: "capture-one", expectedGeneration: 1,
            newSessionID: "capture-two", newGeneration: 2)
        #expect(reconnected.phase == .running)
        #expect(reconnected.selection == .hostHEVC)
        #expect(reconnected.capability.sessionID == "capture-two")
        #expect(reconnected.capability.generation == 2)
        #expect(!reconnected.capability.verified)
        #expect(backend.resetCount == 1)

        let stale = await service.submit(
            try frame(sequence: 4, sessionID: "capture-one", generation: 1),
            receivedUptime: 20, nowUptime: 20.1)
        #expect(stale.disposition == .staleSession)
        let fresh = await service.submit(
            try frame(sequence: 5, sessionID: "capture-two", generation: 2),
            receivedUptime: 20, nowUptime: 20.1)
        #expect(fresh.disposition == .accepted)
        try await waitUntil { (await service.status()).capability.verified }
        #expect(collector.samples.map(\.sequence) == [5])
    }

    @Test func statusReportsBoundedEncodedCadenceAfterTwoSamples()
        async throws {
        let backend = ProductOutputBackend()
        let service = try HostHEVCProductOutputService(
            configuration: configuration, backendFactory: { backend })
        _ = try await service.select(.hostHEVC)
        _ = try await service.startHostHEVC(
            sessionID: "capture-one", generation: 1, sink: { _ in })
        _ = await service.submit(
            try frame(sequence: 1), receivedUptime: 10, nowUptime: 10.01)
        _ = await service.submit(
            try frame(sequence: 2), receivedUptime: 10.03, nowUptime: 10.04)
        try await waitUntil { (await service.status()).encodedFPS != nil }
        let status = await service.status()
        #expect(status.encodedFPS.map { abs($0 - 30) < 0.01 } == true)
        #expect(status.capability.observedSampleCount == 2)
        _ = await service.stop()
    }

    @Test func failedHostEncoderStaysFailedWithoutAutomaticBGRAFallback()
        async throws {
        let backend = ProductOutputBackend(fails: true)
        let service = try HostHEVCProductOutputService(
            configuration: configuration,
            backendFactory: { backend })
        _ = try await service.select(.hostHEVC)
        _ = try await service.startHostHEVC(
            sessionID: "capture-one", generation: 1, sink: { _ in })
        _ = await service.submit(
            try frame(sequence: 6), receivedUptime: 30, nowUptime: 30.1)
        try await waitUntil { (await service.status()).phase == .failed }

        let failed = await service.status()
        #expect(failed.selection == .hostHEVC)
        #expect(failed.phase == .failed)
        #expect(failed.capability.transport == .macVideoToolboxHost)
        #expect(!failed.capability.automaticFallback)
        #expect(failed.capability.usbWireCodecClaim == nil)
        #expect(backend.encodeCount == 1)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
