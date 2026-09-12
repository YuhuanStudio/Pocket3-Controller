import SwiftUI
import Pocket3Core
import YunDesign

/// Full, read-only body capability inventory for Settings > Camera. The
/// native command path remains developer-gated; this view never offers a
/// candidate writer to a normal user.
struct BodyCapabilitySection: View {
    @Bindable var model: AppModel
    let developerMode: Bool
    let developerValidationExpanded: Bool
    let advancedSettingsExpanded: Bool
    let exposureExpanded: Bool

    init(model: AppModel,
         developerMode: Bool = CommandLine.arguments.contains("--hardware-validation"),
         developerValidationExpanded: Bool = false,
         advancedSettingsExpanded: Bool = false,
         exposureExpanded: Bool = false) {
        self.model = model
        self.developerMode = developerMode
        self.developerValidationExpanded = developerValidationExpanded
        self.advancedSettingsExpanded = advancedSettingsExpanded
        self.exposureExpanded = exposureExpanded
    }

    var body: some View {
        YunCard {
            BodyCapabilityDetails(model: model, showsHeader: true,
                                  showsDeveloperValidation: developerMode,
                                  developerValidationExpanded: developerValidationExpanded,
                                  advancedSettingsExpanded: advancedSettingsExpanded,
                                  exposureExpanded: exposureExpanded)
        }
            .accessibilityIdentifier("Pocket3BodyCapabilitySection")
            .measuredForLayout("bodyCapabilitySection")
    }
}

/// Compact Diagnostics entry. Legal formats stay behind YunDisclosure so the
/// regular Diagnostics page does not repeat the full Camera settings card.
struct BodyCapabilitySummary: View {
    @Bindable var model: AppModel
    let developerMode: Bool
    let developerValidationExpanded: Bool
    let advancedSettingsExpanded: Bool
    @State private var formatsExpanded = false

