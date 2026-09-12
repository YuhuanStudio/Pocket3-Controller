import Foundation

public enum BluetoothDiscoveryPhase: String, Codable, Sendable {
    case idle, waitingForBluetooth, scanning, scanComplete, connecting
    case discoveringServices, discoveringCharacteristics, subscribing
    case gattConnectedUnauthenticated, disconnected, unauthorized, poweredOff, unsupported, failed
    case pairing, awaitingPairingApproval, retrievingCredentials, gattPaired
}

/// FFF0/name/RSSI are discovery hints. They do not verify Pocket 3 identity.
public struct BluetoothCandidate: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String?
    public let rssi: Int?
    public let connectable: Bool?
}

/// Bounded protocol diagnostics. Never contains a payload or credential value.
public struct BluetoothDUMLHeader: Codable, Sendable {
    public let direction: String
    public let characteristic: String
    public let source: UInt8
    public let destination: UInt8
    public let sequence: UInt16
    public let flags: UInt8
    public let commandSet: UInt8
    public let commandID: UInt8
}

public struct BluetoothDiscoveryStatus: Codable, Sendable {
    public let phase: BluetoothDiscoveryPhase
    public let sessionID: UUID
    public let candidates: [BluetoothCandidate]
    public let selectedPeripheralID: UUID?
    public let issueCode: String?
    public let identityVerification: String
    public let authentication: String
    public let fff4NotificationEnabled: Bool
    public let fff5NotificationEnabled: Bool
    public let fff4Properties: UInt?
    public let fff5Properties: UInt?
    public let receivedFrames: Int
    public let fragments: [String: DUMLFragmentStatistics]
    public var pairing: BluetoothPairingStatus? = nil
    public var battery: BluetoothBatteryObservation? = nil
    public var pose: BluetoothPoseObservation? = nil
    /// Same-paired-peer host receive age only, not cryptographic freshness or
    /// a USB association. Empty when unpaired, disconnected or older than 5 s.
    public var cameraSettingsObservations: [CameraSettingsObservation] = []
    /// Fresh unsolicited `02/80` camera state from this exact paired peer.
    public var cameraStatus: Pocket3CameraStatusObservation? = nil
    public var storageStatus: Pocket3StorageObservation? = nil
    /// Last passive cross-model tracking candidates; never a support claim.
    public var trackingCandidates: [Pocket3TrackingCandidateFrame] = []
    /// Fresh, typed A5/A89 state from the current paired session. This is
    /// intentionally separate from the older raw candidate evidence above so
    /// callers can migrate without treating A6 as a readback.
    public var activeTrackObservation: Pocket3ActiveTrackObservation? = nil
    /// Bounded fresh history for diagnostics/read-only consumers. The store
    /// owns admission and generation fencing; status only publishes its
    /// already-filtered snapshot.
    public var activeTrackHistory: [Pocket3ActiveTrackObservation] = []
    public var activeTrackObservations: [Pocket3ActiveTrackObservation] { activeTrackHistory }
    public var activeTrackHistoryCount: Int { activeTrackHistory.count }
    public var recentHeaders: [BluetoothDUMLHeader] = []
    public var registrationAcknowledgmentSubmitted = false
    public var nativeProbeActive = false
    public var authorization: String? = nil
}

