import Foundation
import Pocket3Core
import YunDesign

/// Small, pure presentation helpers for the shared capability graph. Keeping
/// the mapping here lets settings and Diagnostics use identical wording
/// without exposing protocol payloads or creating a transport.
enum CapabilityPresentation {
    static func access(_ availability: CapabilityAvailability) -> String {
        if availability.verified { return loc("Verified") }
        if availability.write { return loc("Writable") }
        if availability.read { return loc("Read-only") }
        return loc("Unavailable")
    }

    static func evidence(_ level: CapabilityEvidenceLevel) -> String {
        level.rawValue
    }

    static func reason(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        switch value {
        case "Candidate command has no typed body-state readback or persistence proof":
            return loc("Candidate command has no typed body-state readback or persistence proof")
        case "Official body feature only; no Pocket 3 command or readback schema":
            return loc("Official body feature only; no Pocket 3 command or readback schema")
        case "Official feature record only; inspected body settings had no typed schema":
            return loc("Official feature record only; inspected body settings had no typed schema")
        case "Do not confuse host UVC processing-unit sharpness with body setting":
            return loc("Do not confuse host UVC processing-unit sharpness with body setting")
        case "Keyed candidate requires a fresh same-session readback; write is not locally verified":
            return loc("Keyed candidate requires a fresh same-session readback; write is not locally verified")
        case "Keyed candidate requires a fresh same-session readback; raw selector 0x03 remains unknown":
            return loc("Keyed candidate requires a fresh same-session readback; raw selector 0x03 remains unknown")
        case "Keyed candidate requires a fresh same-session readback; local hardware result is absent":
            return loc("Keyed candidate requires a fresh same-session readback; local hardware result is absent")
        case "Body PID 0038 is GET-only in the reviewed catalog; FE09 is a toggle without setting readback":
            return loc("Body PID 0038 is GET-only in the reviewed catalog; FE09 is a toggle without setting readback")
        case "Native command session is not ready":
            return loc("Native command session is not ready")
        case "No current body readback":
            return loc("No current body readback")
        case "No current ActiveTrack readback":
            return loc("No current ActiveTrack readback")
        case "No current exposure readback":
            return loc("No current exposure readback")
        case "No current ISO limit readback":
            return loc("No current ISO limit readback")
        case "ISO limit raw selector is unknown":
            return loc("ISO limit raw selector is unknown")
        case "No firmware component readback is exposed by current BLE/USB observations":
            return loc("No firmware component readback is exposed by current BLE/USB observations")
        case "No current screen orientation readback":
            return loc("No current screen orientation readback")
        case "No Auto Power Off readback schema":
            return loc("No Auto Power Off readback schema")
        case "No Wearable readback schema":
            return loc("No Wearable readback schema")
        case "No Rotate & Capture readback schema":
            return loc("No Rotate & Capture readback schema")
        case "No current Selfie Flip readback":
            return loc("No current Selfie Flip readback")
        case "Screen orientation raw selector is unknown":
            return loc("Screen orientation raw selector is unknown")
        case "SD storage capacity fields are inconsistent":
            return loc("SD storage capacity fields are inconsistent")
        case "No current SD storage readback":
            return loc("No current SD storage readback")
        case "No independent accessory identity readback is exposed by current BLE/USB observations":
            return loc("No independent accessory identity readback is exposed by current BLE/USB observations")
        case "ActiveTrack state is read-only; the A6 command path is not exposed.":
            return loc("ActiveTrack state is read-only; the A6 command path is not exposed.")
        case "Body validation is already in progress":
            return loc("Body validation is already in progress")
        case "Current body status readback is required":
            return loc("Current body status readback is required")
        case "Current body format readback is required for format validation":
            return loc("Current body format readback is required for format validation")
        case "Readback gates are ready; execution remains developer-only":
            return loc("Readback gates are ready; execution remains developer-only")
        case "Known camera resolution; current legal FPS/codec pair is not read back":
            return loc("Known camera resolution; current legal FPS/codec pair is not read back")
        case "Unknown body-format flags":
            return loc("Unknown body-format flags")
        case "No native camera session":
            return loc("No native camera session")
        case "BLE pairing is available; command session is not ready":
            return loc("BLE pairing is available; command session is not ready")
        case "Native datalink has not completed its handshake":
            return loc("Native datalink has not completed its handshake")
        case "Datalink handshake is in progress":
            return loc("Datalink handshake is in progress")
        case "No camera setting write has been verified":
            return loc("No camera setting write has been verified")
        case "Camera Wi-Fi live view is disabled; USB capture remains independent":
            return loc("Camera Wi-Fi live view is disabled; USB capture remains independent")
        case "Native session is not bound to the current camera":
            return loc("Native session is not bound to the current camera")
        case "Native session reported an error":
            return loc("Native session reported an error")
        case "Native telemetry is stale":
            return loc("Native telemetry is stale")
        default:
            return value
        }
    }

