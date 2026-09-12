import Foundation
import ImageIO

/// Internal transport seam. Production uses the retained UVC actor unchanged;
/// tests can exercise the real service/IPC cancellation and independent Stop
/// without constructing a USB connection or issuing hardware requests.
protocol CameraControlConnection: AnyObject, Sendable {
    func invalidate()
    func status() async throws -> UVCCapabilities
    func set(_ position: GimbalPosition, permit: OperationPermit?) async throws
    func zoomStatus() async throws -> USBZoomCapabilities
    func setZoom(rawValue: Int, validUntil: TimeInterval, permit: OperationPermit,
                 connectionPermit: OperationPermit?) async throws
    func rollStatus() async throws -> USBRollCapabilities
    func setRoll(rawValue: Int, validUntil: TimeInterval, permit: OperationPermit,
                 connectionPermit: OperationPermit?) async throws
    func setFast(_ position: GimbalPosition, validUntil: TimeInterval, permit: OperationPermit,
                 connectionPermit: OperationPermit?) async throws
}
extension UVCConnection: CameraControlConnection {}

/// Test-only status dependencies. Production status reads continue to use
/// CaptureEngine discovery and FrameStore freshness directly; tests can model
/// discovery, a healthy capture stream, and attachment invalidation without
/// opening a real camera.
struct CameraServiceStatusSeam: Sendable {
    let devices: @Sendable () -> [CameraDevice]
    let captureIsFreshForSelectedDevice: @Sendable (String) -> Bool
    let onAttachmentInvalidated: (@Sendable () async -> Void)?

    init(
        devices: @escaping @Sendable () -> [CameraDevice],
        captureIsFreshForSelectedDevice: @escaping @Sendable (String) -> Bool,
        onAttachmentInvalidated: (@Sendable () async -> Void)? = nil
    ) {
        self.devices = devices
        self.captureIsFreshForSelectedDevice = captureIsFreshForSelectedDevice
        self.onAttachmentInvalidated = onAttachmentInvalidated
    }
}

public struct ServiceStatus: Codable, Sendable {
    public var appVersion: String = Pocket3Product.semanticVersion
    public var buildVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    public var phase: String
    public var devices: [CameraDevice]
    public var selected: CameraDevice?
    public var access: AccessMode
    public var permission: String
    public var capture: CaptureStats
    public var gimbal: UVCCapabilities?
    public var motionActive: Bool
    public var stopStrategy: String = "hold_current_uvc_target_and_verify_readback"
    public var stopValidated: Bool
    public var lastError: String?
    public var activities: [Activity]
    public var requestedMode: CaptureMode? = nil
    public var requestedPixelFormat: CapturePixelFormat? = nil
    public var requestedOutputPolicy: CaptureOutputPolicy? = nil
    public var lastCaptureAttempt: CaptureSampleDiagnostics? = nil
    public var power: USBPowerStatus? = nil
    public var controlTransport: String? = nil
    public var controlReadIssueCode: String? = nil
    public var lastControlReadFailureAt: Date? = nil
    public var nativeControl: NativeControlStatus? = nil
    /// Typed capability graph.  The optional keeps older status replies
    /// decodable while new replies always publish the current graph.
    public var capabilities: Pocket3CapabilityGraph? = nil
    public var capabilityGraph: Pocket3CapabilityGraph? {
        get { capabilities }
        set { capabilities = newValue }
    }
    /// Developer capture isolation only; nil remains compatible with older replies.
    public var uvcControlDisabledForCapture: Bool? = nil
    /// Independent Roll motion/stop hardware acceptance. Pan/Tilt evidence does
    /// not unlock this capability; ordinary raw readback is not that evidence.
    public var rollStopValidated: Bool? = nil
}

/// One developer calibration target, anchored to an exact freshly read origin.
/// The five-degree bound uses nominal UVC units, not calibrated physical angles.
struct ValidationPositionProbe: Sendable {
    static let maximumDelta: Int64 = 5 * 3600
    let panDegrees: Double?
    let tiltDegrees: Double?
    let expectedOrigin: GimbalPosition

    init(arguments: JSONValue) throws {
        guard case .object(let values) = arguments,
              Set(values.keys).isSubset(of: ["panDegrees", "tiltDegrees", "expectedPanRaw", "expectedTiltRaw"]),
              values.keys.contains("panDegrees") != values.keys.contains("tiltDegrees") else {
            throw BridgeFailure("invalid_position_probe", "探測只接受一個絕對軸目標與完整預期原點")
        }
        let axis = values.keys.contains("panDegrees") ? "panDegrees" : "tiltDegrees"
        guard let angle = values[axis]?.number, angle.isFinite else {
            throw BridgeFailure("invalid_position_probe", "探測角度須為有限數值")
        }
        func raw(_ name: String) throws -> Int32 {
            guard let value = values[name]?.number, value.isFinite, value.rounded() == value,
                  value >= Double(Int32.min), value <= Double(Int32.max) else {
                throw BridgeFailure("invalid_position_probe", "探測須提供 Int32 範圍內的 expectedPanRaw 與 expectedTiltRaw")
            }
            return Int32(value)
        }
        panDegrees = axis == "panDegrees" ? angle : nil
        tiltDegrees = axis == "tiltDegrees" ? angle : nil
        expectedOrigin = try GimbalPosition(pan: raw("expectedPanRaw"), tilt: raw("expectedTiltRaw"))
    }

    func target(from fresh: UVCCapabilities) throws -> GimbalPosition {
        guard fresh.position == expectedOrigin else {
            throw BridgeFailure("probe_origin_changed", "新鮮 USB 原點與預期值不符，沒有送出探測指令")
        }
        guard fresh.writable, let minimum = fresh.minimum, let maximum = fresh.maximum,
              minimum.pan <= maximum.pan, minimum.tilt <= maximum.tilt,
              fresh.position.pan >= minimum.pan, fresh.position.pan <= maximum.pan,
              fresh.position.tilt >= minimum.tilt, fresh.position.tilt <= maximum.tilt else {
            throw BridgeFailure("invalid_readback", "USB 原點或控制範圍無效，不能進行位置探測")
        }
        guard let requestedDegrees = panDegrees ?? tiltDegrees else {
            throw BridgeFailure("invalid_position_probe", "探測只接受一個絕對軸目標")
        }
        let requested = requestedDegrees * 3600
        let current = Double(panDegrees == nil ? fresh.position.tilt : fresh.position.pan)
        guard requested.isFinite, abs(requested - current) <= Double(Self.maximumDelta) else {
            throw BridgeFailure("probe_distance_exceeded", "探測目標須在新鮮原點的 5 個 UVC 度以內")
        }
        let target = try GimbalNavigationPolicy.absolute(panDegrees: panDegrees, tiltDegrees: tiltDegrees,
            origin: fresh.position, capabilities: fresh)
        guard target.distance(to: fresh.position) <= Self.maximumDelta else {
            throw BridgeFailure("probe_distance_exceeded", "探測目標超出距離限制")
        }
        return target
    }
}

