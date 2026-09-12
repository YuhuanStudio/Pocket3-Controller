import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Pocket3Core

private final class ValidationSource: @unchecked Sendable,
    HostHEVCFrameSource {
    private let lock = NSLock()
    private var bindingValue: HostHEVCFrameSourceBinding
    private let pixelBuffer: CVPixelBuffer
    private var sequence: UInt64 = 0
    private var freshCount = 0

    init(binding: HostHEVCFrameSourceBinding,
         pixelBuffer: CVPixelBuffer) {
        self.bindingValue = binding
        self.pixelBuffer = pixelBuffer
    }

    var count: Int { lock.withLock { freshCount } }

    func currentBinding() -> HostHEVCFrameSourceBinding? {
        lock.withLock { bindingValue }
    }

    func freshFrame(expected: HostHEVCFrameSourceBinding,
                    maxAgeSeconds _: Double) throws -> HostHEVCFreshFrame {
        try lock.withLock {
            guard bindingValue == expected else {
                throw HostHEVCFrameSourceError.sessionChanged
            }
            freshCount += 1
            sequence += 1
            let frame = HostVideoFrame(
                pixelBuffer: pixelBuffer,
                sessionID: bindingValue.captureSessionID,
                generation: bindingValue.generation,
                sequence: sequence,
                presentationTimeStamp: CMTime(
                    value: Int64(sequence), timescale: 30),
                duration: CMTime(value: 1, timescale: 30))
            return HostHEVCFreshFrame(
                frame: frame, binding: bindingValue,
                receivedUptime: ProcessInfo.processInfo.systemUptime)
        }
    }

    func replaceBinding(_ binding: HostHEVCFrameSourceBinding) {
        lock.withLock { bindingValue = binding }
    }
}

private final class ValidationBackend: @unchecked Sendable,
    HostHEVCEncoderBackend {
    private let lock = NSLock()
    private var calls = 0
    private var cancels = 0
    private var resets = 0

    var encodeCount: Int { lock.withLock { calls } }
    var cancelCount: Int { lock.withLock { cancels } }
    var resetCount: Int { lock.withLock { resets } }

    func encode(_ frame: HostVideoFrame,
                configuration _: HostVideoEncoderConfiguration) async throws
        -> HostHEVCEncodedSample {
        lock.withLock { calls += 1 }
        let sets = try VideoToolboxParameterSetBundle(codec: .hevc,
            parameterSets: [Data([0x40, 1]), Data([0x42, 1]), Data([0x44, 1])])
        return try HostHEVCEncodedSample(
            parameterSets: sets, accessUnit: Data([0, 0, 0, 2, 0x26, 1]),
            dimensions: CMVideoDimensions(width: 2, height: 2),
            presentationTimeStamp: frame.presentationTimeStamp,
            duration: frame.duration,
            sessionID: frame.sessionID, generation: frame.generation,
            sequence: frame.sequence, isKeyFrame: true)
    }

    func finish() async {}
    func cancel() async { lock.withLock { cancels += 1 } }
    func reset() async { lock.withLock { resets += 1 } }
}

@Suite("Host HEVC developer validation", .serialized)
struct HostHEVCValidationTests {
    private let deviceID = "device-one"
    private let sessionID = "capture-one"

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

    private func binding(generation: UInt64 = 3)
        -> HostHEVCFrameSourceBinding {
        HostHEVCFrameSourceBinding(
            deviceID: deviceID, captureSessionID: sessionID,
            generation: generation, width: 2, height: 2,
            inputPixelFormat: .bgra)
    }

    private func request(
        execute: Bool = false,
        generation: UInt64? = 3,
        maximumFrames: Int = 2
    ) throws -> HostHEVCValidationRequest {
        try HostHEVCValidationRequest(
            expectedDeviceID: deviceID,
            expectedCaptureSessionID: sessionID,
            expectedGeneration: generation,
            maximumFramesToEncode: maximumFrames,
            maximumInputAgeSeconds: 1,
            execute: execute)
    }

