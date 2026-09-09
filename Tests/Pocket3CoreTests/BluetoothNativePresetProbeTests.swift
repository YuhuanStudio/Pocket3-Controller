import Foundation
import Testing
@testable import Pocket3Core

@Suite struct BluetoothNativePresetProbeTests {
    private func telemetry(sequence: UInt16, yaw: Double = 0, pitch: Double = 0, roll: Double = 0) throws -> Data {
        var payload = Data()
        for angle in [pitch, roll, yaw] {
            let raw = UInt16(bitPattern: Int16((angle * 10).rounded()))
            payload.append(contentsOf: [UInt8(raw & 0xff), UInt8(raw >> 8)])
        }
        return try DUMLCodec.encode(DUMLFrame(source: 4, destination: 2, sequence: sequence,
            flags: 0, commandSet: 4, commandID: 5, payload: payload))
    }
    private func ack(sequence: UInt16 = 0x9123, source: UInt8 = 4, destination: UInt8 = 2,
                     set: UInt8 = 4, command: UInt8 = 0x4c, flags: UInt8 = 0x80,
                     payload: Data = Data([0, 0])) throws -> Data {
        try DUMLCodec.encode(DUMLFrame(source: source, destination: destination, sequence: sequence,
            flags: flags, commandSet: set, commandID: command, payload: payload))
    }
    private func feed(_ probe: inout BluetoothNativePresetProbe, data: Data, at time: Double, characteristic: String = "FFF4") {
        probe.receive(data, characteristic: characteristic, receivedAt: Date(timeIntervalSince1970: 1000 + time), uptime: time)
    }
    private func baseline(yaw: Double = 0) throws -> BluetoothNativePresetProbe {
        var probe = BluetoothNativePresetProbe(sequence: 0x9123, startedUptime: 0, registrationAcknowledgmentSubmitted: true)
        for index in 0..<6 {
            feed(&probe, data: try telemetry(sequence: UInt16(index + 1), yaw: yaw), at: 0.01 + Double(index) * 0.1)
        }
        return probe
    }

    @Test func requestIsOnlyFE08AndSubmissionCannotBeRetried() throws {
        var probe = try baseline()
        let packet = try DUMLCodec.encode(probe.request)
        #expect(packet.count == 15)
        let decoded = try DUMLCodec.decode(packet)
        #expect(decoded.source == 2 && decoded.destination == 4 && decoded.flags == 0x40)
        #expect(decoded.sequence == 0x9123 && decoded.commandSet == 4 && decoded.commandID == 0x4c)
        #expect(decoded.payload == Data([0xfe, 0x08]))
        try probe.submitted(at: 0.52)
        #expect(throws: BridgeFailure.self) { try probe.submitted(at: 0.53) }
        #expect(probe.result.localSubmitted && probe.result.submittedUptime == 0.52)
    }

    @Test func absentReplayedAndStaleBaselinesAuthorizeZeroWrites() throws {
        var absent = BluetoothNativePresetProbe(sequence: 1, startedUptime: 0, registrationAcknowledgmentSubmitted: true)
        #expect(throws: BridgeFailure.self) { try absent.submitted(at: 0.52) }
        for index in 0..<6 { feed(&absent, data: try telemetry(sequence: 1), at: 0.01 + Double(index) * 0.1) }
        #expect(!absent.baselineIsReady(at: 0.52))
        #expect(throws: BridgeFailure.self) { try absent.submitted(at: 0.52) }
        var stale = try baseline()
        #expect(!stale.baselineIsReady(at: 0.91))
        #expect(throws: BridgeFailure.self) { try stale.submitted(at: 0.91) }
        #expect(!absent.result.localSubmitted && !stale.result.localSubmitted)
    }

    @Test func acknowledgmentsRequireExactRouteSequenceOpcodeFlagsAndValidCRC() throws {
        let invalid = try [ack(sequence: 0x9124), ack(source: 5), ack(destination: 0x22),
            ack(set: 7, command: 0x0e, payload: Data("fixture-private-password".utf8)),
            ack(command: 1), ack(flags: 0), ack(flags: 0x40), ack(flags: 0xff)]
        var probe = try baseline()
        feed(&probe, data: try ack(), at: 0.515) // An ACK before submission is not correlated.
        try probe.submitted(at: 0.52)
        for packet in invalid { feed(&probe, data: packet, at: 0.6) }
        feed(&probe, data: try ack(), at: 0.6, characteristic: "FFF3")
        var corrupt = try ack(); corrupt[corrupt.count - 1] ^= 1
        feed(&probe, data: corrupt, at: 0.6)
        #expect(!probe.result.responseReceived && probe.result.payloadHex == nil && probe.result.replyHeader == nil)
        feed(&probe, data: try ack(), at: 0.7)
        #expect(probe.result.responseReceived && probe.result.replyHeader?.flags == 0x80)
        #expect(probe.result.payloadHex == "0000" && !probe.result.movementObserved)
        feed(&probe, data: try ack(payload: Data([9])), at: 0.8)
        #expect(probe.result.payloadHex == "0000")
    }

