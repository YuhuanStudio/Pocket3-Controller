import Foundation
import Testing
@testable import Pocket3Core

@Suite("BLE-native stop sample identities") struct NativeStopBLEIdentityTests {
    private func frame(sequence: UInt16, source: UInt8 = 4, commandID: UInt8 = 5, payload: Data = Data([8, 7, 0, 0, 0, 0])) -> DUMLFrame {
        DUMLFrame(source: source, destination: 2, sequence: sequence, flags: 0, commandSet: 4, commandID: commandID, payload: payload)
    }
    @Test func BLEAdmissionUsesActualSourceAndSequenceWithAnObservedBaseline() {
        var admission = NativeBLETelemetrySequenceAdmission(baselineSequence: 0xfffe)
        let old = admission.accept(frame(sequence: 0xfffd))
        let same = admission.accept(frame(sequence: 0xfffe))
        let next = admission.accept(frame(sequence: 0xffff))
        let wrapped = admission.accept(frame(sequence: 0))
        let duplicate = admission.accept(frame(sequence: 0))
        let ambiguous = admission.accept(frame(sequence: 0x8000))
        #expect(old == nil && same == nil)
        #expect(next == .bluetooth(source: 4, messageSequence: 0xffff))
        #expect(wrapped == .bluetooth(source: 4, messageSequence: 0))
        #expect(duplicate == nil && ambiguous == nil)
        #expect(admission.lastAcceptedSequence == 0)
        for invalid in [frame(sequence: 1, source: 0x48), frame(sequence: 1, commandID: 0x27),
                        frame(sequence: 1, payload: Data(repeating: 0, count: 5)), frame(sequence: 1, payload: Data([0xff, 0x7f, 0, 0, 0, 0]))] {
            let accepted = admission.accept(invalid)
            #expect(accepted == nil && admission.lastAcceptedSequence == 0)
        }
    }
    @Test func BLEProofNeedsRealSequenceProgressRatherThanInventedReceiptNumbers() {
        var admission = NativeBLETelemetrySequenceAdmission(baselineSequence: 40)
        var verifier = NativeStopTelemetryVerifier(neutralSentUptime: 1000)
        for (index, sequence) in [UInt16(41), 41, 40, 42, 43].enumerated() {
            let time = 1000.01 + Double(index) * 0.1
            if let identity = admission.accept(frame(sequence: sequence)) {
                let telemetry = Pocket3DatalinkTelemetry(pitchDegrees: 180, rollDegrees: 0, yawDegrees: 0,
                    receivedAt: Date(timeIntervalSince1970: time))
                verifier.receive(telemetry, receivedUptime: time, identity: identity, now: time)
            }
        }
        #expect(verifier.sampleCount == 3)
        #expect(verifier.isStable(now: 1000.41))
    }
    @Test func OneStabilityWindowCannotMixUDPAndBluetoothSamples() {
        var verifier = NativeStopTelemetryVerifier(neutralSentUptime: 1000)
        for (index, identity) in [NativeStopReceiveIdentity.bluetooth(source: 4, messageSequence: 1),
                                  .udp(packetSequence: 2, messageSequence: 2), .bluetooth(source: 5, messageSequence: 3)].enumerated() {
            let time = 1000.01 + Double(index) * 0.1
            verifier.receive(.init(pitchDegrees: 0, rollDegrees: 0, yawDegrees: 0, receivedAt: Date(timeIntervalSince1970: time)),
                receivedUptime: time, identity: identity, now: time)
        }
        #expect(verifier.sampleCount == 1)
        #expect(!verifier.isStable(now: 1000.21))
    }
}