    static func activeTrackState(_ observation: Pocket3ActiveTrackObservation?) -> String {
        guard let observation else { return loc("No current ActiveTrack readback") }
        switch observation.state {
        case .idle:
            return loc("Idle")
        case .locked(let box):
            return box == nil ? loc("Locked; no box readback") : loc("Locked; box readback")
        case .subjectBox:
            return loc("Subject box observed")
        case .unknown:
            return loc("Unknown")
        }
    }

    static func activeTrackAvailability(_ observation: Pocket3ActiveTrackObservation?) -> CapabilityAvailability {
        observation == nil
            ? .unavailable(reason: "No current ActiveTrack readback")
            : .readOnly
    }

    static func activeTrackEvidence(_ observation: Pocket3ActiveTrackObservation?) -> CapabilityEvidenceLevel {
        observation == nil ? .publicReverseEngineering : .localReadOnly
    }

    static func advancedSettingsSummary(_ graph: Pocket3CapabilityGraph) -> String {
        let entries = Pocket3AdvancedSettingInventory.all
        let readable = entries.filter {
            advancedSettingAvailability($0, graph: graph).read
        }.count
        return String(format: loc("%d of %d advanced settings readable"),
                      readable, entries.count)
    }

    static func advancedSettingAvailability(
        _ entry: Pocket3AdvancedSettingInventoryEntry,
        graph: Pocket3CapabilityGraph
    ) -> CapabilityAvailability {
        guard entry.availability.isAvailable else { return entry.availability }
        guard graph.nativeSession.commandReady else {
            return .unavailable(reason: "Native command session is not ready")
        }
        return entry.availability
    }

    static func advancedSettingTitle(_ id: Pocket3AdvancedSettingID) -> String {
        switch id {
        case .medTele: loc("Med-Tele")
        case .breathingCompensation: loc("Breathing compensation")
        case .sharpness: loc("Sharpness")
        case .noiseReduction: loc("Noise reduction")
        case .isoLimit: loc("ISO limit")
        case .audioChannel: loc("Audio channel")
        case .vocalBoost: loc("Vocal Boost")
        case .selfieFlip: loc("Selfie Flip")
        }
    }

    static func advancedSettingEvidence(
        _ evidence: Pocket3AdvancedSettingEvidence
    ) -> String {
        switch evidence {
        case .officialOnly: loc("Official only")
        case .publicReverseEngineering: loc("Public reverse engineering")
        case .localParser: loc("Local parser")
        }
    }

    /// Compact, language-neutral flags keep the three availability dimensions
    /// visible without implying that a writer control is present in this UI.
    static func advancedSettingAccess(_ availability: CapabilityAvailability) -> String {
        let read = availability.read ? "✓" : "—"
        let write = availability.write ? "✓" : "—"
        let verified = availability.verified ? "✓" : "—"
        return "R \(read)  W \(write)  V \(verified)"
    }

    static func bodyValidationReadiness(
        graph: Pocket3CapabilityGraph,
        bodyStatusAvailable: Bool,
        bodyFormatAvailable: Bool,
        busy: Bool
    ) -> (value: String, availability: CapabilityAvailability, evidence: CapabilityEvidenceLevel) {
        if busy {
            return (loc("In progress"),
                    .init(read: true, reason: "Body validation is already in progress"),
                    .localReadOnly)
        }
        guard graph.nativeSession.commandReady else {
            return (nativeSession(graph), graph.nativeSession.availability, graph.nativeSession.evidence)
        }
        guard bodyStatusAvailable else {
            return (loc("Not ready"),
                    .unavailable(reason: "Current body status readback is required"),
                    .localReadOnly)
        }
        guard bodyFormatAvailable else {
            return (loc("Partial"),
                    .init(read: true, reason: "Current body format readback is required for format validation"),
                    .localReadOnly)
        }
        return (loc("Ready"),
                .init(read: true, reason: "Readback gates are ready; execution remains developer-only"),
                .localReadOnly)
    }

