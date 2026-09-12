import Foundation

/// The read-only state carried by the Pocket 3 ActiveTrack telemetry paths.
/// A5 reports the camera's polling state and A89 reports a subject rectangle.
/// Neither path authorizes an A6 write or establishes a coordinate-system
/// orientation.
public enum Pocket3ActiveTrackState: Codable, Sendable, Equatable, Hashable {
    case idle
    case locked(box: Pocket3TrackingBox?)
    case subjectBox(Pocket3TrackingBox)
    case unknown(commandID: UInt8, raw: Data)

    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    public var isLocked: Bool {
        if case .locked = self { return true }
        return false
    }

    public var isSubjectBox: Bool {
        if case .subjectBox = self { return true }
        return false
    }

    /// A rectangle is available only when the camera actually supplied one.
    /// A5 may report locked while it is still acquiring a rectangle.
    public var box: Pocket3TrackingBox? {
        switch self {
        case .locked(let box): return box
        case .subjectBox(let box): return box
        case .idle, .unknown: return nil
        }
    }

    public var commandID: UInt8? {
        if case .unknown(let commandID, _) = self { return commandID }
        return nil
    }

    public var unknownRaw: Data? {
        if case .unknown(_, let raw) = self { return raw }
        return nil
    }
}

/// A generation-bound, host-timestamped observation from ActiveTrack A5 or
/// A89. The complete bounded payload is retained even when its shape or enum
/// value is unknown, so a future decoder can revisit the evidence.
public struct Pocket3ActiveTrackObservation: Codable, Sendable, Equatable {
    public static let maximumAge: TimeInterval = 5
    public static let maximumPayloadBytes = 128

    public let sessionID: UUID
    public let peripheralID: UUID
    public let binding: ContinuousGimbalBinding
    public let receivedAt: Date
    public let receivedUptime: TimeInterval
    public let sequence: UInt16
    public let source: UInt8
    public let destination: UInt8
    public let flags: UInt8
    public let commandSet: UInt8
    public let commandID: UInt8
    public let payloadRaw: Data
    public let state: Pocket3ActiveTrackState
    /// A5 byte 1, when present. It remains available for future state values.
    public let statusRaw: UInt8?
    /// A89 byte 5, when the live-subject layout is valid.
    public let tagRaw: UInt8?
    /// A89 byte 6, when the live-subject layout is valid.
    public let reservedRaw: UInt8?

    public var payload: Data { payloadRaw }
    public var raw: Data { payloadRaw }
    public var generation: UInt64 { binding.generation }
    public var box: Pocket3TrackingBox? { state.box }

    /// Builds an observation only for camera-to-app A5/A89 readback. A6 is a
    /// command path and intentionally has no initializer here.
    public init?(frame: DUMLFrame, sessionID: UUID, peripheralID: UUID,
                binding: ContinuousGimbalBinding, receivedAt: Date,
                receivedUptime: TimeInterval) {
        guard Self.validBinding(binding),
              frame.source == 0x01, frame.destination == 0x02,
              frame.commandSet == 0x02,
              Self.validFlags(frame.flags, commandID: frame.commandID),
              [0x89, 0xA5].contains(frame.commandID),
              frame.payload.count <= Self.maximumPayloadBytes,
              receivedAt.timeIntervalSinceReferenceDate.isFinite,
              receivedUptime.isFinite, receivedUptime >= 0 else { return nil }

        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.binding = binding
        self.receivedAt = receivedAt
        self.receivedUptime = receivedUptime
        self.sequence = frame.sequence
        self.source = frame.source
        self.destination = frame.destination
        self.flags = frame.flags
        self.commandSet = frame.commandSet
        self.commandID = frame.commandID
        self.payloadRaw = Data(frame.payload)

        switch frame.commandID {
        case 0xA5:
            self.statusRaw = frame.payload.count > 1 ? frame.payload[1] : nil
            self.tagRaw = nil
            self.reservedRaw = nil
            guard let readback = Pocket3TrackingPollReadback.decode(frame.payload),
                  let pollState = readback.state else {
                self.state = .unknown(commandID: frame.commandID, raw: Data(frame.payload))
                return
            }
            switch pollState {
            case .idle:
                // Bytes after the four-byte idle prefix are retained but are
                // not interpreted as a rectangle.
                self.state = .idle
            case .locked:
                // A four-byte locked status is a captured acquisition state.
                // Extra bytes must contain a valid complete box if present;
                // silently turning malformed coordinates into `locked(nil)`
                // would lose evidence about a changed layout.
                if frame.payload.count > 4 && readback.box == nil {
                    self.state = .unknown(commandID: frame.commandID, raw: Data(frame.payload))
                } else {
                    self.state = .locked(box: readback.box)
                }
            }

        case 0x89:
            self.statusRaw = nil
            guard let subject = Pocket3TrackingLiveSubject.decode(frame.payload) else {
                self.tagRaw = frame.payload.count > 5 ? frame.payload[5] : nil
                self.reservedRaw = frame.payload.count > 6 ? frame.payload[6] : nil
                self.state = .unknown(commandID: frame.commandID, raw: Data(frame.payload))
                return
            }
            self.tagRaw = subject.tagRaw
            self.reservedRaw = subject.reservedRaw
            self.state = .subjectBox(subject.box)

        default:
            return nil
        }
    }

