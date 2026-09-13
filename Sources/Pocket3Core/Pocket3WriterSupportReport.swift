import Foundation

/// The setting-writer evidence matrix shared by developer diagnostics and the
/// command line.  It deliberately describes product support separately from
/// protocol shape: a known frame and a readback parser are still only a
/// candidate until the same-session write is acknowledged and read back.
public enum Pocket3WriterCandidateID: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable, Identifiable {
    case whiteBalance = "white_balance"
    case focusMode = "focus_mode"
    case colorProfile = "color_profile"
    case exposure
    case bodyRecording = "body_recording"
    case audioDSP = "audio_dsp"

    public var id: String { rawValue }
}

public enum Pocket3WriterProtocolStatus: String, Codable, Sendable,
    Equatable, CaseIterable {
    /// The operation, envelope and value shape are independently described by
    /// the reviewed sources and mirrored by a local encoder.
    case exact
    /// The packet envelope is known, but one or more payload fields are still
    /// composite or variable-length and cannot be treated as fully decoded.
    case partial
    /// No safe Pocket 3 packet shape was found.
    case unavailable
}

/// Product admission is intentionally conservative.  `candidateOnly` means
/// that a dry-run can show the exact next experiment; it never makes a writer
/// available to the ordinary UI.
public enum Pocket3WriterAdmission: String, Codable, Sendable,
    Equatable, CaseIterable {
    case candidateOnly = "candidate_only"
    case blockedNoVerifiedWrite = "blocked_no_verified_write"
    case unsupportedNoProtocol = "unsupported_no_protocol"
    case locallyVerifiedWrite = "local_verified_write"
}

public enum Pocket3WriterValidationStep: String, Codable, Sendable,
    Equatable, CaseIterable {
    case selectExactPairedSession = "select_exact_paired_session"
    case captureFreshBaseline = "capture_fresh_baseline"
    case submitOneSet = "submit_one_set"
    case correlateMatchingACK = "correlate_matching_ack"
    case correlateMatchingReadback = "correlate_matching_readback"
    case confirmPhysicalResult = "confirm_physical_result"
    case restoreCapturedBaseline = "restore_captured_baseline"
    case stopOnMismatch = "stop_on_mismatch"
}

/// One exact command packet fact.  `payloadHex` is an example when a field is
/// variable; `payloadShape` remains the machine-readable statement of what is
/// actually known.  No sequence is stored because the single transaction
/// owner allocates it at send time.
public struct Pocket3WriterPacketEvidence: Codable, Sendable,
    Equatable {
    public let transport: CameraCapabilityTransport
    public let operation: String
    public let source: UInt8
    public let destination: UInt8
    public let flags: UInt8
    public let commandSet: UInt8
    public let commandID: UInt8
    public let payloadShape: String
    public let payloadHex: String?
    public let payloadLength: Int?
    public let payloadExact: Bool
    public let transportDetail: String
    /// Accepted/status evidence from the independent OpenPocketCine Pocket 3
    /// survey. This is tagged with its transport because upstream Wi-Fi
    /// success cannot authorize this app's BLE-only writer.
    public let upstreamAccepted: Bool
    public let upstreamTransport: CameraCapabilityTransport?
    public let upstreamTransportDetail: String?
    public let upstreamPayloadHex: [String]
    public let upstreamEvidence: String?
    public let sourceReferences: [String]

    public init(transport: CameraCapabilityTransport = .bluetoothDatalink,
                operation: String, source: UInt8 = 0x02,
                destination: UInt8 = 0x01, flags: UInt8 = 0x40,
                commandSet: UInt8, commandID: UInt8,
                payloadShape: String, payloadHex: String? = nil,
                payloadLength: Int? = nil, payloadExact: Bool = false,
                transportDetail: String = "local BLE FFF5 write-without-response; DUML source 02->01",
                upstreamAccepted: Bool = false,
                upstreamTransport: CameraCapabilityTransport? = nil,
                upstreamTransportDetail: String? = nil,
                upstreamPayloadHex: [String] = [],
                upstreamEvidence: String? = nil,
                sourceReferences: [String]) {
        self.transport = transport
        self.operation = operation
        self.source = source
        self.destination = destination
        self.flags = flags
        self.commandSet = commandSet
        self.commandID = commandID
        self.payloadShape = payloadShape
        self.payloadHex = payloadHex
        self.payloadLength = payloadLength
        self.payloadExact = payloadExact
        self.transportDetail = transportDetail
        self.upstreamAccepted = upstreamAccepted
        self.upstreamTransport = upstreamTransport
        self.upstreamTransportDetail = upstreamTransportDetail
        self.upstreamPayloadHex = upstreamPayloadHex
        self.upstreamEvidence = upstreamEvidence
        self.sourceReferences = sourceReferences
    }

    public var command: String {
        String(format: "%02X/%02X", commandSet, commandID)
    }
}

