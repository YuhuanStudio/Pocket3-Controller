@preconcurrency import AppIntents
import Foundation
import Pocket3Core

/// Shortcuts/Spotlight entry points that use the same AppModel and local IPC
/// service as the window, MCP and background bridge. They deliberately retain
/// manual access: running a shortcut never grants AI/gimbal control, joins
/// camera Wi-Fi, or starts a body recording.
@available(macOS 26.0, *)
struct Pocket3ConnectPreviewIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect Pocket 3 Preview"
    static let description = IntentDescription("Connect the selected Pocket 3 using its saved preview settings.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        await model.launch()
        guard model.canConnect else {
            throw BridgeFailure("intent_camera_unavailable", "The selected Pocket 3 or its saved capture format is unavailable")
        }
        await model.connect()
        guard model.status?.phase == "ready" else {
            throw BridgeFailure("intent_connect_failed", "Pocket 3 preview did not become ready")
        }
        return .result(dialog: "Pocket 3 preview connected")
    }
}

@available(macOS 26.0, *)
struct Pocket3PrivacyPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Pocket 3 Preview"
    static let description = IntentDescription("Release the active Pocket 3 preview and camera session.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        await model.launch()
        await model.pause()
        guard model.status?.phase == "paused" else {
            throw BridgeFailure("intent_pause_failed", "Pocket 3 preview did not pause")
        }
        return .result(dialog: "Pocket 3 preview paused")
    }
}

/// Advertises the two safe camera lifecycle actions to Shortcuts/Spotlight.
/// More invasive control remains in the explicit App/MCP paths until it has
/// the required hardware evidence.
@available(macOS 26.0, *)
struct Pocket3AppShortcuts: AppShortcutsProvider {
    static let appShortcuts: [AppShortcut] = [
        AppShortcut(intent: Pocket3ConnectPreviewIntent(),
                    phrases: ["Connect \(.applicationName) preview"],
                    shortTitle: "Connect Preview",
                    systemImageName: "video"),
        AppShortcut(intent: Pocket3PrivacyPauseIntent(),
                    phrases: ["Pause \(.applicationName) preview"],
                    shortTitle: "Pause Preview",
                    systemImageName: "eye.slash")
    ]
}
