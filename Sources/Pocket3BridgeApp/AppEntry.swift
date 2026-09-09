import AppKit
import Foundation
import YunDesign

/// Packaging probes run before the app model exists, so building an icon
/// cannot open the camera, claim the bridge socket or start an updater.
@main @MainActor enum AppEntry {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        if environment["POCKET3_UPDATE_CHECK"] != nil {
            UpdateFeedVerification.run(environment: environment)
        }
        YunStrings.bundle = AppResources.bundle
        if let directory = environment["POCKET3_ICON"] {
            _ = NSApplication.shared
            exit(YunIconBadge.writeIconset(to: directory, style: YunIconBadge.style(named: environment["POCKET3_ICON_STYLE"])) ? 0 : 1)
        }
        if environment["POCKET3_RESOURCE_CHECK"] != nil {
            let manager = FileManager.default
            let resources = Bundle.main.resourceURL!
            var checks = [String: Bool]()
            checks["icon"] = YunAppIcon.image != nil
            for language in [YunLanguage.english, .traditionalChinese, .simplifiedChinese] {
                YunStrings.useForThisLaunchOnly(language)
                checks[language.rawValue] = !loc("Settings").isEmpty && (language == .english || loc("Settings") != "Settings")
            }
            checks["coreAI"] = manager.fileExists(atPath: resources.appendingPathComponent("Models/yolos-tiny_float32_static.aimodel").path)
            checks["mlxMetal"] = manager.fileExists(atPath: resources.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib").path)
            checks["sparkle"] = manager.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Sparkle").path)
            checks["icns"] = manager.fileExists(atPath: resources.appendingPathComponent("Pocket3MCP.icns").path)
            let data = try! JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        }
        Pocket3BridgeApp.main()
    }
}
