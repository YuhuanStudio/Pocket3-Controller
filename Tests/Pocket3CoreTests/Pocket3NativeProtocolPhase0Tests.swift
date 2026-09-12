import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 native protocol Phase 0 data layer")
struct Pocket3NativeProtocolPhase0Tests {
    private func floatBytes(_ value: Double) -> [UInt8] {
        var bits = Float(value).bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Array($0) }
    }

    private func hex(_ value: String) -> Data {
        let chars = Array(value)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }

    @Test func bodyFormatCapabilityDecodesPortraitAndSquareValuesAndRetainsUnknowns() throws {
        // 01 | inner length 19 | six entries × (resolution, fps, flags).
        let fixture = hex("011300064203004302006c03006903006a02006b0300")
        let capabilities = try #require(CameraVideoFormatCapabilityDecoder.decode(fixture))
        #expect(capabilities.knownVersion)
        #expect(capabilities.entryCountRaw == 6 && capabilities.entries.count == 6)
        #expect(capabilities.entries.map(\.resolutionRaw) == [0x42, 0x43, 0x6C, 0x69, 0x6A, 0x6B])
        #expect(capabilities.entries[0].resolution == .portrait1080)
        #expect(capabilities.entries[1].resolution == .portrait2_7K)
        #expect(capabilities.entries[2].resolution == .portrait3K)
        #expect(capabilities.entries[3].resolution?.aspect == .oneByOne)
        #expect(capabilities.entries[5].aspect == .oneByOne)
        #expect(capabilities.entries[0].frameRate == .fps30)
        #expect(capabilities.entries[1].frameRate == .fps25)
        #expect(capabilities.contains(resolution: .portrait3K, frameRate: .fps30))

        let unknownFixture = hex("01070002feff7f420300")
        let unknown = try #require(CameraVideoFormatCapabilityDecoder.decode(unknownFixture))
        #expect(unknown.entries.count == 2)
        #expect(unknown.entries[0].resolution == nil && unknown.entries[0].frameRate == nil)
        #expect(unknown.entries[0].resolutionRaw == 0xFE && unknown.entries[0].frameRateRaw == 0xFF)
        #expect(unknown.entries[0].reservedRaw == 0x7F && unknown.hasUnknownEntries)
        #expect(unknown.raw == unknownFixture)
    }

    @Test func bodyFormatCapabilityRejectsOnlyBrokenEnvelopeAndCommandUsesThePair() throws {
        #expect(CameraVideoFormatCapabilityDecoder.decode(hex("010b0003420300")) == nil)
        #expect(CameraVideoFormatCapabilityDecoder.decode(hex("01020000")) == nil)

        let fixture = try #require(CameraVideoFormatCapabilityDecoder.decode(
            hex("01040001420300")))
        let command = try #require(CameraBodyRecordingFormatCommand(
            capability: fixture.entries[0], slowMotionMultiplier: .x4))
        #expect(command.payload == Data([0x42, 0x03, 0x00, 0x04, 0x00]))
        #expect(command.isAllowed(by: fixture))
        let frame = command.frame(sequence: 0x1201)
        #expect(frame.source == 0x02 && frame.destination == 0x01 && frame.flags == 0x40)
        #expect(frame.commandSet == 0x02 && frame.commandID == 0x18 && frame.sequence == 0x1201)
        #expect(try DUMLCodec.decode(command.encodedFrame(sequence: 0x1201)) == frame)
        #expect(CameraVideoResolution.portrait3K.aspect == .nineBySixteen)
        #expect(CameraVideoResolution.square1080.aspect == .oneByOne)
    }

    @Test func gimbalShortcutsEncodeDistinctFE08AndFE09PayloadsAndUnknownsStayRaw() throws {
        for (shortcut, code) in [(Pocket3GimbalShortcut.recenter, UInt8(0x08)),
                                 (.flip, UInt8(0x09))] {
            let frame = shortcut.frame(sequence: 9)
            #expect(frame.source == 2 && frame.destination == 4 && frame.flags == 0x40)
            #expect(frame.commandSet == 4 && frame.commandID == 0x4C)
            #expect(frame.payload == Data([0xFE, code]))
            #expect(try DUMLCodec.decode(shortcut.encodedFrame(sequence: 9)) == frame)
            #expect(Pocket3GimbalShortcutPayload.decode(frame.payload)
                    == (code == 0x08 ? .recenter : .flip))
        }
        #expect(Pocket3GimbalShortcutPayload.decode(Data([0xFE, 0x0A, 0x99])) == .unknown(Data([0xFE, 0x0A, 0x99])))
        #expect(Pocket3GimbalShortcutPayload.decode(Data([0xFE])) == nil)
    }

    @Test func gimbal040x50ModeSpeedCommandsAndReadbackPreserveRawSelectors() throws {
        let get = Pocket3GimbalParameterCommand.get.frame(sequence: 1)
        #expect(get.payload == Data([0x01, 0x04, 0x05]))

        let mode = Pocket3GimbalParameterCommand.setMode(.tiltLocked).frame(sequence: 2)
        #expect(mode.payload == Data([0x00, 0x04, 0x01, 0x01]))
        let speed = Pocket3GimbalParameterCommand.setSpeed(.slow).frame(sequence: 3)
        #expect(speed.payload == Data([0x00, 0x05, 0x01, 0x02]))

        let known = try #require(Pocket3GimbalParameterReadback.decode(
            Data([0x00, 0x01, 0x04, 0x01, 0x01, 0x05, 0x01, 0x02, 0xFE])))
        #expect(known.mode == .tiltLocked && known.modeRaw == 0x01)
        #expect(known.speed == .slow && known.speedRaw == 0x02)
        #expect(known.raw.count == 9)

        let unknown = try #require(Pocket3GimbalParameterReadback.decode(
            Data([0x00, 0x01, 0x04, 0x01, 0xFE, 0x05, 0x01, 0xFD])))
        #expect(unknown.mode == nil && unknown.modeRaw == 0xFE)
        #expect(unknown.speed == nil && unknown.speedRaw == 0xFD)
        #expect(Pocket3GimbalParameterReadback.decode(Data([0x00, 0x01, 0x04])) == nil)
    }

    @Test func trackingA6A5And89UseTheCapturedSchemas() throws {
        let box = try Pocket3TrackingBox(centerX: 0.4, centerY: 0.5, width: 0.2, height: 0.3)
        let set = Pocket3TrackingCommand.setBox(id: 0x1234, box: box)
        let expectedSet = Data([0x01, 0x00, 0x00, 0x34, 0x12]
            + floatBytes(0.4) + floatBytes(0.5) + floatBytes(0.2) + floatBytes(0.3))
        #expect(set.payload == expectedSet && set.payload.count == 21)
        let setFrame = set.frame(sequence: 10)
        #expect(setFrame.source == 2 && setFrame.destination == 1 && setFrame.flags == 0x40)
        #expect(setFrame.commandSet == 2 && setFrame.commandID == 0xA6)
        #expect(Pocket3TrackingFrameDecoder.decodeBoxCommand(setFrame)
                == .setBox(id: 0x1234, box: box))

        let clear = Pocket3TrackingCommand.clearBox.frame(sequence: 11)
        #expect(clear.commandID == 0xA6 && clear.payload == Data(repeating: 0, count: 21))
        #expect(Pocket3TrackingFrameDecoder.decodeBoxCommand(clear) == .clearBox)
        let poll = Pocket3TrackingCommand.poll.frame(sequence: 12)
        #expect(poll.commandID == 0xA5 && poll.payload == Data([0]))

        let lockedPayload = Data([0, 1, 0, 0] + floatBytes(0.4) + floatBytes(0.5)
            + floatBytes(0.2) + floatBytes(0.3))
        let locked = try #require(Pocket3TrackingPollReadback.decode(lockedPayload))
        #expect(locked.state == .locked && locked.stateRaw == 1 && locked.box == box)
        #expect(Pocket3TrackingPollReadback.decode(Data([0, 0, 0, 0]))?.state == .idle)
        let futureState = try #require(Pocket3TrackingPollReadback.decode(Data([0, 0xFE, 0, 0])))
        #expect(futureState.state == nil && futureState.stateRaw == 0xFE)

        let livePayload = Data(repeating: 0, count: 5) + Data([0x07, 0xA1])
            + Data(floatBytes(0.4) + floatBytes(0.5) + floatBytes(0.2) + floatBytes(0.3))
        let liveFrame = DUMLFrame(source: 1, destination: 2, sequence: 13, flags: 0,
                                  commandSet: 2, commandID: 0x89, payload: livePayload)
        let live = try #require(Pocket3TrackingFrameDecoder.decodeLiveSubject(liveFrame))
        #expect(live.tagRaw == 0x07 && live.reservedRaw == 0xA1 && live.box == box)
        #expect(live.raw == livePayload)
        #expect(Pocket3TrackingLiveSubject.decode(Data(repeating: 0, count: 22)) == nil)
    }

    @Test func zoomB8EncodesAbsoluteRelativeAndStopAndRejectsUnsafeWrites() throws {
        let absolute = try Pocket3NativeZoomCommand(absoluteLens: 217)
        #expect(absolute.payload == Data([0x0A, 0x4E, 0xD9, 0x00]))
        #expect(Pocket3NativeZoomPayload.decode(absolute.payload) == .absoluteLens(position: 217))
        let relative = try Pocket3NativeZoomCommand(relativeSlew: 300)
        #expect(relative.payload == Data([0x03, 0x00, 0x2C, 0x01]))
        #expect(Pocket3NativeZoomPayload.decode(relative.payload) == .relativeSlew(value: 300))
        let stop = Pocket3NativeZoomCommand.stop
        #expect(stop.payload == Data([0xFF, 0x00, 0x00, 0x00]))
        #expect(Pocket3NativeZoomPayload.decode(stop.payload) == .stop)
        #expect(Pocket3NativeZoomPayload.decode(Data([0x02, 0, 0, 0])) == .unknown(Data([0x02, 0, 0, 0])))
        #expect(throws: Pocket3NativeZoomError.invalidLensPosition) {
            try Pocket3NativeZoomCommand(absoluteLens: 0)
        }
        #expect(throws: Pocket3NativeZoomError.invalidSlewValue) {
            try Pocket3NativeZoomCommand(relativeSlew: 3_001)
        }
    }

    @Test func tapFocusSequenceEmitsExactlyFourOrderedCommandsWithFloatPayloads() throws {
        let sequence = try Pocket3TapFocusSequence(x: 0.25, y: 0.75)
        let frames = sequence.frames(sequence: 0x80)
        #expect(frames.map(\.commandID) == [0x22, 0x30, 0x68, 0x32])
        #expect(frames.map(\.sequence) == [0x80, 0x80, 0x80, 0x80])
        #expect(frames.map { $0.payload.count } == [1, 21, 1, 20])
        #expect(frames[0].payload == Data([0x02]))
        #expect(frames[1].payload == Data(floatBytes(0.25) + floatBytes(0.75)
            + [UInt8](repeating: 0, count: 13)))
        #expect(frames[2].payload == Data([0x08]))
        #expect(frames[3].payload == Data([0x00, 0x02, 0x01, 0x00]
            + floatBytes(0.25) + floatBytes(0.75) + [UInt8](repeating: 0, count: 8)))
        #expect(try sequence.encodedFrames(sequence: 0x80).map(DUMLCodec.decode) == frames)

        let distinct = try sequence.frames(sequences: [1, 2, 3, 4])
        #expect(distinct.map(\.sequence) == [1, 2, 3, 4])
        #expect(throws: Pocket3NativeProtocolError.invalidTapFocusSequence) {
            try sequence.frames(sequences: [1, 1, 2, 3])
        }
        #expect(throws: Pocket3NativeProtocolError.invalidTapFocusCoordinate) {
            try Pocket3TapFocusSequence(x: 1.01, y: 0.5)
        }
    }
}
