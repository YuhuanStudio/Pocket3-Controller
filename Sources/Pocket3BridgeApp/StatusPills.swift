import SwiftUI
import YunDesign

/// YunAudio's footer presentation, with camera and AI readings.
/// Keep the shared capsule geometry and wrapping behaviour unchanged.
struct StatusPills: View {
    @Bindable var model: AppModel
    var body: some View {
        YunWrap(spacing: Yun.Space.sm) {
            ForEach(Self.pills(for: model)) { pill in
                YunStatusPill(pill.label, value: pill.value, tone: pill.tone, showsDot: pill.showsDot)
                    .help(pill.help ?? pill.label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Yun.Space.xl)
        .padding(.bottom, Yun.Space.md)
    }
    struct Pill: Identifiable {
        let id: String
        let label: String
        var value: String?
        var tone: YunStatusTone = .neutral
        var showsDot = false
        var help: String?
    }
    static func pills(for model: AppModel) -> [Pill] {
        let fresh = model.ready && (model.status?.capture.age ?? 10) < 1
        var pills = [Pill(id: "camera", label: model.phaseTitle, tone: model.status?.phase == "stalled" ? .warning : fresh ? .success : .neutral, showsDot: true)]
        if let frame = model.status?.capture.frame {
            pills.append(Pill(id: "format", label: "\(frame.width)×\(frame.height)", value: String(format: "%.1f fps", model.status?.capture.recentFPS ?? 0), help: loc("Measured from received camera frames.")))
            if !fresh && model.ready { pills.append(Pill(id: "stale", label: loc("Stale frame"), tone: .warning, showsDot: true)) }
        }
        pills.append(Pill(id: "access", label: loc(model.access.title)))
        if model.access == .control && model.status?.stopValidated != true { pills.append(Pill(id: "validation", label: loc("Movement not validated"), tone: .warning, showsDot: true)) }
        if let diagnosis = model.powerChargingDiagnosis,
           diagnosis.usbPresent || diagnosis.batteryPercent != nil {
            pills.append(Pill(id: "power", label: PowerChargingPresentation.title(diagnosis),
                              value: PowerChargingPresentation.value(diagnosis),
                              tone: PowerChargingPresentation.tone(diagnosis),
                              showsDot: diagnosis.needsAttention,
                              help: PowerChargingPresentation.reason(diagnosis)))
        } else if let power = model.status?.power, power.present {
            pills.append(Pill(id: "power", label: loc(power.isPowerAllocationFailed == true ? "USB power issue" : "Charging unknown"), tone: power.isPowerAllocationFailed == true ? .warning : .neutral, help: loc("USB power is detected separately from battery charging. See Diagnostics for details.")))
        }
        if let battery = model.wireless.freshBatteryAssessment,
           let warning = BluetoothBatteryPresentation.warningTitle(battery) {
            pills.append(Pill(id: "bluetoothBattery", label: warning, value: "\(battery.percent)%", tone: .warning,
                showsDot: true, help: BluetoothBatteryPresentation.sourceDetail))
        }
        if model.aiWorking { pills.append(Pill(id: "ai", label: loc("AI observing"), tone: .info, showsDot: true)) }
        pills.append(Pill(id: "mcp", label: loc(model.bridgeRunning ? "MCP ready" : "MCP unavailable"), tone: model.bridgeRunning ? .neutral : .warning, help: loc("The local service is ready for MCP clients. This does not mean a client is connected.")))
        if model.status?.lastError != nil { pills.append(Pill(id: "error", label: loc("Needs attention"), tone: .warning, showsDot: true)) }
        return pills
    }
}

struct CompactCameraStatus: View {
    @Bindable var model: AppModel
    var body: some View {
        YunWrap(spacing: Yun.Space.sm) {
            ForEach(StatusPills.pills(for: model).filter { $0.id != "format" }) { pill in
                YunStatusPill(pill.label, value: pill.value, tone: pill.tone, showsDot: pill.showsDot)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
