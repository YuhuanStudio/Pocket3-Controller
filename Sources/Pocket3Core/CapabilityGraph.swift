import Foundation

/// The five evidence levels used by the Pocket 3 capability inventory.
///
/// A source or fixture can describe a capability without making it available
/// to the current camera session.  Keeping the level separate from access
/// prevents protocol research and hardware results from becoming one boolean.
public enum CapabilityEvidenceLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case officialSpecification = "A"
    case publicReverseEngineering = "B"
    case softwareFixture = "C"
    case localReadOnly = "D"
    case localVerifiedWrite = "E"

    public var rank: Int {
        switch self {
        case .officialSpecification: 1
        case .publicReverseEngineering: 2
        case .softwareFixture: 3
        case .localReadOnly: 4
        case .localVerifiedWrite: 5
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    public var title: String {
        switch self {
        case .officialSpecification: "Official specification"
        case .publicReverseEngineering: "Public reverse engineering"
        case .softwareFixture: "Software fixture or parser"
        case .localReadOnly: "Local read-only observation"
        case .localVerifiedWrite: "Local verified write"
        }
    }
}

/// Transport names are intentionally product-level.  They describe which
/// path would need to be healthy; they are not proof that the path is active.
public enum CameraCapabilityTransport: String, Codable, Sendable, CaseIterable {
    case usbUVC = "usb_uvc"
    case avFoundation = "avfoundation"
    case bluetooth = "bluetooth"
    case bluetoothDatalink = "bluetooth_datalink"
    case wiFiDatalink = "wifi_datalink"
    case local = "local"
    case multiple = "multiple"
    case unknown
}

/// Read/write access and current-session verification are independent facts.
/// `verified` means the capability's result was observed and confirmed for
/// the represented operation.  For a format this can be frame delivery; for
/// a setting it is a matching readback after a write.
public struct CapabilityAvailability: Codable, Sendable, Equatable, Hashable {
    public let read: Bool
    public let write: Bool
    public let verified: Bool
    public let reason: String?

    public init(read: Bool = false, write: Bool = false, verified: Bool = false,
                reason: String? = nil) {
        self.read = read
        self.write = write
        self.verified = verified
        self.reason = reason
    }

    public var readAvailable: Bool { read }
    public var writeAvailable: Bool { write }
    public var verifiedAvailable: Bool { verified }
    public var readable: Bool { read }
    public var writable: Bool { write }
    public var writeVerified: Bool { verified }
    public var isAvailable: Bool { read || write }

    /// Stable, language-neutral detail for tooltips and diagnostics. The
    /// evidence level is carried by the enclosing capability value.
    public var accessSummary: String {
        "read=\(read),write=\(write),verified=\(verified)"
    }

    public static func unavailable(reason: String? = nil) -> Self {
        .init(reason: reason)
    }

    public static var readOnly: Self { .init(read: true) }
    public static var writable: Self { .init(read: true, write: true) }
    public static var verified: Self { .init(read: true, write: true, verified: true) }
}

/// A UVC mode is a USB capture choice.  `wireCodec` stays optional because an
/// AVFoundation pixel-buffer subtype does not identify the USB wire codec.
public enum UVCCaptureWireCodec: String, Codable, Sendable, CaseIterable {
    case mjpeg
    case h264
    case unknown
}

public struct UVCCaptureFormat: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let mode: CaptureMode
    public let inputPixelFormat: CapturePixelFormat?
    public let wireCodec: UVCCaptureWireCodec?
    public let availability: CapabilityAvailability
    public let evidence: CapabilityEvidenceLevel
    public let transport: CameraCapabilityTransport

    public var id: String {
        let input = inputPixelFormat?.rawValue ?? "unknown"
        return "\(mode.id):\(input)"
    }

    public init(mode: CaptureMode, inputPixelFormat: CapturePixelFormat? = nil,
                wireCodec: UVCCaptureWireCodec? = nil,
                availability: CapabilityAvailability,
                evidence: CapabilityEvidenceLevel,
                transport: CameraCapabilityTransport = .usbUVC) {
        self.mode = mode
        self.inputPixelFormat = inputPixelFormat
        self.wireCodec = wireCodec
        self.availability = availability
        self.evidence = evidence
        self.transport = transport
    }

    public var pixelFormat: CapturePixelFormat? { inputPixelFormat }
    public var evidenceLevel: CapabilityEvidenceLevel { evidence }
}

