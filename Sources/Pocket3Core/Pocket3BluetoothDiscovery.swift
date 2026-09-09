import Foundation
import AppKit
@preconcurrency import CoreBluetooth

public struct BluetoothDUMLObservation: Sendable {
    public let sessionID: UUID
    public let peripheralID: UUID
    public let characteristic: String
    public let receivedAt: Date
    public let packet: ValidatedDUMLPacket
}

/// Explicit discovery, GATT subscription, and operator-initiated pairing.
/// FFF0 is not a verified model identity and is never associated with USB here.
/// The containing app needs NSBluetoothAlwaysUsageDescription before startScan.
@MainActor
public final class Pocket3BluetoothDiscovery: NSObject, @preconcurrency CBCentralManagerDelegate {
    public var onStatus: (@MainActor @Sendable (BluetoothDiscoveryStatus) -> Void)?
    public var onFrame: (@MainActor @Sendable (BluetoothDUMLObservation) -> Void)?
    public var onCredentials: (@MainActor @Sendable (BluetoothWiFiCredentials) -> Void)?
    public var pairingStatus: BluetoothPairingStatus? { pairer?.status }
    public var isBluetoothInitialized: Bool { central != nil }

    // Mapping checked against Kaze for DJI, revision
    // 341a35de18493ff61f97c93b8b10161a7512aa36,
    // ios/Pocket3Controller/Pocket3BLEManager.swift, lines 173–183, 212–225,
    // 553–612: FFF4 notifies + writes with response; FFF5 notifies + writes
    // without response. Pairing writes require explicit beginPairing().
    private static let serviceID = CBUUID(string: "FFF0")
    private static let fff4ID = CBUUID(string: "FFF4")
    private static let fff5ID = CBUUID(string: "FFF5")
    private var central: CBCentralManager?
    private var state = BluetoothDiscoveryState()
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var selectedPeripheral: CBPeripheral?
    private var peripheralDelegate: BluetoothPeripheralDelegate?
    private var selectedService: CBService?
    private var fff4: CBCharacteristic?
    private var fff5: CBCharacteristic?
    private var fff4Notifying = false
    private var fff5Notifying = false
    private var fff4Properties: UInt?
    private var fff5Properties: UInt?
    private var decoders: [String: DUMLFragmentDecoder] = [:]
    private var receivedFrames = 0
    private var deadlineTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var pairer: BluetoothPairingSession?
    private var pairingTasks: [Task<Void, Never>] = []
    private var keepaliveTask: Task<Void, Never>?
    private var writeQueue = BluetoothWriteQueue()
    private var battery: BluetoothBatteryObservation?
    private var poseStore = BluetoothPoseStore()
    private var cameraSettingsStore = BluetoothCameraSettingsStore()
    private var recentHeaders: [BluetoothDUMLHeader] = []
    private var registrationAcknowledgmentSession: UUID?
    private var probeOperation: BluetoothProbeOperation?
    private var probeTask: Task<BluetoothGimbalProbeResult, Never>?
    private var readinessOperation: BluetoothReadinessOperation?
    private var readinessTask: Task<BluetoothReadinessResult, Never>?
    private var nativePresetOperation: BluetoothNativePresetOperation?
    private var nativePresetTask: Task<BluetoothNativeRecenterResult, Never>?
    private var lensStateOperation: BluetoothLensStateOperation?
    private var lensStateTask: Task<BluetoothLensStateQueryResult, Never>?
    private var cameraPropertyOperation: BluetoothCameraPropertyOperation?
    private var cameraPropertyTask: Task<BluetoothCameraPropertyQueryResult, Never>?
    private var settingWriteOperation: BluetoothSettingWriteOperation?
    private var settingWriteTask: Task<BluetoothCameraSettingWriteResult, Never>?
    private var tapFocusOperation: BluetoothTapFocusOperation?
    private var tapFocusTask: Task<BluetoothTapFocusResult, Never>?
    private var lensPointOperation: BluetoothLensPointOperation?
    private var lensPointTask: Task<BluetoothFocusPointRecording, Never>?

    public override init() { super.init() } // Does not create a CBCentralManager.

    public var status: BluetoothDiscoveryStatus {
        var result = BluetoothDiscoveryStatus(phase: state.phase, sessionID: state.generation,
            candidates: state.candidates, selectedPeripheralID: state.selected,
            issueCode: state.issueCode, identityVerification: "unverified_candidate",
            authentication: pairer?.paired == true ? "protocol_pair_confirmed" :
                pairer?.status.peerReportedPaired == true ? "protocol_pair_previously_confirmed" :
                pairer == nil ? "not_performed" : "unconfirmed", fff4NotificationEnabled: fff4Notifying,
            fff5NotificationEnabled: fff5Notifying, fff4Properties: fff4Properties,
            fff5Properties: fff5Properties, receivedFrames: receivedFrames,
            fragments: decoders.mapValues(\.statistics), pairing: pairingStatus,
            battery: battery.flatMap { $0.telemetry.isFresh(now: Date()) ? $0 : nil }, recentHeaders: recentHeaders)
        result.registrationAcknowledgmentSubmitted = registrationAcknowledgmentSession != nil
        result.pose = poseStore.snapshot(sessionID: state.generation, peripheralID: state.selected,
            paired: pairer?.paired == true, nowUptime: ProcessInfo.processInfo.systemUptime)
        result.cameraSettingsObservations = cameraSettingsStore.snapshot(sessionID: state.generation, peripheralID: state.selected,
            paired: pairer?.paired == true, nowUptime: ProcessInfo.processInfo.systemUptime)
        result.nativeProbeActive = settingWriteOperation != nil || tapFocusOperation != nil || probeOperation != nil || nativePresetOperation != nil || lensStateOperation != nil || cameraPropertyOperation != nil || lensPointOperation != nil
        result.authorization = switch CBManager.authorization {
        case .allowedAlways: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
        return result
    }

    /// A fresh explicit request creates a fresh manager. Old manager callbacks
    /// cannot be mistaken for a new scan or connection to the same UUID.
    public func startScan() throws {
        cancelCameraSettingWrite()
        cancelTapFocusProbe()
        cancelLensPointRecording()
        cancelLensStateQuery(); cancelCameraPropertyQuery()
        cancelNativeRecenter()
        guard settingWriteOperation == nil, tapFocusOperation == nil, probeOperation == nil else { throw BridgeFailure("bluetooth_probe_busy", "Stop the active BLE probe before scanning.") }
        disconnect()
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state.finish(.failed, issue: "bluetooth_usage_description_missing"); publish()
            throw BridgeFailure("bluetooth_usage_description_missing", "The app must declare its Bluetooth usage before discovery.")
        }
        switch CBManager.authorization {
        case .denied, .restricted:
            state.finish(.unauthorized, issue: "bluetooth_permission_denied"); publish(); return
        case .allowedAlways, .notDetermined: break
        @unknown default:
            state.finish(.unauthorized, issue: "bluetooth_authorization_unknown"); publish(); return
        }
        let session = state.beginScan()
        poseStore.clear()
        cameraSettingsStore.clear()
        decoders = [:]; receivedFrames = 0; fff4Properties = nil; fff5Properties = nil; pairer = nil; battery = nil; recentHeaders = []; registrationAcknowledgmentSession = nil
        deadlineTask = Task { @MainActor [weak self] in
            // First-run authorization is a separate, bounded operator wait.
            // It must not consume the actual radio discovery budget.
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            guard let self, session == self.state.generation,
                  self.state.phase == .waitingForBluetooth else { return }
            self.close(phase: .failed, issue: "bluetooth_start_timeout")
        }
        // nil queue is the main queue. Delegate conformances explicitly use
        // MainActor; no non-Sendable CoreBluetooth objects cross actor queues.
        let manager = CBCentralManager(delegate: self, queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
        central = manager
        updateRadio(manager)
        publish()
    }

    /// Stop discovery but retain this scan's candidates for explicit selection.
    public func stopScan() {
        if state.phase == .waitingForBluetooth { disconnect(); return }
        guard state.phase == .scanning else { return }
        central?.stopScan(); deadlineTask?.cancel(); deadlineTask = nil
        _ = state.transition(from: .scanning, to: .scanComplete, session: state.generation)
        publish()
    }

    /// Connects only a UUID discovered during the current explicit scan.
    /// The 8-second limit includes service discovery and notification setup.
    public func connect(peripheralID: UUID) throws {
        cancelCameraSettingWrite()
        cancelTapFocusProbe()
        cancelLensPointRecording()
        cancelLensStateQuery(); cancelCameraPropertyQuery()
        cancelNativeRecenter()
        guard settingWriteOperation == nil, tapFocusOperation == nil, probeOperation == nil else { throw BridgeFailure("bluetooth_probe_busy", "Stop the active BLE probe before connecting.") }
        guard let central, central.state == .poweredOn,
              let peripheral = peripherals[peripheralID],
              let session = state.select(peripheralID) else {
            throw BridgeFailure("bluetooth_selection_required", "Select a connectable candidate from the current Bluetooth scan.")
        }
        central.stopScan(); deadlineTask?.cancel()
        poseStore.bind(sessionID: session, peripheralID: peripheralID)
        cameraSettingsStore.bind(sessionID: session, peripheralID: peripheralID)
        selectedPeripheral = peripheral
        let delegate = BluetoothPeripheralDelegate(owner: self, session: session)
        peripheralDelegate = delegate; peripheral.delegate = delegate
        deadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, session == self.state.generation else { return }
            self.close(phase: .failed, issue: "bluetooth_gatt_timeout")
        }
        central.connect(peripheral, options: nil)
        publish()
    }

    public func disconnect() { close(phase: .disconnected, issue: nil) }

