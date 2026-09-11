import Foundation
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public final class FramePacket: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let info: FrameInfo
    public init(pixelBuffer: CVPixelBuffer, info: FrameInfo) { self.pixelBuffer = pixelBuffer; self.info = info }
    public func jpegWithInfo(maxDimension: Int = 1920) throws -> (FrameInfo, Data) {
        let data = try jpeg(maxDimension: maxDimension)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw BridgeFailure("encode_metadata", "無法讀取 JPEG 的實際尺寸") }
        var metadata = info
        metadata.sourceWidth = metadata.width; metadata.sourceHeight = metadata.height
        metadata.width = width; metadata.height = height
        metadata.outputPixelFormat = "JPEG"
        return (metadata, data)
    }
    public func jpeg(maxDimension: Int = 1920) throws -> Data {
        let ci = CIContext(options: [.cacheIntermediates: false])
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1, Double(maxDimension) / max(image.extent.width, image.extent.height))
        if scale < 1 { image = image.transformed(by: .init(scaleX: scale, y: scale)) }
        guard let cg = ci.createCGImage(image, from: image.extent) else { throw BridgeFailure("encode_failed", "影格無法轉為圖片") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw BridgeFailure("encode_failed", "無法建立 JPEG") }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw BridgeFailure("encode_failed", "JPEG 編碼失敗") }
        return data as Data
    }
}
public struct AudioStats: Codable, Sendable {
    public var buffers: Int = 0
    public var sampleFrames: Int = 0
    public var sampleRate: Double = 0
    public var channels: Int = 0
    public var rms: Double = 0
    public var peak: Double = 0
}
/// Capture configuration/callback metadata only. CM sample/input FourCC values do not identify the
/// USB wire codec; that requires a separate UVC COMMIT observation.
public struct CaptureSampleDiagnostics: Codable, Sendable, Equatable {
    public var videoSampleCount = 0
    public var pixelBufferCount = 0
    public var nonImageVideoSampleCount = 0
    public var nonImageVideoBlockBufferCount = 0
    // Optional for backward-compatible decoding of persisted diagnostics.
    public var decodedH264FrameCount: Int? = 0
    public var h264DecodeFailureCount: Int? = 0
    public var h264DecodeTotalMilliseconds: Double? = 0
    public var h264DecodeMaximumMilliseconds: Double? = 0
    public var lastVideoSampleFourCC: String?
    public var lastVideoInputFourCC: String?
    public var requestedOutputPolicy: String?
    public var availableVideoOutputPixelFormats: [String]?
    public var availableVideoOutputCodecs: [String]?
    public var runtimeErrorCount = 0
    public var lastAVFoundationErrorCode: Int?
    public var interruptionCount = 0
    public var interruptionEndedCount = 0
    public var interrupted = false
    public var activeFormatFourCC: String?
    public var activeFormatWidth: Int?
    public var activeFormatHeight: Int?
    public var requestedFrameRate: Double?
    public var requestedFrameDurationSeconds: Double?
    public var activeMinFrameDurationSeconds: Double?
    public var activeMaxFrameDurationSeconds: Double?
    public var sessionPreset: String?
    public var outputVideoSettingsWasNil: Bool?
    public var outputVideoSettingsKeys: [String]?
    public var outputVideoSettingsValueTypes: [String: String]?
    public var connectionEnabled: Bool?
    public var connectionActive: Bool?
    public var inputPortFourCC: String?
    public var sessionRunning: Bool?
    public var deviceConnected: Bool?
    public var callbackWaitTimedOut: Bool?
    public var noVideoSample: Bool?
    public var callbackTimeoutCount: Int?
    public init() {}
}

/// One explicitly opted-in diagnostic policy. Normal application launches keep
/// their BGRA conversion, even if the environment variable happens to be set.
public enum CaptureOutputPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case bgra, native, systemDefault = "system_default", h264
    public var id: String { rawValue }
    public var isUserSelectable: Bool { self == .bgra || self == .h264 }
    static func selected(environment: [String: String], arguments: [String]) -> Self {
        guard arguments.contains("--hardware-validation") else { return .bgra }
        return Self(rawValue: environment["POCKET3_CAPTURE_OUTPUT"] ?? "") ?? .bgra
    }
    func settings(width: Int? = nil, height: Int? = nil) -> [String: Any]? {
        // AVCaptureVideoDataOutput.h: an empty dictionary requests device-native
        // samples; nil would instead request a default uncompressed format.
        if self == .native { return [:] }
        if self == .systemDefault { return nil }
        if self == .h264 {
            // Before attaching/configuring the input, retain system defaults.
            // The explicit codec is applied only after activeFormat is selected
            // and its availableVideoCodecTypes has been checked below.
            guard let width, let height else { return nil }
            return [AVVideoCodecKey: AVVideoCodecType.h264.rawValue,
                    AVVideoWidthKey: width, AVVideoHeightKey: height]
        }
        var result: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if let width, let height {
            result[kCVPixelBufferWidthKey as String] = width
            result[kCVPixelBufferHeightKey as String] = height
        }
        return result
    }
    func validateAvailableCodecs(_ codecs: [String]) throws {
        guard self != .h264 || codecs.contains(AVVideoCodecType.h264.rawValue) else {
            throw BridgeFailure("output_codec_unavailable", "目前擷取格式未提供 H.264 診斷輸出")
        }
    }
}

