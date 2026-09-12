import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 audio and advanced setting codecs")
struct Pocket3AudioSettingsTests {
    private let binding = ContinuousGimbalBinding(sessionID: "native-audio-session", generation: 7)

    private func blob(byte2: UInt8 = 0x1A, count: Int = 31) -> Data {
        var value = Data((0..<count).map { UInt8($0 & 0xFF) })
        value[2] = byte2
        return value
    }

    private func responsePayload(status: UInt8 = 0, byte2: UInt8 = 0x1A, count: Int = 31) -> Data {
        Data([status]) + blob(byte2: byte2, count: count)
    }

    @Test func audioDspGetAndVariableLengthReadbackPreserveEveryByte() throws {
        let get = Pocket3AudioDSPGetCommand()
        let frame = get.frame(sequence: 0x1234)
        #expect(frame.source == 2 && frame.destination == 1 && frame.flags == 0x40)
        #expect(frame.commandSet == 2 && frame.commandID == 0xA0 && frame.payload.isEmpty)

        let payload = responsePayload(byte2: 0x3A, count: 31)
        let readback = try #require(Pocket3AudioDSPReadback.decode(payload, receivedUptime: 10))
        #expect(readback.statusRaw == 0 && readback.blob.count == 31)
        #expect(readback.raw == payload && readback.byte2Raw == 0x3A)
        #expect(readback.byte2 == .directional(.front))

        let reply = DUMLFrame(source: 1, destination: 2, sequence: 4, flags: 0xC0,
                              commandSet: 2, commandID: 0xA0, payload: payload)
        #expect(Pocket3AudioDSPReadback.decode(reply, receivedUptime: 10)?.blob == readback.blob)
        #expect(Pocket3AudioDSPReadback.decode(Data([0]), receivedUptime: 10) == nil)
        #expect(Pocket3AudioDSPReadback.decode(Data([9, 1, 2]), receivedUptime: 10) == nil)
        #expect(Pocket3AudioDSPReadback.decode(reply.with(source: 2), receivedUptime: 10) == nil)
    }

    @Test func audioDspSetPatchesOnlyConfirmedByteTwoFromFreshMatchingBaseline() throws {
        let readback = try #require(Pocket3AudioDSPReadback.decode(responsePayload(byte2: 0x3A), receivedUptime: 10))
        let baseline = try Pocket3AudioDSPBaseline(readback: readback, binding: binding)
        let setWind = try Pocket3AudioDSPSetCommand(baseline: baseline, binding: binding,
            nowUptime: 15, wind: .off)
        #expect(setWind.blob.count == baseline.blob.count)
        #expect(setWind.blob[2] == Pocket3WindNoiseReduction.off.rawValue)
        #expect(Data(setWind.blob.enumerated().filter { $0.offset != 2 }.map(\.element))
                == Data(baseline.blob.enumerated().filter { $0.offset != 2 }.map(\.element)))
        let frame = setWind.frame(sequence: 22)
        #expect(frame.commandSet == 2 && frame.commandID == 0x9F && frame.payload == setWind.blob)

        // Directional values encode wind-on; wind-on preserves the current direction.
        let preserveDirection = try Pocket3AudioDSPSetCommand(baseline: baseline, binding: binding,
            nowUptime: 15, wind: .on)
        #expect(preserveDirection.blob[2] == Pocket3DirectionalAudio.front.rawValue)
        let changeDirection = try Pocket3AudioDSPSetCommand(baseline: baseline, binding: binding,
            nowUptime: 15, directional: .frontAndBack)
        #expect(changeDirection.blob[2] == Pocket3DirectionalAudio.frontAndBack.rawValue)
        #expect(changeDirection.blob.count == 31)
    }

    @Test func audioDspSetRejectsStaleForeignUnknownAndEmptyBaselines() throws {
        let readback = try #require(Pocket3AudioDSPReadback.decode(responsePayload(), receivedUptime: 10))
        let baseline = try Pocket3AudioDSPBaseline(readback: readback, binding: binding)
        #expect(throws: Pocket3AudioDSPError.staleBaseline) {
            try Pocket3AudioDSPSetCommand(baseline: baseline, binding: binding, nowUptime: 15.001, wind: .off)
        }
        let foreign = ContinuousGimbalBinding(sessionID: binding.sessionID, generation: 8)
        #expect(throws: Pocket3AudioDSPError.sessionMismatch) {
            try Pocket3AudioDSPSetCommand(baseline: baseline, binding: foreign, nowUptime: 12, wind: .off)
        }
        #expect(throws: Pocket3AudioDSPError.noRequestedChange) {
            try Pocket3AudioDSPSetCommand(baseline: baseline, binding: binding, nowUptime: 12)
        }
        let unknownReadback = try #require(Pocket3AudioDSPReadback.decode(responsePayload(byte2: 0xFE), receivedUptime: 10))
        let unknownBaseline = try Pocket3AudioDSPBaseline(readback: unknownReadback, binding: binding)
        #expect(throws: Pocket3AudioDSPError.unsupportedBaselineFields) {
            try Pocket3AudioDSPSetCommand(baseline: unknownBaseline, binding: binding, nowUptime: 12, wind: .off)
        }
    }

    @Test func productShowcaseKeyedParameterAndColorCandidatesUseKnownSchemas() throws {
        let get = Pocket3ProductShowcaseCommand.get.frame(sequence: 1)
        #expect(get.payload == Data([0, 1, 0x3B, 0]))
        let set = Pocket3ProductShowcaseCommand.setEnabled(true).frame(sequence: 2)
        #expect(set.payload == Data([1, 1, 0x3B, 0, 2, 1, 1]))
        let disabled = Pocket3ProductShowcaseCommand.set(.off)
        #expect(disabled.payload.last == 0)

        let reply = Data([0, 0, 1, 0x3B, 0, 2, 1, 1, 0xFE])
        let readback = try #require(Pocket3ProductShowcaseReadback.decode(reply))
        #expect(readback.mode == .on && readback.modeRaw == 1 && readback.raw == reply)
        let unknown = try #require(Pocket3ProductShowcaseReadback.decode(Data([0, 0, 1, 0x3B, 0, 2, 1, 0xFE])))
        #expect(unknown.mode == nil && unknown.modeRaw == 0xFE)
        #expect(Pocket3ProductShowcaseReadback.decode(Data([0, 0, 1, 0x3B])) == nil)

        let color = Pocket3ColorProfileCommand(.dLogM).frame(sequence: 3)
        #expect(color.commandSet == 2 && color.commandID == 0x42 && color.payload == Data([0x3D]))
        let effect = Data([0, 0, 0x3D, 0, 0x06, 0x38])
        let candidate = try #require(Pocket3ColorWhiteBalanceCandidate.decode(effect))
        #expect(candidate.color == .dLogM && candidate.whiteBalance == .customKelvin(5600))
        #expect(candidate.colorRaw == 0x3D && candidate.whiteBalanceRaw == 0x06 && candidate.kelvinRaw == 0x38)
        #expect(Pocket3ColorWhiteBalanceCandidate.decode(Data([0, 0, 0, 0, 0x06])) == nil)
    }
}

private extension DUMLFrame {
    func with(source: UInt8) -> DUMLFrame {
        DUMLFrame(source: source, destination: destination, sequence: sequence, flags: flags,
                  commandSet: commandSet, commandID: commandID, payload: payload)
    }
}
