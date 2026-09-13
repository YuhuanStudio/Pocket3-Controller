import Foundation
import Testing
@testable import Pocket3Core

@Suite("USB pan/tilt full-range stress metrics")
struct USBPanTiltStressAcceptanceTests {
    private let oldBinding = USBManualAcceptanceBinding(
        deviceID: "0x11000002ca30023", captureSessionID: "capture-old",
        registryID: "registry-1", bootSessionID: "boot-1")
    private let newBinding = USBManualAcceptanceBinding(
        deviceID: "0x11000002ca30023", captureSessionID: "capture-new",
        registryID: "registry-1", bootSessionID: "boot-1")

    private func range() throws -> USBPanTiltStressRange {
        try USBPanTiltStressRange(
            minimum: .init(pan: -10_000, tilt: -8_000),
            center: .init(pan: 0, tilt: 0),
            maximum: .init(pan: 10_000, tilt: 8_000))
    }

    private func plan() throws -> USBPanTiltStressPlan {
        try USBPanTiltStressPlan(range: try range())
    }

    private func frame(_ index: Int, age: TimeInterval = 0.1,
                       sessionID: String = "capture-old")
        -> USBManualFrameEvidence {
        let received = 10 + Double(index) * 0.1
        return USBManualFrameEvidence(
            frameID: "frame-\(index)", sessionID: sessionID,
            deviceID: oldBinding.deviceID, receivedUptime: received,
            sampledUptime: received + age, age: age,
            width: 1920, height: 1080)
    }

    private func trial(
        _ casePlan: USBPanTiltStressCasePlan,
        frameBase: Int = 0,
        finalFraction: Double? = nil,
        range: USBPanTiltStressRange
    ) -> USBPanTiltStressTrial {
        let endFraction = finalFraction ?? casePlan.targetFraction
        let fractions = [endFraction * 0.2, endFraction * 0.6, endFraction]
        let samples = fractions.enumerated().map { index, fraction in
            USBPanTiltStressSample(
                elapsed: 0.2 + Double(index) * 0.4,
                position: range.target(
                    axis: casePlan.axis, direction: casePlan.direction,
                    fraction: fraction),
                frame: frame(frameBase + index),
                phase: "moving", motionActive: true)
        }
        let stopPosition = samples.last!.position
        let stop = USBManualStopEvidence(
            submitted: true, verified: true, motionStopped: true,
            held: stopPosition, final: stopPosition,
            stableSampleCount: 4, stableDurationSeconds: 0.25)
        let restore = USBManualRestoreEvidence(
            requested: range.center, observed: range.center,
            submitted: true, verified: true,
            stableSampleCount: 4, stableDurationSeconds: 0.25)
        return USBPanTiltStressTrial(
            plan: casePlan, origin: range.center,
            holdDurationSeconds: 1.0, samples: samples,
            stop: stop, restore: restore)
    }

