import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Pocket3Core

@Suite("Host HEVC Annex-B file consumer", .serialized)
struct HostHEVCAnnexBFileConsumerTests {
    private let vps = Data([0x40, 0x01, 0xaa])
    private let sps = Data([0x42, 0x01, 0xbb])
    private let pps = Data([0x44, 0x01, 0xcc])
    private let key = Data([0x26, 0x01, 0xdd])
    private let trail = Data([0x02, 0x01, 0xee])

    private func bundle() throws -> VideoToolboxParameterSetBundle {
        try VideoToolboxParameterSetBundle(
            codec: .hevc, parameterSets: [vps, sps, pps])
    }

    private func hvcc(_ units: [Data]) -> Data {
        var result = Data()
        for unit in units {
            let length = UInt32(unit.count)
            result.append(contentsOf: [
                UInt8(length >> 24), UInt8(length >> 16),
                UInt8(length >> 8), UInt8(length)
            ])
            result.append(unit)
        }
        return result
    }

    private func annexB(_ units: [Data]) -> Data {
        var result = Data()
        for unit in units {
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(unit)
        }
        return result
    }

    private func sample(
        sequence: UInt64,
        pts: Int64,
        timescale: Int32 = 30,
        sessionID: String = "capture-one",
        generation: UInt64 = 1,
        isKeyFrame: Bool = false,
        accessUnit: Data? = nil
    ) throws -> HostHEVCEncodedSample {
        try HostHEVCEncodedSample(
            parameterSets: try bundle(),
            accessUnit: accessUnit ?? hvcc([isKeyFrame ? key : trail]),
            dimensions: CMVideoDimensions(width: 2, height: 2),
            presentationTimeStamp: CMTime(value: pts, timescale: timescale),
            duration: CMTime(value: 1, timescale: timescale),
            sessionID: sessionID,
            generation: generation,
            sequence: sequence,
            isKeyFrame: isKeyFrame)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-hevc-consumer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false)
        return url
    }

    private final class ProductBackend: @unchecked Sendable,
        HostHEVCEncoderBackend {
        func encode(
            _ frame: HostVideoFrame,
            configuration _: HostVideoEncoderConfiguration
        ) async throws -> HostHEVCEncodedSample {
            let vps = Data([0x40, 0x01, 0xaa])
            let sps = Data([0x42, 0x01, 0xbb])
            let pps = Data([0x44, 0x01, 0xcc])
            return try HostHEVCEncodedSample(
                parameterSets: try VideoToolboxParameterSetBundle(
                    codec: .hevc, parameterSets: [vps, sps, pps]),
                accessUnit: Data([0, 0, 0, 3, 0x26, 0x01, 0xdd]),
                dimensions: CMVideoDimensions(width: 2, height: 2),
                presentationTimeStamp: frame.presentationTimeStamp,
                duration: frame.duration,
                sessionID: frame.sessionID,
                generation: frame.generation,
                sequence: frame.sequence,
                isKeyFrame: true)
        }

        func finish() async {}
        func cancel() async {}
        func reset() async {}
    }

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

    @Test func converterPrependsSetsInVPSPSPPSOrderAndPreservesAUOrder()
        throws {
        let converter = HostHEVCAnnexBAccessUnitConverter()
        let result = try converter.convert(
            parameterSets: try bundle(),
            accessUnit: hvcc([trail, key]),
            prependParameterSets: true)
        #expect(result == annexB([vps, sps, pps, trail, key]))

        let continuation = try converter.convert(
            parameterSets: try bundle(),
            accessUnit: hvcc([trail, key]),
            prependParameterSets: false)
        #expect(continuation == annexB([trail, key]))
    }

    @Test func converterRejectsAnnexBAndMalformedLengthPrefixedInput() throws {
        let converter = HostHEVCAnnexBAccessUnitConverter()
        #expect(throws: HostHEVCAnnexBConversionError.lengthPrefixedInputRequired) {
            try converter.convert(
                parameterSets: try bundle(),
                accessUnit: annexB([key]),
                prependParameterSets: false)
        }
        #expect(throws: HostHEVCAnnexBConversionError.self) {
            try converter.convert(
                parameterSets: try bundle(),
                accessUnit: Data([0, 0, 0, 5, 0x26, 0x01]),
                prependParameterSets: false)
        }
    }

    @Test func stopPublishesAtomicFileAndInsertsSetsAtEachKeyframe()
        throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("capture.hevc")
        let configuration = try HostHEVCProductFileConfiguration(
            outputPath: output.path, maximumBytes: 1_024,
            maximumDurationSeconds: 10)
        let consumer = try HostHEVCAnnexBFileConsumer(
            configuration: configuration, sessionID: "capture-one", generation: 1)

        #expect(consumer.append(try sample(sequence: 1, pts: 0, isKeyFrame: true)) == .accepted)
        #expect(consumer.append(try sample(sequence: 2, pts: 1)) == .accepted)
        #expect(consumer.append(try sample(sequence: 3, pts: 2, isKeyFrame: true)) == .accepted)
        let finished = consumer.finish()

        #expect(finished.phase == .finished)
        #expect(finished.finalFilePublished)
        #expect(finished.samplesWritten == 3)
        #expect(finished.finishReason == .explicitlyStopped)
        #expect(try Data(contentsOf: output) == annexB([
            vps, sps, pps, key, trail, vps, sps, pps, key
        ]))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        #expect(leftovers.map(\.standardizedFileURL) ==
            [output.standardizedFileURL])
    }

    @Test func byteAndDurationBoundsFinalizeWithoutWritingPastTheLimit()
        throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let byteOutput = directory.appendingPathComponent("bytes.hevc")
        let byteConfig = try HostHEVCProductFileConfiguration(
            outputPath: byteOutput.path, maximumBytes: 20,
            maximumDurationSeconds: 10)
        let byteConsumer = try HostHEVCAnnexBFileConsumer(
            configuration: byteConfig, sessionID: "capture-one", generation: 1)
        #expect(byteConsumer.append(try sample(sequence: 1, pts: 0, isKeyFrame: true)) == .finishedAtByteLimit)
        let byteStatus = byteConsumer.snapshot()
        #expect(byteStatus.phase == .finished)
        #expect(byteStatus.finishReason == .byteLimit)
        #expect(byteStatus.bytesWritten <= 20)
        #expect(byteStatus.finalFilePublished)
        #expect(try Data(contentsOf: byteOutput).count == 0)

        let durationOutput = directory.appendingPathComponent("duration.hevc")
        let durationConfig = try HostHEVCProductFileConfiguration(
            outputPath: durationOutput.path, maximumBytes: 1_024,
            maximumDurationSeconds: 0.5)
        let durationConsumer = try HostHEVCAnnexBFileConsumer(
            configuration: durationConfig, sessionID: "capture-one", generation: 1)
        #expect(durationConsumer.append(try sample(sequence: 1, pts: 0)) == .accepted)
        #expect(durationConsumer.append(try sample(sequence: 2, pts: 30)) == .finishedAtDurationLimit)
        let durationStatus = durationConsumer.snapshot()
        #expect(durationStatus.phase == .finished)
        #expect(durationStatus.finishReason == .durationLimit)
        #expect(durationStatus.samplesWritten == 1)
        #expect(durationStatus.finalFilePublished)
    }

    @Test func cancellationAndStaleIdentityRemoveTemporaryBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("cancelled.hevc")
        let config = try HostHEVCProductFileConfiguration(outputPath: output.path)
        let consumer = try HostHEVCAnnexBFileConsumer(
            configuration: config, sessionID: "capture-one", generation: 1)
        #expect(consumer.append(try sample(sequence: 1, pts: 0)) == .accepted)
        #expect(consumer.append(try sample(sequence: 2, pts: 1, generation: 2)) == .failed)
        #expect(consumer.snapshot().phase == .failed)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let noTemporaryFiles = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        #expect(noTemporaryFiles.isEmpty)

        let cancelledOutput = directory.appendingPathComponent("cancelled-2.hevc")
        let cancelledConfig = try HostHEVCProductFileConfiguration(
            outputPath: cancelledOutput.path)
        let cancelled = try HostHEVCAnnexBFileConsumer(
            configuration: cancelledConfig, sessionID: "capture-one", generation: 1)
        #expect(cancelled.append(try sample(sequence: 1, pts: 0)) == .accepted)
        #expect(cancelled.cancel().phase == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: cancelledOutput.path))
    }

    @Test func productServicePublishesExplicitFileAndKeepsEvidenceDefault()
        async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("service.hevc")
        let fileConfiguration = try HostHEVCProductFileConfiguration(
            outputPath: output.path, maximumBytes: 1_024,
            maximumDurationSeconds: 10)
        let encoderConfiguration = try HostVideoEncoderConfiguration(
            width: 2, height: 2, frameRate: 30, maximumPendingFrames: 1)
        let backend = ProductBackend()
        let service = try HostHEVCProductOutputService(
            configuration: encoderConfiguration,
            backendFactory: { backend })
        _ = try await service.select(.hostHEVC)
        let started = try await service.startHostHEVC(
            sessionID: "capture-one", generation: 1, sink: { _ in },
            fileConfiguration: fileConfiguration)
        #expect(started.consumer == .localAnnexBFile)
        #expect(started.file?.finalFilePublished == false)

        let frame = HostVideoFrame(
            pixelBuffer: try pixelBuffer(), sessionID: "capture-one",
            generation: 1, sequence: 1,
            presentationTimeStamp: CMTime(value: 0, timescale: 30),
            duration: CMTime(value: 1, timescale: 30))
        #expect((await service.submit(
            frame, receivedUptime: 10, nowUptime: 10.01)).disposition == .accepted)
        for _ in 0..<200 {
            if (await service.status()).capability.verified { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let stopped = await service.stop()
        #expect(stopped.consumer == .localAnnexBFile)
        #expect(stopped.file?.phase == .finished)
        #expect(stopped.file?.finalFilePublished == true)
        #expect(try Data(contentsOf: output) == annexB([vps, sps, pps, key]))

        let evidenceService = try HostHEVCProductOutputService(
            configuration: encoderConfiguration,
            backendFactory: { ProductBackend() })
        _ = try await evidenceService.select(.hostHEVC)
        let evidenceStarted = try await evidenceService.startHostHEVC(
            sessionID: "capture-one", generation: 1, sink: { _ in })
        #expect(evidenceStarted.consumer == .localSampleEvidence)
        #expect(evidenceStarted.file == nil)
        _ = await evidenceService.cancel()
    }

    @Test func requestSelectsFileOnlyWhenOutputPathIsExplicit() throws {
        let evidence = try HostHEVCProductStartRequest(cliArguments: [
            "--device", "camera", "--session", "capture", "--execute"
        ])
        #expect(evidence.outputPath == nil)
        #expect(evidence.maximumOutputBytes == nil)

        let file = try HostHEVCProductStartRequest(cliArguments: [
            "--device", "camera", "--session", "capture",
            "--output", "/tmp/capture.hevc", "--max-bytes", "4096",
            "--max-duration-seconds", "2", "--execute"
        ])
        #expect(file.outputPath == "/tmp/capture.hevc")
        #expect(file.maximumOutputBytes == 4_096)
        #expect(file.maximumDurationSeconds == 2)
        #expect(file.arguments["outputPath"].string == "/tmp/capture.hevc")
    }
}
