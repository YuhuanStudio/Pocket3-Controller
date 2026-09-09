import Foundation
import CryptoKit
import Testing
@testable import Pocket3Core

@Suite struct BluetoothCameraSettingWriterTests {
    let session = UUID(), peer = UUID(), capture = UUID()
    var binding: ContinuousGimbalBinding { .init(sessionID: "ble:\(session.uuidString)", generation: 0) }
    func observation(_ value: CameraSettingValue?, property: CameraSettingsProperty = .imageEffect,
                     time: Double = 100, mode: CameraExposureMode? = nil) -> CameraSettingsObservation {
        CameraSettingsObservation(property: value?.property ?? property, value: value,
            exposureMode: property == .exposure || value?.property == .exposure ? (mode ?? .automatic) : mode,
            transactionID: 77, binding: binding, receivedUptime: time)
    }
    func snapshot(_ value: CameraSettingValue = .whiteBalance(.automatic), time: Double = 100,
                  sequence: UInt16 = 40, fingerprints: [Data] = []) -> BluetoothCameraSettingsStore.AdmissionSnapshot {
        .init(observation: observation(value, time: time), sequence: sequence, fingerprints: fingerprints)
    }
    func request(_ value: CameraSettingValue = .whiteBalance(.customKelvin(5600)),
                 baseline: CameraSettingsObservation? = nil) throws -> BluetoothCameraSettingWriteRequest {
        try .init(expectedSessionID: session, peripheralID: peer, expectedCaptureSessionID: capture.uuidString,
                  command: CameraSettingCommand(value), expectedBaseline: baseline ?? observation(.whiteBalance(.automatic)))
    }
    func writer(_ value: CameraSettingValue = .whiteBalance(.customKelvin(5600)),
                baseline: BluetoothCameraSettingsStore.AdmissionSnapshot? = nil) throws -> BluetoothCameraSettingWriter {
        let baseline = baseline ?? snapshot()
        return try .init(request: request(value, baseline: baseline.observation), baseline: baseline, sequence: 7, now: 100)
    }
    func packet(_ frame: DUMLFrame) throws -> ValidatedDUMLPacket {
        var decoder = DUMLFragmentDecoder()
        return try #require(decoder.append(DUMLCodec.encode(frame), at: 100).first)
    }
    func ack(commandID: UInt8 = 0x2c, status: [UInt8] = [0], sequence: UInt16 = 7,
             source: UInt8 = 1, destination: UInt8 = 2, flags: UInt8 = 0xc0) throws -> ValidatedDUMLPacket {
        try packet(.init(source: source, destination: destination, sequence: sequence, flags: flags,
                         commandSet: 2, commandID: commandID, payload: Data(status)))
    }
    func push(_ value: CameraSettingValue?, property: CameraSettingsProperty = .imageEffect,
              sequence: UInt16 = 41, mode: CameraExposureMode = .automatic) throws -> ValidatedDUMLPacket {
        let property = value?.property ?? property
        var contents: [UInt8]
        switch value {
        case .whiteBalance(.automatic): contents = [0,0,0,0,0,0] + Array(repeating: 0, count: 10)
        case .whiteBalance(.customKelvin(let kelvin)): contents = [0,0,0,0,6,UInt8(kelvin / 100)] + Array(repeating: 0, count: 10)
        case .focus(let mode): contents = [mode == .single ? 0xb1 : 0xb2] + Array(repeating: 0, count: 46)
        case .autoEV(let thirds):
            contents = Array(repeating: 0, count: 44); contents[6] = UInt8(0x10 + thirds); contents[7] = mode.rawValue
        case nil: contents = [0,0,0,0,255,0] + Array(repeating: 0, count: 10)
        }
        let name = Array(property.rawValue.utf8)
        var bytes: [UInt8] = [2,6,0,0,88,0,0,0,0,0,0,0,0,UInt8(name.count),0]
        bytes += name; bytes += [0,0,0,0,0,0,UInt8(contents.count),0]; bytes += contents
        return try packet(.init(source: 0x28, destination: 2, sequence: sequence, flags: 0,
                                commandSet: 0, commandID: 0x99, payload: Data(bytes)))
    }
    func receive(_ writer: inout BluetoothCameraSettingWriter, _ packet: ValidatedDUMLPacket,
                 at time: Double, admitted: Bool = true, session: UUID? = nil, peer: UUID? = nil) {
        writer.receive(packet, propertyAdmitted: admitted, characteristic: "FFF5",
                       sessionID: session ?? self.session, peripheralID: peer ?? self.peer, at: time)
    }
    func submit(_ writer: inout BluetoothCameraSettingWriter,
                baseline: BluetoothCameraSettingsStore.AdmissionSnapshot? = nil, at time: Double = 100) throws {
        let sent = try writer.submitIfReady(currentBaseline: baseline ?? snapshot(), hasCredit: true,
                                            maximumWriteBytes: 64, at: time) { _, _ in }
        #expect(sent)
    }