enum CaptureNegotiationSanitizer {
    static func seconds(_ time: CMTime) -> Double? {
        let value = CMTimeGetSeconds(time)
        return value.isFinite && value > 0 ? value : nil
    }
    static func valueTypes(_ settings: [String: Any]) -> [String: String] {
        settings.mapValues { value in
            switch value {
            case is String: "string"
            case is Bool: "boolean"
            case is Int, is Int8, is Int16, is Int32, is Int64,
                 is UInt, is UInt8, is UInt16, is UInt32, is UInt64: "integer"
            case is Float, is Double: "number"
            default: "unsupported"
            }
        }
    }
}
public struct CaptureStats: Codable, Sendable {
    public var sessionID: String
    public var frames: Int
    public var recentFPS: Double
    public var frame: FrameInfo?
    public var age: Double?
    public var audio: AudioStats
    public var sampleDiagnostics: CaptureSampleDiagnostics? = nil
}

/// Shared with CaptureEngine's lifecycle lock. A callback snapshots a binding
/// before inspecting its sample, then commits under this same lock. Reset and
/// reactivation cannot slip between the final validation and store mutation.
final class CaptureCallbackFence: @unchecked Sendable {
    enum Kind: Sendable, Hashable { case video, audio }
    struct Binding: Sendable, Equatable {
        let output: ObjectIdentifier
        let kind: Kind
        let generation: UInt64
        let activation: UInt64
    }
    private let lock: NSLock
    private var generation: UInt64 = 0
    private var activation: UInt64 = 0
    private var bindings: [Kind: Binding] = [:]
    init(lock: NSLock = NSLock()) { self.lock = lock }
    func currentGeneration() -> UInt64 { lock.withLock { generation } }
    func isCurrent(_ expected: UInt64) -> Bool { lock.withLock { generation == expected } }
    func advance() -> UInt64 {
        lock.withLock { generation &+= 1; bindings.removeAll(); return generation }
    }
    func invalidate(_ kind: Kind) { lock.withLock { _ = bindings.removeValue(forKey: kind) } }
    func invalidateAll(perform action: () -> Void = {}) {
        lock.withLock { bindings.removeAll(); action() }
    }
    @discardableResult
    func whileCurrent(_ expected: UInt64, perform action: () -> Void) -> Bool {
        lock.withLock { guard generation == expected else { return false }; action(); return true }
    }
    func withCurrent<T>(_ expected: UInt64, perform action: () throws -> T) throws -> T {
        try lock.withLock {
            guard generation == expected else { throw BridgeFailure("session_changed", "相機擷取連線已改變") }
            return try action()
        }
    }
    func activate(output: ObjectIdentifier, kind: Kind, generation expected: UInt64,
                  prepare: () -> Void = {}) -> Binding? {
        lock.withLock {
            guard generation == expected else { return nil }
            activation &+= 1
            let binding = Binding(output: output, kind: kind, generation: generation, activation: activation)
            prepare()
            bindings[kind] = binding
            return binding
        }
    }
    func begin(output: ObjectIdentifier) -> Binding? {
        lock.withLock { bindings.values.first { $0.output == output && $0.generation == generation } }
    }
    @discardableResult
    func commit(_ binding: Binding, perform action: () -> Void) -> Bool {
        lock.withLock {
            guard binding.generation == generation, bindings[binding.kind] == binding else { return false }
            action()
            return true
        }
    }
}

/// All CoreMedia/CoreVideo getters are evaluated before the lifecycle commit.
struct CaptureVideoMetadata: Sendable {
    let pts: Double
    let inputMediaSubType: UInt32?
    let outputMediaSubType: UInt32
    let width: Int
    let height: Int
    let receivedAt: Date
    let receivedUptime: Double
    init(buffer: CVPixelBuffer, pts: Double, inputMediaSubType: UInt32?,
         receivedAt: Date = Date(), receivedUptime: Double = ProcessInfo.processInfo.systemUptime) {
        self.pts = pts; self.inputMediaSubType = inputMediaSubType
        outputMediaSubType = CVPixelBufferGetPixelFormatType(buffer)
        width = CVPixelBufferGetWidth(buffer); height = CVPixelBufferGetHeight(buffer)
        self.receivedAt = receivedAt; self.receivedUptime = receivedUptime
    }
}