/// AVFoundation output is a Mac-side representation.  It is deliberately
/// separate from `UVCCaptureWireCodec` and from body recording compression.
public enum HostOutputCodec: String, Codable, Sendable, CaseIterable {
    case bgra
    case h264
    case hevc
    case jpeg
    case native
    case systemDefault = "system_default"

    public init?(avFoundationName: String) {
        switch avFoundationName.lowercased() {
        case "avc1", "h264", "avc": self = .h264
        case "hvc1", "hevc", "hev1": self = .hevc
        case "jpeg", "mjpg", "mjpeg": self = .jpeg
        default: return nil
        }
    }

    public var isCompressed: Bool { self == .h264 || self == .hevc || self == .jpeg }
}

public struct HostOutputCodecCapability: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let codec: HostOutputCodec
    public let requested: Bool
    public let observedSampleCount: Int?
    public let availability: CapabilityAvailability
    public let evidence: CapabilityEvidenceLevel
    public let transport: CameraCapabilityTransport

    public var id: String { codec.rawValue }
    public var evidenceLevel: CapabilityEvidenceLevel { evidence }

    public init(codec: HostOutputCodec, requested: Bool = false,
                observedSampleCount: Int? = nil,
                availability: CapabilityAvailability,
                evidence: CapabilityEvidenceLevel,
                transport: CameraCapabilityTransport = .avFoundation) {
        self.codec = codec
        self.requested = requested
        self.observedSampleCount = observedSampleCount
        self.availability = availability
        self.evidence = evidence
        self.transport = transport
    }
}

/// Body recording keeps the camera-side enum and raw bytes together.  A nil
/// field means that the selected legal pair has not been read back yet; it is
/// different from an unknown raw value, which remains in its `*Raw` field.
public struct BodyRecordingFormat: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let resolution: CameraVideoResolution?
    public let resolutionRaw: UInt8?
    public let frameRate: CameraFrameRate?
    public let frameRateRaw: UInt8?
    public let compression: CameraVideoCompression?
    public let compressionRaw: UInt8?
    public let raw: Data?

    public var id: String {
        [rawValue(resolution?.rawValue, fallback: resolutionRaw),
         rawValue(frameRate?.rawValue, fallback: frameRateRaw),
         rawValue(compression?.rawValue, fallback: compressionRaw)].joined(separator: ":")
    }

    public init(resolution: CameraVideoResolution? = nil, resolutionRaw: UInt8? = nil,
                frameRate: CameraFrameRate? = nil, frameRateRaw: UInt8? = nil,
                compression: CameraVideoCompression? = nil, compressionRaw: UInt8? = nil,
                raw: Data? = nil) {
        self.resolution = resolution
        self.resolutionRaw = resolutionRaw ?? resolution?.rawValue
        self.frameRate = frameRate
        self.frameRateRaw = frameRateRaw ?? frameRate?.rawValue
        self.compression = compression
        self.compressionRaw = compressionRaw ?? compression?.rawValue
        self.raw = raw
    }

    public init(_ parameters: CameraVideoParameters) {
        self.init(resolution: parameters.resolution, resolutionRaw: parameters.resolutionRaw,
                  frameRate: parameters.frameRate, frameRateRaw: parameters.frameRateRaw,
                  compression: parameters.compression, compressionRaw: parameters.compressionRaw,
                  raw: parameters.raw)
    }

    public var aspectRatio: BodyRecordingAspectRatio {
        switch resolution {
        case .p1080, .p2_7K, .p4K: .sixteenByNine
        case .square1080, .square2160, .square3K: .oneByOne
        case .portrait1080, .portrait2_7K, .portrait3K: .nineBySixteen
        case nil: .unknown
        }
    }

    public var dimensions: (width: Int, height: Int)? {
        switch resolution {
        case .p1080: (1920, 1080)
        case .p2_7K: (2704, 1520)
        case .p4K: (3840, 2160)
        case .square1080: (1080, 1080)
        case .square2160: (2160, 2160)
        case .square3K: (3072, 3072)
        case .portrait1080: (1080, 1920)
        case .portrait2_7K: (1520, 2704)
        case .portrait3K: (1728, 3072)
        case nil: nil
        }
    }

    private func rawValue(_ typed: UInt8?, fallback: UInt8?) -> String {
        let value = typed ?? fallback
        return value.map { String(format: "%02x", $0) } ?? "unknown"
    }
}