/// One readback route and the exact fields that can be claimed from it.
/// `rawPreserved` is true for every route in this matrix, including unknown
/// selectors and reserved bytes.
public struct Pocket3WriterReadbackEvidence: Codable, Sendable,
    Equatable {
    public let transport: CameraCapabilityTransport
    public let route: String
    public let source: UInt8
    public let destination: UInt8
    public let flags: UInt8?
    public let commandSet: UInt8
    public let commandID: UInt8
    public let property: String?
    public let minimumPayloadBytes: Int?
    public let typedFields: [String]
    public let rawPreserved: Bool
    public let observedLocally: Bool
    public let matchingWriteObserved: Bool
    public let transportDetail: String
    public let upstreamObserved: Bool
    public let upstreamTransport: CameraCapabilityTransport?
    public let upstreamTransportDetail: String?
    public let upstreamEvidence: String?
    public let sourceReferences: [String]

    public init(transport: CameraCapabilityTransport = .bluetoothDatalink,
                route: String, source: UInt8 = 0x28,
                destination: UInt8 = 0x02, flags: UInt8? = 0,
                commandSet: UInt8, commandID: UInt8,
                property: String? = nil, minimumPayloadBytes: Int? = nil,
                typedFields: [String], rawPreserved: Bool = true,
                observedLocally: Bool, matchingWriteObserved: Bool = false,
                transportDetail: String = "local BLE FFF4 notifications / FFF5 transaction; DUML response",
                upstreamObserved: Bool = false,
                upstreamTransport: CameraCapabilityTransport? = nil,
                upstreamTransportDetail: String? = nil,
                upstreamEvidence: String? = nil,
                sourceReferences: [String]) {
        self.transport = transport
        self.route = route
        self.source = source
        self.destination = destination
        self.flags = flags
        self.commandSet = commandSet
        self.commandID = commandID
        self.property = property
        self.minimumPayloadBytes = minimumPayloadBytes
        self.typedFields = typedFields
        self.rawPreserved = rawPreserved
        self.observedLocally = observedLocally
        self.matchingWriteObserved = matchingWriteObserved
        self.transportDetail = transportDetail
        self.upstreamObserved = upstreamObserved
        self.upstreamTransport = upstreamTransport
        self.upstreamTransportDetail = upstreamTransportDetail
        self.upstreamEvidence = upstreamEvidence
        self.sourceReferences = sourceReferences
    }

    public var command: String {
        String(format: "%02X/%02X", commandSet, commandID)
    }
}