public final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var packet: FramePacket?
    private var generation = UUID().uuidString
    private var deviceID = ""
    private var frameCount = 0
    private var times: [Double] = []
    private var audio = AudioStats()
    private var diagnostics = CaptureSampleDiagnostics()
    public init() {}
    public func reset(deviceID: String = "") {
        lock.lock(); defer { lock.unlock() }
        generation = UUID().uuidString; self.deviceID = deviceID; packet = nil; frameCount = 0; times = []; audio = AudioStats(); diagnostics = CaptureSampleDiagnostics()
    }
    public func recordVideoSample(hasImageBuffer: Bool, hasBlockBuffer: Bool,
                                  mediaSubType: UInt32?, inputMediaSubType: UInt32?) {
        lock.withLock {
            diagnostics.videoSampleCount += 1
            if hasImageBuffer { diagnostics.pixelBufferCount += 1 }
            else {
                diagnostics.nonImageVideoSampleCount += 1
                if hasBlockBuffer { diagnostics.nonImageVideoBlockBufferCount += 1 }
            }
            diagnostics.lastVideoSampleFourCC = mediaSubType.map(CapturePixelFormat.fourCCString)
            diagnostics.lastVideoInputFourCC = inputMediaSubType.map(CapturePixelFormat.fourCCString)
        }
    }
    public func recordH264Decode(success: Bool, durationSeconds: Double) {
        guard durationSeconds.isFinite && durationSeconds >= 0 else { return }
        lock.withLock {
            if success { diagnostics.decodedH264FrameCount = (diagnostics.decodedH264FrameCount ?? 0) + 1 }
            else { diagnostics.h264DecodeFailureCount = (diagnostics.h264DecodeFailureCount ?? 0) + 1 }
            let milliseconds = durationSeconds * 1_000
            diagnostics.h264DecodeTotalMilliseconds = (diagnostics.h264DecodeTotalMilliseconds ?? 0) + milliseconds
            diagnostics.h264DecodeMaximumMilliseconds = max(diagnostics.h264DecodeMaximumMilliseconds ?? 0, milliseconds)
        }
    }
    public func recordOutputConfiguration(policy: String, pixelFormats: [UInt32], codecs: [String]) {
        lock.withLock {
            diagnostics.requestedOutputPolicy = policy
            diagnostics.availableVideoOutputPixelFormats = pixelFormats.map(CapturePixelFormat.fourCCString)
            diagnostics.availableVideoOutputCodecs = codecs
        }
    }
    public func recordNegotiation(activeFormat: CMFormatDescription, requestedFrameRate: Double,
                                  requestedFrameDuration: CMTime, activeMinFrameDuration: CMTime,
                                  activeMaxFrameDuration: CMTime,
                                  sessionPreset: String, outputVideoSettings: [String: Any]?,
                                  connectionEnabled: Bool?, connectionActive: Bool?,
                                  inputPortFormat: CMFormatDescription?, sessionRunning: Bool,
                                  deviceConnected: Bool) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(activeFormat)
        lock.withLock {
            diagnostics.activeFormatFourCC = CapturePixelFormat.fourCCString(CMFormatDescriptionGetMediaSubType(activeFormat))
            diagnostics.activeFormatWidth = Int(dimensions.width); diagnostics.activeFormatHeight = Int(dimensions.height)
            diagnostics.requestedFrameRate = requestedFrameRate; diagnostics.sessionPreset = sessionPreset
            diagnostics.requestedFrameDurationSeconds = CaptureNegotiationSanitizer.seconds(requestedFrameDuration)
            diagnostics.activeMinFrameDurationSeconds = CaptureNegotiationSanitizer.seconds(activeMinFrameDuration)
            diagnostics.activeMaxFrameDurationSeconds = CaptureNegotiationSanitizer.seconds(activeMaxFrameDuration)
            diagnostics.outputVideoSettingsWasNil = outputVideoSettings == nil
            diagnostics.outputVideoSettingsKeys = outputVideoSettings?.keys.sorted()
            diagnostics.outputVideoSettingsValueTypes = outputVideoSettings.map(CaptureNegotiationSanitizer.valueTypes)
            diagnostics.connectionEnabled = connectionEnabled; diagnostics.connectionActive = connectionActive
            diagnostics.inputPortFourCC = inputPortFormat.map { CapturePixelFormat.fourCCString(CMFormatDescriptionGetMediaSubType($0)) }
            diagnostics.sessionRunning = sessionRunning; diagnostics.deviceConnected = deviceConnected
        }
    }
    public func recordCallbackTimeout() {
        lock.withLock {
            diagnostics.callbackTimeoutCount = (diagnostics.callbackTimeoutCount ?? 0) + 1
            diagnostics.callbackWaitTimedOut = true
            diagnostics.noVideoSample = diagnostics.videoSampleCount == 0
        }
    }
    public func recordRuntimeError(avFoundationCode: Int?) {
        lock.withLock {
            diagnostics.runtimeErrorCount += 1
            diagnostics.lastAVFoundationErrorCode = avFoundationCode
        }
    }
    public func recordInterruption(active: Bool) {
        lock.withLock {
            if active { diagnostics.interruptionCount += 1 }
            else { diagnostics.interruptionEndedCount += 1 }
            diagnostics.interrupted = active
        }
    }
    public func sampleDiagnostics() -> CaptureSampleDiagnostics { lock.withLock { diagnostics } }
    public func receive(_ buffer: CVPixelBuffer, pts: Double, inputMediaSubType: UInt32? = nil) {
        receive(buffer, metadata: CaptureVideoMetadata(buffer: buffer, pts: pts, inputMediaSubType: inputMediaSubType))
    }
    func receive(_ buffer: CVPixelBuffer, metadata: CaptureVideoMetadata) {
        lock.lock(); defer { lock.unlock() }
        guard !deviceID.isEmpty else { return }
        let now = metadata.receivedUptime
        frameCount += 1; times.append(now); if times.count > 150 { times.removeFirst(times.count - 150) }
        var info = FrameInfo(id: "\(generation):\(frameCount)", sessionID: generation, deviceID: deviceID, receivedAt: metadata.receivedAt, receivedUptime: now, presentationTime: metadata.pts, width: metadata.width, height: metadata.height)
        info.inputPixelFormat = metadata.inputMediaSubType.flatMap(CapturePixelFormat.init(mediaSubType:))
        info.inputPixelFormatFourCC = metadata.inputMediaSubType.map(CapturePixelFormat.fourCCString)
        info.outputPixelFormat = CapturePixelFormat.fourCCString(metadata.outputMediaSubType)
        packet = FramePacket(pixelBuffer: buffer, info: info)
    }
    public func resetAudio() { lock.withLock { audio = AudioStats() } }
    public func receiveAudio(frames: Int, rate: Double, channels: Int, rms: Double, peak: Double) {
        lock.lock(); defer { lock.unlock() }
        audio.buffers += 1; audio.sampleFrames += frames; audio.sampleRate = rate; audio.channels = channels; audio.rms = rms; audio.peak = peak
    }
    public func latest(maxAge: Double = 1, after: Double = 0) throws -> FramePacket {
        lock.lock(); defer { lock.unlock() }
        guard let packet else { throw BridgeFailure("no_frame", "相機尚未提供影格", retryable: true) }
        guard ProcessInfo.processInfo.systemUptime - packet.info.receivedUptime <= maxAge, packet.info.receivedUptime > after else { throw BridgeFailure("stale_frame", "尚未取得符合要求的新影格", retryable: true) }
        return packet
    }
    public func stats() -> CaptureStats {
        lock.lock(); defer { lock.unlock() }
        let fresh = packet.map { ProcessInfo.processInfo.systemUptime - $0.info.receivedUptime <= 1 } ?? false
        let fps = fresh && times.count > 1 ? Double(times.count - 1) / max(0.001, times.last! - times.first!) : 0
        return CaptureStats(sessionID: generation, frames: frameCount, recentFPS: fps, frame: packet?.info, age: packet.map { ProcessInfo.processInfo.systemUptime - $0.info.receivedUptime }, audio: audio, sampleDiagnostics: diagnostics)
    }
}

