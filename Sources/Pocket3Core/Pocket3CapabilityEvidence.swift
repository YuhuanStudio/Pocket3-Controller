import Foundation

/// Camera families in an external project's evidence. A model marker or a
/// packet builder does not promote a capability to a different camera family.
public enum Pocket3CapabilityHardwareScope: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable {
    case pocket3 = "pocket3"
    case pocket4 = "pocket4"
    case pocket4Pro = "pocket4_pro"
    case action4 = "action4"
    case multiple = "multiple"
    case unknown
}

/// License/provenance is kept beside capability evidence so a source can be
/// reviewed before code or protocol constants are reused.
public enum Pocket3CapabilityLicense: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable {
    case official = "official"
    case mit = "mit"
    case apache2 = "apache_2_0"
    case mixed = "mixed"
    case sourceAvailableNoBlanketLicense = "source_available_no_blanket_license"
    case notApplicable = "not_applicable"
    case unknown
}

/// One auditable source claim. `commit`, `file`, and `url` are optional for
/// first-party observations, but external reverse-engineering claims carry all
/// three whenever the source provides them.
public struct Pocket3CapabilityProvenance: Codable, Sendable,
    Equatable, Hashable {
    public let project: String
    public let commit: String?
    public let file: String?
    public let url: String?
    public let license: Pocket3CapabilityLicense
    public let claim: String

    public init(project: String, commit: String? = nil, file: String? = nil,
                url: String? = nil, license: Pocket3CapabilityLicense,
                claim: String) {
        self.project = project
        self.commit = commit
        self.file = file
        self.url = url
        self.license = license
        self.claim = claim
    }
}

/// Evidence context shared by station, native-gimbal, capture-format and
/// settings candidates. Transport is the local path being described; an
/// upstream source that used another path is recorded in `provenance` and
/// `limitations` rather than silently changing local admission.
public struct Pocket3CapabilityEvidenceMetadata: Codable, Sendable,
    Equatable, Hashable {
    public let transport: CameraCapabilityTransport
    public let transportDetail: String
    public let hardwareScope: [Pocket3CapabilityHardwareScope]
    public let evidenceLevel: CapabilityEvidenceLevel
    public let license: Pocket3CapabilityLicense
    public let provenance: [Pocket3CapabilityProvenance]
    public let limitations: [String]

    public init(
        transport: CameraCapabilityTransport,
        transportDetail: String,
        hardwareScope: [Pocket3CapabilityHardwareScope],
        evidenceLevel: CapabilityEvidenceLevel,
        license: Pocket3CapabilityLicense,
        provenance: [Pocket3CapabilityProvenance],
        limitations: [String] = []
    ) {
        self.transport = transport
        self.transportDetail = transportDetail
        self.hardwareScope = hardwareScope
        self.evidenceLevel = evidenceLevel
        self.license = license
        self.provenance = provenance
        self.limitations = limitations
    }
}

public enum Pocket3CapabilityEvidenceCandidateID: String, Codable, Sendable,
    Equatable, Hashable, CaseIterable, Identifiable {
    case station = "station"
    case gimbal = "gimbal"
    case capture4K = "capture_4k"
    case settings = "settings"

    public var id: String { rawValue }
}

/// A machine-readable source/evidence row. Availability is deliberately
/// separate from `metadata.evidenceLevel`: a known protocol can still be
/// blocked on this product's transport or missing physical acceptance.
public struct Pocket3CapabilityEvidenceCandidate: Codable, Sendable,
    Equatable, Hashable, Identifiable {
    public let id: Pocket3CapabilityEvidenceCandidateID
    public let availability: CapabilityAvailability
    public let metadata: Pocket3CapabilityEvidenceMetadata

    public var evidenceLevel: CapabilityEvidenceLevel {
        metadata.evidenceLevel
    }

    public init(id: Pocket3CapabilityEvidenceCandidateID,
                availability: CapabilityAvailability,
                metadata: Pocket3CapabilityEvidenceMetadata) {
        self.id = id
        self.availability = availability
        self.metadata = metadata
    }
}

