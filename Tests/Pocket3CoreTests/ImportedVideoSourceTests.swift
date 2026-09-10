@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Pocket3Core

/// Real encoded local movies, created in temporary storage. No capture device,
/// camera service, model, network or repository video fixture is used.
private func makeImportedMovie(at url: URL, width: Int = 64, height: Int = 32, rotated: Bool = false,
                               frameCount: Int = 10, frameStep: CMTime = CMTime(value: 1, timescale: 10),
                               presentationTimes: [CMTime]? = nil, endTime: CMTime? = nil) async throws {
    let times = presentationTimes ?? (0..<frameCount).map { CMTimeMultiply(frameStep, multiplier: Int32($0)) }
    let end = endTime ?? CMTimeMultiply(frameStep, multiplier: Int32(frameCount))
    let timeScale = max(600, max(end.timescale, times.map(\.timescale).max() ?? frameStep.timescale))
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    writer.movieTimeScale = timeScale
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264.rawValue,
        AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1, AVVideoAverageBitRateKey: 500_000]])
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = timeScale
    if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0) }
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    guard writer.canAdd(input) else { throw BridgeFailure("video_fixture", "Cannot add fixture encoder input") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? BridgeFailure("video_fixture", "Cannot start fixture encoder") }
    writer.startSession(atSourceTime: .zero)
    do {
        for (index, time) in times.enumerated() {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw BridgeFailure("video_fixture", "Fixture encoder readiness timed out") }
                try await Task.sleep(for: .milliseconds(1))
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { throw BridgeFailure("video_fixture", "Cannot create fixture pixels") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + x * 4
                    // First half is red, second half blue. Rotated fixture also
                    // has a spatial red/blue split to check actual orientation.
                    let red = rotated ? x < width / 2 : index < 5
                    bytes[offset] = red ? 0 : 255
                    bytes[offset + 1] = 0
                    bytes[offset + 2] = red ? 255 : 0
                    bytes[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adapter.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? BridgeFailure("video_fixture", "Cannot append fixture pixels")
            }
        }
        writer.endSession(atSourceTime: end)
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? BridgeFailure("video_fixture", "Cannot finish fixture encoder") }
    } catch { writer.cancelWriting(); throw error }
}

private func makeAudioTail(at url: URL) throws {
    var audio: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000], commonFormat: .pcmFormatFloat32, interleaved: false)
    let pcm = AVAudioPCMBuffer(pcmFormat: audio!.processingFormat, frameCapacity: 96_000)!
    pcm.frameLength = 96_000
    pcm.floatChannelData![0].initialize(repeating: 0, count: 96_000)
    try audio?.write(from: pcm)
    audio = nil
}

private func composeImportedMovie(video: URL, audio: URL? = nil, range: CMTimeRange? = nil,
                                  at destination: CMTime = .zero, output: URL) async throws {
    let composition = AVMutableComposition()
    let source = AVURLAsset(url: video)
    let sourceTrack = try #require(try await source.loadTracks(withMediaType: .video).first)
    let videoTrack = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
    let selectedRange: CMTimeRange
    if let range { selectedRange = range } else { selectedRange = try await sourceTrack.load(.timeRange) }
    try videoTrack.insertTimeRange(selectedRange, of: sourceTrack, at: destination)
    if let audio {
        let audioAsset = AVURLAsset(url: audio)
        let sourceAudio = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
        let audioTrack = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try audioTrack.insertTimeRange(try await sourceAudio.load(.timeRange), of: sourceAudio, at: .zero)
    }
    let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
    try await exporter.export(to: output, as: .mp4)
}

private func movieDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pocket3-video-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func videoPixel(_ frame: FramePacket, x: Int, y: Int) -> (red: Int, blue: Int) {
    CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly) }
    let data = CVPixelBufferGetBaseAddress(frame.pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    let offset = y * CVPixelBufferGetBytesPerRow(frame.pixelBuffer) + x * 4
    return (Int(data[offset + 2]), Int(data[offset]))
}

private actor VideoDeliveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { let current = continuation; continuation = nil; current?.resume() }
}