public enum BodyRecordingAspectRatio: String, Codable, Sendable, CaseIterable {
    case sixteenByNine = "16:9"
    case oneByOne = "1:1"
    case nineBySixteen = "9:16"
    case unknown
}

public struct BodyRecordingFormatCapability: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let format: BodyRecordingFormat
    public let availability: CapabilityAvailability
    public let evidence: CapabilityEvidenceLevel
    public let transport: CameraCapabilityTransport

    public var id: String { format.id }
    public var evidenceLevel: CapabilityEvidenceLevel { evidence }

    public init(format: BodyRecordingFormat, availability: CapabilityAvailability,
                evidence: CapabilityEvidenceLevel,
                transport: CameraCapabilityTransport = .bluetoothDatalink) {
        self.format = format
        self.availability = availability
        self.evidence = evidence
        self.transport = transport
    }

    public init(readback: CameraVideoParameters,
                commandReady: Bool = false,
                writeVerified: Bool = false) {
        self.init(format: BodyRecordingFormat(readback),
                  availability: .init(read: true, write: commandReady,
                                      verified: writeVerified,
                                      reason: writeVerified ? nil : commandReady ? "Write requires matching body readback" : nil),
                  evidence: writeVerified ? .localVerifiedWrite : .localReadOnly)
    }

    /// Converts one sparse `camcap_video_format` entry into the graph's body
    /// format type while preserving its complete three-byte entry. Compression
    /// is intentionally nil because that capability table does not carry it.
    public init(capability: CameraVideoFormatCapability,
                commandReady: Bool = false,
                writeVerified: Bool = false) {
        self.init(
            format: BodyRecordingFormat(
                resolution: capability.resolution, resolutionRaw: capability.resolutionRaw,
                frameRate: capability.frameRate, frameRateRaw: capability.frameRateRaw,
                raw: capability.raw),
            availability: .init(read: true, write: commandReady,
                                verified: writeVerified,
                                reason: capability.flagsRaw == 0 ? nil : "Unknown body-format flags"),
            evidence: writeVerified ? .localVerifiedWrite : .localReadOnly)
    }
}

/// The official Pocket 3 resolution families are useful inventory entries,
/// but their legal FPS/codec combinations remain unknown until the camera
/// returns `camcap_video_format`/`cam_video_param_v2` for this session.
public enum Pocket3BodyRecordingCatalog {
    public static var knownResolutionFamilies: [BodyRecordingFormatCapability] {
        CameraVideoResolution.allCases.map { resolution in
            BodyRecordingFormatCapability(
                format: BodyRecordingFormat(resolution: resolution),
                availability: .unavailable(reason: "Known camera resolution; current legal FPS/codec pair is not read back"),
                evidence: .officialSpecification)
        }
    }

    /// Keep the official resolution families visible even after a sparse
    /// session readback supplies the legal resolution/FPS pairs.
    public static func merging(_ observed: [BodyRecordingFormatCapability]) -> [BodyRecordingFormatCapability] {
        var result = knownResolutionFamilies
        for value in observed where !result.contains(where: { $0.id == value.id }) {
            result.append(value)
        }
        return result
    }
}

public enum NativeSessionReadiness: String, Codable, Sendable, CaseIterable {
    case disconnected
    case blePaired = "ble_paired"
    case credentialsAvailable = "credentials_available"
    case datalinkHandshaking = "datalink_handshaking"
    case commandReady = "command_ready"
    case liveReady = "live_ready"
    case error
}

