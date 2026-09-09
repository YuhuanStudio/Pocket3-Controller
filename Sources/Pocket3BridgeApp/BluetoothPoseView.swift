import SwiftUI
import Pocket3Core
import YunDesign

struct BluetoothPoseView: View {
    let observation: BluetoothPoseObservation

    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            Text(loc("Camera-reported orientation")).font(Yun.Text.label)
            HStack(spacing: Yun.Space.md) {
                angle(loc("Yaw"), observation.yawDegrees)
                angle(loc("Pitch"), observation.pitchDegrees)
                angle(loc("Roll"), observation.rollDegrees)
            }
            Text(loc("Device-reported angles; not calibrated to USB coordinates."))
                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func angle(_ title: String, _ degrees: Double) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.xs) {
            Text(title).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
            Text(verbatim: String(format: "%.1f°", degrees)).font(Yun.Text.mono)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