public actor CameraService {
    private struct NativeControlReservation: Sendable {
        let binding: ContinuousGimbalBinding
        let readStatus: @Sendable () async -> NativeControlStatus
        let stop: @Sendable () async throws -> MotionResult
        let writePermit: OperationPermit?
    }
    public nonisolated let capture = CaptureEngine()
    private var selected: CameraDevice?
    private var requestedMode: CaptureMode?
    private var requestedPixelFormat: CapturePixelFormat?
    private var requestedOutputPolicy: CaptureOutputPolicy?
    private var lastCaptureAttempt: CaptureSampleDiagnostics?
    private var uvc: (any CameraControlConnection)?
    private var uvcControlDisabledForCapture = false
    private var capabilities: UVCCapabilities?
    private var controlReadIssueCode: String?
    private var lastControlReadFailureAt: Date?
    private var controlReadNeedsValidation = false
    private var controlReadSequence: UInt64 = 0
    private var phase = "idle"
    private var access: AccessMode = .manual
    private var lastError: String?
    private var activities: [Activity] = []
    private var interactionEpoch = 0
    private var activeMotionPermit: OperationPermit?
    private var stopTask: Task<MotionResult, Error>?
    // Cancelling the submitting Task does not stop device-side zoom slew.
    private var zoomNeedsHold = false
    private var zoomHoldRevision: UInt64 = 0
    private var zoomStopWork: (id: UUID, revision: UInt64, connection: any CameraControlConnection, task: Task<USBZoomStopResult, Never>)?
    private var rollNeedsHold = false
    private var rollHoldRevision: UInt64 = 0
    private var rollStopWork: (id: UUID, revision: UInt64, connection: any CameraControlConnection, task: Task<USBRollStopResult, Never>)?
    private var rollStopValidated = false
    private var motionID: UUID?
    private var motionGeneration = 0
    private var lifecycleGeneration = 0
    private var lastMotionEnded = 0.0
    private var stopValidated = false
    private var connectionInProgress = false
    private var audioTestInProgress = false
    private var streamValidationTask: Task<Void, Never>?
    private var streamValidationReport: StreamValidationReport?
    private let validationEnabled: Bool
    private var validationTask: Task<Void, Never>?
    private var validationRunID: UUID?
    private var validationReport: HardwareValidationReport?
    private var validationError: String?
    private var nativeControl: NativeControlReservation?
    /// Context supplied by the App's already-running wireless observer. It is
    /// a scalar projection only; updating it never starts Bluetooth or Wi-Fi.
    private var nativeSessionCapability = NativeSessionCapability.disconnected
    private var bodyRecordingCapabilities: [BodyRecordingFormatCapability] = []
    private var nativeControlPending = false
    private var usbEndpoint: USBContinuousControlEndpoint?
    private var usbAuthorization: (id: UUID, epoch: Int, interaction: Int)?
    private var usbActiveLease: ContinuousGimbalLease?
    private var usbLastStop: (lease: ContinuousGimbalLease, result: MotionResult)?
    private let usesTestConnection: Bool
    private let statusSeam: CameraServiceStatusSeam?
    public init(stopValidated: Bool = false, validationEnabled: Bool = false) {
        self.stopValidated = stopValidated; self.validationEnabled = validationEnabled; usesTestConnection = false
        statusSeam = nil
    }
    /// Internal-only fixture admission. No App/CLI/RPC route can enable it.
    /// Frames are supplied explicitly by tests; no AVF capture is started.
    init(testConnection: any CameraControlConnection, testFrame: FramePacket,
         statusSeam: CameraServiceStatusSeam? = nil) {
        validationEnabled = false; usesTestConnection = true
        self.statusSeam = statusSeam
        stopValidated = true; uvc = testConnection; phase = "ready"; access = .control
        if statusSeam != nil {
            selected = CameraDevice(id: testFrame.info.deviceID, name: "Status fixture", location: nil)
        }
        capture.store.reset(deviceID: testFrame.info.deviceID)
        capture.store.receive(testFrame.pixelBuffer, pts: testFrame.info.presentationTime)
    }
    /// Replaces only an injected fixture, exercising obsolete-operation fences
    /// on the same service actor without opening or reconnecting a real camera.
    func replaceTestConnection(_ connection: any CameraControlConnection, frame: FramePacket) throws {
        guard usesTestConnection else { throw BridgeFailure("fixture_disabled", "This service is not a test fixture") }
        activeMotionPermit?.invalidate(); activeMotionPermit = nil; uvc?.invalidate()
        lifecycleGeneration += 1; motionGeneration += 1; interactionEpoch += 1
        motionID = nil; stopTask = nil
        resetZoomHoldForConnectionChange(); resetRollHoldForConnectionChange()
        usbEndpoint?.connectionPermit.invalidate(); usbEndpoint = nil; usbAuthorization = nil; usbActiveLease = nil
        uvc = connection; phase = "ready"; access = .control; stopValidated = true
        if statusSeam != nil {
            selected = CameraDevice(id: frame.info.deviceID, name: "Status fixture", location: nil)
        }
        controlReadSequence &+= 1
        controlReadIssueCode = nil; lastControlReadFailureAt = nil; controlReadNeedsValidation = false
        capture.store.reset(deviceID: frame.info.deviceID)
        capture.store.receive(frame.pixelBuffer, pts: frame.info.presentationTime)
    }
    /// Publishes read-only context from another transport into the shared
    /// status graph. The graph remains useful when no USB capture is active,
    /// while the optional body list can be cleared when its observations age
    /// out. This method performs no device I/O.
    public func updateCapabilityContext(nativeSession: NativeSessionCapability? = nil,
                                        bodyRecordingFormats: [BodyRecordingFormatCapability]? = nil) {
        if let nativeSession { self.nativeSessionCapability = nativeSession }
        if let bodyRecordingFormats { self.bodyRecordingCapabilities = bodyRecordingFormats }
    }
    private func log(_ op: String, _ message: String, error: Bool = false, presentationKey: String? = nil) {
        activities.insert(Activity(op, message, isError: error, presentationKey: presentationKey), at: 0)
        if activities.count > 80 { activities.removeLast(activities.count - 80) }
    }
    public func setAccess(_ mode: AccessMode) async {
        interactionEpoch += 1
        if mode != .control && (motionID != nil || zoomNeedsHold || rollNeedsHold) { _ = try? await stop() }
        access = (nativeControl != nil || nativeControlPending) && mode == .control ? .observe : mode
        log("access", access.title, presentationKey: "access.\(access.rawValue)")
    }
    /// Reserves the gimbal for the native transport across gestures. USB
    /// position writes remain fenced until this exact connection is released.
    public func reserveNativeControl(binding: ContinuousGimbalBinding,
        readStatus: @escaping @Sendable () async -> NativeControlStatus = { .disconnected },
        writePermit: OperationPermit? = nil,
        stop: @escaping @Sendable () async throws -> MotionResult) async throws {
        guard nativeControl == nil, !nativeControlPending else { throw BridgeFailure("motion_busy", "已有雲台控制連線") }
        nativeControlPending = true
        defer { nativeControlPending = false }
        let generation = lifecycleGeneration
        let expectedMotionGeneration = motionGeneration + 1
        let stopped = try await self.stop()
        try Task.checkCancellation()
        guard generation == lifecycleGeneration, motionGeneration == expectedMotionGeneration else { throw BridgeFailure("session_changed", "相機連線或停止狀態已改變") }
        guard stopped.verified else { throw BridgeFailure("stop_unverified", "尚未確認前一個操作停止，未切換控制通道") }
        access = .manual; interactionEpoch += 1
        try writePermit?.perform {}
        nativeControl = NativeControlReservation(binding: binding, readStatus: readStatus, stop: stop, writePermit: writePermit)
    }
    public func releaseNativeControl(binding: ContinuousGimbalBinding) {
        guard nativeControl?.binding == binding else { return }
        nativeControl?.writePermit?.invalidate()
        nativeControl = nil; interactionEpoch += 1; access = .manual
    }
    /// No I/O: the BLE focus probe checks this exact owner before each burst.
    /// The same permit is synchronously revoked at Stop/lifecycle changes and
    /// checked again under its lock at the final CoreBluetooth write.
    public func validateNativeControlReservation(binding: ContinuousGimbalBinding,
        expectedCaptureSessionID: String, writePermit: OperationPermit) throws {
        try writePermit.perform {
            guard validationEnabled, nativeControl?.binding == binding,
                  nativeControl?.writePermit === writePermit, !nativeControlPending, !connectionInProgress,
                  phase == "ready", motionID == nil, !zoomNeedsHold, !rollNeedsHold,
                  try capture.store.latest(maxAge: 1).info.sessionID == expectedCaptureSessionID else {
                throw BridgeFailure("bluetooth_focus_capture_changed", "The exclusive control owner or fresh USB capture changed")
            }
        }
    }
    /// Atomically releases this research/native reservation before entering
    /// USB hold cleanup. An obsolete callback cannot stop a newer owner.
    public func stopNativeControlAndHold(binding: ContinuousGimbalBinding) async throws -> MotionResult {
        guard nativeControl?.binding == binding else {
            return MotionResult(accepted: false, completed: false, verified: false,
                verification: "stale_control_reservation", target: nil, observed: nil, message: "控制連線已改變")
        }
        nativeControl?.writePermit?.invalidate()
        nativeControl = nil; interactionEpoch += 1; access = .manual
        return try await stop()
    }
    public func usbContinuousControlEndpoint() throws -> USBContinuousControlEndpoint? {
        guard !connectionInProgress, nativeControl == nil, !nativeControlPending,
              ["ready", "moving", "stopping"].contains(phase), let uvc else { return nil }
        let sessionID = capture.store.stats().sessionID
        let lifecycle = lifecycleGeneration
        guard !sessionID.isEmpty, capabilities?.writable == true,
              capabilities?.minimum != nil, capabilities?.maximum != nil else { return nil }
        let binding = ContinuousGimbalBinding(sessionID: sessionID, generation: UInt64(lifecycleGeneration))
        if let endpoint = usbEndpoint, endpoint.binding == binding { return endpoint }
        guard phase == "ready" else { return nil }
        usbEndpoint?.connectionPermit.invalidate()
        let connectionPermit = OperationPermit()
        let transport = USBContinuousGimbalTransport(binding: binding,
            onStart: { [weak self] lease, permit in
                guard let self else { throw CancellationError() }
                try await self.claimUSBContinuous(lease, permit: permit)
            },
            onContinue: { [weak self] lease in
                guard let self else { throw CancellationError() }
                try await self.checkUSBContinuous(lease)
            },
            read: { [weak self] lease in
                guard lease.binding == binding else { throw ContinuousGimbalError.staleLease }
                guard let self else { throw CancellationError() }
                let started = ProcessInfo.processInfo.systemUptime
                let feedback = try await self.readUVCStatus(uvc, expectedGeneration: lifecycle)
                await self.recordUSBContinuousFeedback(lease, capabilities: feedback)
                return USBContinuousGimbalFeedback(capabilities: feedback, observedAt: started)
            },
            write: { position, lease, deadline, permit in
                guard lease.binding == binding else { throw ContinuousGimbalError.staleLease }
                try await uvc.setFast(position, validUntil: deadline, permit: permit, connectionPermit: connectionPermit)
            },
            onStop: { [weak self] lease, result in await self?.finishedUSBContinuous(lease, result: result) })
        let endpoint = USBContinuousControlEndpoint(scheduler: ContinuousGimbalScheduler(inputTransport: transport),
            binding: binding, transport: transport, connectionPermit: connectionPermit)
        usbEndpoint = endpoint
        return endpoint
    }

    /// Stops previous motion but leaves no owner until the exact ticket is
    /// consumed by the first transport send. Release during preparation is safe.
    public func prepareUSBContinuousControl(binding: ContinuousGimbalBinding) async throws -> UUID {
        guard usbEndpoint?.binding == binding, binding.generation == UInt64(lifecycleGeneration),
              !connectionInProgress, nativeControl == nil, !nativeControlPending else {
            throw BridgeFailure("session_changed", "USB 連線已改變")
        }
        let lifecycle = lifecycleGeneration, expectedGeneration = motionGeneration + 1
        let stopped = try await stop()
        try Task.checkCancellation()
        guard lifecycle == lifecycleGeneration, expectedGeneration == motionGeneration,
              usbEndpoint?.binding == binding, phase == "ready", stopped.verified, !rollNeedsHold,
              !connectionInProgress, nativeControl == nil, !nativeControlPending else {
            throw BridgeFailure("control_cancelled", "控制準備已取消，請重新按住操作")
        }
        let ticket = UUID()
        access = .manual; interactionEpoch += 1
        usbAuthorization = (ticket, motionGeneration, interactionEpoch)
        return ticket
    }

    private func claimUSBContinuous(_ lease: ContinuousGimbalLease, permit: OperationPermit) throws {
        try permit.perform {}
        guard !rollNeedsHold else { throw BridgeFailure("roll_stop_required", "請先確認 Roll 已停止，再開始連續視角控制") }
        guard let authorization = usbAuthorization, authorization.id == lease.authorizationID,
              authorization.epoch == motionGeneration, authorization.interaction == interactionEpoch,
              usbEndpoint?.binding == lease.binding,
              lease.binding.generation == UInt64(lifecycleGeneration),
              motionID == nil, phase == "ready", !connectionInProgress,
              nativeControl == nil, !nativeControlPending else { throw BridgeFailure("control_cancelled", "控制授權已失效") }
        guard try capture.store.latest(maxAge: 1).info.sessionID == lease.binding.sessionID else {
            throw BridgeFailure("session_changed", "相機影像連線已改變")
        }
        usbAuthorization = nil; motionGeneration += 1; interactionEpoch += 1
        motionID = lease.id; usbActiveLease = lease; activeMotionPermit = permit
        phase = "moving"; access = .manual; usbLastStop = nil
        log("move", "開始 USB 連續視角控制", presentationKey: "control.started")
    }

    private func checkUSBContinuous(_ lease: ContinuousGimbalLease) throws {
        guard usbActiveLease == lease, motionID == lease.id, phase == "moving",
              lease.binding.generation == UInt64(lifecycleGeneration),
              try capture.store.latest(maxAge: 1).info.sessionID == lease.binding.sessionID else {
            throw BridgeFailure("control_cancelled", "連續控制已取消或影像已過期")
        }
    }

    private func recordUSBContinuousFeedback(_ lease: ContinuousGimbalLease, capabilities: UVCCapabilities) {
        guard usbActiveLease == lease, lease.binding.generation == UInt64(lifecycleGeneration) else { return }
        self.capabilities = capabilities
    }

    private func finishedUSBContinuous(_ lease: ContinuousGimbalLease, result: MotionResult) {
        guard usbActiveLease == lease else { return }
        usbLastStop = (lease, result); usbActiveLease = nil
        activeMotionPermit?.invalidate(); activeMotionPermit = nil
        motionID = nil; usbAuthorization = nil; interactionEpoch += 1
        lastMotionEnded = ProcessInfo.processInfo.systemUptime
        if lease.binding.generation == UInt64(lifecycleGeneration), !connectionInProgress {
            phase = result.verified ? "ready" : "error"
            if !result.verified { lastError = "USB 停止未確認"; access = .manual }
        }
        log("stop", result.verified ? "USB 連續控制已結束，保持回讀穩定" : "USB 連續控制停止未確認", error: !result.verified,
            presentationKey: result.verified ? "control.stopped" : "control.stop_failed")
    }
    public func connect(id: String, resolution: Int = 1080, mode: CaptureMode? = nil, pixelFormat: CapturePixelFormat = .automatic,
                        outputPolicy: CaptureOutputPolicy = .bgra,
                        validationStartupTimeout: TimeInterval? = nil, validationSkipUVC: Bool? = nil) async throws {
        guard validationSkipUVC == nil || validationEnabled else {
            throw BridgeFailure("validation_disabled", "略過 UVC 控制只供開發驗證")
        }
        let startupTimeout = validationStartupTimeout ?? 4
        guard validationStartupTimeout == nil || validationEnabled,
              startupTimeout.isFinite, (1...30).contains(startupTimeout) else {
            throw BridgeFailure("invalid_startup_timeout", "較長啟動等待只供開發驗證，須為 1–30 秒")
        }
        guard !connectionInProgress else { throw BridgeFailure("connection_busy", "正在處理另一個連接請求") }
        connectionInProgress = true
        nativeControl?.writePermit?.invalidate()
        defer { connectionInProgress = false }
        let captureMode = mode ?? (resolution == 2160 ? CaptureMode(width: 3840, height: 2160, frameRate: 30) : .default1080p30)
        guard (mode != nil || [1080, 2160].contains(resolution)), CaptureMode.available(deviceID: id).contains(captureMode) else { throw BridgeFailure("invalid_format", "請選擇相機實際列出的影像格式") }
        if pixelFormat != .automatic {
            guard CaptureMode.availableInputFormats(deviceID: id)[captureMode.id]?.contains(pixelFormat) == true else {
                throw BridgeFailure("input_format_unavailable", "相機未宣告支援 \(captureMode.title) · \(pixelFormat.title)，請選擇其他輸入格式")
            }
        }
        guard let device = CaptureEngine.devices().first(where: { $0.id == id }) else { throw BridgeFailure("device_missing", "找不到選定的 Pocket 3") }
        lifecycleGeneration += 1; let generation = lifecycleGeneration
        _ = try? await stop()
        guard generation == lifecycleGeneration else { throw CancellationError() }
        usbEndpoint?.connectionPermit.invalidate(); usbEndpoint = nil; uvc?.invalidate()
        resetZoomHoldForConnectionChange()
        resetRollHoldForConnectionChange()
        phase = "connecting"; lastError = nil; lastCaptureAttempt = nil
        guard outputPolicy.isUserSelectable || validationEnabled else {
            throw BridgeFailure("invalid_output_policy", "只可選擇 BGRA preview、H.264 或 HEVC host output")
        }
        selected = device; requestedMode = captureMode; requestedPixelFormat = pixelFormat; requestedOutputPolicy = outputPolicy
        // The previous control's Stop cleanup has finished above. Do not create
        // a replacement UVC connection in capture-only isolation: its startup
        // status call and later status polls must not open the control interface.
        uvcControlDisabledForCapture = validationSkipUVC ?? false
        uvc = uvcControlDisabledForCapture ? nil : device.location.map(UVCConnection.init(location:))
        capabilities = nil
        if uvcControlDisabledForCapture { stopValidated = false }
        var captureStarted = false
        do {
            try await capture.start(deviceID: id, mode: captureMode, pixelFormat: pixelFormat, outputPolicy: outputPolicy)
            captureStarted = true
            try Task.checkCancellation()
            guard generation == lifecycleGeneration else { throw CancellationError() }
            if let uvc { capabilities = try? await uvc.status() }
            loadValidationForCurrentDevice()
            let deadline = ProcessInfo.processInfo.systemUptime + startupTimeout
            var firstMatchingFrame: FramePacket?
            repeat {
                guard generation == lifecycleGeneration else { throw CancellationError() }
                if let candidate = try? capture.store.latest(),
                   candidate.info.width == captureMode.width, candidate.info.height == captureMode.height,
                   pixelFormat == .automatic || candidate.info.inputPixelFormat == pixelFormat {
                    firstMatchingFrame = candidate
                    break
                }
                try await Task.sleep(for: .milliseconds(80))
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard generation == lifecycleGeneration else { throw CancellationError() }
            // Port format metadata can settle after the first callback during
            // a format transition. Wait for a matching fresh frame within the
            // same bounded startup window, then preserve the exact failure.
            let first = try firstMatchingFrame ?? capture.store.latest()
            guard first.info.width == captureMode.width && first.info.height == captureMode.height else { throw BridgeFailure("format_changed", "收到的影格尺寸與要求不符，請選擇其他格式") }
            guard pixelFormat == .automatic || first.info.inputPixelFormat == pixelFormat else { throw BridgeFailure("input_format_changed", "收到的相機輸入格式與要求的 \(pixelFormat.title) 不符") }
            phase = "ready"; log("connect", "已連接 \(device.name)，\(captureMode.title) · \(first.info.inputPixelFormat?.title ?? first.info.inputPixelFormatFourCC ?? pixelFormat.title)", presentationKey: "camera.connected")
        } catch {
            if generation == lifecycleGeneration {
                // Cleanup clears buffers and live counters; retain only the
                // failed attempt's scalar diagnostics for doctor/status.
                if captureStarted, (error as? BridgeFailure)?.code == "no_frame" {
                    capture.store.recordCallbackTimeout()
                }
                lastCaptureAttempt = captureStarted ? capture.store.sampleDiagnostics()
                    : capture.lastFailedStartDiagnostics() ?? CaptureSampleDiagnostics()
                await capture.stop(); phase = "error"; lastError = error.localizedDescription; log("connect", error.localizedDescription, error: true, presentationKey: "camera.connection_failed")
            }
            throw error
        }
    }
    public func pause() async {
        nativeControl?.writePermit?.invalidate()
        lifecycleGeneration += 1; let generation = lifecycleGeneration; access = .manual
        _ = try? await stop()
        guard generation == lifecycleGeneration else { return }
        usbEndpoint?.connectionPermit.invalidate(); usbEndpoint = nil; uvc?.invalidate()
        resetZoomHoldForConnectionChange()
        resetRollHoldForConnectionChange()
        await capture.stop()
        guard generation == lifecycleGeneration else { return }
        phase = "paused"; capabilities = nil; uvc = nil; stopValidated = false
        log("pause", "隱私暫停：影音已釋放，AI 存取已關閉", presentationKey: "camera.paused")
    }
    public func suspend() async {
        let expectedGeneration = lifecycleGeneration + 1
        await pause()
        guard lifecycleGeneration == expectedGeneration, phase == "paused" else { return }
        phase = "suspended"; log("sleep", "主機休眠；喚醒後請重新連接", presentationKey: "camera.suspended")
    }
    public func status() async -> ServiceStatus {
        var devices = statusDevices()
        if let selected, !devices.contains(where: { $0.id == selected.id }), ["ready", "moving", "stopping", "validating", "soaking"].contains(phase) {
            await invalidateAttachment()
            devices = statusDevices()
        }
        // A periodic status refresh must not supersede the serialized UVC
        // feedback reads owned by an active motion/trajectory operation. It
        // returns the last verified capability snapshot while motion runs;
        // stop/completion performs the next authoritative read.
        if let uvc, usbActiveLease == nil, motionID == nil, ["ready", "moving", "validating", "soaking"].contains(phase) {
            let generation = lifecycleGeneration
            do {
                let current = try await readUVCStatus(uvc, expectedGeneration: generation)
                if generation == lifecycleGeneration { capabilities = current }
            }
            catch { /* readUVCStatus records or invalidates the failure */ }
            devices = statusDevices()
        }
        let nativeSnapshot: NativeControlStatus?
        if let reservation = nativeControl {
            let snapshot = await reservation.readStatus()
            nativeSnapshot = nativeControl?.binding == reservation.binding ? snapshot : .connectionChanged
        } else { nativeSnapshot = nil }
        let captureStats = capture.store.stats()
        let reportedPhase = phase == "ready" && (captureStats.age ?? .infinity) > 1 ? "stalled" : phase
        var result = ServiceStatus(phase: reportedPhase, devices: devices, selected: selected, access: access, permission: CaptureEngine.permission(), capture: captureStats, gimbal: capabilities, motionActive: motionID != nil, stopValidated: stopValidated, lastError: lastError, activities: activities, requestedMode: requestedMode, requestedPixelFormat: requestedPixelFormat, requestedOutputPolicy: requestedOutputPolicy, lastCaptureAttempt: lastCaptureAttempt, power: selected?.location.map { USBPowerMonitor.read(location: $0) })
        result.uvcControlDisabledForCapture = uvcControlDisabledForCapture
        result.rollStopValidated = rollStopValidated
        result.controlTransport = uvcControlDisabledForCapture ? "capture_only" : "usb_position"
        if usbActiveLease != nil { result.controlTransport = "usb_continuous_position" }
        if uvcControlDisabledForCapture { result.stopStrategy = "uvc_control_disabled_for_capture" }
        result.controlReadIssueCode = controlReadIssueCode
        result.lastControlReadFailureAt = lastControlReadFailureAt
        if controlReadIssueCode != nil, let transport = result.controlTransport, !transport.contains("degraded") {
            result.controlTransport = transport + "_degraded"
        }
        result.nativeControl = nativeSnapshot
        result.capabilities = Pocket3CapabilityGraph.from(
            phase: reportedPhase, capture: captureStats,
            requestedMode: requestedMode, requestedPixelFormat: requestedPixelFormat,
            requestedOutputPolicy: requestedOutputPolicy, nativeControl: nativeSnapshot,
            nativeSession: nativeSnapshot == nil ? nativeSessionCapability : nil,
            bodyRecordingFormats: bodyRecordingCapabilities)
        if nativeControl != nil {
            result.controlTransport = "native_joystick"
            result.stopStrategy = "native_joystick_neutral_and_telemetry"
            result.motionActive = result.motionActive || nativeSnapshot?.motionActive == true
            result.stopValidated = false
        }
        return result
    }

    private func statusDevices() -> [CameraDevice] {
        statusSeam?.devices() ?? CaptureEngine.devices()
    }

    private func captureIsFreshForSelectedDevice(_ deviceID: String) -> Bool {
        if let statusSeam { return statusSeam.captureIsFreshForSelectedDevice(deviceID) }
        let stats = capture.store.stats()
        guard stats.frame?.deviceID == deviceID, let age = stats.age,
              age.isFinite, age >= 0, age <= 1 else { return false }
        return stats.frame?.sessionID == stats.sessionID
    }

    private func controlFailureCode(_ error: Error) -> String {
        (error as? BridgeFailure)?.code ?? "uvc_status_read_failed"
    }

    private func isControlIdentityFailure(_ error: Error) -> Bool {
        guard let code = (error as? BridgeFailure)?.code else { return false }
        return ["uvc_attachment_changed", "hardware_identity", "uvc_connection_closed", "uvc_device_missing"].contains(code)
    }

    private func clearControlReadIssue() {
        controlReadIssueCode = nil
        lastControlReadFailureAt = nil
        controlReadNeedsValidation = false
    }

    private func recordControlReadFailure(_ error: Error) {
        let code = controlFailureCode(error)
        if controlReadIssueCode != code {
            log("uvc_status", "USB 控制讀取暫時失敗：\(code)；保留取像並要求下次寫入重新驗證", error: true,
                presentationKey: "camera.control_read_degraded")
        }
        controlReadIssueCode = code
        lastControlReadFailureAt = Date()
        controlReadNeedsValidation = true
    }

    /// Reads capabilities and treats the UVC attachment as valid only after
    /// the read succeeds. A generic read failure may degrade control while a
    /// fresh frame proves the selected capture is still alive; identity or
    /// actual-device failures retire the entire attachment.
    private func readUVCStatus(
        _ connection: any CameraControlConnection,
        expectedGeneration: Int
    ) async throws -> UVCCapabilities {
        try Task.checkCancellation()
        controlReadSequence &+= 1
        let sequence = controlReadSequence
        do {
            let current = try await connection.status()
            try Task.checkCancellation()
            guard expectedGeneration == lifecycleGeneration, self.uvc === connection else {
                throw BridgeFailure("session_changed", "USB 控制讀取期間相機連線已改變")
            }
            guard sequence == controlReadSequence else {
                throw BridgeFailure("control_read_superseded", "較新的 USB 控制讀取已取代本次讀取")
            }
            if let selected {
                let available = statusDevices()
                guard available.contains(where: { $0.id == selected.id }) else {
                    await invalidateAttachment()
                    throw BridgeFailure("device_missing", "選定的 Pocket 3 已離線")
                }
            }
            capabilities = current
            clearControlReadIssue()
            return current
        } catch {
            if error is CancellationError { throw error }
            guard expectedGeneration == lifecycleGeneration, self.uvc === connection else { throw error }
            guard sequence == controlReadSequence else {
                throw BridgeFailure("control_read_superseded", "較新的 USB 控制讀取已取代本次讀取")
            }
            let available = statusDevices()
            let selectedPresent = selected.map { device in available.contains(where: { $0.id == device.id }) } ?? false
            let retainCapture = selectedPresent && selected.map { captureIsFreshForSelectedDevice($0.id) } == true
            if isControlIdentityFailure(error) || !selectedPresent || !retainCapture {
                await invalidateAttachment()
            } else {
                recordControlReadFailure(error)
            }
            throw error
        }
    }

    /// After a degraded status read, do not allow an automation SET to reuse
    /// stale capabilities. A successful status read clears the degraded state;
    /// a repeated generic failure still blocks the write without guessing that
    /// the device was unplugged.
    private func validateControlAttachmentBeforeWrite(
        _ connection: any CameraControlConnection,
        expectedGeneration: Int
    ) async throws {
        guard controlReadNeedsValidation else { return }
        _ = try await readUVCStatus(connection, expectedGeneration: expectedGeneration)
    }

    private func invalidateAttachment() async {
        nativeControl?.writePermit?.invalidate()
        resetZoomHoldForConnectionChange()
        resetRollHoldForConnectionChange()
        validationTask?.cancel(); streamValidationTask?.cancel(); activeMotionPermit?.invalidate(); activeMotionPermit = nil; interactionEpoch += 1
        lifecycleGeneration += 1; motionGeneration += 1; motionID = nil; access = .manual
        usbEndpoint?.connectionPermit.invalidate()
        uvc?.invalidate()
        usbAuthorization = nil; usbActiveLease = nil; usbEndpoint = nil
        // No hold write: this port may already contain a different attachment.
        uvc = nil; capabilities = nil; stopTask = nil; stopValidated = false; phase = "disconnected"
        clearControlReadIssue()
        await capture.stop()
        log("disconnect", "Pocket 3 已離線或重新插入，先前操作已失效", error: true, presentationKey: "camera.disconnected")
        if let onAttachmentInvalidated = statusSeam?.onAttachmentInvalidated {
            await onAttachmentInvalidated()
        }
    }
    private func requireObservation(_ origin: RequestOrigin) throws {
        if origin == .automation && access == .manual { throw BridgeFailure("access_denied", "請在 App 開放 AI 取像權限") }
        guard phase == "ready" else { throw BridgeFailure("camera_not_ready", phase == "paused" ? "相機已隱私暫停" : "相機目前尚未就緒", retryable: phase == "connecting") }
    }
    var observationMovementIsAllowed: Bool { access == .control && stopValidated }
    public func interactionStamp(origin: RequestOrigin) throws -> InteractionStamp {
        try requireObservation(origin)
        return InteractionStamp(sessionID: capture.store.stats().sessionID, epoch: interactionEpoch)
    }
    public func validateInteraction(_ stamp: InteractionStamp, origin: RequestOrigin) throws {
        try requireObservation(origin)
        guard stamp.epoch == interactionEpoch && stamp.sessionID == capture.store.stats().sessionID else {
            throw BridgeFailure("interaction_changed", "控制權、連線或使用者操作已改變，本次 AI 任務已失效")
        }
    }
    public func frame(origin: RequestOrigin = .manual, after: Double = 0) async throws -> FramePacket {
        try requireObservation(origin)
        let generation = lifecycleGeneration
        let requiredAfter = max(after, lastMotionEnded)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            try Task.checkCancellation(); try requireObservation(origin)
            guard generation == lifecycleGeneration else { throw BridgeFailure("session_changed", "相機連接已改變，請重新取像") }
            if let frame = try? capture.store.latest(maxAge: 1, after: requiredAfter) { return frame }
            try await Task.sleep(for: .milliseconds(50))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw BridgeFailure("stale_frame", "未取得新影格，請重新連接相機", retryable: true)
    }
    public func compareFreshFrames(origin: RequestOrigin = .automation) async throws -> FrameComparisonObservation {
        let stamp = try interactionStamp(origin: origin)
        let first = try await frame(origin: origin)
        let second = try await frame(origin: origin, after: first.info.receivedUptime)
        try validateInteraction(stamp, origin: origin)
        guard first.info.sessionID == second.info.sessionID else { throw BridgeFailure("session_changed", "影格比較期間相機連線已改變") }
        let metrics = try await Task.detached(priority: .userInitiated) {
            try FrameComparison.compare(first.pixelBuffer, second.pixelBuffer)
        }.value
        try validateInteraction(stamp, origin: origin)
        return FrameComparisonObservation(sessionID: first.info.sessionID, firstFrameID: first.info.id,
            secondFrameID: second.info.id, intervalSeconds: second.info.receivedUptime - first.info.receivedUptime, metrics: metrics)
    }
    public func snapshot(origin: RequestOrigin = .manual, maxDimension: Int = 1920) async throws -> (FrameInfo, Data) {
        guard (320...3840).contains(maxDimension) else { throw BridgeFailure("invalid_size", "圖片最大邊長須在 320–3840") }
        let frame = try await frame(origin: origin)
        let (info, data) = try await Task.detached(priority: .userInitiated) { try frame.jpegWithInfo(maxDimension: maxDimension) }.value
        try requireObservation(origin)
        guard frame.info.sessionID == capture.store.stats().sessionID else { throw BridgeFailure("session_changed", "取像期間連接已改變") }
        log("capture", "已取得新影格 \(frame.info.width)×\(frame.info.height)", presentationKey: "capture.completed")
        return (info, data)
    }
    public func move(direction: String, origin: RequestOrigin = .manual, interaction: InteractionStamp? = nil) async throws -> MotionResult {
        try await performMotion(direction: direction, origin: origin, interaction: interaction)
    }
    public func point(panDegrees: Double?, tiltDegrees: Double?, origin: RequestOrigin = .manual, expectedSessionID: String? = nil) async throws -> MotionResult {
        if let expectedSessionID, expectedSessionID != capture.store.stats().sessionID { throw BridgeFailure("session_changed", "相機連線已改變，請重新調整視角") }
        return try await performMotion(direction: "absolute", panDegrees: panDegrees, tiltDegrees: tiltDegrees, origin: origin)
    }
    public func zoomCapabilities(expectedSessionID: String? = nil) async throws -> USBZoomCapabilities {
        guard !connectionInProgress, ["ready", "moving"].contains(phase), let uvc else {
            throw BridgeFailure("camera_not_ready", "請先連接相機再讀取 USB 縮放能力")
        }
        let lifecycle = lifecycleGeneration, sessionID = capture.store.stats().sessionID
        if let expectedSessionID, expectedSessionID != sessionID { throw BridgeFailure("session_changed", "相機連線已改變") }
        let result = try await uvc.zoomStatus()
        guard lifecycle == lifecycleGeneration, capture.store.stats().sessionID == sessionID else {
            throw BridgeFailure("session_changed", "讀取縮放能力期間相機連線已改變")
        }
        return result
    }

    public func zoom(rawValue: Int, expectedSessionID: String, origin: RequestOrigin = .manual) async throws -> USBZoomResult {
        guard !zoomNeedsHold else { throw BridgeFailure("zoom_stop_required", "請先確認先前縮放已停止，再調整縮放") }
        try requireObservation(origin)
        guard !rollNeedsHold else { throw BridgeFailure("roll_stop_required", "請先確認 Roll 已停止，再調整縮放") }
        guard origin == .manual || access == .control else { throw BridgeFailure("zoom_denied", "請在 App 開放 AI 控制權限") }
        guard !expectedSessionID.isEmpty, try capture.store.latest(maxAge: 1).info.sessionID == expectedSessionID else {
            throw BridgeFailure("session_changed", "相機連線已改變，請重新調整縮放")
        }
        guard !connectionInProgress, motionID == nil, nativeControl == nil, !nativeControlPending, let uvc else {
            throw BridgeFailure("motion_busy", "請先結束其他相機控制再調整縮放")
        }
        if origin == .manual { interactionEpoch += 1; access = .manual }
        let lifecycle = lifecycleGeneration, epoch = interactionEpoch
        if controlReadNeedsValidation {
            _ = try await readUVCStatus(uvc, expectedGeneration: lifecycle)
        }
        let before = try await uvc.zoomStatus()
        try USBZoomPolicy.validate(rawValue, capabilities: before)
        try Task.checkCancellation()
        guard !zoomNeedsHold else { throw BridgeFailure("zoom_stop_required", "請先確認先前縮放已停止，再調整縮放") }
        guard lifecycle == lifecycleGeneration, epoch == interactionEpoch, motionID == nil, phase == "ready",
              !connectionInProgress, nativeControl == nil, !nativeControlPending,
              try capture.store.latest(maxAge: 1).info.sessionID == expectedSessionID,
              origin == .manual || access == .control else { throw BridgeFailure("control_cancelled", "縮放操作已取消") }
        motionGeneration += 1; let generation = motionGeneration
        let id = UUID(), permit = OperationPermit(), connectionPermit = usbEndpoint?.connectionPermit
        motionID = id; activeMotionPermit = permit; phase = "moving"
        defer {
            permit.invalidate()
            if generation == motionGeneration, lifecycle == lifecycleGeneration, motionID == id {
                activeMotionPermit = nil; motionID = nil; phase = "ready"
                lastMotionEnded = ProcessInfo.processInfo.systemUptime
            }
        }
        do {
            var verifier = try USBZoomReadbackVerifier(target: rawValue, capabilities: before)
            zoomNeedsHold = true; zoomHoldRevision &+= 1; zoomStopWork = nil
            try await validateControlAttachmentBeforeWrite(uvc, expectedGeneration: lifecycle)
            try await uvc.setZoom(rawValue: rawValue, validUntil: ProcessInfo.processInfo.systemUptime + 0.25,
                                  permit: permit, connectionPermit: connectionPermit)
            var observed = before
            // Pocket 3 slews its zoom value: a 100→200 request was still at
            // 164 after 640 ms, then reached 200 without another SET. Allow
            // bounded read-only settling; never resend to "fix" that delay.
            let settlingSeconds = min(6, max(2, Double(abs(rawValue - before.current)) / 75 + 1))
            let deadline = ProcessInfo.processInfo.systemUptime + settlingSeconds
            while ProcessInfo.processInfo.systemUptime <= deadline {
                try Task.checkCancellation()
                guard generation == motionGeneration, lifecycle == lifecycleGeneration, motionID == id,
                      capture.store.stats().sessionID == expectedSessionID else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(80))
                observed = try await uvc.zoomStatus()
                try Task.checkCancellation()
                guard generation == motionGeneration, lifecycle == lifecycleGeneration, motionID == id,
                      capture.store.stats().sessionID == expectedSessionID else { throw CancellationError() }
                if ProcessInfo.processInfo.systemUptime > deadline { break }
                if try verifier.observe(observed, at: ProcessInfo.processInfo.systemUptime) {
                    zoomNeedsHold = false
                    lastError = nil; log("zoom", "縮放讀回已穩定", presentationKey: "zoom.completed")
                    return USBZoomResult(target: rawValue, observed: observed.current, accepted: true,
                        completed: true, verified: true, verification: "stable_uvc_zoom_readback_with_advertised_tolerance", capabilities: observed,
                        message: "縮放讀回已在裝置步進容差內穩定；原始值尚未校準為倍率",
                        toleranceRaw: verifier.toleranceRaw, sampleCount: verifier.sampleCount,
                        stableDurationSeconds: verifier.stableDurationSeconds)
                }
            }
            lastError = "USB 縮放回讀未確認"; log("zoom", lastError!, error: true, presentationKey: "zoom.failed")
            let unconfirmed = USBZoomResult(target: rawValue, observed: observed.current, accepted: true,
                completed: false, verified: false, verification: "uvc_zoom_readback_unconfirmed", capabilities: observed,
                message: "縮放請求已送出，但回讀未確認，請勿自動重送",
                toleranceRaw: verifier.toleranceRaw, sampleCount: verifier.sampleCount,
                stableDurationSeconds: verifier.stableDurationSeconds)
            // Reaching the readback deadline is not proof the device stopped.
            // Preserve the failed zoom snapshot, then hold independently before
            // returning. A successful hold can never turn this zoom into success.
            await stopCurrentZoom(id: id, generation: generation, lifecycle: lifecycle,
                sessionID: expectedSessionID, connection: uvc, permit: permit)
            return unconfirmed
        } catch {
            // Cancellation of the request only fences future SETs; a submitted
            // zoom can keep slewing in the device. While this exact operation
            // still owns the connection, join the independent global Stop.
            // stop() invalidates/revokes before its first await, and its hold
            // task survives this submitting task's cancellation. A replacement
            // session or newer operation must never receive this cleanup.
            let failure = (error as? BridgeFailure)?.message ?? "USB 縮放操作未完成"
            let owned = await stopCurrentZoom(id: id, generation: generation, lifecycle: lifecycle,
                sessionID: expectedSessionID, connection: uvc, permit: permit)
            if owned, lifecycle == lifecycleGeneration, self.uvc === uvc,
               motionGeneration == generation + 1 {
                lastError = failure
                log("zoom", failure, error: true, presentationKey: "zoom.failed")
            }
            throw error
        }
    }
    @discardableResult
    private func stopCurrentZoom(id: UUID, generation: Int, lifecycle: Int,
                                 sessionID: String, connection: any CameraControlConnection,
                                 permit: OperationPermit) async -> Bool {
        guard generation == motionGeneration, lifecycle == lifecycleGeneration,
              motionID == id, uvc === connection, capture.store.stats().sessionID == sessionID else { return false }
        // A repeated grant may advance interactionEpoch without replacing the
        // operation. Physical cleanup follows its actual motion owner instead.
        permit.invalidate()
        _ = try? await stop()
        return true
    }
    public func rollCapabilities(expectedSessionID: String? = nil) async throws -> USBRollCapabilities {
        try Task.checkCancellation()
        guard !connectionInProgress, ["ready", "moving"].contains(phase), let uvc else {
            throw BridgeFailure("camera_not_ready", "請先連接相機再讀取 USB Roll 能力")
        }
        let lifecycle = lifecycleGeneration, sessionID = capture.store.stats().sessionID
        if let expectedSessionID {
            guard !expectedSessionID.isEmpty, expectedSessionID == sessionID else { throw BridgeFailure("session_changed", "相機連線已改變") }
        }
        let result = try await uvc.rollStatus()
        try Task.checkCancellation()
        guard lifecycle == lifecycleGeneration, self.uvc === uvc, capture.store.stats().sessionID == sessionID else {
            throw BridgeFailure("session_changed", "讀取 Roll 能力期間相機連線已改變")
        }
        return result
    }

    public func roll(rawValue: Int, expectedSessionID: String, origin: RequestOrigin = .manual) async throws -> USBRollResult {
        try Task.checkCancellation()
        try requireObservation(origin)
        try USBRollPolicy.authorize(origin: origin, access: access, rollStopValidated: rollStopValidated)
        guard !rollNeedsHold, !zoomNeedsHold else { throw BridgeFailure("scalar_stop_required", "請先確認先前的 Roll 或縮放已停止") }
        guard !expectedSessionID.isEmpty, try capture.store.latest(maxAge: 1).info.sessionID == expectedSessionID else {
            throw BridgeFailure("session_changed", "相機連線已改變，請重新調整 Roll")
        }
        guard !connectionInProgress, motionID == nil, nativeControl == nil, !nativeControlPending, let uvc else {
            throw BridgeFailure("motion_busy", "請先結束其他相機控制再調整 Roll")
        }
        if origin == .manual { interactionEpoch += 1; access = .manual }
        let lifecycle = lifecycleGeneration, epoch = interactionEpoch
        let readStarted = ProcessInfo.processInfo.systemUptime
        if controlReadNeedsValidation {
            _ = try await readUVCStatus(uvc, expectedGeneration: lifecycle)
        }
        let before = try await uvc.rollStatus()
        try USBRollPolicy.validate(rawValue, capabilities: before)
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime - readStarted <= 0.10,
              lifecycle == lifecycleGeneration, epoch == interactionEpoch, self.uvc === uvc,
              motionID == nil, phase == "ready", !connectionInProgress,
              !rollNeedsHold, !zoomNeedsHold, nativeControl == nil, !nativeControlPending,
              try capture.store.latest(maxAge: 1).info.sessionID == expectedSessionID else {
            throw BridgeFailure("control_cancelled", "Roll 準備期間連線、回讀或控制權已改變")
        }
        try USBRollPolicy.authorize(origin: origin, access: access, rollStopValidated: rollStopValidated)
        motionGeneration += 1; let generation = motionGeneration
        let id = UUID(), permit = OperationPermit(), connectionPermit = usbEndpoint?.connectionPermit
        motionID = id; activeMotionPermit = permit; phase = "moving"
        defer {
            permit.invalidate()
            if generation == motionGeneration, lifecycle == lifecycleGeneration, motionID == id {
                activeMotionPermit = nil; motionID = nil; phase = "ready"
                lastMotionEnded = ProcessInfo.processInfo.systemUptime
            }
        }
        // Mark before any SET is eligible. An error/cancel leaves this pending
        // until independent Stop verifies a hold or the connection is retired.
        rollNeedsHold = true; rollHoldRevision &+= 1; rollStopWork = nil
        do {
            let result = try await USBRollSetOperation.perform(rawValue: rawValue, before: before, permit: permit,
                validate: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.validateRollOperation(id: id, generation: generation, lifecycle: lifecycle,
                        epoch: epoch, sessionID: expectedSessionID, origin: origin)
                }, read: { try await uvc.rollStatus() },
                write: { value, deadline, permit in
                    try await uvc.setRoll(rawValue: value, validUntil: deadline, permit: permit, connectionPermit: connectionPermit)
                })
            try validateRollOperation(id: id, generation: generation, lifecycle: lifecycle,
                epoch: epoch, sessionID: expectedSessionID, origin: origin)
            if result.verified {
                rollNeedsHold = false; lastError = nil
                log("roll", "Roll 原始值 \(rawValue) 已精確穩定回讀；未校準物理角度", presentationKey: "roll.completed")
            } else {
                lastError = result.message; log("roll", result.message, error: true, presentationKey: "roll.failed")
            }
            // Normal target readback deliberately never sets rollStopValidated.
            return result
        } catch {
            if generation == motionGeneration, lifecycle == lifecycleGeneration, motionID == id {
                lastError = (error as? BridgeFailure)?.message ?? "USB Roll 操作未完成"
                log("roll", lastError!, error: true, presentationKey: "roll.failed")
            }
            throw error
        }
    }

    private func validateRollOperation(id: UUID, generation: Int, lifecycle: Int, epoch: Int,
                                       sessionID: String, origin: RequestOrigin) throws {
        try Task.checkCancellation()
        guard generation == motionGeneration, lifecycle == lifecycleGeneration, epoch == interactionEpoch,
              motionID == id, phase == "moving", !connectionInProgress,
              nativeControl == nil, !nativeControlPending,
              try capture.store.latest(maxAge: 1).info.sessionID == sessionID else {
            throw BridgeFailure("control_cancelled", "Roll 操作的連線或控制權已失效")
        }
        try USBRollPolicy.authorize(origin: origin, access: access, rollStopValidated: rollStopValidated)
    }

    public func manualGimbalPreset(flip: Bool) async throws -> MotionResult {
        let lifecycle = lifecycleGeneration, expectedGeneration = motionGeneration + 1
        let stopped = try await stop()
        try Task.checkCancellation()
        guard lifecycle == lifecycleGeneration, expectedGeneration == motionGeneration, stopped.verified,
              !connectionInProgress, let uvc else { throw BridgeFailure("control_cancelled", "視角切換已取消") }
        let fresh = try await readUVCStatus(uvc, expectedGeneration: lifecycle)
        guard lifecycle == lifecycleGeneration, expectedGeneration == motionGeneration else { throw CancellationError() }
        let front = try GimbalNavigationPolicy.home(capabilities: fresh)
        let target: GimbalPosition
        if flip {
            let back = try GimbalNavigationPolicy.back(capabilities: fresh)
            target = fresh.position.distance(to: front) <= fresh.position.distance(to: back) ? back : front
        } else { target = front }
        return try await performMotion(direction: "absolute", panDegrees: Double(target.pan) / 3600,
            tiltDegrees: Double(target.tilt) / 3600, origin: .manual)
    }
    private func performMotion(direction: String, panDegrees: Double? = nil, tiltDegrees: Double? = nil, origin: RequestOrigin, interaction: InteractionStamp? = nil, isHardwareProbe: Bool = false, positionProbe: ValidationPositionProbe? = nil) async throws -> MotionResult {
        guard !zoomNeedsHold else { throw BridgeFailure("zoom_stop_required", "請先確認先前縮放已停止，再調整視角") }
        guard !rollNeedsHold else { throw BridgeFailure("roll_stop_required", "請先確認 Roll 已停止，再調整視角") }
        guard nativeControl == nil, !nativeControlPending else { throw BridgeFailure("native_control_active", "雲台由原生連續控制連線使用，USB 位置指令已暫停") }
        try requireObservation(origin)
        if origin == .manual { interactionEpoch += 1; access = .manual }
        if let interaction { try validateInteraction(interaction, origin: origin) }
        let epoch = interactionEpoch
        if origin == .automation && access != .control { throw BridgeFailure("movement_denied", "請在 App 開放 AI 移動權限") }
        // Direct manual operation uses declared limits, exclusive ownership,
        // cancellation and hold verification below. AI motion keeps its
        // separate local validation gate; it must not disable manual controls.
        guard origin == .manual || stopValidated else { throw BridgeFailure("motion_not_validated", "請先在診斷頁完成 AI 控制與停止驗證") }
        _ = try capture.store.latest(maxAge: 1)
        guard !connectionInProgress, motionID == nil, let uvc else { throw BridgeFailure("motion_busy", "相機控制不可用或另一個動作進行中") }
        let lifecycle = lifecycleGeneration
        let before = try await readUVCStatus(uvc, expectedGeneration: lifecycle)
        let target: GimbalPosition
        if let positionProbe {
            guard isHardwareProbe, validationEnabled, origin == .manual, direction == "absolute" else {
                throw BridgeFailure("validation_disabled", "位置探測只供開發驗證")
            }
            target = try positionProbe.target(from: before)
        }
        else if direction == "absolute" { target = try GimbalNavigationPolicy.absolute(panDegrees: panDegrees, tiltDegrees: tiltDegrees, origin: before.position, capabilities: before) }
        else if ["home", "front", "back"].contains(direction) { target = try GimbalNavigationPolicy.preset(named: direction, capabilities: before) }
        else { target = try MotionPolicy.target(direction: direction, origin: before.position, capabilities: before) }
        // Reserve the action before awaiting any write. Stop increments the generation.
        guard !zoomNeedsHold else { throw BridgeFailure("zoom_stop_required", "請先確認先前縮放已停止，再調整視角") }
        guard nativeControl == nil, !nativeControlPending, motionID == nil, phase == "ready" else { throw BridgeFailure("motion_busy", "另一個動作已先開始") }
        try requireObservation(origin)
        guard lifecycle == lifecycleGeneration, epoch == interactionEpoch, origin == .manual || access == .control else { throw BridgeFailure("access_changed", "連接或使用權已改變，動作沒有送出") }
        motionGeneration += 1; let generation = motionGeneration
        let id = UUID(); motionID = id; phase = "moving"
        let permit = OperationPermit(); activeMotionPermit = permit
        log("move", "調整視角：\(["left":"左","right":"右","up":"上","down":"下","home":"回中","front":"正面","back":"背面","absolute":"指定位置"][direction] ?? direction)", presentationKey: "control.started")
        do {
            if target.distance(to: before.position) > 5 * 3600 {
                let observed = try await approachUSBTarget(target, before: before, uvc: uvc,
                    id: id, generation: generation, lifecycle: lifecycle, permit: permit)
                guard generation == motionGeneration, motionID == id else { throw CancellationError() }
                activeMotionPermit = nil; motionID = nil; phase = "ready"
                lastMotionEnded = ProcessInfo.processInfo.systemUptime; lastError = nil
                log("move", "已到達視角目標，USB 回讀穩定", presentationKey: "control.completed")
                return MotionResult(id: id.uuidString, accepted: true, completed: true, verified: true,
                    verification: "continuous_usb_approach_and_stable_readback", target: target, observed: observed,
                    message: "視角目標已完成")
            }
            try await validateControlAttachmentBeforeWrite(uvc, expectedGeneration: lifecycle)
            try await uvc.set(target, permit: permit)
            var observed = before.position
            var stableCount = 0
            var previous: GimbalPosition?
            for _ in 0..<(target.distance(to: before.position) > Int64(MotionPolicy.maxStep) ? 80 : 35) {
                try Task.checkCancellation()
                guard generation == motionGeneration, motionID == id else { throw BridgeFailure("cancelled", "動作已取消") }
                try await Task.sleep(for: .milliseconds(100))
                observed = try await readUVCStatus(uvc, expectedGeneration: lifecycle).position
                if observed.distance(to: target) <= MotionPolicy.readbackTolerance, let previous, observed.distance(to: previous) <= 360 { stableCount += 1 } else { stableCount = 0 }
                previous = observed
                if stableCount >= 3 {
                    guard generation == motionGeneration else { throw BridgeFailure("cancelled", "動作已取消") }
                    activeMotionPermit = nil; motionID = nil; phase = "ready"; lastMotionEnded = ProcessInfo.processInfo.systemUptime
                    log("move", "動作完成，USB 回讀穩定；未校準物理角度", presentationKey: "control.completed")
                    return MotionResult(id: id.uuidString, accepted: true, completed: true, verified: true, verification: "stable_uvc_readback_with_tolerance", target: target, observed: observed, message: "視角目標已完成；物理角度未校準")
                }
            }
            throw BridgeFailure("motion_timeout", "未能確認到達目標，已請求停止")
        } catch {
            if generation == motionGeneration {
                _ = try? await stop(); lastError = error.localizedDescription
                log("move", error.localizedDescription, error: true, presentationKey: "control.failed")
            }
            throw error
        }
    }
    private func approachUSBTarget(_ target: GimbalPosition, before: UVCCapabilities, uvc: any CameraControlConnection,
        id: UUID, generation: Int, lifecycle: Int, permit: OperationPermit) async throws -> GimbalPosition {
        let started = ProcessInfo.processInfo.systemUptime
        let distance = hypot(Double(Int64(target.pan) - Int64(before.position.pan)),
                             Double(Int64(target.tilt) - Int64(before.position.tilt)))
        // A bounded travel allowance in nominal UVC units, including firmware
        // following lag. Cancellation/Stop remains available throughout.
        let deadline = started + min(80, distance / 18000 + 8)
        var approach = try USBTargetApproach(target: target, capabilities: before, now: started)
        var samples: [(position: GimbalPosition, time: Double)] = []
        var submittedFinalTarget = false
        var lastProgressPosition = before.position
        var lastProgressAt = started
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation(); try permit.perform {}
            guard generation == motionGeneration, motionID == id, lifecycle == lifecycleGeneration else {
                throw BridgeFailure("cancelled", "動作已取消")
            }
            _ = try capture.store.latest(maxAge: 1)
            let readStarted = ProcessInfo.processInfo.systemUptime
            let fresh = try await readUVCStatus(uvc, expectedGeneration: lifecycle)
            let now = ProcessInfo.processInfo.systemUptime
            guard fresh.minimum == before.minimum, fresh.maximum == before.maximum else {
                throw BridgeFailure("usb_capabilities_changed", "USB 控制範圍已改變")
            }
            capabilities = fresh
            if fresh.position.distance(to: lastProgressPosition) >= 360 {
                lastProgressPosition = fresh.position; lastProgressAt = now
            } else if now - lastProgressAt > 3, fresh.position.distance(to: target) > MotionPolicy.readbackTolerance {
                throw BridgeFailure("motion_not_progressing", "相機未繼續移動，已請求保持目前視角")
            }
            if submittedFinalTarget, fresh.position.distance(to: target) <= MotionPolicy.readbackTolerance {
                samples.append((fresh.position, now))
                if samples.count > 5 { samples.removeFirst() }
                if samples.count == 5, now - samples[0].time >= 0.20 {
                    let panSpan = Int64(samples.map(\.position.pan).max()!) - Int64(samples.map(\.position.pan).min()!)
                    let tiltSpan = Int64(samples.map(\.position.tilt).max()!) - Int64(samples.map(\.position.tilt).min()!)
                    if max(panSpan, tiltSpan) <= 360 { return fresh.position }
                }
            } else { samples.removeAll() }
            let next = try approach.advance(observed: fresh.position, observedAt: readStarted, now: now)
                try await validateControlAttachmentBeforeWrite(uvc, expectedGeneration: lifecycle)
                try await uvc.setFast(next, validUntil: min(readStarted + 0.25, now + 0.10), permit: permit, connectionPermit: nil)
            if next == target { submittedFinalTarget = true }
            // One target per slot; a slow operation never creates a catch-up burst.
            try await Task.sleep(for: .seconds(max(0, now + 0.05 - ProcessInfo.processInfo.systemUptime)), tolerance: .zero)
        }
        throw BridgeFailure("motion_timeout", "未能確認到達目標，已請求停止")
    }
    public func stopIfInteractionCurrent(_ stamp: InteractionStamp) async throws -> MotionResult? {
        guard stamp.epoch == interactionEpoch, stamp.sessionID == capture.store.stats().sessionID else { return nil }
        return try await stop()
    }
    /// Fixed, development-only retarget experiment: 600 ms in one direction,
    /// 600 ms reversed, then the independent Stop path. No Wi-Fi or BLE writes.
    private func trajectoryProbe(arguments: JSONValue) async throws -> USBTrajectoryProbeReport {
        guard validationEnabled, let direction = arguments["direction"].string,
              ["left", "right", "up", "down"].contains(direction),
              case .object(let values) = arguments,
              Set(values.keys) == ["direction", "expectedPanRaw", "expectedTiltRaw"] else {
            throw BridgeFailure("invalid_trajectory_probe", "軌跡探測只供開發驗證，須提供方向與預期 USB 原點")
        }
        func raw(_ key: String) throws -> Int32 {
            guard let number = arguments[key].number, number.isFinite, number.rounded() == number,
                  number >= Double(Int32.min), number <= Double(Int32.max) else {
                throw BridgeFailure("invalid_trajectory_probe", "預期 USB 原點須為 Int32 整數")
            }
            return Int32(number)
        }
        let expected = try GimbalPosition(pan: raw("expectedPanRaw"), tilt: raw("expectedTiltRaw"))
        try requireObservation(.manual)
        guard phase == "ready", motionID == nil, nativeControl == nil, !nativeControlPending, let uvc else {
            throw BridgeFailure("motion_busy", "請先結束其他相機操作")
        }
        let lifecycle = lifecycleGeneration, epoch = interactionEpoch
        let sessionID = try capture.store.latest(maxAge: 1).info.sessionID
        let before = try await readUVCStatus(uvc, expectedGeneration: lifecycle)
        guard before.position == expected else { throw BridgeFailure("probe_origin_changed", "USB 原點已改變，沒有送出軌跡") }
        guard lifecycle == lifecycleGeneration, epoch == interactionEpoch, motionID == nil, phase == "ready",
              nativeControl == nil, !nativeControlPending else { throw BridgeFailure("session_changed", "控制狀態已改變") }
        var bounded = before
        if let minimum = before.minimum, let maximum = before.maximum {
            bounded.minimum = GimbalPosition(pan: Int32(max(Int64(minimum.pan), Int64(expected.pan) - 18000)),
                tilt: Int32(max(Int64(minimum.tilt), Int64(expected.tilt) - 18000)))
            bounded.maximum = GimbalPosition(pan: Int32(min(Int64(maximum.pan), Int64(expected.pan) + 18000)),
                tilt: Int32(min(Int64(maximum.tilt), Int64(expected.tilt) + 18000)))
        }
        let started = ProcessInfo.processInfo.systemUptime
        var trajectory = try USBPositionTrajectory(capabilities: bounded, now: started)
        interactionEpoch += 1; access = .manual; motionGeneration += 1
        let generation = motionGeneration
        motionID = UUID(); phase = "moving"
        let permit = OperationPermit(); activeMotionPermit = permit
        var samples: [USBTrajectoryProbeSample] = []
        var failure: String?
        do {
            for tick in 1...24 {
                let deadline = started + Double(tick) * 0.05
                try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)), tolerance: .zero)
                try permit.perform {}
                guard generation == motionGeneration, lifecycle == lifecycleGeneration,
                      try capture.store.latest(maxAge: 1).info.sessionID == sessionID else { throw CancellationError() }
                let fresh = try await readUVCStatus(uvc, expectedGeneration: lifecycle)
                let now = ProcessInfo.processInfo.systemUptime
                guard now - deadline <= 0.025 else { throw BridgeFailure("trajectory_timing", "軌跡排程過期，已取消並請求保持") }
                let reversed = tick > 12
                let sign: Double = reversed ? -1 : 1
                let x: Double = direction == "right" ? sign : direction == "left" ? -sign : 0
                let y: Double = direction == "down" ? sign : direction == "up" ? -sign : 0
                let target = try trajectory.advance(x: x, y: y, speed: 0.5, now: now,
                    observed: fresh.position, observedAt: now)
                let writeStarted = ProcessInfo.processInfo.systemUptime
                try await validateControlAttachmentBeforeWrite(uvc, expectedGeneration: lifecycle)
                try await uvc.setFast(target, validUntil: deadline + 0.025, permit: permit, connectionPermit: nil)
                samples.append(USBTrajectoryProbeSample(elapsed: now - started, target: target, observed: fresh.position,
                    writeSeconds: ProcessInfo.processInfo.systemUptime - writeStarted, reversed: reversed))
            }
        } catch {
            failure = (error as? BridgeFailure)?.code ?? (error is CancellationError ? "cancelled" : "trajectory_failed")
        }
        // Never send cleanup to a replacement lifecycle. An external Stop has
        // already fenced this permit and owns its own independent hold task.
        let held: MotionResult?
        if generation == motionGeneration, lifecycle == lifecycleGeneration {
            do { held = try await stop() }
            catch { held = nil; failure = failure ?? "trajectory_stop_failed" }
        } else { held = nil; failure = failure ?? "cancelled" }
        return USBTrajectoryProbeReport(direction: direction, origin: before.position, samples: samples, failure: failure, stop: held)
    }
    public func stop() async throws -> MotionResult {
        nativeControl?.writePermit?.invalidate()
        if access == .control { access = .observe }
        interactionEpoch += 1
        activeMotionPermit?.invalidate(); activeMotionPermit = nil
        usbAuthorization = nil
        validationTask?.cancel(); streamValidationTask?.cancel()
        motionGeneration += 1; let generation = motionGeneration
        let wasMoving = motionID != nil; motionID = nil
        let requiredZoomHold = zoomNeedsHold ? zoomHoldRevision : nil
        let requiredRollHold = rollNeedsHold ? rollHoldRevision : nil
        let scalarConnection = uvc
        if let lease = usbActiveLease, let endpoint = usbEndpoint, endpoint.binding == lease.binding {
            phase = "stopping"
            let stopped = await endpoint.scheduler.stop(lease)
            let primary: MotionResult
            if let last = usbLastStop, last.lease == lease { primary = last.result }
            else {
                primary = MotionResult(accepted: true, completed: false, verified: false,
                    verification: stopped.failure ?? "usb_stop_unverified", target: nil, observed: nil,
                    message: "USB 連續控制停止未確認")
            }
            let result = await stopPendingScalars(primary, connection: scalarConnection,
                zoomRevision: requiredZoomHold, rollRevision: requiredRollHold)
            finishStop(result, generation: generation, wasMoving: wasMoving)
            return result
        }
        if let nativeControl {
            // A native neutral and a UVC absolute hold use different coordinate
            // systems. Only the current transport may issue the stop command.
            let primary: MotionResult
            do { primary = try await nativeControl.stop() }
            catch {
                primary = MotionResult(accepted: true, completed: false, verified: false,
                    verification: (error as? BridgeFailure)?.code ?? "native_stop_failed", target: nil, observed: nil,
                    message: "原生雲台停止未確認")
            }
            let result = await stopPendingScalars(primary, connection: scalarConnection,
                zoomRevision: requiredZoomHold, rollRevision: requiredRollHold)
            finishStop(result, generation: generation, wasMoving: wasMoving)
            return result
        }
        guard let uvc else {
            let primary = MotionResult(accepted: true, completed: !wasMoving, verified: !wasMoving,
                verification: "no_active_action", target: nil, observed: nil, message: "已取消排程，沒有可用的 USB 控制連接")
            let result = await stopPendingScalars(primary, connection: nil,
                zoomRevision: requiredZoomHold, rollRevision: requiredRollHold)
            finishStop(result, generation: generation, wasMoving: wasMoving)
            return result
        }
        if ["ready", "moving", "stopping", "validating", "soaking"].contains(phase) { phase = "stopping" }
        // Stopping must survive cancellation of the task that requested motion.
        // Join concurrent Stop requests instead of racing two new hold targets.
        let work: Task<MotionResult, Error>
        if let existing = stopTask { work = existing }
        else {
            work = Task.detached(priority: .userInitiated) {
                var held: GimbalPosition?, last: GimbalPosition?
                var panSubmitted = false, panVerified = false
                do {
                    let fresh = try await uvc.status().position
                    held = fresh; last = fresh
                    try await uvc.set(fresh, permit: nil)
                    panSubmitted = true
                } catch {
                    // Attempt pan first even when zoom feedback is unavailable.
                    // Its failure does not suppress an independent zoom hold.
                }
                // Pan's hold SET is already complete before any zoom read.
                // Verification may interleave on the same serialized UVC actor.
                async let zoom = self.stopPendingZoom(connection: uvc, revision: requiredZoomHold)
                async let roll = self.stopPendingRoll(connection: uvc, revision: requiredRollHold)
                if panSubmitted, let target = held, var previous = last {
                    do {
                        var stable = 0
                        for _ in 0..<10 {
                            try await Task.sleep(for: .milliseconds(80))
                            let read = try await uvc.status().position
                            stable = read.distance(to: previous) <= 360 ? stable + 1 : 0
                            previous = read; last = read
                            if stable >= 3 { break }
                        }
                        panVerified = stable >= 3 && previous.distance(to: target) <= 1080
                    } catch { panVerified = false }
                }
                let pan = MotionResult(id: UUID().uuidString, accepted: true, completed: panVerified, verified: panVerified,
                    verification: "hold_current_target_and_stable_uvc_readback", target: held, observed: last,
                    message: panVerified ? "已取消排程並保持目前視角；不是裝置端緊急停止命令" : "雲台停止未確認")
                return USBRollStopResult.combining(USBZoomStopResult.combining(pan, zoom: await zoom), roll: await roll)
            }
            stopTask = work
        }
        do {
            let result = try await work.value
            if generation == motionGeneration {
                stopTask = nil
            }
            finishStop(result, generation: generation, wasMoving: wasMoving)
            return result
        } catch {
            if generation == motionGeneration { stopTask = nil; phase = "error"; access = .manual; lastError = "USB 停止未確認" }
            throw error
        }
    }
    private func resetZoomHoldForConnectionChange() {
        zoomNeedsHold = false; zoomHoldRevision &+= 1; zoomStopWork = nil
    }

    private func finishStop(_ result: MotionResult, generation: Int, wasMoving: Bool) {
        guard generation == motionGeneration else { return }
        if phase == "stopping" { phase = result.verified ? "ready" : "error" }
        lastMotionEnded = ProcessInfo.processInfo.systemUptime
        if !result.verified { access = .manual; lastError = "停止未確認，請在相機上人工確認" }
        if wasMoving {
            log("stop", result.verified ? "保持目前目標，回讀已穩定" : "停止未確認", error: !result.verified,
                presentationKey: result.verified ? "control.stopped" : "control.stop_failed")
        }
    }

    private func stopPendingScalars(_ primary: MotionResult, connection: (any CameraControlConnection)?,
                                    zoomRevision: UInt64?, rollRevision: UInt64?) async -> MotionResult {
        guard let connection else {
            let zoom = zoomRevision.map { _ in USBZoomStopResult(submitted: false, target: nil, observed: nil,
                verified: false, failure: "zoom_connection_changed") }
            let roll = rollRevision.map { _ in USBRollStopResult(submitted: false, target: nil, observed: nil,
                verified: false, failure: "roll_connection_changed") }
            return USBRollStopResult.combining(USBZoomStopResult.combining(primary, zoom: zoom), roll: roll)
        }
        // One failed axis must not suppress another axis's hold attempt.
        async let zoom = stopPendingZoom(connection: connection, revision: zoomRevision)
        async let roll = stopPendingRoll(connection: connection, revision: rollRevision)
        return USBRollStopResult.combining(USBZoomStopResult.combining(primary, zoom: await zoom), roll: await roll)
    }

    private func resetRollHoldForConnectionChange() {
        rollNeedsHold = false; rollHoldRevision &+= 1; rollStopWork = nil; rollStopValidated = false
    }

    private func stopPendingRoll(connection: any CameraControlConnection, revision: UInt64?) async -> USBRollStopResult? {
        guard let revision else { return nil }
        guard uvc === connection, rollHoldRevision == revision else {
            return USBRollStopResult(submitted: false, target: nil, observed: nil,
                verified: false, failure: "roll_connection_changed")
        }
        let task: Task<USBRollStopResult, Never>, workID: UUID
        if let existing = rollStopWork, existing.revision == revision, existing.connection === connection {
            task = existing.task; workID = existing.id
        } else {
            workID = UUID()
            task = Task.detached(priority: .userInitiated) {
                await USBRollStopOperation.perform(read: { try await connection.rollStatus() },
                    write: { value, deadline, permit in
                        try await connection.setRoll(rawValue: value, validUntil: deadline, permit: permit, connectionPermit: nil)
                    })
            }
            rollStopWork = (workID, revision, connection, task)
        }
        let result = await task.value
        guard uvc === connection, rollHoldRevision == revision else {
            return USBRollStopResult(submitted: result.submitted, target: result.target, observed: result.observed,
                verified: false, sampleCount: result.sampleCount, failure: "roll_connection_changed",
                stableDurationSeconds: result.stableDurationSeconds)
        }
        if result.verified { rollNeedsHold = false }
        else if rollStopWork?.id == workID { rollStopWork = nil }
        // A stationary hold is not the required independent moving-stop test.
        return result
    }

    /// Deduplicate independent cleanup for one pending zoom submission. The
    /// retained actor's lifetime fence prevents writes after an App reconnect.
    private func stopPendingZoom(connection: any CameraControlConnection, revision: UInt64?) async -> USBZoomStopResult? {
        guard let revision else { return nil }
        guard uvc === connection, zoomHoldRevision == revision else {
            return USBZoomStopResult(submitted: false, target: nil, observed: nil, verified: false, failure: "zoom_connection_changed")
        }
        let task: Task<USBZoomStopResult, Never>
        let workID: UUID
        if let existing = zoomStopWork, existing.revision == revision, existing.connection === connection {
            task = existing.task; workID = existing.id
        } else {
            workID = UUID()
            task = Task.detached(priority: .userInitiated) {
                await USBZoomStopOperation.perform(read: { try await connection.zoomStatus() },
                    write: { value, deadline, permit in
                        try await connection.setZoom(rawValue: value, validUntil: deadline, permit: permit, connectionPermit: nil)
                    })
            }
            zoomStopWork = (workID, revision, connection, task)
        }
        let result = await task.value
        guard uvc === connection, zoomHoldRevision == revision else {
            return USBZoomStopResult(submitted: result.submitted, target: result.target, observed: result.observed,
                verified: false, sampleCount: result.sampleCount, failure: "zoom_connection_changed",
                toleranceRaw: result.toleranceRaw ?? 0, stableDurationSeconds: result.stableDurationSeconds ?? 0)
        }
        if result.verified { zoomNeedsHold = false }
        else if zoomStopWork?.id == workID {
            // No automatic repeat. A later explicit Stop may make a fresh
            // attempt after a transient read/write failure.
            zoomStopWork = nil
        }
        return result
    }

    public func audioTest(seconds: Double = 3) async throws -> AudioStats {
        try AudioTestPolicy.validateDuration(seconds)
        try requireObservation(.manual)
        guard !audioTestInProgress else { throw BridgeFailure("audio_busy", "已有音訊測試正在執行") }
        audioTestInProgress = true; defer { audioTestInProgress = false }
        let generation = lifecycleGeneration
        let captureToken = capture.currentLifecycle()
        do {
            try await capture.setAudio(enabled: true, sessionToken: captureToken)
            guard generation == lifecycleGeneration else { throw BridgeFailure("session_changed", "音訊測試期間相機連線已改變") }
            try await Task.sleep(for: .seconds(seconds))
            guard generation == lifecycleGeneration else { throw BridgeFailure("session_changed", "音訊測試期間相機連線已改變") }
            let result = capture.store.stats().audio
            try await capture.setAudio(enabled: false, sessionToken: captureToken)
            log("audio", "音訊測試完成：\(result.channels) 聲道，\(Int(result.sampleRate)) Hz；未保存音訊", presentationKey: "audio.completed")
            return result
        } catch {
            // The old input was removed by stop/reconnect. Do not disable an
            // input belonging to a later capture session from this old task.
            if generation == lifecycleGeneration {
                _ = try? await Task.detached { try await self.capture.setAudio(enabled: false, sessionToken: captureToken) }.value
            }
            throw error
        }
    }
    public func handle(_ request: ServiceRequest) async -> ServiceReply {
        do {
            if request.arguments["skipUVC"] != .null {
                guard request.operation == "validation-connect", validationEnabled else {
                    throw BridgeFailure("validation_disabled", "skipUVC 只適用於已啟用開發驗證的 validation-connect")
                }
            }
            switch request.operation {
            case "connect":
                guard case .object(let fields) = request.arguments,
                      Set(fields.keys).isSubset(of: ["deviceID", "modeID", "pixelFormat", "outputPolicy"]) else {
                    throw BridgeFailure("connect_arguments", "Choose a currently connected Pocket 3")
                }
                guard let id = fields["deviceID"]?.string ?? selected?.id ?? CaptureEngine.devices().first?.id,
                      !id.isEmpty else { throw BridgeFailure("connect_arguments", "Choose a currently connected Pocket 3") }
                let mode: CaptureMode
                if let modeID = fields["modeID"]?.string {
                    guard let found = CaptureMode.available(deviceID: id).first(where: { $0.id == modeID }) else {
                        throw BridgeFailure("invalid_format", "Choose a format advertised by the selected Pocket 3")
                    }
                    mode = found
                } else { mode = .default1080p30 }
                let pixelFormat = fields["pixelFormat"]?.string.flatMap(CapturePixelFormat.init(rawValue:)) ?? .automatic
                let outputPolicy = fields["outputPolicy"]?.string.flatMap(CaptureOutputPolicy.init(rawValue:)) ?? .bgra
                guard outputPolicy.isUserSelectable else { throw BridgeFailure("invalid_output_policy", "Choose BGRA preview, H.264 or HEVC host output") }
                try await connect(id: id, mode: mode, pixelFormat: pixelFormat, outputPolicy: outputPolicy)
                return ServiceReply(id: request.id, result: try .encode(await status()))
            case "pause":
                guard request.arguments == .object([:]) else { throw BridgeFailure("pause_arguments", "Pause accepts no arguments") }
                await pause()
                return ServiceReply(id: request.id, result: try .encode(await status()))
            case "validation-stream-start":
                guard validationEnabled else { throw BridgeFailure("validation_disabled", "串流驗證只供開發工作階段使用") }
                let seconds = request.arguments["seconds"].number ?? 1800
                guard seconds.isFinite, seconds.rounded() == seconds, (1...1800).contains(seconds) else { throw BridgeFailure("invalid_duration", "驗證時間須為 1–1800 秒的整數") }
                try beginStreamValidation(seconds: Int(seconds), audio: request.arguments["audio"].bool == true)
                return ServiceReply(id: request.id, result: .object(["started": .bool(true)]))
            case "validation-stream-status":
                guard validationEnabled else { throw BridgeFailure("validation_disabled", "串流驗證只供開發工作階段使用") }
                return ServiceReply(id: request.id, result: .object(["running": .bool(streamValidationTask != nil), "report": try streamValidationReport?.json(includeSamples: request.arguments["fullReport"].bool == true) ?? .null]))
            case "validation-stream-cancel":
                guard validationEnabled else { throw BridgeFailure("validation_disabled", "串流驗證只供開發工作階段使用") }
                streamValidationTask?.cancel()
                return ServiceReply(id: request.id, result: .object(["cancelRequested": .bool(true)]))
            case "validation-connect":
                guard validationEnabled else { throw BridgeFailure("validation_disabled", "此操作只供開發驗證") }
                let skipUVC: Bool?
                if request.arguments["skipUVC"] == .null { skipUVC = nil }
                else if let value = request.arguments["skipUVC"].bool { skipUVC = value }
                else { throw BridgeFailure("invalid_skip_uvc", "skipUVC 須為布林值") }
                let startupTimeout: Double?
                if request.arguments["startupTimeout"] == .null { startupTimeout = nil }
                else if let value = request.arguments["startupTimeout"].number, value.isFinite, (1...30).contains(value) { startupTimeout = value }
                else { throw BridgeFailure("invalid_startup_timeout", "開發驗證啟動等待須為 1–30 秒") }
                let pixelFormat: CapturePixelFormat
                if request.arguments["pixelFormat"] == .null { pixelFormat = .automatic }
                else if let raw = request.arguments["pixelFormat"].string, let value = CapturePixelFormat(rawValue: raw) { pixelFormat = value }
                else { throw BridgeFailure("invalid_input_format", "Input pixel format must be automatic, nv12 or uyvy") }
                let outputPolicy: CaptureOutputPolicy
                if request.arguments["outputPolicy"] == .null { outputPolicy = .bgra }
                else if let raw = request.arguments["outputPolicy"].string, let value = CaptureOutputPolicy(rawValue: raw), value.isUserSelectable { outputPolicy = value }
                else { throw BridgeFailure("invalid_output_policy", "Output policy must be bgra, h264 or hevc") }
                let resolution = request.arguments["resolution"].number ?? 1080
                guard resolution == 1080 || resolution == 2160 else { throw BridgeFailure("invalid_format", "只接受 1080 或 2160") }
                let id = request.arguments["deviceID"].string ?? selected?.id ?? CaptureEngine.devices().first?.id ?? ""
                let mode: CaptureMode?
                if let modeID = request.arguments["modeID"].string {
                    guard let found = CaptureMode.available(deviceID: id).first(where: { $0.id == modeID }) else { throw BridgeFailure("invalid_format", "Unknown capture mode") }
                    mode = found
                } else { mode = nil }
                try await connect(id: id, resolution: Int(resolution), mode: mode, pixelFormat: pixelFormat, outputPolicy: outputPolicy,
                                  validationStartupTimeout: startupTimeout, validationSkipUVC: skipUVC)
                return ServiceReply(id: request.id, result: try .encode(await status()))
            case "validation-pause", "validation-suspend":
                guard validationEnabled else { throw BridgeFailure("validation_disabled", "此操作只供開發驗證") }
                if request.operation == "validation-pause" { await pause() } else { await suspend() }
                return ServiceReply(id: request.id, result: try .encode(await status()))
            case "validation-setup":
                guard validationEnabled, let mode = AccessMode(rawValue: request.arguments["access"].string ?? "") else { throw BridgeFailure("validation_disabled", "此設定只供已啟用的開發驗證工作階段使用") }
                await setAccess(mode)
                return ServiceReply(id: request.id, result: .object(["access": .string(mode.rawValue)]))
            case "validate-start":
                guard validationEnabled else { throw BridgeFailure("validation_disabled", "遠端硬體驗證只供開發工作階段使用") }
                try beginValidation()
                return ServiceReply(id: request.id, result: .object(["started": .bool(true)]))
            case "validation-move":
                guard validationEnabled, let direction = request.arguments["direction"].string,
                      ["left", "right", "up", "down"].contains(direction) else { throw BridgeFailure("validation_disabled", "單步探測只供開發驗證") }
                let result = try await performMotion(direction: direction, origin: .manual, isHardwareProbe: true)
                return ServiceReply(id: request.id, result: try .encode(result))
            case "validation-position-probe":
                guard validationEnabled else { throw BridgeFailure("validation_disabled", "位置探測只供開發驗證") }
                let probe = try ValidationPositionProbe(arguments: request.arguments)
                let result = try await performMotion(direction: "absolute", origin: .manual,
                    isHardwareProbe: true, positionProbe: probe)
                return ServiceReply(id: request.id, result: try .encode(result))
            case "validation-trajectory-probe":
                return ServiceReply(id: request.id, result: try .encode(try await trajectoryProbe(arguments: request.arguments)))
            case "validation-manual-preset":
                guard validationEnabled, let flip = request.arguments["flip"].bool else {
                    throw BridgeFailure("validation_disabled", "此操作只供開發驗證")
                }
                return ServiceReply(id: request.id, result: try .encode(try await manualGimbalPreset(flip: flip)))
            case "validate-status":
                return ServiceReply(id: request.id, result: .object(["running": .bool(validationTask != nil), "error": validationError.map(JSONValue.string) ?? .null, "report": try validationReport.map(JSONValue.encode) ?? .null]))
            case "status", "doctor": return ServiceReply(id: request.id, result: try .encode(await status()))
            case "snapshot":
                let requested = try MCPCameraToolContract.captureDimension(arguments: request.arguments)
                let (info, data) = try await snapshot(origin: .automation, maxDimension: requested)
                return ServiceReply(id: request.id, result: try .encode(info), imageJPEG: data)
            case "compare-frames":
                guard request.arguments == .object([:]) else { throw BridgeFailure("invalid_camera_arguments", "Frame comparison accepts no arguments") }
                return ServiceReply(id: request.id, result: try .encode(try await compareFreshFrames(origin: .automation)))
            case "move":
                let result: MotionResult
                if request.arguments["direction"] != .null {
                    guard request.arguments["direction"].string != nil else { throw BridgeFailure("invalid_target", "Direction must be a string") }
                    guard request.arguments["panDegrees"] == .null && request.arguments["tiltDegrees"] == .null else { throw BridgeFailure("invalid_target", "Choose a direction or absolute angles, not both") }
                    result = try await move(direction: request.arguments["direction"].string ?? "", origin: .automation)
                } else {
                    guard request.arguments["panDegrees"] == .null || request.arguments["panDegrees"].number != nil,
                          request.arguments["tiltDegrees"] == .null || request.arguments["tiltDegrees"].number != nil else { throw BridgeFailure("invalid_target", "Angles must be finite numbers") }
                    result = try await point(panDegrees: request.arguments["panDegrees"].number, tiltDegrees: request.arguments["tiltDegrees"].number, origin: .automation)
                }
                do {
                    let (info, data) = try await snapshot(origin: .automation, maxDimension: 1280)
                    return ServiceReply(id: request.id, result: .object(["action": try .encode(result), "frame": try .encode(info)]), imageJPEG: data)
                } catch {
                    throw BridgeFailure("post_move_frame_failed", "雲台目標回讀已確認，但後續取像失敗；請重新取像，不要重送同一移動。")
                }
            case "zoom-status":
                return ServiceReply(id: request.id, result: try .encode(try await zoomCapabilities(expectedSessionID: request.arguments["expectedSessionID"].string)))
            case "zoom", "validation-zoom":
                if request.operation == "validation-zoom", !validationEnabled { throw BridgeFailure("validation_disabled", "縮放驗證只供開發使用") }
                guard let number = request.arguments["rawValue"].number else { throw BridgeFailure("invalid_zoom_value", "請提供整數 rawValue") }
                let rawValue = try USBZoomPolicy.rawValue(number)
                guard let expected = request.arguments["expectedSessionID"].string, !expected.isEmpty else {
                    throw BridgeFailure("session_required", "請提供相機狀態中的 expectedSessionID")
                }
                return ServiceReply(id: request.id, result: try .encode(try await zoom(rawValue: rawValue, expectedSessionID: expected,
                    origin: request.operation == "validation-zoom" ? .manual : .automation)))
            case "roll-status":
                let arguments = try USBRollPolicy.arguments(request.arguments, requiresValue: false)
                return ServiceReply(id: request.id, result: try .encode(try await rollCapabilities(expectedSessionID: arguments.sessionID)))
            case "roll", "validation-roll":
                if request.operation == "validation-roll", !validationEnabled {
                    throw BridgeFailure("validation_disabled", "Roll 驗證只供開發工作階段使用")
                }
                let arguments = try USBRollPolicy.arguments(request.arguments, requiresValue: true)
                guard let value = arguments.rawValue, let sessionID = arguments.sessionID else {
                    throw BridgeFailure("invalid_roll_arguments", "Roll 需要原始值及相機 session")
                }
                return ServiceReply(id: request.id, result: try .encode(try await roll(rawValue: value,
                    expectedSessionID: sessionID, origin: request.operation == "validation-roll" ? .manual : .automation)))
            case "stop": return ServiceReply(id: request.id, result: try .encode(try await stop()))
            default: throw BridgeFailure("unknown_operation", "不支持此操作")
            }
        } catch let failure as BridgeFailure {
            return ServiceReply(id: request.id, error: failure)
        } catch is CancellationError {
            return ServiceReply(id: request.id, error: BridgeFailure("cancelled", "操作已取消"))
        } catch {
            return ServiceReply(id: request.id, error: BridgeFailure("operation_failed", error.localizedDescription))
        }
    }
    private func beginStreamValidation(seconds: Int, audio: Bool) throws {
        guard streamValidationTask == nil, validationTask == nil, !audioTestInProgress, phase == "ready", motionID == nil else { throw BridgeFailure("validation_busy", "請先連接相機並結束其他操作") }
        var report = try StreamValidationReport(seconds: seconds, audio: audio, initial: capture.store.stats(), frameRate: requestedMode?.frameRate ?? 30)
        interactionEpoch += 1; access = .manual; phase = "soaking"
        let generation = lifecycleGeneration, epoch = interactionEpoch, captureToken = capture.currentLifecycle()
        let initialUptime = ProcessInfo.processInfo.systemUptime
        streamValidationReport = report
        log("stream-validation", "串流驗證中；不保存影像或音訊，可按停止操作取消")
        streamValidationTask = Task {
            do {
                if audio { try await capture.setAudio(enabled: true, sessionToken: captureToken) }
                report.configurationSeconds = ProcessInfo.processInfo.systemUptime - initialUptime
                streamValidationReport = report
                let started = ProcessInfo.processInfo.systemUptime
                repeat {
                    try await Task.sleep(for: .seconds(1))
                    guard generation == lifecycleGeneration && epoch == interactionEpoch else { throw BridgeFailure("session_changed", "串流驗證期間連線或操作狀態已改變") }
                    report.record(capture.store.stats(), elapsed: ProcessInfo.processInfo.systemUptime-started, residentBytes: ProcessMemory.residentBytes())
                    streamValidationReport = report
                } while report.elapsedSeconds < Double(seconds)
                report.outcome = "completed"
            } catch {
                report.outcome = error is CancellationError ? "cancelled" : "interrupted"
                if !(error is CancellationError) { report.failures.append(error.localizedDescription) }
            }
            if audio && generation == lifecycleGeneration {
                do { try await Task.detached { try await self.capture.setAudio(enabled: false, sessionToken: captureToken) }.value }
                catch { report.failures.append("audio_cleanup_not_confirmed") }
            }
            if generation == lifecycleGeneration && phase == "soaking" { phase = "ready" }
            streamValidationReport = report; streamValidationTask = nil
            log("stream-validation", "串流驗證結束：\(report.outcome)，\(Int(ProcessInfo.processInfo.systemUptime-initialUptime)) 秒", error: !report.passed)
            if let json = try? report.json() {
                try? BridgePaths.prepare()
                try? Data(json.pretty.utf8).write(to: BridgePaths.directory.appendingPathComponent("stream-validation.json"), options: .atomic)
            }
        }
    }
    public func startUserValidation() throws { try beginValidation() }
    private func beginValidation() throws {
        guard !zoomNeedsHold else { throw BridgeFailure("zoom_stop_required", "請先確認縮放已停止，再驗證視角控制") }
        guard !rollNeedsHold else { throw BridgeFailure("roll_stop_required", "請先確認 Roll 已停止，再驗證視角控制") }
        guard nativeControl == nil, !nativeControlPending else { throw BridgeFailure("native_control_active", "請先中斷原生控制，再執行 USB 診斷") }
        guard !connectionInProgress, validationTask == nil, motionID == nil, phase == "ready", let selected,
              let uvc = uvc as? UVCConnection else { throw BridgeFailure("validation_busy", "請先連接相機並結束其他操作") }
        interactionEpoch += 1; access = .manual; stopValidated = false; phase = "validating"; motionGeneration += 1
        let generation = motionGeneration, lifecycle = lifecycleGeneration
        let runID = UUID(), permit = OperationPermit()
        motionID = runID; activeMotionPermit = permit; validationRunID = runID
        validationReport = nil; validationError = nil
        log("validation", "正在驗證小幅往返與中途保持；可隨時停止")
        validationTask = Task {
            defer {
                permit.invalidate()
                if activeMotionPermit === permit { activeMotionPermit = nil }
                if validationRunID == runID { validationRunID = nil; validationTask = nil }
            }
            do {
                let report = try await HardwareValidator.run(uvc: uvc, deviceID: selected.id, frames: capture.store, permit: permit)
                guard validationRunID == runID else { return }
                // Preserve this run's partial evidence after an external Stop.
                // Its old task may never restore access or overwrite a new
                // connection's state/cache merely because cleanup completed.
                validationReport = report
                validationError = report.failureCode
                if generation == motionGeneration, lifecycle == lifecycleGeneration, motionID == runID, self.uvc === uvc {
                    let accepted = HardwareValidator.accepts(report)
                    var retained = report; retained.images = [:]
                    let object: JSONValue = .object(["report": try .encode(retained), "minimum": try .encode(capabilities?.minimum), "maximum": try .encode(capabilities?.maximum)])
                    try BridgePaths.prepare()
                    try Data(object.pretty.utf8).write(to: BridgePaths.directory.appendingPathComponent("hardware-validation.json"), options: .atomic)
                    stopValidated = accepted
                    phase = report.cleanup.map { $0.stable ? "ready" : "error" } ?? "ready"
                    motionID = nil; lastMotionEnded = ProcessInfo.processInfo.systemUptime
                    if phase == "error" { lastError = "USB 停止未確認" }
                    log("validation", stopValidated ? "本機小幅控制与停止驗證通過" : "驗證完成，部分條件未通過", error: !stopValidated)
                }
            } catch {
                guard validationRunID == runID else { return }
                validationError = error.localizedDescription
                if generation == motionGeneration, lifecycle == lifecycleGeneration, motionID == runID, self.uvc === uvc {
                    phase = "error"; motionID = nil; lastError = error.localizedDescription
                }
                log("validation", error.localizedDescription, error: true)
            }
        }
    }
    private func loadValidationForCurrentDevice() {
        stopValidated = false
        guard let selected, let capabilities,
              let data = try? Data(contentsOf: BridgePaths.directory.appendingPathComponent("hardware-validation.json")),
              let object = try? JSONDecoder().decode(JSONValue.self, from: data),
              let report = try? object["report"].decode(HardwareValidationReport.self),
              HardwareValidator.accepts(report), report.registryID != nil, report.bootSessionID != nil,
              report.registryID == capabilities.registryID, report.bootSessionID == capabilities.bootSessionID,
              report.deviceID == selected.id, report.osVersion == ProcessInfo.processInfo.operatingSystemVersionString,
              let min = try? object["minimum"].decode(GimbalPosition.self), let max = try? object["maximum"].decode(GimbalPosition.self),
              min == capabilities.minimum, max == capabilities.maximum else { return }
        stopValidated = true
    }
}