public struct NativeSessionCapability: Codable, Sendable, Equatable, Hashable {
    public let readiness: NativeSessionReadiness
    public let availability: CapabilityAvailability
    public let evidence: CapabilityEvidenceLevel
    public let transport: CameraCapabilityTransport

    public init(readiness: NativeSessionReadiness,
                availability: CapabilityAvailability,
                evidence: CapabilityEvidenceLevel,
                transport: CameraCapabilityTransport = .bluetoothDatalink) {
        self.readiness = readiness
        self.availability = availability
        self.evidence = evidence
        self.transport = transport
    }

    public var commandReady: Bool {
        readiness == .commandReady || readiness == .liveReady
    }
    public var evidenceLevel: CapabilityEvidenceLevel { evidence }

    public static var disconnected: Self {
        .init(readiness: .disconnected, availability: .unavailable(reason: "No native camera session"), evidence: .softwareFixture)
    }

    public static func from(_ status: NativeControlStatus?) -> Self {
        guard let status else { return .disconnected }
        let reason = status.availability == .disarmed ? "Native session is disarmed" : nil
        switch status.availability {
        case .connecting:
            return .init(readiness: .datalinkHandshaking,
                         availability: .init(reason: "Datalink handshake is in progress"), evidence: .localReadOnly)
        case .ready, .busy, .staleFeedback, .blocked, .disarmed:
            return .init(readiness: .commandReady,
                         availability: .init(read: status.telemetryFresh,
                                             write: status.availability == .ready || status.availability == .busy,
                                             verified: status.lastStop?.stableTelemetry == true,
                                             reason: reason ?? (status.telemetryFresh ? nil : "Native telemetry is stale")),
                         evidence: .localReadOnly)
        case .error:
            return .init(readiness: .error, availability: .unavailable(reason: "Native session reported an error"), evidence: .localReadOnly)
        case .connectionChanged, .disconnected:
            return .init(readiness: .disconnected, availability: .unavailable(reason: "Native session is not bound to the current camera"), evidence: .localReadOnly)
        }
    }

    /// Projects the generation-safe native session state used by the App into
    /// the credential-free graph status. Session identifiers never enter this
    /// projection; readiness and access remain explicit.
    public static func from(_ status: NativeCameraSessionStatus) -> Self {
        let readiness: NativeSessionReadiness
        let availability: CapabilityAvailability
        let evidence: CapabilityEvidenceLevel
        switch status.state {
        case .disconnected:
            readiness = .disconnected
            availability = .unavailable(reason: "No native camera session")
            evidence = .softwareFixture
        case .paired:
            readiness = .blePaired
            availability = .init(read: true, reason: "BLE pairing is available; command session is not ready")
            evidence = .localReadOnly
        case .credentialsAvailable:
            readiness = .credentialsAvailable
            availability = .init(read: true, reason: "Native datalink has not completed its handshake")
            evidence = .localReadOnly
        case .datalinkHandshaking:
            readiness = .datalinkHandshaking
            availability = .init(read: true, reason: "Datalink handshake is in progress")
            evidence = .localReadOnly
        case .commandReady:
            readiness = .commandReady
            availability = .init(read: true, write: true, reason: "No camera setting write has been verified")
            evidence = .localReadOnly
        case .liveReady:
            readiness = .liveReady
            availability = .init(read: true, write: true, reason: "No camera setting write has been verified")
            evidence = .localReadOnly
        }
        return .init(readiness: readiness, availability: availability, evidence: evidence)
    }
}

public enum LiveSessionReadiness: String, Codable, Sendable, CaseIterable {
    case unavailable
    case connecting
    case ready
    case interrupted
    case error
}

public struct WiFiLiveProfile: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let codec: HostOutputCodec
    public let availability: CapabilityAvailability
    public let evidence: CapabilityEvidenceLevel

    public var id: String { "\(width)x\(height)@\(String(format: "%.3f", frameRate)):\(codec.rawValue)" }
    public var evidenceLevel: CapabilityEvidenceLevel { evidence }

    public init(width: Int, height: Int, frameRate: Double, codec: HostOutputCodec,
                availability: CapabilityAvailability, evidence: CapabilityEvidenceLevel) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.availability = availability
        self.evidence = evidence
    }
}

