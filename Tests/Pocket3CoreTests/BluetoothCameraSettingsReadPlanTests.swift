import Foundation
import Testing
@testable import Pocket3Core

@Suite("Bluetooth camera-settings read plan")
struct BluetoothCameraSettingsReadPlanTests {
    @Test func knownWorkingVideoParametersAreAttemptedFirst() {
        let properties = BluetoothCameraSettingsReadPlan.orderedProperties
        #expect(properties.first == .videoParameters)
        #expect(properties.count <=
                BluetoothCameraSettingsReadPlan.maximumPropertyCount)
        #expect(Set(properties).count == properties.count)
        #expect(Set(properties).isSubset(of: Set(CameraSettingsProperty.allCases)))
    }

    @Test func totalWindowBoundsCurrentAllowlistWithoutChangingPerQueryWindow() {
        #expect(BluetoothCameraSettingsReadPlan.maximumPropertyCount == 11)
        #expect(BluetoothCameraSettingsReadPlan.maximumDuration == 24)
        #expect(BluetoothCameraSettingsReadPlan.maximumDuration >=
                Double(BluetoothCameraSettingsReadPlan.maximumPropertyCount * 2))
    }

    @Test func propertyTimeoutContinuesButCancellationOrSessionChangeStops() throws {
        let binding = ContinuousGimbalBinding(sessionID: "ble-plan", generation: 0)
        var query = try BluetoothCameraPropertyQuery(
            property: .videoParameters, binding: binding, sequence: 7,
            transactionID: 9, startedUptime: 0)
        try query.submitted(at: 0.01)
        let timedOut = query.finish(at: 2.1)
        #expect(!BluetoothCameraSettingsReadPlan.hasTypedReadback(timedOut))
        #expect(BluetoothCameraSettingsReadPlan.shouldContinue(after: timedOut))

        var cancelled = timedOut
        cancelled.cancelled = true
        #expect(!BluetoothCameraSettingsReadPlan.shouldContinue(after: cancelled))
        var changed = timedOut
        changed.connectionChanged = true
        #expect(!BluetoothCameraSettingsReadPlan.shouldContinue(after: changed))
    }
}
