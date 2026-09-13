import Foundation
import Testing
@testable import Pocket3Core

@Suite("Bluetooth camera-settings read plan")
struct BluetoothCameraSettingsReadPlanTests {
    private func readinessSnapshot(
        sessionID: UUID, peripheralID: UUID,
        ready: Bool = false
    ) -> BluetoothCameraPropertyReadinessSnapshot {
        BluetoothCameraPropertyReadinessSnapshot(
            sessionID: sessionID, peripheralID: peripheralID,
            phase: ready ? .gattPaired : .subscribing,
            paired: ready,
            registrationAcknowledged: ready,
            centralPoweredOn: ready,
            peripheralConnected: ready,
            fff4NotificationsEnabled: ready,
            fff5NotificationsEnabled: ready,
            fff5CharacteristicNotifying: ready,
            writeWithoutResponse: ready,
            canSendWriteWithoutResponse: ready,
            writeQueueEmpty: ready)
    }

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

    @Test func emptyUnpairedPlanIsNotCompleteAndPreflightFailureIsPartial() {
        let empty = BluetoothCameraSettingsReadSummary(
            routeAvailable: false, issuePresent: false, results: [], failures: [])
        #expect(!empty.completed)
        #expect(!empty.partial)
        #expect(empty.state == .notStarted)
        #expect(empty.attemptedPropertyCount == 0)

        let failure = BluetoothCameraSettingsQueryFailure(
            index: 0, property: .videoParameters,
            expectedSessionID: UUID(), expectedPeripheralID: UUID(),
            code: "bluetooth_probe_busy")
        let partial = BluetoothCameraSettingsReadSummary(
            routeAvailable: true, issuePresent: true, results: [],
            failures: [failure])
        #expect(!partial.completed)
        #expect(partial.partial)
        #expect(partial.state == .partial)
        #expect(partial.attemptedPropertyCount == 1)
    }

    @Test func readinessWaitDistinguishesReadyTimeoutAndSessionChange() {
        let session = UUID(), peer = UUID()
        let waiting = readinessSnapshot(sessionID: session, peripheralID: peer)
        #expect(BluetoothCameraSettingsReadPlan.readinessDecision(
            expectedSessionID: session, expectedPeripheralID: peer,
            snapshot: waiting, now: 0.1, deadline: 0.5) == .wait)
        #expect(BluetoothCameraSettingsReadPlan.readinessDecision(
            expectedSessionID: session, expectedPeripheralID: peer,
            snapshot: readinessSnapshot(sessionID: session, peripheralID: peer,
                                         ready: true), now: 0.1, deadline: 0.5) == .ready)
        #expect(BluetoothCameraSettingsReadPlan.readinessDecision(
            expectedSessionID: session, expectedPeripheralID: peer,
            snapshot: waiting, now: 0.5, deadline: 0.5) == .timeout)
        #expect(BluetoothCameraSettingsReadPlan.readinessDecision(
            expectedSessionID: session, expectedPeripheralID: peer,
            snapshot: readinessSnapshot(sessionID: UUID(), peripheralID: peer),
            now: 0.5, deadline: 0.5) == .sessionChanged)
        #expect(BluetoothCameraSettingsReadPlan.propertyReadinessTimeout == 0.5)
    }
}
