@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

public struct ImportedVideoMetadata: Codable, Sendable, Equatable {
    public let sessionID: String
    /// Video-track span, excluding a longer audio-only tail.
    public let durationSeconds: Double
    public let startSeconds: Double
    /// Inclusive request limit: the last seek-clock tick before track end.
    /// This is a seek position, not a claim that a sample exists at that PTS.
    public let lastSeekSeconds: Double
    /// Display dimensions after pixel-aspect and preferred-track transforms.
    public let width: Int
    public let height: Int
}

/// Scope is retained for the asset's entire lifetime, not only metadata load.
/// Closing more than once (including deinit) balances at most one acquisition.
final class ImportedVideoSecurityScope: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let stop: @Sendable (URL) -> Void
    private var active: Bool
    init(url: URL, start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.url = url; self.stop = stop; active = start(url)
    }
    func close() {
        let release = lock.withLock { let previous = active; active = false; return previous }
        if release { stop(url) }
    }
    deinit { close() }
}

/// Immutable AVURLAsset wrapper. AVFoundation supports asynchronous property
/// loading/cancellation; the wrapper carries it across the timeout worker.
private final class ImportedVideoAsset: @unchecked Sendable {
    let value: AVURLAsset
    let scope: ImportedVideoSecurityScope
    init(url: URL, scope: ImportedVideoSecurityScope) {
        self.scope = scope
        value = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
            AVURLAssetAllowsCellularAccessKey: false])
    }
    func close() { value.cancelLoading(); scope.close() }
    deinit { close() }
}

private final class ImportedVideoResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    func resolve(_ result: Result<Value, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let existing = lock.withLock { () -> Result<Value, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let existing { continuation.resume(with: existing) }
        }
    }
}

private struct ImportedVideoDecodedImage: @unchecked Sendable {
    let image: CGImage
    let time: CMTime
}
private struct ImportedVideoLoad: Sendable {
    let metadata: ImportedVideoMetadata
    let timeRange: CMTimeRange
}

/// Each seek owns its generator and completion latch, so cancelling an older
/// request cannot accidentally cancel the generator used by a later seek.
private final class ImportedVideoImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let generator: AVAssetImageGenerator
    private let result = ImportedVideoResult<ImportedVideoDecodedImage>()
    private var cancelled = false
    init(asset: AVAsset, toleranceBefore: CMTime) {
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .productionAperture
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        generator.requestedTimeToleranceBefore = toleranceBefore
        generator.requestedTimeToleranceAfter = .zero
        generator.dynamicRangePolicy = .forceSDR
    }
    func value(at time: CMTime) async throws -> ImportedVideoDecodedImage {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            lock.withLock {
                guard !cancelled else { return }
                // One requested timestamp only; no whole-video image sequence.
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [result] _, image, actualTime, status, error in
                    switch status {
                    case .succeeded:
                        if let image { result.resolve(.success(.init(image: image, time: actualTime))) }
                        else { result.resolve(.failure(BridgeFailure("video_decode_failed", "No image returned for the requested video time"))) }
                    case .cancelled: result.resolve(.failure(CancellationError()))
                    case .failed: result.resolve(.failure(error ?? BridgeFailure("video_decode_failed", "The requested video frame could not be decoded")))
                    @unknown default: result.resolve(.failure(BridgeFailure("video_decode_failed", "Unknown video image generation result")))
                    }
                }
            }
            return try await result.value()
        } onCancel: { self.cancel() }
    }
    func cancel() {
        lock.withLock { cancelled = true; generator.cancelAllCGImageGeneration() }
        result.resolve(.failure(CancellationError()))
    }
}