    public func isFresh(nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        nowUptime.isFinite && receivedUptime.isFinite && receivedUptime >= 0 &&
            maximumAge.isFinite && maximumAge >= 0 && nowUptime >= receivedUptime &&
            nowUptime - receivedUptime <= maximumAge &&
            receivedAt.timeIntervalSinceReferenceDate.isFinite
    }

    /// Exact identity and generation fence used by a read-only owner before
    /// publishing an observation. A missing peer can never satisfy the fence.
    public func isFresh(sessionID: UUID, peripheralID: UUID?,
                        binding: ContinuousGimbalBinding? = nil, paired: Bool,
                        nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        guard paired, let peripheralID,
              self.sessionID == sessionID, self.peripheralID == peripheralID else { return false }
        if let binding, self.binding != binding { return false }
        return isFresh(nowUptime: nowUptime, maximumAge: maximumAge)
    }

    public func matches(sessionID: UUID, peripheralID: UUID?,
                        binding: ContinuousGimbalBinding? = nil, paired: Bool,
                        nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        isFresh(sessionID: sessionID, peripheralID: peripheralID, binding: binding,
                paired: paired, nowUptime: nowUptime, maximumAge: maximumAge)
    }

    public static func bluetoothBinding(sessionID: UUID,
                                        generation: UInt64 = 0) -> ContinuousGimbalBinding {
        ContinuousGimbalBinding(sessionID: "ble:\(sessionID.uuidString)", generation: generation)
    }

    private static func validBinding(_ binding: ContinuousGimbalBinding) -> Bool {
        !binding.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validFlags(_ flags: UInt8, commandID: UInt8) -> Bool {
        switch commandID {
        case 0xA5: return flags == 0 || flags == 0x80 || flags == 0xC0
        case 0x89: return flags == 0
        default: return false
        }
    }
}

/// A bounded, read-only ActiveTrack history owned by one exact BLE/native
/// session generation. It accepts already CRC-validated packets and never
/// sends an A6 command.
public struct Pocket3ActiveTrackObservationStore: Sendable, Equatable {
    public static let maximumAge: TimeInterval = Pocket3ActiveTrackObservation.maximumAge
    public static let maximumObservations = 64
    public static let maximumFingerprintsPerCommand = 16

    public private(set) var sessionID: UUID?
    public private(set) var peripheralID: UUID?
    public private(set) var binding: ContinuousGimbalBinding?

    private var stored: [Pocket3ActiveTrackObservation] = []
    private var sequenceAdmissions: [UInt8: BluetoothCameraEventSequenceAdmission] = [:]
    private var fingerprints: [UInt8: [Data]] = [:]
    private var lastAcceptedUptime: TimeInterval?

    public init() {}

    public init(sessionID: UUID, peripheralID: UUID,
                binding: ContinuousGimbalBinding) {
        self.init()
        _ = bind(sessionID: sessionID, peripheralID: peripheralID, binding: binding)
    }

