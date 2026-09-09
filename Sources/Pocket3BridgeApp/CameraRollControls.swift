import SwiftUI
import YunDesign

@MainActor struct CameraRollControls: View {
    @Bindable var model: CameraRollModel

    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack(spacing: Yun.Space.sm) {
                Text(loc("USB roll")).font(Yun.Text.label).foregroundStyle(Yun.Palette.textSecondary)
                YunBadge(loc("Experimental"))
                Spacer(minLength: 0)
                Text(model.currentRawValue.map(String.init) ?? "—")
                    .font(Yun.Text.mono).monospacedDigit().foregroundStyle(Yun.Palette.textTertiary)
                    .frame(width: 38, alignment: .trailing)
                    .accessibilityLabel(loc("Roll control value"))
                Button { model.restoreDefault() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 12, height: 12) }
                    .buttonStyle(YunButtonStyle(.secondary, small: true)).disabled(!model.canRestoreDefault)
                    .help(loc("Restore the device's roll default")).accessibilityLabel(loc("Restore the device's roll default"))
            }
            HStack(spacing: Yun.Space.sm) {
                Button { model.adjust(-1) } label: { Image(systemName: "minus").frame(width: 12, height: 12) }
                    .buttonStyle(YunButtonStyle(.secondary, small: true))
                    .disabled(!model.canInteract || model.fraction <= 0)
                    .help(loc("Decrease roll")).accessibilityLabel(loc("Decrease roll"))
                YunSlider(fraction: Binding(get: { model.fraction }, set: { model.request(fraction: $0) }))
                    .disabled(!model.canInteract).allowsHitTesting(model.canInteract)
                    .accessibilityLabel(loc("USB roll"))
                    .accessibilityHint(loc("Device roll control value; physical direction and angle are not calibrated."))
                Button { model.adjust(1) } label: { Image(systemName: "plus").frame(width: 12, height: 12) }
                    .buttonStyle(YunButtonStyle(.secondary, small: true))
                    .disabled(!model.canInteract || model.fraction >= 1)
                    .help(loc("Increase roll")).accessibilityLabel(loc("Increase roll"))
            }
        }.help(model.lastError ?? loc("Device roll control value; physical direction and angle are not calibrated."))
    }
}