    private func report(
        trials: [USBPanTiltStressTrial]? = nil,
        baselineFrames: [USBManualFrameEvidence]? = nil,
        reconnect: USBManualReconnectFenceMetric? = nil,
        finalPosition: GimbalPosition? = nil,
        cameraImagesStored: Bool = false,
        physicalMotionVerified: Bool = false
    ) throws -> USBPanTiltStressReport {
        let r = try range()
        let p = try USBPanTiltStressPlan(range: r)
        let defaultTrials = p.cases.enumerated().map { index, casePlan in
            trial(casePlan, frameBase: index * 3, range: r)
        }
        return USBPanTiltStressReport(
            plan: p, initialBinding: oldBinding,
            baselineFrames: baselineFrames ?? [frame(100), frame(101), frame(102)],
            trials: trials ?? defaultTrials,
            reconnect: reconnect ?? USBManualReconnectFenceMetric(
                oldBinding: oldBinding, newBinding: newBinding,
                oldOperationStopped: true, oldOperationSuppressed: true,
                newSessionReady: true),
            finalBinding: newBinding,
            finalPosition: finalPosition ?? r.center,
            cameraImagesStored: cameraImagesStored,
            physicalMotionVerified: physicalMotionVerified,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func planCoversBothAxesDirectionsAndRawEndpoints() throws {
        let r = try range()
        let p = try plan()
        #expect(p.version == USBPanTiltStressPlan.currentVersion)
        #expect(p.profile == USBPanTiltStressPlan.currentProfile)
        #expect(p.cases.count == 16)
        #expect(Set(p.cases.map(\.id)).count == 16)
        #expect(Set(p.cases.map(\.axis)) == [.pan, .tilt])
        #expect(Set(p.cases.map(\.direction)) == [.negative, .positive])
        #expect(Set(p.cases.map(\.distanceBand)) ==
                [.near, .middle, .far, .limit])
        #expect(!p.hardwareExecutionEnabled && !p.cameraImagesStored)
        #expect(p.maximumHoldSeconds == 1.2 &&
                p.maximumExecutionSeconds == 60)
        #expect(p.stages.contains("distance_to_speed_metrics"))
        #expect(p.stages.contains("moving_stop_stable_window"))
        #expect(p.stages.contains("reconnect_old_session_fence"))

        for axis in USBPanTiltStressAxis.allCases {
            let negativeLimit = try #require(p.cases.first {
                $0.axis == axis && $0.direction == .negative &&
                    $0.distanceBand == .limit
            })
            let positiveLimit = try #require(p.cases.first {
                $0.axis == axis && $0.direction == .positive &&
                    $0.distanceBand == .limit
            })
            #expect(negativeLimit.target == r.target(
                axis: axis, direction: .negative, fraction: 1))
            #expect(positiveLimit.target == r.target(
                axis: axis, direction: .positive, fraction: 1))
        }

        var encoded = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(p)) as? [String: Any])
        encoded["hardwareExecutionEnabled"] = true
        #expect(throws: USBPanTiltStressAcceptanceError.invalidPlan) {
            try JSONDecoder().decode(
                USBPanTiltStressPlan.self,
                from: JSONSerialization.data(withJSONObject: encoded))
        }

        var alteredCases = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(p)) as? [String: Any])
        alteredCases["cases"] = []
        #expect(throws: USBPanTiltStressAcceptanceError.invalidPlan) {
            try JSONDecoder().decode(
                USBPanTiltStressPlan.self,
                from: JSONSerialization.data(withJSONObject: alteredCases))
        }
    }

    @Test func completeMetricsPassSpeedStopRestoreAndFenceWithoutPhysicalClaim()
        throws {
        let value = try report()
        let evaluation = USBPanTiltStressAcceptance.evaluate(value)
        #expect(evaluation.metricsPassed)
        #expect(evaluation.failureCode == nil)
        #expect(evaluation.checks["full_range_matrix"] == true)
        #expect(evaluation.checks["speed_follows_input_distance"] == true)
        #expect(evaluation.checks["stop_and_restore"] == true)
        #expect(evaluation.checks["reconnect_session_fence"] == true)
        #expect(!evaluation.cameraImagesStored)
        #expect(!evaluation.physicalMotionVerified)
        #expect(evaluation.remainingPhysicalSteps.count == 4)

        let decoded = try JSONDecoder().decode(
            USBPanTiltStressReport.self,
            from: JSONEncoder().encode(value))
        #expect(decoded == value)
        let decodedEvaluation = try JSONDecoder().decode(
            USBPanTiltStressEvaluation.self,
            from: JSONEncoder().encode(evaluation))
        #expect(decodedEvaluation == evaluation)
    }

    @Test func speedMetricRejectsFarInputThatDoesNotOutrunNearInput() throws {
        let r = try range()
        let p = try plan()
        let trials = p.cases.enumerated().map { index, casePlan in
            if casePlan.axis == .pan && casePlan.direction == .positive &&
                casePlan.distanceBand == .far {
                return trial(casePlan, frameBase: index * 3,
                             finalFraction: 0.30, range: r)
            }
            return trial(casePlan, frameBase: index * 3, range: r)
        }
        let evaluation = USBPanTiltStressAcceptance.evaluate(
            try report(trials: trials))
        #expect(!evaluation.metricsPassed)
        #expect(evaluation.checks["fresh_monotonic_samples"] == true)
        #expect(evaluation.checks["speed_follows_input_distance"] == false)
        #expect(evaluation.failureCode == "speed_follows_input_distance")
    }

    @Test func endpointAndSafetyChecksFailClosed() throws {
        let r = try range()
        let p = try plan()
        var missingEndpoint = p.cases.enumerated().map { index, casePlan in
            let fraction: Double? = casePlan.distanceBand == .limit &&
                casePlan.axis == .tilt && casePlan.direction == .negative
                ? 0.80 : nil
            return trial(casePlan, frameBase: index * 3,
                         finalFraction: fraction, range: r)
        }
        let endpointReport = try report(trials: missingEndpoint)
        let endpointEvaluation = USBPanTiltStressAcceptance.evaluate(endpointReport)
        #expect(!endpointEvaluation.metricsPassed)
        #expect(endpointEvaluation.checks["limit_targets_reached"] == false)

        missingEndpoint[0] = trial(p.cases[0], range: r)
        let staleReport = try report(
            trials: missingEndpoint,
            baselineFrames: [frame(100, age: 1.01), frame(101), frame(102)])
        let staleEvaluation = USBPanTiltStressAcceptance.evaluate(staleReport)
        #expect(!staleEvaluation.metricsPassed)
        #expect(staleEvaluation.checks["fresh_center_baseline"] == false)

        let unsafeReport = try report(
            cameraImagesStored: true, physicalMotionVerified: true)
        let unsafeEvaluation = USBPanTiltStressAcceptance.evaluate(unsafeReport)
        #expect(!unsafeEvaluation.metricsPassed)
        #expect(unsafeEvaluation.checks["metrics_only"] == false)
    }

    @Test func stopRestoreAndReconnectEvidenceCannotBeOmitted() throws {
        let r = try range()
        let p = try plan()
        var trials = p.cases.map { trial($0, range: r) }
        let first = trials[0]
        trials[0] = USBPanTiltStressTrial(
            plan: p.cases[0], origin: first.origin,
            holdDurationSeconds: first.holdDurationSeconds,
            samples: first.samples,
            stop: .init(submitted: true, verified: false,
                        motionStopped: false, held: first.stop.held,
                        final: first.stop.final),
            restore: first.restore)
        let noStop = USBPanTiltStressAcceptance.evaluate(
            try report(trials: trials))
        #expect(!noStop.metricsPassed)
        #expect(noStop.checks["stop_and_restore"] == false)

        let brokenFence = USBManualReconnectFenceMetric(
            oldBinding: oldBinding, newBinding: newBinding,
            oldOperationStopped: true, oldOperationSuppressed: false,
            newSessionReady: true)
        let fenceEvaluation = USBPanTiltStressAcceptance.evaluate(
            try report(reconnect: brokenFence))
        #expect(!fenceEvaluation.metricsPassed)
        #expect(fenceEvaluation.checks["reconnect_session_fence"] == false)
    }
}
