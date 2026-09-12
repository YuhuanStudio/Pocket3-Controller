import SwiftUI
import Pocket3Core
import YunDesign

/// Full, read-only body capability inventory for Settings > Camera. The
/// native command path remains developer-gated; this view never offers a
/// candidate writer to a normal user.
struct BodyCapabilitySection: View {
    @Bindable var model: AppModel

    var body: some View {
        YunCard { BodyCapabilityDetails(model: model, showsHeader: true) }
            .accessibilityIdentifier("Pocket3BodyCapabilitySection")
            .measuredForLayout("bodyCapabilitySection")
    }
}

/// Compact Diagnostics entry. Legal formats stay behind YunDisclosure so the
/// regular Diagnostics page does not repeat the full Camera settings card.
struct BodyCapabilitySummary: View {
    @Bindable var model: AppModel
    @State private var formatsExpanded = false

    var body: some View {
        let graph = model.status?.capabilities ?? Pocket3CapabilityGraph()
        YunDisclosure(loc("Camera body capabilities"),
                      subtitle: summary(graph),
                      isExpanded: $formatsExpanded) {
            BodyCapabilityDetails(model: model, showsHeader: false)
        }
        .accessibilityIdentifier("Pocket3BodyCapabilitySummary")
        .measuredForLayout("bodyCapabilitySummary")
    }

    private func summary(_ graph: Pocket3CapabilityGraph) -> String {
        if let current = graph.bodyRecordingFormats.first(where: {
            $0.availability.read && $0.format.frameRate != nil && $0.format.compression != nil
        }) {
            return CapabilityPresentation.bodyFormat(current)
        }
        return CapabilityPresentation.bodyRecording(graph)
    }
}

private struct BodyCapabilityDetails: View {
    @Bindable var model: AppModel
    let showsHeader: Bool

