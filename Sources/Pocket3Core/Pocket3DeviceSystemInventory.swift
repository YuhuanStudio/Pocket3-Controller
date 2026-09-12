import Foundation

/// Evidence labels for device inventory entries. They are deliberately
/// separate from current availability: an official feature statement does not
/// prove that this BLE/USB session can read or control it.
public enum Pocket3DeviceInventoryEvidence: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable {
    case officialOnly = "official_only"
    case publicReverseEngineering = "public_reverse_engineering"
    case localParser = "local_parser"
    case localObservation = "local_observation"
    case operatorReport = "operator_report"
    case unknown

    public var capabilityLevel: CapabilityEvidenceLevel {
        switch self {
        case .officialOnly: .officialSpecification
        case .publicReverseEngineering: .publicReverseEngineering
        case .localParser, .operatorReport, .unknown: .softwareFixture
        case .localObservation: .localReadOnly
        }
    }
}

public enum Pocket3FirmwareComponentID: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable, Identifiable {
    case device = "device"
    case camera = "camera"
    case gimbal = "gimbal"

    public var id: String { rawValue }
}

/// Firmware values stay optional because the current BLE/USB observations do
/// not expose a capture-confirmed firmware-version property.
public struct Pocket3FirmwareComponentInventory: Codable, Sendable,
    Equatable, Hashable, Identifiable {
    public let id: Pocket3FirmwareComponentID
    public let currentVersion: String?
    public let rawVersion: String?
    public let availability: CapabilityAvailability
    public let evidence: [Pocket3DeviceInventoryEvidence]
    public let sourceReferences: [String]
    public let transport: CameraCapabilityTransport

    public var evidenceLevel: CapabilityEvidenceLevel {
        evidence.map(\.capabilityLevel).max() ?? .softwareFixture
    }

    public init(id: Pocket3FirmwareComponentID, currentVersion: String? = nil,
                rawVersion: String? = nil,
                availability: CapabilityAvailability,
                evidence: [Pocket3DeviceInventoryEvidence],
                sourceReferences: [String] = [],
                transport: CameraCapabilityTransport = .multiple) {
        self.id = id
        self.currentVersion = currentVersion
        self.rawVersion = rawVersion
        self.availability = availability
        self.evidence = evidence
        self.sourceReferences = sourceReferences
        self.transport = transport
    }
}

public enum Pocket3DevicePreferenceID: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable, Identifiable {
    case screenOrientation = "screen_orientation"
    case autoPowerOff = "auto_power_off"
    case wearable
    case rotateAndCapture = "rotate_and_capture"
    case selfieFlip = "selfie_flip"

    public var id: String { rawValue }
}

/// A typed preference readback keeps the raw property bytes alongside a
/// recognized value. Unknown selector bytes therefore remain evidence and
/// never become a guessed preference state.
public enum Pocket3DevicePreferenceReadback: Codable, Sendable,
    Equatable, Hashable {
    case screenOrientation(CameraSensorAspectRatio)
    case boolean(Bool)
}

public struct Pocket3DevicePreferenceInventory: Codable, Sendable,
    Equatable, Hashable, Identifiable {
    public let id: Pocket3DevicePreferenceID
    public let readback: Pocket3DevicePreferenceReadback?
    public let raw: Data?
    public let availability: CapabilityAvailability
    public let evidence: [Pocket3DeviceInventoryEvidence]
    public let sourceReferences: [String]
    public let transport: CameraCapabilityTransport

    public var evidenceLevel: CapabilityEvidenceLevel {
        evidence.map(\.capabilityLevel).max() ?? .softwareFixture
    }

    public init(id: Pocket3DevicePreferenceID,
                readback: Pocket3DevicePreferenceReadback? = nil,
                raw: Data? = nil,
                availability: CapabilityAvailability,
                evidence: [Pocket3DeviceInventoryEvidence],
                sourceReferences: [String] = [],
                transport: CameraCapabilityTransport = .bluetooth) {
        self.id = id
        self.readback = readback
        self.raw = raw
        self.availability = availability
        self.evidence = evidence
        self.sourceReferences = sourceReferences
        self.transport = transport
    }
}

public enum Pocket3AccessoryID: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable, Identifiable {
    case djiMic2 = "dji_mic_2"
    case djiMicMini = "dji_mic_mini"
    case batteryHandle = "battery_handle"

    public var id: String { rawValue }
}

/// Accessory candidates are separate entries even when no independent
/// identity was observed. This prevents camera battery or generic BLE names
/// from being promoted to a Mic/Handle identity.
public struct Pocket3AccessoryInventory: Codable, Sendable,
    Equatable, Hashable, Identifiable {
    public let id: Pocket3AccessoryID
    public let identity: String?
    public let rawIdentity: Data?
    public let availability: CapabilityAvailability
    public let evidence: [Pocket3DeviceInventoryEvidence]
    public let sourceReferences: [String]
    public let transport: CameraCapabilityTransport

    public var evidenceLevel: CapabilityEvidenceLevel {
        evidence.map(\.capabilityLevel).max() ?? .softwareFixture
    }

    public init(id: Pocket3AccessoryID, identity: String? = nil,
                rawIdentity: Data? = nil,
                availability: CapabilityAvailability,
                evidence: [Pocket3DeviceInventoryEvidence],
                sourceReferences: [String] = [],
                transport: CameraCapabilityTransport = .unknown) {
        self.id = id
        self.identity = identity
        self.rawIdentity = rawIdentity
        self.availability = availability
        self.evidence = evidence
        self.sourceReferences = sourceReferences
        self.transport = transport
    }
}

