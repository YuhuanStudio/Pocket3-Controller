import Foundation
import AppKit
import Pocket3Core
import YunDesign

/// Owns an explicitly selected wireless camera. Construction does not scan,
/// pair, change Wi-Fi, or create a camera datalink.
@MainActor @Observable
final class WirelessGimbalModel {
    let bluetooth = Pocket3BluetoothDiscovery()
    var discovery: BluetoothDiscoveryStatus
    private(set) var batteryAssessment: BluetoothBatteryAssessment?
    @ObservationIgnored private var batteryMonitor = BluetoothBatteryMonitor()
    var freshBatteryAssessment: BluetoothBatteryAssessment? {
        guard let batteryAssessment,
              batteryAssessment.sessionID == discovery.sessionID,
              batteryAssessment.peripheralID == discovery.selectedPeripheralID,
              batteryAssessment.isFresh(now: Date()) else { return nil }
        return batteryAssessment
    }
    var selectedPeripheral = ""
    var nativeStatus: Pocket3DatalinkStatus?
    /// Credential-free readiness projection shared by native command gates and
    /// UI. `commandReady` is reached only after the existing datalink's
    /// handshake has completed; BLE pairing alone remains `paired`.
    private(set) var nativeSessionStatus: NativeCameraSessionStatus
    /// Developer-only network selection. The default remains the legacy
    /// unbound kernel route; general UI never chooses an adapter.
    private(set) var nativeNetworkConfiguration: Pocket3DatalinkSocketConfiguration = .legacy
    private(set) var nativeRouteStatus: Pocket3DatalinkRouteStatus = .unknown
    var connecting = false
    var joiningNetwork = false
    private(set) var presetBusy = false
    private(set) var nativeBodyValidationBusy = false
    var issue: String?
    private(set) var readingCameraSettings = false
    @ObservationIgnored private var settingsReadTask: Task<Void, Never>?
    @ObservationIgnored private var settingsReadID: UUID?
    private(set) var networkName: String?
    private(set) var hasCredentials = false
    var nativeConnected: Bool { nativeSessionStatus.commandReady }
    /// BLE discovery/telemetry alone never owns the shared manual controls.
    var ownsContinuousControls: Bool { datalink != nil || binding != nil || scheduler != nil || disconnectTask != nil }
    var pairingStatus: BluetoothPairingStatus? { discovery.pairing }
    /// Fresh sparse body-format entries from `camcap_video_format`. The
    /// graph's official resolution families remain visible even when this
    /// readback is unavailable; these entries add only session evidence.
    var bodyRecordingCapabilitySnapshot: [BodyRecordingFormatCapability] {
        let fresh = discovery.cameraSettingsObservations.filter {
            $0.isFresh(now: ProcessInfo.processInfo.systemUptime)
        }
        var result: [BodyRecordingFormatCapability] = []
        if let current = fresh.first(where: { $0.property == .videoParameters }),
           case .videoParameters(let value) = current.readOnlyValue {
            // Keep the selected body format first so presentation can
            // distinguish current state from the legal format table.
            result.append(BodyRecordingFormatCapability(readback: value))
        }
        if let observation = fresh.first(where: { $0.property == .videoFormatCapabilities }),
           let capabilities = observation.bodyRecordingCapabilities {
            result.append(contentsOf: capabilities.entries.map { BodyRecordingFormatCapability(capability: $0) })
        }
        return result
    }
    var capabilityGraph: Pocket3CapabilityGraph {
        Pocket3CapabilityGraph(
            bodyRecordingFormats: Pocket3BodyRecordingCatalog.merging(bodyRecordingCapabilitySnapshot),
            nativeSession: NativeSessionCapability.from(nativeSessionStatus),
            liveSession: .unavailable)
    }
    var nativeConnectionDetail: String? {
        if joiningNetwork { return loc("Joining camera Wi-Fi…") }
        if connecting { return loc("Connecting…") }
        if nativeStatus?.lastErrorCode == "native_feedback_stale" {
            return loc("Camera feedback was lost. Reconnect native control to continue.")
        }
        if nativeStatus?.phase == .disarmed || nativeStatus?.phase == .error {
            return loc("Native control is not ready. Reconnect to continue.")
        }
        if hasCredentials && !nativeConnected {
            return loc("Camera pairing is complete. Connect native control to move the gimbal.")
        }
        return nil
    }
    @ObservationIgnored private var credentials: BluetoothWiFiCredentials?
    @ObservationIgnored private var nativeSession = NativeCameraSession()
    @ObservationIgnored private var nativeSessionBluetoothID: UUID?
    @ObservationIgnored private var datalink: Pocket3Datalink?
    @ObservationIgnored private var scheduler: ContinuousGimbalScheduler?
    @ObservationIgnored private var binding: ContinuousGimbalBinding?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var disconnectTask: Task<Void, Never>?
    @ObservationIgnored private var joinTask: Task<Void, Error>?
    @ObservationIgnored private var joinRequest: CameraWiFiJoinRequest?
    @ObservationIgnored private var joinID: UUID?
    @ObservationIgnored private var presetTask: Task<Void, Never>?
    @ObservationIgnored private var presetPermit: OperationPermit?
    @ObservationIgnored private var presetID: UUID?
    @ObservationIgnored private var nativeBodyValidationPermit: OperationPermit?
    @ObservationIgnored private var selectionOperationID = UUID()
    @ObservationIgnored private let service: CameraService
    @ObservationIgnored private let controls: ContinuousGimbalGestureController
    @ObservationIgnored private let prepareManual: @MainActor () async throws -> Void
    @ObservationIgnored private let clientIdentifier: String

