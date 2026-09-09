import Foundation
import Testing
@testable import Pocket3Core

@Suite struct NativeControlStatusTests {
    private let binding = ContinuousGimbalBinding(sessionID: "private-connection-id", generation: 8)
    private func ready() -> Pocket3DatalinkStatus {
        var value = Pocket3DatalinkStatus()
        value.phase = .ready; value.binding = binding
        value.lastTelemetryAge = 0.1; value.lastHeartbeatAge = 1
        return value
    }

    @Test func idleReadyHoldingAndPendingPresetsAreDifferentStates() {
        let idle = NativeControlStatus(transport: ready(), expectedBinding: binding, controlsAvailable: true)
        #expect(idle.availability == .ready && idle.activity == .idle && !idle.motionActive)
        let held = NativeControlStatus(transport: ready(), expectedBinding: binding, holding: true, controlsAvailable: true)
        #expect(held.availability == .busy && held.activity == .holding && held.motionActive)
        let preset = NativeControlStatus(transport: ready(), expectedBinding: binding, presetPending: true)
        #expect(preset.activity == .presetPending && preset.motionActive)
        let stopping = NativeControlStatus(transport: ready(), expectedBinding: binding, holding: true, stopping: true, presetPending: true)
        #expect(stopping.activity == .stopping && stopping.motionActive)
    }

    @Test func scheduledLeaseCountsBeforeTheViewReceivesItsHoldingUpdate() {
        let lease = ContinuousGimbalLease(id: UUID(), binding: binding)
        let scheduler = ContinuousGimbalSchedulerStatus(phase: .active, lease: lease, completedCommandSends: 1, lastStop: nil)
        let snapshot = NativeControlStatus(transport: ready(), scheduler: scheduler, expectedBinding: binding)
        #expect(snapshot.activity == .holding && snapshot.motionActive)
        let old = ContinuousGimbalSchedulerStatus(phase: .active,
            lease: .init(id: UUID(), binding: .init(sessionID: "another-connection", generation: 9)),
            completedCommandSends: 1, lastStop: nil)
        let ignored = NativeControlStatus(transport: ready(), scheduler: old, expectedBinding: binding, controlsAvailable: true)
        #expect(ignored.activity == .idle && ignored.availability == .ready)
    }

    @Test func feedbackMustRemainFreshUntilAggregationFinishes() {
        let snapshot = NativeControlStatus(transport: ready(), expectedBinding: binding, controlsAvailable: true, ageAdjustment: 0.3)
        #expect(!snapshot.telemetryFresh && snapshot.heartbeatFresh)
        #expect(snapshot.availability == .staleFeedback)
        var staleHeartbeat = ready(); staleHeartbeat.lastHeartbeatAge = 4
        let heartbeat = NativeControlStatus(transport: staleHeartbeat, expectedBinding: binding, controlsAvailable: true)
        #expect(heartbeat.telemetryFresh && !heartbeat.heartbeatFresh && heartbeat.availability == .staleFeedback)
    }

    @Test func invalidAgesCannotBecomeFreshOrBreakJSONEncoding() throws {
        for invalid in [Double.nan, .infinity, -1] {
            var transport = ready(); transport.lastTelemetryAge = invalid; transport.lastHeartbeatAge = invalid
            let snapshot = NativeControlStatus(transport: transport, expectedBinding: binding, controlsAvailable: true)
            #expect(snapshot.telemetryAgeSeconds == nil && snapshot.heartbeatAgeSeconds == nil)
            #expect(!snapshot.telemetryFresh && !snapshot.heartbeatFresh)
            _ = try JSONEncoder().encode(snapshot)
        }
    }