    /// The app supplies one persistent UUID32 identifier, also used by its
    /// wireless datalink. No shared/default vendor identifier is transmitted.
    public func beginPairing(clientIdentifier: String, pairOnly: Bool = true) throws {
        cancelCameraSettingWrite()
        cancelTapFocusProbe()
        cancelLensPointRecording()
        cancelLensStateQuery(); cancelCameraPropertyQuery()
        cancelNativeRecenter()
        guard settingWriteOperation == nil, tapFocusOperation == nil, probeOperation == nil else { throw BridgeFailure("bluetooth_probe_busy", "Stop the active BLE probe before pairing.") }
        guard state.phase == .gattConnectedUnauthenticated, pairer == nil,
              let peripheral = selectedPeripheral, let fff4, let fff5,
              fff4Notifying, fff5Notifying, peripheral.state == .connected,
              fff4.properties.contains(.write), fff5.properties.contains(.writeWithoutResponse) else {
            throw BridgeFailure("bluetooth_gatt_required", "Select and connect a Bluetooth candidate before starting pairing.")
        }
        pairer = try BluetoothPairingSession(clientIdentifier: clientIdentifier,
            initialSequence: UInt16.random(in: 0x8000...0xf000), pairOnly: pairOnly)
        let session = state.generation
        _ = state.transition(from: .gattConnectedUnauthenticated, to: .pairing, session: session)
        schedulePairing(after: 8, session: session) { owner in
            if owner.pairer?.phase == .arming { owner.close(phase: .failed, issue: "bluetooth_pair_arm_timeout") }
        }
        schedulePairing(after: 60, session: session) { owner in
            if ![.paired, .credentialsReady].contains(owner.pairer?.phase ?? .idle) { owner.close(phase: .failed, issue: "bluetooth_pairing_timeout") }
        }
        peripheral.writeValue(Data([1, 0]), for: fff4, type: .withResponse)
        publish()
    }
    public func cancelPairing() { disconnect() }

