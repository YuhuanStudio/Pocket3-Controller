import AppKit
import SwiftUI
import YunDesign
import Pocket3Core

enum PreferencesSection: String, CaseIterable, Identifiable {
    case general, appearance, camera, permissions, shortcuts, diagnostics, about
    var id: String { rawValue }
    var title: String { loc(["general":"General", "appearance":"Appearance", "camera":"Camera", "permissions":"Permissions", "shortcuts":"Shortcuts", "diagnostics":"Diagnostics", "about":"About"][rawValue]!) }
    var symbol: String { ["general":"gearshape", "appearance":"paintpalette", "camera":"camera", "permissions":"hand.raised", "shortcuts":"command", "diagnostics":"waveform.path.ecg", "about":"info.circle"][rawValue]! }
}
@MainActor @Observable final class SettingsNavigation {
    var selection: PreferencesSection
    init(selection: PreferencesSection = .general) { self.selection = selection }
}
/// YunAudio's retained settings-window owner, with camera-specific content.
@MainActor enum SettingsWindow {
    private static var controller: NSWindowController?
    private static var host: NSViewController?
    private static var delegate: Delegate?
    private static let navigation = SettingsNavigation()
    static func open(model: AppModel, initialSection: PreferencesSection? = nil) {
        if let initialSection { navigation.selection = initialSection }
        if controller == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            host = NSHostingController(rootView: PreferencesWindow(model: model, navigation: navigation))
            delegate = Delegate(); window.delegate = delegate
            window.title = loc("Settings"); WindowChrome.integrate(window)
            window.isReleasedWhenClosed = false; window.contentViewController = host
            window.minSize = NSSize(width: 620, height: 440)
            window.setFrameAutosaveName("Pocket3BridgeSettingsWindow"); window.center()
            controller = NSWindowController(window: window)
        }
        if controller?.window?.contentViewController == nil { controller?.window?.contentViewController = host }
        NSApp.activate(ignoringOtherApps: true); controller?.showWindow(nil); controller?.window?.makeKeyAndOrderFront(nil)
    }
    static var selection: PreferencesSection { get { navigation.selection } set { navigation.selection = newValue } }
    static var hostIdentity: ObjectIdentifier? { host.map(ObjectIdentifier.init) }
    static func refreshContent(model: AppModel) {
        (host as? NSHostingController<PreferencesWindow>)?.rootView = PreferencesWindow(model: model, navigation: navigation)
    }
    static var window: NSWindow? { controller?.window }
    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) { (notification.object as? NSWindow)?.contentViewController = nil }
    }
}

