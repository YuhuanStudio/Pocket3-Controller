import AppKit
import Foundation
import Observation
import Pocket3Core
import Sparkle
import YunDesign

/// Sparkle terminates through the app delegate, which releases camera inputs
/// and closes IPC before the bundle can be replaced.
@MainActor
@Observable
final class AppUpdateController: NSObject, SPUUpdaterDelegate, NSWindowDelegate {
    enum PermissionDecision: String {
        case manual
        case automatic
    }

    enum InstallationLocation: Equatable {
        case applications
        case userApplications
        case readOnlyVolume
        case appTranslocation
        case elsewhere

        var canReplaceInPlace: Bool {
            self == .applications || self == .userApplications
        }
    }

    static let shared = AppUpdateController()
    static var repositoryURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "Pocket3RepositoryURL") as? String).flatMap(URL.init(string:))
    }
    // GitHub's latest endpoint excludes prereleases, including our first beta.
    static var releasesURL: URL? { repositoryURL?.appendingPathComponent("releases") }
    private(set) var statusMessage = "No update source is configured for this development build. Replace the app manually."

    private(set) var isAvailable = false
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var installationLocation: InstallationLocation = .elsewhere
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var automaticCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var feedVerificationCompletion: ((Error?) -> Void)?
    @ObservationIgnored private(set) var feedSigningStatus: SPUAppcastSigningValidationStatus?
    @ObservationIgnored private var permissionWindowController: NSWindowController?
    @ObservationIgnored private var permissionDefaults: UserDefaults?
    @ObservationIgnored private var permissionWasAnswered = false

    private static let permissionLaunchMarkerKey = "updatePermissionHasLaunched"
    private static let permissionDecisionKey = "updatePermissionDecision"

    override init() {
        super.init()
    }

    func start(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main, defaults: UserDefaults = .standard
    ) {
        let values = try? bundle.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        installationLocation = Self.installationLocation(
            bundleURL: bundle.bundleURL,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            volumeIsReadOnly: values?.volumeIsReadOnly == true)
        let verifiesFeed = environment["POCKET3_UPDATE_CHECK"] != nil
        let isEvidence = CommandLine.arguments.contains("--hardware-validation")
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        if isEvidence, !verifiesFeed, Self.hasValidConfiguration(feed: feed, publicKey: publicKey) {
            statusMessage = "Updates are paused for this validation session."
        }
        let fixture = Self.allowsLoopbackFixture(bundleIdentifier: bundle.bundleIdentifier, feed: feed,
            enabled: environment["POCKET3_UPDATE_FIXTURE"] == "loopback",
            explicitLaunch: CommandLine.arguments.contains("--update-verification"))
        guard controller == nil, (!isEvidence || verifiesFeed), (!verifiesFeed || fixture),
            bundle.bundleURL.pathExtension == "app",
            Self.hasValidConfiguration(feed: feed, publicKey: publicKey)
                || (fixture && publicKey.flatMap { Data(base64Encoded: $0) }?.count == 32)
        else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        canCheckObservation = updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
        automaticCheckObservation = updater.observe(
            \.automaticallyChecksForUpdates, options: [.initial, .new]
        ) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.automaticallyChecksForUpdates = value }
        }
        controller.startUpdater()
        isAvailable = true
        statusMessage = "The updater is ready."

        // Isolated verification has no permission window or ordinary launch
        // bookkeeping. Its bundle disables automatic checks and downloads.
        if verifiesFeed { return }

        permissionDefaults = defaults
        let hasLaunched = defaults.bool(forKey: Self.permissionLaunchMarkerKey)
        let storedDecision = defaults.string(forKey: Self.permissionDecisionKey)
        let previousAutomaticChecks = bundle.bundleIdentifier.flatMap {
            defaults.persistentDomain(forName: $0)?["SUEnableAutomaticChecks"] as? Bool
        }
        let effectiveDecision = Self.effectivePermissionDecision(
            storedDecision: storedDecision,
            previousAutomaticChecks: previousAutomaticChecks)
        if storedDecision == nil, let effectiveDecision {
            // An earlier build may already have asked through Sparkle's stock
            // alert. Import that answer once instead of asking the same person
            // again merely because Pocket 3 Controller now owns the presentation.
            defaults.set(effectiveDecision, forKey: Self.permissionDecisionKey)
        }
        defaults.set(true, forKey: Self.permissionLaunchMarkerKey)
        guard
            Self.shouldPresentPermission(
                hasLaunched: hasLaunched, storedDecision: effectiveDecision)
        else { return }
        Task { @MainActor [weak self] in
            // The first-launch permissions guide owns the initial launch. On a
            // later launch this yield lets SwiftUI finish installing its scene
            // before a second AppKit window is ordered.
            await Task.yield()
            self?.presentPermissionWindow()
        }
    }

    nonisolated static func hasValidConfiguration(feed: String?, publicKey: String?) -> Bool {
        guard let feed, let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              let publicKey, Data(base64Encoded: publicKey)?.count == 32 else { return false }
        return true
    }

    nonisolated static func allowsLoopbackFixture(bundleIdentifier: String?, feed: String?, enabled: Bool, explicitLaunch: Bool) -> Bool {
        guard enabled, explicitLaunch,
              bundleIdentifier?.hasPrefix("studio.yuhuan.Pocket3Bridge.UpdateFixture.") == true,
              let feed, let url = URL(string: feed), url.scheme == "http", url.host == "127.0.0.1",
              let port = url.port, (1024...65535).contains(port), url.user == nil, url.password == nil else { return false }
        return true
    }

    nonisolated static func shouldPresentPermission(
        hasLaunched: Bool, storedDecision: String?
    ) -> Bool {
        hasLaunched && PermissionDecision(rawValue: storedDecision ?? "") == nil
    }

    nonisolated static func effectivePermissionDecision(
        storedDecision: String?, previousAutomaticChecks: Bool?
    ) -> String? {
        if PermissionDecision(rawValue: storedDecision ?? "") != nil {
            return storedDecision
        }
        return previousAutomaticChecks.map {
            $0 ? PermissionDecision.automatic.rawValue : PermissionDecision.manual.rawValue
        }
    }

    /// Authenticates the appcast without downloading or installing an update.
    func verifyFeed(_ completion: @escaping (Error?) -> Void) {
        guard feedVerificationCompletion == nil, let updater = controller?.updater, updater.canCheckForUpdates else {
            completion(AppUpdateError.updaterUnavailable)
            return
        }
        feedSigningStatus = nil
        feedVerificationCompletion = completion
        updater.checkForUpdateInformation()
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        if feedVerificationCompletion != nil { feedSigningStatus = appcast.signingValidationStatus }
    }

    nonisolated static func feedVerificationError(checkError: Error?, signingStatus: SPUAppcastSigningValidationStatus?) -> Error? {
        if let error = checkError as NSError?, !(error.domain == SUSparkleErrorDomain && error.code == 1001) {
            return error
        }
        // SUNoUpdateError says nothing about authenticity. Sparkle may have
        // skipped signature validation or entered its signed-feed fallback.
        guard signingStatus == .succeeded else { return AppUpdateError.feedSignatureUnverified }
        return nil
    }

    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        guard updateCheck == .updateInformation, let completion = feedVerificationCompletion
        else { return }
        feedVerificationCompletion = nil
        completion(Self.feedVerificationError(checkError: error, signingStatus: feedSigningStatus))
    }

    func checkForUpdates() {
        guard let controller else {
            statusMessage = "This development build has no published update source. The latest version cannot be checked."
            return
        }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
        permissionDefaults?.set(
            enabled
                ? PermissionDecision.automatic.rawValue : PermissionDecision.manual.rawValue,
            forKey: Self.permissionDecisionKey)
    }

    private func presentPermissionWindow() {
        guard permissionWindowController == nil else { return }
        let window = UpdatePermissionWindow.make { [weak self] checks, downloads in
            self?.answerPermission(
                checksAutomatically: checks, downloadsAutomatically: downloads)
        }
        window.delegate = self
        let controller = NSWindowController(window: window)
        permissionWindowController = controller
        permissionWasAnswered = false
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func answerPermission(
        checksAutomatically: Bool, downloadsAutomatically: Bool
    ) {
        permissionWasAnswered = true
        recordPermission(
            checksAutomatically: checksAutomatically,
            downloadsAutomatically: downloadsAutomatically)
        permissionWindowController?.close()
    }

    private func recordPermission(
        checksAutomatically: Bool, downloadsAutomatically: Bool
    ) {
        if let updater = controller?.updater {
            updater.automaticallyDownloadsUpdates = downloadsAutomatically
            updater.automaticallyChecksForUpdates = checksAutomatically
        }
        automaticallyChecksForUpdates = checksAutomatically
        permissionDefaults?.set(
            checksAutomatically
                ? PermissionDecision.automatic.rawValue : PermissionDecision.manual.rawValue,
            forKey: Self.permissionDecisionKey)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === permissionWindowController?.window else {
            return
        }
        if !permissionWasAnswered {
            recordPermission(checksAutomatically: false, downloadsAutomatically: false)
        }
        permissionWindowController?.window?.contentViewController = nil
        permissionWindowController = nil
    }

    func openReleases() {
        if let url = Self.releasesURL { NSWorkspace.shared.open(url) }
    }

    func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    func reportIssue(
        bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo
    ) {
        guard let url = Self.issueURL(bundle: bundle, processInfo: processInfo) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated static func installationLocation(
        bundleURL: URL, homeDirectory: URL,
        volumeIsReadOnly: Bool
    ) -> InstallationLocation {
        let path = bundleURL.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return .appTranslocation }
        if volumeIsReadOnly { return .readOnlyVolume }
        if path.hasPrefix("/Applications/") { return .applications }
        let userApplications =
            homeDirectory
            .appending(path: "Applications", directoryHint: .isDirectory)
            .standardizedFileURL.path + "/"
        return path.hasPrefix(userApplications) ? .userApplications : .elsewhere
    }

    /// A report starts with reproducible identity and no machine-owned detail.
    ///
    /// Device names, camera images, questions and diagnostics are deliberately absent.
    /// The person can decide which of those belongs in the issue after GitHub opens.
    static func issueURL(
        bundle: Bundle, processInfo: ProcessInfo
    ) -> URL? {
        let version = Pocket3Product.displayVersion
        let build =
            bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        return issueURL(
            version: version, build: build,
            operatingSystem: processInfo.operatingSystemVersionString,
            title: loc("Pocket 3 Controller problem: "))
    }

    nonisolated static func issueURL(
        version: String, build: String, operatingSystem: String,
        title: String
    ) -> URL? {
        guard let base = (Bundle.main.object(forInfoDictionaryKey: "Pocket3RepositoryURL") as? String),
            let url = URL(string: base)?.appendingPathComponent("issues/new") else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(
                name: "body",
                value: """
                    \(Pocket3Product.displayName): \(version) (\(build))
                    macOS: \(operatingSystem)

                    What happened?


                    What did you expect?


                    How can it be reproduced?

                    """),
        ]
        return components?.url
    }
}

private enum AppUpdateError: LocalizedError {
    case updaterUnavailable
    case feedSignatureUnverified

    var errorDescription: String? {
        switch self {
        case .updaterUnavailable: "The updater is unavailable in this process."
        case .feedSignatureUnverified: "The update feed signature was not verified."
        }
    }
}