    var body: some View {
        let graph = model.status?.capabilities ?? Pocket3CapabilityGraph()
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            if showsHeader {
                Text(loc("Camera body capabilities")).font(Yun.Text.title)
                Text(loc("Body recording is separate from USB Webcam capture."))
                    .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(loc("Current body recording")).font(Yun.Text.label)
            bodyLifecycle(graph: graph)

            YunDivider()
            Text(loc("Legal body formats")).font(Yun.Text.label)
            Text(loc("Known camera resolutions are listed even when this session has not read back a legal FPS or codec pair."))
                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                ForEach(BodyFormatFamily.allCases) { family in
                    formatRow(family, graph: graph)
                }
            }

            YunDivider()
            Text(loc("Native session readiness")).font(Yun.Text.label)
            capabilityRow(loc("Native command"), CapabilityPresentation.nativeSession(graph),
                          availability: graph.nativeSession.availability,
                          evidence: graph.nativeSession.evidence)
            capabilityRow(loc("Live view"), CapabilityPresentation.liveSession(graph),
                          availability: graph.liveSession.availability,
                          evidence: graph.liveSession.evidence)
            Text(loc("Read/write/verified and evidence level are reported for each capability. Candidate writers stay unavailable until the session and readback gates pass."))
                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum BodyFormatFamily: String, CaseIterable, Identifiable {
        case landscape = "16:9"
        case square = "1:1"
        case portrait = "9:16"

        var id: String { rawValue }
        var title: String { rawValue }
        var resolutions: [CameraVideoResolution] {
            switch self {
            case .landscape: [.p1080, .p2_7K, .p4K]
            case .square: [.square1080, .square2160, .square3K]
            case .portrait: [.portrait1080, .portrait2_7K, .portrait3K]
            }
        }
    }

    @ViewBuilder private func bodyLifecycle(graph: Pocket3CapabilityGraph) -> some View {
        if let observation = currentBodyStatus {
            capabilityRow(loc("Recording state"), BluetoothCameraStatusPresentation.recordState(observation),
                          availability: .init(read: true), evidence: .localReadOnly)
            capabilityRow(loc("Shooting mode"), BluetoothCameraStatusPresentation.mode(observation),
                          availability: .init(read: true), evidence: .localReadOnly)
            if let currentBodyFormat {
                capabilityRow(loc("Current format"), CapabilityPresentation.bodyFormat(currentBodyFormat),
                              availability: currentBodyFormat.availability, evidence: currentBodyFormat.evidence)
            } else {
                capabilityRow(loc("Current format"), loc("Unavailable"),
                              availability: .unavailable(reason: "No current body readback"), evidence: .officialSpecification)
            }
            if observation.videoLike == true || observation.recording {
                capabilityRow(loc("Remaining recording time"), BluetoothCameraStatusPresentation.duration(observation.remainingRecordSeconds),
                              availability: .init(read: true), evidence: .localReadOnly)
                capabilityRow(loc("Recorded time"), BluetoothCameraStatusPresentation.duration(observation.elapsedRecordSeconds),
                              availability: .init(read: true), evidence: .localReadOnly)
            }
        } else {
            capabilityRow(loc("Recording state"), loc("No current body status"),
                          availability: .unavailable(reason: "No current body readback"), evidence: .softwareFixture)
            capabilityRow(loc("Current format"), loc("Unavailable"),
                          availability: .unavailable(reason: "No current body readback"), evidence: .officialSpecification)
        }
    }

    private func formatRow(_ family: BodyFormatFamily,
                           graph: Pocket3CapabilityGraph) -> some View {
        let allEntries = graph.bodyRecordingFormats.filter {
            guard let resolution = $0.format.resolution else { return false }
            return family.resolutions.contains(resolution)
        }
        let observed = allEntries.filter { $0.availability.read && $0.format.frameRate != nil }
        let value: String
        let representative: BodyRecordingFormatCapability
        if observed.isEmpty {
            value = family.resolutions.map(CapabilityPresentation.resolutionName).joined(separator: " · ")
                + " · " + loc("Readback pending")
            representative = allEntries.first ?? BodyRecordingFormatCapability(
                format: BodyRecordingFormat(resolution: family.resolutions[0]),
                availability: .unavailable(reason: "Known camera resolution; current legal FPS/codec pair is not read back"),
                evidence: .officialSpecification)
        } else {
            var pairs: [String] = []
            for resolution in family.resolutions {
                let rates = observed.filter { $0.format.resolution == resolution }
                    .compactMap { $0.format.frameRate.map(CapabilityPresentation.frameRateName) }
                let uniqueRates = Array(Set(rates)).sorted { Int($0) ?? 0 < Int($1) ?? 0 }
                let label = CapabilityPresentation.resolutionName(resolution)
                pairs.append(uniqueRates.isEmpty ? "\(label): \(loc("Readback pending"))" : "\(label): \(uniqueRates.joined(separator: "/")) fps")
            }
            value = pairs.joined(separator: " · ")
            representative = observed[0]
        }
        return capabilityRow(family.title, value,
                             availability: representative.availability,
                             evidence: representative.evidence)
    }

    private func capabilityRow(_ label: String, _ value: String,
                               availability: CapabilityAvailability,
                               evidence: CapabilityEvidenceLevel) -> some View {
        HStack(alignment: .top, spacing: Yun.Space.sm) {
            Text(label).foregroundStyle(Yun.Palette.textSecondary)
            Spacer(minLength: Yun.Space.sm)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).foregroundStyle(Yun.Palette.textPrimary)
                    .multilineTextAlignment(.trailing)
                Text(CapabilityPresentation.detail(availability, evidence: evidence))
                    .font(Yun.Text.mono).foregroundStyle(Yun.Palette.textTertiary)
                    .multilineTextAlignment(.trailing)
                if let reason = CapabilityPresentation.reason(availability.reason) {
                    Text(reason).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .font(Yun.Text.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var currentBodyStatus: Pocket3CameraStatusObservation? {
        let discovery = model.wireless.discovery
        guard let observation = discovery.cameraStatus,
              observation.sessionID == discovery.sessionID,
              observation.peripheralID == discovery.selectedPeripheralID,
              observation.isFresh(nowUptime: ProcessInfo.processInfo.systemUptime) else { return nil }
        return observation
    }

    private var currentBodyFormat: BodyRecordingFormatCapability? {
        model.status?.capabilities?.bodyRecordingFormats.first(where: {
            $0.availability.read && $0.format.frameRate != nil && $0.format.compression != nil
        })
    }
}