public struct LiveSessionCapability: Codable, Sendable, Equatable, Hashable {
    public let readiness: LiveSessionReadiness
    public let profiles: [WiFiLiveProfile]
    public let availability: CapabilityAvailability
    public let evidence: CapabilityEvidenceLevel
    public let transport: CameraCapabilityTransport

    public var evidenceLevel: CapabilityEvidenceLevel { evidence }

    public init(readiness: LiveSessionReadiness = .unavailable,
                profiles: [WiFiLiveProfile] = [],
                availability: CapabilityAvailability = .unavailable(),
                evidence: CapabilityEvidenceLevel = .softwareFixture,
                transport: CameraCapabilityTransport = .wiFiDatalink) {
        self.readiness = readiness
        self.profiles = profiles
        self.availability = availability
        self.evidence = evidence
        self.transport = transport
    }

    public static var unavailable: Self {
        .init(availability: .unavailable(reason: "Camera Wi-Fi live view is disabled; USB capture remains independent"))
    }
}

public enum Pocket3CapabilityID: String, Codable, Sendable, CaseIterable {
    case uvcCapture = "uvc_capture"
    case hostOutput = "host_output"
    case bodyRecording = "body_recording"
    case nativeSession = "native_session"
    case liveSession = "live_session"
}

public struct Pocket3CapabilityGraphNode: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: Pocket3CapabilityID
    public let dependsOn: [Pocket3CapabilityID]
    public let availability: CapabilityAvailability
    public let evidence: CapabilityEvidenceLevel

    public var evidenceLevel: CapabilityEvidenceLevel { evidence }

    public init(id: Pocket3CapabilityID, dependsOn: [Pocket3CapabilityID] = [],
                availability: CapabilityAvailability,
                evidence: CapabilityEvidenceLevel) {
        self.id = id
        self.dependsOn = dependsOn
        self.availability = availability
        self.evidence = evidence
    }
}

/// Typed runtime inventory shared by status, CLI and MCP callers.
public struct Pocket3CapabilityGraph: Codable, Sendable, Equatable {
    public let version: Int
    public let uvcCaptureFormats: [UVCCaptureFormat]
    public let hostOutputCodecs: [HostOutputCodecCapability]
    public let bodyRecordingFormats: [BodyRecordingFormatCapability]
    public let nativeSession: NativeSessionCapability
    public let liveSession: LiveSessionCapability
    /// Read-only firmware/accessory/system preference inventory. Optional so
    /// older status JSON remains decodable when no BLE observation exists.
    public let deviceInventory: Pocket3DeviceSystemInventory?
    public let nodes: [Pocket3CapabilityGraphNode]

    public init(version: Int = 1,
                uvcCaptureFormats: [UVCCaptureFormat] = [],
                hostOutputCodecs: [HostOutputCodecCapability] = [],
                bodyRecordingFormats: [BodyRecordingFormatCapability] = Pocket3BodyRecordingCatalog.knownResolutionFamilies,
                nativeSession: NativeSessionCapability = .disconnected,
                liveSession: LiveSessionCapability = .unavailable,
                deviceInventory: Pocket3DeviceSystemInventory? = nil) {
        self.version = version
        self.uvcCaptureFormats = uvcCaptureFormats
        self.hostOutputCodecs = hostOutputCodecs
        self.bodyRecordingFormats = bodyRecordingFormats
        self.nativeSession = nativeSession
        self.liveSession = liveSession
        self.deviceInventory = deviceInventory

        let uvc = Self.aggregate(uvcCaptureFormats.map(\.availability))
        let host = Self.aggregate(hostOutputCodecs.map(\.availability))
        let body = Self.aggregate(bodyRecordingFormats.map(\.availability))
        self.nodes = [
            .init(id: .uvcCapture, availability: uvc,
                  evidence: Self.highest(uvcCaptureFormats.map(\.evidence), fallback: .softwareFixture)),
            .init(id: .hostOutput, dependsOn: [.uvcCapture], availability: host,
                  evidence: Self.highest(hostOutputCodecs.map(\.evidence), fallback: .softwareFixture)),
            .init(id: .bodyRecording, dependsOn: [.nativeSession], availability: body,
                  evidence: Self.highest(bodyRecordingFormats.map(\.evidence), fallback: .softwareFixture)),
            .init(id: .nativeSession, availability: nativeSession.availability, evidence: nativeSession.evidence),
            .init(id: .liveSession, dependsOn: [.nativeSession], availability: liveSession.availability,
                  evidence: liveSession.evidence)
        ]
    }

