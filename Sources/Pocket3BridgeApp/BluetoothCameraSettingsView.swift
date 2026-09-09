import SwiftUI
import Pocket3Core
import YunDesign

struct BluetoothCameraSettingsView: View {
    let observations: [CameraSettingsObservation]
    let reading: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack {
                Text(loc("Bluetooth camera settings")).font(Yun.Text.label)
                Spacer(minLength: 0)
                if reading { ProgressView().controlSize(.mini) }
                Button(loc("Read settings"), action: refresh)
                    .buttonStyle(YunButtonStyle(.secondary, small: true)).disabled(reading)
            }
            row(loc("White balance"), whiteBalance)
            row(loc("Focus mode"), focus)
            row(loc("Exposure"), exposure)
            Text(loc("Read-only values reported by the paired Bluetooth camera."))
                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: Yun.Space.sm) {
            Text(label).foregroundStyle(Yun.Palette.textSecondary)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(Yun.Palette.textPrimary).lineLimit(1)
        }.font(Yun.Text.caption)
    }
    private func observation(_ property: CameraSettingsProperty) -> CameraSettingsObservation? {
        observations.first { $0.property == property && $0.isFresh(now: ProcessInfo.processInfo.systemUptime) }
    }
    private var whiteBalance: String {
        guard let stored = observation(.imageEffect)?.value, case .whiteBalance(let value) = stored else { return "—" }
        switch value {
        case .automatic: return loc("Auto")
        case .customKelvin(let kelvin): return "\(kelvin) K"
        }
    }
    private var focus: String {
        guard let stored = observation(.lensState)?.value, case .focus(let value) = stored else { return "—" }
        return value == .single ? loc("Single AF") : loc("Continuous AF")
    }
    private var exposure: String {
        guard let observed = observation(.exposure), let mode = observed.exposureMode else { return "—" }
        if mode == .manual { return loc("Manual exposure") }
        guard let stored = observed.value, case .autoEV(let thirds) = stored else { return loc("Auto") }
        return loc("Auto") + " · " + String(format: "%+.1f EV", Double(thirds) / 3)
    }
}