/// The bounded ecosystem evidence inventory published with the capability
/// graph. It is pure data: it never scans, joins Wi-Fi, opens a datalink or
/// sends a setting/gimbal packet.
public struct Pocket3CapabilityEvidenceInventory: Codable, Sendable,
    Equatable, Hashable {
    public static let currentVersion = 1
    public static let reportSource =
        "research/2026-09-13/POCKET3_REFERENCE_PROJECTS_DEEP_RESEARCH.md"

    public let version: Int
    public let candidates: [Pocket3CapabilityEvidenceCandidate]
    public let source: String

    public init(version: Int = Self.currentVersion,
                candidates: [Pocket3CapabilityEvidenceCandidate] =
                    Self.currentCandidates,
                source: String = Self.reportSource) {
        self.version = version
        self.candidates = candidates
        self.source = source
    }

    public static let current = Self()

    public func candidate(for id: Pocket3CapabilityEvidenceCandidateID)
        -> Pocket3CapabilityEvidenceCandidate? {
        candidates.first { $0.id == id }
    }

    public static let currentCandidates: [Pocket3CapabilityEvidenceCandidate] = [
        .init(
            id: .station,
            availability: .init(
                read: true,
                reason: "Station command readiness requires exact BLE/LAN identity and retained owner"),
            metadata: .init(
                transport: .multiple,
                transportDetail: "CoreBluetooth station provisioning followed by camera Wi-Fi TCP7001/UDP9004",
                hardwareScope: [.pocket3],
                evidenceLevel: .publicReverseEngineering,
                license: .mixed,
                provenance: [
                    .init(
                        project: "OpenPocketCine",
                        commit: "9b30b93572797c94db5ad9236fb746410f8d761f",
                        file: "handbook/src/content/docs/protocol/pocket3.md",
                        url: "https://github.com/erik-sutton95/OpenPocketCine/blob/9b30b93572797c94db5ad9236fb746410f8d761f/handbook/src/content/docs/protocol/pocket3.md",
                        license: .apache2,
                        claim: "Pocket 3 station transition and LAN identity sequence are Wi-Fi-datalink evidence"),
                    .init(
                        project: "OsmoOffload",
                        commit: "9c5bad9cadcc3fecd402a4bddef7a52d8b2ad54f",
                        file: "src/osmooffload/ble/pairing.py",
                        url: "https://github.com/intermittech/OsmoOffload/blob/9c5bad9cadcc3fecd402a4bddef7a52d8b2ad54f/src/osmooffload/ble/pairing.py",
                        license: .mit,
                        claim: "Pocket 3 53/10 E0 wake response is non-fatal and may continue the existing wake state"),
                    .init(
                        project: "OpenPocketCine macOS",
                        commit: "2bb7e0f4ae8b3dd9289f6c606f97c6d6b0e52a34",
                        file: "macos/Sources/OpenPocketCineMac/DatalinkDriver.swift",
                        url: "https://github.com/Yjsmall/OpenPocketCine/blob/2bb7e0f4ae8b3dd9289f6c606f97c6d6b0e52a34/macos/Sources/OpenPocketCineMac/DatalinkDriver.swift",
                        license: .apache2,
                        claim: "Explicit local endpoint/interface binding is a transport design reference; its Wi-Fi joiner is not product-safe"),
                    .init(
                        project: "Pocket3 Controller",
                        file: "Sources/Pocket3Core/Pocket3StationSession.swift",
                        license: .notApplicable,
                        claim: "The local station coordinator keeps 53/10 evidence on the existing 07/39 probe state and never auto-associates Wi-Fi")
                ],
                limitations: [
                    "53/10 is a typed diagnostic observation of the existing network-mode probe state; it does not add a new station operation",
                    "The current coordinator remains command-ready only after exact BLE/LAN identity and datalink-owner checks",
                    "No automatic Wi-Fi association or credential persistence is allowed"
                ])),
        .init(
            id: .gimbal,
            availability: .init(
                read: true,
                reason: "Native gimbal writes remain blocked until local command-ready physical evidence"),
            metadata: .init(
                transport: .wiFiDatalink,
                transportDetail: "Pocket 3 native 04/01 reference path; local BLE candidate remains unverified",
                hardwareScope: [.pocket3, .pocket4Pro],
                evidenceLevel: .publicReverseEngineering,
                license: .mixed,
                provenance: [
                    .init(
                        project: "Pocket3Direct-iOS",
                        commit: "da51f53d98c0c3723dc60371e10bfc9042071532",
                        file: "Pocket3Controller/Pocket3GimbalSession.swift",
                        url: "https://github.com/brianmerchant/Pocket3Direct-iOS/blob/da51f53d98c0c3723dc60371e10bfc9042071532/Pocket3Controller/Pocket3GimbalSession.swift",
                        license: .mit,
                        claim: "Pocket 3 04/01 neutral/release and TCP7001/UDP9004 station spine; published tests are offline"),
                    .init(
                        project: "Pocket3Direct-Android",
                        commit: "f30c3642c8d8e430cd9d19cf182aa064929c6b1b",
                        file: "app/src/main/java/dev/konraditurbe/osmosis/net/DumlTransport.kt",
                        url: "https://github.com/brianmerchant/Pocket3Direct-Android/blob/f30c3642c8d8e430cd9d19cf182aa064929c6b1b/app/src/main/java/dev/konraditurbe/osmosis/net/DumlTransport.kt",
                        license: .mit,
                        claim: "Pocket 3 station/gimbal reference with app-managed Wi-Fi; tests are protocol fixtures"),
                    .init(
                        project: "OpenPocketCine",
                        commit: "9b30b93572797c94db5ad9236fb746410f8d761f",
                        file: "handbook/src/content/docs/protocol/commands.md",
                        url: "https://github.com/erik-sutton95/OpenPocketCine/blob/9b30b93572797c94db5ad9236fb746410f8d761f/handbook/src/content/docs/protocol/commands.md",
                        license: .apache2,
                        claim: "Pocket 3 command catalog corroborates native gimbal packet families"),
                    .init(
                        project: "OsmoDesk",
                        commit: "2a8c4e0da622daad14ba916008b6bedf39e26dac",
                        file: "driver/gimbal.py",
                        url: "https://github.com/ElectronicPaper/OsmoDesk/tree/2a8c4e0da622daad14ba916008b6bedf39e26dac",
                        license: .sourceAvailableNoBlanketLicense,
                        claim: "P4 Pro development-camera gimbal measurements; Pocket 3/Pocket 4 are untested"),
                    .init(
                        project: "OsmoPalm",
                        commit: "f37b7da625dd196090b54fe24a8edbbd98df37d9",
                        file: "firmware/core2_panel/src/direct_camera.cpp",
                        url: "https://github.com/ElectronicPaper/OsmoPalm/tree/f37b7da625dd196090b54fe24a8edbbd98df37d9",
                        license: .sourceAvailableNoBlanketLicense,
                        claim: "P4 Pro development-camera station/gimbal safety architecture; Pocket 3/Pocket 4 are untested")
                ],
                limitations: [
                    "P4 Pro telemetry/layout and measured signs cannot unlock a Pocket 3 parser",
                    "04/01 packet construction or an ACK does not establish physical movement or stop completion",
                    "No local native gimbal writer is admitted by this inventory"
                ])),
        .init(
            id: .capture4K,
            availability: .init(
                read: true,
                reason: "4K capture evidence is bounded to UVC/AVFoundation trials; native recording and realtime limits stay separate"),
            metadata: .init(
                transport: .usbUVC,
                transportDetail: "USB UVC/AVFoundation capture metrics; camera Wi-Fi HEVC is a separate path",
                hardwareScope: [.pocket3],
                evidenceLevel: .localReadOnly,
                license: .notApplicable,
                provenance: [
                    .init(
                        project: "Pocket3 Controller",
                        file: "Sources/Pocket3Core/NativeCaptureFormatValidation.swift",
                        license: .notApplicable,
                        claim: "4K30 H.264 evaluation retains scalar codec/decode/realtime evidence without storing images"),
                    .init(
                        project: "Pocket3 Controller",
                        file: "docs/POCKET3_SUPPORT_MATRIX.md",
                        license: .notApplicable,
                        claim: "Advertised UVC formats and bounded 4K trials are kept separate from body-recording capability"),
                    .init(
                        project: "dji-remote",
                        commit: "c2012be6aca67d4882774cf5d9746f420a03e11f",
                        file: "app/src/main/java/com/dimadesu/djiremote/dji/DjiPayloads.kt",
                        url: "https://github.com/dimadesu/dji-remote/blob/c2012be6aca67d4882774cf5d9746f420a03e11f/app/src/main/java/com/dimadesu/djiremote/dji/DjiPayloads.kt",
                        license: .mit,
                        claim: "Pocket 4 HEVC JSON stream payload is a packet candidate and remains unconfirmed by the author")
                ],
                limitations: [
                    "UVC descriptor/frame evidence does not prove camera body recording or host HEVC input",
                    "A source-level Pocket 4 HEVC payload cannot raise Pocket 3 4K capability",
                    "Realtime rate, decode success and format availability remain independent fields"
                ])),
        .init(
            id: .settings,
            availability: .init(
                read: true,
                reason: "Pocket 3 accepted/status evidence from OpenPocketCine is Wi-Fi-only; local BLE writers remain gated"),
            metadata: .init(
                transport: .bluetoothDatalink,
                transportDetail: "Local CoreBluetooth FFF4 notifications + FFF5 write-without-response; upstream accepted/status evidence is Wi-Fi-only",
                hardwareScope: [.pocket3, .pocket4, .pocket4Pro],
                evidenceLevel: .publicReverseEngineering,
                license: .mixed,
                provenance: [
                    .init(
                        project: "OpenPocketCine",
                        commit: "9b30b93572797c94db5ad9236fb746410f8d761f",
                        file: "handbook/src/content/docs/protocol/pocket3.md",
                        url: "https://github.com/erik-sutton95/OpenPocketCine/blob/9b30b93572797c94db5ad9236fb746410f8d761f/handbook/src/content/docs/protocol/pocket3.md",
                        license: .apache2,
                        claim: "Pocket 3 setting accepted/status/readback survey used camera Wi-Fi datalink"),
                    .init(
                        project: "Kaze-for-DJI",
                        commit: "341a35de18493ff61f97c93b8b10161a7512aa36",
                        file: "ios/Pocket3Controller/Pocket3CameraSettings.swift",
                        url: "https://github.com/brianmerchant/Kaze-for-DJI/blob/341a35de18493ff61f97c93b8b10161a7512aa36/ios/Pocket3Controller/Pocket3CameraSettings.swift",
                        license: .unknown,
                        claim: "Pocket 3 command/readback source used as a protocol candidate, not local BLE write proof"),
                    .init(
                        project: "node-osmo",
                        commit: "cec92aec9304a5cc3dae7f7de541eef38ebb680e",
                        file: "src/device.ts",
                        url: "https://github.com/datagutt/node-osmo/blob/cec92aec9304a5cc3dae7f7de541eef38ebb680e/src/device.ts",
                        license: .mit,
                        claim: "FFF3 write mapping is historical and conflicts with the local FFF5 route; no Pocket 3 hardware acceptance"),
                    .init(
                        project: "dji-remote",
                        commit: "c2012be6aca67d4882774cf5d9746f420a03e11f",
                        file: "README.md; app/src/main/java/com/dimadesu/djiremote/dji/DjiModel.kt",
                        url: "https://github.com/dimadesu/dji-remote/blob/c2012be6aca67d4882774cf5d9746f420a03e11f/README.md",
                        license: .mit,
                        claim: "Pocket 4 model 0x0021 and JSON payload are unconfirmed; README confirms only Action 4 hardware")
                ],
                limitations: [
                    "OpenPocketCine accepted/status evidence is Wi-Fi-only and cannot authorize a BLE setter",
                    "FFF3 from node-osmo is not the current local FFF5 write characteristic",
                    "Pocket 4/Pocket 4 Pro sources are not Pocket 3 BLE writer evidence",
                    "Every local write still requires same-session ACK, matching readback and restore"
                ]))
    ]
}
