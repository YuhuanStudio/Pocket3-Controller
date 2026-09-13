import Foundation

/// The result of a read-only admission audit.  A descriptor or a zero-callback
/// AVFoundation trial never makes the direct endpoint stream-ready.
public enum DirectUVCOwnershipAdmissionState: String, Codable, Sendable,
    Equatable, CaseIterable {
    case blockedByAVFoundationOwner = "blocked_by_avfoundation_owner"
    case blockedBySystemOwner = "blocked_by_system_owner"
    case blockedByUnsafeOperation = "blocked_by_unsafe_operation"
    case blockedByInvalidEvidence = "blocked_by_invalid_evidence"
    case readyForNegotiation = "ready_for_negotiation"
}

/// Conditions are declarative.  The evaluator never performs the condition
/// and never recommends seize, alternate-setting changes, or process kills.
public enum DirectUVCOwnershipAdmissionCondition: String, Codable, Sendable,
    Equatable, CaseIterable {
    case stopAndDrainAVFoundation = "stop_and_drain_avfoundation"
    case normalOpenAfterOwnerRelease = "normal_open_after_owner_release"
    case descriptorEndpointMatch = "descriptor_endpoint_match"
    case preserveNoSeize = "preserve_no_seize"
    case preserveNoAlternateSettingChange = "preserve_no_alternate_setting_change"
    case preserveNoProbeOrCommit = "preserve_no_probe_or_commit"
    case preserveNoPipeRead = "preserve_no_pipe_read"
    case boundedNegotiationReview = "bounded_negotiation_review"
    case releaseDirectResourcesBeforeAVFoundationRestart = "release_direct_resources_before_avfoundation_restart"
}

public enum DirectUVCHostOutputStatus: String, Codable, Sendable,
    Equatable, CaseIterable {
    case notObserved = "not_observed"
    case expectedZeroCallbacks = "expected_zero_callbacks"
    case unexpectedZeroCallbacks = "unexpected_zero_callbacks"
    case callbacksObserved = "callbacks_observed"
}

/// Descriptor evidence for the Pocket 3 frame-based H.264 candidate.  It is
/// intentionally labelled as a candidate: these intervals do not prove that
/// macOS can own the VS interface or receive a stream from it.
public struct DirectUVCFrameBasedFormatEvidence: Codable, Sendable,
    Equatable {
    public let descriptorArtifact: String
    public let formatSubtype: String
    public let codec: DirectUVCVideoCodec
    public let width: UInt16
    public let height: UInt16
    public let intervals100ns: [UInt32]
    public let status: String

    public init(descriptorArtifact: String, formatSubtype: String,
                codec: DirectUVCVideoCodec, width: UInt16, height: UInt16,
                intervals100ns: [UInt32],
                status: String = "descriptor_candidate_not_stream_confirmed") {
        self.descriptorArtifact = descriptorArtifact
        self.formatSubtype = formatSubtype
        self.codec = codec
        self.width = width
        self.height = height
        self.intervals100ns = intervals100ns
        self.status = status
    }
}

