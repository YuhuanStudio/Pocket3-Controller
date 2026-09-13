import Foundation

public enum Pocket3DatalinkPhase: String, Codable, Sendable { case idle, connecting, ready, disarmed, error }
public struct Pocket3DatalinkTelemetry: Codable, Sendable, Equatable {
    public let pitchDegrees: Double
    public let rollDegrees: Double
    public let yawDegrees: Double
    public let receivedAt: Date
}
public struct Pocket3DatalinkStatus: Codable, Sendable {
    public var phase: Pocket3DatalinkPhase = .idle
    public var binding: ContinuousGimbalBinding?
    public var lastHeartbeatAge: TimeInterval?
    public var lastTelemetryAge: TimeInterval?
    public var telemetry: Pocket3DatalinkTelemetry?
    public var battery: Pocket3BatteryTelemetry?
    public var identityEvidence = "fixed_ipv4_and_correlated_duml_reply;not_cryptographic_device_identity"
    public var pairedDeviceID: String?
    public var receivedDatagrams = 0
    public var rejectedDatagrams = 0
    public var unmatchedHeartbeatReplies = 0
    public var replayedOrReorderedControlDatagrams = 0
    public var transmitLagSlots: Int = 0
    public var lastErrorCode: String?
    public var tcpBootstrapErrorCode: String?
    public var lastStop: Pocket3DatalinkStopResult?
}
public struct Pocket3DatalinkDisconnectResult: Codable, Sendable {
    public let neutralSent: Bool
    public let failure: String?
}
public struct Pocket3DatalinkActionResult: Codable, Sendable {
    public let command: String
    public let requestAccepted: Bool
    public let responseStatus: UInt16
    public let physicalCompletionVerified: Bool
}