    /// Developer-only fixed BLE experiment. The caller must reserve exclusive
    /// control in CameraService first, fencing all USB position writes.
    public func probeNativeJoystick(permit: OperationPermit = OperationPermit()) async throws -> BluetoothGimbalProbeResult {
        try permit.perform {}
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled", "BLE joystick probing requires a development launch.")
        }
        guard settingWriteOperation == nil, tapFocusOperation == nil, probeOperation == nil, probeTask == nil, readinessOperation == nil, nativePresetOperation == nil, lensStateOperation == nil, cameraPropertyOperation == nil, lensPointOperation == nil else { throw BridgeFailure("bluetooth_probe_busy", "A BLE probe or readiness query is already running.") }
        guard state.phase == .gattPaired, pairer?.paired == true,
              [.paired, .credentialsReady].contains(pairer?.phase ?? .idle),
              registrationAcknowledgmentSession == state.generation,
              let central, central.state == .poweredOn,
              let peripheral = selectedPeripheral, peripheral.state == .connected,
              let fff5, fff5.isNotifying, fff5.properties.contains(.writeWithoutResponse),
              peripheral.maximumWriteValueLength(for: .withoutResponse) >= BluetoothGimbalProbePlan.frameBytes,
              peripheral.canSendWriteWithoutResponse, writeQueue.isEmpty,
              let sequences = pairer?.reserveProbeSequences() else {
            throw BridgeFailure("bluetooth_probe_not_ready", "The current peer must confirm pairing, the APP registration reply must be submitted, and GATT must be ready before this probe.")
        }
        let operation = try BluetoothProbeOperation(session: state.generation, central: central,
            peripheral: peripheral, characteristic: fff5, sequences: sequences, permit: permit)
        probeOperation = operation
        let work = Task<BluetoothGimbalProbeResult, Never>(priority: .userInitiated) { @MainActor [self] in
            await runProbe(operation)
        }
        probeTask = work
        operation.focusObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { _ in permit.invalidate(); work.cancel() }
        return await withTaskCancellationHandler { await work.value } onCancel: {
            permit.invalidate(); work.cancel()
        }
    }

    /// Returns only the cleanup result of the probe that was active at entry.
    /// Nil does not imply a neutral command was sent.
    public func stopNativeProbe() async -> BluetoothGimbalProbeResult? {
        let operation = probeOperation, work = probeTask
        let lensQuery = lensStateTask
        let propertyQuery = cameraPropertyTask
        let lensPoints = lensPointTask
        let tapFocus = tapFocusTask
        let settingWrite = settingWriteTask
        cancelCameraSettingWrite()
        cancelTapFocusProbe()
        cancelLensPointRecording()
        cancelLensStateQuery(); cancelCameraPropertyQuery()
        operation?.permit.invalidate(); work?.cancel()
        cancelNativeRecenter()
        let preset = nativePresetTask
        if let preset { _ = await preset.value }
        if let lensQuery { _ = await lensQuery.value }
        if let propertyQuery { _ = await propertyQuery.value }
        if let lensPoints { _ = await lensPoints.value }
        if let tapFocus { _ = await tapFocus.value }
        if let settingWrite { _ = await settingWrite.value }
        guard operation != nil, let work else { return nil }
        return await work.value
    }
    public func cancelNativeProbe() { cancelCameraSettingWrite(); cancelTapFocusProbe(); cancelLensPointRecording(); cancelLensStateQuery(); cancelCameraPropertyQuery(); cancelNativeRecenter(); probeOperation?.permit.invalidate(); probeTask?.cancel() }

    /// Development-only, one FE08 command, no retry or fallback. The App must
    /// own USB/motion exclusion and independent cleanup throughout this call.
    public func probeNativeRecenter(permit: OperationPermit = OperationPermit()) async throws -> BluetoothNativeRecenterResult {
        try Task.checkCancellation()
        try permit.perform {}
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled", "BLE recenter probing requires a development launch.")
        }
        guard settingWriteOperation == nil, tapFocusOperation == nil, nativePresetOperation == nil, nativePresetTask == nil, probeOperation == nil,
              probeTask == nil, readinessOperation == nil, readinessTask == nil, lensStateOperation == nil, cameraPropertyOperation == nil, lensPointOperation == nil else {
            throw BridgeFailure("bluetooth_probe_busy", "Another BLE probe is already running.")
        }
        guard state.phase == .gattPaired, pairer?.paired == true,
              [.paired, .credentialsReady].contains(pairer?.phase ?? .idle),
              registrationAcknowledgmentSession == state.generation,
              let central, central.state == .poweredOn,
              let peripheral = selectedPeripheral, peripheral.state == .connected,
              fff4Notifying, fff5Notifying,
              let fff5, fff5.isNotifying, fff5.properties.contains(.writeWithoutResponse),
              peripheral.canSendWriteWithoutResponse, writeQueue.isEmpty,
              peripheral.maximumWriteValueLength(for: .withoutResponse) >= BluetoothNativePresetProbe.frameBytes,
              let sequence = pairer?.reserveReadinessSequence() else {
            throw BridgeFailure("bluetooth_recenter_not_ready", "Pair and register the current BLE peer before recenter probing.")
        }
        let operation = try BluetoothNativePresetOperation(session: state.generation, central: central,
            peripheral: peripheral, characteristic: fff5, sequence: sequence, permit: permit)
        nativePresetOperation = operation
        let work = Task<BluetoothNativeRecenterResult, Never>(priority: .userInitiated) { @MainActor [self, operation] in
            await runNativeRecenter(operation)
        }
        nativePresetTask = work
        operation.focusObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { _ in permit.invalidate(); work.cancel() }
        publish()
        return await withTaskCancellationHandler { await work.value } onCancel: {
            permit.invalidate(); work.cancel()
        }
    }

    /// Synchronous fence; no BLE neutral or USB hold is inferred or sent here.
    public func cancelNativeRecenter() { nativePresetOperation?.permit.invalidate(); nativePresetTask?.cancel() }

    private func nativeRecenterIsCurrent(_ operation: BluetoothNativePresetOperation) -> Bool {
        nativePresetOperation === operation && state.generation == operation.session
            && central === operation.central && selectedPeripheral === operation.peripheral
            && fff5 === operation.characteristic && state.phase == .gattPaired
            && operation.central.state == .poweredOn && operation.peripheral.state == .connected
            && operation.characteristic.isNotifying && fff4Notifying && fff5Notifying
            && pairer?.paired == true && registrationAcknowledgmentSession == operation.session
    }

    private func runNativeRecenter(_ operation: BluetoothNativePresetOperation) async -> BluetoothNativeRecenterResult {
        var failure: String?
        var cancelled = false
        do {
            let baselineDeadline = operation.evidence.result.startedUptime + BluetoothNativePresetProbe.baselineTimeout
            while !operation.evidence.baselineIsReady(at: ProcessInfo.processInfo.systemUptime) {
                try Task.checkCancellation()
                try operation.permit.perform {}
                guard nativeRecenterIsCurrent(operation) else { throw BridgeFailure("bluetooth_recenter_connection_changed", "The BLE connection changed.") }
                guard ProcessInfo.processInfo.systemUptime < baselineDeadline else {
                    throw BridgeFailure("bluetooth_recenter_baseline", "No fresh half-second stable BLE baseline was received; no recenter command was sent.")
                }
                try await Task.sleep(for: .milliseconds(10), tolerance: .zero)
            }
            try Task.checkCancellation()
            try operation.permit.perform {
                guard nativeRecenterIsCurrent(operation) else { throw BridgeFailure("bluetooth_recenter_connection_changed", "The BLE connection changed.") }
                guard operation.peripheral.canSendWriteWithoutResponse, writeQueue.isEmpty,
                      operation.peripheral.maximumWriteValueLength(for: .withoutResponse) >= operation.packet.count else {
                    throw BridgeFailure("bluetooth_recenter_backpressure", "The single recenter command was not queued or retried.")
                }
                try operation.evidence.submitted(at: ProcessInfo.processInfo.systemUptime)
                operation.peripheral.writeValue(operation.packet, for: operation.characteristic, type: .withoutResponse)
            }
            recordHeader(operation.evidence.request, direction: "submitted_tx", characteristic: "FFF5")
            let deadline = operation.evidence.result.submittedUptime! + BluetoothNativePresetProbe.observationDuration
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                try operation.permit.perform {}
                guard nativeRecenterIsCurrent(operation) else { throw BridgeFailure("bluetooth_recenter_connection_changed", "The BLE connection changed.") }
                try await Task.sleep(for: .milliseconds(10), tolerance: .zero)
            }
        } catch {
            cancelled = Task.isCancelled || error is CancellationError
            failure = (error as? BridgeFailure)?.code ?? (cancelled ? "cancelled" : "bluetooth_recenter_failed")
        }
        if let observer = operation.focusObserver { NotificationCenter.default.removeObserver(observer); operation.focusObserver = nil }
        let result = operation.evidence.finish(at: ProcessInfo.processInfo.systemUptime,
            cancelled: cancelled || Task.isCancelled || !operation.permit.isValid,
            connectionChanged: operation.connectionChanged || !nativeRecenterIsCurrent(operation), failure: failure)
        if nativePresetOperation === operation { nativePresetOperation = nil; nativePresetTask = nil; drainWrites(); publish() }
        return result
    }

    /// One explicit 04/50 request, no retries and no motor/registration/mode writes.
    public func queryNativeReadiness() async throws -> BluetoothReadinessResult {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled", "BLE readiness queries require a development launch.")
        }
        let permit = OperationPermit()
        try permit.perform {}
        guard settingWriteOperation == nil, tapFocusOperation == nil, readinessOperation == nil, probeOperation == nil, nativePresetOperation == nil, lensStateOperation == nil, cameraPropertyOperation == nil, lensPointOperation == nil,
              state.phase == .gattPaired, pairer?.paired == true,
              [.paired, .credentialsReady].contains(pairer?.phase ?? .idle),
              registrationAcknowledgmentSession == state.generation,
              let central, central.state == .poweredOn,
              let peripheral = selectedPeripheral, peripheral.state == .connected,
              let fff5, fff5.isNotifying, fff5.properties.contains(.writeWithoutResponse),
              peripheral.canSendWriteWithoutResponse, writeQueue.isEmpty,
              let sequence = pairer?.reserveReadinessSequence() else {
            throw BridgeFailure("bluetooth_readiness_not_ready", "Pair and register the current BLE peer before requesting readiness.")
        }
        let operation = BluetoothReadinessOperation(session: state.generation, peripheral: peripheral,
            characteristic: fff5, sequence: sequence, permit: permit)
        let packet = try DUMLCodec.encode(operation.query.request)
        guard peripheral.maximumWriteValueLength(for: .withoutResponse) >= packet.count else {
            throw BridgeFailure("bluetooth_readiness_mtu", "The readiness request does not fit one BLE write.")
        }
        // Submit before the first suspension, while the current peer/allocator
        // selection is still one MainActor transaction. Never enqueue a retry.
        try permit.perform {
            peripheral.writeValue(packet, for: fff5, type: .withoutResponse)
            operation.query.submitted(at: ProcessInfo.processInfo.systemUptime)
        }
        readinessOperation = operation
        recordHeader(operation.query.request, direction: "submitted_tx", characteristic: "FFF5")
        let work = Task<BluetoothReadinessResult, Never>(priority: .userInitiated) { @MainActor [self, operation] in
            let deadline = (operation.query.result.submittedUptime ?? operation.query.result.startedUptime)
                + BluetoothReadinessQuery.responseTimeout
            while !Task.isCancelled, state.generation == operation.session,
                  selectedPeripheral === operation.peripheral,
                  !operation.query.result.responseReceived, ProcessInfo.processInfo.systemUptime < deadline {
                do { try await Task.sleep(for: .milliseconds(10), tolerance: .zero) } catch { break }
            }
            let result = operation.query.finish(at: ProcessInfo.processInfo.systemUptime,
                cancelled: Task.isCancelled,
                connectionChanged: state.generation != operation.session || selectedPeripheral !== operation.peripheral)
            if readinessOperation === operation { readinessOperation = nil; readinessTask = nil }
            return result
        }
        readinessTask = work
        return await withTaskCancellationHandler { await work.value } onCancel: {
            permit.invalidate(); work.cancel()
        }
    }

    /// One development-only named-property subscription. No AF/AE writes,
    /// retry, alternative address, credentials query, or implicit connection.
    public func queryLensState(permit: OperationPermit = OperationPermit()) async throws -> BluetoothLensStateQueryResult {
        try Task.checkCancellation()
        try permit.perform {}
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled", "BLE lens-state queries require a development launch.")
        }
        guard settingWriteOperation == nil, tapFocusOperation == nil, lensPointOperation == nil, lensStateOperation == nil, cameraPropertyOperation == nil, lensStateTask == nil, nativePresetOperation == nil,
              nativePresetTask == nil, probeOperation == nil, probeTask == nil,
              readinessOperation == nil, readinessTask == nil else {
            throw BridgeFailure("bluetooth_probe_busy", "Another BLE query or probe is already running.")
        }
        guard state.phase == .gattPaired, pairer?.paired == true,
              [.paired, .credentialsReady].contains(pairer?.phase ?? .idle),
              registrationAcknowledgmentSession == state.generation,
              let central, central.state == .poweredOn,
              let peripheral = selectedPeripheral, peripheral.state == .connected,
              fff4Notifying, fff5Notifying, let fff5, fff5.isNotifying,
              fff5.properties.contains(.writeWithoutResponse), peripheral.canSendWriteWithoutResponse,
              writeQueue.isEmpty, let sequence = pairer?.reserveReadinessSequence() else {
            throw BridgeFailure("bluetooth_lens_query_not_ready", "Pair and register the current BLE peer before reading lens state.")
        }
        let operation = try BluetoothLensStateOperation(session: state.generation, central: central,
            peripheral: peripheral, characteristic: fff5, sequence: sequence, permit: permit)
        guard peripheral.maximumWriteValueLength(for: .withoutResponse) >= operation.packet.count else {
            throw BridgeFailure("bluetooth_lens_query_mtu", "The fixed subscription must fit one BLE write.")
        }
        lensStateOperation = operation
        let work = Task<BluetoothLensStateQueryResult, Never>(priority: .userInitiated) { @MainActor [self, operation] in
            var failure: String?
            do {
                try operation.permit.perform {
                    guard lensStateIsCurrent(operation) else { throw BridgeFailure("bluetooth_lens_query_connection_changed", "The BLE connection changed.") }
                    guard operation.peripheral.canSendWriteWithoutResponse, writeQueue.isEmpty,
                          operation.peripheral.maximumWriteValueLength(for: .withoutResponse) >= operation.packet.count else {
                        throw BridgeFailure("bluetooth_lens_query_backpressure", "The subscription was not queued or retried.")
                    }
                    try operation.query.submitted(at: ProcessInfo.processInfo.systemUptime)
                    operation.peripheral.writeValue(operation.packet, for: operation.characteristic, type: .withoutResponse)
                }
                recordHeader(operation.query.request, direction: "submitted_tx", characteristic: "FFF5")
                let deadline = operation.query.result.submittedUptime! + BluetoothLensStateQuery.observationDuration
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try Task.checkCancellation()
                    try operation.permit.perform {}
                    guard lensStateIsCurrent(operation) else { throw BridgeFailure("bluetooth_lens_query_connection_changed", "The BLE connection changed.") }
                    try await Task.sleep(for: .milliseconds(10), tolerance: .zero)
                }
            } catch {
                failure = (error as? BridgeFailure)?.code ?? (error is CancellationError ? "cancelled" : "bluetooth_lens_query_failed")
            }
            let result = operation.query.finish(at: ProcessInfo.processInfo.systemUptime,
                cancelled: Task.isCancelled || !operation.permit.isValid,
                connectionChanged: operation.connectionChanged || !lensStateIsCurrent(operation), failure: failure)
            if lensStateOperation === operation { lensStateOperation = nil; lensStateTask = nil; drainWrites(); publish() }
            return result
        }
        lensStateTask = work; publish()
        return await withTaskCancellationHandler { await work.value } onCancel: {
            permit.invalidate(); work.cancel()
        }
    }

    public func cancelLensStateQuery() { lensStateOperation?.permit.invalidate(); lensStateTask?.cancel() }

    private func lensStateIsCurrent(_ operation: BluetoothLensStateOperation) -> Bool {
        lensStateOperation === operation && state.generation == operation.session
            && central === operation.central && selectedPeripheral === operation.peripheral
            && fff5 === operation.characteristic && state.phase == .gattPaired
            && operation.central.state == .poweredOn && operation.peripheral.state == .connected
            && operation.characteristic.isNotifying && fff4Notifying && fff5Notifying
            && pairer?.paired == true && registrationAcknowledgmentSession == operation.session
    }

    public func queryCameraProperty(property: CameraSettingsProperty, permit: OperationPermit = OperationPermit()) async throws -> BluetoothCameraPropertyQueryResult {
        try Task.checkCancellation()
        try permit.perform {}
        guard settingWriteOperation == nil, tapFocusOperation == nil, lensPointOperation == nil, cameraPropertyOperation == nil, cameraPropertyTask == nil, lensStateOperation == nil, lensStateTask == nil, nativePresetOperation == nil,
              nativePresetTask == nil, probeOperation == nil, probeTask == nil,
              readinessOperation == nil, readinessTask == nil else {
            throw BridgeFailure("bluetooth_probe_busy", "Another BLE query or probe is already running.")
        }
        guard state.phase == .gattPaired, pairer?.paired == true,
              [.paired, .credentialsReady].contains(pairer?.phase ?? .idle),
              registrationAcknowledgmentSession == state.generation,
              let central, central.state == .poweredOn,
              let peripheral = selectedPeripheral, peripheral.state == .connected,
              fff4Notifying, fff5Notifying, let fff5, fff5.isNotifying,
              fff5.properties.contains(.writeWithoutResponse), peripheral.canSendWriteWithoutResponse,
              writeQueue.isEmpty, let sequence = pairer?.reserveReadinessSequence() else {
            throw BridgeFailure("bluetooth_property_query_not_ready", "Pair and register the current BLE peer before reading a camera property.")
        }
        let operation = try BluetoothCameraPropertyOperation(property: property, session: state.generation, central: central,
            peripheral: peripheral, characteristic: fff5, sequence: sequence, permit: permit)
        guard peripheral.maximumWriteValueLength(for: .withoutResponse) >= operation.packet.count else {
            throw BridgeFailure("bluetooth_property_query_mtu", "The fixed subscription must fit one BLE write.")
        }
        cameraPropertyOperation = operation
        let work = Task<BluetoothCameraPropertyQueryResult, Never>(priority: .userInitiated) { @MainActor [self, operation] in
            var failure: String?
            do {
                try operation.permit.perform {
                    guard cameraPropertyIsCurrent(operation) else { throw BridgeFailure("bluetooth_property_query_connection_changed", "The BLE connection changed.") }
                    guard operation.peripheral.canSendWriteWithoutResponse, writeQueue.isEmpty,
                          operation.peripheral.maximumWriteValueLength(for: .withoutResponse) >= operation.packet.count else {
                        throw BridgeFailure("bluetooth_property_query_backpressure", "The subscription was not queued or retried.")
                    }
                    let submittedAt = ProcessInfo.processInfo.systemUptime
                    guard cameraSettingsStore.resetAdmission(for: property, sessionID: operation.session,
                        peripheralID: operation.peripheral.identifier, at: submittedAt) else {
                        throw BridgeFailure("bluetooth_property_query_connection_changed", "The settings readback session changed.")
                    }
                    try operation.query.submitted(at: submittedAt)
                    operation.peripheral.writeValue(operation.packet, for: operation.characteristic, type: .withoutResponse)
                }
                recordHeader(operation.query.request, direction: "submitted_tx", characteristic: "FFF5")
                let deadline = operation.query.result.submittedUptime! + BluetoothCameraPropertyQuery.observationDuration
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try Task.checkCancellation()
                    try operation.permit.perform {}
                    guard cameraPropertyIsCurrent(operation) else { throw BridgeFailure("bluetooth_property_query_connection_changed", "The BLE connection changed.") }
                    if operation.query.result.ackReceived && operation.query.result.propertyReceived { break }
                    try await Task.sleep(for: .milliseconds(10), tolerance: .zero)
                }
            } catch {
                failure = (error as? BridgeFailure)?.code ?? (error is CancellationError ? "cancelled" : "bluetooth_property_query_failed")
            }
            let result = operation.query.finish(at: ProcessInfo.processInfo.systemUptime,
                cancelled: Task.isCancelled || !operation.permit.isValid,
                connectionChanged: operation.connectionChanged || !cameraPropertyIsCurrent(operation), failure: failure)
            if cameraPropertyOperation === operation { cameraPropertyOperation = nil; cameraPropertyTask = nil; drainWrites(); publish() }
            return result
        }
        cameraPropertyTask = work; publish()
        return await withTaskCancellationHandler { await work.value } onCancel: {
            permit.invalidate(); work.cancel()
        }
    }

    public func cancelCameraPropertyQuery() { cameraPropertyOperation?.permit.invalidate(); cameraPropertyTask?.cancel() }

    private func cameraPropertyIsCurrent(_ operation: BluetoothCameraPropertyOperation) -> Bool {
        cameraPropertyOperation === operation && state.generation == operation.session
            && central === operation.central && selectedPeripheral === operation.peripheral
            && fff5 === operation.characteristic && state.phase == .gattPaired
            && operation.central.state == .poweredOn && operation.peripheral.state == .connected
            && operation.characteristic.isNotifying && fff4Notifying && fff5Notifying
            && pairer?.paired == true && registrationAcknowledgmentSession == operation.session
    }

    /// One explicit development subscription, then bounded passive sampling.
    /// Existing keepalives continue; no camera setting or gimbal SET is sent.
    public func recordLensPoints(expectedSessionID: UUID, peripheralID: UUID,
                                 permit: OperationPermit = OperationPermit()) async throws -> BluetoothFocusPointRecording {
        try Task.checkCancellation()
        try permit.perform {}
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled", "Lens-point recording requires a development launch")
        }
        guard state.generation == expectedSessionID, state.selected == peripheralID else {
            throw BridgeFailure("bluetooth_lens_series_connection_changed", "The selected Bluetooth peer or session changed")
        }
        guard settingWriteOperation == nil, tapFocusOperation == nil, lensPointOperation == nil, lensPointTask == nil, cameraPropertyOperation == nil, cameraPropertyTask == nil,
              lensStateOperation == nil, lensStateTask == nil, nativePresetOperation == nil, nativePresetTask == nil,
              probeOperation == nil, probeTask == nil, readinessOperation == nil, readinessTask == nil else {
            throw BridgeFailure("bluetooth_probe_busy", "Another Bluetooth query or probe is already running")
        }
        guard state.phase == .gattPaired, pairer?.paired == true,
              [.paired, .credentialsReady].contains(pairer?.phase ?? .idle),
              registrationAcknowledgmentSession == expectedSessionID,
              let central, central.state == .poweredOn, let peripheral = selectedPeripheral,
              peripheral.identifier == peripheralID, peripheral.state == .connected,
              fff4Notifying, fff5Notifying, let fff5, fff5.isNotifying,
              fff5.properties.contains(.writeWithoutResponse), peripheral.canSendWriteWithoutResponse,
              writeQueue.isEmpty, let sequence = pairer?.reserveReadinessSequence() else {
            throw BridgeFailure("bluetooth_lens_series_not_ready", "Pair and register the explicitly selected Bluetooth peer first")
        }
        let operation = try BluetoothLensPointOperation(session: expectedSessionID, central: central,
            peripheral: peripheral, characteristic: fff5, sequence: sequence, permit: permit)
        guard peripheral.maximumWriteValueLength(for: .withoutResponse) >= operation.packet.count else {
            throw BridgeFailure("bluetooth_lens_series_mtu", "The fixed lens subscription must fit one Bluetooth write")
        }
        lensPointOperation = operation
        let work = Task<BluetoothFocusPointRecording, Never>(priority: .userInitiated) { @MainActor [self, operation] in
            var ending: BluetoothFocusPointRecordingEnd?
            var failureCode: String?
            do {
                try operation.permit.perform {
                    guard lensPointsAreCurrent(operation) else { throw BridgeFailure("bluetooth_lens_series_connection_changed", "The Bluetooth connection changed") }
                    guard operation.peripheral.canSendWriteWithoutResponse, writeQueue.isEmpty,
                          operation.peripheral.maximumWriteValueLength(for: .withoutResponse) >= operation.packet.count else {
                        throw BridgeFailure("bluetooth_lens_series_backpressure", "The single subscription was not queued or retried")
                    }
                    try operation.recorder.submitted(at: ProcessInfo.processInfo.systemUptime)
                    operation.peripheral.writeValue(operation.packet, for: operation.characteristic, type: .withoutResponse)
                }
                recordHeader(operation.recorder.request, direction: "submitted_tx", characteristic: "FFF5")
                let deadline = operation.recorder.result.submittedUptime! + BluetoothFocusPointRecorder.maximumDuration
                while operation.recorder.result.end == nil, ProcessInfo.processInfo.systemUptime < deadline {
                    try Task.checkCancellation()
                    try operation.permit.perform {}
                    guard lensPointsAreCurrent(operation) else { throw BridgeFailure("bluetooth_lens_series_connection_changed", "The Bluetooth connection changed") }
                    try await Task.sleep(for: .milliseconds(50), tolerance: .zero)
                }
            } catch {
                failureCode = (error as? BridgeFailure)?.code ?? (error is CancellationError ? "cancelled" : "bluetooth_lens_series_failed")
                if operation.connectionChanged || !lensPointsAreCurrent(operation) { ending = .connectionChanged }
                else if Task.isCancelled || !operation.permit.isValid { ending = .cancelled }
                else { ending = .failed }
            }
            // Final publication is one MainActor turn. An old operation never
            // clears a newer recording or sends cleanup through a new peer.
            if ending == nil, operation.connectionChanged || !lensPointsAreCurrent(operation) { ending = .connectionChanged }
            if ending == nil, Task.isCancelled || !operation.permit.isValid { ending = .cancelled }
            let result = operation.recorder.finish(at: ProcessInfo.processInfo.systemUptime,
                                                   reason: ending, failureCode: failureCode)
            if lensPointOperation === operation { lensPointOperation = nil; lensPointTask = nil; drainWrites(); publish() }
            return result
        }
        lensPointTask = work; publish()
        return await withTaskCancellationHandler { await work.value } onCancel: {
            permit.invalidate(); work.cancel()
        }
    }

    public func cancelLensPointRecording() { lensPointOperation?.permit.invalidate(); lensPointTask?.cancel() }

    private func lensPointsAreCurrent(_ operation: BluetoothLensPointOperation) -> Bool {
        lensPointOperation === operation && state.generation == operation.session
            && state.selected == operation.peripheral.identifier && central === operation.central
            && selectedPeripheral === operation.peripheral && fff5 === operation.characteristic
            && state.phase == .gattPaired && operation.central.state == .poweredOn
            && operation.peripheral.state == .connected && operation.characteristic.isNotifying
            && fff4Notifying && fff5Notifying && pairer?.paired == true
            && registrationAcknowledgmentSession == operation.session
    }

    /// Developer-only, exactly one existing camera-setting command. No scan,
    /// pairing, extra subscription, retry, restoration or image export occurs.
    public func writeCameraSetting(request: BluetoothCameraSettingWriteRequest, permit: OperationPermit,
        validateCapture: @escaping @MainActor @Sendable () async throws -> Void,
        validateCaptureSynchronously: @escaping @MainActor @Sendable () throws -> Void) async throws -> BluetoothCameraSettingWriteResult {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled", "BLE camera setting writes require a development launch")
        }
        try Task.checkCancellation(); try permit.perform {}
        guard settingWriteOperation == nil, settingWriteTask == nil, tapFocusOperation == nil, tapFocusTask == nil,
              lensPointOperation == nil, lensPointTask == nil, cameraPropertyOperation == nil, cameraPropertyTask == nil,
              lensStateOperation == nil, lensStateTask == nil, nativePresetOperation == nil, nativePresetTask == nil,
              probeOperation == nil, probeTask == nil, readinessOperation == nil, readinessTask == nil else {
            throw BridgeFailure("bluetooth_probe_busy", "Another Bluetooth query or write is active")
        }
        guard state.generation == request.expectedSessionID, state.selected == request.peripheralID,
              state.phase == .gattPaired, pairer?.paired == true,
              registrationAcknowledgmentSession == request.expectedSessionID,
              let central, central.state == .poweredOn, let peripheral = selectedPeripheral,
              peripheral.identifier == request.peripheralID, peripheral.state == .connected,
              fff4Notifying, fff5Notifying, let fff5, fff5.isNotifying,
              fff5.properties.contains(.writeWithoutResponse), writeQueue.isEmpty,
              let baseline = cameraSettingsStore.admissionSnapshot(for: request.property,
                sessionID: request.expectedSessionID, peripheralID: request.peripheralID,
                paired: true, nowUptime: ProcessInfo.processInfo.systemUptime),
              let sequence = pairer?.reserveReadinessSequence() else {
            throw BridgeFailure("bluetooth_setting_not_ready", "Use the exact paired/registered peer with a fresh setting baseline")
        }
        let operation = try BluetoothSettingWriteOperation(request: request, baseline: baseline, central: central,
            peripheral: peripheral, characteristic: fff5, sequence: sequence, permit: permit)
        if operation.writer.result.noOp { return operation.writer.result }
        settingWriteOperation = operation
        let work = Task<BluetoothCameraSettingWriteResult, Never>(priority: .userInitiated) { @MainActor [self, operation] in
            do {
                while operation.writer.result.end == nil {
                    try Task.checkCancellation()
                    try permit.perform {
                        try validateCaptureSynchronously()
                        guard settingWriteIsCurrent(operation) else { throw BridgeFailure("bluetooth_setting_connection_changed", "The paired camera connection changed") }
                    }
                    operation.writer.tick(at: ProcessInfo.processInfo.systemUptime)
                    if operation.writer.result.end == nil, !operation.writer.result.localSubmitted {
                        try await validateCapture()
                        try permit.perform {
                            try validateCaptureSynchronously()
                            guard settingWriteIsCurrent(operation), writeQueue.isEmpty,
                                  let current = cameraSettingsStore.admissionSnapshot(for: request.property,
                                    sessionID: request.expectedSessionID, peripheralID: request.peripheralID,
                                    paired: true, nowUptime: ProcessInfo.processInfo.systemUptime) else {
                                throw BridgeFailure("bluetooth_setting_baseline_stale", "The final paired setting baseline is unavailable")
                            }
                            _ = try operation.writer.submitIfReady(currentBaseline: current,
                                hasCredit: peripheral.canSendWriteWithoutResponse,
                                maximumWriteBytes: peripheral.maximumWriteValueLength(for: .withoutResponse),
                                at: ProcessInfo.processInfo.systemUptime) { frame, data in
                                    peripheral.writeValue(data, for: operation.characteristic, type: .withoutResponse)
                                    recordHeader(frame, direction: "submitted_tx", characteristic: "FFF5")
                                }
                        }
                    }
                    if operation.writer.result.end == nil { try await Task.sleep(for: .milliseconds(10), tolerance: .zero) }
                }
            } catch {
                let code = (error as? BridgeFailure)?.code ?? (error is CancellationError ? "cancelled" : "bluetooth_setting_failed")
                let changed = operation.connectionChanged || !settingWriteIsCurrent(operation) || code.contains("capture_changed")
                let cancelled = Task.isCancelled || !permit.isValid
                let baselineChanged = code.contains("baseline") || (error as? CameraSettingsError) == .baselineChanged
                operation.writer.finish(at: ProcessInfo.processInfo.systemUptime,
                    reason: changed ? .connectionChanged : cancelled ? .cancelled : baselineChanged ? .baselineChanged : .failed,
                    failure: code)
            }
            if let observer = operation.focusObserver { NotificationCenter.default.removeObserver(observer) }
            if settingWriteOperation === operation { settingWriteOperation = nil; settingWriteTask = nil; drainWrites(); publish() }
            return operation.writer.result
        }
        settingWriteTask = work
        operation.focusObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { _ in permit.invalidate(); work.cancel() }
        publish()
        return await withTaskCancellationHandler { await work.value } onCancel: { permit.invalidate(); work.cancel() }
    }
    public func cancelCameraSettingWrite() { settingWriteOperation?.permit.invalidate(); settingWriteTask?.cancel() }
    public func stopCameraSettingWrite(permit: OperationPermit) async -> BluetoothCameraSettingWriteResult? {
        guard settingWriteOperation?.permit === permit else { return nil }
        let work = settingWriteTask
        permit.invalidate(); work?.cancel()
        return await work?.value
    }
    private func settingWriteIsCurrent(_ operation: BluetoothSettingWriteOperation) -> Bool {
        settingWriteOperation === operation && state.generation == operation.request.expectedSessionID
            && state.selected == operation.request.peripheralID && selectedPeripheral === operation.peripheral
            && central === operation.central && fff5 === operation.characteristic && state.phase == .gattPaired
            && operation.central.state == .poweredOn && operation.peripheral.state == .connected
            && operation.characteristic.isNotifying && fff4Notifying && fff5Notifying && pairer?.paired == true
            && registrationAcknowledgmentSession == operation.request.expectedSessionID
    }

    /// Four exact camera writes at most; no pairing, query, retry, neutral or
    /// restore is introduced. The App owns USB/control exclusion and freshness.
    public func probeTapFocus(request: BluetoothTapFocusRequest, permit: OperationPermit,
        validateCapture: @escaping @MainActor @Sendable () async throws -> Void,
        validateCaptureSynchronously: @escaping @MainActor @Sendable () throws -> Void) async throws -> BluetoothTapFocusResult {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled", "BLE tap-focus requires a development launch")
        }
        try Task.checkCancellation(); try permit.perform {}
        guard settingWriteOperation == nil, tapFocusOperation == nil, tapFocusTask == nil, lensPointOperation == nil, lensPointTask == nil,
              cameraPropertyOperation == nil, cameraPropertyTask == nil, lensStateOperation == nil, lensStateTask == nil,
              nativePresetOperation == nil, nativePresetTask == nil, probeOperation == nil, probeTask == nil,
              readinessOperation == nil, readinessTask == nil else {
            throw BridgeFailure("bluetooth_probe_busy", "Another BLE operation is active")
        }
        guard state.generation == request.expectedSessionID, state.selected == request.peripheralID,
              state.phase == .gattPaired, pairer?.paired == true,
              registrationAcknowledgmentSession == request.expectedSessionID,
              let central, central.state == .poweredOn,
              let peripheral = selectedPeripheral, peripheral.identifier == request.peripheralID,
              peripheral.state == .connected, fff4Notifying, fff5Notifying,
              let fff5, fff5.isNotifying, fff5.properties.contains(.writeWithoutResponse),
              writeQueue.isEmpty,
              peripheral.maximumWriteValueLength(for: .withoutResponse) >= 34 else {
            throw BridgeFailure("bluetooth_focus_not_ready", "The exact paired/registered BLE peer must be ready for a whole 34-byte write")
        }
        let now = ProcessInfo.processInfo.systemUptime
        let baseline = try BluetoothTapFocusBaseline(request: request, observations: cameraSettingsStore.snapshot(
            sessionID: request.expectedSessionID, peripheralID: request.peripheralID, paired: true, nowUptime: now), now: now)
        var sequences: [UInt16] = []
        for _ in 0..<4 {
            guard let value = pairer?.reserveReadinessSequence() else { throw BridgeFailure("bluetooth_focus_sequence", "The paired sequence allocator is unavailable") }
            sequences.append(value)
        }
        let operation = try BluetoothTapFocusOperation(request: request, baseline: baseline, central: central,
            peripheral: peripheral, characteristic: fff5, sequences: sequences, permit: permit, now: now)
        tapFocusOperation = operation
        let work = Task<BluetoothTapFocusResult, Never>(priority: .userInitiated) { @MainActor [self, operation] in
            do {
                while operation.probe.result.end == nil {
                    try Task.checkCancellation(); try permit.perform {}
                    guard tapFocusIsCurrent(operation) else { throw BridgeFailure("bluetooth_focus_connection_changed", "The paired BLE connection changed") }
                    operation.probe.tick(at: ProcessInfo.processInfo.systemUptime)
                    if operation.probe.nextStep != nil {
                        try await validateCapture()
                        // Prepare does not wait for an ACK. CoreBluetooth may
                        // temporarily exhaust credits after it, so yield while
                        // the next unsent step waits for its bounded credit window.
                        while operation.probe.nextStep != nil {
                            let submitted = try permit.perform {
                                try validateCaptureSynchronously()
                                guard tapFocusIsCurrent(operation), writeQueue.isEmpty else {
                                    throw BridgeFailure("bluetooth_focus_write_blocked", "Focus write was not queued or retried")
                                }
                                return try operation.probe.submitNextIfReady(
                                    hasCredit: operation.peripheral.canSendWriteWithoutResponse,
                                    maximumWriteBytes: operation.peripheral.maximumWriteValueLength(for: .withoutResponse),
                                    at: ProcessInfo.processInfo.systemUptime) { frame, data in
                                        operation.peripheral.writeValue(data, for: operation.characteristic, type: .withoutResponse)
                                        recordHeader(frame, direction: "submitted_tx", characteristic: "FFF5")
                                    }
                            }
                            if !submitted { break }
                        }
                    }
                    if operation.probe.result.end == nil { try await Task.sleep(for: .milliseconds(10), tolerance: .zero) }
                }
            } catch {
                let changed = operation.connectionChanged || !tapFocusIsCurrent(operation)
                let cancelled = Task.isCancelled || !permit.isValid
                operation.probe.finish(at: ProcessInfo.processInfo.systemUptime,
                    reason: changed ? .connectionChanged : cancelled ? .cancelled : .failed,
                    failure: (error as? BridgeFailure)?.code ?? (cancelled ? "cancelled" : "bluetooth_focus_failed"))
            }
            if let observer = operation.focusObserver { NotificationCenter.default.removeObserver(observer) }
            if tapFocusOperation === operation { tapFocusOperation = nil; tapFocusTask = nil; drainWrites(); publish() }
            return operation.probe.result
        }
        tapFocusTask = work
        operation.focusObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { _ in permit.invalidate(); work.cancel() }
        publish()
        return await withTaskCancellationHandler { await work.value } onCancel: { permit.invalidate(); work.cancel() }
    }

    public func cancelTapFocusProbe() { tapFocusOperation?.permit.invalidate(); tapFocusTask?.cancel() }
    public func stopTapFocusProbe(permit: OperationPermit) async -> BluetoothTapFocusResult? {
        guard tapFocusOperation?.permit === permit else { return nil }
        let work = tapFocusTask
        permit.invalidate(); work?.cancel()
        return await work?.value
    }
    private func tapFocusIsCurrent(_ operation: BluetoothTapFocusOperation) -> Bool {
        tapFocusOperation === operation && state.generation == operation.request.expectedSessionID
            && state.selected == operation.request.peripheralID && selectedPeripheral === operation.peripheral
            && central === operation.central && fff5 === operation.characteristic && state.phase == .gattPaired
            && operation.central.state == .poweredOn && operation.peripheral.state == .connected
            && operation.characteristic.isNotifying && fff4Notifying && fff5Notifying && pairer?.paired == true
            && registrationAcknowledgmentSession == operation.request.expectedSessionID
    }

    private func runProbe(_ operation: BluetoothProbeOperation) async -> BluetoothGimbalProbeResult {
        var failure: String?
        var cancelled = false
        do {
            let deadline = operation.evidence.result.startedUptime + BluetoothGimbalProbePlan.baselineTimeout
            while !operation.evidence.baselineIsReady(at: ProcessInfo.processInfo.systemUptime) {
                try operation.permit.perform {}
                guard probeIsCurrent(operation) else { throw BridgeFailure("bluetooth_probe_connection_changed", "The BLE connection changed.") }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw BridgeFailure("bluetooth_probe_baseline", "No fresh half-second stable BLE gimbal baseline was received.")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let start = ProcessInfo.processInfo.systemUptime
            try operation.evidence.beginPulse(at: start)
            for index in BluetoothGimbalProbePlan.offsets.indices {
                let target = start + BluetoothGimbalProbePlan.offsets[index]
                let remaining = target - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining), tolerance: .zero) }
                try operation.permit.perform {
                    let now = ProcessInfo.processInfo.systemUptime
                    guard probeIsCurrent(operation) else { throw BridgeFailure("bluetooth_probe_connection_changed", "The BLE connection changed.") }
                    guard operation.evidence.hasFreshTelemetry(at: now) else { throw BridgeFailure("bluetooth_probe_feedback_stale", "BLE telemetry became stale during the fixed pulse.") }
                    guard operation.peripheral.canSendWriteWithoutResponse,
                          operation.peripheral.maximumWriteValueLength(for: .withoutResponse) >= BluetoothGimbalProbePlan.frameBytes else {
                        throw BridgeFailure("bluetooth_probe_backpressure", "The BLE pulse was aborted rather than queued behind backpressure.")
                    }
                    // The fixed slot is consumed once immediately before the
                    // synchronous CoreBluetooth call, inside the permit fence.
                    try operation.evidence.pulseSubmitted(index: index, at: now)
                    operation.peripheral.writeValue(operation.pulses[index], for: operation.characteristic, type: .withoutResponse)
                }
            }
            let remaining = start + BluetoothGimbalProbePlan.neutralOffset - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining), tolerance: .zero) }
        } catch {
            cancelled = Task.isCancelled || error is CancellationError
            failure = (error as? BridgeFailure)?.code ?? (cancelled ? "cancelled" : "bluetooth_probe_failed")
        }
        // Cleanup is independent of the cancelled pulse task and has its own
        // bounded neutral submission/readback window. It never sends a pulse.
        let neutral = await ensureProbeNeutral(operation)
        if operation.evidence.result.nonNeutralFramesSent > 0 && !neutral && failure == nil { failure = "bluetooth_probe_neutral_not_submitted" }
        // An unstructured Task does not inherit its creator's cancellation.
        // Keeping it on MainActor avoids transferring CoreBluetooth objects
        // through the Swift 6.4 detached-task region-isolation checker.
        let verification = Task<Void, Never> { @MainActor [self, operation] in
            if let neutralAt = operation.evidence.result.neutralUptime {
                let end = neutralAt + BluetoothGimbalProbePlan.postNeutralTimeout
                while probeIsCurrent(operation), ProcessInfo.processInfo.systemUptime < end,
                      !operation.evidence.stopIsStable(at: ProcessInfo.processInfo.systemUptime) {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                }
            }
        }
        await verification.value
        if let observer = operation.focusObserver { NotificationCenter.default.removeObserver(observer); operation.focusObserver = nil }
        let changed = operation.connectionChanged || !probeIsCurrent(operation)
        let result = operation.evidence.finish(at: ProcessInfo.processInfo.systemUptime,
            cancelled: cancelled || Task.isCancelled, connectionChanged: changed, failure: failure)
        if probeOperation === operation { probeOperation = nil; probeTask = nil; drainWrites() }
        return result
    }

    private func probeIsCurrent(_ operation: BluetoothProbeOperation) -> Bool {
        probeOperation === operation && state.generation == operation.session
            && central === operation.central && selectedPeripheral === operation.peripheral
            && fff5 === operation.characteristic && operation.peripheral.state == .connected
            && operation.central.state == .poweredOn && pairer?.paired == true
    }

    private func ensureProbeNeutral(_ operation: BluetoothProbeOperation) async -> Bool {
        if operation.evidence.result.neutralSent { return true }
        guard operation.evidence.result.nonNeutralFramesSent > 0 else { return false }
        if let cleanup = operation.cleanupTask { return await cleanup.value }
        let cleanup = Task<Bool, Never>(priority: .userInitiated) { @MainActor [operation] in
            let deadline = ProcessInfo.processInfo.systemUptime + BluetoothGimbalProbePlan.neutralSubmissionTimeout
            let cleanupPermit = OperationPermit()
            repeat {
                guard operation.central.state == .poweredOn, operation.peripheral.state == .connected else { return false }
                if operation.peripheral.canSendWriteWithoutResponse,
                   operation.peripheral.maximumWriteValueLength(for: .withoutResponse) >= BluetoothGimbalProbePlan.frameBytes {
                    do {
                        try cleanupPermit.perform {
                            operation.peripheral.writeValue(operation.neutral, for: operation.characteristic, type: .withoutResponse)
                            operation.evidence.neutralSubmitted(at: ProcessInfo.processInfo.systemUptime)
                        }
                        return true
                    } catch { return false }
                }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
            } while ProcessInfo.processInfo.systemUptime < deadline
            return false
        }
        operation.cleanupTask = cleanup
        let result = await cleanup.value
        operation.cleanupTask = nil
        return result
    }

    private func schedulePairing(after seconds: TimeInterval, session: UUID,
                                 action: @escaping @MainActor @Sendable (Pocket3BluetoothDiscovery) -> Void) {
        pairingTasks.append(Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.state.generation == session, self.pairer != nil else { return }
            action(self)
        })
    }
    private func enqueue(_ frame: DUMLFrame) {
        do {
            try writeQueue.enqueue(DUMLCodec.encode(frame), at: ProcessInfo.processInfo.systemUptime)
            recordHeader(frame, direction: "queued_tx", characteristic: "FFF5")
            drainWrites()
        } catch { close(phase: .failed, issue: "bluetooth_write_queue_invalid") }
    }
    private func recordHeader(_ frame: DUMLFrame, direction: String, characteristic: String) {
        recentHeaders.insert(.init(direction: direction, characteristic: characteristic,
            source: frame.source, destination: frame.destination, sequence: frame.sequence,
            flags: frame.flags, commandSet: frame.commandSet, commandID: frame.commandID), at: 0)
        if recentHeaders.count > 16 { recentHeaders.removeLast(recentHeaders.count - 16) }
    }
    fileprivate func drainWrites() {
        // A lens-point recording excludes other explicit operations, but is
        // passive after its one synchronous subscription write. Keepalive stays live.
        guard settingWriteOperation == nil, tapFocusOperation == nil, probeOperation == nil, nativePresetOperation == nil, lensStateOperation == nil, cameraPropertyOperation == nil, pairer != nil, let peripheral = selectedPeripheral, let fff5,
              state.accepts(peripheral: peripheral.identifier, session: state.generation),
              peripheral.state == .connected else { return }
        do {
            while peripheral.canSendWriteWithoutResponse, !writeQueue.isEmpty {
                guard let chunk = try writeQueue.nextFragment(maximumBytes: peripheral.maximumWriteValueLength(for: .withoutResponse),
                    at: ProcessInfo.processInfo.systemUptime) else { return }
                peripheral.writeValue(chunk, for: fff5, type: .withoutResponse)
                if let frame = writeQueue.completedFrame {
                    recordHeader(frame, direction: "submitted_tx", characteristic: "FFF5")
                    if frame.source == 2, frame.destination == 0x48, frame.flags == 0xc0,
                       frame.commandSet == 0, frame.commandID == 0x81,
                       frame.payload == BluetoothPairingCommands.applicationInfo {
                        registrationAcknowledgmentSession = state.generation
                    }
                }
            }
        } catch { close(phase: .failed, issue: "bluetooth_write_queue_expired") }
    }
    fileprivate func armWritten(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?, session: UUID) {
        guard accepts(peripheral, session: session), characteristic === fff4, pairer?.phase == .arming else { return }
        guard error == nil, let wake = pairer?.armSucceeded() else { close(phase: .failed, issue: "bluetooth_pair_arm_failed"); return }
        enqueue(wake)
        schedulePairing(after: 0.12, session: session) { owner in
            do { if let request = try owner.pairer?.pairingRequest() { owner.enqueue(request); owner.publish() } }
            catch { owner.close(phase: .failed, issue: "bluetooth_pair_request_invalid") }
        }
        publish()
    }
    private func handlePairing(_ frame: DUMLFrame, peripheral: CBPeripheral, session: UUID) {
        guard let update = pairer?.receive(frame) else { return }
        if pairer?.phase == .failed { close(phase: .failed, issue: pairer?.issueCode ?? "bluetooth_pairing_failed"); return }
        if let acknowledgment = update.acknowledgment { enqueue(acknowledgment) }
        guard accepts(peripheral, session: session) else { return }
        if pairer?.phase == .awaitingApproval {
            _ = state.transition(from: .pairing, to: .awaitingPairingApproval, session: session)
            publish()
        }
        if update.confirmedPairing {
            let pairOnly = pairer?.phase == .paired
            _ = state.transition(from: state.phase, to: pairOnly ? .gattPaired : .retrievingCredentials, session: session)
            if pairOnly {
                pairingTasks.forEach { $0.cancel() }; pairingTasks.removeAll()
            } else {
                for command in pairer?.credentialRequests() ?? [] {
                    schedulePairing(after: command.delay, session: session) { owner in owner.enqueue(command.frame) }
                }
                schedulePairing(after: 8, session: session) { owner in
                    if owner.pairer?.phase != .credentialsReady { owner.close(phase: .failed, issue: "bluetooth_credentials_timeout") }
                }
            }
            keepaliveTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.state.generation == session else { return }
                    // lensPointOperation deliberately does not suppress the
                    // existing heartbeat during its longer passive window.
                    if self.settingWriteOperation == nil, self.tapFocusOperation == nil, self.probeOperation == nil, self.nativePresetOperation == nil, self.lensStateOperation == nil, self.cameraPropertyOperation == nil, let frame = self.pairer?.keepalive() { self.enqueue(frame) }
                }
            }
            publish()
        }
        if let credentials = update.credentials {
            _ = state.transition(from: .retrievingCredentials, to: .gattPaired, session: session)
            pairingTasks.forEach { $0.cancel() }; pairingTasks.removeAll()
            publish()
            guard accepts(peripheral, session: session) else { return }
            onCredentials?(BluetoothWiFiCredentials(ssid: credentials.ssid, password: credentials.password,
                sessionID: session, peripheralID: peripheral.identifier))
        }
    }

    private func publish() { onStatus?(status) }
    private func close(phase: BluetoothDiscoveryPhase, issue: String?) {
        settingWriteOperation?.connectionChanged = true
        tapFocusOperation?.connectionChanged = true
        cancelCameraSettingWrite()
        cancelTapFocusProbe()
        lensPointOperation?.connectionChanged = true
        cancelLensPointRecording()
        lensStateOperation?.connectionChanged = true
        cameraPropertyOperation?.connectionChanged = true
        cancelLensStateQuery(); cancelCameraPropertyQuery()
        nativePresetOperation?.connectionChanged = true
        cancelNativeRecenter()
        readinessOperation?.permit.invalidate(); readinessTask?.cancel()
        let interruptedProbe = probeOperation
        interruptedProbe?.permit.invalidate(); probeTask?.cancel()
        interruptedProbe?.connectionChanged = true
        deadlineTask?.cancel(); deadlineTask = nil
        expirationTask?.cancel(); expirationTask = nil
        pairingTasks.forEach { $0.cancel() }; pairingTasks.removeAll()
        keepaliveTask?.cancel(); keepaliveTask = nil; writeQueue.reset(); battery = nil; poseStore.clear(); cameraSettingsStore.clear()
        if let issue { pairer?.fail(issue) } else { pairer?.cancel() }
        // Invalidate generation/delegates before cancelling the OS operation.
        state.finish(phase, issue: issue)
        selectedPeripheral?.delegate = nil
        if let central, central.state == .poweredOn {
            if central.isScanning { central.stopScan() }
            if let selectedPeripheral {
                if let interruptedProbe, interruptedProbe.evidence.result.nonNeutralFramesSent > 0,
                   !interruptedProbe.evidence.result.neutralSent {
                    // Preserve only the old connection long enough to attempt
                    // neutral. A new session is never used for this cleanup.
                    Task { @MainActor [self, central, selectedPeripheral] in
                        _ = await ensureProbeNeutral(interruptedProbe)
                        if central.state == .poweredOn { central.cancelPeripheralConnection(selectedPeripheral) }
                    }
                } else { central.cancelPeripheralConnection(selectedPeripheral) }
            }
        }
        central?.delegate = nil; central = nil
        selectedPeripheral = nil; peripheralDelegate = nil; selectedService = nil
        fff4 = nil; fff5 = nil; fff4Notifying = false; fff5Notifying = false
        peripherals.removeAll()
        // Discard unfinished fragments, retaining only scalar statistics.
        for key in Array(decoders.keys) { decoders[key]?.discardPending() }
        publish()
    }

    private func updateRadio(_ manager: CBCentralManager) {
        guard manager === central else { return }
        switch manager.state {
        case .poweredOn:
            if state.transition(from: .waitingForBluetooth, to: .scanning, session: state.generation) {
                deadlineTask?.cancel()
                manager.scanForPeripherals(withServices: [Self.serviceID],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
                let session = state.generation
                deadlineTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self, session == self.state.generation,
                          self.state.transition(from: .scanning, to: .scanComplete, session: session) else { return }
                    self.central?.stopScan()
                    self.publish()
                }
                publish()
            }
        case .poweredOff: close(phase: .poweredOff, issue: "bluetooth_powered_off")
        case .unauthorized: close(phase: .unauthorized, issue: "bluetooth_permission_denied")
        case .unsupported: close(phase: .unsupported, issue: "bluetooth_unsupported")
        case .resetting:
            if state.phase != .waitingForBluetooth { close(phase: .failed, issue: "bluetooth_reset") }
        case .unknown: break
        @unknown default: close(phase: .failed, issue: "bluetooth_state_unknown")
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) { updateRadio(central) }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, state.phase == .scanning else { return }
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let name = advertised.map { String($0.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(80)) }
        let rssi = RSSI.intValue
        let candidate = BluetoothCandidate(id: peripheral.identifier, name: name,
            rssi: (-127...20).contains(rssi) ? rssi : nil,
            connectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue)
        guard state.discover(candidate, session: state.generation) else { return }
        peripherals[peripheral.identifier] = peripheral
        publish()
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === selectedPeripheral,
              state.transition(from: .connecting, to: .discoveringServices, session: state.generation) else { return }
        peripheral.discoverServices([Self.serviceID]); publish()
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === selectedPeripheral else { return }
        close(phase: .failed, issue: "bluetooth_connect_failed")
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === selectedPeripheral else { return }
        close(phase: .disconnected, issue: error == nil ? nil : "bluetooth_link_lost")
    }

    fileprivate func discoveredServices(_ peripheral: CBPeripheral, error: Error?, session: UUID) {
        guard accepts(peripheral, session: session), state.phase == .discoveringServices else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            close(phase: .failed, issue: "bluetooth_fff0_missing"); return
        }
        selectedService = service
        _ = state.transition(from: .discoveringServices, to: .discoveringCharacteristics, session: session)
        peripheral.discoverCharacteristics([Self.fff4ID, Self.fff5ID], for: service); publish()
    }
    fileprivate func invalidatedServices(_ peripheral: CBPeripheral, services: [CBService], session: UUID) {
        guard accepts(peripheral, session: session), services.contains(where: { $0 === selectedService }) else { return }
        close(phase: .failed, issue: "bluetooth_service_invalidated")
    }
    fileprivate func discoveredCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?, session: UUID) {
        guard accepts(peripheral, session: session), service === selectedService,
              state.phase == .discoveringCharacteristics else { return }
        guard error == nil,
              let fff4 = service.characteristics?.first(where: { $0.uuid == Self.fff4ID }),
              let fff5 = service.characteristics?.first(where: { $0.uuid == Self.fff5ID }) else {
            close(phase: .failed, issue: "bluetooth_characteristics_missing"); return
        }
        fff4Properties = fff4.properties.rawValue; fff5Properties = fff5.properties.rawValue
        let notification: CBCharacteristicProperties = [.notify, .indicate]
        guard !fff4.properties.intersection(notification).isEmpty, fff4.properties.contains(.write),
              !fff5.properties.intersection(notification).isEmpty, fff5.properties.contains(.writeWithoutResponse) else {
            close(phase: .failed, issue: "bluetooth_gatt_properties_mismatch"); return
        }
        self.fff4 = fff4; self.fff5 = fff5
        decoders = ["FFF4": DUMLFragmentDecoder(), "FFF5": DUMLFragmentDecoder()]
        _ = state.transition(from: .discoveringCharacteristics, to: .subscribing, session: session)
        // These are CCCD subscriptions, not pair-arm or DUML characteristic writes.
        peripheral.setNotifyValue(true, for: fff4)
        peripheral.setNotifyValue(true, for: fff5)
        publish()
    }
    fileprivate func notificationState(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?, session: UUID) {
        guard accepts(peripheral, session: session), characteristic === fff4 || characteristic === fff5 else { return }
        guard error == nil, characteristic.isNotifying else { close(phase: .failed, issue: "bluetooth_notification_failed"); return }
        if characteristic === fff4 { fff4Notifying = true } else { fff5Notifying = true }
        if fff4Notifying && fff5Notifying,
           state.transition(from: .subscribing, to: .gattConnectedUnauthenticated, session: session) {
            deadlineTask?.cancel(); deadlineTask = nil
            expirationTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard let self, session == self.state.generation else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    for key in Array(self.decoders.keys) { self.decoders[key]?.expire(at: now) }
                    do { try self.writeQueue.checkDeadline(at: now) }
                    catch { self.close(phase: .failed, issue: "bluetooth_write_queue_expired"); return }
                }
            }
        }
        publish()
    }
    fileprivate func notified(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?, session: UUID) {
        guard accepts(peripheral, session: session),
              [.gattConnectedUnauthenticated, .pairing, .awaitingPairingApproval, .retrievingCredentials, .gattPaired].contains(state.phase),
              characteristic === fff4 || characteristic === fff5 else { return }
        guard error == nil else { close(phase: .failed, issue: "bluetooth_notification_error"); return }
        guard let data = characteristic.value else { return }
        let key = characteristic === fff4 ? "FFF4" : "FFF5"
        do {
            let packets = try decoders[key]?.append(data, at: ProcessInfo.processInfo.systemUptime) ?? []
            for packet in packets {
                guard accepts(peripheral, session: session) else { return }
                let hostReceivedAt = Date(), receivedUptime = ProcessInfo.processInfo.systemUptime
                receivedFrames += 1
                recordHeader(packet.frame, direction: "received", characteristic: key)
                if let readinessOperation, readinessOperation.session == session {
                    _ = try? readinessOperation.permit.perform {
                        readinessOperation.query.receive(packet.frameData, characteristic: key, at: ProcessInfo.processInfo.systemUptime)
                    }
                }
                if let probeOperation, probeOperation.session == session {
                    probeOperation.evidence.receive(packet.frame, receivedAt: Date(), uptime: ProcessInfo.processInfo.systemUptime)
                }
                if let nativePresetOperation, nativePresetOperation.session == session {
                    _ = try? nativePresetOperation.permit.perform {
                        nativePresetOperation.evidence.receive(packet.frameData, characteristic: key,
                            receivedAt: Date(), uptime: ProcessInfo.processInfo.systemUptime)
                    }
                }
                if let lensStateOperation, lensStateOperation.session == session {
                    _ = try? lensStateOperation.permit.perform {
                        lensStateOperation.query.receive(packet.frameData, characteristic: key, at: ProcessInfo.processInfo.systemUptime)
                    }
                }
                if let operation = cameraPropertyOperation, operation.session == session {
                    _ = try? operation.permit.perform {
                        operation.query.receive(packet.frameData, characteristic: key, binding: operation.binding,
                            at: ProcessInfo.processInfo.systemUptime)
                    }
                }
                if let operation = lensPointOperation, lensPointsAreCurrent(operation) {
                    _ = try? operation.permit.perform {
                        operation.recorder.receive(packet, characteristic: key, sessionID: session,
                            peripheralID: peripheral.identifier, paired: pairer?.paired == true,
                            hostReceivedAt: hostReceivedAt, uptime: receivedUptime)
                    }
                }
                if let operation = tapFocusOperation, tapFocusIsCurrent(operation) {
                    _ = try? operation.permit.perform {
                        operation.probe.receive(packet, characteristic: key, sessionID: session,
                            peripheralID: peripheral.identifier, hostReceivedAt: hostReceivedAt, uptime: receivedUptime)
                    }
                }
                handlePairing(packet.frame, peripheral: peripheral, session: session)
                guard accepts(peripheral, session: session) else { return }
                if pairer?.paired == true,
                   let telemetry = BluetoothBatteryTelemetryParser.parse(packet.frame, receivedAt: Date()) {
                    battery = BluetoothBatteryObservation(sessionID: session, peripheralID: peripheral.identifier, telemetry: telemetry)
                }
                poseStore.receive(packet, sessionID: session, peripheralID: peripheral.identifier,
                    paired: pairer?.paired == true, receivedAt: Date(), uptime: ProcessInfo.processInfo.systemUptime)
                let settingAdmitted = cameraSettingsStore.receive(packet, sessionID: session, peripheralID: peripheral.identifier,
                    paired: pairer?.paired == true, uptime: receivedUptime)
                if let operation = settingWriteOperation, settingWriteIsCurrent(operation) {
                    _ = try? operation.permit.perform {
                        operation.writer.receive(packet, propertyAdmitted: settingAdmitted, characteristic: key,
                            sessionID: session, peripheralID: peripheral.identifier, at: receivedUptime)
                    }
                }
                // Pairing/Wi-Fi replies may contain credentials: they never go
                // through the generic frame callback or serializable status.
                if packet.frame.commandSet != 7 {
                    onFrame?(BluetoothDUMLObservation(sessionID: session, peripheralID: peripheral.identifier,
                        characteristic: key, receivedAt: Date(), packet: packet))
                }
            }
        } catch { close(phase: .failed, issue: "bluetooth_fragment_budget_or_clock") }
    }
    private func accepts(_ peripheral: CBPeripheral, session: UUID) -> Bool {
        peripheral === selectedPeripheral && state.accepts(peripheral: peripheral.identifier, session: session)
    }
}