    @discardableResult
    public mutating func bind(sessionID: UUID, peripheralID: UUID,
                              binding: ContinuousGimbalBinding) -> Bool {
        guard !binding.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clear()
            return false
        }
        clear()
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.binding = binding
        return true
    }

    @discardableResult
    public mutating func bindBluetooth(sessionID: UUID, peripheralID: UUID,
                                       generation: UInt64 = 0) -> Bool {
        bind(sessionID: sessionID, peripheralID: peripheralID,
             binding: Pocket3ActiveTrackObservation.bluetoothBinding(
                sessionID: sessionID, generation: generation))
    }

    public mutating func clear() {
        sessionID = nil
        peripheralID = nil
        binding = nil
        stored.removeAll(keepingCapacity: true)
        sequenceAdmissions.removeAll(keepingCapacity: true)
        fingerprints.removeAll(keepingCapacity: true)
        lastAcceptedUptime = nil
    }

    /// Accepts a validated packet from the current paired identity. Omitting
    /// the binding uses the store's current binding, which still requires an
    /// exact session/peripheral match and therefore cannot cross generations.
    @discardableResult
    public mutating func receive(_ packet: ValidatedDUMLPacket,
                                 sessionID: UUID, peripheralID: UUID,
                                 paired: Bool, hostReceivedAt: Date,
                                 uptime: TimeInterval) -> Bool {
        guard let currentBinding = binding else { return false }
        return receive(packet, sessionID: sessionID, peripheralID: peripheralID,
                       binding: currentBinding, paired: paired,
                       hostReceivedAt: hostReceivedAt, uptime: uptime)
    }

    @discardableResult
    public mutating func receive(_ packet: ValidatedDUMLPacket,
                                 sessionID: UUID, peripheralID: UUID,
                                 binding: ContinuousGimbalBinding,
                                 paired: Bool, hostReceivedAt: Date,
                                 uptime: TimeInterval) -> Bool {
        guard let observation = Pocket3ActiveTrackObservation(
            frame: packet.frame, sessionID: sessionID, peripheralID: peripheralID,
            binding: binding, receivedAt: hostReceivedAt, receivedUptime: uptime) else {
            return false
        }
        return receive(observation, paired: paired)
    }

    @discardableResult
    public mutating func receive(_ packet: ValidatedDUMLPacket,
                                 sessionID: UUID, peripheralID: UUID,
                                 binding: ContinuousGimbalBinding,
                                 paired: Bool, receivedAt: Date,
                                 receivedUptime: TimeInterval) -> Bool {
        receive(packet, sessionID: sessionID, peripheralID: peripheralID,
                binding: binding, paired: paired, hostReceivedAt: receivedAt,
                uptime: receivedUptime)
    }

    /// Useful when a recorder has already performed packet admission. The
    /// same identity, generation, sequence and replay checks still apply.
    @discardableResult
    public mutating func receive(_ observation: Pocket3ActiveTrackObservation,
                                 paired: Bool = true) -> Bool {
        guard paired, sessionID == observation.sessionID,
              peripheralID == observation.peripheralID,
              binding == observation.binding,
              observation.receivedUptime.isFinite,
              observation.receivedUptime >= 0,
              lastAcceptedUptime == nil || observation.receivedUptime >= lastAcceptedUptime! else {
            return false
        }

        let commandID = observation.commandID
        var admission = sequenceAdmissions[commandID]
            ?? BluetoothCameraEventSequenceAdmission()
        guard admission.accept(observation.sequence) else { return false }
        sequenceAdmissions[commandID] = admission

        let payload = observation.payloadRaw
        guard fingerprints[commandID]?.contains(payload) != true else { return false }
        var history = fingerprints[commandID] ?? []
        history.append(payload)
        if history.count > Self.maximumFingerprintsPerCommand {
            history.removeFirst(history.count - Self.maximumFingerprintsPerCommand)
        }
        fingerprints[commandID] = history

        stored.append(observation)
        if stored.count > Self.maximumObservations {
            stored.removeFirst(stored.count - Self.maximumObservations)
        }
        lastAcceptedUptime = observation.receivedUptime
        return true
    }