@Suite("Imported local video", .serialized) struct ImportedVideoSourceTests {
    @Test func realMP4SeekingUsesActualTimeFreshIDsAndStableVideoSession() async throws {
        let directory = try movieDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local-private-name.mp4")
        try await makeImportedMovie(at: url)
        let source = try await ImportedVideoSource.open(url)
        let metadata = source.metadata
        #expect(metadata.width == 64 && metadata.height == 32)
        #expect(abs(metadata.durationSeconds - 1) < 0.05)
        let first = try await source.frame(at: 0.2)
        let second = try await source.frame(at: 0.7)
        #expect(first.info.id != second.info.id)
        #expect(first.info.sessionID == second.info.sessionID && first.info.sessionID == metadata.sessionID)
        #expect(first.info.timestampSource == "local_video_import" && second.info.deviceID == "local-evaluation")
        #expect(abs(first.info.presentationTime - 0.2) < 0.11)
        #expect(abs(second.info.presentationTime - 0.7) < 0.11)
        let red = videoPixel(first, x: 30, y: 16), blue = videoPixel(second, x: 30, y: 16)
        #expect(red.red > 180 && red.blue < 70)
        #expect(blue.blue > 180 && blue.red < 70)
        let encoded = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        #expect(!encoded.contains(url.path) && !encoded.contains(url.lastPathComponent))
        await source.close()
        do { _ = try await source.frame(at: 0); Issue.record("Closed source decoded another frame") }
        catch let failure as BridgeFailure { #expect(failure.code == "video_closed") }
    }

    @Test func preferredTransformIsAppliedToPixelsAndDisplayMetadata() async throws {
        let directory = try movieDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rotated.mp4")
        try await makeImportedMovie(at: url, rotated: true)
        let source = try await ImportedVideoSource.open(url)
        let frame = try await source.frame(at: 0.2)
        #expect(source.metadata.width == 32 && source.metadata.height == 64)
        #expect(frame.info.width == 32 && frame.info.height == 64)
        #expect(frame.info.rotationDegrees == 0 && !frame.info.mirrored)
        let upper = videoPixel(frame, x: 16, y: 8), lower = videoPixel(frame, x: 16, y: 56)
        #expect(upper.red > 180 && upper.blue < 70)
        #expect(lower.blue > 180 && lower.red < 70)
        await source.close()
    }

    @Test func offGridAndInclusiveEndRequestsReturnRealPriorFrames() async throws {
        let directory = try movieDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("off-grid.mp4")
        try await makeImportedMovie(at: url)
        let source = try await ImportedVideoSource.open(url)
        #expect(source.metadata.startSeconds == 0)
        #expect(source.metadata.lastSeekSeconds < source.metadata.durationSeconds)
        for requested in [0.55, 0.999, source.metadata.lastSeekSeconds] {
            let frame = try await source.frame(at: requested)
            #expect(frame.info.presentationTime <= requested + 0.000_001)
            #expect(requested - frame.info.presentationTime < 0.111)
            let pixel = videoPixel(frame, x: 30, y: 16)
            #expect(pixel.blue > 180 && pixel.red < 70)
        }
        await source.close()
    }

    @Test func variableRateMovieSeeksInsideLongHeldFramesAndAtTrackEnd() async throws {
        let directory = try movieDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("variable-rate.mp4")
        // Red at 0.4 s remains visible until the blue frame at 2 s. The last
        // blue frame at 2.4 s is held to 4.5 s, far beyond a nominal interval.
        let times = [0, 1, 2, 3, 4, 20, 21, 22, 23, 24].map { CMTime(value: Int64($0), timescale: 10) }
        try await makeImportedMovie(at: url, presentationTimes: times, endTime: CMTime(value: 45, timescale: 10))
        let source = try await ImportedVideoSource.open(url)
        #expect(abs(source.metadata.durationSeconds - 4.5) < 0.01)
        for requested in [1.0, 1.5, 1.99] {
            let frame = try await source.frame(at: requested)
            #expect(abs(frame.info.presentationTime - 0.4) < 0.001)
            #expect(frame.info.presentationTime <= requested)
            let pixel = videoPixel(frame, x: 30, y: 16)
            #expect(pixel.red > 180 && pixel.blue < 70)
        }
        for requested in [3.5, source.metadata.lastSeekSeconds] {
            let frame = try await source.frame(at: requested)
            #expect(abs(frame.info.presentationTime - 2.4) < 0.001)
            #expect(frame.info.presentationTime <= requested)
            let pixel = videoPixel(frame, x: 30, y: 16)
            #expect(pixel.blue > 180 && pixel.red < 70)
        }
        await source.close()
    }

    @Test func singleLongHeldFrameRemainsSeekableThroughoutItsDuration() async throws {
        let directory = try movieDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("single-held-frame.mp4")
        try await makeImportedMovie(at: url, frameCount: 1, endTime: CMTime(value: 5, timescale: 1))
        let source = try await ImportedVideoSource.open(url)
        #expect(abs(source.metadata.durationSeconds - 5) < 0.01)
        for requested in [source.metadata.startSeconds, 2.5, source.metadata.lastSeekSeconds] {
            let frame = try await source.frame(at: requested)
            #expect(frame.info.presentationTime == 0)
            let pixel = videoPixel(frame, x: 30, y: 16)
            #expect(pixel.red > 180 && pixel.blue < 70)
        }
        await source.close()
    }

    @Test func seekRangeExcludesAudioTailAndHonoursTrimmedTrackEdits() async throws {
        let directory = try movieDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mp4"), audio = directory.appendingPathComponent("tail.m4a")
        try await makeImportedMovie(at: video)
        try makeAudioTail(at: audio)
        let tailed = directory.appendingPathComponent("audio-tail.mp4")
        try await composeImportedMovie(video: video, audio: audio, output: tailed)
        let assetDuration = try await AVURLAsset(url: tailed).load(.duration).seconds
        #expect(assetDuration > 1.5)
        let source = try await ImportedVideoSource.open(tailed)
        #expect(source.metadata.durationSeconds < 1.1)
        #expect(source.metadata.lastSeekSeconds < 1.1)
        let last = try await source.frame(at: source.metadata.lastSeekSeconds)
        #expect(videoPixel(last, x: 30, y: 16).blue > 180)
        do { _ = try await source.frame(at: 1.5); Issue.record("Audio-only tail accepted as a video seek") }
        catch let failure as BridgeFailure { #expect(failure.code == "video_time_range") }
        await source.close()

        let trimmed = directory.appendingPathComponent("trimmed.mp4")
        try await composeImportedMovie(video: video,
            range: CMTimeRange(start: CMTime(value: 2, timescale: 10), duration: CMTime(value: 6, timescale: 10)),
            at: CMTime(value: 4, timescale: 10), output: trimmed)
        let trim = try await ImportedVideoSource.open(trimmed)
        #expect(abs(trim.metadata.startSeconds - 0.4) < 0.03)
        #expect(abs(trim.metadata.durationSeconds - 0.6) < 0.03)
        let first = try await trim.frame(at: trim.metadata.startSeconds)
        let end = try await trim.frame(at: trim.metadata.lastSeekSeconds)
        #expect(videoPixel(first, x: 30, y: 16).red > 180)
        #expect(videoPixel(end, x: 30, y: 16).blue > 180)
        #expect(first.info.presentationTime >= trim.metadata.startSeconds)
        #expect(end.info.presentationTime < trim.metadata.startSeconds + trim.metadata.durationSeconds)
        await trim.close()
    }

    @Test func extremelyShortMovieHasNoArtificialOneMillisecondMinimum() async throws {
        let directory = try movieDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("short.mp4")
        try await makeImportedMovie(at: url, frameCount: 1, frameStep: CMTime(value: 1, timescale: 4000))
        let source = try await ImportedVideoSource.open(url)
        #expect(source.metadata.durationSeconds > 0 && source.metadata.durationSeconds < 0.001)
        #expect(source.metadata.lastSeekSeconds >= source.metadata.startSeconds)
        #expect(source.metadata.lastSeekSeconds < source.metadata.startSeconds + source.metadata.durationSeconds)
        let first = try await source.frame(at: source.metadata.startSeconds)
        let last = try await source.frame(at: source.metadata.lastSeekSeconds)
        #expect(first.info.presentationTime == last.info.presentationTime)
        #expect(videoPixel(last, x: 30, y: 16).red > 180)
        await source.close()
    }

    @Test func largeMovieDecodesOnlyOneBoundedSizeFrame() async throws {
        let directory = try movieDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.mp4")
        try await makeImportedMovie(at: url, width: 2560, height: 1440)
        let source = try await ImportedVideoSource.open(url)
        let frame = try await source.frame(at: 0.7)
        #expect(source.metadata.width == 2560 && source.metadata.height == 1440)
        #expect(frame.info.width == 1920 && frame.info.height == 1080)
        #expect(frame.info.sourceWidth == 2560 && frame.info.sourceHeight == 1440)
        await source.close()
    }

    @Test func invalidTimesAreRejectedWithoutClampingAndMetadataRejectsIndefiniteTime() async throws {
        let directory = try movieDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("time.mp4")
        try await makeImportedMovie(at: url)
        let source = try await ImportedVideoSource.open(url)
        for time in [-1, Double.nan, Double.infinity, source.metadata.durationSeconds, source.metadata.durationSeconds + 1] {
            do { _ = try await source.frame(at: time); Issue.record("Invalid seek time accepted") }
            catch let failure as BridgeFailure { #expect(failure.code == "video_time_range") }
        }
        await source.close()
        for duration in [CMTime.indefinite, .invalid, .positiveInfinity, .zero] {
            #expect(throws: BridgeFailure.self) {
                try ImportedVideoSource.validatedMetadata(duration: duration, size: .init(width: 10, height: 10), transform: .identity)
            }
        }
        #expect(throws: BridgeFailure.self) {
            try ImportedVideoSource.validatedMetadata(duration: CMTime(value: 1, timescale: 1), size: .init(width: 10, height: 10),
                transform: CGAffineTransform(scaleX: -1, y: 1))
        }
    }

    @Test func onlyReadableLocalVideoFilesAreAccepted() async throws {
        for url in [URL(string: "https://example.invalid/movie.mp4")!, URL(string: "file://remote-host/movie.mp4")!] {
            do { _ = try await ImportedVideoSource.open(url); Issue.record("Nonlocal URL accepted") }
            catch let failure as BridgeFailure { #expect(failure.code == "video_local_file_required") }
        }
        let directory = try movieDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try await ImportedVideoSource.open(directory); Issue.record("Directory accepted") }
        catch let failure as BridgeFailure { #expect(failure.code == "video_local_file_required") }
        let audioURL = directory.appendingPathComponent("audio-only.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        var audio: AVAudioFile? = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        pcm.frameLength = 4800
        pcm.floatChannelData![0].initialize(repeating: 0, count: 4800)
        try audio?.write(from: pcm)
        audio = nil
        do { _ = try await ImportedVideoSource.open(audioURL); Issue.record("Audio-only file accepted") }
        catch let failure as BridgeFailure { #expect(failure.code == "video_no_track") }
    }

    @Test func cancellingOrClosingAfterRealDecodeCannotDeliverALateFrame() async throws {
        let directory = try movieDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cancel.mp4")
        try await makeImportedMovie(at: url)
        for close in [false, true] {
            let source = try await ImportedVideoSource.open(url), gate = VideoDeliveryGate()
            let task = Task { try await source.frame(at: 0.2, beforeDelivery: { await gate.wait() }) }
            for _ in 0..<1000 {
                if await gate.waiting { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await gate.waiting)
            if close { await source.close() } else { task.cancel() }
            await gate.release()
            do { _ = try await task.value; Issue.record("Late frame survived cancellation/close") }
            catch is CancellationError { #expect(!close) }
            catch let failure as BridgeFailure { #expect(close && failure.code == "video_closed") }
            if !close {
                let next = try await source.frame(at: 0.7)
                #expect(next.info.sessionID == source.metadata.sessionID)
            }
            await source.close()
        }
    }
}

private final class VideoScopeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Test func videoSecurityScopeBalancesExactlyOneSuccessfulAcquisition() {
    let counter = VideoScopeCounter(), url = URL(fileURLWithPath: "/synthetic/security-scope.mp4")
    var granted: ImportedVideoSecurityScope? = .init(url: url, start: { _ in true }, stop: { _ in counter.increment() })
    granted?.close(); granted?.close(); granted = nil
    #expect(counter.value == 1)
    var unscoped: ImportedVideoSecurityScope? = .init(url: url, start: { _ in false }, stop: { _ in counter.increment() })
    unscoped?.close(); unscoped = nil
    #expect(counter.value == 1)
}