public struct Pocket3WriterSupportEntry: Codable, Sendable,
    Equatable, Identifiable {
    public let id: Pocket3WriterCandidateID
    public let protocolStatus: Pocket3WriterProtocolStatus
    public let evidence: [CapabilityEvidenceLevel]
    public let packetEvidence: [Pocket3WriterPacketEvidence]
    public let readbackEvidence: [Pocket3WriterReadbackEvidence]
    public let availability: CapabilityAvailability
    public let admission: Pocket3WriterAdmission
    public let executionAllowed: Bool
    public let candidateOperation: String?
    public let writeAttempts: Int
    public let acknowledgedWrites: Int
    public let matchingReadbacksAfterWrite: Int
    public let reason: String
    public let nextValidation: [Pocket3WriterValidationStep]
    public let nextValidationNote: String

    public var evidenceLevel: CapabilityEvidenceLevel {
        evidence.max() ?? .softwareFixture
    }

    public var idValue: String { id.rawValue }

    public init(
        id: Pocket3WriterCandidateID,
        protocolStatus: Pocket3WriterProtocolStatus,
        evidence: [CapabilityEvidenceLevel],
        packetEvidence: [Pocket3WriterPacketEvidence],
        readbackEvidence: [Pocket3WriterReadbackEvidence],
        availability: CapabilityAvailability,
        admission: Pocket3WriterAdmission,
        executionAllowed: Bool = false,
        candidateOperation: String? = nil,
        writeAttempts: Int = 0,
        acknowledgedWrites: Int = 0,
        matchingReadbacksAfterWrite: Int = 0,
        reason: String,
        nextValidation: [Pocket3WriterValidationStep],
        nextValidationNote: String
    ) {
        self.id = id
        self.protocolStatus = protocolStatus
        self.evidence = evidence
        self.packetEvidence = packetEvidence
        self.readbackEvidence = readbackEvidence
        self.availability = availability
        self.admission = admission
        self.executionAllowed = executionAllowed
        self.candidateOperation = candidateOperation
        self.writeAttempts = writeAttempts
        self.acknowledgedWrites = acknowledgedWrites
        self.matchingReadbacksAfterWrite = matchingReadbacksAfterWrite
        self.reason = reason
        self.nextValidation = nextValidation
        self.nextValidationNote = nextValidationNote
    }
}

/// Immutable, deterministic report for the current product source tree. It
/// is suitable for JSON, CLI and future status projection without opening a
/// BLE session. The report itself always has `hardwareAccessed == false`.
public struct Pocket3WriterSupportReport: Codable, Sendable, Equatable {
    public static let operation = "validation-wireless-writer-support-report"
    public static let currentVersion = 1

    public let version: Int
    public let operation: String
    public let entries: [Pocket3WriterSupportEntry]
    public let hardwareAccessed: Bool
    public let executeAllowed: Bool
    public let localTransport: CameraCapabilityTransport
    public let localTransportDetail: String
    public let sources: [String]
    public let notes: [String]

    public init() {
        self.init(entries: Self.makeEntries())
    }

    public init(entries: [Pocket3WriterSupportEntry]) {
        version = Self.currentVersion
        operation = Self.operation
        self.entries = entries
        hardwareAccessed = false
        executeAllowed = false
        localTransport = .bluetoothDatalink
        localTransportDetail = Self.localBLETransportDetail
        sources = [
            Self.kazeSettingsSource,
            Self.kazeReadbackSource,
            Self.openPocketCineSurveySource,
            Self.openPocketCineCommandSource,
            Self.localWriterAuditSource,
            Self.localProtocolSource,
            Self.localHardwareEvidenceSource
        ]
        notes = [
            "Protocol evidence and product write support are separate facts",
            "A command ACK without matching same-session readback is not a verified write",
            "OpenPocketCine accepted/status evidence is Wi-Fi datalink evidence and does not authorize this BLE writer",
            "bluetoothDatalink entries are local CoreBluetooth FFF4/FFF5 paths; they are not UDP",
            "This report is dry-run metadata and never creates BLE, Wi-Fi or datalink I/O"
        ]
    }

    public static let current = Pocket3WriterSupportReport()

    public func entry(for id: Pocket3WriterCandidateID)
        -> Pocket3WriterSupportEntry? {
        entries.first { $0.id == id }
    }

    public var candidateCount: Int {
        entries.filter { $0.admission == .candidateOnly }.count
    }

    public var blockedCount: Int {
        entries.filter { $0.admission == .blockedNoVerifiedWrite }.count
    }

    public var unsupportedCount: Int {
        entries.filter { $0.admission == .unsupportedNoProtocol }.count
    }

