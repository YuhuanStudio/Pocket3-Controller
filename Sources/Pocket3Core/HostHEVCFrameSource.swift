import CoreMedia
import CoreVideo
import Foundation

/// The exact identity and scalar format of one current CaptureEngine source.
/// The generation is the CaptureCallbackFence lifecycle, while the session ID
/// is the FrameStore capture session. Both are required for a fresh handoff.
public struct HostHEVCFrameSourceBinding: Codable, Sendable, Equatable {
    public let deviceID: String
    public let captureSessionID: String
    public let generation: UInt64
    public let width: Int
    public let height: Int
    public let inputPixelFormat: HostVideoInputPixelFormat

    public init(deviceID: String, captureSessionID: String,
                generation: UInt64, width: Int, height: Int,
                inputPixelFormat: HostVideoInputPixelFormat) {
        self.deviceID = String(deviceID.prefix(128))
        self.captureSessionID = String(captureSessionID.prefix(128))
        self.generation = generation
        self.width = width
        self.height = height
        self.inputPixelFormat = inputPixelFormat
    }
}

public struct HostHEVCFreshFrame: @unchecked Sendable {
    public let frame: HostVideoFrame
    public let binding: HostHEVCFrameSourceBinding
    public let receivedUptime: Double

    public init(frame: HostVideoFrame, binding: HostHEVCFrameSourceBinding,
                receivedUptime: Double) {
        self.frame = frame
        self.binding = binding
        self.receivedUptime = receivedUptime
    }
}

public enum HostHEVCFrameSourceError: Error, LocalizedError, Sendable,
    Equatable {
    case captureUnavailable
    case noFreshFrame
    case invalidFreshnessWindow
    case invalidTimestamp
    case unsupportedPixelFormat
    case sessionChanged

    public var errorDescription: String? {
        switch self {
        case .captureUnavailable: "CaptureEngine is not running"
        case .noFreshFrame: "CaptureEngine has no fresh frame"
        case .invalidFreshnessWindow: "host HEVC source freshness window is invalid"
        case .invalidTimestamp: "CaptureEngine frame timestamp is invalid"
        case .unsupportedPixelFormat: "CaptureEngine frame is not BGRA or NV12"
        case .sessionChanged: "CaptureEngine session changed during frame read"
        }
    }
}

public protocol HostHEVCFrameSource: Sendable {
    func currentBinding() -> HostHEVCFrameSourceBinding?
    func freshFrame(expected: HostHEVCFrameSourceBinding,
                    maxAgeSeconds: Double,
                    afterReceivedUptime: Double) throws -> HostHEVCFreshFrame
}

/// Read-only adapter over the real CaptureEngine/FrameStore. It snapshots a
/// copied pixel-buffer reference and rechecks both the frame identity and
/// CaptureCallbackFence generation after the read; it never retains a sample
/// buffer or mutates the capture session.
public final class CaptureEngineHostHEVCFrameSource: @unchecked Sendable,
    HostHEVCFrameSource {
    public let capture: CaptureEngine
    private let lock = NSLock()
    private var nextSequence: UInt64 = 0
    private var lastFrameID: String?
    private var lastSequence: UInt64 = 0

    public init(capture: CaptureEngine) {
        self.capture = capture
    }

    public func currentBinding() -> HostHEVCFrameSourceBinding? {
        guard capture.session.isRunning else { return nil }
        let stats = capture.store.stats()
        guard let info = stats.frame,
              !info.deviceID.isEmpty,
              !info.sessionID.isEmpty,
              info.width > 0, info.height > 0,
              let input = inputFormat(from: info) else {
            return nil
        }
        return HostHEVCFrameSourceBinding(
            deviceID: info.deviceID, captureSessionID: info.sessionID,
            generation: capture.currentLifecycle(), width: info.width,
            height: info.height, inputPixelFormat: input)
    }

    public func freshFrame(expected: HostHEVCFrameSourceBinding,
                           maxAgeSeconds: Double,
                           afterReceivedUptime: Double = 0) throws -> HostHEVCFreshFrame {
        guard maxAgeSeconds.isFinite, maxAgeSeconds > 0,
              maxAgeSeconds <= 5 else {
            throw HostHEVCFrameSourceError.invalidFreshnessWindow
        }
        guard let before = currentBinding(), before == expected else {
            throw HostHEVCFrameSourceError.sessionChanged
        }
        let packet: FramePacket
        do {
            packet = try capture.store.latest(
                maxAge: maxAgeSeconds, after: afterReceivedUptime)
        } catch {
            throw HostHEVCFrameSourceError.noFreshFrame
        }
        let info = packet.info
        guard info.deviceID == expected.deviceID,
              info.sessionID == expected.captureSessionID,
              info.width == expected.width, info.height == expected.height,
              let input = HostVideoInputPixelFormat(pixelBuffer: packet.pixelBuffer),
              input == expected.inputPixelFormat,
              info.receivedUptime.isFinite,
              info.presentationTime.isFinite else {
            throw HostHEVCFrameSourceError.sessionChanged
        }
        guard let after = currentBinding(), after == expected else {
            throw HostHEVCFrameSourceError.sessionChanged
        }
        let sequence = sequence(for: info.id)
        let frame = HostVideoFrame(
            pixelBuffer: packet.pixelBuffer,
            sessionID: info.sessionID, generation: expected.generation,
            sequence: sequence,
            presentationTimeStamp: CMTime(
                seconds: info.presentationTime, preferredTimescale: 600_000),
            duration: .invalid)
        return HostHEVCFreshFrame(
            frame: frame, binding: expected,
            receivedUptime: info.receivedUptime)
    }

    private func sequence(for frameID: String) -> UInt64 {
        lock.withLock {
            if lastFrameID == frameID { return lastSequence }
            nextSequence = nextSequence == .max ? 1 : nextSequence + 1
            lastFrameID = frameID
            lastSequence = nextSequence
            return nextSequence
        }
    }

    private func inputFormat(from info: FrameInfo) -> HostVideoInputPixelFormat? {
        // FrameStore records the delivered buffer's output format. BGRA is the
        // current stable output of both the native BGRA and host-decoded paths.
        switch info.outputPixelFormat {
        case "BGRA": return .bgra
        case "420v": return .nv12VideoRange
        case "420f": return .nv12FullRange
        default: return nil
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
