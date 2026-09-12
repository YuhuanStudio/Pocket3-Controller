import Foundation
import Testing
@testable import Pocket3Core

@Suite("USB manual gimbal and zoom acceptance metrics")
struct USBManualAcceptanceMetricsTests {
    private let oldBinding = USBManualAcceptanceBinding(
        deviceID: "device-1", captureSessionID: "capture-1",
        registryID: "registry-1", bootSessionID: "boot-1")
    private let newBinding = USBManualAcceptanceBinding(
        deviceID: "device-1", captureSessionID: "capture-2",
        registryID: "registry-2", bootSessionID: "boot-2")

    private func frame(_ index: Int, age: TimeInterval = 0.1,
                       sessionID: String = "capture-1") -> USBManualFrameEvidence {
        USBManualFrameEvidence(
            frameID: "frame-\(index)", sessionID: sessionID,
            deviceID: "device-1", receivedUptime: 10 + Double(index) * 0.1,
            sampledUptime: 10 + Double(index) * 0.1 + age,
            age: age, width: 1920, height: 1080)
    }

    private func hold(
        _ axis: USBManualAcceptanceAxis,
        profile: USBManualAcceptanceProfile,
        direction: Int,
        nearTravel: Int32,
        inputMagnitude: Double
    ) -> USBManualGimbalHoldMetric {
        let origin = GimbalPosition(pan: 0, tilt: 0)
        let rawDirection = Int32(direction)
        let final: GimbalPosition
        if axis == .pan {
            final = .init(pan: rawDirection * nearTravel, tilt: 0)
        } else {
            final = .init(pan: 0, tilt: rawDirection * nearTravel)
        }
        let first = axis == .pan
            ? GimbalPosition(pan: rawDirection * 360, tilt: 0)
            : GimbalPosition(pan: 0, tilt: rawDirection * 360)
        let middle = axis == .pan
            ? GimbalPosition(pan: rawDirection * 540, tilt: 0)
            : GimbalPosition(pan: 0, tilt: rawDirection * 540)
        let samples = [first, middle, final].enumerated().map { index, position in
            USBManualPositionSample(
                elapsed: 0.15 + Double(index) * 0.2,
                position: position, frame: frame(index), phase: "moving",
                motionActive: true)
        }
        return USBManualGimbalHoldMetric(
            axis: axis, direction: direction, profile: profile,
            inputMagnitude: inputMagnitude, speed: 1,
            holdDurationSeconds: 0.6, origin: origin, samples: samples,
            stop: USBManualStopEvidence(
                submitted: true, verified: true, motionStopped: true,
                held: final, final: final, stableSampleCount: 3,
                stableDurationSeconds: 0.2),
            restore: USBManualRestoreEvidence(
                requested: origin, observed: origin, submitted: true,
                verified: true, stableSampleCount: 3,
                stableDurationSeconds: 0.2))
    }

    private func report() -> USBManualAcceptanceReport {
        let panNear = hold(.pan, profile: .near, direction: 1,
                           nearTravel: 720, inputMagnitude: 0.25)
        let panFar = hold(.pan, profile: .far, direction: 1,
                          nearTravel: 1_440, inputMagnitude: 0.8)
        let tiltNear = hold(.tilt, profile: .near, direction: -1,
                            nearTravel: 720, inputMagnitude: 0.25)
        let tiltFar = hold(.tilt, profile: .far, direction: -1,
                           nearTravel: 1_440, inputMagnitude: 0.8)
        let progress = [110, 120, 130].enumerated().map { index, value in
            USBManualZoomProgressSample(
                elapsed: 0.2 + Double(index) * 0.2, current: value,
                frame: frame(10 + index), phase: "moving", motionActive: true)
        }
        let zoom = USBManualZoomMetric(
            origin: 100, target: 200, minimum: 0, maximum: 400, step: 1,
            progress: progress,
            stop: USBManualStopEvidence(
                submitted: true, verified: true, motionStopped: true,
                held: .init(pan: 130, tilt: 0),
                final: .init(pan: 130, tilt: 0), stableSampleCount: 3,
                stableDurationSeconds: 0.8),
            restore: USBManualZoomRestoreEvidence(
                requestedRaw: 100, observedRaw: 100, submitted: true,
                verified: true, stableSampleCount: 3,
                stableDurationSeconds: 0.8))
        return USBManualAcceptanceReport(
            initialBinding: oldBinding,
            baselineFrames: [frame(100), frame(101), frame(102)],
            gimbalHolds: [panNear, panFar, tiltNear, tiltFar], zoom: zoom,
            reconnect: USBManualReconnectFenceMetric(
                oldBinding: oldBinding, newBinding: newBinding,
                oldOperationStopped: true, oldOperationSuppressed: true,
                newSessionReady: true),
            finalBinding: newBinding,
            finalGimbalPosition: .init(pan: 0, tilt: 0), finalZoomRaw: 100)
    }