    init(model: AppModel,
         developerMode: Bool = CommandLine.arguments.contains("--hardware-validation"),
         developerValidationExpanded: Bool = false,
         advancedSettingsExpanded: Bool = false,
         initiallyExpanded: Bool = false) {
        self.model = model
        self.developerMode = developerMode
        self.developerValidationExpanded = developerValidationExpanded
        self.advancedSettingsExpanded = advancedSettingsExpanded
        _formatsExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let graph = model.status?.capabilities ?? Pocket3CapabilityGraph()
        YunDisclosure(loc("Camera body capabilities"),
                      subtitle: summary(graph),
                      isExpanded: $formatsExpanded) {
            BodyCapabilityDetails(model: model, showsHeader: false,
                                  showsDeveloperValidation: developerMode,
                                  developerValidationExpanded: developerValidationExpanded,
                                  advancedSettingsExpanded: advancedSettingsExpanded)
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
    let showsDeveloperValidation: Bool
    @State private var activeTrackExpanded = false
    @State private var exposureExpanded: Bool
    @State private var advancedSettingsExpanded: Bool
    @State private var validationExpanded: Bool

    init(model: AppModel, showsHeader: Bool, showsDeveloperValidation: Bool,
         developerValidationExpanded: Bool = false,
         advancedSettingsExpanded: Bool = false,
         exposureExpanded: Bool = false) {
        self.model = model
        self.showsHeader = showsHeader
        self.showsDeveloperValidation = showsDeveloperValidation
        _exposureExpanded = State(initialValue: exposureExpanded)
        _advancedSettingsExpanded = State(initialValue: advancedSettingsExpanded)
        _validationExpanded = State(initialValue: developerValidationExpanded)
    }

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

            YunDisclosure(loc("ActiveTrack (read-only)"),
                          subtitle: CapabilityPresentation.activeTrackState(currentActiveTrack),
                          isExpanded: $activeTrackExpanded) {
                capabilityRow(loc("ActiveTrack state"),
                              CapabilityPresentation.activeTrackState(currentActiveTrack),
                              availability: CapabilityPresentation.activeTrackAvailability(currentActiveTrack),
                              evidence: CapabilityPresentation.activeTrackEvidence(currentActiveTrack))
                Text(loc("ActiveTrack state is read-only; the A6 command path is not exposed."))
                    .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            YunDisclosure(loc("Exposure (read-only)"),
                          subtitle: ExposurePresentation.summary(
                              currentExposureReadback,
                              isoLimit: currentISOLimitReadback),
                          isExpanded: $exposureExpanded) {
                exposureDetails
            }
            .accessibilityIdentifier("Pocket3ExposureDisclosure")

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

            YunDisclosure(loc("Advanced body settings"),
                          subtitle: CapabilityPresentation.advancedSettingsSummary(graph),
                          isExpanded: $advancedSettingsExpanded) {
                advancedSettingsDetails(graph)
            }
            .accessibilityIdentifier("Pocket3AdvancedSettingsDisclosure")

            if showsDeveloperValidation {
                YunDisclosure(loc("Developer body validation"),
                              subtitle: validationReadiness(graph).value,
                              isExpanded: $validationExpanded) {
                    developerValidationDetails(graph)
                }
            }
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

    @ViewBuilder private func advancedSettingsDetails(
        _ graph: Pocket3CapabilityGraph
    ) -> some View {
        Text(loc("Read-only inventory from the evidence-led Pocket 3 capability catalog."))
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        advancedSettingGroup(loc("Protocol candidates"), ids: [
            .medTele, .isoLimit, .audioChannel, .vocalBoost, .selfieFlip
        ], graph: graph)
        advancedSettingGroup(loc("Official-only body features"), ids: [
            .breathingCompensation, .sharpness, .noiseReduction
        ], graph: graph)
        Text(loc("Candidate writers are not available from the regular UI."))
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func advancedSettingGroup(
        _ title: String,
        ids: [Pocket3AdvancedSettingID],
        graph: Pocket3CapabilityGraph
    ) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.xs) {
            Text(title)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            ForEach(ids, id: \.self) { id in
                if let entry = Pocket3AdvancedSettingInventory.entry(for: id) {
                    advancedSettingRow(entry, graph: graph)
                }
            }
        }
    }

    private func advancedSettingRow(
        _ entry: Pocket3AdvancedSettingInventoryEntry,
        graph: Pocket3CapabilityGraph
    ) -> some View {
        let availability = CapabilityPresentation.advancedSettingAvailability(entry,
                                                                               graph: graph)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: Yun.Space.sm) {
                Text(CapabilityPresentation.advancedSettingTitle(entry.id))
                    .foregroundStyle(Yun.Palette.textSecondary)
                Spacer(minLength: Yun.Space.sm)
                YunBadge(CapabilityPresentation.advancedSettingAccess(availability))
            }
            YunWrap(spacing: 4, lineSpacing: 2) {
                YunBadge(loc("Evidence"))
                ForEach(entry.evidence, id: \.self) { evidence in
                    YunBadge(CapabilityPresentation.advancedSettingEvidence(evidence))
                }
            }
            if let reason = CapabilityPresentation.reason(availability.reason) {
                Text(reason)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Yun.Text.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @ViewBuilder private var exposureDetails: some View {
        let readback = currentExposureReadback
        let isoLimit = currentISOLimitReadback
        let validation = currentExposureValidationResult
        capabilityRow(loc("Shooting mode"), ExposurePresentation.mode(readback),
                      availability: ExposurePresentation.availability(
                          hasReadback: readback != nil),
                      evidence: ExposurePresentation.evidence(
                          hasReadback: readback != nil, validation: validation))
        capabilityRow("EV", ExposurePresentation.ev(readback),
                      availability: ExposurePresentation.availability(
                          hasReadback: readback != nil),
                      evidence: ExposurePresentation.evidence(
                          hasReadback: readback != nil, validation: validation))
        capabilityRow(loc("Selected ISO"),
                      ExposurePresentation.selectedISO(readback),
                      availability: ExposurePresentation.availability(
                          hasReadback: readback != nil),
                      evidence: ExposurePresentation.evidence(
                          hasReadback: readback != nil, validation: validation))
        capabilityRow(loc("Effective ISO"),
                      ExposurePresentation.effectiveISO(readback),
                      availability: ExposurePresentation.availability(
                          hasReadback: readback != nil),
                      evidence: ExposurePresentation.evidence(
                          hasReadback: readback != nil, validation: validation))
        capabilityRow(loc("Shutter"), ExposurePresentation.shutter(readback),
                      availability: ExposurePresentation.availability(
                          hasReadback: readback != nil),
                      evidence: ExposurePresentation.evidence(
                          hasReadback: readback != nil, validation: validation))
        capabilityRow(loc("ISO limit"), ExposurePresentation.isoLimitValue(isoLimit),
                      availability: ExposurePresentation.isoLimitAvailability(isoLimit),
                      evidence: isoLimit == nil ? .publicReverseEngineering :
                          ExposurePresentation.evidence(hasReadback: true,
                                                        validation: validation))

        if showsDeveloperValidation {
            Text(loc("Developer exposure validation")).font(Yun.Text.label)
            capabilityRow(loc("Validation result"),
                          ExposurePresentation.validationSummary(validation),
                          availability: .readOnly,
                          evidence: .localReadOnly)
            if let validation {
                YunWrap(spacing: 4, lineSpacing: 4) {
                    ForEach(Array(ExposurePresentation.validationStages(validation).enumerated()),
                            id: \.offset) { _, stage in
                        YunBadge(stageLabel(stage.label, result: stage.value))
                    }
                }
                Text(ExposurePresentation.validationReason(validation,
                    currentSession: true))
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Text(loc("Unknown exposure selectors remain visible as raw values; this UI never submits exposure commands."))
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
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
                HStack(spacing: 4) {
                    YunBadge(CapabilityPresentation.access(availability))
                    YunBadge("\(loc("Evidence")) \(CapabilityPresentation.evidence(evidence))")
                }
                if let reason = CapabilityPresentation.reason(availability.reason) {
                    Text(reason).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .font(Yun.Text.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func developerValidationDetails(_ graph: Pocket3CapabilityGraph) -> some View {
        let readiness = validationReadiness(graph)
        capabilityRow(loc("Readiness"), readiness.value,
                      availability: readiness.availability,
                      evidence: readiness.evidence)
        if let result = model.developerBodyValidationResult {
            Text(loc("Last validation result")).font(Yun.Text.label)
            validationStages(result)
            Text(CapabilityPresentation.bodyValidationReason(result,
                currentSession: resultBelongsToCurrentSession(result)))
                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            capabilityRow(loc("Last validation result"), loc("No developer validation result"),
                          availability: .unavailable(reason: readiness.availability.reason),
                          evidence: readiness.evidence)
        }
        Text(loc("The UI is read-only; candidate writers stay hidden from normal users."))
            .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func validationStages(_ result: NativeBodyValidationResult) -> some View {
        YunWrap(spacing: 4, lineSpacing: 4) {
            YunBadge(stageLabel("Requested", result: CapabilityPresentation.bodyValidationRequested(result)))
            YunBadge(stageLabel("Submitted", result: result.submitted))
            YunBadge(stageLabel("Acknowledged", result: result.acknowledged))
            YunBadge(stageLabel("Observed", result: result.observed))
            YunBadge(stageLabel("Completed", result: result.completed))
        }
    }

    private func stageLabel(_ key: String, result: Bool) -> String {
        "\(loc(key)) \(result ? "✓" : "—")"
    }

    private func validationReadiness(_ graph: Pocket3CapabilityGraph)
        -> (value: String, availability: CapabilityAvailability, evidence: CapabilityEvidenceLevel) {
        CapabilityPresentation.bodyValidationReadiness(
            graph: graph,
            bodyStatusAvailable: currentBodyStatus != nil,
            bodyFormatAvailable: currentBodyFormat != nil,
            busy: model.wireless.nativeBodyValidationBusy)
    }

    private func resultBelongsToCurrentSession(_ result: NativeBodyValidationResult) -> Bool {
        guard let sessionID = result.request.sessionID,
              let currentSessionID = model.wireless.nativeSessionStatus.sessionID else { return false }
        return sessionID == currentSessionID &&
            result.request.generation == model.wireless.nativeSessionStatus.generation
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

    private var currentActiveTrack: Pocket3ActiveTrackObservation? {
        model.wireless.discovery.activeTrackObservation(
            nowUptime: ProcessInfo.processInfo.systemUptime)
    }

    private var currentExposureReadback: Pocket3ExposureReadback? {
        if let validation = currentExposureValidationResult?.exposureReadback,
           validation.isFresh(session: model.wireless.nativeSessionStatus,
                              nowUptime: ProcessInfo.processInfo.systemUptime) {
            return validation.readback
        }
        let discovery = model.wireless.discovery
        guard discovery.pairing?.peerReportedPaired == true,
              discovery.selectedPeripheralID != nil else { return nil }
        let binding = ContinuousGimbalBinding(
            sessionID: "ble:\(discovery.sessionID.uuidString)", generation: 0)
        return discovery.cameraSettingsObservations.reversed().first(where: {
            $0.property == .exposure && $0.binding == binding &&
                $0.isFresh(now: ProcessInfo.processInfo.systemUptime,
                           maximumAge: Pocket3ExposureObservation.maximumAge)
        }).flatMap { observation in
            guard observation.binding == binding,
                  case .exposure(let value) = observation.readOnlyValue else {
                return nil
            }
            return Pocket3ExposureReadback.decode(value.raw)
        }
    }

    private var currentExposureValidationResult: NativeExposureValidationResult? {
        guard let result = model.developerExposureValidationResult,
              let request = result.request,
              request.sessionID == model.wireless.nativeSessionStatus.sessionID,
              request.generation == model.wireless.nativeSessionStatus.generation else {
            return nil
        }
        return result
    }

    private var currentISOLimitReadback: Pocket3AdvancedSettingObservation? {
        guard let observation = currentExposureValidationResult?.isoLimitReadback,
              observation.isFresh(session: model.wireless.nativeSessionStatus,
                                  nowUptime: ProcessInfo.processInfo.systemUptime) else {
            return nil
        }
        return observation
    }
}