    /// Build the graph from the already published USB service status.  This
    /// function performs no I/O and intentionally leaves native body formats
    /// at their conservative catalog/readback boundary.
    public static func from(phase: String, capture: CaptureStats,
                            requestedMode: CaptureMode? = nil,
                            requestedPixelFormat: CapturePixelFormat? = nil,
                            requestedOutputPolicy: CaptureOutputPolicy? = nil,
                            nativeControl: NativeControlStatus? = nil,
                            nativeSession: NativeSessionCapability? = nil,
                            bodyRecordingFormats: [BodyRecordingFormatCapability]? = nil,
                            liveSession: LiveSessionCapability = .unavailable,
                            deviceInventory: Pocket3DeviceSystemInventory? = nil) -> Self {
        var uvc: [UVCCaptureFormat] = []
        if let frame = capture.frame,
           frame.width > 0, frame.height > 0,
           frame.receivedUptime.isFinite,
           let fps = finitePositive(capture.sampleDiagnostics?.requestedFrameRate)
                ?? requestedMode?.frameRate
                ?? finitePositive(capture.recentFPS) {
            let mode = CaptureMode(width: frame.width, height: frame.height, frameRate: fps)
            let fresh = capture.age.map { $0.isFinite && $0 >= 0 && $0 <= 1 } == true
            let input = frame.inputPixelFormat ?? requestedPixelFormat.flatMap { $0 == .automatic ? nil : $0 }
            uvc.append(.init(mode: mode, inputPixelFormat: input,
                             availability: .init(read: true, write: phase == "ready",
                                                 verified: fresh,
                                                 reason: fresh ? nil : "Capture frame is stale"),
                             evidence: .localReadOnly))
        } else if let requestedMode {
            uvc.append(.init(mode: requestedMode,
                             inputPixelFormat: requestedPixelFormat.flatMap { $0 == .automatic ? nil : $0 },
                             availability: .init(write: phase == "connecting" || phase == "ready",
                                                 reason: "Waiting for a frame to verify delivery"),
                             evidence: .softwareFixture))
        }

        let output = Self.outputCapabilities(capture: capture, phase: phase,
                                             requestedPolicy: requestedOutputPolicy)
        return Self(uvcCaptureFormats: uvc, hostOutputCodecs: output,
                    bodyRecordingFormats: bodyRecordingFormats.map(Pocket3BodyRecordingCatalog.merging)
                        ?? Pocket3BodyRecordingCatalog.knownResolutionFamilies,
                    nativeSession: nativeSession ?? .from(nativeControl),
                    liveSession: liveSession, deviceInventory: deviceInventory)
    }

    /// Adds a read-only device inventory to a graph assembled by the USB
    /// service without recomputing or changing any USB/native capability.
    public func adding(deviceInventory: Pocket3DeviceSystemInventory?) -> Self {
        Self(version: version, uvcCaptureFormats: uvcCaptureFormats,
             hostOutputCodecs: hostOutputCodecs,
             bodyRecordingFormats: bodyRecordingFormats,
             nativeSession: nativeSession, liveSession: liveSession,
             deviceInventory: deviceInventory)
    }