@MainActor
private final class BluetoothSettingWriteOperation {
    let request: BluetoothCameraSettingWriteRequest
    let central: CBCentralManager
    let peripheral: CBPeripheral
    let characteristic: CBCharacteristic
    let permit: OperationPermit
    var writer: BluetoothCameraSettingWriter
    var connectionChanged = false
    var focusObserver: NSObjectProtocol?
    init(request: BluetoothCameraSettingWriteRequest, baseline: BluetoothCameraSettingsStore.AdmissionSnapshot,
         central: CBCentralManager, peripheral: CBPeripheral, characteristic: CBCharacteristic,
         sequence: UInt16, permit: OperationPermit) throws {
        self.request = request; self.central = central; self.peripheral = peripheral
        self.characteristic = characteristic; self.permit = permit
        writer = try BluetoothCameraSettingWriter(request: request, baseline: baseline, sequence: sequence,
                                                  now: ProcessInfo.processInfo.systemUptime)
    }
}

@MainActor
private final class BluetoothTapFocusOperation {
    let request: BluetoothTapFocusRequest
    let central: CBCentralManager
    let peripheral: CBPeripheral
    let characteristic: CBCharacteristic
    let permit: OperationPermit
    var probe: BluetoothTapFocusProbe
    var connectionChanged = false
    var focusObserver: NSObjectProtocol?
    init(request: BluetoothTapFocusRequest, baseline: BluetoothTapFocusBaseline, central: CBCentralManager,
         peripheral: CBPeripheral, characteristic: CBCharacteristic, sequences: [UInt16], permit: OperationPermit, now: TimeInterval) throws {
        self.request = request; self.central = central; self.peripheral = peripheral
        self.characteristic = characteristic; self.permit = permit
        probe = try BluetoothTapFocusProbe(request: request, baseline: baseline, sequences: sequences, now: now)
    }
}

