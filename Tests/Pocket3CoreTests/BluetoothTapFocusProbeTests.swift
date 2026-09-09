import Foundation
import Testing
@testable import Pocket3Core

@Suite struct BluetoothTapFocusProbeTests {
    let session = UUID(), peer = UUID(), capture = UUID()
    func request(x: Double = 0.25, y: Double = 0.75) throws -> BluetoothTapFocusRequest {
        try BluetoothTapFocusRequest(arguments: .object(["expectedSessionID": .string(session.uuidString),
            "peripheralID": .string(peer.uuidString), "expectedCaptureSessionID": .string(capture.uuidString),
            "x": .number(x), "y": .number(y)]))
    }
    func observations(at now: Double = 100, mode: CameraExposureMode? = .automatic) -> [CameraSettingsObservation] {
        let binding = ContinuousGimbalBinding(sessionID: "ble:\(session.uuidString)", generation: 0)
        return [CameraSettingsObservation(property: .lensState, value: .focus(.continuous), exposureMode: nil,
                transactionID: 1, binding: binding, receivedUptime: now),
                CameraSettingsObservation(property: .exposure, value: .autoEV(thirdStops: 0), exposureMode: mode,
                transactionID: 2, binding: binding, receivedUptime: now)]
    }
    func probe() throws -> BluetoothTapFocusProbe {
        let request = try request()
        return try BluetoothTapFocusProbe(request: request,
            baseline: BluetoothTapFocusBaseline(request: request, observations: observations(), now: 100),
            sequences: [10,11,12,13], now: 100)
    }
    func packet(_ frame: DUMLFrame) throws -> ValidatedDUMLPacket {
        var decoder = DUMLFragmentDecoder()
        return try #require(decoder.append(DUMLCodec.encode(frame), at: 100).first)
    }
    func ack(_ step: BluetoothTapFocusStep, sequence: UInt16? = nil, status: [UInt8] = [0],
             source: UInt8 = 1, destination: UInt8 = 2, flags: UInt8 = 0xc0) throws -> ValidatedDUMLPacket {
        let index = BluetoothTapFocusStep.allCases.firstIndex(of: step)!
        return try packet(DUMLFrame(source: source, destination: destination, sequence: sequence ?? UInt16(10 + index),
            flags: flags, commandSet: 2, commandID: step.commandID, payload: Data(status)))
    }
    func receive(_ probe: inout BluetoothTapFocusProbe, packet: ValidatedDUMLPacket, at now: Double,
                 session: UUID? = nil, peer: UUID? = nil) {
        probe.receive(packet, characteristic: "FFF4", sessionID: session ?? self.session,
                      peripheralID: peer ?? self.peer, hostReceivedAt: Date(), uptime: now)
    }
    func lens(sequence: UInt16, x: Float = 0.25, y: Float = 0.75, flags: UInt8 = 0) throws -> ValidatedDUMLPacket {
        let name = Array("cam_lens_state".utf8)
        var value: [UInt8] = [0xb2]
        for bits in [x.bitPattern, y.bitPattern] { value += (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) } }
        value += [UInt8](repeating: 0, count: 38)
        var payload: [UInt8] = [2,6,0,0,7,0,0,0,0,0,0,0,0,UInt8(name.count),0]
        payload += name; payload += [0,0,0,0,0,0,UInt8(value.count),0]; payload += value
        return try packet(DUMLFrame(source: 0x28, destination: 2, sequence: sequence, flags: flags,
            commandSet: 0, commandID: 0x99, payload: Data(payload)))
    }

    @Test func exactFourCapturedPayloadsAndRoutesNoAlternativeOpcode() throws {
        let p = try probe()
        let xy: [UInt8] = [0,0,0x80,0x3e,0,0,0x40,0x3f]
        let payloads = [Data([2]), Data(xy + [UInt8](repeating: 0, count: 13)),
                        Data([8]), Data([0,2,1,0] + xy + [UInt8](repeating: 0, count: 8))]
        for (index, step) in BluetoothTapFocusStep.allCases.enumerated() {
            let frame = p.frame(for: step)
            #expect(frame.source == 2 && frame.destination == 1 && frame.flags == 0x40 && frame.commandSet == 2)
            #expect(frame.sequence == UInt16(10 + index) && frame.payload == payloads[index])
            #expect(try DUMLCodec.encode(frame).count == [14,34,14,33][index])
        }
        #expect(p.result.opticalFocusVerification == "not_available")
    }
    @Test func strictInputsAndCodableCannotBypassSafeInterior() throws {
        for pair in [(-0.1,0.5),(0.099,0.5),(0.91,0.5),(0.5,1.0),(.nan,0.5),(.infinity,0.5)] {
            #expect(throws: BridgeFailure.self) { try request(x: pair.0, y: pair.1) }
        }
        #expect(try request(x: 0.1,y: 0.9).x == 0.1)
        let valid = try request()
        #expect(try JSONDecoder().decode(BluetoothTapFocusRequest.self, from: JSONEncoder().encode(valid)) == valid)
        guard case .object(var fields) = valid.arguments else { Issue.record("Expected request fields"); return }
        fields["retry"] = .bool(true)
        #expect(throws: BridgeFailure.self) { try BluetoothTapFocusRequest(arguments: .object(fields)) }
        fields.removeValue(forKey: "retry"); fields["x"] = .string("0.25")
        #expect(throws: BridgeFailure.self) { try BluetoothTapFocusRequest(arguments: .object(fields)) }
        #expect(throws: BridgeFailure.self) { try BluetoothTapFocusRequest(cliArguments: ["--session",session.uuidString,"--peripheral",peer.uuidString,"--capture-session",capture.uuidString,"--x","0.25","--x","0.75"]) }
    }
    @Test func freshKnownSameSessionAutomaticExposureBaselineRequired() throws {
        let request = try request()
        for values in [[], Array(observations().prefix(1)), observations(at: 94), observations(mode: nil), observations(mode: .manual)] {
            #expect(throws: BridgeFailure.self) { try BluetoothTapFocusBaseline(request: request, observations: values, now: 100) }
        }
        var other = try BluetoothTapFocusRequest(arguments: request.arguments)
        guard case .object(var fields) = other.arguments else { return }
        fields["expectedSessionID"] = .string(UUID().uuidString)
        other = try BluetoothTapFocusRequest(arguments: .object(fields))
        #expect(throws: BridgeFailure.self) { try BluetoothTapFocusBaseline(request: other, observations: observations(), now: 100) }
    }
    @Test func prepareDoesNotWaitPointAndHintRequireExactSuccessfulAck() throws {
        var p = try probe()
        try p.submitted(.prepareAE, at: 100)
        #expect(p.nextStep == .point)
        try p.submitted(.point, at: 100.001)
        #expect(p.nextStep == nil)
        for wrong in [try ack(.point, sequence: 9), try ack(.point, source: 0x28), try ack(.point, destination: 1), try ack(.point, flags: 0)] {
            receive(&p, packet: wrong, at: 100.1)
            #expect(p.nextStep == nil && p.result.end == nil)
        }
        receive(&p, packet: try ack(.point), at: 100.15, session: UUID())
        #expect(p.nextStep == nil)
        receive(&p, packet: try ack(.point), at: 100.2)
        #expect(p.nextStep == .hintAE)
        try p.submitted(.hintAE, at: 100.21)
        #expect(p.nextStep == nil)
        receive(&p, packet: try ack(.hintAE, flags: 0x80), at: 100.3)
        #expect(p.nextStep == .commitMetering && p.result.hintPolicyDiffersFromUpstream)
    }
    @Test func pointNackOrEmptyAckEndsWithoutHint() throws {
        for status in [[UInt8](),[0xd9],[0xdf],[0xe3],[0xee],[0xe0]] {
            var p = try probe(); try p.submitted(.prepareAE, at: 100); try p.submitted(.point, at: 100)
            receive(&p, packet: try ack(.point,status: status), at: 100.1)
            #expect(p.nextStep == nil && p.result.submittedCount == 2 && p.result.partialSequence && p.result.possibleAEsideEffects)
            #expect(p.result.end == (status.isEmpty ? .invalidACK : .nack))
            #expect(!p.result.retryPerformed && !p.result.restorePerformed)
        }
    }
    @Test func eachRequiredAckHas800msDeadlineAndCannotRevive() throws {
        for target in [BluetoothTapFocusStep.point, .hintAE, .commitMetering] {
            var p = try probe(); try p.submitted(.prepareAE, at: 100); try p.submitted(.point, at: 100)
            var sent = 100.0
            if target != .point {
                receive(&p, packet: try ack(.point), at: 100.1); try p.submitted(.hintAE, at: 100.1); sent = 100.1
            }
            if target == .commitMetering {
                receive(&p, packet: try ack(.hintAE), at: 100.2); try p.submitted(.commitMetering, at: 100.2); sent = 100.2
            }
            p.tick(at: sent + 0.801)
            #expect(p.result.end == .ackTimeout && p.nextStep == nil)
            receive(&p, packet: try ack(target), at: sent + 0.802)
            #expect(p.result.end == .ackTimeout && !p.result.sequenceAcknowledged)
        }
    }
    @Test func explicitPrepareNackStopsRemainderThoughPrepareIsUntracked() throws {
        var p = try probe(); try p.submitted(.prepareAE, at: 100); try p.submitted(.point, at: 100)
        receive(&p, packet: try ack(.point), at: 100.1)
        receive(&p, packet: try ack(.prepareAE,status: [0xe3]), at: 100.11)
        #expect(p.result.end == .nack && p.nextStep == nil && p.result.submittedCount == 2)
    }
    @Test func completedSequenceCollectsOnlyPostPointDistinctLensCandidates() throws {
        var p = try probe()
        receive(&p, packet: try lens(sequence: 1), at: 100)
        #expect(p.result.lensPoints.isEmpty)
        try p.submitted(.prepareAE, at: 100); try p.submitted(.point, at: 100)
        receive(&p, packet: try lens(sequence: 2), at: 100.05)
        receive(&p, packet: try lens(sequence: 2), at: 100.06)
        receive(&p, packet: try lens(sequence: 3), at: 100.07, peer: UUID())
        receive(&p, packet: try lens(sequence: 3,flags: 0xc0), at: 100.08)
        #expect(p.result.lensPoints.count == 1)
        receive(&p, packet: try ack(.point), at: 100.1); try p.submitted(.hintAE, at: 100.1)
        receive(&p, packet: try ack(.hintAE), at: 100.2); try p.submitted(.commitMetering, at: 100.2)
        receive(&p, packet: try ack(.commitMetering), at: 100.3)
        #expect(p.result.sequenceAcknowledged && p.result.end == nil && p.nextStep == nil)
        p.tick(at: 102.3)
        #expect(p.result.end == .observationComplete && !p.result.partialSequence && p.result.possibleAEsideEffects)
        let encoded = try JSONValue.encode(p.result)
        #expect(encoded["submittedCount"].number == 4 && encoded["sequenceAcknowledged"].bool == true)
        #expect(encoded["focusAchieved"].bool == nil)
    }
    @Test func cancelledChangedAndInvalidClockNeverPermitAnotherStep() throws {
        for end in [BluetoothTapFocusEnd.cancelled, .connectionChanged] {
            var p = try probe(); try p.submitted(.prepareAE, at: 100)
            p.finish(at: 100.1, reason: end)
            #expect(p.nextStep == nil && p.result.partialSequence)
            do { try p.submitted(.point, at: 100.2); Issue.record("Cancelled sequence revived") } catch {}
        }
        var p = try probe(); p.tick(at: .nan)
        #expect(p.result.end == .invalidClock && p.result.finishedUptime?.isFinite == true)
    }
    @Test func platformCreditRestorationSendsOnlyTheNextUnsentStepOnce() throws {
        var p = try probe(), writes: [DUMLFrame] = []
        let prepare = try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 34, at: 100) { frame, _ in writes.append(frame) }
        let blocked1 = try p.submitNextIfReady(hasCredit: false, maximumWriteBytes: 34, at: 100.01) { frame, _ in writes.append(frame) }
        let blocked2 = try p.submitNextIfReady(hasCredit: false, maximumWriteBytes: 34, at: 100.10) { frame, _ in writes.append(frame) }
        #expect(prepare && !blocked1 && !blocked2 && writes.map(\.sequence) == [10])
        #expect(p.result.steps[1].submittedUptime == nil && !p.result.steps[1].ackTimedOut)
        let point = try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 34, at: 100.25) { frame, data in
            #expect(data.count == 34); writes.append(frame)
        }
        let waitingForACK = try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 34, at: 100.26) { frame, _ in writes.append(frame) }
        #expect(point && !waitingForACK && writes.map(\.sequence) == [10,11])
        #expect(abs(p.result.steps[1].creditWaitDurationSeconds - 0.24) < 0.00001)
        #expect(p.result.steps[1].creditWaitOutcome == "credit_restored")
        // This ACK is later than prepare+800ms but within point submission+800ms.
        receive(&p, packet: try ack(.point), at: 100.95)
        #expect(p.nextStep == .hintAE && p.result.end == nil && p.result.steps[1].acknowledged)
        #expect(p.result.steps[0].ackTimedOut && !p.result.steps[1].ackTimedOut)
        let hint = try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 34, at: 100.96) { frame, _ in writes.append(frame) }
        #expect(hint && writes.map(\.sequence) == [10,11,12] && !p.result.retryPerformed)
    }
    @Test func cancelOrConnectionChangeWhileWaitingNeverSubmitsPoint() throws {
        for end in [BluetoothTapFocusEnd.cancelled, .connectionChanged] {
            var p = try probe(), writes: [UInt16] = []
            _ = try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 34, at: 100) { frame, _ in writes.append(frame.sequence) }
            _ = try p.submitNextIfReady(hasCredit: false, maximumWriteBytes: 34, at: 100.01) { frame, _ in writes.append(frame.sequence) }
            p.finish(at: 100.1, reason: end)
            let sent = try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 34, at: 100.2) { frame, _ in writes.append(frame.sequence) }
            #expect(!sent && writes == [10] && p.result.partialSequence && p.result.possibleAEsideEffects)
            #expect(p.result.steps[1].creditWaitOutcome == end.rawValue)
            #expect(abs(p.result.steps[1].creditWaitDurationSeconds - 0.09) < 0.00001)
        }
    }
    @Test func invalidatedFinalPermitBlocksCreditRestorationWrite() throws {
        var p = try probe(), writes: [UInt16] = []
        let permit = OperationPermit()
        _ = try permit.perform { try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 34, at: 100) { frame, _ in writes.append(frame.sequence) } }
        _ = try permit.perform { try p.submitNextIfReady(hasCredit: false, maximumWriteBytes: 34, at: 100.01) { frame, _ in writes.append(frame.sequence) } }
        permit.invalidate()
        do {
            _ = try permit.perform { try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 34, at: 100.02) { frame, _ in writes.append(frame.sequence) } }
            Issue.record("A revoked final permit sent a pending focus step")
        } catch let error as BridgeFailure { #expect(error.code == "cancelled") }
        #expect(writes == [10] && p.result.steps[1].submittedUptime == nil)
    }
    @Test func unavailableCreditHasIndependentDeadlineAndIsNotCameraACKTimeout() throws {
        var p = try probe(), writes: [UInt16] = []
        _ = try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 34, at: 100) { frame, _ in writes.append(frame.sequence) }
        for time in [100.01,100.2,100.5,100.811] {
            _ = try p.submitNextIfReady(hasCredit: false, maximumWriteBytes: 34, at: time) { frame, _ in writes.append(frame.sequence) }
        }
        #expect(p.result.end == .creditTimeout && p.result.failure == "bluetooth_focus_credit_timeout")
        #expect(p.result.steps[1].submittedUptime == nil && !p.result.steps[1].ackTimedOut && writes == [10])
        #expect(p.result.steps[1].creditWaitReason == "corebluetooth_without_response_credit")
        #expect(p.result.steps[1].creditWaitOutcome == "creditTimeout" && p.result.steps[1].creditWaitDurationSeconds >= 0.8)
        let late = try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 34, at: 100.82) { frame, _ in writes.append(frame.sequence) }
        #expect(!late && writes == [10])
    }
    @Test func waitingForCreditDoesNotExtendOverallFiveSecondLimitOrBypassMTU() throws {
        var p = try probe(), writes: [UInt16] = []
        _ = try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 34, at: 104.4) { frame, _ in writes.append(frame.sequence) }
        _ = try p.submitNextIfReady(hasCredit: false, maximumWriteBytes: 34, at: 104.41) { frame, _ in writes.append(frame.sequence) }
        let sent = try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 34, at: 105) { frame, _ in writes.append(frame.sequence) }
        #expect(!sent && p.result.end == .overallTimeout && writes == [10])
        #expect(p.result.steps[1].creditWaitOutcome == "overallTimeout")
        p = try probe(); writes = []
        _ = try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 34, at: 100) { frame, _ in writes.append(frame.sequence) }
        _ = try p.submitNextIfReady(hasCredit: false, maximumWriteBytes: 34, at: 100.01) { frame, _ in writes.append(frame.sequence) }
        do {
            _ = try p.submitNextIfReady(hasCredit: true, maximumWriteBytes: 33, at: 100.02) { frame, _ in writes.append(frame.sequence) }
            Issue.record("Restored credits bypassed the whole-frame MTU limit")
        } catch let error as BridgeFailure { #expect(error.code == "bluetooth_focus_mtu") }
        #expect(writes == [10] && p.result.steps[1].submittedUptime == nil)
    }
    @MainActor @Test func developmentGateDoesNotInitializeBluetooth() async throws {
        let discovery = Pocket3BluetoothDiscovery()
        do {
            _ = try await discovery.probeTapFocus(request: request(), permit: OperationPermit(), validateCapture: {}, validateCaptureSynchronously: {})
            Issue.record("A normal test process must not enable the developer probe")
        } catch let error as BridgeFailure { #expect(error.code == "validation_disabled") }
        #expect(!discovery.isBluetoothInitialized)
    }
}