    public var verifiedCount: Int {
        entries.filter { $0.admission == .locallyVerifiedWrite }.count
    }

    public static let kazeSettingsSource =
        "Kaze@341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3Controller/Pocket3CameraSettings.swift"
    public static let kazeReadbackSource =
        "Kaze@341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3Controller/Pocket3CameraReadback.swift"
    public static let openPocketCineSurveySource =
        "OpenPocketCine@9b30b93572797c94db5ad9236fb746410f8d761f/handbook/src/content/docs/protocol/pocket3.md"
    public static let openPocketCineCommandSource =
        "OpenPocketCine@9b30b93572797c94db5ad9236fb746410f8d761f/handbook/src/content/docs/protocol/commands.md"
    public static let localWriterAuditSource =
        "research/2026-09-09/ble-camera-write-route.md"
    public static let localProtocolSource =
        "Sources/Pocket3Core/Pocket3NativeSettingCoordinator.swift"
    public static let localHardwareEvidenceSource =
        "docs/HARDWARE_ACCEPTANCE.md"
    public static let localBLETransportDetail =
        "CoreBluetooth FFF4 notifications + FFF5 write-without-response; local DUML source 02->01"
    public static let upstreamWiFiTransportDetail =
        "OpenPocketCine Pocket 3 survey via camera Wi-Fi UDP datalink"

    private static let commonSteps: [Pocket3WriterValidationStep] = [
        .selectExactPairedSession,
        .captureFreshBaseline,
        .submitOneSet,
        .correlateMatchingACK,
        .correlateMatchingReadback,
        .confirmPhysicalResult,
        .restoreCapturedBaseline,
        .stopOnMismatch
    ]

    private static func makeEntries() -> [Pocket3WriterSupportEntry] {
        [whiteBalanceEntry(), focusEntry(), colorEntry(), exposureEntry(),
         bodyEntry(), audioEntry()]
    }

    private static func whiteBalanceEntry() -> Pocket3WriterSupportEntry {
        let packets = [
            packet(operation: "set", commandSet: 0x02, commandID: 0x2C,
                   payloadShape: "automatic [00 00 00 00 00]; custom [06 kelvin/100 00 00 00]",
                   payloadHex: "06 38 00 00 00", payloadLength: 5,
                   payloadExact: true,
                   references: [kazeSettingsSource, localProtocolSource])
        ]
        let readbacks = [namedProperty(
            route: "00/99/06 named-property push",
            property: "cam_image_effect", minimumBytes: 6,
            fields: ["color[2]", "whiteBalanceMode[4]", "kelvin/100[5]"],
            observed: true,
            references: [kazeReadbackSource, localHardwareEvidenceSource])]
        return entry(id: .whiteBalance, protocolStatus: .exact,
                     evidence: [.publicReverseEngineering, .softwareFixture,
                                .localReadOnly], packets: packets,
                     readbacks: readbacks, availability: .init(read: true,
                         write: false, verified: false,
                         reason: "Two 5600 K attempts had no ACK or matching readback"),
                     admission: .blockedNoVerifiedWrite,
                     candidateOperation: "validation-wireless-native-setting",
                     writeAttempts: 2, reason:
                         "02/2C and cam_image_effect are typed, but local BLE writer evidence is not successful (no ACK or matching readback)",
                     nextNote: "One Auto↔custom-Kelvin round trip on the exact paired session; restore only after matching readback")
    }

