import SwiftUI
import YunDesign

/// YunAudio/MainWindow.errorBanner, kept at the original control density.
struct AppMessageBanner: View {
    let message: String
    var body: some View {
        let displayMessage = YunMessagePresentation.displayText(for: message)
        HStack(spacing: Yun.Space.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(Yun.Palette.danger)
            Text(displayMessage)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.danger)
                .yunBoundedMessage(message, maximumLines: 1)
        }
        .padding(.horizontal, Yun.Space.md)
        .padding(.vertical, Yun.Space.sm)
        .background(Yun.Palette.danger.opacity(0.08), in: .rect(cornerRadius: Yun.Radius.button))
    }
}