    @discardableResult
    public mutating func receive(_ event: BluetoothCameraEvent,
                                 binding: ContinuousGimbalBinding,
                                 paired: Bool = true) -> Bool {
        guard let observation = event.activeTrackObservation(binding: binding) else { return false }
        return receive(observation, paired: paired)
    }

    @discardableResult
    public mutating func ingest(_ event: BluetoothCameraEvent,
                                binding: ContinuousGimbalBinding,
                                paired: Bool = true) -> Bool {
        receive(event, binding: binding, paired: paired)
    }

    /// The unfiltered history is intentionally read-only. Call `snapshot` or
    /// `latest` for a freshness and identity-fenced view.
    public var observations: [Pocket3ActiveTrackObservation] { stored }
    public var latestObservation: Pocket3ActiveTrackObservation? { stored.last }

    public func snapshot(sessionID: UUID, peripheralID: UUID?, paired: Bool,
                         nowUptime: TimeInterval,
                         maximumAge: TimeInterval = Self.maximumAge) -> [Pocket3ActiveTrackObservation] {
        guard let binding else { return [] }
        return snapshot(sessionID: sessionID, peripheralID: peripheralID,
                        binding: binding, paired: paired, nowUptime: nowUptime,
                        maximumAge: maximumAge)
    }

    public func snapshot(sessionID: UUID, peripheralID: UUID?,
                         binding: ContinuousGimbalBinding, paired: Bool,
                         nowUptime: TimeInterval,
                         maximumAge: TimeInterval = Self.maximumAge) -> [Pocket3ActiveTrackObservation] {
        guard sessionID == self.sessionID, peripheralID == self.peripheralID,
              binding == self.binding, paired else { return [] }
        return stored.filter {
            $0.isFresh(sessionID: sessionID, peripheralID: peripheralID,
                       binding: binding, paired: paired, nowUptime: nowUptime,
                       maximumAge: maximumAge)
        }
    }

    public func latest(sessionID: UUID, peripheralID: UUID?, paired: Bool,
                       nowUptime: TimeInterval,
                       maximumAge: TimeInterval = Self.maximumAge) -> Pocket3ActiveTrackObservation? {
        snapshot(sessionID: sessionID, peripheralID: peripheralID, paired: paired,
                 nowUptime: nowUptime, maximumAge: maximumAge).last
    }

    public func latest(sessionID: UUID, peripheralID: UUID?,
                       binding: ContinuousGimbalBinding, paired: Bool,
                       nowUptime: TimeInterval,
                       maximumAge: TimeInterval = Self.maximumAge) -> Pocket3ActiveTrackObservation? {
        snapshot(sessionID: sessionID, peripheralID: peripheralID, binding: binding,
                 paired: paired, nowUptime: nowUptime, maximumAge: maximumAge).last
    }
}

public typealias Pocket3ActiveTrackStore = Pocket3ActiveTrackObservationStore

// MARK: - Existing passive recorder/read-only evidence projections

private enum Pocket3ActiveTrackHex {
    static func decode(_ text: String, expectedLength: Int) -> Data? {
        let bytes = Array(text.utf8)
        guard bytes.count.isMultiple(of: 2), bytes.count / 2 == expectedLength,
              expectedLength <= Pocket3ActiveTrackObservation.maximumPayloadBytes else { return nil }
        var result = Data()
        result.reserveCapacity(expectedLength)
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            result.append((high << 4) | low)
            index += 2
        }
        return result
    }

    private static func nibble(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: return value - 48
        case 65...70: return value - 55
        case 97...102: return value - 87
        default: return nil
        }
    }
}

public extension BluetoothCameraEvent {
    /// Typed A5/A89 view of one already accepted recorder event. A6 events
    /// remain available in `events` but intentionally return nil here.
    var activeTrackObservation: Pocket3ActiveTrackObservation? {
        makeActiveTrackObservation(binding: Pocket3ActiveTrackObservation.bluetoothBinding(sessionID: sessionID))
    }

