import Foundation
import Testing
import Pocket3Core
@testable import Pocket3BridgeApp

@Suite(.serialized)
struct ManualControlAcceptanceHarnessTests {
    @MainActor @Test func disabledHarnessNeverClaimsHardwareExecution() async {
        let result = await ManualControlAcceptanceHarness.run(developerMode: false)
        #expect(result.developerOnly)
        #expect(!result.hardwareExecuted)
        #expect(!result.passed)
        #expect(result.failureCode == "developer_mode_required")
    }

    @MainActor @Test func injectedHarnessExercisesEveryOwnershipFence() async {
        let result = await ManualControlAcceptanceHarness.run(developerMode: true)
        #expect(result.developerOnly)
        #expect(!result.hardwareExecuted)
        #expect(result.mappingPassed)
        #expect(result.nearCommandOffset != nil)
        #expect(result.farCommandOffset != nil)
        #expect(result.farCommandOffset! > result.nearCommandOffset!)

        #expect(result.mouseRelease.trigger == "mouse_release")
        #expect(result.mouseRelease.stopReason == .released)
        #expect(result.mouseRelease.neutralSent)
        #expect(result.keyRelease.trigger == "key_release")
        #expect(result.keyRelease.stopReason == .released)
        #expect(result.explicitStop.stopReason == .cancelled)
        #expect(result.focusLoss.stopReason == .focusLost)
        #expect(result.accessTakeover.stopReason == .cancelled)

        #expect(result.reconnect.oldStopReason == .cancelled)
        #expect(result.reconnect.oldNeutralSent)
        #expect(result.reconnect.oldSchedulerIdle)
        #expect(result.reconnect.newSessionStarted)
        #expect(result.reconnect.staleOldGestureDidNotStopNew)
        #expect(result.passed)
        #expect(result.failureCode == nil)
    }
}