/// Exact scalar identity and format facts that a future direct-UVC collector
/// must bind before attempting any negotiation. Defaults match the reviewed
/// Pocket 3 H.264 4K60 descriptor candidate; they are not a hardware stream
/// or ownership confirmation. The separate UYVY host observation belongs to
/// `DirectUVCHostOutputObservation`. In particular, endpoint 0x82 becomes
/// evidence only when a normal open returns that matching observation.
public struct DirectUVCOwnershipAdmissionRequest: Codable, Sendable,
    Equatable {
    public static let currentVersion = 1
    public static let currentProfile = "direct_uvc_h264_4k60_ownership_v1"
    public static let reviewedFormatEvidence =
        DirectUVCFrameBasedFormatEvidence(
            descriptorArtifact:
                "artifacts/usb-all-descriptors-2026-09-09.json:H264_FORMAT_FRAME_BASED",
            formatSubtype: "FORMAT_FRAME_BASED", codec: .h264,
            width: 3840, height: 2160,
            intervals100ns: [166_666, 200_000, 208_333, 333_333,
                             400_000, 416_666])
    public static let reviewedSources = [
        "local:artifacts/usb-all-descriptors-2026-09-09.json",
        "daijertech/obs-dji-uvc@504452d",
        "BELABOX/gstlibuvch264src@1644b6d"
    ]

    public let version: Int
    public let profile: String
    public let location: UInt32
    public let interfaceNumber: UInt8
    public let alternateSetting: UInt8
    public let endpointAddress: UInt8
    public let codec: DirectUVCVideoCodec
    public let inputFourCC: String
    public let width: UInt16
    public let height: UInt16
    public let frameRate: Int
    public let expectedRegistryID: String?
    public let expectedBootSessionID: String?

    public init(
        location: UInt32,
        interfaceNumber: UInt8 = 1,
        alternateSetting: UInt8 = 0,
        endpointAddress: UInt8 = 0x82,
        codec: DirectUVCVideoCodec = .h264,
        inputFourCC: String = "H264",
        width: UInt16 = 3840,
        height: UInt16 = 2160,
        frameRate: Int = 60,
        expectedRegistryID: String? = nil,
        expectedBootSessionID: String? = nil
    ) throws {
        guard interfaceNumber > 0,
              endpointAddress & 0x80 != 0,
              endpointAddress & 0x7f != 0,
              !inputFourCC.isEmpty, inputFourCC.utf8.count <= 16,
              width > 0, height > 0,
              (1...120).contains(frameRate),
              expectedRegistryID.map({ !$0.isEmpty }) ?? true,
              expectedBootSessionID.map({ !$0.isEmpty }) ?? true else {
            throw DirectUVCOwnershipAdmissionError.invalidRequest
        }
        version = Self.currentVersion
        profile = Self.currentProfile
        self.location = location
        self.interfaceNumber = interfaceNumber
        self.alternateSetting = alternateSetting
        self.endpointAddress = endpointAddress
        self.codec = codec
        self.inputFourCC = inputFourCC
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.expectedRegistryID = expectedRegistryID
        self.expectedBootSessionID = expectedBootSessionID
    }

    private enum CodingKeys: String, CodingKey {
        case version, profile, location, interfaceNumber, alternateSetting,
             endpointAddress, codec, inputFourCC, width, height, frameRate,
             expectedRegistryID, expectedBootSessionID
    }

    /// Revalidates decoded requests so JSON cannot turn an inventory record
    /// into an arbitrary interface/endpoint probe.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        let profile = try values.decode(String.self, forKey: .profile)
        guard version == Self.currentVersion,
              profile == Self.currentProfile else {
            throw DirectUVCOwnershipAdmissionError.invalidRequest
        }
        try self.init(
            location: values.decode(UInt32.self, forKey: .location),
            interfaceNumber: values.decode(UInt8.self, forKey: .interfaceNumber),
            alternateSetting: values.decode(UInt8.self, forKey: .alternateSetting),
            endpointAddress: values.decode(UInt8.self, forKey: .endpointAddress),
            codec: values.decode(DirectUVCVideoCodec.self, forKey: .codec),
            inputFourCC: values.decode(String.self, forKey: .inputFourCC),
            width: values.decode(UInt16.self, forKey: .width),
            height: values.decode(UInt16.self, forKey: .height),
            frameRate: values.decode(Int.self, forKey: .frameRate),
            expectedRegistryID: values.decodeIfPresent(
                String.self, forKey: .expectedRegistryID),
            expectedBootSessionID: values.decodeIfPresent(
                String.self, forKey: .expectedBootSessionID))
    }
}

public enum DirectUVCOwnershipAdmissionError: Error, Codable, Sendable,
    Equatable {
    case invalidRequest
    case invalidEvidence
}

/// Scalar host-output evidence is kept beside direct ownership evidence so a
/// zero-callback UYVY result cannot be mistaken for a direct-UVC failure.
public struct DirectUVCHostOutputObservation: Codable, Sendable, Equatable {
    public let selectedInputFourCC: String?
    public let inputPortFourCC: String?
    public let callbackCount: Int?
    public let expectedZeroCallbacks: Bool
    public let runtimeErrorCount: Int
    public let interruptionCount: Int

    public init(selectedInputFourCC: String? = nil,
                inputPortFourCC: String? = nil,
                callbackCount: Int? = nil,
                expectedZeroCallbacks: Bool = false,
                runtimeErrorCount: Int = 0,
                interruptionCount: Int = 0) throws {
        guard runtimeErrorCount >= 0, interruptionCount >= 0,
              callbackCount.map({ $0 >= 0 }) ?? true,
              selectedInputFourCC.map({ !$0.isEmpty }) ?? true,
              inputPortFourCC.map({ !$0.isEmpty }) ?? true else {
            throw DirectUVCOwnershipAdmissionError.invalidEvidence
        }
        self.selectedInputFourCC = selectedInputFourCC
        self.inputPortFourCC = inputPortFourCC
        self.callbackCount = callbackCount
        self.expectedZeroCallbacks = expectedZeroCallbacks
        self.runtimeErrorCount = runtimeErrorCount
        self.interruptionCount = interruptionCount
    }