    static func bodyValidationRequested(_ result: NativeBodyValidationResult) -> Bool {
        result.recording?.requested == true || result.format?.requested == true
    }

    static func bodyValidationSummary(_ result: NativeBodyValidationResult) -> String {
        if result.completed { return loc("Completed") }
        if result.observed { return loc("Observed") }
        if result.acknowledged { return loc("Acknowledged") }
        if result.submitted { return loc("Submitted") }
        if bodyValidationRequested(result) { return loc("Requested") }
        return loc("Not requested")
    }

    static func bodyValidationReason(_ result: NativeBodyValidationResult,
                                    currentSession: Bool = true) -> String {
        guard currentSession else { return loc("Validation result belongs to another native session") }
        if let failureCode = result.failureCode {
            return bodyValidationFailureReason(failureCode)
        }
        if result.dryRun { return loc("Dry run requested; no command was submitted") }
        if !result.submitted { return loc("Command was not submitted") }
        if !result.acknowledged { return loc("Command acknowledgement was not observed") }
        if !result.observed { return loc("Terminal body readback was not observed") }
        if !result.completed { return loc("Requested body state was not completed") }
        return loc("Completed with same-session body readback")
    }

    private static func bodyValidationFailureReason(_ code: String) -> String {
        switch code {
        case "native_body_executor_unavailable", "native_datalink_unavailable":
            return loc("Native body validation executor is unavailable")
        case "native_body_recording_baseline_missing", "native_body_recording_baseline_invalid":
            return loc("Current body status readback is required")
        case "native_body_format_baseline_missing", "native_body_format_baseline_invalid":
            return loc("Current body format readback is required for format validation")
        case "native_body_format_capability_missing", "native_body_format_unsupported":
            return loc("Requested body format is not in the current legal capability table")
        case "native_body_command_not_ready", "native_command_not_ready":
            return loc("Native command session is not ready")
        case "native_body_session_missing", "native_command_generation_changed", "native_body_connection_changed":
            return loc("The selected body validation session is unavailable")
        case "native_body_validation_busy", "native_busy":
            return loc("Body validation is already in progress")
        case "native_body_readback_stale", "native_body_readback_invalid":
            return loc("Terminal body readback was not observed")
        case "native_body_validation_timeout", "native_command_invalid_timeout":
            return loc("Body validation timed out before completion")
        case "cancelled":
            return loc("Validation was cancelled before completion")
        default:
            return String(format: loc("Validation returned gate: %@"), code)
        }
    }

    static func detail(_ availability: CapabilityAvailability,
                       evidence: CapabilityEvidenceLevel) -> String {
        "\(availability.accessSummary) · \(loc("Evidence")) \(Self.evidence(evidence))"
    }

    static func usbCapture(_ graph: Pocket3CapabilityGraph) -> String {
        guard let capture = graph.uvcCaptureFormats.first else { return loc("Unavailable") }
        let input = capture.inputPixelFormat?.rawValue.uppercased() ?? loc("Unknown")
        return "\(capture.mode.width)×\(capture.mode.height) · \(input) · \(access(capture.availability))"
    }

    static func usbCaptureDetail(_ graph: Pocket3CapabilityGraph) -> String {
        guard let capture = graph.uvcCaptureFormats.first else { return loc("Unavailable") }
        return detail(capture.availability, evidence: capture.evidence)
    }

    static func hostOutput(_ graph: Pocket3CapabilityGraph) -> String {
        let codec = graph.hostOutputCodecs.first(where: \.requested)
            ?? graph.hostOutputCodecs.first(where: { $0.availability.verified })
            ?? graph.hostOutputCodecs.first(where: { $0.availability.isAvailable })
        guard let codec else { return loc("Unavailable") }
        return "\(name(codec.codec)) · \(access(codec.availability))"
    }

    static func hostOutputDetail(_ graph: Pocket3CapabilityGraph) -> String {
        let codec = graph.hostOutputCodecs.first(where: \.requested)
            ?? graph.hostOutputCodecs.first(where: { $0.availability.verified })
            ?? graph.hostOutputCodecs.first
        guard let codec else { return loc("Unavailable") }
        return detail(codec.availability, evidence: codec.evidence)
    }

