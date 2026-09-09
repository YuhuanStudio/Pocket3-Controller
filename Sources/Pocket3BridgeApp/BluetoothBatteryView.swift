import SwiftUI
import Pocket3Core
import YunDesign

enum BluetoothBatteryPresentation {
    static func warningTitle(_ assessment: BluetoothBatteryAssessment) -> String? {
        if assessment.lowBattery && assessment.falling { return loc("Bluetooth battery low and falling") }
        if assessment.lowBattery { return loc("Bluetooth battery low") }
        if assessment.falling { return loc("Bluetooth battery falling") }
        return nil
    }

    static var sourceDetail: String {
        loc("Battery reports come from the paired Bluetooth camera. USB power information is shown separately in Diagnostics.")
    }
}

/// Shared by the paired-camera panel and offline presentation checks. Battery
/// telemetry is never implicitly associated with the USB capture device.
struct BluetoothBatteryView: View {
    let assessment: BluetoothBatteryAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack {
                Text(loc("Bluetooth camera battery")).font(Yun.Text.label)
                Spacer(minLength: 0)
                Text(verbatim: "\(assessment.percent)%").font(Yun.Text.mono)
            }
            Text(chargingTitle).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
            if let warning = BluetoothBatteryPresentation.warningTitle(assessment) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(Yun.Text.caption).foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Text(assessment.falling ? loc("Check the power connection on that camera.")
                     : loc("Keep this camera connected to power while the battery is low."))
                    .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(BluetoothBatteryPresentation.sourceDetail)
                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chargingTitle: String {
        switch assessment.chargingState {
        case .charging: loc("Charging")
        case .notCharging: loc("Not charging")
        case .unknown: loc("Charging unknown")
        }
    }
}