    private static func focusEntry() -> Pocket3WriterSupportEntry {
        let packets = [
            packet(operation: "set", commandSet: 0x02, commandID: 0x24,
                   payloadShape: "one byte focus mode: 01 S-AF or 02 C-AF",
                   payloadHex: "01", payloadLength: 1, payloadExact: true,
                   references: [kazeSettingsSource, localProtocolSource])
        ]
        let readbacks = [namedProperty(
            route: "00/99/06 named-property push", property: "cam_lens_state",
            minimumBytes: 1, fields: ["focusMode[0]: B1/B2"], observed: true,
            references: [kazeReadbackSource, localHardwareEvidenceSource])]
        return entry(id: .focusMode, protocolStatus: .exact,
                     evidence: [.publicReverseEngineering, .softwareFixture,
                                .localReadOnly], packets: packets,
                     readbacks: readbacks, availability: .init(read: true,
                         write: false, verified: false,
                         reason: "Raw B1/B2 readback exists; no BLE mode SET ACK/readback proof"),
                     admission: .candidateOnly,
                     candidateOperation: "validation-wireless-setting-candidate",
                     reason: "Phase29 dry-run candidate only; the exact 02/24 shape is not local write evidence",
                     nextNote: "Switch once, correlate 02/24 ACK and post-submit cam_lens_state, then restore the captured mode")
    }

    private static func colorEntry() -> Pocket3WriterSupportEntry {
        let packets = [
            packet(operation: "set", commandSet: 0x02, commandID: 0x42,
                   payloadShape: "one byte color profile: 00 Normal, 3C HLG, 3D D-Log M",
                   payloadHex: "00", payloadLength: 1, payloadExact: true,
                   references: [kazeSettingsSource, localProtocolSource])
        ]
        let readbacks = [namedProperty(
            route: "00/99/06 named-property push", property: "cam_image_effect",
            minimumBytes: 6, fields: ["colorProfile[2]"], observed: true,
            references: [kazeReadbackSource, localHardwareEvidenceSource])]
        return entry(id: .colorProfile, protocolStatus: .exact,
                     evidence: [.publicReverseEngineering, .softwareFixture,
                                .localReadOnly], packets: packets,
                     readbacks: readbacks, availability: .init(read: true,
                         write: false, verified: false,
                         reason: "Typed color readback exists; no local color SET ACK/readback proof"),
                     admission: .candidateOnly,
                     candidateOperation: "validation-wireless-native-setting",
                     reason: "02/42 is a reviewed candidate command, not a product-supported writer",
                     nextNote: "Use one profile transition with matching image-effect readback and explicit restore")
    }

    private static func exposureEntry() -> Pocket3WriterSupportEntry {
        let packets = [
            packet(operation: "set", commandSet: 0x02, commandID: 0x1E,
                   payloadShape: "mode [01|04 00] for Auto|Manual",
                   payloadHex: "01 00", payloadLength: 2, payloadExact: true,
                   references: [kazeSettingsSource, localProtocolSource]),
            packet(operation: "set", commandSet: 0x02, commandID: 0x2E,
                   payloadShape: "one EV byte 07...19 (0x10 + third-stops)",
                   payloadHex: "10", payloadLength: 1, payloadExact: true,
                   references: [kazeSettingsSource, localProtocolSource]),
            packet(operation: "set", commandSet: 0x02, commandID: 0x2A,
                   payloadShape: "local typed domain 00 or 02...09; upstream Pocket 3 Low-Light also accepted sparse 10=9600 and 11=16000",
                   payloadHex: "00", payloadLength: 1, payloadExact: true,
                   references: [kazeSettingsSource, localProtocolSource],
                   upstreamPayloadHex: ["10", "11"]),
            packet(operation: "set", commandSet: 0x02, commandID: 0x28,
                   payloadShape: "seven-byte shutter payload; reviewed fractional bytes retained",
                   payloadHex: "01 01 00 00 00 00 40", payloadLength: 7,
                   payloadExact: true,
                   references: [kazeSettingsSource, localProtocolSource]),
            packet(operation: "set", commandSet: 0x02, commandID: 0x8E,
                   payloadShape: "keyed SET [01 01 pidLE 01 selector], PID 000F ISO limit",
                   payloadHex: "01 01 0F 00 01 01", payloadLength: 6,
                   payloadExact: true,
                   references: [kazeSettingsSource, localProtocolSource,
                                openPocketCineCommandSource],
                   upstreamAccepted: false)
        ]
        let readbacks = [
            namedProperty(route: "00/99/06 named-property push",
                          property: "cam_expo_param", minimumBytes: 20,
                          fields: ["EV[6]", "exposureMode[7]",
                                   "effectiveISO:u32LE[16...19]"], observed: true,
                          references: [kazeReadbackSource, localHardwareEvidenceSource]),
            keyedProperty(route: "02/8E keyed response",
                          property: "iso_limit", minimumBytes: 7,
                          fields: ["status[0...2]", "PID[3...4]",
                                   "declaredLength[5]", "value[6...]"], observed: false,
                          references: [localProtocolSource])
        ]
        return entry(id: .exposure, protocolStatus: .exact,
                     evidence: [.publicReverseEngineering, .softwareFixture,
                                .localReadOnly], packets: packets,
                     readbacks: readbacks, availability: .init(read: true,
                         write: false, verified: false,
                         reason: "Auto/EV/effective ISO are read back; no exposure writer has matching write evidence"),
                     admission: .candidateOnly,
                     candidateOperation: "validation-wireless-native-exposure",
                     reason: "Mode, EV, ISO, shutter and ISO-limit packet shapes are typed, but no local write is verified",
                     nextNote: "Start with Auto or one EV step, then test Manual as an atomic mode→ISO→shutter sequence")
    }