    func activeTrackObservation(binding: ContinuousGimbalBinding) -> Pocket3ActiveTrackObservation? {
        makeActiveTrackObservation(binding: binding)
    }

    private func makeActiveTrackObservation(binding: ContinuousGimbalBinding) -> Pocket3ActiveTrackObservation? {
        guard commandSet == 0x02, [0x89, 0xA5].contains(commandID),
              payloadLength >= 0,
              let payload = Pocket3ActiveTrackHex.decode(payloadHex, expectedLength: payloadLength) else {
            return nil
        }
        let frame = DUMLFrame(source: source, destination: destinationForActiveTrack,
            sequence: sequence, flags: flagsForActiveTrack,
            commandSet: commandSet, commandID: commandID, payload: payload)
        return Pocket3ActiveTrackObservation(frame: frame, sessionID: sessionID,
            peripheralID: peripheralID, binding: binding, receivedAt: receivedAt,
            receivedUptime: receivedUptime)
    }

    private var destinationForActiveTrack: UInt8 { 0x02 }
    private var flagsForActiveTrack: UInt8 { commandID == 0xA5 ? 0 : 0 }
}

public extension BluetoothCameraEventRecording {
    /// Accepted recorder events projected through the strict A5/A89 decoder.
    /// Unknown/malformed payloads remain typed `.unknown` when their route is
    /// valid; A6 remains absent because it is a write path.
    var activeTrackObservations: [Pocket3ActiveTrackObservation] {
        events.compactMap(\.activeTrackObservation)
    }

    var latestActiveTrackObservation: Pocket3ActiveTrackObservation? {
        activeTrackObservations.last
    }

    func activeTrackObservations(binding: ContinuousGimbalBinding) -> [Pocket3ActiveTrackObservation] {
        events.compactMap { $0.activeTrackObservation(binding: binding) }
    }

    func latestActiveTrackObservation(binding: ContinuousGimbalBinding) -> Pocket3ActiveTrackObservation? {
        activeTrackObservations(binding: binding).last
    }
}

public extension Pocket3TrackingCandidateFrame {
    /// Converts existing passive candidate evidence to the same typed
    /// observation without changing its admission or freshness metadata.
    var activeTrackObservation: Pocket3ActiveTrackObservation? {
        activeTrackObservation(binding: Pocket3ActiveTrackObservation.bluetoothBinding(sessionID: sessionID))
    }

    func activeTrackObservation(binding: ContinuousGimbalBinding) -> Pocket3ActiveTrackObservation? {
        guard commandID == 0x89 || commandID == 0xA5,
              payloadLength >= 0,
              let payload = Pocket3ActiveTrackHex.decode(payloadHex, expectedLength: payloadLength) else {
            return nil
        }
        let frame = DUMLFrame(source: 0x01, destination: 0x02, sequence: 0,
            flags: 0, commandSet: 0x02, commandID: commandID, payload: payload)
        return Pocket3ActiveTrackObservation(frame: frame, sessionID: sessionID,
            peripheralID: peripheralID, binding: binding, receivedAt: receivedAt,
            receivedUptime: receivedUptime)
    }
}

/// The credential-free data passed to a body-status/read-only consumer. It
/// combines current camera lifecycle, legal body-format readback and the
/// latest fresh ActiveTrack observation from the same BLE identity.
public struct Pocket3CameraBodyReadOnlyContext: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let peripheralID: UUID?
    public let paired: Bool
    public let cameraStatus: Pocket3CameraStatusObservation?
    public let bodyRecordingCapabilities: CameraVideoFormatCapabilities?
    public let activeTrackObservation: Pocket3ActiveTrackObservation?

    public init(sessionID: UUID, peripheralID: UUID?, paired: Bool,
                cameraStatus: Pocket3CameraStatusObservation? = nil,
                bodyRecordingCapabilities: CameraVideoFormatCapabilities? = nil,
                activeTrackObservation: Pocket3ActiveTrackObservation? = nil) {
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.paired = paired
        self.cameraStatus = cameraStatus
        self.bodyRecordingCapabilities = bodyRecordingCapabilities
        self.activeTrackObservation = activeTrackObservation
    }

    public var bodyRecordingStatus: Pocket3BodyRecordingStatus? {
        cameraStatus?.bodyRecordingStatus
    }

    public var bodyRecordingLifecycle: Pocket3BodyRecordingLifecycle? {
        cameraStatus?.bodyRecordingLifecycle
    }

    public var activeTrack: Pocket3ActiveTrackObservation? { activeTrackObservation }
    public var capabilities: CameraVideoFormatCapabilities? { bodyRecordingCapabilities }
}

