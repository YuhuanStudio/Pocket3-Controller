import Foundation
import Testing
@testable import Pocket3Core

@Suite("USB Roll moving-stop acceptance")
struct USBRollAcceptanceTests {
    private let deviceID = "roll-acceptance-device"
    private let sessionID = "roll-acceptance-session"

    @Test func requestKeepsSignedRawAndDryRunIsNonOperational() throws {
        let dry = try USBRollAcceptanceRequest(cliArguments: [])
        #expect(!dry.execute && dry.rawValue == nil)
        #expect(USBRollAcceptanceExecutor.dryRun(dry).phase == "dry_run")

        let request = try USBRollAcceptanceRequest(cliArguments: [
            "--device", deviceID, "--session", sessionID,
            "--raw", "-18", "--move-seconds", "0.6",
            "--poll-interval", "0.08", "--timeout", "3", "--execute"
        ])
        #expect(request.execute && request.rawValue == -18)
        #expect(request.expectedDeviceID == deviceID &&
                request.expectedSessionID == sessionID)
        let decoded = try JSONDecoder().decode(
            USBRollAcceptanceRequest.self,
            from: JSONEncoder().encode(request))
        #expect(decoded == request)

        for value in [-32769, 32768, -18.5] {
            #expect(throws: USBRollAcceptanceRequestError.invalidRawValue) {
                try USBRollAcceptanceRequest(arguments: .object([
                    "rawValue": .number(value)
                ]))
            }
        }
        #expect(throws: USBRollAcceptanceRequestError.identityRequired) {
            try USBRollAcceptanceRequest(execute: true)
        }
    }

    @Test func targetSelectionUsesFreshSignedRangeAndAdvertisedStep() throws {
        let baseline = rollTestCapabilities(current: -20)
        #expect(try USBRollAcceptanceExecutor.targetRaw(nil, baseline: baseline) == -18)
        #expect(try USBRollAcceptanceExecutor.targetRaw(-18, baseline: baseline) == -18)
        #expect(throws: BridgeFailure.self) {
            try USBRollAcceptanceExecutor.targetRaw(-20, baseline: baseline)
        }
        #expect(throws: BridgeFailure.self) {
            try USBRollAcceptanceExecutor.targetRaw(-19, baseline: baseline)
        }
        let atHigh = rollTestCapabilities(current: 86)
        #expect(try USBRollAcceptanceExecutor.targetRaw(nil, baseline: atHigh) == 84)
    }

    @Test func evaluatorRequiresStopRestoreAndReconnectEvidence() throws {
        let report = validReport()
        let evaluation = USBRollAcceptanceExecutor.evaluate(report)
        #expect(evaluation.metricsPassed)
        #expect(evaluation.failureCode == nil)
        #expect(!evaluation.cameraImagesStored && !evaluation.physicalMotionVerified)

        let incomplete = USBRollAcceptanceReport(
            phase: "failed", completed: false,
            expectedDeviceID: deviceID, expectedSessionID: sessionID,
            initialBinding: report.initialBinding, baseline: report.baseline,
            targetRaw: report.targetRaw, progress: report.progress,
            stop: USBRollStopResult(submitted: true, target: -18,
                observed: -17, verified: false), restore: report.restore,
            reconnect: report.reconnect, finalBinding: report.finalBinding,
            failureCode: "roll_acceptance_stop_unverified")
        let failed = USBRollAcceptanceExecutor.evaluate(incomplete)
        #expect(!failed.metricsPassed)
        #expect(failed.checks["stop_stable_window"] == false)
    }

    @Test func fakeExecutorRunsMoveStopRestoreAndReconnectInOrder() async throws {
        let request = try USBRollAcceptanceRequest(
            expectedDeviceID: deviceID, expectedSessionID: sessionID,
            rawValue: -18, moveSeconds: 0.6, pollInterval: 0.08,
            timeout: 3, execute: true)
        let old = USBRollAcceptanceBinding(
            deviceID: deviceID, captureSessionID: sessionID,
            registryID: "registry", bootSessionID: "boot")
        let new = USBRollAcceptanceBinding(
            deviceID: deviceID, captureSessionID: "reconnected-session",
            registryID: "registry", bootSessionID: "boot")
        let baseline = rollTestCapabilities(current: -20)
        let currentValues = RollAcceptanceFakeState(values: [
            baseline, rollTestCapabilities(current: -20),
            rollTestCapabilities(current: -18)
        ], old: old, new: new)
        let clock = RollTestClock()
        let adapter = USBRollAcceptanceExecutorAdapter(
            readCapabilities: { await currentValues.nextCapabilities() },
            startMove: { raw, _ in
                Task {
                    await currentValues.recordMove(raw)
                    return USBRollResult(target: raw, observed: raw,
                        accepted: true, completed: true, verified: true,
                        verification: "fake_exact_stable",
                        capabilities: rollTestCapabilities(current: raw),
                        message: "fixture", sampleCount: 3,
                        stableDurationSeconds: 0.2)
                }
            },
            stop: {
                await currentValues.recordStop()
                return USBRollStopResult(submitted: true, target: -18,
                    observed: -18, verified: true, sampleCount: 11,
                    stableDurationSeconds: 0.8)
            },
            readBinding: { await currentValues.nextBinding() },
            reconnect: { oldBinding, oldTarget, _ in
                await currentValues.recordReconnect(oldBinding, oldTarget)
                return USBRollAcceptanceReconnectEvidence(
                    oldBinding: oldBinding, newBinding: new,
                    oldOperationStopped: true, oldOperationSuppressed: true,
                    newSessionReady: true)
            })

        let report = await USBRollAcceptanceExecutor.execute(
            request, adapter: adapter, clock: clock)
        let evaluation = USBRollAcceptanceExecutor.evaluate(report)
        #expect(report.completed && report.phase == "completed")
        #expect(evaluation.metricsPassed)
        #expect(await currentValues.moves == [-18, -20])
        #expect(await currentValues.stops == 1)
        #expect(await currentValues.reconnects == 1)
        #expect(report.progress.count >= USBRollAcceptanceExecutor.minimumProgressSamples)
        #expect(report.finalBinding == new)
    }

    private func validReport() -> USBRollAcceptanceReport {
        let old = USBRollAcceptanceBinding(
            deviceID: deviceID, captureSessionID: sessionID,
            registryID: "registry", bootSessionID: "boot")
        let new = USBRollAcceptanceBinding(
            deviceID: deviceID, captureSessionID: "new-session",
            registryID: "registry", bootSessionID: "boot")
        let baseline = rollTestCapabilities(current: -20)
        let progress = [
            USBRollAcceptanceProgressSample(elapsed: 0.1, phase: "moving",
                observedRaw: -20, targetRaw: -18, minimumRaw: -120,
                maximumRaw: 86, stepRaw: 2, sessionID: sessionID,
                deviceID: deviceID),
            USBRollAcceptanceProgressSample(elapsed: 0.2, phase: "moving",
                observedRaw: -18, targetRaw: -18, minimumRaw: -120,
                maximumRaw: 86, stepRaw: 2, sessionID: sessionID,
                deviceID: deviceID)
        ]
        return USBRollAcceptanceReport(
            phase: "completed", completed: true,
            expectedDeviceID: deviceID, expectedSessionID: sessionID,
            initialBinding: old, baseline: baseline, targetRaw: -18,
            progress: progress,
            stop: USBRollStopResult(submitted: true, target: -18,
                observed: -18, verified: true, sampleCount: 11,
                stableDurationSeconds: 0.8),
            restore: USBRollAcceptanceRestoreEvidence(
                requestedRaw: -20, observedRaw: -20, submitted: true,
                verified: true, stableSampleCount: 3,
                stableDurationSeconds: 0.2),
            reconnect: USBRollAcceptanceReconnectEvidence(
                oldBinding: old, newBinding: new,
                oldOperationStopped: true, oldOperationSuppressed: true,
                newSessionReady: true), finalBinding: new)
    }
}

private actor RollAcceptanceFakeState {
    private var values: [USBRollCapabilities]
    private let old: USBRollAcceptanceBinding
    private let new: USBRollAcceptanceBinding
    private var bindingReads = 0
    private(set) var moves: [Int] = []
    private(set) var stops = 0
    private(set) var reconnects = 0

    init(values: [USBRollCapabilities], old: USBRollAcceptanceBinding,
         new: USBRollAcceptanceBinding) {
        self.values = values
        self.old = old
        self.new = new
    }

    func nextCapabilities() -> USBRollCapabilities {
        values.isEmpty ? rollTestCapabilities(current: -18) : values.removeFirst()
    }

    func recordMove(_ raw: Int) { moves.append(raw) }
    func recordStop() { stops += 1 }
    func recordReconnect(_ oldBinding: USBRollAcceptanceBinding, _ oldTarget: Int) {
        if oldBinding == old && oldTarget == -18 { reconnects += 1 }
    }

    func nextBinding() -> USBRollAcceptanceBinding {
        bindingReads += 1
        return bindingReads == 1 ? old : new
    }
}
