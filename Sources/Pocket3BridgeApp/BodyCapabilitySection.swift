import SwiftUI
import Pocket3Core
import YunDesign

/// Read-only body capability inventory used in Camera settings and
/// Diagnostics. It never presents a setter: the native command path remains
/// developer-gated until matching readback and hardware evidence exist.
struct BodyCapabilitySection: View {
    @Bindable var model: AppModel

    var body: some View {
        let graph = model.status?.capabilities ?? Pocket3CapabilityGraph()
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                Text(loc("Camera body capabilities")).font(Yun.Text.title)
                Text(loc("Body recording is separate from USB Webcam capture."))
                    .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(loc("Current body recording")).font(Yun.Text.label)
                bodyLifecycle(graph: graph)

                YunDivider()
                Text(loc("Legal body formats")).font(Yun.Text.label)
                Text(loc("Known camera resolutions are listed even when this session has not read back a legal FPS or codec pair."))
                    .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    ForEach(CameraVideoResolution.allCases, id: \.rawValue) { resolution in
                        formatRow(resolution, graph: graph)
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
        .accessibilityIdentifier("Pocket3BodyCapabilitySection")
        .measuredForLayout("bodyCapabilitySection")
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
            capabilityRow(loc("Current format"), CapabilityPresentation.bodyRecording(graph),
                          availability: currentBodyFormat?.availability ?? .unavailable(reason: "No current body readback"),
                          evidence: currentBodyFormat?.evidence ?? .officialSpecification)
        }
    }

    private func formatRow(_ resolution: CameraVideoResolution,
                           graph: Pocket3CapabilityGraph) -> some View {
        let entries = graph.bodyRecordingFormats.filter { $0.format.resolution == resolution }
        let observed = entries.filter { $0.availability.read && $0.format.frameRate != nil }
        let name = CapabilityPresentation.resolutionName(resolution)
        let value: String
        let capability: BodyRecordingFormatCapability
        if observed.isEmpty {
            value = loc("Readback pending")
            capability = entries.first ?? BodyRecordingFormatCapability(
                format: BodyRecordingFormat(resolution: resolution),
                availability: .unavailable(reason: "Known camera resolution; current legal FPS/codec pair is not read back"),
                evidence: .officialSpecification)
        } else {
            let rates = observed.compactMap { $0.format.frameRate.map(CapabilityPresentation.frameRateName) }
            value = "\(rates.joined(separator: ", ")) fps"
            capability = observed[0]
        }
        return capabilityRow(name, value.isEmpty ? loc("Unknown") : value,
                            availability: capability.availability, evidence: capability.evidence)
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
        let wireless = model.wireless
        let discovery = wireless.discovery
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