public typealias Pocket3CameraBodyStatusContext = Pocket3CameraBodyReadOnlyContext

public extension BluetoothDiscoveryStatus {
    /// Builds the pure read-only context consumed by `camera_body_status`.
    /// The caller supplies the monotonic clock so tests and non-UI owners do
    /// not need to consult system time. Pairing may be overridden by a caller
    /// that owns a more precise transport state; the default is conservative.
    func cameraBodyReadOnlyContext(nowUptime: TimeInterval,
                                   paired: Bool? = nil,
                                   maximumAge: TimeInterval = Pocket3ActiveTrackObservation.maximumAge)
        -> Pocket3CameraBodyReadOnlyContext {
        let pairedNow = paired ?? Self.inferPaired(pairing)
        guard pairedNow, let peripheralID = selectedPeripheralID else {
            return Pocket3CameraBodyReadOnlyContext(sessionID: sessionID,
                peripheralID: selectedPeripheralID, paired: false)
        }

        let binding = Pocket3ActiveTrackObservation.bluetoothBinding(sessionID: sessionID)
        let currentStatus: Pocket3CameraStatusObservation?
        if let candidate = cameraStatus,
           candidate.sessionID == sessionID, candidate.peripheralID == peripheralID,
           candidate.isFresh(nowUptime: nowUptime, maximumAge: maximumAge) {
            currentStatus = candidate
        } else {
            currentStatus = nil
        }
        let currentCapabilities = cameraSettingsObservations.reversed().first {
            $0.property == .videoFormatCapabilities &&
            $0.binding == binding &&
            $0.isFresh(now: nowUptime, maximumAge: maximumAge)
        }?.bodyRecordingCapabilities
        let currentTrack: Pocket3ActiveTrackObservation?
        if let typed = activeTrackObservation,
           typed.isFresh(sessionID: sessionID, peripheralID: peripheralID,
                        binding: binding, paired: pairedNow, nowUptime: nowUptime,
                        maximumAge: maximumAge) {
            currentTrack = typed
        } else if let typed = activeTrackHistory.reversed().first(where: {
            $0.isFresh(sessionID: sessionID, peripheralID: peripheralID,
                      binding: binding, paired: pairedNow, nowUptime: nowUptime,
                      maximumAge: maximumAge)
        }) {
            currentTrack = typed
        } else {
            currentTrack = trackingCandidates.reversed().compactMap {
                $0.activeTrackObservation(binding: binding)
            }.first {
                $0.isFresh(sessionID: sessionID, peripheralID: peripheralID,
                          binding: binding, paired: pairedNow, nowUptime: nowUptime,
                          maximumAge: maximumAge)
            }
        }
        return Pocket3CameraBodyReadOnlyContext(sessionID: sessionID,
            peripheralID: peripheralID, paired: pairedNow,
            cameraStatus: currentStatus,
            bodyRecordingCapabilities: currentCapabilities,
            activeTrackObservation: currentTrack)
    }

    func activeTrackObservation(nowUptime: TimeInterval,
                                paired: Bool? = nil,
                                maximumAge: TimeInterval = Pocket3ActiveTrackObservation.maximumAge)
        -> Pocket3ActiveTrackObservation? {
        cameraBodyReadOnlyContext(nowUptime: nowUptime, paired: paired,
                                  maximumAge: maximumAge).activeTrackObservation
    }

    private static func inferPaired(_ status: BluetoothPairingStatus?) -> Bool {
        guard let status else { return false }
        return status.peerReportedPaired ||
            [.paired, .retrievingCredentials, .credentialsReady].contains(status.phase)
    }
}