struct PreferencesWindow: View {
    @Bindable var model: AppModel
    @Bindable var navigation: SettingsNavigation
    @Bindable private var theme = YunTheme.shared
    @Bindable private var updater = AppUpdateController.shared
    @State private var showsDock = InterfaceOptions.showsDockIcon
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginMessage: String?
    @State private var previewSwitch = true
    var body: some View {
        let _ = theme.language
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(PreferencesSection.allCases) { section in
                    Button { navigation.selection = section } label: {
                        HStack(spacing: Yun.Space.sm) { Image(systemName: section.symbol).font(.system(size: 11)).frame(width: 16); Text(section.title).font(.system(size: 12, weight: .medium)); Spacer(minLength: 0) }
                            .foregroundStyle(navigation.selection == section ? Yun.Palette.textPrimary : Yun.Palette.textSecondary)
                            .padding(.horizontal, Yun.Space.sm).padding(.vertical, 6)
                            .background(navigation.selection == section ? Yun.Palette.accentSubtle : .clear, in: .rect(cornerRadius: Yun.Radius.control))
                            .contentShape(.rect(cornerRadius: Yun.Radius.control))
                    }.buttonStyle(.plain).focusEffectDisabled()
                }
                Spacer()
            }.padding(Yun.Space.md).padding(.top, WindowChrome.controlClearance).frame(width: 168)
            Rectangle().fill(Yun.Palette.borderHairline).frame(width: 1)
            ScrollView { content.padding(Yun.Space.xl).frame(maxWidth: .infinity, alignment: .leading) }.scrollIndicators(.never)
        }.ignoresSafeArea(.container, edges: .top).background(Yun.Palette.background).focusEffectDisabled()
            .background(WindowChromeInstaller().frame(width: 0, height: 0))
            .accessibilityIdentifier("Pocket3BridgeSettingsWindow")
            .environment(\.locale, theme.language == .system ? .autoupdatingCurrent : Locale(identifier: theme.language.rawValue))
    }
    @ViewBuilder private var content: some View {
        switch navigation.selection {
        case .general: general
        case .appearance: appearance
        case .camera: camera
        case .permissions: permissions
        case .shortcuts: shortcuts
        case .diagnostics: diagnostics
        case .about: about
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading("Language")
            settingsCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    SettingsChoiceGroup(selection: $theme.language, options: YunLanguage.allCases.map { ($0, $0.title) })
                    caption("Takes effect at once. Kept separately from the system's own language, so this application can be read in one language on a Mac set up in another.")
                }
            }
            heading("Application")
            settingsCard {
                VStack(spacing: Yun.Space.md) {
                    setting("Show in Dock", "Reach the app from the Dock and Command-Tab.") { YunSwitch(isOn: Binding(get: { showsDock }, set: { showsDock = $0; InterfaceOptions.showsDockIcon = $0 })) }
                    YunDivider()
                    setting("Launch at login", "The app opens without automatically enabling camera access.") {
                        YunSwitch(isOn: Binding(get: { loginEnabled }, set: { value in loginMessage = LoginItem.setEnabled(value); loginEnabled = LoginItem.isEnabled }))
                    }
                    if let loginMessage { Text(loginMessage).font(Yun.Text.caption).foregroundStyle(Yun.Palette.warning) }
                }
            }
            heading("Updates")
            updateCard
        }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading("Appearance")
            settingsCard { VStack(alignment: .leading, spacing: Yun.Space.md) {
                YunSegmented(selection: $theme.appearance, options: YunAppearance.allCases.map { ($0, $0.title) })
                YunDivider()
                YunSegmented(selection: $theme.style, options: YunStyle.allCases.map { ($0, $0.title) })
                caption(theme.style.detail)
            } }
            heading("Accent")
            settingsCard { VStack(alignment: .leading, spacing: Yun.Space.md) {
                SettingsChoiceGroup(selection: $theme.accent, options: YunAccent.allCases.map { ($0, $0.title) })
                if theme.accent == .custom { HueStrip(hue: $theme.accentHue) }
                HStack { Button(loc("Primary")) {}.buttonStyle(YunButtonStyle(.primary)); Button(loc("Secondary")) {}.buttonStyle(YunButtonStyle(.secondary)); Spacer(); YunSwitch(isOn: $previewSwitch) }
                YunStatusPill(loc("Preview"), value: "30 fps", tone: .success)
            } }
            heading("Application icon")
            settingsCard { HStack(spacing: Yun.Space.md) {
                Image(nsImage: YunIconBadge.image(size: 64, style: YunIconBadge.style(named: model.iconStyle)))
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    YunSelect(selection: Binding(get: { model.iconStyle }, set: { model.setIconStyle($0) }), options: YunIconBadge.styles.map { .init(value: $0.name, title: $0.name) })
                    caption("Changes the icon drawn by the app. Finder uses the icon packaged with this build.")
                }
            } }
        }
    }
    private var camera: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading("Camera")
            settingsCard { VStack(alignment: .leading, spacing: Yun.Space.md) {
                YunSelect(selection: $model.selectedID, placeholder: model.cameraSelectionPlaceholder, options: (model.status?.devices ?? []).map { .init(value: $0.id, title: $0.name) })
                YunSelect(selection: $model.captureModeID, placeholder: loc("Select a capture format"), options: model.availableModes.map { .init(value: $0.id, title: $0.compactTitle, detail: loc($0.isPortrait ? "Portrait" : "Landscape")) })
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    Text(loc("USB input format")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                    YunSelect(selection: $model.capturePixelFormat, options: model.capturePixelFormatOptions)
                    if model.captureMode != nil && !model.capturePixelFormatSupported {
                        caption("This input format is not advertised for the selected mode.")
                    }
                }
                Button(loc("Connect")) { Task { await model.connect() } }.buttonStyle(YunButtonStyle(.primary, small: true)).disabled(!model.canConnect)
                caption("Format changes take effect when reconnecting. Only the selected Pocket 3 is used.")
                caption("Match the shooting orientation on Pocket 3 to this format to avoid black borders.")
            } }
            heading("AI access")
            settingsCard { VStack(alignment: .leading, spacing: Yun.Space.md) {
                YunSelect(selection: Binding(get: { model.access }, set: { value in Task { await model.setAccess(value) } }), options: AccessMode.allCases.map { .init(value: $0, title: loc($0.title)) })
                    .disabled(!model.isCameraSource)
                caption("Manual control takes over from AI. Reconnecting never resumes an old movement.")
            } }
        }
    }
    private var permissions: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading("Permissions")
            permissionCard("Camera", detail: model.status?.permission ?? "notDetermined", symbol: "camera", pane: "Privacy_Camera", request: { await model.allowCameraPermission() })
            permissionCard("Microphone", detail: model.microphonePermission, symbol: "mic", pane: "Privacy_Microphone", request: { await model.allowMicrophonePermission() })
            settingsCard { VStack(alignment: .leading, spacing: Yun.Space.md) {
                Text(loc("Camera access stays with you")).font(Yun.Text.body)
                caption("Microphone access is requested only for an audio test or a voice task. Privacy pause releases both inputs.")
                Button(loc("Privacy pause")) { Task { await model.pause() } }.buttonStyle(YunButtonStyle(.primary, small: true))
            } }
        }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading("In the window")
            settingsCard { VStack(spacing: Yun.Space.md) {
                shortcut("Settings", "⌘ ,")
                shortcut("Capture image", "⇧ ⌘ S")
                shortcut("Stop operation", "⌘ .")
                shortcut("Privacy pause", "⇧ ⌘ P")
                shortcut("Quit", "⌘ Q")
            } }
            caption("The menu bar also provides these actions when the main window is closed.")
        }
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading("Diagnostics")
            settingsCard { VStack(alignment: .leading, spacing: Yun.Space.md) {
                YunDetailRow(loc("State"), value: loc(model.phaseTitle))
                YunDetailRow(loc("Frames"), value: "\(model.status?.capture.frames ?? 0)")
                YunDetailRow("FPS", value: String(format: "%.1f", model.status?.capture.recentFPS ?? 0))
                YunDetailRow(loc("AI engine"), value: model.selectedEngine == "mlx" ? "Qwen 3.5 · MLX" : "Apple Foundation Models")
                Button(loc("Export diagnostics")) { Task { await model.exportDiagnostics() } }.buttonStyle(YunButtonStyle(.secondary, small: true))
                caption("Exports omit camera images and device identifiers by default.")
            } }
            settingsCard { VStack(alignment: .leading, spacing: Yun.Space.md) {
                Text(loc("USB audio test")).font(Yun.Text.title)
                Text(model.audioMessage).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                Button(loc("Test for 3 seconds")) { Task { await model.audioTest() } }.buttonStyle(YunButtonStyle(.secondary, small: true)).disabled(!model.cameraActionReady)
            } }
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            HStack(spacing: Yun.Space.md) {
                Image(nsImage: YunIconBadge.image(size: 56, style: YunIconBadge.style(named: model.iconStyle))).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Pocket3Product.displayName).font(.system(size: 20, weight: .semibold)).foregroundStyle(Yun.Palette.textPrimary)
                    Text(String(format: loc("Version %@"), Pocket3Product.displayVersion)).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                }
            }
            settingsCard { VStack(alignment: .leading, spacing: Yun.Space.sm) {
                YunDetailRow(loc("Build"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                YunDetailRow(loc("Platform"), value: "macOS 27 · Apple Silicon")
                YunDetailRow(loc("Design"), value: "YunAudio / YunUI")
                caption("Independent, unofficial integration for DJI Osmo Pocket 3.")
            } }
            heading("Updates")
            updateCard
            settingsCard { VStack(alignment: .leading, spacing: Yun.Space.md) {
                Button(loc("Third-party licences")) { if let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses") { NSWorkspace.shared.open(url) } }.buttonStyle(YunButtonStyle(.ghost, small: true))
                Button(loc("Report an issue")) { model.copyIssueReport() }.buttonStyle(YunButtonStyle(.secondary, small: true))
                caption("Copies the app version and macOS version so you can share a reproducible report.")
            } }
        }
    }
    private var updateCard: some View {
        settingsCard { VStack(alignment: .leading, spacing: Yun.Space.md) {
            settingsActionRow {
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc("Keep Pocket 3 Controller up to date")).font(Yun.Text.body)
                    Text(loc(updater.statusMessage)).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } action: {
                Button(loc("Check for Updates…")) { updater.checkForUpdates() }.buttonStyle(YunButtonStyle(.secondary, small: true))
                    .disabled(!updater.canCheckForUpdates)
            }
            YunDivider()
            setting("Automatically check for updates", "Update checks require this project's published feed and signing key.") {
                YunSwitch(isOn: Binding(get: { updater.automaticallyChecksForUpdates }, set: { updater.setAutomaticallyChecksForUpdates($0) })).disabled(!updater.isAvailable)
            }
            if !updater.installationLocation.canReplaceInPlace {
                YunDivider()
                settingsActionRow {
                    HStack(alignment: .top, spacing: Yun.Space.sm) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Yun.Palette.warning)
                        caption("Move the app to Applications before installing updates.")
                    }
                } action: {
                    Button(loc("Open Applications")) { updater.openApplicationsFolder() }.buttonStyle(YunButtonStyle(.secondary, small: true))
                }
            }
        } }
    }
    private func permissionCard(_ title: String, detail: String, symbol: String, pane: String, request: @escaping () async -> Void) -> some View {
        settingsCard { HStack(spacing: Yun.Space.md) { Image(systemName: symbol).frame(width: 20); VStack(alignment: .leading, spacing: 4) { Text(loc(title)).font(Yun.Text.title); Text(loc(detail)).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary) }; Spacer(); Button(loc(detail == "notDetermined" ? "Allow access" : "Open Settings")) { if detail == "notDetermined" { Task { await request() } } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) } }.buttonStyle(YunButtonStyle(.secondary, small: true)) } }
    }
    private func setting<Content: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> Content) -> some View {
        HStack(spacing: Yun.Space.sm) { VStack(alignment: .leading, spacing: 4) { Text(loc(title)).font(Yun.Text.body); caption(detail) }; Spacer(minLength: Yun.Space.sm); control().fixedSize(horizontal: true, vertical: false) }
    }
    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack { Text(loc(title)).font(Yun.Text.body); Spacer(); Text(keys).font(Yun.Text.mono).foregroundStyle(Yun.Palette.textSecondary).padding(.horizontal, 8).padding(.vertical, 3).background(Yun.Palette.elevated, in: .rect(cornerRadius: 6)).overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Yun.Palette.border, lineWidth: 1) } }
    }
    // YunCard draws its surface around its content. Short diagnostic/status
    // content must receive the same column width as the neighbouring cards.
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        YunCard { content().frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func settingsActionRow<Label: View, Action: View>(@ViewBuilder label: () -> Label, @ViewBuilder action: () -> Action) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Yun.Space.sm) {
                label().fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: Yun.Space.sm)
                action().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                label().fixedSize(horizontal: false, vertical: true)
                action().fixedSize(horizontal: true, vertical: false)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func heading(_ title: String) -> some View { Text(loc(title)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Yun.Palette.textTertiary).textCase(.uppercase) }
    private func caption(_ text: String) -> some View { Text(loc(text)).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary).fixedSize(horizontal: false, vertical: true) }
}

/// Preserve Yun's individual button styling and balanced, filled rows. Its
/// shared wrap measures unequal natural widths before assigning equal cells;
/// reserving the longest label width prevents those equal cells clipping it.
private struct SettingsChoiceGroup<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    private var minimumChoiceWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        return options.map { ceil(($0.title as NSString).size(withAttributes: [.font: font]).width) + 12 }.max() ?? 0
    }

    var body: some View {
        YunWrap(spacing: 6, lineSpacing: 6, balanced: true, fills: true) {
            ForEach(options, id: \.value) { option in
                YunSegmented(selection: $selection, options: [option], wraps: true)
                    .frame(minWidth: minimumChoiceWidth)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