public final class CaptureEngine: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public let session = AVCaptureSession()
    public let store = FrameStore()
    private let queue = DispatchQueue(label: "studio.yuhuan.pocket3.capture", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "studio.yuhuan.pocket3.frames", qos: .userInitiated)
    private var audioInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var avc1Decoder: AVC1SampleDecoder?
    private var sessionObservers: [NSObjectProtocol] = []
    private let captureActivity = CaptureActivityLease()
    private let lifecycleLock: NSLock
    private let callbackFence: CaptureCallbackFence
    private var failedStartDiagnostics: CaptureSampleDiagnostics?
    private func advanceLifecycle() -> UInt64 { callbackFence.advance() }
    func currentLifecycle() -> UInt64 { callbackFence.currentGeneration() }
    private func isCurrent(_ generation: UInt64) -> Bool { callbackFence.isCurrent(generation) }
    public override init() {
        let lock = NSLock()
        lifecycleLock = lock; callbackFence = CaptureCallbackFence(lock: lock)
        super.init()
        let store = self.store
        let center = NotificationCenter.default
        sessionObservers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                store.recordRuntimeError(avFoundationCode: error?.domain == AVFoundationErrorDomain ? error?.code : nil)
                self?.reconcileCaptureActivity()
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
                store.recordInterruption(active: true)
                self?.reconcileCaptureActivity()
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
                store.recordInterruption(active: false)
                self?.reconcileCaptureActivity()
            },
            center.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: session, queue: nil) { [weak self] _ in
                self?.reconcileCaptureActivity()
            },
            center.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session, queue: nil) { [weak self] _ in
                self?.reconcileCaptureActivity()
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] _ in
                self?.reconcileCaptureActivity()
            }
        ]
    }
    deinit {
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        captureActivity.stop()
    }
    private func reconcileCaptureActivity() {
        // Capture the lifecycle at notification arrival, then inspect AVF on
        // its owning queue. Notification delivery can lag a stop/start cycle.
        let generation = currentLifecycle()
        queue.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.captureActivity.reconcile(generation: generation, isRunning: self.session.isRunning,
                deviceConnected: self.currentVideoDeviceOnQueue()?.isConnected == true)
        }
    }
    public func lastFailedStartDiagnostics() -> CaptureSampleDiagnostics? {
        lifecycleLock.withLock { failedStartDiagnostics }
    }
    public static func devices() -> [CameraDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
            .filter { $0.modelID.contains("VendorID_11427 ProductID_35") }
            .map { CameraDevice(id: $0.uniqueID, name: $0.localizedName, location: CameraDevice.location(from: $0.uniqueID)) }
    }
    public static func permission() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        default: "notDetermined"
        }
    }
    /// Reads only the current session's video input. No discovery, permission
    /// prompt, configuration lock or property write is performed by this probe.
    public func focusCapabilities() async -> FocusCapabilities {
        let generation = currentLifecycle()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard isCurrent(generation), session.isRunning, let device = currentVideoDeviceOnQueue(), device.isConnected else {
                    continuation.resume(returning: .unavailable); return
                }
                let stats = store.stats()
                let token = CaptureLifecycleToken(generation: generation, sessionID: stats.sessionID, deviceID: device.uniqueID)
                let result = FocusCapabilities(supportsPoint: device.isFocusPointOfInterestSupported,
                    supportsAuto: device.isFocusModeSupported(.autoFocus),
                    supportsContinuous: device.isFocusModeSupported(.continuousAutoFocus),
                    currentMode: Self.focusMode(device.focusMode), sessionToken: token)
                let current = isCurrent(generation) && store.stats().sessionID == token.sessionID
                continuation.resume(returning: current ? result : .unavailable)
            }
        }
    }

    /// Sets a normalized device point and triggers supported autofocus on the
    /// existing input. The caller must convert preview coordinates first.
    public func focus(at point: CGPoint, sessionToken token: CaptureLifecycleToken) async throws -> FocusResult {
        let requested = try CameraFocusPoint(point)
        try Task.checkCancellation()
        let permit = OperationPermit()
        return try await withTaskCancellationHandler {
            let result: FocusResult = try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        try permit.perform {}
                        guard session.isRunning, let device = currentVideoDeviceOnQueue(), device.isConnected else {
                            throw BridgeFailure("not_connected", "請先連接相機")
                        }
                        let frame = try store.latest(maxAge: 1).info
                        try token.validate(generation: currentLifecycle(), sessionID: frame.sessionID, deviceID: device.uniqueID)
                        guard frame.deviceID == device.uniqueID else { throw BridgeFailure("session_changed", "相機影像來源已改變") }
                        let mode = try FocusPointPolicy.mode(supportsPoint: device.isFocusPointOfInterestSupported,
                            supportsAuto: device.isFocusModeSupported(.autoFocus),
                            supportsContinuous: device.isFocusModeSupported(.continuousAutoFocus))
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }
                        let result = try permit.perform {
                            try callbackFence.withCurrent(token.generation) {
                                let current = try store.latest(maxAge: 1).info
                                try token.validate(generation: token.generation, sessionID: current.sessionID, deviceID: device.uniqueID)
                                guard current.deviceID == token.deviceID, device.isConnected else {
                                    throw BridgeFailure("session_changed", "相機影像來源已改變")
                                }
                                // Recheck capability immediately before setting either property.
                                let currentMode = try FocusPointPolicy.mode(supportsPoint: device.isFocusPointOfInterestSupported,
                                    supportsAuto: device.isFocusModeSupported(.autoFocus),
                                    supportsContinuous: device.isFocusModeSupported(.continuousAutoFocus))
                                guard currentMode == mode else { throw BridgeFailure("focus_mode_changed", "相機對焦能力已改變") }
                                let submitted = ProcessInfo.processInfo.systemUptime
                                device.focusPointOfInterest = requested.cgPoint
                                device.focusMode = mode == .autoFocus ? .autoFocus : .continuousAutoFocus
                                return FocusResult(sessionID: token.sessionID, requestedPoint: requested,
                                    observedPoint: try? CameraFocusPoint(device.focusPointOfInterest), requestedMode: mode,
                                    observedMode: Self.focusMode(device.focusMode), adjustingFocus: device.isAdjustingFocus,
                                    submittedUptime: submitted, readbackUptime: ProcessInfo.processInfo.systemUptime)
                            }
                        }
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            guard isCurrent(token.generation), store.stats().sessionID == token.sessionID else {
                throw BridgeFailure("session_changed", "對焦請求期間相機連線已改變")
            }
            return result
        } onCancel: { permit.invalidate() }
    }

    private func currentVideoDeviceOnQueue() -> AVCaptureDevice? {
        session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first { $0.device.hasMediaType(.video) }?.device
    }
    private static func focusMode(_ mode: AVCaptureDevice.FocusMode) -> CaptureFocusMode? {
        switch mode {
        case .locked: .locked
        case .autoFocus: .autoFocus
        case .continuousAutoFocus: .continuousAutoFocus
        @unknown default: nil
        }
    }
    public func start(deviceID: String, mode: CaptureMode = .default1080p30, pixelFormat: CapturePixelFormat = .automatic,
                      outputPolicy explicitOutputPolicy: CaptureOutputPolicy? = nil) async throws {
        lifecycleLock.withLock { failedStartDiagnostics = nil }
        let outputPolicy = explicitOutputPolicy ?? CaptureOutputPolicy.selected(environment: ProcessInfo.processInfo.environment,
                                                                                arguments: CommandLine.arguments)
        guard mode.width > 0, mode.width <= Int32.max, mode.height > 0, mode.height <= Int32.max,
              mode.frameRate.isFinite, mode.frameRate > 0 else { throw BridgeFailure("invalid_format", "無效的影像格式") }
        let generation = advanceLifecycle()
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
        try Task.checkCancellation()
        guard isCurrent(generation) else { throw CancellationError() }
        guard Self.permission() == "authorized" else { throw BridgeFailure("camera_permission", "請在系統設定的隱私權與安全性中允許 \(Pocket3Product.displayName) 使用相機") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard isCurrent(generation) else { throw CancellationError() }
                    stopOnQueue()
                    guard callbackFence.whileCurrent(generation, perform: { store.reset(deviceID: deviceID) }) else { throw CancellationError() }
                    guard let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices.first(where: { $0.uniqueID == deviceID && $0.modelID.contains("VendorID_11427 ProductID_35") }) else { throw BridgeFailure("device_missing", "選定的 Pocket 3 已離線") }
                    let width = Int32(mode.width), height = Int32(mode.height)
                    let matching = device.formats.filter { f in
                        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                        return d.width == width && d.height == height
                            && pixelFormat.accepts(mediaSubType: CMFormatDescriptionGetMediaSubType(f.formatDescription))
                            && f.videoSupportedFrameRateRanges.contains {
                            mode.supports(minFrameRate: $0.minFrameRate, maxFrameRate: $0.maxFrameRate)
                        }
                    }.sorted {
                        CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                            && CMFormatDescriptionGetMediaSubType($1.formatDescription) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    }
                    guard let format = matching.first, let range = format.videoSupportedFrameRateRanges.first(where: {
                        mode.supports(minFrameRate: $0.minFrameRate, maxFrameRate: $0.maxFrameRate)
                    }) else { throw BridgeFailure("format_unavailable", "裝置未提供要求的 \(mode.title) · \(pixelFormat.title) 輸入格式") }
                    let duration = abs(range.maxFrameRate - mode.frameRate) < 0.01 ? range.minFrameDuration : CMTime(seconds: 1 / mode.frameRate, preferredTimescale: 600_000)
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureVideoDataOutput()
                    output.videoSettings = outputPolicy.settings()
                    output.alwaysDiscardsLateVideoFrames = true
                    session.beginConfiguration()
                    guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); throw BridgeFailure("capture_unavailable", "無法建立相機擷取，請關閉其他可能占用相機的程式後重試") }
                    session.addInput(input); session.addOutput(output)
                    // macOS has no inputPriority preset. Keep its supported
                    // session preset and the explicit device format in agreement.
                    let preset: AVCaptureSession.Preset
                    switch (mode.width, mode.height) {
                    case (3840, 2160): preset = .hd4K3840x2160
                    case (1920, 1080): preset = .hd1920x1080
                    case (1280, 720): preset = .hd1280x720
                    default: preset = .high
                    }
                    guard session.canSetSessionPreset(preset) else { session.commitConfiguration(); throw BridgeFailure("format_unavailable", "相機無法使用要求的擷取格式") }
                    session.sessionPreset = preset
                    if let connection = output.connection(with: .video) {
                        if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
                        if connection.isVideoMirroringSupported {
                            connection.automaticallyAdjustsVideoMirroring = false
                            connection.isVideoMirrored = false
                        }
                    }
                    var configurationCommitted = false
                    do {
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }
                        device.activeFormat = format
                        device.activeVideoMinFrameDuration = duration
                        device.activeVideoMaxFrameDuration = duration
                        // Supported output choices can change with activeFormat.
                        // Record scalar names only, after the selected format is set.
                        let outputTypes = output.availableVideoPixelFormatTypes
                        let outputCodecs = output.availableVideoCodecTypes.map(\.rawValue)
                        guard callbackFence.whileCurrent(generation, perform: {
                            store.recordOutputConfiguration(policy: outputPolicy.rawValue, pixelFormats: outputTypes, codecs: outputCodecs)
                        }) else { throw CancellationError() }
                        try outputPolicy.validateAvailableCodecs(outputCodecs)
                        output.videoSettings = outputPolicy.settings(width: Int(width), height: Int(height))
                        let videoConnection = output.connection(with: .video)
                        let portFormat = input.ports.first(where: { $0.mediaType == .video })?.formatDescription
                        store.recordNegotiation(activeFormat: device.activeFormat.formatDescription,
                            requestedFrameRate: mode.frameRate, requestedFrameDuration: duration,
                            activeMinFrameDuration: device.activeVideoMinFrameDuration,
                            activeMaxFrameDuration: device.activeVideoMaxFrameDuration,
                            sessionPreset: session.sessionPreset.rawValue,
                            outputVideoSettings: output.videoSettings,
                            connectionEnabled: videoConnection?.isEnabled, connectionActive: videoConnection?.isActive,
                            inputPortFormat: portFormat, sessionRunning: session.isRunning,
                            deviceConnected: device.isConnected)
                        guard callbackFence.activate(output: ObjectIdentifier(output), kind: .video, generation: generation) != nil else { throw CancellationError() }
                        output.setSampleBufferDelegate(self, queue: frameQueue)
                        session.commitConfiguration()
                        configurationCommitted = true
                        guard isCurrent(generation) else { throw CancellationError() }
                        session.startRunning()
                        store.recordNegotiation(activeFormat: device.activeFormat.formatDescription,
                            requestedFrameRate: mode.frameRate, requestedFrameDuration: duration,
                            activeMinFrameDuration: device.activeVideoMinFrameDuration,
                            activeMaxFrameDuration: device.activeVideoMaxFrameDuration,
                            sessionPreset: session.sessionPreset.rawValue,
                            outputVideoSettings: output.videoSettings,
                            connectionEnabled: videoConnection?.isEnabled, connectionActive: videoConnection?.isActive,
                            inputPortFormat: portFormat, sessionRunning: session.isRunning,
                            deviceConnected: device.isConnected)
                    } catch { if !configurationCommitted { session.commitConfiguration() }; throw error }
                    guard isCurrent(generation) else { throw CancellationError() }
                    let actual = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    guard actual.width == width && actual.height == height else { throw BridgeFailure("format_changed", "相機將要求格式改為 \(actual.width)×\(actual.height)，請選擇其他格式") }
                    let actualSubType = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
                    guard pixelFormat.accepts(mediaSubType: actualSubType) else { throw BridgeFailure("input_format_changed", "相機將輸入格式改為 \(CapturePixelFormat.fourCCString(actualSubType))，未套用要求的 \(pixelFormat.title)") }
                    guard session.isRunning else { throw BridgeFailure("capture_start_failed", "相機未能開始取像") }
                    guard callbackFence.whileCurrent(generation, perform: {
                        captureActivity.start(generation: generation)
                    }) else { throw CancellationError() }
                    continuation.resume()
                } catch {
                    let attempt = store.sampleDiagnostics()
                    lifecycleLock.withLock { failedStartDiagnostics = attempt }
                    stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    public func stop() async {
        _ = advanceLifecycle()
        await withCheckedContinuation { continuation in queue.async { self.stopOnQueue(); continuation.resume() } }
    }
    private func stopOnQueue() {
        captureActivity.stop()
        avc1Decoder?.invalidate(); avc1Decoder = nil
        // Invalidate first: even a callback already computing outside the lock
        // cannot commit after this point. Detach delegates before stop/removal.
        callbackFence.invalidateAll()
        for output in session.outputs {
            if let video = output as? AVCaptureVideoDataOutput { video.setSampleBufferDelegate(nil, queue: nil) }
            if let audio = output as? AVCaptureAudioDataOutput { audio.setSampleBufferDelegate(nil, queue: nil) }
        }
        session.stopRunning()
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }; session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration(); audioInput = nil; audioOutput = nil
        frameQueue.sync {}
        callbackFence.invalidateAll { store.reset() }
    }
    public func setAudio(enabled: Bool, sessionToken: UInt64? = nil) async throws {
        let generation = sessionToken ?? currentLifecycle()
        if enabled && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        try Task.checkCancellation()
        guard isCurrent(generation) else { throw BridgeFailure("session_changed", "音訊授權期間相機連線已改變") }
        if enabled && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { throw BridgeFailure("microphone_permission", "尚未允許 \(Pocket3Product.displayName) 使用麥克風") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard isCurrent(generation) else { throw BridgeFailure("session_changed", "音訊啟用前相機連線已改變") }
                    guard session.isRunning else { throw BridgeFailure("not_connected", "請先連接相機") }
                    callbackFence.invalidate(.audio)
                    audioOutput?.setSampleBufferDelegate(nil, queue: nil)
                    try {
                        session.beginConfiguration()
                        defer { session.commitConfiguration() }
                        if let audioInput { session.removeInput(audioInput); self.audioInput = nil }
                        if let audioOutput { session.removeOutput(audioOutput); self.audioOutput = nil }
                        frameQueue.sync {}
                        if enabled {
                            let items = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices.filter { $0.modelID.contains("2CA3:0023") }
                            guard items.count == 1, let device = items.first else { throw BridgeFailure("audio_ambiguous", "无法唯一確認 Pocket 3 音訊來源") }
                            let input = try AVCaptureDeviceInput(device: device)
                            let output = AVCaptureAudioDataOutput()
                            output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
                            guard session.canAddInput(input), session.canAddOutput(output) else { throw BridgeFailure("audio_unavailable", "無法同時加入相機音訊") }
                            guard callbackFence.activate(output: ObjectIdentifier(output), kind: .audio, generation: generation,
                                prepare: { store.resetAudio() }) != nil else { throw BridgeFailure("session_changed", "音訊啟用期間相機連線已改變") }
                            output.setSampleBufferDelegate(self, queue: frameQueue)
                            session.addInput(input); session.addOutput(output)
                            audioInput = input; audioOutput = output
                        }
                    }()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        if enabled {
            // Configuration may restart the AVFoundation graph. Do not report
            // success (or start a timed audio test) until actual buffers arrive.
            let configuredAt = ProcessInfo.processInfo.systemUptime
            let deadline = configuredAt + 5
            repeat {
                try Task.checkCancellation()
                guard isCurrent(generation) else { throw BridgeFailure("session_changed", "音訊啟動期間相機連線已改變") }
                let stats = store.stats()
                if stats.audio.sampleFrames > 0 && (stats.frame?.receivedUptime ?? 0) > configuredAt && (stats.age ?? .infinity) <= 1 { return }
                try await Task.sleep(for: .milliseconds(50))
            } while ProcessInfo.processInfo.systemUptime < deadline
            throw BridgeFailure("audio_start_timeout", "未能取得新的相機影音資料，請重新連接")
        }
    }
    public func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let binding = callbackFence.begin(output: ObjectIdentifier(output)) else { return }
        let receivedAt = Date(), receivedUptime = ProcessInfo.processInfo.systemUptime
        let pixel = CMSampleBufferGetImageBuffer(sample)
        let description = CMSampleBufferGetFormatDescription(sample)
        if binding.kind == .video {
            let inputDescription = connection.inputPorts.first(where: { $0.mediaType == .video })?.formatDescription
            let inputSubType = inputDescription.map(CMFormatDescriptionGetMediaSubType)
            let mediaSubType = description.map(CMFormatDescriptionGetMediaSubType)
            let hasBlockBuffer = CMSampleBufferGetDataBuffer(sample) != nil
            let decodedPixel: CVPixelBuffer?
            if pixel == nil, mediaSubType == kCMVideoCodecType_H264, hasBlockBuffer {
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    if avc1Decoder == nil { avc1Decoder = AVC1SampleDecoder() }
                    decodedPixel = try avc1Decoder?.decode(sample).pixelBuffer
                    store.recordH264Decode(success: decodedPixel != nil, durationSeconds: ProcessInfo.processInfo.systemUptime - started)
                } catch {
                    store.recordH264Decode(success: false, durationSeconds: ProcessInfo.processInfo.systemUptime - started)
                    decodedPixel = nil
                }
            } else { decodedPixel = nil }
            let deliveredPixel = pixel ?? decodedPixel
            let metadata = deliveredPixel.map { CaptureVideoMetadata(buffer: $0,
                pts: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), inputMediaSubType: inputSubType,
                receivedAt: receivedAt, receivedUptime: receivedUptime) }
            callbackFence.commit(binding) {
                store.recordVideoSample(hasImageBuffer: pixel != nil, hasBlockBuffer: hasBlockBuffer,
                    mediaSubType: mediaSubType, inputMediaSubType: inputSubType)
                if let deliveredPixel, let metadata { store.receive(deliveredPixel, metadata: metadata) }
            }
        } else if binding.kind == .audio,
                  let desc = description, let fmt = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
                  fmt.mFormatID == kAudioFormatLinearPCM, fmt.mBitsPerChannel == 16,
                  fmt.mSampleRate.isFinite, fmt.mSampleRate > 0,
                  fmt.mFormatFlags & kAudioFormatFlagIsFloat == 0, fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                  fmt.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  let block = CMSampleBufferGetDataBuffer(sample) {
            let bytes = CMBlockBufferGetDataLength(block)
            guard AudioTestPolicy.acceptsPCM16(byteCount: bytes, frames: CMSampleBufferGetNumSamples(sample), channels: fmt.mChannelsPerFrame) else { return }
            var samples = [Int16](repeating: 0, count: bytes / 2)
            guard samples.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }) == noErr else { return }
            var sum = 0.0, peak = 0.0
            for s in samples { let v = Double(s) / 32768; sum += v*v; peak = max(peak, abs(v)) }
            let frames = CMSampleBufferGetNumSamples(sample), rms = sqrt(sum/Double(samples.count))
            callbackFence.commit(binding) {
                store.receiveAudio(frames: frames, rate: fmt.mSampleRate, channels: Int(fmt.mChannelsPerFrame), rms: rms, peak: peak)
            }
        }
    }
}