    @Test func onlyNewTelemetryAddsSamplesAndWrappedDeltasStaySmall() throws {
        var probe = try baseline(yaw: 179.8)
        try probe.submitted(at: 0.52)
        let first = try telemetry(sequence: 7, yaw: -179.7, pitch: 1.2, roll: -0.8)
        feed(&probe, data: first, at: 0.6)
        feed(&probe, data: first, at: 0.7) // Duplicate even with a new host time.
        feed(&probe, data: try telemetry(sequence: 6, yaw: -170), at: 0.8)
        feed(&probe, data: try telemetry(sequence: 8, yaw: -179.6, pitch: 1), at: 2.9)
        let result = probe.finish(at: 3.53, cancelled: false, connectionChanged: false, failure: nil)
        #expect(result.movementSampleCount == 2 && result.sampleUptimes == [0.6, 2.9])
        #expect(abs(result.maximumYawDelta - 0.6) < 0.00001)
        #expect(result.maximumPitchDelta == 1.2 && result.maximumRollDelta == 0.8)
        #expect(result.finalPose?.yawDegrees == -179.6)
        #expect(result.movementObserved && result.timedOut && !result.responseReceived)
    }

    @Test func replyDoesNotShortenThreeSecondWindowAndLateReplyIsExcluded() throws {
        var early = try baseline()
        try early.submitted(at: 0.52)
        feed(&early, data: try ack(flags: 0xc0), at: 0.6)
        let partial = early.finish(at: 1, cancelled: false, connectionChanged: false, failure: nil)
        #expect(partial.responseReceived && !partial.observationWindowCompleted && !partial.timedOut)
        var late = try baseline()
        try late.submitted(at: 0.52)
        feed(&late, data: try ack(), at: 3.521)
        let result = late.finish(at: 3.53, cancelled: false, connectionChanged: false, failure: nil)
        #expect(result.observationWindowCompleted && result.timedOut && !result.responseReceived)
    }

    @Test func cancellationAndConnectionChangeStayDistinctAndFinishFreezesEvidence() throws {
        for changed in [false, true] {
            var probe = try baseline()
            try probe.submitted(at: 0.52)
            let result = probe.finish(at: 3.53, cancelled: !changed, connectionChanged: changed, failure: nil)
            #expect(result.cancelled == !changed && result.connectionChanged == changed)
            #expect(!result.timedOut && !result.observationWindowCompleted)
            feed(&probe, data: try ack(), at: 0.7)
            #expect(!probe.result.responseReceived && probe.result.payloadHex == nil)
        }
        var beforeWrite = try baseline()
        let permit = OperationPermit(); permit.invalidate()
        var writes = 0
        #expect(throws: BridgeFailure.self) {
            try permit.perform { try beforeWrite.submitted(at: 0.52); writes += 1 }
        }
        #expect(writes == 0 && !beforeWrite.result.localSubmitted)
    }

    @Test func matchingPayloadAndSampleStorageAreBounded() throws {
        var probe = try baseline()
        try probe.submitted(at: 0.52)
        feed(&probe, data: try ack(payload: Data(repeating: 0xab, count: 64)), at: 0.6)
        for index in 0..<300 {
            feed(&probe, data: try telemetry(sequence: UInt16(index + 7)), at: 0.61 + Double(index) * 0.005)
        }
        let result = probe.finish(at: 3.53, cancelled: false, connectionChanged: false, failure: nil)
        #expect(result.payloadByteCount == 64 && result.payloadHex?.count == 32 && result.payloadTruncated)
        #expect(result.sampleUptimes.count == 128 && result.sampleTimesTruncated && result.movementSampleCount == 300)
        #expect(!result.movementObserved && result.responseReceived && result.observationWindowCompleted)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!json.contains("password") && !json.contains("nativeSupported") && !json.contains("\"passed\""))
    }

    @MainActor @Test func disabledDevelopmentEntryDoesNotInitializeBluetooth() async {
        guard !CommandLine.arguments.contains("--hardware-validation") else { return }
        let discovery = Pocket3BluetoothDiscovery()
        do {
            _ = try await discovery.probeNativeRecenter()
            Issue.record("Production launch unexpectedly admitted a native recenter probe")
        } catch {
            #expect((error as? BridgeFailure)?.code == "validation_disabled")
        }
        #expect(!discovery.isBluetoothInitialized)
    }
}
