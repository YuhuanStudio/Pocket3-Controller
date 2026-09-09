import Foundation
import Testing
@testable import Pocket3Core

@Suite struct BluetoothGimbalProbeTests {
    private func telemetry(sequence: UInt16, yaw: Double = 0, pitch: Double = 0, roll: Double = 0) -> DUMLFrame {
        var payload = Data()
        for angle in [pitch, roll, yaw] {
            let value = UInt16(bitPattern: Int16((angle * 10).rounded()))
            payload.append(contentsOf: [UInt8(value & 0xff), UInt8(value >> 8)])
        }
        return DUMLFrame(source: 4, destination: 2, sequence: sequence, flags: 0,
            commandSet: 4, commandID: 5, payload: payload)
    }
    private func feed(_ evidence: inout BluetoothGimbalProbeEvidence, sequence: UInt16, at time: Double, yaw: Double = 0) {
        evidence.receive(telemetry(sequence: sequence, yaw: yaw), receivedAt: Date(timeIntervalSince1970: 1000 + time), uptime: time)
    }
    private func baseline(yaw: Double = 0) -> BluetoothGimbalProbeEvidence {
        var evidence = BluetoothGimbalProbeEvidence(startedUptime: 0, registrationAcknowledgmentSubmitted: true)
        for index in 0..<6 { feed(&evidence, sequence: UInt16(index + 1), at: 0.01 + Double(index) * 0.1, yaw: yaw) }
        return evidence
    }

    @Test func probePlanHasExactlyFourSmallSingleAxisFramesAndOneNeutral() throws {
        #expect(BluetoothGimbalProbePlan.offsets == [0, 0.05, 0.1, 0.15])
        #expect(BluetoothGimbalProbePlan.neutralOffset == 0.2)
        for index in 0..<4 {
            let data = try BluetoothGimbalProbePlan.pulse(sequence: UInt16(10 + index))
            let frame = try DUMLCodec.decode(data)
            #expect(data.count == 23 && frame.commandSet == 4 && frame.commandID == 1)
            #expect(frame.flags == 0 && frame.source == 2 && frame.destination == 4)
            #expect(frame.payload == Data([0, 4, 0, 0, 0x21, 4, 0, 0x80, 0x22, 0]))
        }
        let neutral = try DUMLJoystickCommand.neutral.encodedFrame(sequence: 14)
        #expect(neutral.count == 23)
        #expect(try DUMLCodec.decode(neutral).payload == Data([0, 4, 0, 0, 0, 4, 0, 0x80, 0x22, 0]))
    }

    @Test func realSequenceProgressAndHalfSecondStableBaselineAreRequired() throws {
        var evidence = BluetoothGimbalProbeEvidence(startedUptime: 0, registrationAcknowledgmentSubmitted: true)
        for index in 0..<6 { feed(&evidence, sequence: 1, at: 0.01 + Double(index) * 0.1) }
        #expect(!evidence.baselineIsReady(at: 0.52))
        #expect(throws: BridgeFailure.self) { try evidence.beginPulse(at: 0.52) }
        var valid = baseline()
        #expect(valid.baselineIsReady(at: 0.52))
        try valid.beginPulse(at: 0.52)
        #expect(valid.result.baselineStable && valid.result.baselineSampleCount == 6)
    }

    @Test func nominalPulseRequiresMeasuredYawChangeAndPostNeutralStabilityToPass() throws {
        var evidence = baseline()
        let start = 0.52
        try evidence.beginPulse(at: start)
        for index in 0..<4 {
            let time = start + BluetoothGimbalProbePlan.offsets[index]
            try evidence.pulseSubmitted(index: index, at: time)
            feed(&evidence, sequence: UInt16(7 + index), at: time + 0.001, yaw: Double(index + 1) * 0.3)
        }
        let neutral = start + BluetoothGimbalProbePlan.neutralOffset
        evidence.neutralSubmitted(at: neutral)
        for index in 0..<3 { feed(&evidence, sequence: UInt16(11 + index), at: neutral + 0.01 + Double(index) * 0.11, yaw: 1.2) }
        let result = evidence.finish(at: neutral + 0.24, cancelled: false, connectionChanged: false, failure: nil)
        #expect(result.passed && result.movementObserved && result.stableTelemetry)
        #expect(result.nonNeutralFramesSent == 4 && result.neutralSent)
        #expect(result.yawDelta == 1.2 && result.maximumYawDelta == 1.2)
    }

    @Test func ignoredJoystickFramesCannotPassFromTheirAcknowledgmentsOrSubmissionAlone() throws {
        var evidence = baseline()
        let start = 0.52
        try evidence.beginPulse(at: start)
        for index in 0..<4 { try evidence.pulseSubmitted(index: index, at: start + BluetoothGimbalProbePlan.offsets[index]) }
        evidence.neutralSubmitted(at: start + 0.2)
        for index in 0..<3 { feed(&evidence, sequence: UInt16(7 + index), at: start + 0.21 + Double(index) * 0.11) }
        let result = evidence.finish(at: start + 0.44, cancelled: false, connectionChanged: false, failure: nil)
        #expect(result.neutralSent && result.stableTelemetry && !result.movementObserved && !result.passed)
    }

    @Test func lateOrRepeatedPulseSlotsDoNotPermitCatchup() throws {
        var evidence = baseline()
        try evidence.beginPulse(at: 0.52)
        #expect(throws: BridgeFailure.self) { try evidence.pulseSubmitted(index: 0, at: 0.541) }
        #expect(evidence.result.nonNeutralFramesSent == 0)
        var repeated = baseline()
        try repeated.beginPulse(at: 0.52)
        try repeated.pulseSubmitted(index: 0, at: 0.52)
        #expect(throws: BridgeFailure.self) { try repeated.pulseSubmitted(index: 0, at: 0.53) }
        #expect(repeated.result.nonNeutralFramesSent == 1)
    }

    @Test func duplicatesCannotManufacturePostNeutralStabilityAndCancellationCannotPass() throws {
        var evidence = baseline()
        try evidence.beginPulse(at: 0.52)
        try evidence.pulseSubmitted(index: 0, at: 0.52)
        evidence.neutralSubmitted(at: 0.6)
        for index in 0..<4 { feed(&evidence, sequence: 7, at: 0.61 + Double(index) * 0.11, yaw: 1) }
        let result = evidence.finish(at: 0.94, cancelled: true, connectionChanged: false, failure: "cancelled")
        #expect(result.neutralSent && !result.stableTelemetry && !result.passed && result.cancelled)
        #expect(result.postNeutralSampleCount == 1)
    }

    @Test @MainActor func unstructuredCleanupCanRunAfterItsCallerIsCancelled() async {
        let caller = Task<(Bool, Bool), Never> { @MainActor in
            let callerWasCancelled = Task.isCancelled
            let cleanup = Task<Bool, Never> { @MainActor in
                do {
                    try OperationPermit().perform {}
                    return !Task.isCancelled
                } catch { return false }
            }
            return (callerWasCancelled, await cleanup.value)
        }
        // The test itself owns MainActor until it awaits, so cancellation is
        // established before the caller starts and creates its cleanup task.
        caller.cancel()
        let result = await caller.value
        #expect(result.0 && result.1)
    }
}