/// Bounded SD facts from `02/DC` (or the equivalent extended `02/80` fields).
/// The store count is kept as received; `present` is only derived from that
/// exact count and is nil when no store-count field was observed.
public struct Pocket3SDStorageInventory: Codable, Sendable,
    Equatable, Hashable {
    public let present: Bool?
    public let storeCountRaw: UInt8?
    public let totalMiB: UInt32?
    public let freeMiB: UInt32?
    public let receivedUptime: TimeInterval?
    public let sessionID: UUID?
    public let peripheralID: UUID?
    public let availability: CapabilityAvailability
    public let evidence: [Pocket3DeviceInventoryEvidence]
    public let sourceReferences: [String]
    public let transport: CameraCapabilityTransport

    public var evidenceLevel: CapabilityEvidenceLevel {
        evidence.map(\.capabilityLevel).max() ?? .softwareFixture
    }

    public init(present: Bool? = nil, storeCountRaw: UInt8? = nil,
                totalMiB: UInt32? = nil, freeMiB: UInt32? = nil,
                receivedUptime: TimeInterval? = nil, sessionID: UUID? = nil,
                peripheralID: UUID? = nil,
                availability: CapabilityAvailability,
                evidence: [Pocket3DeviceInventoryEvidence],
                sourceReferences: [String] = [],
                transport: CameraCapabilityTransport = .bluetooth) {
        self.present = present
        self.storeCountRaw = storeCountRaw
        self.totalMiB = totalMiB
        self.freeMiB = freeMiB
        self.receivedUptime = receivedUptime
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.availability = availability
        self.evidence = evidence
        self.sourceReferences = sourceReferences
        self.transport = transport
    }
}