/// Explicit-only Pocket 3 datalink. One queue owns sockets, ACKs, parsing and
/// all writes. No network switching, CoreBluetooth initialization or live-view
/// START commands are performed. Pairing/network selection belongs to the App.
public final class Pocket3Datalink: ContinuousGimbalTransport,
    ContinuousGimbalInputTransport, @unchecked Sendable {
    public static let host = "192.168.2.1"
    public static let maximumTelemetryAge: TimeInterval = 0.35
    public static let maximumHeartbeatAge: TimeInterval = 3
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let io: any Pocket3DatalinkIO
    private let clientIdentifier: String
    private let maximumQueuedOperations: Int
    private var snapshot = Pocket3DatalinkStatus()
    private var generation: UInt64 = 0
    private var motionEpoch: UInt64 = 0
    private var motionIntentCounter: UInt64 = 0
    private var stopVerificationID: UUID?
    private var stopVerificationTask: (binding: ContinuousGimbalBinding, epoch: UInt64, intent: UInt64, task: Task<Pocket3DatalinkStopResult, Never>)?
    private var connectionPermit: OperationPermit?
    private var velocityPermit: OperationPermit?
    private var heartbeatTime: TimeInterval?
    private var telemetryTime: TimeInterval?
    private var disconnectTask: Task<Pocket3DatalinkDisconnectResult, Never>?
    private var pendingOperations = 0
    // Optional receive-only live-view consumer.  The transport remains the
    // sole socket/control owner; this slot is never constructed by default.
    private var liveViewSink: (token: Pocket3DatalinkLiveViewSinkToken,
                               sink: any Pocket3DatalinkLiveViewSink)?

    // Owner-queue state only.
    private var window: DJIUDPWindowState?
    private var dumlSequence: UInt16 = 0xa000
    private var commandCounter: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var ownerReady = false
    private var activeLease: UUID?
    private var retiredLeases: [UUID] = []
    private var pendingHeartbeats: [UInt16: TimeInterval] = [:]
    private var nativeActionSequence: UInt16?
    private var nativeActionReply: UInt16?
    private var nextAck: TimeInterval = 0
    private var nextHeartbeat: TimeInterval = 0
    private var nextPresence: TimeInterval = 0
    private var ownerStopVerifier: NativeStopTelemetryVerifier?
    private var telemetrySequenceAdmission = NativeTelemetrySequenceAdmission()
    private var nativeCommandTransactionID: UUID?
    private var pendingNativeCommand: (id: UUID, sequence: UInt16, matcher: NativeCommandResponseMatcher,
                                        observation: (@Sendable (DUMLFrame) -> Data?)?)?
    private var nativeCommandReply: DUMLFrame?
    private var nativeCommandObservedPayload: Data?
    private var nativeCommandObservedUptime: TimeInterval?
    private var nativeCommandObservationTooLarge = false

    public convenience init(clientIdentifier: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""), pairedDeviceID: String? = nil) {
        self.init(io: Pocket3DatalinkSocket(), clientIdentifier: clientIdentifier, pairedDeviceID: pairedDeviceID)
    }
    /// Explicit network configuration for callers that already have a
    /// route-safe plan.  A bound interface without a matching allowed plan is
    /// rejected by the socket before any TCP/UDP descriptor is opened.
    public convenience init(clientIdentifier: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                            pairedDeviceID: String? = nil,
                            networkConfiguration: Pocket3DatalinkSocketConfiguration,
                            routePlan: Pocket3DatalinkRoutePlan? = nil) {
        self.init(io: Pocket3DatalinkSocket(configuration: networkConfiguration,
                                             routePlan: routePlan),
                  clientIdentifier: clientIdentifier, pairedDeviceID: pairedDeviceID)
    }
    init(io: any Pocket3DatalinkIO, clientIdentifier: String, pairedDeviceID: String? = nil,
         queue: DispatchQueue? = nil, maximumQueuedOperations: Int = 16) {
        self.io = io; self.clientIdentifier = clientIdentifier
        self.queue = queue ?? DispatchQueue(label: "studio.yuhuan.pocket3.native-datalink", qos: .userInitiated)
        self.maximumQueuedOperations = max(0, min(maximumQueuedOperations, 16))
        snapshot.pairedDeviceID = pairedDeviceID.map { String($0.prefix(128)) }
    }
    public func status() async -> Pocket3DatalinkStatus {
        let now = io.now
        return lock.withLock {
            var result = snapshot
            result.lastHeartbeatAge = heartbeatTime.map { max(0, now - $0) }
            result.lastTelemetryAge = telemetryTime.map { max(0, now - $0) }
            if result.battery?.isFresh(now: Date()) != true { result.battery = nil }
            return result
        }
    }

    /// Attach one passive pktType-02 consumer to an exact datalink
    /// generation.  Replacing an existing sink flushes the old sink first;
    /// this method never sends a packet or enables live view.
    @discardableResult
    public func attachLiveViewSink(
        _ sink: any Pocket3DatalinkLiveViewSink,
        generation: UInt64
    ) -> Pocket3DatalinkLiveViewSinkToken {
        let token = Pocket3DatalinkLiveViewSinkToken(generation: generation)
        guard generation != 0 else { return token }
        let replaced = lock.withLock {
            let old = liveViewSink
            liveViewSink = (token: token, sink: sink)
            return old
        }
        if let replaced {
            replaced.sink.flush(generation: replaced.token.generation)
        }
        sink.attach(generation: generation)
        return token
    }

    /// Binding overload that derives the generation from the caller's exact
    /// connection lease.
    @discardableResult
    public func attachLiveViewSink(
        _ sink: any Pocket3DatalinkLiveViewSink,
        binding: ContinuousGimbalBinding
    ) -> Pocket3DatalinkLiveViewSinkToken {
        attachLiveViewSink(sink, generation: binding.generation)
    }

    public func detachLiveViewSink(_ token: Pocket3DatalinkLiveViewSinkToken) {
        let detached = lock.withLock { () -> (Pocket3DatalinkLiveViewSinkToken,
                                               any Pocket3DatalinkLiveViewSink)? in
            guard let current = liveViewSink, current.token == token else {
                return nil
            }
            liveViewSink = nil
            return current
        }
        if let detached {
            detached.1.flush(generation: detached.0.generation)
        }
    }

    /// Diagnostic state only; attaching a sink does not imply command or
    /// decoder readiness.
    public var hasLiveViewSink: Bool {
        lock.withLock { liveViewSink != nil }
    }

    /// The caller must explicitly select the Pocket network beforehand. A
    /// handshake is not permission to move: fresh correlated 04/50 plus 04/05
    /// are required, and the App must separately grant a manual-control lease.
    public func connect() async throws -> ContinuousGimbalBinding {
        try Task.checkCancellation()
        let pairing = try Pocket3DatalinkProtocol.pairingFrame(clientIdentifier: clientIdentifier)
        let permit = OperationPermit()
        let binding = try lock.withLock { () throws -> ContinuousGimbalBinding in
            guard snapshot.binding == nil, disconnectTask == nil else { throw BridgeFailure("native_busy", "請先中斷目前的無線連接") }
            generation &+= 1; motionEpoch &+= 1
            let binding = ContinuousGimbalBinding(sessionID: UUID().uuidString, generation: generation)
            snapshot.phase = .connecting; snapshot.binding = binding; snapshot.lastErrorCode = nil
            snapshot.tcpBootstrapErrorCode = nil; snapshot.telemetry = nil; snapshot.battery = nil
            snapshot.lastStop = nil; stopVerificationID = nil
            snapshot.receivedDatagrams = 0; snapshot.rejectedDatagrams = 0; snapshot.unmatchedHeartbeatReplies = 0
            snapshot.replayedOrReorderedControlDatagrams = 0
            heartbeatTime = nil; telemetryTime = nil; connectionPermit = permit
            return binding
        }
        do { return try await queued(permit: permit) { [self] in
            do {
                try checkpoint(binding, permit: permit)
                resetOwner()
                do { try io.tcpPoke(pairing, permit: permit) }
                catch {
                    try permit.perform {}
                    // The pinned implementation also continues to UDP if the
                    // bounded TCP bootstrap fails; readiness still must pass.
                    lock.withLock { snapshot.tcpBootstrapErrorCode = code(error) }
                }
                try checkpoint(binding, permit: permit)
                try io.openUDP()
                let session = UInt16.random(in: 0x1000..<0xfffe)
                let base = UInt16.random(in: 0x1000..<0xf000) & 0xfff8
                window = DJIUDPWindowState(sessionID: session, baseSequence: base)
                var handshakeReceived = false
                for _ in 0..<20 {
                    try checkpoint(binding, permit: permit)
                    try sendRaw(.handshake, payload: Pocket3DatalinkProtocol.handshake(baseSequence: base), binding: binding, permit: permit)
                    handshakeReceived = try drain(for: 0.35, binding: binding, permit: permit, stopAtHandshake: true)
                    if handshakeReceived { break }
                }
                guard handshakeReceived else { throw BridgeFailure("native_handshake_timeout", "Pocket 3 無線握手未完成") }
                for _ in 0..<5 { _ = try drain(for: 0.4, binding: binding, permit: permit); try sendAck(binding, permit: permit) }
                try window?.synchronizeToPeerChannel()
                _ = try sendControl(set: 0, command: 0x81, payload: Pocket3DatalinkProtocol.appDeviceInfo, destination: 0x48, flags: 0x80, binding: binding, permit: permit)
                _ = try drain(for: 0.4, binding: binding, permit: permit); try sendAck(binding, permit: permit)
                _ = try sendControl(set: 0, command: 0x88, payload: Pocket3DatalinkProtocol.appPresence, destination: 0x28, binding: binding, permit: permit)
                _ = try drain(for: 0.4, binding: binding, permit: permit); try sendAck(binding, permit: permit)
                _ = try sendControl(set: 3, command: 0xda, payload: Pocket3DatalinkProtocol.initialization, destination: 3, binding: binding, permit: permit)
                _ = try drain(for: 0.4, binding: binding, permit: permit); try sendAck(binding, permit: permit)
                try sendHeartbeat(binding, permit: permit)
                _ = try drain(for: 0.6, binding: binding, permit: permit); try sendAck(binding, permit: permit)
                try checkpoint(binding, permit: permit)
                guard feedbackIsFresh() else { throw BridgeFailure("native_feedback_unavailable", "尚未取得有效的 Pocket 3 雲台心跳及姿態，移動未開放") }
                ownerReady = true
                lock.withLock { if snapshot.binding == binding { snapshot.phase = .ready } }
                nextHeartbeat = io.now + 0.7; nextPresence = io.now + 0.9; nextAck = io.now + 0.25
                startMaintenance(binding)
                return binding
            } catch {
                closeOwner(binding: binding, phase: .error, errorCode: code(error))
                throw error
            }
        } } catch {
            // Covers cancellation before the owner-queue closure was entered
            // too; otherwise a reserved binding could remain connecting forever.
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    closeOwner(binding: binding, phase: .error, errorCode: code(error))
                    continuation.resume()
                }
            }
            throw error
        }
    }

    public func send(_ command: DUMLJoystickCommand, lease: ContinuousGimbalLease, permit: OperationPermit) async throws {
        let epoch = try permit.perform {
            try lock.withLock { () throws -> UInt64 in
                guard snapshot.binding == lease.binding else { throw ContinuousGimbalError.staleLease }
                if !command.isNeutral {
                    guard snapshot.phase == .ready else { throw BridgeFailure("native_disarmed", "無線雲台目前未開放移動") }
                    motionIntentCounter &+= 1; snapshot.lastStop = nil
                }
                return motionEpoch
            }
        }
        try await queued(permit: permit, priorityStop: command.isNeutral) { [self] in
            try checkpoint(lease.binding, permit: permit)
            if command.isNeutral {
                guard activeLease == nil || activeLease == lease.id else { throw ContinuousGimbalError.staleLease }
                try safetyNeutral(lease.binding, permit: permit)
                retire(lease.id)
                return
            }
            guard !retiredLeases.contains(lease.id), activeLease == nil || activeLease == lease.id else { throw ContinuousGimbalError.staleLease }
            guard feedbackIsFresh(), Int(window?.transmitLagSlots ?? 0) <= 64 else {
                disarm(binding: lease.binding, reason: "native_feedback_stale")
                throw BridgeFailure("native_feedback_stale", "雲台回報已過期，已撤回移動")
            }
            let frame = command.frame(sequence: dumlSequence)
            try sendFrame(frame, binding: lease.binding, permit: permit, motionEpoch: epoch, requireReady: true)
            activeLease = lease.id
            lock.withLock { velocityPermit = permit }
        }
    }

    /// Adapter entry used by the native continuous-control scheduler. The
    /// datalink remains the only UDP9004 owner and keeps sequence/cursor
    /// allocation inside its queue.
    public func send(_ input: ContinuousGimbalInput,
                     lease: ContinuousGimbalLease,
                     permit: OperationPermit) async throws {
        let command = try DUMLJoystickCommand.encode(
            x: input.x, y: input.y, speed: input.speed)
        try await send(command, lease: lease, permit: permit)
    }

    /// Global Stop without constructing a scheduler lease. This completes a
    /// neutral network send only; it does not certify physical stopping.
    public func neutral(binding: ContinuousGimbalBinding, permit: OperationPermit) async throws {
        let oldPermit = try lock.withLock { () throws -> OperationPermit? in
            guard snapshot.binding == binding else { throw ContinuousGimbalError.staleLease }
            motionEpoch &+= 1
            let old = velocityPermit; velocityPermit = nil
            return old
        }
        oldPermit?.invalidate()
        try await queued(permit: permit, priorityStop: true) { [self] in
            let retired = activeLease
            try safetyNeutral(binding, permit: permit)
            if let retired { retire(retired) }
        }
    }

    /// Safety cleanup survives caller/IPC cancellation and an invalidated
    /// caller permit. Neutral uses its own permit; telemetry waiting is bounded
    /// to 1.5 seconds. A new movement request supersedes this evidence window.
    public func neutralAndVerify(binding: ContinuousGimbalBinding, permit _: OperationPermit = OperationPermit()) async -> Pocket3DatalinkStopResult {
        let pending = lock.withLock { () -> (Task<Pocket3DatalinkStopResult, Never>, OperationPermit?) in
            if let existing = stopVerificationTask, existing.binding == binding,
               existing.epoch == motionEpoch, existing.intent == motionIntentCounter {
                return (existing.task, nil)
            }
            guard snapshot.binding == binding else {
                return (Task { Pocket3DatalinkStopResult(binding: binding, connectionChanged: true, failure: "native_connection_changed") }, nil)
            }
            motionEpoch &+= 1
            let epoch = motionEpoch, intent = motionIntentCounter, id = UUID()
            let oldPermit = velocityPermit; velocityPermit = nil
            snapshot.lastStop = nil; stopVerificationID = id
            let task = Task.detached(priority: .userInitiated) { [self] in
                await withCheckedContinuation { continuation in
                    queue.async { [self] in
                        let value = verifyNeutralOnOwner(binding: binding, epoch: epoch, intent: intent, id: id)
                        continuation.resume(returning: value)
                    }
                }
            }
            stopVerificationTask = (binding, epoch, intent, task)
            return (task, oldPermit)
        }
        pending.1?.invalidate()
        return await pending.0.value
    }

    private func verifyNeutralOnOwner(binding: ContinuousGimbalBinding, epoch: UInt64, intent: UInt64, id: UUID) -> Pocket3DatalinkStopResult {
        var result = Pocket3DatalinkStopResult(binding: binding)
        let safetyPermit = OperationPermit()
        var started = io.now
        let wallDeadline = ProcessInfo.processInfo.systemUptime + NativeStopTelemetryVerifier.maximumDuration
        defer { ownerStopVerifier = nil }
        do {
            try verifyStopOwnership(binding: binding, epoch: epoch, intent: intent, id: id)
            // Consume already queued control traffic before establishing the
            // neutral receive-time boundary. Sensor acquisition times are not
            // available in 04/05, so the result claims host-received evidence.
            _ = try receive(binding, timeoutMS: 0, permit: safetyPermit)
            let retired = activeLease
            try safetyNeutral(binding, permit: safetyPermit, epoch: epoch, expectedMotionIntent: intent)
            if let retired { retire(retired) }
            result.neutralSent = true; started = io.now
            guard started.isFinite else { throw BridgeFailure("native_clock_invalid", "無法確認姿態回報時間") }
            ownerStopVerifier = NativeStopTelemetryVerifier(neutralSentUptime: started)
            while io.now - started <= NativeStopTelemetryVerifier.maximumDuration,
                  ProcessInfo.processInfo.systemUptime <= wallDeadline {
                try verifyStopOwnership(binding: binding, epoch: epoch, intent: intent, id: id)
                _ = try receive(binding, timeoutMS: 20, permit: safetyPermit)
                try maintenance(binding)
                try verifyStopOwnership(binding: binding, epoch: epoch, intent: intent, id: id)
                if ownerStopVerifier?.isStable(now: io.now) == true { result.stableTelemetry = true; break }
            }
            result.timedOut = !result.stableTelemetry
        } catch { result.failure = code(error) }
        result.elapsedSeconds = io.now.isFinite && started.isFinite ? max(0, io.now - started) : 0
        if let verifier = ownerStopVerifier {
            result.sampleCount = verifier.sampleCount; result.stableDurationSeconds = verifier.stableDurationSeconds
            result.maximumSpanDegrees = verifier.maximumObservedSpan; result.finalTelemetry = verifier.finalTelemetry
        }
        return lock.withLock {
            // Final check and publication are atomic with the next motion
            // intent. Stable evidence cannot be committed for a newer gesture.
            if snapshot.binding != binding || disconnectTask != nil {
                result.stableTelemetry = false; result.timedOut = false; result.connectionChanged = true
                result.failure = "native_connection_changed"
            } else if motionIntentCounter != intent {
                result.stableTelemetry = false; result.timedOut = false; result.replacedByNewMotion = true
                result.failure = "native_stop_replaced_by_motion"
            } else if motionEpoch != epoch || stopVerificationID != id {
                result.stableTelemetry = false; result.timedOut = false; result.failure = "native_stop_superseded"
            }
            let stillOwnsStop = snapshot.binding == binding && disconnectTask == nil && stopVerificationID == id
                && motionEpoch == epoch && motionIntentCounter == intent
            if stillOwnsStop && !result.stableTelemetry && (result.timedOut || result.failure != nil) {
                snapshot.phase = .disarmed; snapshot.lastErrorCode = result.failure ?? "native_stop_timeout"
            }
            if snapshot.binding == binding, stopVerificationID == id { snapshot.lastStop = result }
            if stopVerificationTask?.epoch == epoch { stopVerificationTask = nil }
            return result
        }
    }
    private func verifyStopOwnership(binding: ContinuousGimbalBinding, epoch: UInt64, intent: UInt64, id: UUID) throws {
        try lock.withLock {
            guard snapshot.binding == binding, disconnectTask == nil else { throw BridgeFailure("native_connection_changed", "無線連接已改變") }
            guard motionIntentCounter == intent else { throw BridgeFailure("native_stop_replaced_by_motion", "新的操作已取代停止驗證") }
            guard motionEpoch == epoch, stopVerificationID == id else { throw BridgeFailure("native_stop_superseded", "停止驗證已失效") }
        }
    }
    public func recenter(binding: ContinuousGimbalBinding, permit: OperationPermit) async throws -> Pocket3DatalinkActionResult {
        try await nativeAction("recenter", payload: Data([0xfe, 8]), binding: binding, permit: permit)
    }
    public func flip(binding: ContinuousGimbalBinding, permit: OperationPermit) async throws -> Pocket3DatalinkActionResult {
        try await nativeAction("flip", payload: Data([0xfe, 9]), binding: binding, permit: permit)
    }

    /// Sends one command through the existing owner queue.  The request's
    /// logical generation must match the caller's NativeCameraSession status;
    /// the datalink binding then supplies a second fence for disconnects and
    /// reconnects.  This method never joins Wi-Fi, starts live view, retries,
    /// or acquires the ContinuousGimbal lease.
    public func transact(_ request: NativeCommandTransactionRequest,
                         readiness: NativeCameraSessionStatus,
                         permit: OperationPermit = OperationPermit()) async throws -> NativeCommandTransactionResult {
        guard readiness.generation == request.generation else {
            throw NativeCommandTransactionError.staleGeneration
        }
        guard request.sessionID == nil || request.sessionID == readiness.sessionID else {
            throw NativeCommandTransactionError.staleGeneration
        }
        guard readiness.isReady(for: request.command) else {
            throw NativeCommandTransactionError.commandNotReady
        }
        let binding = try lock.withLock { () throws -> ContinuousGimbalBinding in
            guard snapshot.phase == .ready, let binding = snapshot.binding else {
                throw NativeCommandTransactionError.datalinkUnavailable
            }
            guard nativeCommandTransactionID == nil else {
                throw NativeCommandTransactionError.nativeBusy
            }
            nativeCommandTransactionID = request.id
            return binding
        }
        defer {
            lock.withLock {
                if nativeCommandTransactionID == request.id { nativeCommandTransactionID = nil }
            }
        }
        return try await queued(permit: permit) { [self] in
            executeNativeCommand(request, readiness: readiness, binding: binding, permit: permit)
        }
    }

    /// Descriptive spelling for adapters that treat the operation as an
    /// execution rather than a transport transaction.
    public func executeNativeCommand(_ request: NativeCommandTransactionRequest,
                                     readiness: NativeCameraSessionStatus,
                                     permit: OperationPermit = OperationPermit()) async throws -> NativeCommandTransactionResult {
        try await transact(request, readiness: readiness, permit: permit)
    }

    private func executeNativeCommand(_ request: NativeCommandTransactionRequest,
                                      readiness: NativeCameraSessionStatus,
                                      binding: ContinuousGimbalBinding,
                                      permit: OperationPermit) -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id, command: request.command,
            generation: request.generation, sessionID: request.sessionID)
        result.startedUptime = io.now
        defer {
            pendingNativeCommand = nil
            nativeCommandReply = nil
            nativeCommandObservedPayload = nil
            nativeCommandObservedUptime = nil
            nativeCommandObservationTooLarge = false
        }
        do {
            try checkpoint(binding, permit: permit)
            // This check is owner-queue serialized, so a transaction can
            // never steal an active ContinuousGimbal lease.  A caller must
            // stop the lease explicitly before trying again.
            guard activeLease == nil, velocityPermit == nil else {
                throw NativeCommandTransactionError.nativeBusy
            }
            guard readiness.generation == request.generation else {
                throw NativeCommandTransactionError.staleGeneration
            }
            guard readiness.isReady(for: request.command) else {
                throw NativeCommandTransactionError.commandNotReady
            }
            let sequence = dumlSequence
            pendingNativeCommand = (request.id, sequence, request.responseMatcher,
                                    request.observationHandler())
            nativeCommandReply = nil
            nativeCommandObservedPayload = nil
            nativeCommandObservedUptime = nil
            nativeCommandObservationTooLarge = false
            try sendFrame(request.frame.frame(sequence: sequence), binding: binding,
                          permit: permit, requireReady: true)
            result.sequence = sequence
            result.submitted = true
            result.submittedUptime = io.now

            let deadline = io.now + request.timeout
            while (nativeCommandReply == nil || (request.hasObservation && nativeCommandObservedPayload == nil))
                  && io.now < deadline {
                try checkpoint(binding, permit: permit)
                let remaining = max(0, deadline - io.now)
                let timeoutMS = max(0, min(20, Int((remaining * 1_000).rounded(.down))))
                _ = try receive(binding, timeoutMS: timeoutMS, permit: permit)
                try maintenance(binding)
            }
            guard let response = nativeCommandReply else {
                if nativeCommandObservationTooLarge {
                    result.end = .failed
                    result.failureCode = "native_command_observation_too_large"
                } else {
                    result.end = .timedOut
                    result.failureCode = request.hasObservation && nativeCommandObservedPayload != nil
                        ? "native_command_ack_timeout" : "native_command_timeout"
                }
                if let observed = nativeCommandObservedPayload {
                    result.observed = true; result.observedPayload = observed
                    result.observedUptime = nativeCommandObservedUptime
                }
                result.finishedUptime = io.now
                return result
            }
            result.responseReceived = true
            result.responseStatus = response.payload.first
            let responseAt = io.now
            result.acknowledged = response.payload.first == 0
            if result.acknowledged { result.acknowledgedUptime = responseAt }
            if nativeCommandObservationTooLarge {
                result.end = .failed
                result.failureCode = "native_command_observation_too_large"
                result.finishedUptime = responseAt
                return result
            }
            if let observed = nativeCommandObservedPayload {
                result.observed = true
                result.observedPayload = observed
                result.observedUptime = nativeCommandObservedUptime ?? responseAt
            } else if request.hasObservation {
                result.end = .timedOut
                result.failureCode = "native_command_observation_timeout"
                result.finishedUptime = responseAt
                return result
            }
            if !result.acknowledged {
                result.end = .rejected
                result.failureCode = result.responseStatus == nil ? "native_command_ack_invalid" : "native_command_nack"
            } else if result.observed { result.end = .observed }
            else { result.end = .acknowledged }
            result.finishedUptime = responseAt
            return result
        } catch {
            result.end = nativeCommandTransactionEnd(for: error)
            result.failureCode = code(error)
            result.finishedUptime = io.now
            return result
        }
    }

    private func nativeCommandTransactionEnd(for error: Error) -> NativeCommandTransactionEnd {
        if error is CancellationError || code(error) == "cancelled" { return .cancelled }
        if error is ContinuousGimbalError || code(error) == "native_connection_changed" { return .generationChanged }
        return .failed
    }

    private func nativeAction(_ name: String, payload: Data, binding: ContinuousGimbalBinding, permit: OperationPermit) async throws -> Pocket3DatalinkActionResult {
        let epoch = try permit.perform {
            try lock.withLock { () throws -> UInt64 in
                guard snapshot.binding == binding, snapshot.phase == .ready else { throw BridgeFailure("native_disarmed", "請先建立可控制的無線連接") }
                motionIntentCounter &+= 1; snapshot.lastStop = nil
                return motionEpoch
            }
        }
        return try await queued(permit: permit) { [self] in
            guard activeLease == nil, feedbackIsFresh() else { throw BridgeFailure("native_busy", "請先放開搖桿並等待新姿態回報") }
            defer { nativeActionSequence = nil; nativeActionReply = nil }
            do {
                try checkpoint(binding, permit: permit, epoch: epoch)
                try safetyNeutral(binding, permit: permit)
                nativeActionReply = nil
                nativeActionSequence = try sendControl(set: 4, command: 0x4c, payload: payload, destination: 4, binding: binding, permit: permit, motionEpoch: epoch, requireReady: true)
                let deadline = io.now + 2
                while nativeActionReply == nil && io.now < deadline {
                    try checkpoint(binding, permit: permit, epoch: epoch)
                    _ = try receive(binding, timeoutMS: 20); try maintenance(binding)
                }
                guard let response = nativeActionReply else { throw BridgeFailure("native_action_timeout", "原生雲台命令尚未獲得確認") }
                return Pocket3DatalinkActionResult(command: name, requestAccepted: response == 0, responseStatus: response, physicalCompletionVerified: false)
            } catch {
                _ = try? safetyNeutral(binding, permit: OperationPermit())
                disarm(binding: binding, reason: code(error))
                throw error
            }
        }
    }

    @discardableResult
    public func disconnect() async -> Pocket3DatalinkDisconnectResult {
        let pending = lock.withLock { () -> (Task<Pocket3DatalinkDisconnectResult, Never>, OperationPermit?, OperationPermit?) in
            if let existing = disconnectTask { return (existing, nil, nil) }
            let binding = snapshot.binding, connectPermit = self.connectionPermit, motionPermit = velocityPermit
            motionEpoch &+= 1; snapshot.phase = binding == nil ? .idle : .disarmed
            velocityPermit = nil
            let task = Task.detached { [self] in
                return await withCheckedContinuation { continuation in
                    queue.async { [self] in
                        var sent = false, failure: String?
                        if let binding, ownerReady, io.isOpen {
                            do { try safetyNeutral(binding, permit: OperationPermit()); sent = true }
                            catch { failure = code(error) }
                        }
                        closeOwner(binding: binding, phase: .idle, errorCode: nil)
                        lock.withLock { disconnectTask = nil }
                        continuation.resume(returning: Pocket3DatalinkDisconnectResult(neutralSent: sent, failure: failure))
                    }
                }
            }
            disconnectTask = task
            return (task, connectPermit, motionPermit)
        }
        pending.1?.invalidate(); pending.2?.invalidate()
        return await pending.0.value // Caller cancellation cannot cancel final neutral/close.
    }

    private func queued<T: Sendable>(permit: OperationPermit, priorityStop: Bool = false, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let admitted = lock.withLock { () -> Bool in
                guard pendingOperations < maximumQueuedOperations + (priorityStop ? 4 : 0) else { return false }
                pendingOperations += 1; return true
            }
            guard admitted else { throw BridgeFailure("native_busy", "無線通訊工作佇列已滿") }
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    defer { lock.withLock { pendingOperations -= 1 } }
                    do { try permit.perform {}; continuation.resume(returning: try work()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { permit.invalidate() }
    }
    private func checkpoint(_ binding: ContinuousGimbalBinding, permit: OperationPermit, epoch: UInt64? = nil) throws {
        try permit.perform {
            try lock.withLock {
                guard snapshot.binding == binding, disconnectTask == nil,
                      epoch == nil || epoch == motionEpoch else { throw ContinuousGimbalError.staleLease }
            }
        }
    }
    private func finalSend(_ packet: Data, binding: ContinuousGimbalBinding, permit: OperationPermit, motionEpoch expectedEpoch: UInt64? = nil, expectedMotionIntent: UInt64? = nil, requireReady: Bool = false) throws {
        // This exact synchronous nonblocking send is inside both fences. No
        // NWConnection callback can transmit it later after invalidation.
        try permit.perform {
            try lock.withLock {
                guard snapshot.binding == binding, expectedEpoch == nil || expectedEpoch == motionEpoch else { throw ContinuousGimbalError.staleLease }
                guard expectedMotionIntent == nil || expectedMotionIntent == motionIntentCounter else { throw BridgeFailure("native_stop_replaced_by_motion", "新的操作已取代停止驗證") }
                if requireReady {
                    guard snapshot.phase == .ready, fresh(telemetryTime, limit: Self.maximumTelemetryAge), fresh(heartbeatTime, limit: Self.maximumHeartbeatAge) else {
                        throw BridgeFailure("native_disarmed", "雲台回報已過期或控制已撤回")
                    }
                }
                try io.send(packet)
            }
        }
    }
    private func sendRaw(_ type: DJIUDPPacketType, payload: Data, binding: ContinuousGimbalBinding, permit: OperationPermit) throws {
        guard let window else { throw BridgeFailure("native_not_connected", "尚未建立無線通訊") }
        let sequence = window.nextTransmitSequence
        let packet = try DJIUDPFraming.encode(packetType: type, payload: payload, sessionID: window.sessionID, sequence: sequence)
        try finalSend(packet, binding: binding, permit: permit)
        try self.window?.recordSuccessfulSend(sequence: sequence, packetType: type)
    }
    private func sendFrame(_ frame: DUMLFrame, binding: ContinuousGimbalBinding, permit: OperationPermit, motionEpoch: UInt64? = nil, expectedMotionIntent: UInt64? = nil, requireReady: Bool = false) throws {
        guard let window, window.isSynchronized else { throw BridgeFailure("native_not_synchronized", "無線通訊序號尚未同步") }
        let counter = commandCounter &+ 1
        let packet = try DJIUDPFraming.command(frame: frame, sessionID: window.sessionID, sequence: window.nextTransmitSequence,
            peerAcknowledgment: window.peerAcknowledgedTransmitSequence, commandCounter: counter)
        try finalSend(packet, binding: binding, permit: permit, motionEpoch: motionEpoch, expectedMotionIntent: expectedMotionIntent, requireReady: requireReady)
        try self.window?.recordSuccessfulSend(sequence: window.nextTransmitSequence, packetType: .command)
        commandCounter = counter; dumlSequence &+= 1
    }
    @discardableResult
    private func sendControl(set: UInt8, command: UInt8, payload: Data, destination: UInt8,
                             flags: UInt8 = 0x40, binding: ContinuousGimbalBinding, permit: OperationPermit,
                             motionEpoch: UInt64? = nil, requireReady: Bool = false) throws -> UInt16 {
        let sequence = dumlSequence
        try sendFrame(DUMLFrame(source: 2, destination: destination, sequence: sequence, flags: flags,
            commandSet: set, commandID: command, payload: payload), binding: binding, permit: permit,
            motionEpoch: motionEpoch, requireReady: requireReady)
        return sequence
    }
    private func sendHeartbeat(_ binding: ContinuousGimbalBinding, permit: OperationPermit) throws {
        let sequence = try sendControl(set: 4, command: 0x50, payload: Pocket3DatalinkProtocol.heartbeat, destination: 4, binding: binding, permit: permit)
        pendingHeartbeats = pendingHeartbeats.filter { io.now - $0.value < 8 }
        if pendingHeartbeats.count >= 8, let oldest = pendingHeartbeats.min(by: { $0.value < $1.value })?.key { pendingHeartbeats.removeValue(forKey: oldest) }
        pendingHeartbeats[sequence] = io.now
    }
    private func sendAck(_ binding: ContinuousGimbalBinding, permit: OperationPermit) throws {
        guard let window else { return }
        try finalSend(window.acknowledgmentPacket(), binding: binding, permit: permit)
        nextAck = io.now + 0.25
    }
    private func safetyNeutral(_ binding: ContinuousGimbalBinding, permit: OperationPermit, epoch: UInt64? = nil, expectedMotionIntent: UInt64? = nil) throws {
        try sendFrame(DUMLJoystickCommand.neutral.frame(sequence: dumlSequence), binding: binding, permit: permit, motionEpoch: epoch, expectedMotionIntent: expectedMotionIntent)
        lock.withLock { velocityPermit = nil }
        activeLease = nil
    }
    private func retire(_ id: UUID) {
        activeLease = nil
        if !retiredLeases.contains(id) { retiredLeases.append(id) }
        if retiredLeases.count > 32 { retiredLeases.removeFirst(retiredLeases.count - 32) }
    }
    private func fresh(_ timestamp: TimeInterval?, limit: TimeInterval) -> Bool {
        guard let timestamp else { return false }
        let age = io.now - timestamp
        return age.isFinite && age >= 0 && age <= limit
    }
    private func feedbackIsFresh() -> Bool {
        lock.withLock { fresh(telemetryTime, limit: Self.maximumTelemetryAge) && fresh(heartbeatTime, limit: Self.maximumHeartbeatAge) }
    }
    private func receive(_ binding: ContinuousGimbalBinding, timeoutMS: Int, permit: OperationPermit = OperationPermit()) throws -> Bool {
        try checkpoint(binding, permit: permit)
        guard let sessionID = window?.sessionID else { return false }
        var handshake = false, accepted = false
        for bytes in try io.receive(timeoutMS: timeoutMS) {
            guard let datagram = try? DJIUDPFraming.decode(bytes, expectedSessionID: sessionID),
                  var state = window, case .accepted(let type) = state.observe(datagram) else {
                lock.withLock { snapshot.rejectedDatagrams += 1 }; continue
            }
            window = state
            let telemetryIsNew = telemetrySequenceAdmission.accept(type: type, sequence: datagram.header.sequence)
            if (type == .channel3 || type == .command) && !telemetryIsNew {
                lock.withLock { snapshot.replayedOrReorderedControlDatagrams += 1 }
            }
            accepted = true
            if type == .handshake && datagram.payload.count >= 2 { handshake = true }
            lock.withLock { snapshot.receivedDatagrams += 1; snapshot.transmitLagSlots = Int(window?.transmitLagSlots ?? 0) }
            if type == .video,
               let sink = lock.withLock({ () -> (any Pocket3DatalinkLiveViewSink)? in
                guard let current = liveViewSink,
                      current.token.generation == generation else { return nil }
                return current.sink
            }) {
                // Only the already accepted type-02 datagram is forwarded.
                // The sink has no path back into this transport's sender.
                sink.receive(datagram, generation: generation)
            }
            for frame in Pocket3DatalinkProtocol.controlFrames(in: datagram) {
                let matchesNativeCommand = pendingNativeCommand.map {
                    $0.matcher.matches(frame, sequence: $0.sequence)
                } == true
                if matchesNativeCommand, nativeCommandReply == nil { nativeCommandReply = frame }
                if nativeCommandObservedPayload == nil,
                   let handler = pendingNativeCommand?.observation,
                   let observed = handler(frame) {
                    if observed.count <= DUMLCodec.maximumPayloadLength {
                        nativeCommandObservedPayload = observed
                        nativeCommandObservedUptime = io.now
                    } else {
                        nativeCommandObservationTooLarge = true
                    }
                }
                guard frame.destination & 0x1f == 2 else { continue }
                if frame.commandSet == 4, frame.commandID == 0x50, frame.source & 0x1f == 4, !frame.payload.isEmpty {
                    if matchesNativeCommand {
                        // A gimbal 04/50 GET shares the heartbeat command ID;
                        // its exact transaction match must not be counted as
                        // an unmatched heartbeat.
                    } else if frame.flags & 0x80 != 0, pendingHeartbeats.removeValue(forKey: frame.sequence) != nil {
                        lock.withLock { heartbeatTime = io.now }
                    } else { lock.withLock { snapshot.unmatchedHeartbeatReplies += 1 } }
                } else if frame.commandSet == 4, frame.commandID == 5, frame.source & 0x1f == 4, frame.payload.count >= 6, telemetryIsNew {
                    let p = Array(frame.payload.prefix(6))
                    func angle(_ offset: Int) -> Double { Double(Int16(bitPattern: UInt16(p[offset]) | UInt16(p[offset + 1]) << 8)) / 10 }
                    let pitch = angle(0), roll = angle(2), yaw = angle(4)
                    guard abs(pitch) <= 360, abs(roll) <= 360, abs(yaw) <= 360 else { continue }
                    let telemetry = Pocket3DatalinkTelemetry(pitchDegrees: pitch, rollDegrees: roll, yawDegrees: yaw, receivedAt: Date())
                    let receivedUptime = io.now
                    lock.withLock { snapshot.telemetry = telemetry; telemetryTime = receivedUptime }
                    ownerStopVerifier?.receive(telemetry, receivedUptime: receivedUptime,
                        packetSequence: datagram.header.sequence, messageSequence: frame.sequence, now: receivedUptime)
                } else if frame.commandSet == 4, frame.commandID == 0x4c, frame.source & 0x1f == 4,
                          frame.flags & 0x80 != 0, frame.sequence == nativeActionSequence, !frame.payload.isEmpty {
                    let p = Array(frame.payload.prefix(2)); nativeActionReply = UInt16(p[0]) | (p.count > 1 ? UInt16(p[1]) << 8 : 0)
                } else if telemetryIsNew, let battery = Pocket3TelemetryParser.battery(from: frame, source: .wifi, receivedAt: Date()) {
                    lock.withLock { snapshot.battery = battery }
                }
            }
        }
        if accepted { try sendAck(binding, permit: permit) }
        return handshake
    }
    private func drain(for duration: TimeInterval, binding: ContinuousGimbalBinding, permit: OperationPermit, stopAtHandshake: Bool = false) throws -> Bool {
        let deadline = io.now + duration
        var handshake = false
        while io.now < deadline {
            try checkpoint(binding, permit: permit)
            handshake = try receive(binding, timeoutMS: 20, permit: permit) || handshake
            if stopAtHandshake && handshake { break }
        }
        return handshake
    }
    private func startMaintenance(_ binding: ContinuousGimbalBinding) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            do { _ = try self.receive(binding, timeoutMS: 0); try self.maintenance(binding) }
            catch { self.disarm(binding: binding, reason: self.code(error)); self.timer?.cancel(); self.timer = nil }
        }
        timer = source; source.resume()
    }
    private func maintenance(_ binding: ContinuousGimbalBinding) throws {
        guard lock.withLock({ snapshot.binding == binding }), ownerReady else { return }
        if ownerStopVerifier == nil && (!feedbackIsFresh() || Int(window?.transmitLagSlots ?? 0) > 64) { disarm(binding: binding, reason: "native_feedback_stale") }
        if io.now >= nextAck { try sendAck(binding, permit: OperationPermit()) }
        if io.now >= nextHeartbeat { try sendHeartbeat(binding, permit: OperationPermit()); nextHeartbeat = io.now + 1 }
        if io.now >= nextPresence {
            _ = try sendControl(set: 0, command: 0x88, payload: Pocket3DatalinkProtocol.appPresence, destination: 0x28, binding: binding, permit: OperationPermit())
            nextPresence = io.now + 1
        }
    }
    private func disarm(binding: ContinuousGimbalBinding, reason: String) {
        let permit = lock.withLock { () -> OperationPermit? in
            guard snapshot.binding == binding, snapshot.phase != .disarmed else { return nil }
            snapshot.phase = .disarmed; snapshot.lastErrorCode = reason; motionEpoch &+= 1
            let value = velocityPermit; velocityPermit = nil; return value
        }
        permit?.invalidate()
        if let lease = activeLease {
            _ = try? safetyNeutral(binding, permit: OperationPermit()); retire(lease)
        }
    }
    private func resetOwner() {
        let detachedSink = lock.withLock { () -> (Pocket3DatalinkLiveViewSinkToken,
                                                   any Pocket3DatalinkLiveViewSink)? in
            let value = liveViewSink
            liveViewSink = nil
            return value
        }
        if let detachedSink {
            detachedSink.1.flush(generation: detachedSink.0.generation)
        }
        timer?.cancel(); timer = nil; io.close(); window = nil; ownerReady = false
        dumlSequence = 0xa000; commandCounter = 0; activeLease = nil; retiredLeases = []
        pendingHeartbeats = [:]; nativeActionSequence = nil; nativeActionReply = nil; nextAck = 0
        pendingNativeCommand = nil; nativeCommandReply = nil
        nativeCommandObservedPayload = nil; nativeCommandObservedUptime = nil
        nativeCommandObservationTooLarge = false
        lock.withLock { nativeCommandTransactionID = nil }
        telemetrySequenceAdmission = NativeTelemetrySequenceAdmission()
    }
    private func closeOwner(binding: ContinuousGimbalBinding?, phase: Pocket3DatalinkPhase, errorCode: String?) {
        guard lock.withLock({ snapshot.binding == binding }) else { return }
        resetOwner()
        lock.withLock {
            guard snapshot.binding == binding else { return }
            snapshot.phase = phase; snapshot.binding = nil; snapshot.lastErrorCode = errorCode
            snapshot.telemetry = nil; snapshot.battery = nil; heartbeatTime = nil; telemetryTime = nil
            connectionPermit = nil; velocityPermit = nil
        }
    }
    private func code(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? NativeCommandTransactionError {
            switch error {
            case .invalidPayload: return "native_command_invalid_payload"
            case .invalidTimeout: return "native_command_invalid_timeout"
            case .commandNotReady: return "native_command_not_ready"
            case .staleGeneration: return "native_command_generation_changed"
            case .datalinkUnavailable: return "native_datalink_unavailable"
            case .nativeBusy: return "native_busy"
            }
        }
        return (error as? BridgeFailure)?.code ?? "native_protocol_error"
    }
    deinit { timer?.cancel(); io.close() }
}
