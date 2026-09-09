import AppKit
import SwiftUI
import YunDesign

@MainActor
enum UpdatePermissionWindow {
    static let size = CGSize(width: 540, height: 390)

    static func make(
        icon: NSImage? = NSApp?.applicationIconImage,
        answer: @escaping (_ checksAutomatically: Bool, _ downloadsAutomatically: Bool) -> Void
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = loc("Updates")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: UpdatePermissionView(icon: icon, answer: answer))
        WindowChrome.integrate(window)
        window.center()
        return window
    }
}

/// Pocket 3 Controller's own first-run choice for update checks.
///
/// Sparkle still downloads, verifies and installs; it no longer owns this one
/// piece of interface. Its stock alert belongs to AppKit's visual language and
/// appeared as an unrelated grey sheet over Pocket 3 Controller's flat surface.
struct UpdatePermissionView: View {
    @State private var downloadsAutomatically = true
    private let icon: NSImage
    let answer: (_ checksAutomatically: Bool, _ downloadsAutomatically: Bool) -> Void

    init(
        icon: NSImage? = nil,
        answer: @escaping (_ checksAutomatically: Bool, _ downloadsAutomatically: Bool) -> Void
    ) {
        self.icon =
            icon
            ?? YunIconBadge.image(
                size: 64, style: YunIconBadge.style(named: YunIconBadge.fallbackStyle))
        self.answer = answer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            HStack(alignment: .top, spacing: Yun.Space.md) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: Yun.Space.xs) {
                    Text(loc("Keep Pocket 3 Controller up to date"))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Yun.Palette.textPrimary)
                    Text(
                        loc(
                            "Pocket 3 Controller can check for new versions in the background, at most once a day. You can change this later in Settings."
                        )
                    )
                    .font(Yun.Text.body)
                    .foregroundStyle(Yun.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    detail(
                        symbol: "checkmark.shield.fill",
                        title: loc("Signed before installation"),
                        message: loc("Every update is verified with Pocket 3 Controller's Ed25519 key."))
                    YunDivider()
                    detail(
                        symbol: "hand.raised.fill",
                        title: loc("No activity data"),
                        message: loc("No camera images, audio or questions are sent."))
                    YunDivider()
                    HStack(spacing: Yun.Space.sm) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(loc("Download and install automatically"))
                                .font(Yun.Text.body)
                                .foregroundStyle(Yun.Palette.textPrimary)
                            Text(
                                loc(
                                    "Pocket 3 Controller will still ask macOS for permission when required."
                                )
                            )
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.textSecondary)
                        }
                        Spacer(minLength: Yun.Space.sm)
                        YunSwitch(isOn: $downloadsAutomatically)
                    }
                }
            }

            HStack(spacing: Yun.Space.sm) {
                Spacer()
                Button(loc("Check manually")) {
                    answer(false, false)
                }
                .buttonStyle(YunButtonStyle(.secondary))
                Button(loc("Check automatically")) {
                    answer(true, downloadsAutomatically)
                }
                .buttonStyle(YunButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Yun.Space.xl)
        .frame(
            width: UpdatePermissionWindow.size.width, height: UpdatePermissionWindow.size.height
        )
        .yunWindowBackground()
    }

    private func detail(symbol: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: Yun.Space.sm) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(Yun.Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc(title))
                    .font(Yun.Text.body)
                    .foregroundStyle(Yun.Palette.textPrimary)
                Text(message)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textSecondary)
            }
        }
    }
}
