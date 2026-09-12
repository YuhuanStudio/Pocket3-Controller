import Foundation
import Pocket3Core
import YunDesign

/// Small, pure presentation helpers for the shared capability graph. Keeping
/// the mapping here lets the footer and Diagnostics use identical wording
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
            let resolution = current.format.resolution.map(resolutionName) ?? loc("Unknown")
            let fps = current.format.frameRate.map(frameRateName) ?? loc("Unknown")
            return "\(resolution) · \(fps) fps · \(access(current.availability))"
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

    private static func resolutionName(_ value: CameraVideoResolution) -> String {
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

    private static func frameRateName(_ value: CameraFrameRate) -> String {
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