    @Test func staleBindingAndDisarmedTransportCannotAdvertiseAvailability() {
        let changedBinding = ContinuousGimbalBinding(sessionID: "new-binding", generation: 9)
        let wrong = NativeControlStatus(transport: ready(), expectedBinding: changedBinding, controlsAvailable: true)
        #expect(wrong.availability == .disconnected && !wrong.telemetryFresh && !wrong.heartbeatFresh)
        var disarmed = ready(); disarmed.phase = .disarmed
        let snapshot = NativeControlStatus(transport: disarmed, expectedBinding: binding, controlsAvailable: true)
        #expect(snapshot.availability == .disarmed)
        #expect(NativeControlStatus.connectionChanged.availability == .connectionChanged)
        #expect(!NativeControlStatus.connectionChanged.motionActive)
    }

    @Test func publicStatusOmitsIdentitySecretsFreeformErrorsAndRawPose() throws {
        var transport = ready()
        transport.pairedDeviceID = "private-peripheral-id"
        transport.identityEvidence = "private-network-name"
        transport.lastErrorCode = "private-password-value"
        transport.tcpBootstrapErrorCode = "private-interface-details"
        transport.telemetry = .init(pitchDegrees: 12, rollDegrees: 23, yawDegrees: 34, receivedAt: Date())
        let snapshot = NativeControlStatus(transport: transport, expectedBinding: binding, controlsAvailable: true)
        let encoded = try JSONEncoder().encode(snapshot)
        let text = String(decoding: encoded, as: UTF8.self)
        for secret in [binding.sessionID, "private-peripheral-id", "private-network-name", "private-password-value", "private-interface-details"] {
            #expect(!text.contains(secret))
        }
        let object = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
        #expect(object["telemetry"] == nil && object["binding"] == nil && object["pairedDeviceID"] == nil)
        #expect(!snapshot.automationAvailable && snapshot.usbCameraAssociation == "unverified")
    }

    @Test func nativeStopEvidenceIsSanitizedAndBoundToTheCurrentIdleConnection() throws {
        var transport = ready()
        transport.lastStop = Pocket3DatalinkStopResult(binding: binding, neutralSent: true,
            stableTelemetry: true, sampleCount: 3, stableDurationSeconds: 0.25,
            elapsedSeconds: 0.4, maximumSpanDegrees: 0.1,
            finalTelemetry: .init(pitchDegrees: 12, rollDegrees: 23, yawDegrees: 34, receivedAt: Date()))
        let idle = NativeControlStatus(transport: transport, expectedBinding: binding, controlsAvailable: true)
        #expect(idle.lastStop?.neutralSent == true && idle.lastStop?.stableTelemetry == true)
        #expect(idle.lastStop?.sampleCount == 3)
        let held = NativeControlStatus(transport: transport, expectedBinding: binding, holding: true)
        let pending = NativeControlStatus(transport: transport, expectedBinding: binding, presetPending: true)
        #expect(held.lastStop == nil && pending.lastStop == nil)
        transport.lastStop?.binding = .init(sessionID: "old-peer-session", generation: 2)
        let old = NativeControlStatus(transport: transport, expectedBinding: binding)
        #expect(old.lastStop == nil)

        let contradictory = Pocket3DatalinkStopResult(binding: binding, neutralSent: true,
            stableTelemetry: true, timedOut: true, replacedByNewMotion: true,
            sampleCount: -1, stableDurationSeconds: .nan, elapsedSeconds: .infinity,
            maximumSpanDegrees: -.infinity,
            finalTelemetry: .init(pitchDegrees: 1, rollDegrees: 2, yawDegrees: 3, receivedAt: Date()),
            failure: "private-device-error")
        let safe = NativeControlStopStatus(contradictory)
        #expect(!safe.stableTelemetry && safe.neutralSent && safe.failureReported)
        #expect(safe.sampleCount == 0 && safe.stableDurationSeconds == nil && safe.elapsedSeconds == nil && safe.maximumSpanDegrees == nil)
        let encoded = try JSONEncoder().encode(safe)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains(binding.sessionID) && !text.contains("private-device-error"))
        let object = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
        #expect(object["binding"] == nil && object["finalTelemetry"] == nil && object["failure"] == nil)
    }
}
