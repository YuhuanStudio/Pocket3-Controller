import AppKit
import Foundation
import SwiftUI
import Testing
import Pocket3Core
@testable import Pocket3BridgeApp

@Suite("USB manual acceptance Diagnostics presentation")
struct USBManualAcceptanceDiagnosticsViewTests {
    private func diagnostics() -> USBManualAcceptanceDiagnostics {
        let old = USBManualAcceptanceBinding(
            deviceID: "device", captureSessionID: "old-session",
            registryID: "registry", bootSessionID: "boot")
        let new = USBManualAcceptanceBinding(
            deviceID: "device", captureSessionID: "new-session",
            registryID: "registry", bootSessionID: "boot")
        let origin = GimbalPosition(pan: 0, tilt: 0)
        let hold = USBManualGimbalHoldMetric(
            axis: .pan, direction: 1, profile: .near,
            inputMagnitude: 0.25, speed: 1, holdDurationSeconds: 0.6,
            origin: origin, samples: [],
            stop: USBManualStopEvidence(
                submitted: true, verified: true, motionStopped: true),
            restore: USBManualRestoreEvidence(
                requested: origin, observed: origin,
                submitted: true, verified: true))
        let zoom = USBManualZoomMetric(
            origin: 100, target: 110, minimum: 0, maximum: 400, step: 1,
            progress: [],
            stop: USBManualStopEvidence(
                submitted: true, verified: true, motionStopped: true,
                heldRaw: 105, finalRaw: 105),
            restore: USBManualZoomRestoreEvidence(
                requestedRaw: 100, observedRaw: 100,
                submitted: true, verified: true))
        let report = USBManualAcceptanceReport(
            initialBinding: old, baselineFrames: [], gimbalHolds: [hold],
            zoom: zoom,
            reconnect: USBManualReconnectFenceMetric(
                oldBinding: old, newBinding: new,
                oldOperationStopped: true, oldOperationSuppressed: true,
                newSessionReady: true),
            finalBinding: new, finalGimbalPosition: origin,
            finalZoomRaw: 100)
        return USBManualAcceptanceDiagnostics(
            report: report, evaluation: USBManualAcceptanceExecutor.evaluate(report))
    }

    @MainActor @Test func developerDisclosureRendersCompactVerificationSummary() throws {
        let renderer = ImageRenderer(content:
            USBManualAcceptanceDiagnosticsView(
                diagnostics: diagnostics(), stage: "completed", failure: nil,
                isExpanded: .constant(true)).frame(width: 560))
        renderer.proposedSize = ProposedViewSize(width: 560, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width <= 560)
        #expect(image.size.height < 500)
    }
}