    private static func outputCapabilities(capture: CaptureStats, phase: String,
                                           requestedPolicy: CaptureOutputPolicy?) -> [HostOutputCodecCapability] {
        let diagnostics = capture.sampleDiagnostics
        let policy = requestedPolicy ?? diagnostics?.requestedOutputPolicy.flatMap {
            HostOutputCodec(rawValue: $0)?.mapPolicy
        }
        let active = phase == "ready" || phase == "stalled" || phase == "moving" || phase == "stopping"
        let availableNames = Set(diagnostics?.availableVideoOutputCodecs ?? [])
        let output = capture.frame?.outputPixelFormat?.lowercased()
        let decodedH264 = max(0, diagnostics?.decodedH264FrameCount ?? 0)
        let decodedHEVC = max(0, diagnostics?.decodedHEVCFrameCount ?? 0)

        func hasH264Codec() -> Bool { availableNames.contains { ["avc1", "h264", "avc"].contains($0.lowercased()) } }
        func hasHEVCCodec() -> Bool { availableNames.contains { ["hvc1", "hevc", "hev1"].contains($0.lowercased()) } }

        let bgraRead = output == "bgra" || diagnostics?.availableVideoOutputPixelFormats?.contains(where: { $0.lowercased() == "bgra" }) == true
        let bgra = HostOutputCodecCapability(codec: .bgra, requested: policy == .bgra,
            observedSampleCount: output == "bgra" ? max(0, capture.frames) : nil,
            availability: .init(read: active && bgraRead, write: active,
                                verified: active && bgraRead && capture.age.map { $0 <= 1 } == true,
                                reason: active ? (bgraRead ? nil : "No BGRA frame observed") : "Capture session is not active"),
            evidence: bgraRead ? .localReadOnly : .softwareFixture)

        let h264 = HostOutputCodecCapability(codec: .h264, requested: policy == .h264,
            observedSampleCount: decodedH264,
            availability: .init(read: active && (hasH264Codec() || decodedH264 > 0),
                                write: active && hasH264Codec(),
                                verified: active && decodedH264 > 0,
                                reason: !active ? "Capture session is not active" : hasH264Codec() || decodedH264 > 0 ? nil : "AVFoundation did not advertise H.264 output"),
            evidence: decodedH264 > 0 ? .localReadOnly : .softwareFixture)

        let hevc = HostOutputCodecCapability(codec: .hevc, requested: policy == .hevc,
            observedSampleCount: decodedHEVC,
            availability: .init(read: active && (hasHEVCCodec() || decodedHEVC > 0),
                                write: active && hasHEVCCodec(),
                                verified: active && decodedHEVC > 0,
                                reason: !active ? "Capture session is not active" : hasHEVCCodec() || decodedHEVC > 0 ? nil : "AVFoundation did not advertise HEVC output"),
            evidence: decodedHEVC > 0 ? .localReadOnly : .softwareFixture)
        return [bgra, h264, hevc]
    }

    private static func aggregate(_ values: [CapabilityAvailability]) -> CapabilityAvailability {
        guard !values.isEmpty else { return .unavailable() }
        let read = values.contains(where: \.read)
        let write = values.contains(where: \.write)
        let verified = values.contains(where: \.verified)
        let reason = values.first(where: { $0.reason != nil })?.reason
        return .init(read: read, write: write, verified: verified, reason: reason)
    }

    private static func highest(_ values: [CapabilityEvidenceLevel], fallback: CapabilityEvidenceLevel) -> CapabilityEvidenceLevel {
        values.max() ?? fallback
    }

    private static func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

private extension HostOutputCodec {
    /// CaptureOutputPolicy and HostOutputCodec intentionally remain separate
    /// enums, but status construction needs one small, explicit bridge.
    var mapPolicy: CaptureOutputPolicy? {
        switch self {
        case .bgra: .bgra
        case .h264: .h264
        case .hevc: .hevc
        case .native: .native
        case .systemDefault: .systemDefault
        case .jpeg: nil
        }
    }
}

public typealias UVCCaptureFormatCapability = UVCCaptureFormat
public typealias BodyRecordingCapability = BodyRecordingFormatCapability
public typealias CameraCapabilityGraph = Pocket3CapabilityGraph
public typealias CapabilityGraph = Pocket3CapabilityGraph