/// Read-only firmware/accessory/system preference inventory. Construction is
/// pure: it consumes already published BLE observations and never starts a
/// scan, queries a property, joins Wi-Fi or writes a device setting.
public struct Pocket3DeviceSystemInventory: Codable, Sendable, Equatable,
    Hashable {
    public static let version = 1
    public static let supportMatrixSource = "docs/POCKET3_SUPPORT_MATRIX.md"
    public static let readOnlySource = "research/2026-09-11/camera-read-only-inventory.md"
    public static let settingsSource = "research/2026-09-08/camera-settings/PROVENANCE.md"

    public let version: Int
    public let firmware: [Pocket3FirmwareComponentInventory]
    public let preferences: [Pocket3DevicePreferenceInventory]
    public let storage: Pocket3SDStorageInventory
    public let accessories: [Pocket3AccessoryInventory]

    public init(
        version: Int = Self.version,
        firmware: [Pocket3FirmwareComponentInventory] = Self.unknownFirmware,
        preferences: [Pocket3DevicePreferenceInventory] = Self.unknownPreferences,
        storage: Pocket3SDStorageInventory = Self.unknownStorage,
        accessories: [Pocket3AccessoryInventory] = Self.unknownAccessories
    ) {
        self.version = version
        self.firmware = firmware
        self.preferences = preferences
        self.storage = storage
        self.accessories = accessories
    }

    /// Projects exact, fresh observations from the current paired BLE status.
    /// Values from another session, peer or stale observation are discarded.
    public static func from(
        discovery: BluetoothDiscoveryStatus,
        nowUptime: TimeInterval
    ) -> Self {
        let binding = ContinuousGimbalBinding(
            sessionID: "ble:\(discovery.sessionID.uuidString)", generation: 0)
        let paired = discovery.pairing?.peerReportedPaired == true
        let selected = discovery.selectedPeripheralID
        let freshExposure = paired && selected != nil
        let orientation = discovery.cameraSettingsObservations.reversed()
            .first(where: {
                freshExposure && $0.property == .sensorAspectRatio &&
                    $0.binding == binding &&
                    $0.isFresh(now: nowUptime, maximumAge: 5)
            })
        let orientationEntry = preference(
            id: .screenOrientation, observation: orientation)

        let storageObservation = paired ? discovery.storageStatus : nil
        let storageInventory: Pocket3SDStorageInventory
        if let storageObservation, let selected,
           storageObservation.sessionID == discovery.sessionID,
           storageObservation.peripheralID == selected,
           storageObservation.isFresh(nowUptime: nowUptime, maximumAge: 5) {
            storageInventory = storage(observation: storageObservation)
        } else if let camera = discovery.cameraStatus, let selected,
                  camera.sessionID == discovery.sessionID,
                  camera.peripheralID == selected,
                  camera.isFresh(nowUptime: nowUptime, maximumAge: 5),
                  camera.storageTotalMiB != nil || camera.storageFreeMiB != nil {
            storageInventory = storage(cameraStatus: camera)
        } else {
            storageInventory = unknownStorage
        }

        var preferences = unknownPreferences
        if let index = preferences.firstIndex(where: {
            $0.id == .screenOrientation
        }) {
            preferences[index] = orientationEntry
        }
        return Self(firmware: unknownFirmware, preferences: preferences,
                    storage: storageInventory, accessories: unknownAccessories)
    }

    public static let unknownFirmware: [Pocket3FirmwareComponentInventory] =
        Pocket3FirmwareComponentID.allCases.map { id in
            .init(id: id,
                  availability: .unavailable(
                      reason: "No firmware component readback is exposed by current BLE/USB observations"),
                  evidence: [.operatorReport],
                  sourceReferences: [supportMatrixSource],
                  transport: .multiple)
        }

    public static let unknownPreferences: [Pocket3DevicePreferenceInventory] = [
        .init(id: .screenOrientation,
              availability: .unavailable(
                  reason: "No current screen orientation readback"),
              evidence: [.localParser],
              sourceReferences: [readOnlySource]),
        .init(id: .autoPowerOff,
              availability: .unavailable(
                  reason: "No Auto Power Off readback schema"),
              evidence: [.officialOnly],
              sourceReferences: [supportMatrixSource]),
        .init(id: .wearable,
              availability: .unavailable(
                  reason: "No Wearable readback schema"),
              evidence: [.officialOnly],
              sourceReferences: [supportMatrixSource]),
        .init(id: .rotateAndCapture,
              availability: .unavailable(
                  reason: "No Rotate & Capture readback schema"),
              evidence: [.officialOnly],
              sourceReferences: [supportMatrixSource]),
        .init(id: .selfieFlip,
              availability: .unavailable(
                  reason: "No current Selfie Flip readback"),
              evidence: [.publicReverseEngineering, .localParser],
              sourceReferences: [settingsSource])
    ]

    public static let unknownStorage = Pocket3SDStorageInventory(
        availability: .unavailable(reason: "No current SD storage readback"),
        evidence: [.localParser], sourceReferences: [readOnlySource])

    public static let unknownAccessories: [Pocket3AccessoryInventory] =
        Pocket3AccessoryID.allCases.map { id in
            .init(id: id,
                  availability: .unavailable(
                      reason: "No independent accessory identity readback is exposed by current BLE/USB observations"),
                  evidence: [.officialOnly],
                  sourceReferences: [supportMatrixSource],
                  transport: .unknown)
        }

    private static func preference(
        id: Pocket3DevicePreferenceID,
        observation: CameraSettingsObservation?
    ) -> Pocket3DevicePreferenceInventory {
        guard let observation,
              case .sensorAspectRatio(let value) = observation.readOnlyValue else {
            return unknownPreferences.first(where: { $0.id == id })!
        }
        let readback: Pocket3DevicePreferenceReadback?
        let reason: String?
        if let aspect = value.aspectRatio {
            readback = .screenOrientation(aspect)
            reason = nil
        } else {
            readback = nil
            reason = "Screen orientation raw selector is unknown"
        }
        return .init(id: id, readback: readback, raw: value.raw,
                     availability: .init(read: true, reason: reason),
                     evidence: [.localParser, .localObservation],
                     sourceReferences: [readOnlySource])
    }

    private static func storage(
        observation: Pocket3StorageObservation
    ) -> Pocket3SDStorageInventory {
        let inconsistent = observation.freeMiB > observation.totalMiB
        return .init(
            present: observation.storeCount > 0,
            storeCountRaw: observation.storeCount,
            totalMiB: observation.totalMiB,
            freeMiB: observation.freeMiB,
            receivedUptime: observation.receivedUptime,
            sessionID: observation.sessionID,
            peripheralID: observation.peripheralID,
            availability: .init(read: true,
                                 reason: inconsistent
                                     ? "SD storage capacity fields are inconsistent" : nil),
            evidence: [.localParser, .localObservation],
            sourceReferences: [readOnlySource])
    }

    private static func storage(
        cameraStatus: Pocket3CameraStatusObservation
    ) -> Pocket3SDStorageInventory {
        let total = cameraStatus.storageTotalMiB
        let free = cameraStatus.storageFreeMiB
        let inconsistent = total != nil && free != nil && free! > total!
        return .init(
            present: nil,
            storeCountRaw: nil,
            totalMiB: total,
            freeMiB: free,
            receivedUptime: cameraStatus.receivedUptime,
            sessionID: cameraStatus.sessionID,
            peripheralID: cameraStatus.peripheralID,
            availability: .init(read: total != nil || free != nil,
                                 reason: inconsistent
                                     ? "SD storage capacity fields are inconsistent" : nil),
            evidence: [.localParser, .localObservation],
            sourceReferences: [readOnlySource])
    }
}

public typealias Pocket3FirmwareInventory = Pocket3FirmwareComponentInventory
public typealias Pocket3SystemPreferenceInventory = Pocket3DevicePreferenceInventory
public typealias Pocket3AccessoryIdentityInventory = Pocket3AccessoryInventory
public typealias Pocket3DeviceInventory = Pocket3DeviceSystemInventory
