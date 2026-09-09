import AppKit
import AVFoundation
import YunDesign

/// Present the same permissions entry point as YunAudio. Camera access is
/// requested by Connect; a microphone grant is needed only for an audio task.
@MainActor enum FirstLaunchPermissions {
    static func presentIfNeeded(model: AppModel) {
        let defaults = UserDefaults.standard
        guard !CommandLine.arguments.contains("--hardware-validation"),
              !defaults.bool(forKey: "Pocket3PermissionGuideShown") else { return }
        SettingsWindow.open(model: model, initialSection: .permissions)
        if SettingsWindow.window?.isVisible == true {
            defaults.set(true, forKey: "Pocket3PermissionGuideShown")
        }
    }
}