    private static func bodyEntry() -> Pocket3WriterSupportEntry {
        let packets = [
            packet(operation: "set", commandSet: 0x02, commandID: 0x18,
                   payloadShape: "[resolution fps 00 slowMotion 00]",
                   payloadHex: "10 03 00 00 00", payloadLength: 5,
                   payloadExact: true,
                   references: [kazeSettingsSource, localProtocolSource]),
            packet(operation: "set", commandSet: 0x02, commandID: 0x02,
                   payloadShape: "record lifecycle [01 start] or [00 stop]",
                   payloadHex: "01", payloadLength: 1, payloadExact: true,
                   references: [kazeSettingsSource, localProtocolSource])
        ]
        let readbacks = [
            namedProperty(route: "00/99/06 named-property push",
                          property: "cam_video_param_v2", minimumBytes: 9,
                          fields: ["resolution[0]", "fps[1]", "compression[8]"],
                          observed: true,
                          references: [kazeReadbackSource, localHardwareEvidenceSource]),
            bodyStatus(route: "02/80 camera status",
                       property: "recording_lifecycle", minimumBytes: 58,
                       fields: ["status[0]: idle/transition/recording"],
                       observed: true,
                       references: [localProtocolSource, localHardwareEvidenceSource]),
            namedProperty(route: "camcap_video_format capability table",
                          property: "camcap_video_format", minimumBytes: 5,
                          fields: ["entries: resolution/fps/flags"], observed: true,
                          references: [localProtocolSource, localHardwareEvidenceSource])
        ]
        return entry(id: .bodyRecording, protocolStatus: .exact,
                     evidence: [.publicReverseEngineering, .softwareFixture,
                                .localReadOnly], packets: packets,
                     readbacks: readbacks, availability: .init(read: true,
                         write: false, verified: false,
                         reason: "Legal format and current body state are readable; no 02/18 or lifecycle write is verified"),
                     admission: .candidateOnly,
                     candidateOperation: "validation-wireless-body",
                     reason: "Body format/start/stop are bounded candidates; ACK alone cannot establish camera state or media output",
                     nextNote: "Choose one fresh legal pair, perform one format or lifecycle transition, confirm matching state and restore")
    }