    static func bodyRecording(_ graph: Pocket3CapabilityGraph) -> String {
        if let current = graph.bodyRecordingFormats.first(where: { $0.availability.read && $0.format.frameRate != nil }) {
            return "\(bodyFormat(current)) · \(access(current.availability))"
        }
        let known = graph.bodyRecordingFormats.filter { $0.evidence == .officialSpecification }.count
        return known > 0 ? "\(known) \(loc("Known families")) · \(loc("Readback pending"))" : loc("Unavailable")
    }

    static func bodyRecordingDetail(_ graph: Pocket3CapabilityGraph) -> String {
        if let current = graph.bodyRecordingFormats.first(where: { $0.availability.read && $0.format.frameRate != nil }) {
            return detail(current.availability, evidence: current.evidence)
        }
        let known = graph.bodyRecordingFormats.filter { $0.evidence == .officialSpecification }.count
        return known > 0 ? "\(known) \(loc("Known families")) · \(loc("No current body readback"))" : loc("Unavailable")
    }

    static func bodyFormat(_ capability: BodyRecordingFormatCapability) -> String {
        let resolution = capability.format.resolution.map(resolutionName) ?? loc("Unknown")
        let fps = capability.format.frameRate.map(frameRateName) ?? loc("Unknown")
        var parts = [resolution, "\(fps) fps"]
        if let compression = capability.format.compression {
            parts.append(compression == .h264Compatibility ? "H.264" : "HEVC")
        }
        return parts.joined(separator: " · ")
    }

    static func nativeSession(_ graph: Pocket3CapabilityGraph) -> String {
        readiness(graph.nativeSession.readiness)
    }

    static func nativeSessionDetail(_ graph: Pocket3CapabilityGraph) -> String {
        detail(graph.nativeSession.availability, evidence: graph.nativeSession.evidence)
    }

    static func liveSession(_ graph: Pocket3CapabilityGraph) -> String {
        switch graph.liveSession.readiness {
        case .ready: return loc("Ready")
        case .connecting: return loc("Connecting…")
        case .interrupted: return loc("Interrupted")
        case .error: return loc("Needs attention")
        case .unavailable: return loc("Unavailable")
        }
    }

    static func liveSessionDetail(_ graph: Pocket3CapabilityGraph) -> String {
        detail(graph.liveSession.availability, evidence: graph.liveSession.evidence)
    }

    static func graphDetail(_ graph: Pocket3CapabilityGraph) -> String {
        [
            "USB \(usbCaptureDetail(graph))",
            "Host \(hostOutputDetail(graph))",
            "Body \(bodyRecordingDetail(graph))",
            "Native \(nativeSessionDetail(graph))",
            "Live \(liveSessionDetail(graph))"
        ].joined(separator: "\n")
    }

    private static func readiness(_ value: NativeSessionReadiness) -> String {
        switch value {
        case .disconnected: loc("Unavailable")
        case .blePaired: loc("Bluetooth peer paired")
        case .credentialsAvailable: loc("Credentials available")
        case .datalinkHandshaking: loc("Connecting…")
        case .commandReady: loc("Ready")
        case .liveReady: loc("Ready")
        case .error: loc("Needs attention")
        }
    }

    private static func name(_ codec: HostOutputCodec) -> String {
        switch codec {
        case .bgra: "BGRA"
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .jpeg: "JPEG"
        case .native: loc("Native")
        case .systemDefault: loc("System")
        }
    }

    static func resolutionName(_ value: CameraVideoResolution) -> String {
        switch value {
        case .p1080: "1080p"
        case .p2_7K: "2.7K"
        case .p4K: "4K"
        case .square1080: "1080p 1:1"
        case .square2160: "2160p 1:1"
        case .square3K: "3K 1:1"
        case .portrait1080: "1080p 9:16"
        case .portrait2_7K: "2.7K 9:16"
        case .portrait3K: "3K 9:16"
        }
    }

    static func frameRateName(_ value: CameraFrameRate) -> String {
        switch value {
        case .fps24: "24"
        case .fps25: "25"
        case .fps30: "30"
        case .fps48: "48"
        case .fps50: "50"
        case .fps60: "60"
        case .fps120: "120"
        case .fps240: "240"
        }
    }
}
