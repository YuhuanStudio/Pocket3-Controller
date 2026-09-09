import AppKit
import Foundation

/// Model-free test of a separately identified fixture bundle. Never starts an
/// updater in the production preference domain, where automatic checks or
/// downloads may already be enabled by the user.
@MainActor enum UpdateFeedVerification {
    static func run(environment: [String: String]) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard AppUpdateController.allowsLoopbackFixture(bundleIdentifier: Bundle.main.bundleIdentifier,
                feed: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                enabled: environment["POCKET3_UPDATE_FIXTURE"] == "loopback",
                explicitLaunch: CommandLine.arguments.contains("--update-verification")) else {
            // A caller-supplied environment flag does not authorize deleting
            // the ordinary app's preferences during fixture cleanup.
            emit(verified: false, error: NSError(domain: "UpdateFixture", code: 1), fixture: false)
        }
        let updater = AppUpdateController.shared
        updater.start(environment: environment)
        Task { @MainActor in
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !updater.canCheckForUpdates, ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            updater.verifyFeed { error in emit(verified: error == nil, error: error, fixture: true) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            emit(verified: false, error: NSError(domain: "UpdateVerificationTimeout", code: 1), fixture: true)
        }
        NSApp.run()
        exit(2)
    }

    private static func emit(verified: Bool, error: Error?, fixture: Bool) -> Never {
        struct Report: Encodable {
            let verified: Bool
            let fixture: Bool
            let signatureStatus: Int?
            let errorDomain: String?
            let errorCode: Int?
            let archiveDownloaded = false
            let installationPerformed = false
            let cameraServiceStarted = false
        }
        let failure = error as NSError?
        let report = Report(verified: verified, fixture: fixture,
            signatureStatus: AppUpdateController.shared.feedSigningStatus.map { $0.rawValue },
            errorDomain: failure?.domain, errorCode: failure?.code)
        if let data = try? JSONEncoder().encode(report) { FileHandle.standardOutput.write(data) }
        if fixture, let identifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }
        exit(verified ? 0 : 1)
    }
}