    private enum CodingKeys: String, CodingKey {
        case selectedInputFourCC, inputPortFourCC, callbackCount,
             expectedZeroCallbacks, runtimeErrorCount, interruptionCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            selectedInputFourCC: values.decodeIfPresent(
                String.self, forKey: .selectedInputFourCC),
            inputPortFourCC: values.decodeIfPresent(
                String.self, forKey: .inputPortFourCC),
            callbackCount: values.decodeIfPresent(
                Int.self, forKey: .callbackCount),
            expectedZeroCallbacks: values.decodeIfPresent(
                Bool.self, forKey: .expectedZeroCallbacks) ?? false,
            runtimeErrorCount: values.decodeIfPresent(
                Int.self, forKey: .runtimeErrorCount) ?? 0,
            interruptionCount: values.decodeIfPresent(
                Int.self, forKey: .interruptionCount) ?? 0)
    }

    public var status: DirectUVCHostOutputStatus {
        guard let callbackCount else { return .notObserved }
        if callbackCount == 0 {
            return expectedZeroCallbacks
                ? .expectedZeroCallbacks : .unexpectedZeroCallbacks
        }
        return .callbacksObserved
    }
}

/// Facts supplied by the existing public-API-only diagnostic boundary.  All
/// forbidden-operation bits are explicit so an evaluator can distinguish a
/// clean system-owner block from an unsafe probe attempt.
public struct DirectUVCOwnershipAdmissionEvidence: Codable, Sendable,
    Equatable {
    public let avFoundationStop: AVFoundationStopEvidence
    public let normalOpenAttempted: Bool
    public let openObservation: DirectUVCOpenObservation?
    public let directRelease: DirectCaptureReleaseEvidence?
    public let hostOutput: DirectUVCHostOutputObservation?
    public let seizeAttempted: Bool
    public let alternateSettingChanged: Bool
    public let probeOrCommitSubmitted: Bool
    public let bulkPipeReadAttempted: Bool

    public init(
        avFoundationStop: AVFoundationStopEvidence,
        normalOpenAttempted: Bool,
        openObservation: DirectUVCOpenObservation? = nil,
        directRelease: DirectCaptureReleaseEvidence? = nil,
        hostOutput: DirectUVCHostOutputObservation? = nil,
        seizeAttempted: Bool = false,
        alternateSettingChanged: Bool = false,
        probeOrCommitSubmitted: Bool = false,
        bulkPipeReadAttempted: Bool = false
    ) {
        self.avFoundationStop = avFoundationStop
        self.normalOpenAttempted = normalOpenAttempted
        self.openObservation = openObservation
        self.directRelease = directRelease
        self.hostOutput = hostOutput
        self.seizeAttempted = seizeAttempted
        self.alternateSettingChanged = alternateSettingChanged
        self.probeOrCommitSubmitted = probeOrCommitSubmitted
        self.bulkPipeReadAttempted = bulkPipeReadAttempted
    }
}

public struct DirectUVCOwnershipAdmissionEvaluation: Codable, Sendable,
    Equatable {
    public let version: Int
    public let profile: String
    public let state: DirectUVCOwnershipAdmissionState
    public let checks: [String: Bool]
    public let failureCode: String?
    public let hostOutputStatus: DirectUVCHostOutputStatus
    public let candidateFormatEvidence: DirectUVCFrameBasedFormatEvidence
    public let provenance: [String]
    public let directStreamReady: Bool
    public let conditions: [DirectUVCOwnershipAdmissionCondition]

    init(request: DirectUVCOwnershipAdmissionRequest,
         state: DirectUVCOwnershipAdmissionState,
         checks: [String: Bool], failureCode: String?,
         hostOutputStatus: DirectUVCHostOutputStatus,
         conditions: [DirectUVCOwnershipAdmissionCondition]) {
        version = request.version
        profile = request.profile
        self.state = state
        self.checks = checks
        self.failureCode = failureCode
        self.hostOutputStatus = hostOutputStatus
        candidateFormatEvidence =
            DirectUVCOwnershipAdmissionRequest.reviewedFormatEvidence
        provenance = DirectUVCOwnershipAdmissionRequest.reviewedSources
        directStreamReady = false
        self.conditions = conditions
    }
}