    init(service: CameraService, controls: ContinuousGimbalGestureController,
         prepareManual: @escaping @MainActor () async throws -> Void) {
        self.service = service; self.controls = controls; self.prepareManual = prepareManual
        discovery = bluetooth.status
        nativeSessionStatus = nativeSession.status
        if let saved = UserDefaults.standard.string(forKey: "Pocket3WirelessClientIdentifier"),
           saved.count == 32, saved.allSatisfy(\.isHexDigit) { clientIdentifier = saved }
        else {
            let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            clientIdentifier = value
            UserDefaults.standard.set(value, forKey: "Pocket3WirelessClientIdentifier")
        }
        bluetooth.onStatus = { [weak self] status in self?.applyDiscoveryStatus(status) }
        bluetooth.onCredentials = { [weak self] value in
            guard let self, value.sessionID == self.bluetooth.status.sessionID else { return }
            self.credentials = value
            self.networkName = value.ssid; self.hasCredentials = true
            self.promoteCredentialsIfCurrent()
        }
    }

    func scan() async {
        let selection = UUID(); selectionOperationID = selection
        await disconnectNative()
        guard selectionOperationID == selection, !Task.isCancelled else { return }
        credentials = nil; networkName = nil; hasCredentials = false; selectedPeripheral = ""; issue = nil
        invalidateNativeSession()
        do { try bluetooth.startScan() } catch { issue = AppErrorPresentation.message(error) }
    }
    func connectBluetooth() throws {
        guard !joiningNetwork, !connecting, datalink == nil else { throw BridgeFailure("wireless_busy", loc("Control connection is not ready.")) }
        guard let id = UUID(uuidString: selectedPeripheral) else {
            throw BridgeFailure("bluetooth_selection_required", loc("Select a wireless camera"))
        }
        invalidateNativeSession()
        try bluetooth.connect(peripheralID: id)
        selectionOperationID = UUID()
        credentials = nil; networkName = nil; hasCredentials = false; issue = nil
    }

    /// Developer validation may choose one BSD interface for the next native
    /// connection. Changing this setting never joins Wi-Fi or opens a socket.
    func configureDeveloperNativeNetwork(_ configuration: Pocket3DatalinkSocketConfiguration) throws {
        guard datalink == nil, !connecting, !nativeBodyValidationBusy else {
            throw BridgeFailure("wireless_busy", "Native network selection cannot change during a connection or command")
        }
        nativeNetworkConfiguration = configuration
        nativeRouteStatus = .unknown
    }

