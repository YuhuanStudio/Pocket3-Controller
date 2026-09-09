import Foundation
import Testing
import Sparkle
@testable import Pocket3BridgeApp

@Suite("Application update policy") struct AppUpdateTests {
    @Test func noUpdateDoesNotSubstituteForFeedAuthentication() {
        let current = NSError(domain: SUSparkleErrorDomain, code: 1001)
        for error in [nil, current] {
            #expect(AppUpdateController.feedVerificationError(checkError: error, signingStatus: .succeeded) == nil)
            #expect(AppUpdateController.feedVerificationError(checkError: error, signingStatus: nil) != nil)
            #expect(AppUpdateController.feedVerificationError(checkError: error, signingStatus: .skipped) != nil)
            #expect(AppUpdateController.feedVerificationError(checkError: error, signingStatus: .failed) != nil)
        }
        let downloadFailure = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect((AppUpdateController.feedVerificationError(checkError: downloadFailure, signingStatus: .succeeded) as NSError?) == downloadFailure)
    }
    @Test func loopbackFixtureCannotRelaxProductionTransport() {
        let fixture = "studio.yuhuan.Pocket3Bridge.UpdateFixture.test"
        let local = "http://127.0.0.1:12345/feed.xml"
        #expect(AppUpdateController.allowsLoopbackFixture(bundleIdentifier: fixture, feed: local, enabled: true, explicitLaunch: true))
        #expect(!AppUpdateController.allowsLoopbackFixture(bundleIdentifier: "studio.yuhuan.Pocket3Bridge", feed: local, enabled: true, explicitLaunch: true))
        #expect(!AppUpdateController.allowsLoopbackFixture(bundleIdentifier: fixture, feed: local, enabled: false, explicitLaunch: true))
        #expect(!AppUpdateController.allowsLoopbackFixture(bundleIdentifier: fixture, feed: local, enabled: true, explicitLaunch: false))
        for url in ["http://example.org:12345/feed.xml", "http://localhost:12345/feed.xml", "http://127.0.0.1/feed.xml", "http://user:secret@127.0.0.1:12345/feed.xml"] {
            #expect(!AppUpdateController.allowsLoopbackFixture(bundleIdentifier: fixture, feed: url, enabled: true, explicitLaunch: true))
        }
    }
    @Test func permissionIsAskedOnceOnALaterLaunch() {
        #expect(!AppUpdateController.shouldPresentPermission(hasLaunched: false, storedDecision: nil))
        #expect(AppUpdateController.shouldPresentPermission(hasLaunched: true, storedDecision: nil))
        for answer in ["manual", "automatic"] {
            #expect(!AppUpdateController.shouldPresentPermission(hasLaunched: true, storedDecision: answer))
            #expect(AppUpdateController.effectivePermissionDecision(storedDecision: answer, previousAutomaticChecks: nil) == answer)
        }
        #expect(AppUpdateController.effectivePermissionDecision(storedDecision: nil, previousAutomaticChecks: false) == "manual")
        #expect(AppUpdateController.effectivePermissionDecision(storedDecision: nil, previousAutomaticChecks: true) == "automatic")
    }
    @Test func unconfiguredOrInvalidFeedsCannotStartUpdates() {
        let key = Data(repeating: 42, count: 32).base64EncodedString()
        #expect(AppUpdateController.hasValidConfiguration(feed: "https://example.org/appcast.xml", publicKey: key))
        for feed in [nil, "http://example.org/appcast.xml", "https:", "file:///appcast.xml", "https://user:secret@example.org/appcast.xml"] {
            #expect(!AppUpdateController.hasValidConfiguration(feed: feed, publicKey: key))
        }
        for key in [nil, "", "not-a-key", Data(repeating: 0, count: 31).base64EncodedString()] {
            #expect(!AppUpdateController.hasValidConfiguration(feed: "https://example.org/appcast.xml", publicKey: key))
        }
    }
    @Test func updateLocations() {
        let home = URL(fileURLWithPath: "/Users/person")
        for (path, readOnly, expected) in [
            ("/Applications/Pocket 3 Bridge.app", false, AppUpdateController.InstallationLocation.applications),
            ("/Users/person/Applications/Pocket 3 Bridge.app", false, .userApplications),
            ("/Volumes/Image/Pocket 3 Bridge.app", true, .readOnlyVolume),
            ("/private/AppTranslocation/id/d/Pocket 3 Bridge.app", false, .appTranslocation),
            ("/Applications-copy/Pocket 3 Bridge.app", false, .elsewhere)
        ] {
            #expect(AppUpdateController.installationLocation(bundleURL: URL(fileURLWithPath: path), homeDirectory: home, volumeIsReadOnly: readOnly) == expected)
        }
    }
}