    @Test func dryRunPlanIsBoundedAndCannotEnableHardware() throws {
        let plan = USBManualAcceptanceExecutor.dryRunPlan()
        #expect(plan.version == USBManualAcceptanceReport.currentVersion)
        #expect(plan.profile == USBManualAcceptanceReport.currentProfile)
        #expect(plan.hardwareExecutionEnabled == false)
        #expect(plan.maximumHoldSeconds <= 1.2)
        #expect(plan.maximumZoomProgressSamples == 24)
        #expect(plan.stages.contains("pan_near_continuous_hold"))
        #expect(plan.stages.contains("reconnect_old_session_fence"))
    }

    @Test func completeMetricsReportPassesWithoutClaimingPhysicalMotion() throws {
        let evaluation = USBManualAcceptanceExecutor.evaluate(report())
        #expect(evaluation.metricsPassed)
        #expect(evaluation.failureCode == nil)
        #expect(!evaluation.cameraImagesStored)
        #expect(!evaluation.physicalMotionVerified)
        #expect(evaluation.remainingPhysicalSteps.count == 5)
    }

    @Test func staleFrameOrMissingStopEvidenceFailsClosed() throws {
        var stale = report()
        stale.baselineFrames[0] = frame(100, age: 1.01)
        let staleResult = USBManualAcceptanceExecutor.evaluate(stale)
        #expect(!staleResult.metricsPassed)
        #expect(staleResult.checks["fresh_baseline_frames"] == false)

        var noStop = report()
        let first = noStop.gimbalHolds[0]
        noStop.gimbalHolds[0] = USBManualGimbalHoldMetric(
            id: first.id, axis: first.axis, direction: first.direction,
            profile: first.profile, inputMagnitude: first.inputMagnitude,
            speed: first.speed, holdDurationSeconds: first.holdDurationSeconds,
            origin: first.origin, samples: first.samples,
            stop: .init(submitted: true, verified: false,
                        motionStopped: false, held: first.stop.held,
                        final: first.stop.final), restore: first.restore)
        let noStopResult = USBManualAcceptanceExecutor.evaluate(noStop)
        #expect(!noStopResult.metricsPassed)
        #expect(noStopResult.checks["gimbal_hold_matrix"] == false)
    }

    @Test func speedReconnectZoomAndRestoreChecksRejectContradictoryMetrics() throws {
        var slowFar = report()
        let far = slowFar.gimbalHolds[1]
        slowFar.gimbalHolds[1] = USBManualGimbalHoldMetric(
            id: far.id, axis: far.axis, direction: far.direction,
            profile: far.profile, inputMagnitude: 0.2,
            speed: far.speed, holdDurationSeconds: far.holdDurationSeconds,
            origin: far.origin,
            samples: far.samples, stop: far.stop, restore: far.restore)
        #expect(!USBManualAcceptanceExecutor.evaluate(slowFar).metricsPassed)

        var reconnect = report()
        reconnect.reconnect = USBManualReconnectFenceMetric(
            oldBinding: oldBinding, newBinding: oldBinding,
            oldOperationStopped: true, oldOperationSuppressed: false,
            newSessionReady: true)
        #expect(!USBManualAcceptanceExecutor.evaluate(reconnect).metricsPassed)

        var zoom = report()
        zoom.zoom = USBManualZoomMetric(
            origin: 100, target: 200, minimum: 0, maximum: 400, step: 1,
            progress: [USBManualZoomProgressSample(
                elapsed: 0.2, current: 200, frame: frame(20),
                phase: "moving", motionActive: true)],
            stop: zoom.zoom.stop, restore: zoom.zoom.restore)
        #expect(!USBManualAcceptanceExecutor.evaluate(zoom).metricsPassed)

        var restored = report()
        restored.finalZoomRaw = 110
        #expect(!USBManualAcceptanceExecutor.evaluate(restored).metricsPassed)
    }

    @Test func metricsReportRoundTripsAsBoundedJSON() throws {
        let value = report()
        let decoded = try JSONDecoder().decode(
            USBManualAcceptanceReport.self,
            from: JSONEncoder().encode(value))
        #expect(decoded == value)
        let evaluation = USBManualAcceptanceExecutor.evaluate(decoded)
        let decodedEvaluation = try JSONDecoder().decode(
            USBManualAcceptanceEvaluation.self,
            from: JSONEncoder().encode(evaluation))
        #expect(decodedEvaluation == evaluation)
    }
}