@MainActor
private final class BluetoothLensPointOperation {
    let session: UUID
    let central: CBCentralManager
    let peripheral: CBPeripheral
    let characteristic: CBCharacteristic
    let permit: OperationPermit
    let packet: Data
    var recorder: BluetoothFocusPointRecorder
    var connectionChanged = false
    init(session: UUID, central: CBCentralManager, peripheral: CBPeripheral,
         characteristic: CBCharacteristic, sequence: UInt16, permit: OperationPermit) throws {
        self.session = session; self.central = central; self.peripheral = peripheral
        self.characteristic = characteristic; self.permit = permit
        recorder = try BluetoothFocusPointRecorder(sessionID: session, peripheralID: peripheral.identifier,
            sequence: sequence, transactionID: UInt32.random(in: 1...UInt32.max), startedUptime: ProcessInfo.processInfo.systemUptime)
        packet = try DUMLCodec.encode(recorder.request)
    }
}

@MainActor
private final class BluetoothLensStateOperation {
    let session: UUID
    let central: CBCentralManager
    let peripheral: CBPeripheral
    let characteristic: CBCharacteristic
    let permit: OperationPermit
    let packet: Data
    var query: BluetoothLensStateQuery
    var connectionChanged = false
    init(session: UUID, central: CBCentralManager, peripheral: CBPeripheral,
         characteristic: CBCharacteristic, sequence: UInt16, permit: OperationPermit) throws {
        self.session = session; self.central = central; self.peripheral = peripheral
        self.characteristic = characteristic; self.permit = permit
        query = BluetoothLensStateQuery(sequence: sequence, transactionID: UInt32.random(in: 1...UInt32.max),
            startedUptime: ProcessInfo.processInfo.systemUptime)
        packet = try DUMLCodec.encode(query.request)
    }
}