extension BluetoothDiscoveryStatus {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        phase = try values.decode(BluetoothDiscoveryPhase.self, forKey: .phase)
        sessionID = try values.decode(UUID.self, forKey: .sessionID)
        candidates = try values.decode([BluetoothCandidate].self, forKey: .candidates)
        selectedPeripheralID = try values.decodeIfPresent(UUID.self, forKey: .selectedPeripheralID)
        issueCode = try values.decodeIfPresent(String.self, forKey: .issueCode)
        identityVerification = try values.decode(String.self, forKey: .identityVerification)
        authentication = try values.decode(String.self, forKey: .authentication)
        fff4NotificationEnabled = try values.decode(Bool.self, forKey: .fff4NotificationEnabled)
        fff5NotificationEnabled = try values.decode(Bool.self, forKey: .fff5NotificationEnabled)
        fff4Properties = try values.decodeIfPresent(UInt.self, forKey: .fff4Properties)
        fff5Properties = try values.decodeIfPresent(UInt.self, forKey: .fff5Properties)
        receivedFrames = try values.decode(Int.self, forKey: .receivedFrames)
        fragments = try values.decode([String: DUMLFragmentStatistics].self, forKey: .fragments)
        pairing = try values.decodeIfPresent(BluetoothPairingStatus.self, forKey: .pairing)
        battery = try values.decodeIfPresent(BluetoothBatteryObservation.self, forKey: .battery)
        pose = try values.decodeIfPresent(BluetoothPoseObservation.self, forKey: .pose)
        cameraSettingsObservations = try values.decodeIfPresent([CameraSettingsObservation].self, forKey: .cameraSettingsObservations) ?? []
        cameraStatus = try values.decodeIfPresent(Pocket3CameraStatusObservation.self, forKey: .cameraStatus)
        storageStatus = try values.decodeIfPresent(Pocket3StorageObservation.self, forKey: .storageStatus)
        trackingCandidates = try values.decodeIfPresent([Pocket3TrackingCandidateFrame].self, forKey: .trackingCandidates) ?? []
        activeTrackObservation = try values.decodeIfPresent(Pocket3ActiveTrackObservation.self, forKey: .activeTrackObservation)
        activeTrackHistory = try values.decodeIfPresent([Pocket3ActiveTrackObservation].self, forKey: .activeTrackHistory) ?? []
        recentHeaders = try values.decode([BluetoothDUMLHeader].self, forKey: .recentHeaders)
        registrationAcknowledgmentSubmitted = try values.decode(Bool.self, forKey: .registrationAcknowledgmentSubmitted)
        nativeProbeActive = try values.decode(Bool.self, forKey: .nativeProbeActive)
        authorization = try values.decodeIfPresent(String.self, forKey: .authorization)
    }
}

/// Pure transition fence, separate from CoreBluetooth creation and permissions.
struct BluetoothDiscoveryState: Sendable {
    static let maximumCandidates = 64
    private(set) var phase: BluetoothDiscoveryPhase = .idle
    private(set) var generation = UUID()
    private(set) var candidates: [BluetoothCandidate] = []
    private(set) var selected: UUID?
    private(set) var issueCode: String?

    mutating func beginScan() -> UUID {
        generation = UUID(); phase = .waitingForBluetooth; candidates = []; selected = nil; issueCode = nil
        return generation
    }
    @discardableResult
    mutating func transition(from expected: BluetoothDiscoveryPhase, to next: BluetoothDiscoveryPhase, session: UUID) -> Bool {
        guard session == generation, phase == expected else { return false }
        phase = next
        return true
    }
    @discardableResult
    mutating func discover(_ candidate: BluetoothCandidate, session: UUID) -> Bool {
        guard phase == .scanning, session == generation else { return false }
        if let index = candidates.firstIndex(where: { $0.id == candidate.id }) { candidates[index] = candidate }
        else {
            guard candidates.count < Self.maximumCandidates else { return false }
            candidates.append(candidate)
        }
        return true
    }
    mutating func select(_ id: UUID) -> UUID? {
        guard [.scanning, .scanComplete].contains(phase), candidates.contains(where: { $0.id == id && $0.connectable != false }) else { return nil }
        generation = UUID(); selected = id; phase = .connecting; issueCode = nil
        return generation
    }
    func accepts(peripheral: UUID, session: UUID) -> Bool {
        session == generation && selected == peripheral &&
            [.connecting, .discoveringServices, .discoveringCharacteristics, .subscribing, .gattConnectedUnauthenticated,
             .pairing, .awaitingPairingApproval, .retrievingCredentials, .gattPaired].contains(phase)
    }
    mutating func finish(_ phase: BluetoothDiscoveryPhase, issue: String? = nil) {
        generation = UUID(); self.phase = phase; selected = nil; issueCode = issue
    }
}