    private static func audioEntry() -> Pocket3WriterSupportEntry {
        let packets = [
            packet(operation: "get", commandSet: 0x02, commandID: 0xA0,
                   payloadShape: "empty GET payload; response is status 00 + variable blob",
                   payloadHex: nil, payloadLength: 0, payloadExact: true,
                   references: [kazeSettingsSource, localProtocolSource]),
            packet(operation: "set", commandSet: 0x02, commandID: 0x9F,
                   payloadShape: "complete A0 blob with only confirmed byte 2 patched",
                   payloadHex: nil, payloadLength: nil, payloadExact: false,
                   references: [kazeSettingsSource, localProtocolSource,
                                localWriterAuditSource])
        ]
        let readbacks = [response(
            route: "02/A0 response",
            source: 0x01, destination: 0x02, flags: 0x80,
            commandSet: 0x02, commandID: 0xA0,
            property: "audio_dsp_blob", minimumBytes: 2,
            fields: ["status[0]", "variable blob[1...]", "byte2 wind/directional candidate"],
            observed: false,
            references: [kazeSettingsSource, localProtocolSource],
            upstreamObserved: true)]
        return entry(id: .audioDSP, protocolStatus: .partial,
                     evidence: [.publicReverseEngineering, .softwareFixture],
                     packets: packets, readbacks: readbacks,
                     availability: .init(read: false, write: false,
                         verified: false,
                         reason: "No local A0 baseline/readback has been captured for this product session"),
                     admission: .blockedNoVerifiedWrite,
                     candidateOperation: "validation-wireless-audio-dsp",
                     reason: "The variable envelope and byte-2 patch are typed, but composite field semantics and local write proof remain incomplete",
                     nextNote: "Capture one same-session A0 blob, change one confirmed selector, correlate 9F ACK and matching A0, then restore")
    }

    private static func entry(
        id: Pocket3WriterCandidateID,
        protocolStatus: Pocket3WriterProtocolStatus,
        evidence: [CapabilityEvidenceLevel],
        packets: [Pocket3WriterPacketEvidence],
        readbacks: [Pocket3WriterReadbackEvidence],
        availability: CapabilityAvailability,
        admission: Pocket3WriterAdmission,
        executionAllowed: Bool = false,
        candidateOperation: String?,
        writeAttempts: Int = 0,
        acknowledgedWrites: Int = 0,
        matchingReadbacksAfterWrite: Int = 0,
        reason: String,
        nextNote: String
    ) -> Pocket3WriterSupportEntry {
        Pocket3WriterSupportEntry(
            id: id, protocolStatus: protocolStatus, evidence: evidence,
            packetEvidence: packets, readbackEvidence: readbacks,
            availability: availability, admission: admission,
            executionAllowed: executionAllowed,
            candidateOperation: candidateOperation,
            writeAttempts: writeAttempts,
            acknowledgedWrites: acknowledgedWrites,
            matchingReadbacksAfterWrite: matchingReadbacksAfterWrite,
            reason: reason, nextValidation: commonSteps,
            nextValidationNote: nextNote)
    }

    private static func packet(
        operation: String, commandSet: UInt8, commandID: UInt8,
        payloadShape: String, payloadHex: String?, payloadLength: Int?,
        payloadExact: Bool, references: [String],
        upstreamAccepted: Bool = true,
        upstreamTransport: CameraCapabilityTransport? = .wiFiDatalink,
        upstreamTransportDetail: String? = Self.upstreamWiFiTransportDetail,
        upstreamPayloadHex: [String] = [],
        upstreamEvidence: String? = Self.openPocketCineSurveySource
    ) -> Pocket3WriterPacketEvidence {
        .init(operation: operation, commandSet: commandSet,
              commandID: commandID, payloadShape: payloadShape,
              payloadHex: payloadHex, payloadLength: payloadLength,
              payloadExact: payloadExact,
              transportDetail: Self.localBLETransportDetail,
              upstreamAccepted: upstreamAccepted,
              upstreamTransport: upstreamAccepted ? upstreamTransport : nil,
              upstreamTransportDetail: upstreamAccepted ? upstreamTransportDetail : nil,
              upstreamPayloadHex: upstreamAccepted ? upstreamPayloadHex : [],
              upstreamEvidence: upstreamAccepted ? upstreamEvidence : nil,
              sourceReferences: upstreamAccepted
                  ? references + [Self.openPocketCineSurveySource]
                  : references)
    }