@MainActor
private final class BluetoothCameraPropertyOperation {
    let session: UUID
    let binding: ContinuousGimbalBinding
    let central: CBCentralManager
    let peripheral: CBPeripheral
    let characteristic: CBCharacteristic
    let permit: OperationPermit
    let packet: Data
    var query: BluetoothCameraPropertyQuery
    var connectionChanged = false
    init(property: CameraSettingsProperty, session: UUID, central: CBCentralManager, peripheral: CBPeripheral,
         characteristic: CBCharacteristic, sequence: UInt16, permit: OperationPermit) throws {
        self.session = session; self.central = central; self.peripheral = peripheral
        self.characteristic = characteristic; self.permit = permit
        binding = ContinuousGimbalBinding(sessionID: "ble:\(session.uuidString)", generation: 0)
        query = try BluetoothCameraPropertyQuery(property: property, binding: binding, sequence: sequence, transactionID: UInt32.random(in: 1...UInt32.max),
            startedUptime: ProcessInfo.processInfo.systemUptime)
        packet = try DUMLCodec.encode(query.request)
    }
}

@MainActor
private final class BluetoothNativePresetOperation {
    let session: UUID
    let central: CBCentralManager
    let peripheral: CBPeripheral
    let characteristic: CBCharacteristic
    let permit: OperationPermit
    let packet: Data
    var evidence: BluetoothNativePresetProbe
    var connectionChanged = false
    var focusObserver: NSObjectProtocol?

