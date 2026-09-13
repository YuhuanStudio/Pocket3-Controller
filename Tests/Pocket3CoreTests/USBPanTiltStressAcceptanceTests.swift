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

    @Test func requestRequiresIdentityAndExactRangeOnlyForExecution() throws {
        let range = try range()
        let dry = try USBPanTiltStressRequest(cliArguments: [
            "--minimum-pan", "-10000", "--minimum-tilt", "-8000",
            "--center-pan", "0", "--center-tilt", "0",
            "--maximum-pan", "10000", "--maximum-tilt", "8000"
        ])
        #expect(!dry.execute && dry.declaredRange == range)
        #expect(try JSONDecoder().decode(
            USBPanTiltStressRequest.self,
            from: JSONEncoder().encode(dry)) == dry)
        #expect(throws: USBPanTiltStressRequestError.identityRequired) {
            try USBPanTiltStressRequest(declaredRange: range, execute: true)
        }
        #expect(throws: USBPanTiltStressRequestError.rangeRequired) {
            try USBPanTiltStressRequest(
                expectedDeviceID: "device", expectedSessionID: "session",
                execute: true)
        }
        #expect(throws: USBPanTiltStressRequestError.invalidArguments) {
            try USBPanTiltStressRequest(cliArguments: [
                "--minimum-pan", "-1"
            ])
        }
    }

    @Test func executorRunsAllSixteenCasesAndCleansUpThroughAdapter()
        async throws {
        let range = try range()
        let request = try USBPanTiltStressRequest(
            expectedDeviceID: oldBinding.deviceID,
            expectedSessionID: oldBinding.captureSessionID,
            declaredRange: range, holdSeconds: 0.6,
            pollInterval: 0.05, timeout: 15, execute: true)
        let state = USBPanTiltStressFakeState(range: range,
                                              old: oldBinding,
                                              new: newBinding)
        let clock = USBPanTiltStressTestClock()
        let adapter = USBPanTiltStressExecutorAdapter(
            read: { state.read(clock: clock) },
            startMove: { target, _ in
                let token = state.begin(target)
                return Task {
                    while !state.stopped(token) {
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    throw CancellationError()
                }
            },
            stop: {
                state.stop()
                let position = state.position
                return USBManualStopEvidence(
                    submitted: true, verified: true, motionStopped: true,
                    held: position, final: position,
                    stableSampleCount: 4, stableDurationSeconds: 0.25)
            },
            restore: { origin, _ in
                state.restore(origin)
                return USBManualRestoreEvidence(
                    requested: origin, observed: origin,
                    submitted: true, verified: true,
                    stableSampleCount: 4, stableDurationSeconds: 0.25)
            },
            reconnect: { old, _ in
                #expect(old == oldBinding)
                state.reconnect()
                return USBManualReconnectFenceMetric(
                    oldBinding: oldBinding, newBinding: newBinding,
                    oldOperationStopped: true,
                    oldOperationSuppressed: true,
                    newSessionReady: true)
            },
            cleanup: { true })

        let report = await USBPanTiltStressAcceptance.execute(
            request, adapter: adapter, clock: clock)
        let evaluation = USBPanTiltStressAcceptance.evaluate(report)
        #expect(report.completed && report.phase == "completed")
        #expect(report.trials.count == 16)
        #expect(report.finalRestore?.verified == true)
        #expect(report.cleanupAttempted && report.cleanupSucceeded)
        #expect(evaluation.metricsPassed)
        #expect(state.moves == 16)
        #expect(state.stops == 16)
        #expect(state.restores == 17) // 16 per-case restores plus final centre
        #expect(state.reconnects == 1)
        #expect(!report.cameraImagesStored && !report.physicalMotionVerified)
    }
}

private final class USBPanTiltStressTestClock: ContinuousGimbalClock,
    @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 10
    var now: TimeInterval { lock.withLock { time } }
    func sleep(until deadline: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock { time = max(time, deadline) }
        await Task.yield()
    }
}

private final class USBPanTiltStressFakeState: @unchecked Sendable {
    private let lock = NSLock()
    private let range: USBPanTiltStressRange
    private let old: USBManualAcceptanceBinding
    private let new: USBManualAcceptanceBinding
    private var binding: USBManualAcceptanceBinding
    private var currentPosition: GimbalPosition
    private var target: GimbalPosition?
    private var moveReads = 0
    private var token = 0
    private var stoppedTokens = Set<Int>()
    private var nextFrame = 0
    private(set) var moves = 0
    private(set) var stops = 0
    private(set) var restores = 0
    private(set) var reconnects = 0

    init(range: USBPanTiltStressRange,
         old: USBManualAcceptanceBinding,
         new: USBManualAcceptanceBinding) {
        self.range = range; self.old = old; self.new = new
        binding = old; currentPosition = range.center
    }

    func begin(_ target: GimbalPosition) -> Int {
        lock.withLock {
            moves += 1; self.target = target; moveReads = 0
            token += 1; return token
        }
    }

    func stopped(_ token: Int) -> Bool {
        lock.withLock { stoppedTokens.contains(token) }
    }

    func stop() {
        lock.withLock {
            stops += 1
            if let target {
                currentPosition = target
            }
            target = nil
            stoppedTokens.insert(token)
        }
    }

    func restore(_ value: GimbalPosition) {
        lock.withLock { restores += 1; currentPosition = value; target = nil }
    }

    func reconnect() {
        lock.withLock { reconnects += 1; binding = new; currentPosition = range.center }
    }

    var position: GimbalPosition { lock.withLock { currentPosition } }

    func read(clock: USBPanTiltStressTestClock)
        -> USBPanTiltStressHardwareObservation {
        lock.withLock {
            if let target {
                moveReads += 1
                let fraction = min(1, Double(moveReads) / 3)
                currentPosition = GimbalPosition(
                    pan: Int32((Double(range.center.pan) +
                        Double(Int64(target.pan) - Int64(range.center.pan)) *
                        fraction).rounded()),
                    tilt: Int32((Double(range.center.tilt) +
                        Double(Int64(target.tilt) - Int64(range.center.tilt)) *
                        fraction).rounded()))
            }
            nextFrame += 1
            let now = clock.now
            let frame = USBManualFrameEvidence(
                frameID: "stress-frame-\(nextFrame)",
                sessionID: binding.captureSessionID,
                deviceID: binding.deviceID,
                receivedUptime: now - 0.01,
                sampledUptime: now, age: 0.01,
                width: 1920, height: 1080)
            let moving = target != nil
            let caps = UVCCapabilities(
                location: 1, position: currentPosition,
                minimum: range.minimum, maximum: range.maximum,
                step: .init(pan: 3600, tilt: 3600), writable: true,
                controls: ["pan-tilt-abs"], uvcVersion: 256,
                registryID: binding.registryID,
                bootSessionID: binding.bootSessionID)
            return USBPanTiltStressHardwareObservation(
                binding: binding, capabilities: caps, frame: frame,
                sampledUptime: now,
                phase: moving ? "moving" : "ready", motionActive: moving)
        }
    }
}
