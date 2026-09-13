import Foundation
import Testing
import Pocket3Core
@testable import Pocket3BridgeApp

@Suite("USB Roll release profile presentation")
struct USBRollReleaseProfilePresentationTests {
    @Test func profileMismatchRemainsExplicitlyBlockedInDeveloperReply() throws {
        let request = try USBRollAcceptanceRequest(rawValue: -1,
            moveSeconds: 0.6, pollInterval: 0.08, timeout: 3)
        let report = USBRollAcceptanceExecutor.dryRun(request)
        let evaluation = USBRollAcceptanceExecutor.evaluate(report)
        let payload = try USBRollAcceptanceAppPresentation.payload(
            report: report, evaluation: evaluation,
            rollControlUnlocked: false,
            rollControlUnlockFailure: "roll_acceptance_profile_mismatch")

        #expect(payload["rollControlUnlocked"] == .bool(false))
        #expect(payload["rollControlUnlockFailure"] ==
            .string("roll_acceptance_profile_mismatch"))
        #expect(payload["physicalMotionVerified"] == .bool(false))
        #expect(payload["rollControlProfile"]["rollMinimum"] == .number(-30))
        #expect(payload["rollUnits"].string?.contains("physical Roll angle") == true)
    }

    @Test func profileStillLabelsRollAsRawAndUncalibrated() {
        #expect(USBRollReleaseCapabilityProfile.pocket3Verified
            .rawUnitsDescription.contains("signed UVC raw units"))
    }
}