    func pair(pairOnly: Bool = true) throws {
        guard !joiningNetwork, !connecting else { throw BridgeFailure("wireless_busy", loc("Control connection is not ready.")) }
        issue = nil
        try bluetooth.beginPairing(clientIdentifier: clientIdentifier, pairOnly: pairOnly)
    }
    /// The button names the network change; developer RPC requires a separate
    /// explicit --join-network argument. Discovery/pairing never calls this.
    func joinCameraNetwork() async throws {
        guard !joiningNetwork, joinTask == nil, !connecting, let credentials else {
            throw BridgeFailure("pairing_required", loc("Pair camera"))
        }
        invalidatePendingOperations()
        let id = UUID(), request = CameraWiFiJoinRequest()
        selectionOperationID = id; joinID = id; joinRequest = request
        joiningNetwork = true; issue = nil
        let work = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer {
                if self.joinID == id {
                    self.joinTask = nil; self.joinRequest = nil; self.joinID = nil
                    self.joiningNetwork = false
                }
            }
            try Task.checkCancellation()
            // This is the join's own preparation; do not cancel this join.
            await self.disconnectNativeOnly()
            try Task.checkCancellation()
            guard self.selectionOperationID == id,
                  self.credentials?.sessionID == credentials.sessionID,
                  self.credentials?.peripheralID == credentials.peripheralID else { throw CancellationError() }
            try await CameraWiFiConnection.join(credentials, request: request)
            try Task.checkCancellation()
            guard self.selectionOperationID == id else { throw CancellationError() }
        }
        joinTask = work
        try await withTaskCancellationHandler { try await work.value } onCancel: {
            request.cancel(); work.cancel()
        }
    }
    func connectNative() async {
        applyDiscoveryStatus(bluetooth.status)
        guard !joiningNetwork, joinTask == nil, !connecting, disconnectTask == nil,
              !nativeBodyValidationBusy, let credentials,
              nativeSessionStatus.isReady(for: .credentials) else { return }
        let selection = UUID(); selectionOperationID = selection
        if datalink != nil {
            // Explicit reconnect is also the recovery path for a disarmed or
            // failed link. Keep the old reservation until its cleanup finishes.
            await disconnectNativeOnly()
            guard selectionOperationID == selection, !Task.isCancelled,
                  self.credentials?.sessionID == credentials.sessionID,
                  self.credentials?.peripheralID == credentials.peripheralID else { return }
        }
        guard datalink == nil, !joiningNetwork, joinTask == nil, disconnectTask == nil,
              selectionOperationID == selection, !Task.isCancelled else { return }
        let routeCheck = Pocket3DatalinkRouteCheckResult.check(
            provider: SystemPocket3DatalinkNetworkObservationProvider(),
            configuration: nativeNetworkConfiguration)
        nativeRouteStatus = routeCheck.plan.status
        guard routeCheck.plan.allowed else {
            let code = routeCheck.plan.failureCode ?? "native_route_invalid"
            issue = AppErrorPresentation.message(BridgeFailure(code,
                "The selected camera network route is not safe for native control."))
            return
        }
        connecting = true; issue = nil
        let attempt = UUID(); generation = attempt
        let readinessGeneration = nativeSessionStatus.generation
        guard nativeSession.beginDatalinkHandshake(generation: readinessGeneration) else {
            connecting = false
            return
        }
        publishNativeSessionStatus()
        let link = Pocket3Datalink(clientIdentifier: clientIdentifier,
            pairedDeviceID: credentials.peripheralID.uuidString,
            networkConfiguration: nativeNetworkConfiguration,
            routePlan: routeCheck.plan)
        datalink = link
        var reservedBinding: ContinuousGimbalBinding?
        do {
            let newBinding = try await link.connect()
            try Task.checkCancellation()
            guard generation == attempt, nativeSession.generation == readinessGeneration,
                  nativeSession.markCommandReady(generation: readinessGeneration) else {
                throw CancellationError()
            }
            publishNativeSessionStatus()
            let scheduler = ContinuousGimbalScheduler(transport: link)
            self.scheduler = scheduler
            try await service.reserveNativeControl(binding: newBinding, readStatus: { [weak self] in
                await self?.controlStatus() ?? .disconnected
            }) { [weak self, controls] in
                await self?.invalidatePendingOperations()
                await controls.stop(reason: .cancelled)
                let state = await scheduler.status()
                if let lease = state.lease {
                    let result = await scheduler.stop(lease, reason: .cancelled)
                    guard result.neutralSent else { throw BridgeFailure("native_neutral_failed", "未能送出雲台中立指令") }
                }
                let result = await link.neutralAndVerify(binding: newBinding)
                let stopStatus = NativeControlStopStatus(result)
                return MotionResult(accepted: stopStatus.neutralSent, completed: stopStatus.stableTelemetry,
                    verified: stopStatus.stableTelemetry, verification: result.verification, target: nil, observed: nil,
                    message: stopStatus.stableTelemetry ? "中立指令後的雲台遙測已穩定；不是機械急停或物理角度校準" : "中立指令與停止遙測尚未完整確認",
                    nativeStop: stopStatus)
            }
            reservedBinding = newBinding
            guard generation == attempt else {
                throw CancellationError()
            }
            binding = newBinding
            await refresh()
        } catch {
            var failureStatus = await link.status()
            failureStatus.phase = .error
            failureStatus.lastErrorCode = (error as? BridgeFailure)?.code ?? (error is CancellationError ? "cancelled" : "native_connect_failed")
            _ = await link.disconnect()
            if let reservedBinding { await service.releaseNativeControl(binding: reservedBinding) }
            if generation == attempt {
                if nativeSession.generation == readinessGeneration {
                    resetNativeSessionToPairingEvidence()
                }
                datalink = nil; scheduler = nil; binding = nil
                nativeStatus = failureStatus
                issue = AppErrorPresentation.message(error)
            }
        }
        if generation == attempt { connecting = false }
    }
    func refresh() async {
        // CoreBluetooth notifications update the receive state at camera rate;
        // publish its scalar snapshot on the existing one-second App refresh.
        applyDiscoveryStatus(bluetooth.status)
        guard let datalink else { return }
        let currentGeneration = generation
        let status = await datalink.status()
        guard generation == currentGeneration else { return }
        nativeStatus = status
        updateNativeSessionFromDatalink(status)
        configureControls()
    }

    func applyDiscoveryStatus(_ status: BluetoothDiscoveryStatus, now: Date = Date()) {
        discovery = status
        updateNativeSessionFromDiscovery(status)
        let paired = status.pairing?.peerReportedPaired == true
        batteryAssessment = batteryMonitor.update(observation: paired ? status.battery : nil,
            sessionID: status.sessionID, peripheralID: status.selectedPeripheralID, now: now)
    }

    private func publishNativeSessionStatus() {
        nativeSessionStatus = nativeSession.status
    }

    private func invalidateNativeSession() {
        _ = nativeSession.invalidate()
        nativeSessionBluetoothID = nil
        publishNativeSessionStatus()
    }

    /// Fences the readiness state to the exact Bluetooth discovery session.
    /// A status callback from a finished scan or old peripheral can therefore
    /// never restore pairing/command readiness for the current session.
    private func updateNativeSessionFromDiscovery(_ status: BluetoothDiscoveryStatus) {
        let active: Bool
        switch status.phase {
        case .connecting, .discoveringServices, .discoveringCharacteristics, .subscribing,
             .gattConnectedUnauthenticated, .pairing, .awaitingPairingApproval,
             .retrievingCredentials, .gattPaired:
            active = status.selectedPeripheralID != nil
        default:
            active = false
        }
        guard active else {
            if nativeSession.state != .disconnected { invalidateNativeSession() }
            else { nativeSessionBluetoothID = nil; publishNativeSessionStatus() }
            return
        }

        if nativeSessionBluetoothID != status.sessionID {
            _ = nativeSession.begin(sessionID: status.sessionID, peerID: status.selectedPeripheralID)
            nativeSessionBluetoothID = status.sessionID
        }
        let currentGeneration = nativeSession.generation
        if status.pairing?.peerReportedPaired == true, nativeSession.state == .disconnected {
            _ = nativeSession.markPaired(generation: currentGeneration)
        }
        if (status.pairing?.credentialsAvailable == true || credentials != nil),
           nativeSession.state == .paired {
            _ = nativeSession.markCredentialsAvailable(generation: currentGeneration)
        }
        publishNativeSessionStatus()
    }

    private func promoteCredentialsIfCurrent() {
        applyDiscoveryStatus(bluetooth.status)
        guard nativeSession.state == .paired || nativeSession.state == .credentialsAvailable else { return }
        _ = nativeSession.markCredentialsAvailable(generation: nativeSession.generation)
        publishNativeSessionStatus()
    }

    /// Maps the existing transport lifecycle into the higher-level session.
    /// `Pocket3DatalinkPhase.ready` is accepted only after this exact session
    /// entered `datalinkHandshaking`; it never promotes BLE pairing directly.
    private func updateNativeSessionFromDatalink(_ status: Pocket3DatalinkStatus) {
        guard nativeSessionBluetoothID == discovery.sessionID,
              nativeSession.sessionID == discovery.sessionID else { return }
        let currentGeneration = nativeSession.generation
        _ = nativeSession.observeDatalink(status.phase, generation: currentGeneration)
        publishNativeSessionStatus()
    }

    /// Starts a fresh native-attempt generation while retaining only pairing
    /// evidence that still belongs to the selected BLE session.
    private func resetNativeSessionToPairingEvidence() {
        guard let sessionID = nativeSessionBluetoothID,
              sessionID == discovery.sessionID else {
            invalidateNativeSession()
            return
        }
        _ = nativeSession.begin(sessionID: sessionID, peerID: discovery.selectedPeripheralID)
        let currentGeneration = nativeSession.generation
        if discovery.pairing?.peerReportedPaired == true {
            _ = nativeSession.markPaired(generation: currentGeneration)
        }
        if discovery.pairing?.credentialsAvailable == true || credentials != nil {
            _ = nativeSession.markCredentialsAvailable(generation: currentGeneration)
        }
        publishNativeSessionStatus()
    }

    /// Read-only callback for the reserved native control owner. It does not
    /// configure controls, open sockets, reconnect, or associate with USB.
    func controlStatus() async -> NativeControlStatus {
        let connection = generation, expectedBinding = binding
        let currentLink = datalink, currentScheduler = scheduler
        // Include executor return delays conservatively, so a suspended status
        // read cannot make old feedback appear fresh when it reaches MainActor.
        let sampledAt = ProcessInfo.processInfo.systemUptime
        let transport = await currentLink?.status()
        let schedulerStatus = await currentScheduler?.status()
        guard generation == connection, datalink === currentLink,
              scheduler === currentScheduler, binding == expectedBinding else { return .connectionChanged }
        return NativeControlStatus(transport: transport, scheduler: schedulerStatus,
            expectedBinding: expectedBinding, holding: controls.isHolding,
            starting: controls.isStarting, stopping: controls.isStopping,
            presetPending: presetBusy, controlsAvailable: controls.canInteract,
            connectionPending: connecting,
            ageAdjustment: ProcessInfo.processInfo.systemUptime - sampledAt)
    }
    private func configureControls() {
        guard datalink != nil, let scheduler, let binding else { return }
        controls.configure(scheduler: scheduler, binding: binding,
                           availability: presetBusy ? .blocked(loc("Finishing camera action…")) : nativeSessionStatus.isReady(for: .gimbal) ? .ready : .blocked(loc("Control connection is not ready.")),
                           prepare: { [weak self] in
                               guard let self else { throw CancellationError() }
                               self.cancelPreset()
                               try Task.checkCancellation()
                               try await self.prepareManual()
                           })
    }
    /// MainActor entry fence for global Stop, before its first suspension.
    /// Cancellation cannot undo CoreWLAN association after its commit point;
    /// joinTask remains tracked until the blocking call has actually returned.
    func readCameraSettings() {
        guard settingsReadTask == nil, discovery.phase == .gattPaired, pairingStatus?.peerReportedPaired == true else { return }
        let id = UUID(), session = discovery.sessionID, peer = discovery.selectedPeripheralID
        settingsReadID = id; readingCameraSettings = true; issue = nil
        settingsReadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.settingsReadID == id {
                    self.settingsReadTask = nil; self.settingsReadID = nil; self.readingCameraSettings = false
                }
            }
            do {
                for property in CameraSettingsProperty.allCases {
                    try Task.checkCancellation()
                    guard self.discovery.sessionID == session, self.discovery.selectedPeripheralID == peer else { throw CancellationError() }
                    let result = try await self.bluetooth.queryCameraProperty(property: property)
                    try Task.checkCancellation()
                    guard !result.cancelled, !result.connectionChanged,
                          self.discovery.sessionID == session, self.discovery.selectedPeripheralID == peer else { throw CancellationError() }
                    guard result.failure == nil, result.propertyReceived else {
                        throw BridgeFailure("camera_settings_unavailable", "The camera property was not received")
                    }
                    await self.refresh()
                }
            } catch {
                guard !(error is CancellationError), self.settingsReadID == id else { return }
                self.issue = AppErrorPresentation.message(error, fallback: .cameraSettingsUnavailable)
            }
        }
    }

    func invalidatePendingOperations() {
        settingsReadTask?.cancel()
        bluetooth.cancelNativeProbe()
        nativeBodyValidationPermit?.invalidate()
        cancelPreset()
        joinRequest?.cancel(); joinTask?.cancel()
    }
    private func cancelPreset() { presetPermit?.invalidate(); presetTask?.cancel() }
    func disconnectNative() async {
        invalidatePendingOperations()
        _ = await bluetooth.stopNativeProbe()
        let pendingJoin = joinTask
        await disconnectNativeOnly()
        _ = try? await pendingJoin?.value
    }
    private func disconnectNativeOnly() async {
        cancelPreset()
        if let disconnectTask { await disconnectTask.value; return }
        let oldLink = datalink, oldBinding = binding, oldScheduler = scheduler
        generation = UUID()
        guard oldLink != nil || oldBinding != nil || oldScheduler != nil else {
            nativeStatus = nil; connecting = false
            if nativeSession.state == .datalinkHandshaking || nativeSession.state == .commandReady || nativeSession.state == .liveReady {
                resetNativeSessionToPairingEvidence()
            }
            return // No native owner: leave the USB scheduler/gesture intact.
        }
        connecting = true
        let attempt = generation
        datalink = nil; binding = nil; nativeStatus = nil; scheduler = nil
        resetNativeSessionToPairingEvidence()
        controls.configure(scheduler: nil, binding: nil, availability: .disconnected, prepare: prepareManual)
        let cleanup = Task { [controls, service] in
            await controls.stop(reason: .cancelled)
            if let oldScheduler, let lease = await oldScheduler.status().lease { _ = await oldScheduler.stop(lease, reason: .cancelled) }
            if let oldLink { _ = await oldLink.disconnect() }
            if let oldBinding { await service.releaseNativeControl(binding: oldBinding) }
        }
        disconnectTask = cleanup
        await cleanup.value
        if generation == attempt { disconnectTask = nil; connecting = false }
    }
    func disconnect() async {
        let selection = UUID(); selectionOperationID = selection
        await disconnectNative()
        guard selectionOperationID == selection else { return }
        bluetooth.disconnect(); credentials = nil; networkName = nil; hasCredentials = false; selectedPeripheral = ""
        invalidateNativeSession()
    }
    func preset(flip: Bool) async {
        guard !presetBusy, !joiningNetwork, !connecting, let datalink, let binding,
              nativeSessionStatus.isReady(for: .gimbalPreset) else { return }
        let id = UUID(), permit = OperationPermit(), connection = generation
        presetID = id; presetPermit = permit; presetBusy = true
        configureControls()
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.presetID == id {
                    self.presetTask = nil; self.presetPermit = nil; self.presetID = nil; self.presetBusy = false
                    self.configureControls()
                }
            }
            do {
                try permit.perform {}
                guard self.generation == connection, self.binding == binding, self.datalink === datalink else { throw CancellationError() }
                await self.controls.stop(reason: .cancelled)
                try permit.perform {}
                guard self.generation == connection, self.binding == binding, self.datalink === datalink else { throw CancellationError() }
                // Use the base takeover; the gesture wrapper cancels presets.
                try await self.prepareManual()
                try permit.perform {}
                guard self.generation == connection, self.binding == binding, self.datalink === datalink else { throw CancellationError() }
                if flip { _ = try await datalink.flip(binding: binding, permit: permit) }
                else { _ = try await datalink.recenter(binding: binding, permit: permit) }
            } catch {
                if self.presetID == id, self.generation == connection, !Task.isCancelled { self.issue = AppErrorPresentation.message(error) }
            }
        }
        presetTask = work
        await withTaskCancellationHandler { await work.value } onCancel: {
            permit.invalidate(); work.cancel()
        }
    }

    /// Returns an executor bound to this model's existing datalink owner.
    /// The adapter is intentionally unavailable before the native session is
    /// command-ready; it never creates a link or joins a network.
    func nativeBodyValidationAdapter() -> NativeBodyValidationExecutorAdapter? {
        guard nativeSessionStatus.commandReady else { return nil }
        let expectedReadiness = nativeSessionStatus
        let expectedConnection = generation
        let expectedLink = datalink
        return NativeBodyValidationExecutorAdapter { [weak self] request, readiness in
            guard let self else {
                throw NativeCommandTransactionError.datalinkUnavailable
            }
            return try await self.executeNativeBodyValidation(request,
                readiness: readiness, expectedReadiness: expectedReadiness,
                expectedConnection: expectedConnection, expectedLink: expectedLink)
        }
    }

    /// Returns the same single-owner transaction boundary for the native
    /// four-step tap-AF coordinator. The coordinator remains responsible for
    /// order and step ACKs; this model only supplies the existing datalink
    /// transaction fence.
    func nativeTapFocusValidationAdapter() -> NativeTapFocusValidationExecutorAdapter? {
        guard nativeSessionStatus.commandReady else { return nil }
        let expectedReadiness = nativeSessionStatus
        let expectedConnection = generation
        let expectedLink = datalink
        return NativeTapFocusValidationExecutorAdapter { [weak self] request, readiness in
            guard let self else {
                throw NativeCommandTransactionError.datalinkUnavailable
            }
            return try await self.executeNativeBodyValidation(request,
                readiness: readiness, expectedReadiness: expectedReadiness,
                expectedConnection: expectedConnection, expectedLink: expectedLink)
        }
    }

    /// Reuses the same single-owner transaction boundary for the audio DSP
    /// GET/SET/GET validator. The audio coordinator owns its three-step order;
    /// this model only fences each individual transaction to the current link.
    func nativeAudioDSPValidationAdapter() -> NativeAudioDSPValidationExecutorAdapter? {
        guard nativeSessionStatus.commandReady else { return nil }
        let expectedReadiness = nativeSessionStatus
        let expectedConnection = generation
        let expectedLink = datalink
        return NativeAudioDSPValidationExecutorAdapter { [weak self] request, readiness in
            guard let self else {
                throw NativeCommandTransactionError.datalinkUnavailable
            }
            return try await self.executeNativeBodyValidation(request,
                readiness: readiness, expectedReadiness: expectedReadiness,
                expectedConnection: expectedConnection, expectedLink: expectedLink)
        }
    }

    /// Returns the same single-owner transaction boundary for native zoom and
    /// gimbal validation. The adapter never creates a datalink or obtains a
    /// second connection; the motion service owns the one-request/readback
    /// policy.
    func nativeMotionValidationAdapter() -> NativeMotionValidationExecutorAdapter? {
        guard nativeSessionStatus.commandReady else { return nil }
        let expectedReadiness = nativeSessionStatus
        let expectedConnection = generation
        let expectedLink = datalink
        return NativeMotionValidationExecutorAdapter { [weak self] request, readiness in
            guard let self else {
                throw NativeCommandTransactionError.datalinkUnavailable
            }
            return try await self.executeNativeBodyValidation(request,
                readiness: readiness, expectedReadiness: expectedReadiness,
                expectedConnection: expectedConnection, expectedLink: expectedLink)
        }
    }

    /// Returns the same single-owner transaction boundary for native WB,
    /// focus, color and Product Showcase validation. It never creates another
    /// datalink; the setting service owns the one-request/readback policy.
    func nativeSettingValidationAdapter() -> NativeSettingValidationExecutorAdapter? {
        guard nativeSessionStatus.commandReady else { return nil }
        let expectedReadiness = nativeSessionStatus
        let expectedConnection = generation
        let expectedLink = datalink
        return NativeSettingValidationExecutorAdapter { [weak self] request, readiness in
            guard let self else {
                throw NativeCommandTransactionError.datalinkUnavailable
            }
            return try await self.executeNativeBodyValidation(request,
                readiness: readiness, expectedReadiness: expectedReadiness,
                expectedConnection: expectedConnection, expectedLink: expectedLink)
        }
    }

    /// Returns the same single-owner transaction boundary for native camera
    /// capture validation. It never creates a datalink or performs a read;
    /// the capture service supplies fresh status/property evidence and invokes
    /// this adapter at most once when `--execute` is explicit.
    func nativeCameraCaptureValidationAdapter()
        -> NativeCameraCaptureValidationExecutorAdapter? {
        guard nativeSessionStatus.commandReady else { return nil }
        let expectedReadiness = nativeSessionStatus
        let expectedConnection = generation
        let expectedLink = datalink
        return NativeCameraCaptureValidationExecutorAdapter { [weak self] request, readiness in
            guard let self else {
                throw NativeCommandTransactionError.datalinkUnavailable
            }
            return try await self.executeNativeBodyValidation(request,
                readiness: readiness, expectedReadiness: expectedReadiness,
                expectedConnection: expectedConnection,
                expectedLink: expectedLink)
        }
    }

    /// Reuses the single command-ready datalink owner for read-only media
    /// browsing validation. The list observation closure collects bounded
    /// 00/27 chunks; this adapter only submits the one prepared 00/26 request.
    func nativeMediaValidationAdapter()
        -> NativeMediaValidationExecutorAdapter? {
        guard nativeSessionStatus.commandReady else { return nil }
        let expectedReadiness = nativeSessionStatus
        let expectedConnection = generation
        let expectedLink = datalink
        return NativeMediaValidationExecutorAdapter { [weak self] request, readiness in
            guard let self else {
                throw NativeCommandTransactionError.datalinkUnavailable
            }
            return try await self.executeNativeBodyValidation(request,
                readiness: readiness, expectedReadiness: expectedReadiness,
                expectedConnection: expectedConnection,
                expectedLink: expectedLink)
        }
    }

    /// Reuses the single command-ready datalink owner for the advanced-setting
    /// validation service. The service supplies the exact request and owns the
    /// ACK/readback policy; this adapter never creates another transport.
    func nativeAdvancedSettingValidationAdapter()
        -> NativeAdvancedSettingValidationExecutorAdapter? {
        guard nativeSessionStatus.commandReady else { return nil }
        let expectedReadiness = nativeSessionStatus
        let expectedConnection = generation
        let expectedLink = datalink
        return NativeAdvancedSettingValidationExecutorAdapter { [weak self] request, readiness in
            guard let self else {
                throw NativeCommandTransactionError.datalinkUnavailable
            }
            return try await self.executeNativeBodyValidation(request,
                readiness: readiness, expectedReadiness: expectedReadiness,
                expectedConnection: expectedConnection,
                expectedLink: expectedLink)
        }
    }

    /// Executes exactly one already-prepared transaction through the current
    /// Pocket3Datalink owner.  The surrounding service owns command-specific
    /// readback rules; this method owns model-level identity and busy fences.
    private func executeNativeBodyValidation(
        _ request: NativeCommandTransactionRequest,
        readiness: NativeCameraSessionStatus,
        expectedReadiness: NativeCameraSessionStatus,
        expectedConnection: UUID,
        expectedLink: Pocket3Datalink?
    ) async throws -> NativeCommandTransactionResult {
        guard nativeSessionStatus == expectedReadiness,
              nativeSessionStatus.generation == request.generation,
              request.sessionID == nativeSessionStatus.sessionID,
              generation == expectedConnection,
              datalink === expectedLink,
              !connecting, !joiningNetwork else {
            throw NativeCommandTransactionError.staleGeneration
        }
        guard !presetBusy else { throw NativeCommandTransactionError.nativeBusy }
        guard let link = expectedLink,
              nativeStatus?.phase == .ready else {
            throw NativeCommandTransactionError.datalinkUnavailable
        }
        guard !nativeBodyValidationBusy else {
            throw NativeCommandTransactionError.nativeBusy
        }
        nativeBodyValidationBusy = true
        let permit = OperationPermit()
        nativeBodyValidationPermit = permit
        defer {
            if nativeBodyValidationPermit === permit { nativeBodyValidationPermit = nil }
            permit.invalidate()
            nativeBodyValidationBusy = false
        }
        var result = try await link.transact(request, readiness: readiness, permit: permit)
        // Pocket3Datalink already fences its owner queue. Re-check the model
        // fence as well so a reconnect cannot let a late result complete the
        // old coordinator. Preserve all submitted/ACK/readback fields as
        // partial evidence while changing only the terminal classification.
        guard nativeSessionStatus == expectedReadiness,
              nativeSessionStatus.generation == request.generation,
              generation == expectedConnection, datalink === link else {
            result.end = .generationChanged
            result.failureCode = "native_body_connection_changed"
            result.finishedUptime = result.finishedUptime ?? ProcessInfo.processInfo.systemUptime
            return result
        }
        return result
    }

    /// Only scalar status leaves this model. Credentials stay in memory and
    /// are never present in RPC, diagnostics exports, logs or clipboard data.
    func validationStatus() throws -> JSONValue {
        .object(["bluetooth": try .encode(discovery),
                 "native": try nativeStatus.map(JSONValue.encode) ?? .null,
                 "nativeReadiness": try .encode(nativeSessionStatus),
                 "nativeNetworkConfiguration": try .encode(nativeNetworkConfiguration),
                 "nativeRouteStatus": try .encode(nativeRouteStatus),
                 "nativeBodyValidationBusy": .bool(nativeBodyValidationBusy),
                 "capabilities": try .encode(capabilityGraph),
                 "credentialsAvailable": .bool(credentials != nil)])
    }
}
