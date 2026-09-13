import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import Pocket3Core
import Pocket3Intelligence
import YunDesign

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    let service = CameraService(validationEnabled: CommandLine.arguments.contains("--hardware-validation"))
    let intelligence = IntelligenceEngine()
    let perception = PerceptionEngine(path: Bundle.main.resourceURL!.appendingPathComponent("Models/yolos-tiny_float32_static.aimodel").path)
    let server = IPCServer()
    let continuousGimbal = ContinuousGimbalGestureController()
    @ObservationIgnored private var focusStorage: CameraFocusModel?
    var focus: CameraFocusModel {
        if let focusStorage { return focusStorage }
        let value = CameraFocusModel(capture: service.capture) { [weak self] text in self?.message = text }
        focusStorage = value
        return value
    }
    @ObservationIgnored private var zoomStorage: CameraZoomModel?
    var zoom: CameraZoomModel {
        if let zoomStorage { return zoomStorage }
        let value = CameraZoomModel(service: service, prepare: { [weak self] in
            guard let self else { throw CancellationError() }
            guard self.isCameraSource else { throw BridgeFailure("file_source_active", "Return to the live camera before adjusting zoom") }
            self.rollStorage?.cancel()
            self.aiTask?.cancel()
            await self.continuousGimbal.stop(reason: .cancelled)
            try Task.checkCancellation()
            await self.intelligence.cancelObservation()
            try Task.checkCancellation()
            await self.service.setAccess(.manual)
            try Task.checkCancellation()
        }, reportError: { [weak self] text in self?.message = text })
        zoomStorage = value
        return value
    }
    @ObservationIgnored private var rollStorage: CameraRollModel?
    var roll: CameraRollModel {
        if let rollStorage { return rollStorage }
        let value = CameraRollModel(service: service, prepare: { [weak self] in
            guard let self else { throw CancellationError() }
            guard self.isCameraSource else { throw BridgeFailure("file_source_active", "Return to the live camera before adjusting roll") }
            self.zoomStorage?.cancel()
            self.aiTask?.cancel()
            await self.continuousGimbal.stop(reason: .cancelled)
            try Task.checkCancellation()
            await self.intelligence.cancelObservation()
            try Task.checkCancellation()
            let stopped = try await self.service.stop()
            guard stopped.verified else { throw BridgeFailure("stop_unverified", "Cannot start roll before the current control stops") }
            try Task.checkCancellation()
            await self.service.setAccess(.manual)
        }, reportError: { [weak self] text in self?.message = text })
        rollStorage = value
        return value
    }
    private(set) var isManualPresetBusy = false
    @ObservationIgnored var bluetoothProbePermit: OperationPermit?
    @ObservationIgnored private var wirelessStorage: WirelessGimbalModel?
    var wireless: WirelessGimbalModel {
        if let wirelessStorage { return wirelessStorage }
        let value = WirelessGimbalModel(service: service, controls: continuousGimbal) { [weak self] in
            guard let self else { throw CancellationError() }
            guard self.isCameraSource else { throw BridgeFailure("file_source_active", "Return to the live camera before wireless control") }
            self.zoomStorage?.cancel(); self.rollStorage?.cancel()
            self.aiTask?.cancel()
            await self.intelligence.cancelObservation()
            await self.service.setAccess(.manual)
            try Task.checkCancellation()
        }
        wirelessStorage = value
        return value
    }
    var status: ServiceStatus?
    /// Last developer-only body validation evidence. It is kept in memory for
    /// Diagnostics and never exposed to normal users or persisted as a
    /// command replay surface.
    var developerBodyValidationResult: NativeBodyValidationResult?
    /// Metadata-only camera media library projection used by developer
    /// Diagnostics. It never stores media bytes, thumbnails or credentials.
    var mediaLibrary = Pocket3MediaLibraryModel()
    /// Last developer-only exposure validation evidence. The body capability
    /// Disclosure shows this only when developer mode is explicitly enabled.
    var developerExposureValidationResult: NativeExposureValidationResult?
    /// Last native tap-AF transport result, retained only for the developer
    /// readback diagnostic. It does not enable the uncalibrated writer.
    var developerNativeTapFocusValidationResult: NativeTapFocusValidationResult?
    /// Compact result of the most recent developer-only USB manual acceptance.
    /// It contains verification counters and session-fence identity only; no
    /// frame pixels or replayable command payloads are retained.
    var developerUSBManualAcceptanceDiagnostics: USBManualAcceptanceDiagnostics?
    var developerUSBManualAcceptanceStage: String?
    var developerUSBManualAcceptanceFailure: String?
    @ObservationIgnored private var powerChargingReducer = Pocket3PowerChargingDiagnosisReducer()
    var powerChargingDiagnosis: Pocket3PowerChargingDiagnosis?
    var modelStatus: IntelligenceStatus?
    var localStatus: LocalModelStatus?
    var selectedEngine = "apple"
    var observationSource: ObservationSourceMode = .camera
    var observationIntent: ObservationIntent = .observe
    var switchingObservationSource = false
    var observationRevision = 0
    @ObservationIgnored private var imageWorkspaceStorage: ImageObservationWorkspace?
    var imageWorkspace: ImageObservationWorkspace {
        if let imageWorkspaceStorage { return imageWorkspaceStorage }
        let workspace = ImageObservationWorkspace(intelligence: intelligence)
        imageWorkspaceStorage = workspace
        return workspace
    }
    var confirmDeleteModel = false
    var perceptionResult: PerceptionResult?
    @ObservationIgnored var layoutBounds: [String: CGRect] = [:]
    var capturePreview: NSImage?
    var iconStyle = UserDefaults.standard.string(forKey: "Pocket3IconStyle") ?? YunIconBadge.fallbackStyle
    var openMainWindow: (() -> Void)?
    @ObservationIgnored var statusItem: StatusItemController?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    private var cameraSelection = CameraSelection()
    var selectedID: String {
        get { cameraSelection.selectedID }
        set { cameraSelection.select(newValue, availableIDs: status?.devices.map(\.id) ?? []) }
    }
    var availableModes: [CaptureMode] = []
    var availableInputFormats: [String: [CapturePixelFormat]] = [:]
    var captureModeID = UserDefaults.standard.string(forKey: "Pocket3CaptureModeID") ?? CaptureMode.default1080p30.id
    var captureMode: CaptureMode? { availableModes.first { $0.id == captureModeID } }
    var capturePixelFormat = CapturePixelFormat(rawValue: UserDefaults.standard.string(forKey: "Pocket3CapturePixelFormat") ?? "") ?? .automatic {
        didSet {
            if !capturingUI { UserDefaults.standard.set(capturePixelFormat.rawValue, forKey: "Pocket3CapturePixelFormat") }
        }
    }
    var captureOutputPolicy = CaptureOutputPolicy(rawValue: UserDefaults.standard.string(forKey: "Pocket3CaptureOutputPolicy") ?? "") ?? .bgra {
        didSet { if !capturingUI { UserDefaults.standard.set(captureOutputPolicy.rawValue, forKey: "Pocket3CaptureOutputPolicy") } }
    }
    var captureOutputPolicyOptions: [YunSelect<CaptureOutputPolicy>.Option] {
        [.init(value: .bgra, title: loc("BGRA preview"), detail: loc("Normal preview path")),
         .init(value: .h264, title: loc("H.264 host output"), detail: loc("Experimental · host encoded")),
         .init(value: .hevc, title: loc("HEVC host output"), detail: loc("Experimental · host encoded"))]
    }
    var capturePixelFormatSupported: Bool {
        captureMode != nil && (capturePixelFormat == .automatic || availableInputFormats[captureModeID]?.contains(capturePixelFormat) == true)
    }
    var capturePixelFormatOptions: [YunSelect<CapturePixelFormat>.Option] {
        CapturePixelFormat.allCases.map { value in
            .init(value: value, title: value == .automatic ? loc("Auto") : value.title,
                  detail: value == .automatic ? loc("Prefer NV12") : value.fourCC)
        }
    }
    var selectedPage = UserDefaults.standard.string(forKey: "Pocket3SelectedPage") ?? "camera" { didSet { if !capturingUI { UserDefaults.standard.set(selectedPage, forKey: "Pocket3SelectedPage") } } }
    var capturingUI = false
    var access: AccessMode = .manual
    var question = ""
    var answer = ""
    var observationActions: [ObservationAction] = []
    var observationRoles: ObservationExecutionRoles?
    var evidence: [String] = []
    var uncertainties: [String] = []
    var evidenceImage: NSImage?
    var evidenceFrameID = ""
    var busy = false
    var connecting = false
    var message: String?
    var audioState: AppAudioMessage = .idle
    var audioMessage: String { audioState.formatted() }
    var aiTask: Task<Void, Never>?
    var started = false
    var bridgeRunning = false
    var mcpRequests = MCPRequestHistory()
    var testingBridgeConnection = false
    var bridgeConnectionCheckedAt: Date?
    var bridgeConnectionError: String?
    var remoteTaskCount = 0
    var aiWorking: Bool { busy || imageWorkspace.isWorking || remoteTaskCount > 0 || modelStatus?.isBusy == true }
    init(imageWorkspace: ImageObservationWorkspace? = nil) { imageWorkspaceStorage = imageWorkspace }

    func launch() async {
        guard !started else { return }; started = true
        YunStrings.bundle = AppResources.bundle
        YunTheme.shared.applyAppearance()
        InterfaceOptions.apply()
        setIconStyle(iconStyle)
        statusItem = StatusItemController(model: self)
        AppUpdateController.shared.start()
        do { try server.start { [service, intelligence, perception] request in
            do {
                switch request.operation {
                case "bridge-ping": return try LocalBridgeProbe.reply(to: request)
                case "status", "doctor":
                    return try await AppModel.shared.statusReply(id: request.id)
                case "stop":
                    await MainActor.run {
                        let model = AppModel.shared
                        model.focus.cancel(); model.zoom.cancel(); model.roll.cancel()
                        model.bluetoothProbePermit?.invalidate()
                        model.wireless.invalidatePendingOperations(); model.aiTask?.cancel()
                    }
                    // Fence camera writes before awaiting potentially slower
                    // model cancellation. Preserve the structured Stop reply.
                    let reply = request.source == .mcp
                        ? await AppModel.shared.performMCPRequest(request) : await service.handle(request)
                    await intelligence.cancelObservation()
                    return reply
                case "ui-capture": return try await AppModel.shared.captureWindow(request)
                case "ui-check": return try await AppModel.shared.checkInterface(request)
                case "image-workspace": return try await AppModel.shared.handleImageWorkspace(request)
                case USBManualAcceptanceRequest.operation:
                    return try await AppModel.shared.handleUSBManualAcceptance(request)
                case USBRollAcceptanceRequest.operation:
                    return try await AppModel.shared.handleUSBRollAcceptance(request)
                case NativeCaptureFormatValidationRequest.operation:
                    return try await AppModel.shared.handleNativeCaptureFormatValidation(request)
                case BluetoothReadbackSessionDiagnosticRequest.operation:
                    return try await AppModel.shared.handleReadbackDiagnostic(request)
                case "validation-manual-control": return try await AppModel.shared.handleManualControlValidation(request)
                case "focus-status":
                    // Read the exact active AVFoundation input capability. This
                    // never requests focus, camera access escalation or BLE.
                    return ServiceReply(id: request.id, result: try .encode(await service.capture.focusCapabilities()))
                case "format-inventory":
                    // Discovery reads the selected external camera's advertised
                    // AVFoundation formats only; it creates no capture session.
                    let status = await service.status()
                    // Match the CLI's discovery rule: an explicit selection
                    // wins, otherwise a single currently attached Pocket 3 is
                    // unambiguous. Multiple devices still require a selection.
                    guard let deviceID = status.selected?.id ?? (status.devices.count == 1 ? status.devices[0].id : nil) else {
                        throw BridgeFailure("camera_not_selected", "Choose a Pocket 3 before reading its format inventory")
                    }
                    let variants = CaptureMode.availableInputFormats(deviceID: deviceID)
                    let modes = CaptureMode.available(deviceID: deviceID).map { mode in
                        JSONValue.object(["id": .string(mode.id), "width": .number(Double(mode.width)),
                            "height": .number(Double(mode.height)), "frameRate": .number(mode.frameRate),
                            "portrait": .bool(mode.isPortrait), "verification": .string("advertised_only"),
                            "supportedInputFormats": .array((variants[mode.id] ?? []).map { value in
                                .object(["id": .string(value.rawValue), "name": .string(value.title),
                                         "fourCC": value.fourCC.map(JSONValue.string) ?? .null])
                            })])
                    }
                    return ServiceReply(id: request.id, result: .object(["deviceID": .string(deviceID), "formats": .array(modes)]))
                case "body-status":
                    // Do not touch `wireless`: accessing that lazy property
                    // creates a CoreBluetooth discovery object. MCP reads only
                    // telemetry the person has already explicitly initialized.
                    let bodyStatus = try await MainActor.run { () throws -> JSONValue in
                        if let wirelessStorage = self.wirelessStorage {
                            return .object(["initialized": .bool(true),
                                "discovery": try .encode(wirelessStorage.discovery),
                                "capabilities": try .encode(wirelessStorage.capabilityGraph)])
                        }
                        return .object(["initialized": .bool(false), "discovery": .null,
                            "capabilities": try .encode(Pocket3CapabilityGraph())])
                    }
                    return ServiceReply(id: request.id, result: bodyStatus)
                case "validation-focus-status", "validation-focus-point":
                    guard CommandLine.arguments.contains("--hardware-validation") else { throw BridgeFailure("validation_disabled", "Focus validation requires a development launch") }
                    let capabilities = await service.capture.focusCapabilities()
                    if request.operation == "validation-focus-status" {
                        return ServiceReply(id: request.id, result: try .encode(capabilities))
                    }
                    guard let token = capabilities.sessionToken,
                          let x = request.arguments["x"].number, let y = request.arguments["y"].number else {
                        throw BridgeFailure("invalid_focus_point", "Pass normalized x and y with an active camera")
                    }
                    return ServiceReply(id: request.id, result: try .encode(try await service.capture.focus(at: CGPoint(x: x, y: y), sessionToken: token)))
                case "validation-wireless-status", "validation-wireless-scan", "validation-wireless-connect", "validation-wireless-pair", "validation-wireless-read-settings", BluetoothVideoParametersReadbackRequest.operation, "validation-wireless-datalink", "validation-wireless-join", "validation-wireless-probe", "validation-wireless-readiness", "validation-wireless-recenter", "validation-wireless-lens", "validation-wireless-lens-series", BluetoothCameraEventRecordingRequest.operation, NativeActiveTrackObservationWindowRequest.operation, "validation-wireless-tap-focus", NativeTapFocusValidationRequest.operation, NativeMotionValidationRequest.operation, NativeSettingValidationRequest.operation, NativeAudioDSPValidationRequest.operation, NativeCameraCaptureValidationRequest.operation, NativeMediaValidationRequest.operation, NativeAdvancedSettingValidationRequest.operation, NativeExposureValidationRequest.operation, Pocket3LiveViewValidationRequest.operation, "validation-wireless-setting", "validation-wireless-property", "validation-wireless-body", "validation-wireless-route", NativeActiveTrackValidationRequest.operation, "validation-wireless-disconnect":
                    if request.operation == NativeActiveTrackObservationWindowRequest.operation {
                        return try await AppModel.shared.handleActiveTrackObservationWindow(request)
                    }
                    if request.operation == NativeActiveTrackValidationRequest.operation {
                        return try await AppModel.shared.handleActiveTrackValidation(request)
                    }
                    if request.operation == NativeTapFocusValidationRequest.operation {
                        return try await AppModel.shared.handleNativeTapFocusValidation(request)
                    }
                    if request.operation == NativeMotionValidationRequest.operation {
                        return try await AppModel.shared.handleNativeMotionValidation(request)
                    }
                    if request.operation == NativeSettingValidationRequest.operation {
                        return try await AppModel.shared.handleNativeSettingValidation(request)
                    }
                    if request.operation == NativeAudioDSPValidationRequest.operation {
                        return try await AppModel.shared.handleNativeAudioDSPValidation(request)
                    }
                    if request.operation == NativeCameraCaptureValidationRequest.operation {
                        return try await AppModel.shared.handleNativeCameraCaptureValidation(request)
                    }
                    if request.operation == NativeMediaValidationRequest.operation {
                        return try await AppModel.shared.handleNativeMediaValidation(request)
                    }
                    if request.operation == NativeAdvancedSettingValidationRequest.operation {
                        return try await AppModel.shared.handleNativeAdvancedSettingValidation(request)
                    }
                    if request.operation == NativeExposureValidationRequest.operation {
                        return try await AppModel.shared.handleNativeExposureValidation(request)
                    }
                    if request.operation == Pocket3LiveViewValidationRequest.operation {
                        return try await AppModel.shared.handleNativeLiveViewValidation(request)
                    }
                    return try await AppModel.shared.handleWirelessValidation(request)
                case "evaluate-image", "evaluate-workflow", "evaluate-perception", "evaluate-grounding":
                    guard CommandLine.arguments.contains("--hardware-validation"), let encoded = request.arguments["imageData"].string, encoded.utf8.count <= 11_000_000, let data = Data(base64Encoded: encoded) else { throw BridgeFailure("evaluation_disabled", "圖片評測只供開發工作階段使用，請傳入 8 MB 以下圖片") }
                    let frame = try await Task.detached { try FramePacket.fixture(data: data) }.value
                    let start = ProcessInfo.processInfo.systemUptime
                    let engine = request.arguments["engine"].string ?? "apple"
                    if request.operation == "evaluate-grounding" {
                        guard let kind = GroundedImageKind(rawValue: request.arguments["kind"].string ?? "") else {
                            throw BridgeFailure("invalid_grounding_kind", "定位評測 kind 須為 count、point 或 absent")
                        }
                        let result = try await intelligence.grounded(frame: frame,
                            question: request.arguments["question"].string ?? "", kind: kind, engine: engine)
                        return ServiceReply(id: request.id, result: try result.metadata())
                    }
                    if request.operation == "evaluate-perception" {
                        guard let mode = PerceptionComputeMode(rawValue: request.arguments["compute"].string ?? "automatic") else { throw BridgeFailure("invalid_compute", "未知 Core AI 運算選項") }
                        #if DEBUG
                        let evaluator = request.arguments["precision"].string == "float16" ? PerceptionEngine(path: Bundle.main.resourceURL!.appendingPathComponent("Models/yolos-tiny_float16_static.aimodel").path) : perception
                        if request.arguments["probe"].bool == true { return ServiceReply(id: request.id, result: try .encode(try await evaluator.probe(frame: frame, mode: mode))) }
                        return ServiceReply(id: request.id, result: try .encode(try await evaluator.detect(frame: frame, mode: mode)))
                        #else
                        guard request.arguments["probe"].bool != true, request.arguments["precision"].string != "float16" else { throw BridgeFailure("evaluation_disabled", "原始 tensor／Float16 比較只供 Debug 建置使用") }
                        return ServiceReply(id: request.id, result: try .encode(try await perception.detect(frame: frame, mode: mode)))
                        #endif
                    }
                    #if DEBUG
                    if request.operation == "evaluate-workflow" {
                        let after = request.arguments["afterImageData"].string.flatMap { Data(base64Encoded: $0) }
                        let afterFrame = try await Task.detached { try after.map(FramePacket.fixture(data:)) ?? frame }.value
                        let simulated = SimulatedObservationCamera(before: frame, after: afterFrame, access: request.arguments["allowMove"].bool == true ? .control : .observe)
                        do {
                            let result = try await intelligence.observe(service: simulated, question: request.arguments["question"].string ?? "", engine: engine,
                                intent: try Self.requestedObservationIntent(request.arguments))
                            return ServiceReply(id: request.id, result: .object(["simulation": await simulated.report(), "result": try result.metadata()]))
                        } catch {
                            return ServiceReply(id: request.id, result: .object(["simulation": await simulated.report(), "failure": .string(error.localizedDescription), "error": try .encode(error as? BridgeFailure ?? BridgeFailure("evaluation_failed", error.localizedDescription))]))
                        }
                    }
                    #else
                    if request.operation == "evaluate-workflow" { throw BridgeFailure("evaluation_disabled", "模擬工作流程只供 Debug 建置使用") }
                    #endif
                    let answer = try await intelligence.analyze(frame: frame, question: request.arguments["question"].string ?? "", engine: engine)
                    return ServiceReply(id: request.id, result: .object(["answer": try .encode(answer), "frame": try .encode(frame.info), "engine": .string(engine), "elapsedSeconds": .number(ProcessInfo.processInfo.systemUptime-start)]))
                case "ai-status": return ServiceReply(id: request.id, result: .object(["apple": try .encode(await intelligence.status()), "mlx": try .encode(await intelligence.localModel.status())]))
                case "model-download":
                    Task { try? await intelligence.localModel.download() }
                    return ServiceReply(id: request.id, result: .object(["started": .bool(true)]))
                case "ai-cancel": await intelligence.cancelObservation(); return ServiceReply(id: request.id, result: .object(["cancelled": .bool(true)]))
                case "model-unload": try await intelligence.unloadModel(); return ServiceReply(id: request.id, result: try .encode(await intelligence.localModel.status()))
                case "ask", "detect": return try await AppModel.shared.remoteObservation(request)
                default:
                    if request.source == .mcp { return await AppModel.shared.performMCPRequest(request) }
                    return await service.handle(request)
                }
            } catch { return ServiceReply(id: request.id, error: error as? BridgeFailure ?? BridgeFailure("ai_failed", error.localizedDescription)) }
        }; bridgeRunning = true }
        catch {
            bridgeRunning = false; message = AppErrorPresentation.message(error)
            if (error as? BridgeFailure)?.code == "already_running" {
                NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?.activate()
                NSApp.terminate(nil)
            }
            return
        }
        await refresh()
        FirstLaunchPermissions.presentIfNeeded(model: self)
        modelStatus = await intelligence.status()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if CommandLine.arguments.contains("--autoconnect"), canConnect {
            await connect()
            if CommandLine.arguments.contains("--allow-observe") { await setAccess(.observe) }
        }
    }
    func remoteObservation(_ request: ServiceRequest) async throws -> ServiceReply {
        remoteTaskCount += 1; defer { remoteTaskCount -= 1 }
        if request.operation == "detect" {
            let stamp = try await service.interactionStamp(origin: .automation)
            let frame = try await service.frame(origin: .automation)
            let result = try await perception.detect(frame: frame)
            try await service.validateInteraction(stamp, origin: .automation)
            return ServiceReply(id: request.id, result: try .encode(result))
        }
        let result = try await intelligence.observe(service: service, question: request.arguments["question"].string ?? "", engine: request.arguments["engine"].string ?? "apple",
            intent: Self.requestedObservationIntent(request.arguments), origin: .automation)
        return ServiceReply(id: request.id, result: try result.metadata())
    }
    func refresh() async {
        // The bounded BLE timing experiment owns its live telemetry directly.
        // Keep synchronous format enumeration/model UI polling off MainActor
        // while its 50 ms submission slots are active; Stop stays independent.
        guard bluetoothProbePermit == nil else { return }
        await wireless.refresh()
        // Feed the same credential-free wireless readiness/body readback into
        // CameraService before taking the published status snapshot. This is
        // a scalar context update; it never initializes a transport.
        await service.updateCapabilityContext(
            nativeSession: NativeSessionCapability.from(wireless.nativeSessionStatus),
            bodyRecordingFormats: wireless.bodyRecordingCapabilitySnapshot)
        status = await service.status()
        updatePowerChargingDiagnosis()
        await configureUSBContinuousControls()
        await focus.refresh(capture: status?.capture, phase: status?.phase)
        if !capturingUI {
            await zoom.refresh(sessionID: status?.capture.sessionID, phase: status?.phase ?? "idle",
                               blocked: isConnecting || isManualPresetBusy || wireless.ownsContinuousControls || (rollStorage?.isWorking == true && rollStorage?.isCancelling != true))
            await roll.refresh(sessionID: status?.capture.sessionID, phase: status?.phase ?? "idle",
                               blocked: isConnecting || isManualPresetBusy || wireless.ownsContinuousControls || (zoomStorage?.isWorking == true && zoomStorage?.isCancelling != true))
        }
        localStatus = await intelligence.localModel.status()
        modelStatus = await intelligence.status()
        access = status?.access ?? .manual
        cameraSelection.refresh(availableIDs: status?.devices.map(\.id) ?? [])
        availableModes = CaptureMode.available(deviceID: selectedID)
        availableInputFormats = CaptureMode.availableInputFormats(deviceID: selectedID)
    }

    private func updatePowerChargingDiagnosis() {
        let now = Date()
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let discovery = wireless.discovery
        let paired = discovery.pairing?.peerReportedPaired == true
        let sessionID = paired ? discovery.sessionID : nil
        let peripheralID = paired ? discovery.selectedPeripheralID : nil
        let battery: Pocket3PowerChargingBatterySample?
        if paired, let observation = discovery.battery {
            let age = now.timeIntervalSince(observation.telemetry.receivedAt)
            battery = Pocket3PowerChargingBatterySample(
                sessionID: observation.sessionID,
                peripheralID: observation.peripheralID,
                percent: observation.telemetry.percent,
                chargingRaw: observation.telemetry.chargingStateRaw,
                receivedUptime: nowUptime - age)
        } else {
            battery = nil
        }
        let input = Pocket3PowerChargingInput(
            usb: Pocket3PowerChargingUSBInput(status?.power),
            sessionID: sessionID, peripheralID: peripheralID,
            battery: battery, nowUptime: nowUptime)
        powerChargingDiagnosis = powerChargingReducer.reduce(input)
    }

    /// Keeps the local API on the same USB/BLE power projection as the app.
    /// Reading status never starts a capture, pairs Bluetooth, or writes to the
    /// camera; it only refreshes the already available service snapshot.
    func statusReply(id: String) async throws -> ServiceReply {
        status = await service.status()
        updatePowerChargingDiagnosis()
        var payload = try JSONValue.encode(status)
        if case .object(var fields) = payload {
            fields["powerChargingDiagnosis"] = try powerChargingDiagnosis.map(JSONValue.encode) ?? .null
            payload = .object(fields)
        }
        return ServiceReply(id: id, result: payload)
    }
    private func configureUSBContinuousControls() async {
        guard !wireless.ownsContinuousControls else { return }
        do {
            let endpoint = try await service.usbContinuousControlEndpoint()
            guard !wireless.ownsContinuousControls else { return }
            guard let endpoint else {
                continuousGimbal.configure(scheduler: nil, binding: nil, availability: .disconnected)
                return
            }
            // Core returns the same endpoint while moving/stopping, so the
            // ordinary one-second refresh never cancels a held USB gesture.
            continuousGimbal.configure(scheduler: endpoint.scheduler, binding: endpoint.binding, availability: .ready,
                authorize: { [service] in try await service.prepareUSBContinuousControl(binding: endpoint.binding) },
                prepare: { [weak self] in
                    guard let self else { throw CancellationError() }
                    guard self.isCameraSource else { throw BridgeFailure("file_source_active", "Return to the live camera before camera movement") }
                    self.zoomStorage?.cancel(); self.rollStorage?.cancel()
                    self.aiTask?.cancel()
                    await self.intelligence.cancelObservation()
                    try Task.checkCancellation()
                })
        } catch {
            guard !wireless.ownsContinuousControls else { return }
            continuousGimbal.configure(scheduler: nil, binding: nil,
                availability: .blocked(AppErrorPresentation.message(error, fallback: .controlUnavailable)))
        }
    }
    func setIconStyle(_ value: String) {
        iconStyle = YunIconBadge.style(named: value).name
        UserDefaults.standard.set(iconStyle, forKey: "Pocket3IconStyle")
        NSApp.applicationIconImage = YunIconBadge.image(size: 128, style: YunIconBadge.style(named: iconStyle))
    }
    var microphonePermission: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        default: "notDetermined"
        }
    }
    func allowCameraPermission() async { _ = await AVCaptureDevice.requestAccess(for: .video); await refresh() }
    func allowMicrophonePermission() async { _ = await AVCaptureDevice.requestAccess(for: .audio); await refresh() }
    func copyIssueReport() {
        let info = "\(Pocket3Product.displayName) \(Pocket3Product.displayVersion)\n\(ProcessInfo.processInfo.operatingSystemVersionString)\n\nWhat happened?\n\nExpected result?\n"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(info, forType: .string)
        message = loc("Report copied to clipboard.")
    }
    func connect() async {
        guard isCameraSource else { return }
        zoomStorage?.cancel(); rollStorage?.cancel()
        focusStorage?.cancel()
        connecting = true; message = nil
        await continuousGimbal.stop(reason: .cancelled)
        await wireless.disconnectNative()
        let requestedID = selectedID
        let requestedPixelFormat = capturePixelFormat
        let requestedOutputPolicy = captureOutputPolicy
        do {
            guard let captureMode else { throw BridgeFailure("invalid_format", loc("Select a capture format")) }
            try await service.connect(id: requestedID, mode: captureMode, pixelFormat: requestedPixelFormat, outputPolicy: requestedOutputPolicy)
            UserDefaults.standard.set(captureMode.id, forKey: "Pocket3CaptureModeID")
            // A different choice made while permission or connection was
            // pending remains the operator's next intended camera.
            if selectedID == requestedID { cameraSelection.select(requestedID, availableIDs: status?.devices.map(\.id) ?? []) }
        }
        catch { message = AppErrorPresentation.message(error) }
        connecting = false; await refresh()
    }
    var isConnecting: Bool { connecting || status?.phase == "connecting" }
    var canConnect: Bool { isCameraSource && !isConnecting && capturePixelFormatSupported && status?.devices.contains(where: { $0.id == selectedID }) == true }
    var outputPolicyStatus: String? {
        guard let status, (status.requestedOutputPolicy == .h264 || status.requestedOutputPolicy == .hevc) else { return nil }
        let codec = status.requestedOutputPolicy == .hevc ? "HEVC" : "H.264"
        return codec + " host output · " + String(format: "%.1f fps", status.capture.recentFPS)
    }
    var outputPolicyRateLimited: Bool {
        guard let status, (status.requestedOutputPolicy == .h264 || status.requestedOutputPolicy == .hevc),
              let requested = status.requestedMode?.frameRate, requested > 0 else { return false }
        return status.capture.recentFPS > 0 && status.capture.recentFPS < requested * 0.9
    }
    var hasPossibleHorizontalBlackBars: Bool {
        guard let edges = status?.capture.sampleDiagnostics?.edgeMetrics else { return false }
        return edges.topDarkFraction >= 0.95 && edges.bottomDarkFraction >= 0.95
    }
    var cameraSelectionPlaceholder: String { loc(status?.devices.isEmpty != false ? "No camera detected" : "Select a camera") }
    func setAccess(_ mode: AccessMode) async { guard isCameraSource else { return }; zoomStorage?.cancel(); rollStorage?.cancel(); await service.setAccess(mode); await refresh() }
    func move(_ direction: String) async {
        guard isCameraSource else { return }
        zoomStorage?.cancel(); rollStorage?.cancel()
        do { await service.setAccess(.manual); _ = try await service.move(direction: direction); await refresh() }
        catch { message = AppErrorPresentation.message(error) }
    }
    func point(panDegrees: Double?, tiltDegrees: Double?) async {
        guard isCameraSource else { return }
        zoomStorage?.cancel(); rollStorage?.cancel()
        do {
            _ = try await service.point(panDegrees: panDegrees, tiltDegrees: tiltDegrees, expectedSessionID: status?.capture.sessionID)
            await refresh()
        } catch { message = AppErrorPresentation.message(error) }
    }
    var canManualGimbalPreset: Bool {
        cameraActionReady && !isConnecting && !isManualPresetBusy
            && wireless.nativeConnected
    }
    func manualGimbalPreset(flip: Bool) async {
        zoomStorage?.cancel(); rollStorage?.cancel()
        guard canManualGimbalPreset else { return }
        isManualPresetBusy = true
        defer { isManualPresetBusy = false }
        message = nil
        await continuousGimbal.stop(reason: .cancelled)
        aiTask?.cancel()
        await intelligence.cancelObservation()
        do {
            try Task.checkCancellation()
            // These buttons represent DJI's double/triple-press operations.
            // The slow absolute USB approach remains a separate research API;
            // it must never masquerade as a native recenter/selfie action.
            await wireless.preset(flip: flip)
        } catch { message = AppErrorPresentation.message(error) }
        await refresh()
    }
    /// Used by the isolated BLE focus probe before claiming service ownership.
    func cancelLensControlDrafts() {
        zoomStorage?.cancel(); rollStorage?.cancel(); focusStorage?.cancel()
    }
    func stop() async {
        imageWorkspace.cancel()
        zoomStorage?.cancel(); rollStorage?.cancel()
        focusStorage?.cancel()
        bluetoothProbePermit?.invalidate()
        wireless.invalidatePendingOperations()
        await continuousGimbal.stop(reason: .cancelled)
        aiTask?.cancel(); await intelligence.cancelObservation()
        do { let r = try await service.stop(); message = r.verified ? nil : AppErrorPresentation.message(code: "stop_unverified", details: r.message) }
        catch { message = AppErrorPresentation.message(error) }
        await refresh()
    }
    func pause() async {
        imageWorkspace.cancel()
        zoomStorage?.cancel(); rollStorage?.cancel()
        focusStorage?.cancel()
        bluetoothProbePermit?.invalidate()
        await continuousGimbal.stop(reason: .cancelled)
        _ = try? await service.stop()
        await wireless.disconnect()
        aiTask?.cancel(); await intelligence.cancelObservation(); await service.pause(); evidenceImage = nil; await refresh()
    }
    func snapshot() async {
        guard cameraActionReady else { return }
        do {
            let (_, data) = try await service.snapshot()
            let panel = NSSavePanel(); panel.allowedContentTypes = [.jpeg]; panel.nameFieldStringValue = "Pocket3-\(Int(Date().timeIntervalSince1970)).jpg"
            if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic) }
        } catch { message = AppErrorPresentation.message(error) }
    }
    func ask() {
        guard observationReady, canAsk, !aiWorking else { return }
        if !isCameraSource { imageWorkspace.begin(engine: selectedEngine); return }
        busy = true; clearObservationPresentation()
        observationRevision += 1
        let revision = observationRevision, q = question, engine = selectedEngine, intent = observationIntent
        aiTask = Task { [self] in
            defer { busy = false; aiTask = nil }
            do {
                let result = try await intelligence.observe(service: service, question: q, engine: engine, intent: intent)
                try Task.checkCancellation()
                guard observationRevision == revision, isCameraSource else { return }
                observationActions = result.actions
                observationRoles = result.executionRoles
                evidenceImage = NSImage(data: result.imageJPEG); evidenceFrameID = result.frame.id
                answer = result.answer.answer; evidence = result.answer.evidence; uncertainties = result.answer.uncertainties

            } catch is CancellationError { if observationRevision == revision { message = loc("Observation cancelled") } }
            catch { if observationRevision == revision { message = AppErrorPresentation.message(error) } }
        }
    }
    func ocr() async {
        guard !aiWorking else { return }
        if !isCameraSource { imageWorkspace.begin(engine: selectedEngine, action: .ocr); return }
        busy = true
        observationRevision += 1; let revision = observationRevision
        answer = ""; evidence = []; uncertainties = []; observationActions = []; observationRoles = nil; evidenceImage = nil; evidenceFrameID = ""; message = nil
        let task = Task { [self] in
        defer { busy = false; aiTask = nil }
        do {
            try Task.checkCancellation()
            let stamp = try await service.interactionStamp(origin: .manual)
            let frame = try await service.frame()
            try Task.checkCancellation()
            let lines = try await intelligence.recognizeText(frame: frame)
            try Task.checkCancellation()
            let (metadata, jpeg) = try await Task.detached { try frame.jpegWithInfo(maxDimension: 1280) }.value
            try await service.validateInteraction(stamp, origin: .manual)
            guard observationRevision == revision, isCameraSource else { return }
            answer = lines.isEmpty ? loc("No clear text was recognised.") : lines.joined(separator: "\n")
            evidenceImage = NSImage(data: jpeg); evidenceFrameID = metadata.id
        } catch { if observationRevision == revision { message = AppErrorPresentation.message(error) } }
        }
        aiTask = task
        await task.value
    }
    var localPhaseTitle: String {
        loc(["notDownloaded": "Not downloaded", "downloaded": "Downloaded", "loading": "Loading", "loaded": "Loaded", "downloading": "Downloading", "cancelled": "Download cancelled", "unloading": "Unloading", "error": "Needs attention"][localStatus?.phase ?? "notDownloaded"] ?? "Not ready")
    }
    var localModelDescription: String {
        switch localStatus?.phase {
        case "downloaded": loc("Downloaded and ready for offline use.")
        case "loaded": loc("Loaded in memory · MLX / GPU")
        case "loading": loc("Loading the local model…")
        case "downloading": loc("Downloading the selected model version…")
        case "cancelled": loc("Download cancelled. Download again to resume.")
        case "unloading": loc("Releasing model memory…")
        case "error": AppErrorPresentation.message(code: "local_model_error", details: localStatus?.message)
        default: loc("About 3.1 GB · public Hugging Face weights")
        }
    }
    var appleUsesMLXControl: Bool {
        isCameraSource && observationIntent == .assistFraming && selectedEngine == "apple" && status?.access == .control &&
            (status?.stopValidated == true || zoomStorage?.capabilities.map(ObservationZoomPolicy.isAvailable) == true)
    }
    var canAsk: Bool {
        selectedEngine == "mlx" ? localStatus?.available == true :
            modelStatus?.available == true && (!appleUsesMLXControl || localStatus?.available == true)
    }
    var engineRoleMessage: String {
        if !isCameraSource { return loc("The selected model analyses this frame or area. Camera controls are not used.") }
        if observationIntent == .observe { return loc("Only the selected model observes. Camera adjustments are not part of this task.") }
        return selectedEngine == "apple"
            ? loc("Apple answers from images. AI control also uses the downloaded MLX model.")
            : loc("MLX handles camera control and visual answers locally.")
    }
    var engineMessage: String {
        if selectedEngine == "mlx" { return loc("Download a local model on the AI engines page.") }
        if appleUsesMLXControl, localStatus?.available != true { return loc("Download the MLX model to use AI camera control with Apple visual answers.") }
        if modelStatus?.available == true { return loc("Ready") }
        return AppErrorPresentation.message(code: "model_unavailable", details: modelStatus?.detail)
    }
    func prepareLocalModel() {
        Task {
            do { if localStatus?.available != true { try await intelligence.localModel.download() }; _ = try await intelligence.localModel.load(); await refresh() }
            catch { message = AppErrorPresentation.message(error); await refresh() }
        }
    }
    func detectObjects() async {
        guard isCameraSource, !aiWorking else { return }
        busy = true; perceptionResult = nil; defer { busy = false }
        do {
            let stamp = try await service.interactionStamp(origin: .manual)
            let result = try await perception.detect(frame: service.frame())
            try await service.validateInteraction(stamp, origin: .manual)
            perceptionResult = result
        }
        catch { message = AppErrorPresentation.message(error) }
    }
    func validateControl() async {
        guard isCameraSource, !aiWorking else { return }
        do { try await service.startUserValidation(); await refresh() }
        catch { message = AppErrorPresentation.message(error) }
    }
    func audioTest() async {
        guard isCameraSource else { return }
        audioState = .testing
        do { audioState = .completed(try await service.audioTest()) }
        catch {
            // Retain the existing bounded technical diagnostic independently
            // from the key that is translated when either view renders.
            _ = AppErrorPresentation.message(error, fallback: .audio)
            audioState = .failed(AppErrorPresentation.key(for: error, fallback: .audio))
        }
    }
    func exportDiagnostics() async {
        let status = await service.status()
        do {
            let json = try Diagnostics.redacted(status)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Pocket3-diagnostics.json"
            if panel.runModal() == .OK, let url = panel.url { try Data(json.pretty.utf8).write(to: url, options: .atomic) }
        } catch { message = AppErrorPresentation.message(error) }
    }
    var ready: Bool { status?.phase == "ready" }
    var phaseTitle: String {
        switch status?.phase {
        case "ready": return (status?.capture.age ?? 10) < 1 ? loc("Observing") : loc("Waiting for a fresh frame")
        case "stalled": return loc("Camera stream interrupted")
        case "connecting": return loc("Connecting")
        case "moving": return loc("Moving camera")
        case "stopping": return loc("Stopping")
        case "validating": return loc("Validating hardware")
        case "soaking": return loc("Testing camera stream")
        case "paused": return loc("Privacy paused")
        case "disconnected": return loc("Camera disconnected")
        case "suspended": return loc("Reconnect to continue")
        case "error": return loc("Needs attention")
        default: return loc("Not connected")
        }
    }
    var bridgePath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pocket3").path }
    var mcpConfiguration: String {
        JSONValue.object(["mcpServers": .object(["pocket3": .object(["command": .string(bridgePath), "args": .array([.string("mcp")])])])]).pretty
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationPending = false
    private var backgroundBridge: Bool { CommandLine.arguments.contains("--background-bridge") }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }; terminationPending = true
        Task { await AppModel.shared.pause(); AppModel.shared.server.stop(); AppModel.shared.statusItem?.close(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let present = AppModel.shared.openMainWindow else { return true }; present(); return false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if backgroundBridge {
            // Keep the App and its same-user IPC server alive without a Dock
            // icon or visible main window. This remains a logged-in user
            // process; it is not a pre-login daemon and does not bypass TCC.
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                for window in NSApp.windows where window.title == Pocket3Product.displayName { window.orderOut(nil) }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                AppModel.shared.bluetoothProbePermit?.invalidate()
                AppModel.shared.zoom.cancel(); AppModel.shared.roll.cancel()
                AppModel.shared.focus.cancel()
                await AppModel.shared.continuousGimbal.stop(reason: .focusLost)
                _ = try? await AppModel.shared.service.stop()
                await AppModel.shared.wireless.disconnect()
                await AppModel.shared.service.suspend()
            }
        }
    }
}

