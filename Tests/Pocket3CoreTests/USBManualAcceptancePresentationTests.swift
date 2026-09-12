import Foundation
import Testing
@testable import Pocket3Core

@Suite("USB manual acceptance diagnostics projection")
struct USBManualAcceptancePresentationTests {
    private let oldBinding = USBManualAcceptanceBinding(
        deviceID: "device", captureSessionID: "capture-old",
        registryID: "registry", bootSessionID: "boot")
    private let newBinding = USBManualAcceptanceBinding(
        deviceID: "device", captureSessionID: "capture-new",
        registryID: "registry", bootSessionID: "boot")

    private func hold(axis: USBManualAcceptanceAxis,
                      stopVerified: Bool,
                      restoreVerified: Bool) -> USBManualGimbalHoldMetric {
        let origin = GimbalPosition(pan: 0, tilt: 0)
        return USBManualGimbalHoldMetric(
            axis: axis, direction: 1, profile: .near,
            inputMagnitude: USBManualGimbalControlMapping.nearInputMagnitude,
            speed: 1, holdDurationSeconds: 0.6, origin: origin, samples: [],
            stop: USBManualStopEvidence(
                submitted: stopVerified, verified: stopVerified,
                motionStopped: stopVerified),
            restore: USBManualRestoreEvidence(
                requested: origin, observed: origin,
                submitted: restoreVerified, verified: restoreVerified))
    }

    private func report() -> USBManualAcceptanceReport {
        let zoom = USBManualZoomMetric(
            origin: 100, target: 110, minimum: 0, maximum: 400, step: 1,
            progress: [],
            stop: USBManualStopEvidence(
                submitted: true, verified: true, motionStopped: true,
                heldRaw: 105, finalRaw: 105),
            restore: USBManualZoomRestoreEvidence(
                requestedRaw: 100, observedRaw: 100,
                submitted: true, verified: true))
        return USBManualAcceptanceReport(
            initialBinding: oldBinding, baselineFrames: [],
            gimbalHolds: [hold(axis: .pan, stopVerified: true,
                               restoreVerified: true),
                          hold(axis: .tilt, stopVerified: false,
                               restoreVerified: true)],
            zoom: zoom,
            reconnect: USBManualReconnectFenceMetric(
                oldBinding: oldBinding, newBinding: newBinding,
                oldOperationStopped: true, oldOperationSuppressed: true,
                newSessionReady: true),
            finalBinding: newBinding, finalGimbalPosition: .init(pan: 0, tilt: 0),
            finalZoomRaw: 100)
    }

    @Test func projectionKeepsOnlyVerificationAndFenceSummary() {
        let report = report()
        let evaluation = USBManualAcceptanceExecutor.evaluate(report)
        let diagnostics = USBManualAcceptanceDiagnostics(
            report: report, evaluation: evaluation)

        #expect(diagnostics.gimbalHoldCount == 2)
        #expect(diagnostics.gimbalStopVerifiedCount == 1)
        #expect(diagnostics.gimbalRestoreVerifiedCount == 2)
        #expect(diagnostics.zoomStopVerified)
        #expect(diagnostics.zoomRestoreVerified)
        #expect(diagnostics.reconnectSessionChanged)
        #expect(diagnostics.oldSessionSuppressed)
        #expect(diagnostics.newSessionReady)
        #expect(diagnostics.initialSessionID == "capture-old")
        #expect(diagnostics.finalSessionID == "capture-new")
        #expect(!diagnostics.cameraImagesStored)
        #expect(!diagnostics.physicalMotionVerified)
        #expect(!diagnostics.metricsPassed)
    }

    @Test func mappingMatchesNearFarCurveAndDeadZone() {
        let near = USBManualGimbalControlMapping.nearInputMagnitude
        let far = USBManualGimbalControlMapping.farInputMagnitude
        let nearRate = USBManualGimbalControlMapping.rateFraction(
            inputMagnitude: near, speed: 1)
        let farRate = USBManualGimbalControlMapping.rateFraction(
            inputMagnitude: far, speed: 1)

        #expect(USBManualGimbalControlMapping.magnitude(x: near, y: 0) == near)
        #expect(USBManualGimbalControlMapping.magnitude(x: 0, y: -far) == far)
        #expect(nearRate != nil && farRate != nil && farRate! > nearRate!)
        #expect(USBManualGimbalControlMapping.rateFraction(
            inputMagnitude: USBManualGimbalControlMapping.deadZone,
            speed: 1) == 0)
        #expect(USBManualGimbalControlMapping.magnitude(x: .infinity, y: 0) == nil)
    }

    @Test func trajectoryUsesTheSameCurveAsAcceptanceProfiles() throws {
        let capabilities = UVCCapabilities(
            location: 1, position: .init(pan: 0, tilt: 0),
            minimum: .init(pan: -20_000, tilt: -20_000),
            maximum: .init(pan: 20_000, tilt: 20_000),
            step: .init(pan: 1, tilt: 1), writable: true,
            controls: ["pan", "tilt"], uvcVersion: 1,
            registryID: "registry", bootSessionID: "boot")
        let configuration = USBPositionTrajectory.Configuration(
            maximumRate: 36_000, acceleration: 1_000_000,
            maximumLead: 7_200, maximumFeedbackAge: 0.25,
            maximumTickGap: 0.15)
        var near = try USBPositionTrajectory(
            capabilities: capabilities, now: 10, configuration: configuration)
        var far = try USBPositionTrajectory(
            capabilities: capabilities, now: 10, configuration: configuration)
        let origin = capabilities.position
        let nearTarget = try near.advance(
            x: USBManualGimbalControlMapping.nearInputMagnitude, y: 0,
            speed: 1, now: 10.05, observed: origin, observedAt: 10)
        let farTarget = try far.advance(
            x: USBManualGimbalControlMapping.farInputMagnitude, y: 0,
            speed: 1, now: 10.05, observed: origin, observedAt: 10)

        #expect(farTarget.pan > nearTarget.pan)
        #expect(farTarget.tilt == nearTarget.tilt)
    }
}
