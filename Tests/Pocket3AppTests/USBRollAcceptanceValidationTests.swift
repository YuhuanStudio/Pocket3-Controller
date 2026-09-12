import Foundation
import Testing
import Pocket3Core
@testable import Pocket3BridgeApp

@Suite("USB Roll acceptance App route")
struct USBRollAcceptanceValidationTests {
    @Test func presentationKeepsDryRunAndPhysicalClaimsExplicit() throws {
        let request = try USBRollAcceptanceRequest(
            rawValue: -18, moveSeconds: 0.6, pollInterval: 0.08,
            timeout: 3, execute: false)
        let report = USBRollAcceptanceExecutor.dryRun(request)
        let evaluation = USBRollAcceptanceExecutor.evaluate(report)
        let payload = try USBRollAcceptanceAppPresentation.payload(
            report: report, evaluation: evaluation)

        #expect(payload["operation"] ==
            .string(USBRollAcceptanceRequest.operation))
        #expect(payload["report"]["phase"] == .string("dry_run"))
        #expect(payload["report"]["plan"]["hardwareExecutionEnabled"] ==
            .bool(false))
        #expect(payload["report"]["cameraImagesStored"] == .bool(false))
        #expect(payload["report"]["physicalMotionVerified"] == .bool(false))
        #expect(payload["evaluation"]["metricsPassed"] == .bool(false))
    }

    @Test func planAdvertisesSignedRangeAndStableStopStages() {
        let plan = USBRollAcceptancePlan()
        #expect(plan.signedRawMinimum == Int(Int16.min))
        #expect(plan.signedRawMaximum == Int(Int16.max))
        #expect(plan.stages.contains("one_signed_raw_move_with_in_flight_progress"))
        #expect(plan.stages.contains("stop_and_stable_roll_readback"))
        #expect(plan.stages.contains("reconnect_old_session_fence"))
        #expect(!plan.hardwareExecutionEnabled && !plan.cameraImagesStored)
    }
}