    @Test func threeExistingCommandsWriteOnceAndNeedFullPostSubmissionWindow() throws {
        let cases: [(CameraSettingValue,CameraSettingValue)] = [
            (.whiteBalance(.customKelvin(5600)),.whiteBalance(.automatic)),
            (.focus(.single),.focus(.continuous)),(.autoEV(thirdStops: 1),.autoEV(thirdStops: 0))]
        for (target, previous) in cases {
            let baseline = snapshot(previous)
            var value = try writer(target, baseline: baseline), writes: [Data] = []
            let sent = try value.submitIfReady(currentBaseline: baseline, hasCredit: true, maximumWriteBytes: 64, at: 100) { frame, data in
                #expect(frame.source == 2 && frame.destination == 1 && frame.flags == 0x40 && frame.commandSet == 2)
                writes.append(data)
            }
            let expectedFrame = try CameraSettingCommand(target).encodedFrame(sequence: 7)
            #expect(sent && writes == [expectedFrame])
            let repeated = try value.submitIfReady(currentBaseline: baseline, hasCredit: true, maximumWriteBytes: 64, at: 100.01) { _, data in writes.append(data) }
            #expect(!repeated && writes.count == 1)
            receive(&value, try ack(commandID: CameraSettingCommand(target).commandID), at: 100.1)
            receive(&value, try push(target), at: 100.2)
            #expect(!value.result.applied && value.result.end == nil)
            value.tick(at: 102.999)
            #expect(!value.result.applied && !value.result.observationWindowComplete)
            value.tick(at: 103)
            #expect(value.result.applied && value.result.stateMatched && value.result.end == .applied)
            #expect(value.result.matchingReadbackCount == 1 && value.result.observationWindowComplete)
            #expect(!value.result.retryPerformed && !value.result.restorePerformed)
        }
    }
    @Test func ackAloneOrStateWithoutAckCannotConfirmCommandApplied() throws {
        var ackOnly = try writer(); try submit(&ackOnly)
        receive(&ackOnly, try ack(), at: 100.1)
        ackOnly.tick(at: 103)
        #expect(ackOnly.result.end == .readbackTimeout && !ackOnly.result.applied && ackOnly.result.acknowledged)
        var stateOnly = try writer(); try submit(&stateOnly)
        receive(&stateOnly, try push(.whiteBalance(.customKelvin(5600))), at: 100.1)
        stateOnly.tick(at: 103)
        #expect(stateOnly.result.stateMatched && !stateOnly.result.applied && stateOnly.result.ackTimedOut)
        #expect(stateOnly.result.end == .stateMatchedWithoutACK)
    }
    @Test func nackAndEmptyAckOverrideMatchingReadbackWithoutShorteningObservation() throws {
        for status in [[UInt8](),[0xe0],[0xd9]] {
            var value = try writer(); try submit(&value)
            receive(&value, try ack(), at: 100.1)
            receive(&value, try push(.whiteBalance(.customKelvin(5600))), at: 100.2)
            receive(&value, try ack(status: status), at: 100.3)
            receive(&value, try ack(), at: 100.4) // A duplicate success cannot erase a NACK.
            #expect(value.result.end == nil && !value.result.applied)
            value.tick(at: 103)
            #expect(value.result.stateMatched && !value.result.applied && !value.result.acknowledged)
            #expect(value.result.end == (status.isEmpty ? .invalidACK : .nack))
        }
    }
    @Test func matchingThenChangedPropertyCannotRemainAppliedEvenIfItReturns() throws {
        var value = try writer(); try submit(&value)
        receive(&value, try ack(), at: 100.1)
        receive(&value, try push(.whiteBalance(.customKelvin(5600))), at: 100.2)
        receive(&value, try push(.whiteBalance(.automatic), sequence: 42), at: 101)
        receive(&value, try push(.whiteBalance(.customKelvin(5600)), sequence: 43), at: 102)
        value.tick(at: 103)
        #expect(value.result.end == .valueChangedAfterMatch && value.result.valueChangedAfterMatch && !value.result.applied)
        #expect(value.result.latestObservation?.value == .whiteBalance(.customKelvin(5600)))
        #expect(value.result.observations.count == 3)
    }
    @Test func noOpIsExplicitAndNeverWritesOrClaimsApplied() throws {
        var value = try writer(.whiteBalance(.automatic)), writes = 0
        let sent = try value.submitIfReady(currentBaseline: snapshot(), hasCredit: true, maximumWriteBytes: 64, at: 100) { _, _ in writes += 1 }
        #expect(!sent && writes == 0 && value.result.noOp && value.result.end == .noOp)
        #expect(!value.result.localSubmitted && !value.result.applied && !value.result.stateMatched)
    }
    @Test func changedFinalBaselineBlocksWriteAfterCreditReturns() throws {
        var value = try writer(), writes = 0
        _ = try value.submitIfReady(currentBaseline: snapshot(), hasCredit: false, maximumWriteBytes: 64, at: 100) { _, _ in writes += 1 }
        do {
            _ = try value.submitIfReady(currentBaseline: snapshot(.whiteBalance(.customKelvin(4800)), time: 100.1, sequence: 41),
                hasCredit: true, maximumWriteBytes: 64, at: 100.1) { _, _ in writes += 1 }
            Issue.record("A changed baseline wrote a camera setting")
        } catch let error as BridgeFailure { #expect(error.code == "bluetooth_setting_baseline_changed") }
        #expect(writes == 0 && !value.result.localSubmitted)
    }
    @Test func boundedCreditWaitDoesNotConsumeTheThreeSecondReadbackWindow() throws {
        var value = try writer(), writes = 0
        for time in [100.0,100.1,100.2] {
            _ = try value.submitIfReady(currentBaseline: snapshot(), hasCredit: false, maximumWriteBytes: 64, at: time) { _, _ in writes += 1 }
        }
        _ = try value.submitIfReady(currentBaseline: snapshot(), hasCredit: true, maximumWriteBytes: 64, at: 100.6) { _, _ in writes += 1 }
        receive(&value, try ack(), at: 100.7)
        receive(&value, try push(.whiteBalance(.customKelvin(5600))), at: 100.8)
        value.tick(at: 103.59)
        #expect(value.result.end == nil && !value.result.observationWindowComplete)
        value.tick(at: 103.61)
        #expect(value.result.applied && writes == 1 && abs(value.result.creditWait.durationSeconds - 0.6) < 0.00001)
        var timedOut = try writer()
        _ = try timedOut.submitIfReady(currentBaseline: snapshot(), hasCredit: false, maximumWriteBytes: 64, at: 100) { _, _ in writes += 1 }
        let late = try timedOut.submitIfReady(currentBaseline: snapshot(), hasCredit: true, maximumWriteBytes: 64, at: 100.81) { _, _ in writes += 1 }
        #expect(!late && timedOut.result.end == .creditTimeout && writes == 1)
    }
    @Test func finalStoreSequenceAndFingerprintSeedRejectOldApply() throws {
        var value = try writer()
        let replay = try push(.whiteBalance(.customKelvin(5600)), sequence: 44)
        let final = snapshot(time: 100.1, sequence: 42, fingerprints: [Data(SHA256.hash(data: replay.frameData))])
        try submit(&value, baseline: final, at: 100.2)
        receive(&value, try ack(), at: 100.3)
        receive(&value, try push(.whiteBalance(.customKelvin(5600)), sequence: 41), at: 100.4)
        receive(&value, replay, at: 100.5)
        receive(&value, try push(.whiteBalance(.customKelvin(5600)), sequence: 43), at: 100.6, admitted: false)
        #expect(value.result.matchingReadbackCount == 0 && value.result.submissionBaselineSequence == 42)
        receive(&value, try push(.whiteBalance(.customKelvin(5600)), sequence: 45), at: 100.7)
        value.tick(at: 103.21)
        #expect(value.result.applied && value.result.observations.count == 1)
    }
    @Test func wrongPeerRouteSequenceAndPropertyDoNotCount() throws {
        var value = try writer(); try submit(&value)
        for wrong in [try ack(sequence: 8), try ack(source: 0x28), try ack(destination: 1), try ack(flags: 0)] {
            receive(&value, wrong, at: 100.1)
        }
        receive(&value, try ack(), at: 100.2, session: UUID())
        receive(&value, try push(.whiteBalance(.customKelvin(5600))), at: 100.3, peer: UUID())
        receive(&value, try push(.focus(.single)), at: 100.4)
        value.tick(at: 103)
        #expect(!value.result.ackReceived && value.result.observations.isEmpty && !value.result.applied)
    }
    @Test func cancelConnectionChangeAndClockFailureCannotBecomeApplied() throws {
        for reason in [BluetoothCameraSettingWriteEnd.cancelled, .connectionChanged] {
            var value = try writer(); try submit(&value)
            receive(&value, try ack(), at: 100.1)
            receive(&value, try push(.whiteBalance(.customKelvin(5600))), at: 100.2)
            value.finish(at: 100.3, reason: reason)
            value.tick(at: 103)
            #expect(value.result.end == reason && !value.result.applied && !value.result.observationWindowComplete)
        }
        var invalid = try writer(); invalid.tick(at: .nan)
        #expect(invalid.result.end == .invalidClock && invalid.result.finishedUptime?.isFinite == true)
    }
    @Test func delayedTerminalTickCannotConfirmAnExpiredProperty() throws {
        var value = try writer(); try submit(&value)
        receive(&value, try ack(), at: 100.1)
        receive(&value, try push(.whiteBalance(.customKelvin(5600))), at: 100.2)
        value.tick(at: 106) // Simulate delayed MainActor delivery, not fresh state at the deadline.
        #expect(value.result.end == .readbackTimeout && !value.result.stateMatched && !value.result.applied)
        #expect(value.result.matchingReadbackCount == 1 && value.result.latestObservation?.receivedUptime == 100.2)
    }
    @Test func typedObservationCannotSeedKnownValuesRejectedByTheWireDecoder() throws {
        var state = try CameraSettingsState(binding: binding)
        for invalid in [CameraSettingValue.whiteBalance(.customKelvin(0)), .whiteBalance(.customKelvin(5555)), .autoEV(thirdStops: 999)] {
            let accepted = state.apply(observation(invalid), now: 100)
            #expect(!accepted && state.observation(for: invalid.property) == nil)
        }
        let unknown = state.apply(observation(nil), now: 100)
        #expect(unknown && state.observation(for: .imageEffect)?.value == nil)
    }
    @Test func staleUnknownAndManualExposureBaselinesAreRejected() throws {
        for baseline in [observation(.whiteBalance(.automatic),time:94), observation(nil)] {
            do {
                let input = try request(baseline: baseline)
                _ = try BluetoothCameraSettingWriter(request: input, baseline: .init(observation: baseline, sequence: 40, fingerprints: []), sequence: 7, now: 100)
                Issue.record("Invalid baseline accepted")
            } catch {}
        }
        let manual = observation(.autoEV(thirdStops: 0),mode: .manual)
        #expect(throws: BridgeFailure.self) {
            try BluetoothCameraSettingWriter(request: request(.autoEV(thirdStops: 1), baseline: manual),
                baseline: .init(observation: manual, sequence: 40, fingerprints: []), sequence: 7, now: 100)
        }
    }
    @Test func strictRequestJSONRejectsMismatchExtraKeysAndUnknownCommandData() throws {
        let input = try request()
        let decoded = try JSONDecoder().decode(BluetoothCameraSettingWriteRequest.self, from: JSONEncoder().encode(input))
        #expect(decoded.command == input.command && decoded.expectedBaseline == input.expectedBaseline)
        guard case .object(let valid) = try input.arguments else { return }
        for changed in ["property": JSONValue.string("cam_lens_state"), "retry": .bool(true)] {
            var fields = valid; fields[changed.key] = changed.value
            #expect(throws: BridgeFailure.self) { try BluetoothCameraSettingWriteRequest(arguments: .object(fields)) }
        }
        var fields = valid
        fields["value"] = .object(["whiteBalance": .object(["_0": .object(["automatic": .object([:])])]), "gimbal": .bool(true)])
        #expect(throws: BridgeFailure.self) { try BluetoothCameraSettingWriteRequest(arguments: .object(fields)) }
    }
    @MainActor @Test func ordinaryLaunchCannotInitializeBluetoothForSettingWrite() async throws {
        let discovery = Pocket3BluetoothDiscovery()
        do {
            _ = try await discovery.writeCameraSetting(request: request(), permit: OperationPermit(), validateCapture: {}, validateCaptureSynchronously: {})
            Issue.record("A normal test process enabled a camera setting write")
        } catch let error as BridgeFailure { #expect(error.code == "validation_disabled") }
        #expect(!discovery.isBluetoothInitialized)
    }
}
