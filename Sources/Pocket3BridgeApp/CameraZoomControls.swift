import SwiftUI
import YunDesign

@MainActor struct CameraZoomControls: View {
    @Bindable var model: CameraZoomModel

    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack(spacing: Yun.Space.sm) {
                Text(loc("Zoom")).font(Yun.Text.label).foregroundStyle(Yun.Palette.textSecondary)
                Spacer(minLength: 0)
                Text(model.hasValue ? "\(Int((model.fraction * 100).rounded()))%" : "—")
                    .font(Yun.Text.mono).monospacedDigit().foregroundStyle(Yun.Palette.textTertiary)
                    .frame(width: 38, alignment: .trailing)
                    .accessibilityLabel(loc("Zoom range position"))
            }
            HStack(spacing: Yun.Space.sm) {
                Button { model.adjust(-1) } label: { Image(systemName: "minus").frame(width: 12, height: 12) }
                    .buttonStyle(YunButtonStyle(.secondary, small: true))
                    .disabled(!model.canInteract || model.fraction <= 0)
                    .help(loc("Zoom out")).accessibilityLabel(loc("Zoom out"))
                YunSlider(fraction: Binding(get: { model.fraction }, set: { model.request(fraction: $0) }))
                    .disabled(!model.canInteract).allowsHitTesting(model.canInteract)
                    .accessibilityLabel(loc("Zoom"))
                    .accessibilityHint(loc("Position within the available zoom range, not a magnification ratio."))
                Button { model.adjust(1) } label: { Image(systemName: "plus").frame(width: 12, height: 12) }
                    .buttonStyle(YunButtonStyle(.secondary, small: true))
                    .disabled(!model.canInteract || model.fraction >= 1)
                    .help(loc("Zoom in")).accessibilityLabel(loc("Zoom in"))
            }
        }
        .help(model.lastError ?? loc("Position within the available zoom range, not a magnification ratio."))
    }
}