    private static func namedProperty(
        route: String, property: String, minimumBytes: Int?,
        fields: [String], observed: Bool,
        references: [String], upstreamObserved: Bool = true,
        upstreamTransport: CameraCapabilityTransport? = .wiFiDatalink,
        upstreamTransportDetail: String? = Self.upstreamWiFiTransportDetail,
        upstreamEvidence: String? = Self.openPocketCineSurveySource
    ) -> Pocket3WriterReadbackEvidence {
        response(route: route, source: 0x28, destination: 0x02, flags: 0,
                 commandSet: 0x00, commandID: 0x99, property: property,
                 minimumBytes: minimumBytes, fields: fields, observed: observed,
                 references: references, upstreamObserved: upstreamObserved,
                 upstreamTransport: upstreamTransport,
                 upstreamTransportDetail: upstreamTransportDetail,
                 upstreamEvidence: upstreamEvidence)
    }

    private static func keyedProperty(
        route: String, property: String, minimumBytes: Int?,
        fields: [String], observed: Bool,
        references: [String], upstreamObserved: Bool = false,
        upstreamTransport: CameraCapabilityTransport? = .wiFiDatalink,
        upstreamTransportDetail: String? = Self.upstreamWiFiTransportDetail,
        upstreamEvidence: String? = Self.openPocketCineSurveySource
    ) -> Pocket3WriterReadbackEvidence {
        response(route: route, source: 0x01, destination: 0x02,
                 flags: 0x80, commandSet: 0x02, commandID: 0x8E,
                 property: property, minimumBytes: minimumBytes,
                 fields: fields, observed: observed, references: references,
                 upstreamObserved: upstreamObserved,
                 upstreamTransport: upstreamTransport,
                 upstreamTransportDetail: upstreamTransportDetail,
                 upstreamEvidence: upstreamEvidence)
    }

    private static func bodyStatus(
        route: String, property: String, minimumBytes: Int?,
        fields: [String], observed: Bool,
        references: [String], upstreamObserved: Bool = true,
        upstreamTransport: CameraCapabilityTransport? = .wiFiDatalink,
        upstreamTransportDetail: String? = Self.upstreamWiFiTransportDetail,
        upstreamEvidence: String? = Self.openPocketCineSurveySource
    ) -> Pocket3WriterReadbackEvidence {
        response(route: route, source: 0x01, destination: 0x02,
                 flags: 0, commandSet: 0x02, commandID: 0x80,
                 property: property, minimumBytes: minimumBytes,
                 fields: fields, observed: observed, references: references,
                 upstreamObserved: upstreamObserved,
                 upstreamTransport: upstreamTransport,
                 upstreamTransportDetail: upstreamTransportDetail,
                 upstreamEvidence: upstreamEvidence)
    }

    private static func response(
        route: String, source: UInt8, destination: UInt8, flags: UInt8?,
        commandSet: UInt8, commandID: UInt8, property: String?,
        minimumBytes: Int?, fields: [String], observed: Bool,
        references: [String], upstreamObserved: Bool = false,
        upstreamTransport: CameraCapabilityTransport? = .wiFiDatalink,
        upstreamTransportDetail: String? = Self.upstreamWiFiTransportDetail,
        upstreamEvidence: String? = Self.openPocketCineSurveySource
    ) -> Pocket3WriterReadbackEvidence {
        .init(route: route, source: source, destination: destination,
              flags: flags, commandSet: commandSet, commandID: commandID,
              property: property, minimumPayloadBytes: minimumBytes,
              typedFields: fields, observedLocally: observed,
              transportDetail: Self.localBLETransportDetail,
              upstreamObserved: upstreamObserved,
              upstreamTransport: upstreamObserved ? upstreamTransport : nil,
              upstreamTransportDetail: upstreamObserved ? upstreamTransportDetail : nil,
              upstreamEvidence: upstreamObserved ? upstreamEvidence : nil,
              sourceReferences: upstreamObserved
                  ? references + [Self.openPocketCineSurveySource]
                  : references)
    }
}

public typealias Pocket3CameraWriterSupportReport = Pocket3WriterSupportReport
public typealias Pocket3SettingWriterSupportEntry = Pocket3WriterSupportEntry