    @Test func requestDefaultsToDryRunAndRejectsUnknownArguments() throws {
        let parsed = try HostHEVCValidationRequest(cliArguments: [
            "--device", deviceID, "--session", sessionID,
            "--generation", "3", "--max-frames", "2"
        ])
        #expect(!parsed.execute)
        #expect(parsed.expectedGeneration == 3)
        #expect(throws: HostHEVCValidationError.invalidArguments) {
            try HostHEVCValidationRequest(arguments: .object([
                "deviceID": .string(deviceID), "session": .string(sessionID),
                "unexpected": .bool(true)
            ]))
        }
    }

    @Test func dryRunChecksFreshSourceWithoutCreatingEncoder() async throws {
        let source = ValidationSource(
            binding: binding(), pixelBuffer: try pixelBuffer())
        let backend = ValidationBackend()
        let service = HostHEVCValidationService(
            source: source, backendFactory: { backend })

        let result = await service.run(try request())
        #expect(result.dryRun)
        #expect(result.failureCode == nil)
        #expect(result.freshFrameObserved)
        #expect(result.freshInputPixelFormat == .bgra)
        #expect(result.submissions.isEmpty && result.samples.isEmpty)
        #expect(result.cleanup.requested == false)
        #expect(result.capability?.codecIdentifier == "hvc1")
        #expect(result.capability?.verified == false)
        #expect(backend.encodeCount == 0)
    }

    @Test func executeUsesExactBindingAndReturnsHashOnlyHostSamples()
        async throws {
        let source = ValidationSource(
            binding: binding(), pixelBuffer: try pixelBuffer())
        let backend = ValidationBackend()
        let service = HostHEVCValidationService(
            source: source, backendFactory: { backend })

        let result = await service.run(try request(execute: true))
        #expect(result.failureCode == nil)
        #expect(result.completed)
        #expect(result.submissions.count == 2)
        #expect(result.submissions.allSatisfy { $0.disposition == .accepted })
        #expect(result.samples.count == 2)
        #expect(result.samples.allSatisfy {
            $0.transport == .macVideoToolboxHost &&
                $0.codec == .hevc && $0.codecIdentifier == "hvc1" &&
                $0.parameterSetSHA256.count == 64 &&
                $0.accessUnitSHA256.count == 64 &&
                $0.usbWireCodecClaim == nil
        })
        #expect(result.cleanup.requested && result.cleanup.completed)
        #expect(result.cleanup.phase == .stopped)
        #expect(backend.encodeCount == 2 && backend.cancelCount == 1)
    }

    @Test func wrongDeviceOrGenerationIsRejectedBeforeFreshRead() async throws {
        let source = ValidationSource(
            binding: binding(), pixelBuffer: try pixelBuffer())
        let backend = ValidationBackend()
        let service = HostHEVCValidationService(
            source: source, backendFactory: { backend })
        let wrongDevice = try HostHEVCValidationRequest(
            expectedDeviceID: "other-device",
            expectedCaptureSessionID: sessionID,
            expectedGeneration: 3,
            execute: true)
        let result = await service.run(wrongDevice)
        #expect(result.failureCode == "host_hevc_session_changed")
        #expect(!result.freshFrameObserved)
        #expect(source.count == 0 && backend.encodeCount == 0)
    }

    @Test func sourceReconnectDuringRunGetsCleanupAndNoOldSample() async throws {
        let source = ValidationSource(
            binding: binding(), pixelBuffer: try pixelBuffer())
        let backend = ValidationBackend()
        let service = HostHEVCValidationService(
            source: source, backendFactory: { backend })
        let request = try request(execute: true, maximumFrames: 1)
        source.replaceBinding(binding(generation: 4))
        let result = await service.run(request)
        #expect(result.failureCode == "host_hevc_session_changed")
        #expect(result.samples.isEmpty)
        #expect(result.cleanup.requested == false)
        #expect(backend.encodeCount == 0)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