/// Pure admission/evidence reducer.  It does not open an interface or send a
/// UVC request.  A successful result only means that a future bounded
/// negotiation may be reviewed; `directStreamReady` remains false until a
/// separate transport slice supplies real, owned bulk bytes.
public enum DirectUVCOwnershipAdmission {
    public static func evaluate(
        request: DirectUVCOwnershipAdmissionRequest,
        evidence: DirectUVCOwnershipAdmissionEvidence
    ) -> DirectUVCOwnershipAdmissionEvaluation {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) { checks[name] = value }

        let stopComplete = evidence.avFoundationStop.isComplete
        let open = evidence.openObservation
        let endpointMatches = open.map {
            $0.interfaceNumber == request.interfaceNumber &&
                $0.alternateSetting == request.alternateSetting &&
                $0.endpointAddress == request.endpointAddress &&
                $0.endpoints.contains {
                    $0.address == request.endpointAddress &&
                        $0.isIN && $0.isBulk
                }
        } ?? false
        let exactIdentity: Bool = {
            guard let open else { return true }
            if let expected = request.expectedRegistryID,
               open.registryID != expected { return false }
            if let expected = request.expectedBootSessionID,
               open.bootSessionID != expected { return false }
            return open.location == nil || open.location == request.location
        }()
        check("avfoundation_stopped_and_drained", stopComplete)
        check("normal_open_attempted", evidence.normalOpenAttempted)
        check("normal_open_owned", open?.opened == true &&
            open?.ownedOpen == true && open?.status == .opened)
        check("descriptor_endpoint_match", endpointMatches)
        check("exact_attachment_identity", exactIdentity)
        check("no_unsafe_operations", !evidence.seizeAttempted &&
            !evidence.alternateSettingChanged &&
            !evidence.probeOrCommitSubmitted &&
            !evidence.bulkPipeReadAttempted)
        check("bulk_read_ready", false)

        let hostStatus = evidence.hostOutput?.status ?? .notObserved
        let unsafe = evidence.seizeAttempted ||
            evidence.alternateSettingChanged ||
            evidence.probeOrCommitSubmitted || evidence.bulkPipeReadAttempted
        let state: DirectUVCOwnershipAdmissionState
        let failure: String?
        let conditions: [DirectUVCOwnershipAdmissionCondition]
        if unsafe {
            state = .blockedByUnsafeOperation
            failure = "direct_uvc_unsafe_operation_observed"
            conditions = [.preserveNoSeize, .preserveNoAlternateSettingChange,
                          .preserveNoProbeOrCommit, .preserveNoPipeRead]
        } else if !stopComplete {
            state = .blockedByAVFoundationOwner
            failure = "direct_uvc_avfoundation_owner_not_released"
            conditions = [.stopAndDrainAVFoundation]
        } else if !evidence.normalOpenAttempted || open == nil {
            state = .blockedByInvalidEvidence
            failure = "direct_uvc_normal_open_evidence_missing"
            conditions = [.normalOpenAfterOwnerRelease,
                          .descriptorEndpointMatch]
        } else if open?.status == .busy {
            state = .blockedBySystemOwner
            failure = "direct_uvc_blocked_by_system_owner"
            conditions = [.normalOpenAfterOwnerRelease,
                          .preserveNoSeize]
        } else if open?.opened != true || open?.ownedOpen != true ||
                    open?.status != .opened || !endpointMatches ||
                    !exactIdentity {
            state = .blockedByInvalidEvidence
            failure = open?.status == .detached
                ? "direct_uvc_attachment_changed"
                : "direct_uvc_open_evidence_mismatch"
            conditions = [.descriptorEndpointMatch,
                          .preserveNoSeize,
                          .preserveNoAlternateSettingChange]
        } else {
            state = .readyForNegotiation
            failure = nil
            conditions = [.boundedNegotiationReview,
                          .preserveNoSeize,
                          .preserveNoAlternateSettingChange,
                          .preserveNoProbeOrCommit,
                          .preserveNoPipeRead,
                          .releaseDirectResourcesBeforeAVFoundationRestart]
        }
        return DirectUVCOwnershipAdmissionEvaluation(
            request: request, state: state, checks: checks,
            failureCode: failure, hostOutputStatus: hostStatus,
            conditions: conditions)
    }
}

public typealias Pocket3DirectUVCOwnershipAdmissionRequest =
    DirectUVCOwnershipAdmissionRequest
public typealias Pocket3DirectUVCOwnershipAdmissionEvidence =
    DirectUVCOwnershipAdmissionEvidence
public typealias Pocket3DirectUVCOwnershipAdmissionEvaluation =
    DirectUVCOwnershipAdmissionEvaluation
