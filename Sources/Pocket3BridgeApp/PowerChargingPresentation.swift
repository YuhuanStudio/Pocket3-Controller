import Pocket3Core
import SwiftUI
import YunDesign

enum PowerChargingPresentation {
    static func title(_ diagnosis: Pocket3PowerChargingDiagnosis) -> String {
        switch diagnosis.state {
        case .charging: loc("Charging")
        case .fullNotCharging: loc("Full · not charging")
        case .connectedNotCharging: loc("Connected · not charging")
        case .insufficientPowerCandidate: loc("Power check needed")
        case .telemetryStale: loc("Charging telemetry stale")
        case .unknown: loc("Charging unknown")
        }
    }

    static func value(_ diagnosis: Pocket3PowerChargingDiagnosis) -> String? {
        diagnosis.batteryPercent.map { "\($0)%" }
    }

    static func tone(_ diagnosis: Pocket3PowerChargingDiagnosis) -> YunStatusTone {
        if diagnosis.needsAttention { return .warning }
        return diagnosis.state == .charging ? .success : .neutral
    }

    static func reason(_ diagnosis: Pocket3PowerChargingDiagnosis) -> String {
        switch diagnosis.reason {
        case .chargingReported:
            return loc("Camera reports charging")
        case .fullBatteryNotCharging:
            return loc("Battery is full and reports not charging")
        case .connectedNotCharging:
            return loc("USB is connected; camera reports not charging")
        case .batteryDecliningWhileNotCharging:
            return loc("Battery declined while USB was connected and camera reported not charging")
        case .powerAllocationFailedAndBatteryDeclining:
            return loc("USB allocation failed and battery declined while not charging")
        case .powerAllocationFailed:
            return loc("USB allocation failure was reported; this is not a current measurement")
        case .telemetryStale:
            return loc("Battery telemetry is stale or missing for the current BLE session")
        case .noUSBConnection:
            return loc("USB is not connected; charging state cannot be attributed to this host")
        case .chargingStateUnknown:
            return loc("Camera charging state is unknown")
        case .sessionMismatch:
            return loc("Battery sample belongs to another BLE session")
        case .invalidUSBPower:
            return loc("USB power properties are malformed or unavailable")
        case .invalidBatterySample:
            return loc("Battery sample is outside the valid range")
        case .invalidClock:
            return loc("Reducer clock is invalid")
        }
    }

    static func allocation(_ diagnosis: Pocket3PowerChargingDiagnosis) -> String {
        diagnosis.configuredMilliamps.map { "\($0) mA" } ?? loc("Unknown")
    }

    static func linkSpeed(_ diagnosis: Pocket3PowerChargingDiagnosis) -> String {
        guard let bits = diagnosis.linkBitsPerSecond, bits > 0 else {
            return loc("Unknown")
        }
        if bits >= 1_000_000_000 {
            return String(format: "%.1f Gbps", Double(bits) / 1_000_000_000)
        }
        return String(format: "%.0f Mbps", Double(bits) / 1_000_000)
    }

    static func battery(_ diagnosis: Pocket3PowerChargingDiagnosis) -> String {
        guard let percent = diagnosis.batteryPercent else { return loc("Unknown") }
        let state: String
        switch diagnosis.chargingRaw {
        case 0: state = loc("Not charging")
        case 1: state = loc("Charging")
        default: state = loc("Charging unknown")
        }
        return "\(percent)% · \(state)"
    }

    static func trend(_ diagnosis: Pocket3PowerChargingDiagnosis) -> String? {
        guard let drop = diagnosis.observedDropPercent,
              let duration = diagnosis.trendDuration,
              diagnosis.sampleCount > 1 else { return nil }
        return String(format: loc("Drop %.0f%% over %.0f s · %d samples"),
                      Double(drop), duration, diagnosis.sampleCount)
    }

    static var methodology: String {
        loc("Charging diagnosis uses same-session battery telemetry and a time window; 500 mA alone does not indicate insufficient power.")
    }
}

/// The Diagnostics card is a read-only projection of the reducer. It has no
/// controls and keeps USB allocation, link speed and BLE battery evidence in
/// separate rows so one signal cannot masquerade as another.
struct PowerChargingDiagnosticsCard: View {
    let diagnosis: Pocket3PowerChargingDiagnosis

    var body: some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                Text(loc("USB power & charging")).font(Yun.Text.title)
                detail(loc("Power diagnosis"), PowerChargingPresentation.title(diagnosis))
                detail(loc("USB current allocation"), PowerChargingPresentation.allocation(diagnosis))
                detail(loc("USB link speed"), PowerChargingPresentation.linkSpeed(diagnosis))
                detail(loc("Battery telemetry"), PowerChargingPresentation.battery(diagnosis))
                if let trend = PowerChargingPresentation.trend(diagnosis) {
                    detail(loc("Battery trend"), trend)
                }
                Text(PowerChargingPresentation.reason(diagnosis))
                    .font(Yun.Text.caption)
                    .foregroundStyle(diagnosis.needsAttention ? Yun.Palette.warning : Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if diagnosis.allocationFailed == true {
                    Text(loc("macOS reported a USB power allocation failure."))
                        .font(Yun.Text.caption).foregroundStyle(Yun.Palette.warning)
                }
                Text(PowerChargingPresentation.methodology)
                    .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(Yun.Palette.textTertiary)
            Spacer(minLength: Yun.Space.md)
            Text(value).foregroundStyle(Yun.Palette.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .font(Yun.Text.caption)
    }
}