@MainActor struct Pocket3BridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    var body: some Scene {
        Window(Pocket3Product.displayName, id: "main") {
            RootView(model: model)
                .task {
                    await model.launch()
                }
        }
        .defaultSize(width: 1260, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button(loc("Settings")) { SettingsWindow.open(model: model) }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button(loc("About")) { SettingsWindow.open(model: model, initialSection: .about) }
                Button(loc("Check for Updates…")) { SettingsWindow.open(model: model, initialSection: .about); AppUpdateController.shared.checkForUpdates() }
            }
            CommandMenu(loc("Camera")) {
                Button(loc("Capture image")) { Task { await model.snapshot() } }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.cameraActionReady)
                Button(loc("Stop operation")) { Task { await model.stop() } }.keyboardShortcut(".", modifiers: .command)
                Button(loc("Privacy pause")) { Task { await model.pause() } }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Bindable private var theme = YunTheme.shared
    @State private var showUVC = false
    @State private var showWireless = false
    @State private var showCaptureSettings = false
    @State private var showUSBManualAcceptance = false
    var body: some View {
        let _ = theme.language
        VStack(spacing: 0) {
            header.measuredForLayout("header")
            if let message = model.message {
                AppMessageBanner(message: message).measuredForLayout("banner")
                    .padding(.horizontal, Yun.Space.xl)
                    .padding(.bottom, Yun.Space.md)
            }
            Group {
                switch model.selectedPage {
                case "engines": engines
                case "diagnostics": diagnostics
                default: camera
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer.measuredForLayout("footer")
        }
        .coordinateSpace(name: "Pocket3MainLayout")
        .onPreferenceChange(LayoutBoundsKey.self) { model.layoutBounds = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MainWindowMinimumSize().frame(width: 0, height: 0))
        .ignoresSafeArea(.container, edges: .top)
        .yunWindowBackground()
        .foregroundStyle(Yun.Palette.textPrimary)
        .tint(Yun.Palette.accent)
        .environment(\.locale, theme.language == .system ? .autoupdatingCurrent : Locale(identifier: theme.language.rawValue))
        .focusEffectDisabled()
        .background(WindowChromeInstaller().frame(width: 0, height: 0))
        .background(RemembersFrame(name: "Pocket3BridgeMainWindow").frame(width: 0, height: 0))
        .onAppear { model.openMainWindow = { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } }
    }
    private var header: some View {
        HStack(spacing: Yun.Space.md) {
            Image(nsImage: YunAppIcon.trimmed).resizable().scaledToFit().frame(height: 22)
            Text(Pocket3Product.displayName).font(.system(size: 16, weight: .semibold))
            Rectangle().fill(Yun.Palette.borderHairline).frame(width: 1, height: 18)
            ForEach([("camera", loc("Camera")), ("engines", loc("AI engines & integration")), ("diagnostics", loc("Diagnostics"))], id: \.0) { id, title in
                Button(loc(title)) { model.selectedPage = id }.buttonStyle(YunButtonStyle(model.selectedPage == id ? .primary : .ghost, small: true))
            }
            Spacer(minLength: 10)
            Button { SettingsWindow.open(model: model) } label: { Image(systemName: "gearshape").font(.system(size: 11)).frame(width: 14) }.buttonStyle(YunButtonStyle(.ghost, small: true)).help(loc("Settings"))
            Button { Task { await model.stop() } } label: { Label(loc("Stop operation"), systemImage: "stop.fill") }.buttonStyle(YunButtonStyle(.secondary, small: true))
            Button { Task { await model.pause() } } label: { Label(loc("Privacy pause"), systemImage: "eye.slash") }.buttonStyle(YunButtonStyle(.primary, small: true))
        }.padding(.horizontal, Yun.Space.xl).padding(.top, WindowChrome.controlClearance).padding(.bottom, Yun.Space.md)
    }
    private var camera: some View {
        HStack(alignment: .top, spacing: Yun.Space.lg) {
            ScrollView {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    heading(loc("Source"), loc("Choose a camera or a media file"))
                    YunCard {
                        VStack(alignment: .leading, spacing: Yun.Space.md) {
                            YunSegmented(selection: Binding(get: { model.observationSource }, set: { source in
                                Task { await model.changeObservationSource(source) }
                            }), options: [(.camera, loc("Live camera")), (.image, loc("Media file"))])
                                .disabled(!model.canChangeObservationSource)
                            if model.isCameraSource {
                            HStack {
                                Label("Pocket 3", systemImage: "cable.connector").font(Yun.Text.title)
                                Spacer(minLength: 0)
                                if model.ready {
                                    Button { showCaptureSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                                        .buttonStyle(YunButtonStyle(.ghost, small: true)).help(loc("Capture settings"))
                                }
                            }
                            if !model.ready || showCaptureSettings {
                            YunSelect(selection: $model.selectedID, placeholder: model.cameraSelectionPlaceholder, options: (model.status?.devices ?? []).map { .init(value: $0.id, title: $0.name) })
                            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                                Text(loc("Webcam output format")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                                YunSelect(selection: $model.captureModeID, placeholder: loc("Select a webcam output format"), options: model.availableModes.map { .init(value: $0.id, title: $0.compactTitle, detail: loc($0.isPortrait ? "Portrait" : "Landscape")) })
                            }
                            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                                Text(loc("USB input format")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                                YunSelect(selection: $model.capturePixelFormat, options: model.capturePixelFormatOptions)
                                if model.captureMode != nil && !model.capturePixelFormatSupported {
                                    Text(loc("This input format is not advertised for the selected mode.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                                Text(loc("Preview output")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                                YunSelect(selection: $model.captureOutputPolicy, options: model.captureOutputPolicyOptions)
                            }
                            Text(loc("Match the shooting orientation on Pocket 3 to this format to avoid black borders.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                            Text(loc("Body recording formats such as 3K portrait are separate from currently advertised Webcam UVC formats.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                            Button(model.isConnecting ? loc("Connecting…") : model.ready ? loc("Reconnect") : loc("Connect camera")) { Task { await model.connect() } }.buttonStyle(YunButtonStyle(.primary)).disabled(!model.canConnect)
                            Text(loc("Choose Webcam mode on the camera after connecting USB.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                            } else if let frame = model.status?.capture.frame {
                                HStack(spacing: Yun.Space.sm) {
                                    Text(model.status?.selected?.name ?? "Pocket 3").lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(verbatim: "\(frame.width)×\(frame.height)").font(Yun.Text.mono)
                                }.font(Yun.Text.caption).foregroundStyle(Yun.Palette.textSecondary)
                                if let output = model.outputPolicyStatus {
                                    Label(output, systemImage: "video.badge.waveform")
                                        .font(Yun.Text.caption)
                                        .foregroundStyle(model.outputPolicyRateLimited ? Yun.Palette.warning : Yun.Palette.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if model.outputPolicyRateLimited {
                                        if model.status?.requestedOutputPolicy == .hevc {
                                            Text(loc("HEVC host output is below the requested frame rate."))
                                                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.warning)
                                                .fixedSize(horizontal: false, vertical: true)
                                        } else {
                                            Text(loc("H.264 host output is below the requested frame rate."))
                                                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.warning)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                                if model.hasPossibleHorizontalBlackBars {
                                    Label(loc("Possible horizontal black bars detected."), systemImage: "rectangle.split.3x1")
                                        .font(Yun.Text.caption).foregroundStyle(Yun.Palette.warning)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            YunDivider()
                            YunSelect(selection: Binding(get: { model.access }, set: { value in Task { await model.setAccess(value) } }), options: AccessMode.allCases.map { .init(value: $0, title: loc($0.title)) })
                                .accessibilityLabel(loc("AI access"))
                            } else { ImageObservationSourceControls(model: model) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    YunCard {
                        VStack(alignment: .leading, spacing: Yun.Space.sm) {
                            Text(loc("Manual control")).font(Yun.Text.title)
                            Button { showWireless = true } label: {
                                Label(loc(model.wireless.nativeConnected ? "Wireless control connected" : "Bluetooth and wireless options"), systemImage: "antenna.radiowaves.left.and.right")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(YunButtonStyle(.secondary, small: true))
                                .popover(isPresented: $showWireless, arrowEdge: .trailing) { WirelessGimbalConnectionView(model: model.wireless) }
                            ContinuousGimbalControls(controller: model.continuousGimbal, interactionEnabled: model.isCameraSource)
                            GimbalRangeControls(model: model)
                            HStack(spacing: Yun.Space.sm) {
                                Button { Task { await model.manualGimbalPreset(flip: false) } } label: { Image(systemName: "scope").frame(maxWidth: .infinity) }
                                    .help(loc("Center view")).accessibilityLabel(loc("Center view"))
                                Button { Task { await model.manualGimbalPreset(flip: true) } } label: { Image(systemName: "camera.rotate").frame(maxWidth: .infinity) }
                                    .help(loc("Flip front and back")).accessibilityLabel(loc("Flip front and back"))
                            }.buttonStyle(YunButtonStyle(.secondary, small: true)).disabled(!model.canManualGimbalPreset)
                            if !model.wireless.nativeConnected {
                                Text(loc("Native recenter and flip are still in development."))
                                    .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                            }
                            YunDivider()
                            CameraZoomControls(model: model.zoom)
                            YunDivider()
                            CameraRollControls(model: model.roll)
                            Button { Task { await model.snapshot() } } label: { Label(loc("Capture image"), systemImage: "camera") }.buttonStyle(YunButtonStyle(.secondary)).disabled(!model.cameraActionReady)
                        }
                    }.disabled(!model.isCameraSource)
                }.padding(.bottom, Yun.Space.md)
            }.scrollIndicators(.automatic).yunScrollFade().frame(width: MainWindowLayout.sourceWidth).measuredForLayout("source")
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                heading(loc(model.isCameraSource ? "Live view" : "Media file"), loc(model.isCameraSource ? "Live preview · images shared with AI on request" : "Local file · analyse a selected frame or area"))
                YunCard(padding: 0) {
                    ZStack {
                        let previewIsActive = ["ready", "moving", "stopping", "validating", "soaking"].contains(model.status?.phase ?? "")
                        Yun.Palette.elevated
                        if !model.isCameraSource {
                            ImportedImagePreview(image: model.imageWorkspace.preview,
                                imageSize: CGSize(width: model.imageWorkspace.asset?.frame.info.width ?? 1,
                                    height: model.imageWorkspace.asset?.frame.info.height ?? 1),
                                point: model.imageWorkspace.marker, redacted: model.capturingUI,
                                region: model.imageWorkspace.region,
                                selectingRegion: model.imageWorkspace.selectingRegion,
                                selectRegion: { model.imageWorkspace.setRegion($0) })
                        } else if let image = model.capturePreview { Image(nsImage: image).resizable().scaledToFit() }
                        else if !model.capturingUI { Preview(session: model.service.capture.session, frame: model.status?.capture.frame, focus: model.focus) }
                        else if previewIsActive { YunEmptyState(symbol: "eye.slash", message: loc("Preview hidden for this screenshot")) }
                        if model.isCameraSource && !previewIsActive {
                            YunEmptyState(symbol: model.status?.phase == "paused" ? "eye.slash" : "camera", message: model.status?.phase == "paused" ? loc("Observation paused\nReconnect to continue") : model.status?.phase == "stalled" ? loc("Camera stream interrupted\nReconnect or check other camera apps") : loc("Connect Pocket 3\nGive AI a view of your workspace"))
                        }
                    }.frame(maxWidth: .infinity, minHeight: 265, maxHeight: .infinity).clipShape(.rect(cornerRadius: Yun.Radius.card))
                }
                activity
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).measuredForLayout("previewColumn")
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                heading(loc("AI observation"), loc("On-device answers with evidence"))
                observation
            }.frame(width: MainWindowLayout.inspectorWidth).measuredForLayout("inspector")
        }.padding(.horizontal, Yun.Space.xl).padding(.bottom, Yun.Space.xs)
    }
    private var observation: some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                YunSelect(selection: $model.selectedEngine, options: [.init(value: "apple", title: loc("Apple on-device AI"), detail: loc("System")), .init(value: "mlx", title: "Qwen 3.5 · 4B", detail: "MLX")])
                    .disabled(model.aiWorking)
                if model.isCameraSource {
                    YunSegmented(selection: $model.observationIntent,
                        options: [(.observe, loc("Observe only")), (.assistFraming, loc("Assist framing"))])
                        .disabled(model.aiWorking)
                } else {
                    YunSelect(selection: Binding(get: { model.imageWorkspace.action }, set: { model.imageWorkspace.action = $0 }), options: [
                        .init(value: .ask, title: loc("Ask about image")),
                        .init(value: .count, title: loc("Count objects")),
                        .init(value: .locate, title: loc("Locate a target"))])
                        .disabled(model.aiWorking)
                }
                Text(model.engineRoleMessage).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: Binding(get: { model.capturingUI ? "" : model.observationQuestion },
                    set: { if !model.capturingUI { model.observationQuestion = $0 } }))
                    .font(Yun.Text.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 68)
                    .padding(Yun.Space.xs)
                    .background(Yun.Palette.elevated, in: .rect(cornerRadius: Yun.Radius.control))
                    .overlay(alignment: .topLeading) {
                        if model.capturingUI || model.observationQuestion.isEmpty {
                            Text(loc(model.isCameraSource ? "Ask about this scene" : "Ask about the image or name the target"))
                                .font(Yun.Text.body).foregroundStyle(Yun.Palette.textMuted)
                                .padding(.horizontal, 9).padding(.vertical, 8)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(loc(model.isCameraSource ? "Ask about this scene" : "Ask about the image or name the target")).measuredForLayout("question")
                HStack {
                    Button(model.observationBusy ? loc("Observing…") : loc("Observe and answer")) { model.ask() }.buttonStyle(YunButtonStyle(.primary, small: true)).disabled(!model.observationReady || model.aiWorking || model.observationQuestion.isEmpty || !model.canAsk)
                    if model.observationBusy { Button(loc("Cancel")) { model.cancelCurrentObservation() }.buttonStyle(YunButtonStyle(.ghost, small: true)) }
                    Spacer(minLength: 0)
                    Button("OCR") { Task { await model.ocr() } }.buttonStyle(YunButtonStyle(.ghost, small: true)).disabled(!model.observationReady || model.aiWorking)
                }
                .measuredForLayout("answerActions")
                if !model.isCameraSource, model.imageWorkspace.resultSnapshot != nil {
                    HStack(spacing: Yun.Space.sm) {
                        Text(loc("Export result")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                        Spacer(minLength: 0)
                        Button(loc("Save Markdown")) { model.exportImageAnalysis(format: .markdown) }
                        Button(loc("Save JSON")) { model.exportImageAnalysis(format: .json) }
                    }.buttonStyle(YunButtonStyle(.ghost, small: true))
                        .disabled(model.capturingUI)
                }
                if !model.canAsk { Text(model.engineMessage).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary) }
                YunDivider()
                ScrollView {
                    VStack(alignment: .leading, spacing: Yun.Space.md) {
                        if model.observationBusy { HStack { ProgressView().controlSize(.mini); Text(loc(model.imageWorkspace.isCancelling ? "Finishing cancellation…" : "Understanding this frame")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textSecondary) } }
                        if model.capturingUI {
                            YunEmptyState(symbol: "eye.slash", message: loc("Analysis hidden for this screenshot")).frame(maxWidth: .infinity)
                        } else {
                        if model.observationAnswer.isEmpty && !model.observationBusy { YunEmptyState(symbol: "sparkles", message: loc("Start with a question about the scene.\nFor example: what does the label say?")).frame(maxWidth: .infinity) }
                        ForEach(Array((model.isCameraSource ? model.observationActions : []).enumerated()), id: \.offset) { _, action in
                            Label(actionTitle(action), systemImage: actionSucceeded(action) ? "checkmark.circle" : "exclamationmark.circle")
                                .font(Yun.Text.caption).foregroundStyle(actionSucceeded(action) ? Yun.Palette.textSecondary : Yun.Palette.warning)
                        }
                        if model.isCameraSource, model.observationRoles?.controllerEngine == "mlx", model.observationRoles?.answerEngine == "apple" {
                            Text(loc("MLX control · Apple visual answer")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                        }
                        if !model.observationAnswer.isEmpty { ObservationPrivateText(text: model.observationAnswer, redacted: model.capturingUI).font(Yun.Text.body).frame(maxWidth: .infinity, alignment: .leading) }
                        ForEach(model.observationEvidence, id: \.self) { Text("· " + $0).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textSecondary) }
                        ForEach(model.observationUncertainties, id: \.self) { Label($0, systemImage: "questionmark.circle").font(Yun.Text.caption).foregroundStyle(Yun.Palette.warning) }
                        if model.isCameraSource, let image = model.evidenceImage {
                            Text(loc("Evidence for this answer")).font(Yun.Text.label).foregroundStyle(Yun.Palette.textSecondary)
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 180, alignment: .leading).clipShape(.rect(cornerRadius: Yun.Radius.control))
                        }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.never).yunScrollFade().frame(maxHeight: .infinity)
            }.frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
    private func actionTitle(_ action: ObservationAction) -> String {
        switch action.tool {
        case "move_gimbal": actionSucceeded(action)
            ? String(format: loc("%@ one step · USB readback confirmed"), loc(["left":"Left", "right":"Right", "up":"Up", "down":"Down"][action.detail] ?? "Camera"))
            : loc("Camera movement was not confirmed.")
        case "camera_zoom_status": loc("Read camera zoom range")
        case "camera_set_zoom": actionSucceeded(action)
            ? String(format: loc("Zoom confirmed · raw %d"), action.zoom?.observed ?? 0)
            : loc("Zoom could not be confirmed.")
        case "read_visible_text": loc("Read visible text")
        case "read_barcodes": loc("Read barcodes")
        case "capture_frame": loc("Captured a fresh image")
        default: loc("Camera operation")
        }
    }
    private func actionSucceeded(_ action: ObservationAction) -> Bool {
        guard action.failureCode == nil else { return false }
        switch action.tool {
        case "camera_set_zoom": return action.zoom?.accepted == true && action.zoom?.verified == true && action.zoom?.completed == true && action.postActionFrame != nil
        case "move_gimbal": return action.motion?.accepted == true && action.motion?.verified == true && action.motion?.completed == true
        default: return true
        }
    }
    private var activity: some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                HStack { Text(loc("Recent activity")).font(Yun.Text.title); Spacer(); Text(loc("Camera actions")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary) }
                if model.status?.activities.isEmpty != false { Text(loc("Camera actions and captures appear here.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary) }
                ForEach(Array((model.status?.activities ?? []).prefix(4))) { item in
                    HStack(alignment: .top, spacing: Yun.Space.sm) {
                        Image(systemName: item.isError ? "exclamationmark.circle" : item.operation == "capture" ? "photo" : "checkmark.circle").font(.system(size: 12)).foregroundStyle(item.isError ? Yun.Palette.warning : Yun.Palette.textTertiary)
                        Text(AppActivityPresentation.message(item)).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textSecondary).lineLimit(2)
                        Spacer(minLength: 0)
                        Text(item.time, style: .time).fixedSize().font(Yun.Text.mono).foregroundStyle(Yun.Palette.textMuted)
                    }
                }
            }.frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        }
    }
    private var engines: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Yun.Space.xl) {
                heading(loc("On-device AI engines"), loc("Choose a model for camera images. Unload it when it is no longer needed."))
                HStack(alignment: .top, spacing: Yun.Space.lg) {
                    engineCard(id: "appleEngine", name: loc("Apple on-device AI"), icon: "apple.logo", subtitle: "Foundation Models 27", status: model.modelStatus?.available == true ? loc("Available") : loc("Not ready")) {
                        VStack(alignment: .leading, spacing: Yun.Space.sm) {
                            Text(loc(model.modelStatus?.detail ?? "Checking the model")).font(Yun.Text.body).foregroundStyle(Yun.Palette.textSecondary)
                            Text(loc("Apple answers from images. AI control also uses the downloaded MLX model."))
                                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                        }
                    } capabilities: {
                        YunWrap(spacing: 6) { YunBadge(loc("Image understanding")); YunBadge(loc("Structured answers")); YunBadge(loc("On-device")) }
                    } actions: {
                        Button(loc("Check again")) { Task { model.modelStatus = await model.intelligence.status() } }.buttonStyle(YunButtonStyle(.secondary, small: true))
                    }
                    engineCard(id: "mlxEngine", name: "Qwen 3.5 · 4B", icon: "square.stack.3d.up", subtitle: "MLX Swift · 4-bit", status: model.localPhaseTitle) {
                        VStack(alignment: .leading, spacing: Yun.Space.sm) {
                            Text(model.localModelDescription).font(Yun.Text.body).foregroundStyle(Yun.Palette.textSecondary)
                            Text(loc("MLX handles camera control and visual answers locally."))
                                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                            if model.localStatus?.phase == "downloading" { ProgressView(value: model.localStatus?.progress ?? 0) }
                        }
                    } capabilities: {
                        YunWrap(spacing: 6) { YunBadge(loc("Vision model")); YunBadge("GPU"); YunBadge("Apache-2.0") }
                    } actions: {
                        if model.localStatus?.phase == "downloading" { Button(loc("Cancel download")) { Task { await model.intelligence.localModel.cancelDownload() } }.buttonStyle(YunButtonStyle(.secondary, small: true)) }
                        else {
                            YunWrap(spacing: 8) {
                                Button(model.localStatus?.available == true ? loc("Load model") : loc("Download model")) { model.prepareLocalModel() }.buttonStyle(YunButtonStyle(.primary, small: true)).disabled(model.aiWorking)
                                if model.localStatus?.hasDownload == true {
                                    Button(loc("Unload")) { Task { do { try await model.intelligence.unloadModel(); await model.refresh() } catch { model.message = AppErrorPresentation.message(error) } } }.buttonStyle(YunButtonStyle(.secondary, small: true)).disabled(model.aiWorking)
                                    Button(loc("Delete download")) { model.confirmDeleteModel = true }.buttonStyle(YunButtonStyle(.ghost, small: true)).disabled(model.aiWorking)
                                }
                            }
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
                heading(loc("Integration"), loc("Use the same camera through MCP and the command line."))
                YunCard {
                    VStack(alignment: .leading, spacing: Yun.Space.md) {
                        HStack { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted").font(Yun.Text.title); Spacer(); Button(loc("Copy configuration")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.mcpConfiguration, forType: .string) }.buttonStyle(YunButtonStyle(.secondary, small: true)) }
                        ScrollView(.horizontal) {
                            Text(model.mcpConfiguration).font(Yun.Text.mono).textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(Yun.Space.lg)
                        .background(Yun.Palette.elevated, in: .rect(cornerRadius: Yun.Radius.control))
                        .measuredForLayout("mcpConfiguration")
                        Text(loc("Choose AI access in the camera window. Closing the window keeps the app in the menu bar; quitting ends the service.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                        YunDivider()
                        HStack {
                            Text(loc("Local connection")).font(Yun.Text.label)
                            Spacer()
                            Button(model.testingBridgeConnection ? loc("Checking…") : loc("Test local connection")) { Task { await model.testBridgeConnection() } }.buttonStyle(YunButtonStyle(.secondary, small: true)).disabled(model.testingBridgeConnection)
                        }
                        if let error = model.bridgeConnectionError {
                            Text(error).font(Yun.Text.caption).foregroundStyle(Yun.Palette.warning).textSelection(.enabled)
                        } else if let checkedAt = model.bridgeConnectionCheckedAt {
                            HStack(spacing: Yun.Space.sm) {
                                Label(loc("Local connection passed"), systemImage: "checkmark.circle").font(Yun.Text.caption).foregroundStyle(Yun.Palette.textSecondary)
                                Text(checkedAt, style: .time).font(Yun.Text.mono).foregroundStyle(Yun.Palette.textMuted)
                            }
                        }
                        Text(loc("Checks this app's local bridge without opening the camera. Configure and test your AI client separately.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                        YunDivider()
                        HStack {
                            Text(loc("Recent MCP requests")).font(Yun.Text.label)
                            Spacer()
                            Text(String(format: loc("%d active requests"), model.mcpRequests.activeCount)).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                        }
                        if model.mcpRequests.recent.isEmpty { Text(loc("No MCP tool requests received this launch.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary) }
                        ForEach(Array(model.mcpRequests.recent.prefix(4))) { entry in
                            HStack(spacing: Yun.Space.sm) {
                                Text(entry.tool).font(Yun.Text.mono)
                                Spacer(minLength: 0)
                                Text(mcpOutcome(entry.outcome)).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textSecondary)
                                Text(entry.startedAt, style: .time).font(Yun.Text.mono).foregroundStyle(Yun.Palette.textMuted)
                            }
                        }
                        Text(loc("Tool requests are reported by the MCP helper. This is not a count of connected or idle AI clients.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                    }
                }

            }.padding(.horizontal, Yun.Space.xl).padding(.bottom, Yun.Space.xl)
        }.scrollIndicators(.never).yunScrollFade()
        .confirmationDialog(loc("Delete the downloaded Qwen model?"), isPresented: $model.confirmDeleteModel) {
            Button(loc("Delete model files"), role: .destructive) { Task { do { try await model.intelligence.deleteModel(); await model.refresh() } catch { model.message = AppErrorPresentation.message(error) } } }
        } message: { Text(loc("Only this app's model download is deleted. You can download it again later.")) }
    }
    private func mcpOutcome(_ outcome: MCPRequestHistory.Outcome) -> String {
        switch outcome {
        case .active: loc("In progress")
        case .succeeded: loc("Succeeded")
        case .failed: loc("Failed")
        case .cancelled: loc("Cancelled")
        }
    }
    private func engineCard<Description: View, Capabilities: View, Actions: View>(
        id: String, name: String, icon: String, subtitle: String, status: String,
        @ViewBuilder description: () -> Description, @ViewBuilder capabilities: () -> Capabilities,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.lg) {
                HStack(alignment: .top, spacing: Yun.Space.md) {
                    Image(systemName: icon).font(.system(size: 23, weight: .light)).frame(width: 36, height: 36).background(Yun.Palette.elevated, in: .rect(cornerRadius: Yun.Radius.control))
                    VStack(alignment: .leading, spacing: 5) { Text(name).font(Yun.Text.title); Text(loc(subtitle)).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary) }
                    Spacer(minLength: 0); YunBadge(status)
                }
                description().fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                capabilities().measuredForLayout(id + "Capabilities")
                actions().measuredForLayout(id + "Actions")
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).measuredForLayout(id)
    }
    private var diagnostics: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Yun.Space.lg) {
                HStack { heading(loc("Diagnostics"), loc("Check the device, received frames and inference results.")); Spacer(); Button(loc("Export diagnostics")) { Task { await model.exportDiagnostics() } }.buttonStyle(YunButtonStyle(.secondary, small: true)) }
                HStack(alignment: .top, spacing: Yun.Space.lg) {
                    YunCard {
                        VStack(alignment: .leading, spacing: Yun.Space.md) {
                            Text(loc("Camera & control")).font(Yun.Text.title)
                            detail(loc("Device"), model.status?.selected?.name ?? loc("None selected"))
                            detail(loc("Permissions"), model.status?.permission ?? loc("Unknown"))
                            detail(loc("Frames received"), "\(model.status?.capture.frames ?? 0)")
                            detail("FPS", String(format: "%.1f", model.status?.capture.recentFPS ?? 0))
                            detail(loc("Stopping behaviour"), loc("Hold the current position and verify readback"))
                            Text(model.status?.stopValidated == true ? loc("AI movement passed the local stopping test.") : loc("AI movement is unavailable until stopping is validated.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                            Button(loc("Validate camera control")) { Task { await model.validateControl() } }
                                .buttonStyle(YunButtonStyle(.secondary, small: true)).disabled(!model.cameraActionReady || model.aiWorking)
                            Text(loc("Runs small round trips and stopping checks for about two minutes. Stop operation cancels the test."))
                                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                            if CommandLine.arguments.contains("--hardware-validation") {
                                USBManualAcceptanceDiagnosticsView(
                                    diagnostics: model.developerUSBManualAcceptanceDiagnostics,
                                    stage: model.developerUSBManualAcceptanceStage,
                                    failure: model.developerUSBManualAcceptanceFailure,
                                    isExpanded: $showUSBManualAcceptance)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }.measuredForLayout("cameraDiagnostics")
                    YunCard {
                        VStack(alignment: .leading, spacing: Yun.Space.md) {
                            Text(loc("Local perception")).font(Yun.Text.title)
                            Text("YOLOS tiny · Core AI").font(Yun.Text.body)
                            Text(loc("Detect common objects on request. Core AI selects the compute device.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                            Button(loc("Detect objects")) { Task { await model.detectObjects() } }.buttonStyle(YunButtonStyle(.primary, small: true)).disabled(!model.cameraActionReady || model.busy)
                            if let p = model.perceptionResult { detail(loc("Inference time"), String(format: "%.2f s", p.inferenceSeconds)); Text(p.objects.map { "\($0.label) \(Int($0.confidence*100))%" }.joined(separator: " · ")).font(Yun.Text.caption); if p.objects.isEmpty { Text(loc("No objects met the confidence threshold.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary) } }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }.measuredForLayout("perceptionDiagnostics")
                }.fixedSize(horizontal: false, vertical: true)
                YunCard {
                    HStack { VStack(alignment: .leading, spacing: 6) { Text(loc("USB audio")).font(Yun.Text.title); Text(model.audioMessage).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary) }; Spacer(); Button(loc("Test for 3 seconds")) { Task { await model.audioTest() } }.buttonStyle(YunButtonStyle(.secondary, small: true)).disabled(!model.cameraActionReady) }
                }
                if let diagnosis = model.powerChargingDiagnosis,
                   diagnosis.usbPresent || diagnosis.batteryPercent != nil {
                    PowerChargingDiagnosticsCard(diagnosis: diagnosis)
                } else if let power = model.status?.power, power.present {
                    YunCard {
                        VStack(alignment: .leading, spacing: Yun.Space.md) {
                            Text(loc("USB power & charging")).font(Yun.Text.title)
                            detail(loc("USB current allocation"), power.configuredMilliamps.map { "\($0) mA" } ?? loc("Unknown"))
                            detail(loc("Battery charging"), loc("Unknown"))
                            Text(loc("USB allocation is not measured charging current. Check the camera's battery indicator; Webcam USB does not report battery charging status to this app."))
                                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if CommandLine.arguments.contains("--hardware-validation") {
                    Pocket3MediaLibraryDiagnostics(model: $model.mediaLibrary)
                }
                if let gimbal = model.status?.gimbal { YunDisclosure(loc("Raw UVC data"), isExpanded: $showUVC) { Text((try? JSONValue.encode(gimbal).pretty) ?? "").font(Yun.Text.mono).textSelection(.enabled) } }
                activity
            }.padding(.horizontal, Yun.Space.xl).padding(.bottom, Yun.Space.lg)
        }.scrollIndicators(.never).yunScrollFade()
    }
    private var footer: some View {
        StatusPills(model: model).padding(.top, Yun.Space.xs)
    }
    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(loc(title)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Yun.Palette.textTertiary).textCase(.uppercase); Text(loc(subtitle)).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary) }
    }
    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(loc(label)).foregroundStyle(Yun.Palette.textTertiary); Spacer(minLength: Yun.Space.md); Text(loc(value)).foregroundStyle(Yun.Palette.textSecondary).textSelection(.enabled).multilineTextAlignment(.trailing) }.font(Yun.Text.caption)
    }
}