    init(session: UUID, central: CBCentralManager, peripheral: CBPeripheral,
         characteristic: CBCharacteristic, sequence: UInt16, permit: OperationPermit) throws {
        self.session = session; self.central = central; self.peripheral = peripheral
        self.characteristic = characteristic; self.permit = permit
        evidence = BluetoothNativePresetProbe(sequence: sequence, startedUptime: ProcessInfo.processInfo.systemUptime,
            registrationAcknowledgmentSubmitted: true)
        packet = try DUMLCodec.encode(evidence.request)
        guard packet.count == BluetoothNativePresetProbe.frameBytes else {
            throw BridgeFailure("bluetooth_recenter_packet", "The recenter command must fit one exact 15-byte frame.")
        }
    }
}

@MainActor
private final class BluetoothProbeOperation {
    let session: UUID
    let central: CBCentralManager
    let peripheral: CBPeripheral
    let characteristic: CBCharacteristic
    let permit: OperationPermit
    let pulses: [Data]
    let neutral: Data
    var evidence: BluetoothGimbalProbeEvidence
    var connectionChanged = false
    var cleanupTask: Task<Bool, Never>?
    var focusObserver: NSObjectProtocol?

    init(session: UUID, central: CBCentralManager, peripheral: CBPeripheral,
         characteristic: CBCharacteristic, sequences: [UInt16], permit: OperationPermit) throws {
        guard sequences.count == 5 else { throw BridgeFailure("bluetooth_probe_sequence", "Five coordinated sequence numbers are required.") }
        self.session = session; self.central = central; self.peripheral = peripheral; self.characteristic = characteristic
        self.permit = permit
        pulses = try sequences.prefix(4).map(BluetoothGimbalProbePlan.pulse(sequence:))
        neutral = try DUMLJoystickCommand.neutral.encodedFrame(sequence: sequences[4])
        evidence = BluetoothGimbalProbeEvidence(startedUptime: ProcessInfo.processInfo.systemUptime,
            registrationAcknowledgmentSubmitted: true)
    }
}