/// A selected local movie, decoded only at explicit requested times. It has no
/// camera, microphone, playback, network URL or model-generation interface.
public actor ImportedVideoSource {
    public nonisolated let metadata: ImportedVideoMetadata
    private var asset: ImportedVideoAsset?
    private var activeRequest: ImportedVideoImageRequest?
    private let timeRange: CMTimeRange

    private init(asset: ImportedVideoAsset, loaded: ImportedVideoLoad) {
        self.asset = asset; metadata = loaded.metadata; timeRange = loaded.timeRange
    }
    deinit { activeRequest?.cancel(); asset?.close() }

    public static func open(_ url: URL) async throws -> ImportedVideoSource {
        try Task.checkCancellation()
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw BridgeFailure("video_local_file_required", "Choose a local video file")
        }
        let scope = ImportedVideoSecurityScope(url: url)
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .volumeIsLocalKey])
            guard values.isRegularFile == true, values.isReadable == true, values.volumeIsLocal == true else {
                throw BridgeFailure("video_local_file_required", "Choose a readable regular file on a local volume")
            }
            let asset = ImportedVideoAsset(url: url, scope: scope)
            do {
                let loaded = try await bounded(seconds: 15, timeout: "video_metadata_timeout", cancel: { asset.value.cancelLoading() }) {
                    guard let track = try await asset.value.loadTracks(withMediaType: .video).first else {
                        throw BridgeFailure("video_no_track", "The file does not contain a video track")
                    }
                    let naturalSize = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let timeRange = try await track.load(.timeRange)
                    let segments = try await track.load(.segments)
                    let descriptions = try await track.load(.formatDescriptions)
                    let presentationSize = descriptions.first.map {
                        CMVideoFormatDescriptionGetPresentationDimensions($0, usePixelAspectRatio: true, useCleanAperture: false)
                    } ?? naturalSize
                    try Task.checkCancellation()
                    // Exclude leading/trailing empty edits as well as audio
                    // tails. Segment targets are in the exported asset timeline.
                    let mediaRanges = segments.filter { !$0.isEmpty }.map { $0.timeMapping.target }
                        .filter { $0.isValid && $0.start.isNumeric && $0.duration.isNumeric && $0.duration.seconds > 0 }
                    var readableRange = timeRange
                    if let first = mediaRanges.min(by: { CMTimeCompare($0.start, $1.start) < 0 }),
                       let last = mediaRanges.max(by: { CMTimeCompare($0.end, $1.end) < 0 }) {
                        let firstTime = CMTimeCompare(first.start, timeRange.start) > 0 ? first.start : timeRange.start
                        let lastTime = CMTimeCompare(last.end, timeRange.end) < 0 ? last.end : timeRange.end
                        readableRange = CMTimeRange(start: firstTime, duration: CMTimeSubtract(lastTime, firstTime))
                    }
                    let metadata = try validatedMetadata(timeRange: readableRange, size: presentationSize, transform: transform)
                    return ImportedVideoLoad(metadata: metadata, timeRange: readableRange)
                }
                try Task.checkCancellation()
                return ImportedVideoSource(asset: asset, loaded: loaded)
            } catch { asset.close(); throw error }
        } catch { scope.close(); throw error }
    }

    public func frame(at seconds: Double) async throws -> FramePacket {
        try await frame(at: seconds, beforeDelivery: nil)
    }

    /// Internal delivery hook tests cancellation after a real file decode. It
    /// is not exposed by App, CLI or the public reader method.
    func frame(at seconds: Double, beforeDelivery: (@Sendable () async -> Void)?) async throws -> FramePacket {
        try Task.checkCancellation()
        guard seconds.isFinite, seconds >= metadata.startSeconds, seconds <= metadata.lastSeekSeconds else {
            throw BridgeFailure("video_time_range", "Video time must be finite and within the movie duration")
        }
        guard let asset else { throw BridgeFailure("video_closed", "The imported video has been closed") }
        activeRequest?.cancel()
        // Request the selected visual time exactly. A broad look-behind can
        // cross a GOP/scene boundary even when this frame exists. AVFoundation
        // still renders held VFR frames at intermediate visual times; return
        // the framework's actualTime rather than fabricating one here.
        let scale = max(600_000, max(timeRange.start.timescale, timeRange.duration.timescale))
        let requested = CMTime(seconds: seconds, preferredTimescale: scale)
        guard requested.isNumeric, CMTimeRangeContainsTime(timeRange, time: requested) else {
            throw BridgeFailure("video_time_range", "Requested time is outside the video track")
        }
        let request = ImportedVideoImageRequest(asset: asset.value, toleranceBefore: .zero)
        activeRequest = request
        defer { if activeRequest === request { activeRequest = nil } }
        let metadata = self.metadata
        let frame = try await Self.bounded(seconds: 10, timeout: "video_frame_timeout", cancel: { request.cancel() }) {
            let decoded = try await request.value(at: requested)
            return try Self.makeFrame(decoded, metadata: metadata)
        }
        await beforeDelivery?()
        try Task.checkCancellation()
        guard self.asset === asset, activeRequest === request else { throw BridgeFailure("video_closed", "Video frame belongs to a closed or replaced request") }
        return frame
    }

    private static func makeFrame(_ decoded: ImportedVideoDecodedImage, metadata: ImportedVideoMetadata) throws -> FramePacket {
        try Task.checkCancellation()
        let actual = decoded.time.seconds
        guard decoded.time.isNumeric, actual.isFinite, actual >= metadata.startSeconds,
              actual < metadata.startSeconds + metadata.durationSeconds,
              decoded.image.width > 0, decoded.image.height > 0,
              max(decoded.image.width, decoded.image.height) <= 1920 else {
            throw BridgeFailure("video_frame_invalid", "Decoded video frame metadata is invalid")
        }
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, decoded.image.width, decoded.image.height, kCVPixelFormatType_32BGRA,
            nil, &pixels) == kCVReturnSuccess, let pixels else { throw BridgeFailure("video_frame_memory", "Video frame buffer could not be allocated") }
        CIContext(options: [.cacheIntermediates: false]).render(CIImage(cgImage: decoded.image), to: pixels)
        try Task.checkCancellation()
        var info = FrameInfo(id: UUID().uuidString, sessionID: metadata.sessionID, deviceID: "local-evaluation",
            receivedAt: Date(), receivedUptime: ProcessInfo.processInfo.systemUptime, presentationTime: actual,
            width: decoded.image.width, height: decoded.image.height, timestampSource: "local_video_import")
        info.sourceWidth = metadata.width; info.sourceHeight = metadata.height
        info.outputPixelFormat = "BGRA"
        return FramePacket(pixelBuffer: pixels, info: info)
    }

    public func close() {
        activeRequest?.cancel(); activeRequest = nil
        asset?.close(); asset = nil
    }

    static func validatedMetadata(duration: CMTime, size: CGSize, transform: CGAffineTransform) throws -> ImportedVideoMetadata {
        try validatedMetadata(timeRange: CMTimeRange(start: .zero, duration: duration), size: size, transform: transform)
    }

    static func validatedMetadata(timeRange: CMTimeRange, size: CGSize, transform: CGAffineTransform) throws -> ImportedVideoMetadata {
        let seconds = timeRange.duration.seconds, start = timeRange.start.seconds
        guard timeRange.isValid, timeRange.start.isNumeric, timeRange.duration.isNumeric,
              seconds.isFinite, seconds > 0, start.isFinite, start >= 0,
              timeRange.end.isNumeric, timeRange.end.seconds.isFinite,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite) else {
            throw BridgeFailure("video_metadata_invalid", "The video duration or display geometry is invalid")
        }
        // AVAssetImageGenerator documents support for 90-degree rotations.
        // Reject unsupported affine scaling/shear/reflection instead of
        // publishing geometry that the decoded pixels may not actually follow.
        let rotations: [[CGFloat]] = [[1, 0, 0, 1], [0, 1, -1, 0], [-1, 0, 0, -1], [0, -1, 1, 0]]
        let matrix = [transform.a, transform.b, transform.c, transform.d]
        guard rotations.contains(where: { zip($0, matrix).allSatisfy { abs($0.0 - $0.1) < 0.000_001 } }) else {
            throw BridgeFailure("video_transform_unsupported", "This video uses an unsupported display transform")
        }
        let displayed = CGRect(origin: .zero, size: size).applying(transform).standardized
        guard displayed.width.isFinite, displayed.height.isFinite,
              displayed.width >= 1, displayed.height >= 1,
              displayed.width <= 65_536, displayed.height <= 65_536 else {
            throw BridgeFailure("video_metadata_invalid", "The video display dimensions are invalid")
        }
        let tick = CMTime(value: 1, timescale: max(600_000, max(timeRange.end.timescale, timeRange.start.timescale)))
        let lastSeek = max(start, CMTimeSubtract(timeRange.end, tick).seconds)
        guard lastSeek.isFinite, lastSeek < timeRange.end.seconds else {
            throw BridgeFailure("video_metadata_invalid", "The video track has no representable seek position")
        }
        return .init(sessionID: "video-" + UUID().uuidString, durationSeconds: seconds,
            startSeconds: start, lastSeekSeconds: lastSeek,
            width: Int(displayed.width.rounded()), height: Int(displayed.height.rounded()))
    }

    /// Unlike a throwing task group, a timeout does not wait indefinitely for
    /// a cancelled framework task. Late completion can only resolve its old latch.
    private static func bounded<Value: Sendable>(seconds: Double, timeout: String,
        cancel: @escaping @Sendable () -> Void, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let result = ImportedVideoResult<Value>()
        let worker = Task {
            do { result.resolve(.success(try await operation())) }
            catch { result.resolve(.failure(error)) }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
                result.resolve(.failure(BridgeFailure(timeout, "Local video decoding exceeded its deadline")))
                cancel(); worker.cancel()
            } catch {}
        }
        defer { worker.cancel(); timer.cancel() }
        let value = try await withTaskCancellationHandler { try await result.value() } onCancel: {
            result.resolve(.failure(CancellationError())); cancel(); worker.cancel()
        }
        try Task.checkCancellation()
        return value
    }
}