@MainActor
private final class BluetoothReadinessOperation {
    let session: UUID
    let peripheral: CBPeripheral
    let characteristic: CBCharacteristic
    let permit: OperationPermit
    var query: BluetoothReadinessQuery
    init(session: UUID, peripheral: CBPeripheral, characteristic: CBCharacteristic, sequence: UInt16, permit: OperationPermit) {
        self.session = session; self.peripheral = peripheral; self.characteristic = characteristic; self.permit = permit
        query = BluetoothReadinessQuery(sequence: sequence, startedUptime: ProcessInfo.processInfo.systemUptime)
    }
}

/// Each explicit connection owns a delegate with its immutable session token.
@MainActor
private final class BluetoothPeripheralDelegate: NSObject, @preconcurrency CBPeripheralDelegate {
    weak var owner: Pocket3BluetoothDiscovery?
    let session: UUID
    init(owner: Pocket3BluetoothDiscovery, session: UUID) { self.owner = owner; self.session = session; super.init() }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        owner?.discoveredServices(peripheral, error: error, session: session)
    }
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        owner?.invalidatedServices(peripheral, services: invalidatedServices, session: session)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        owner?.discoveredCharacteristics(peripheral, service: service, error: error, session: session)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        owner?.notificationState(peripheral, characteristic: characteristic, error: error, session: session)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        owner?.notified(peripheral, characteristic: characteristic, error: error, session: session)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        owner?.armWritten(peripheral, characteristic: characteristic, error: error, session: session)
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let owner, owner.status.sessionID == session, owner.status.selectedPeripheralID == peripheral.identifier else { return }
        owner.drainWrites()
    }
}
