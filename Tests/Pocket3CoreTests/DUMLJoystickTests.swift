import Foundation
import Testing
@testable import Pocket3Core

@Test func joystickNeutralIsCenteredAndKeepsProtocolFlags() throws {
    let expected = Data([0,4,0,0,0,4,0,0x80,0x22,0])
    #expect(DUMLJoystickCommand.neutral.payload == expected)
    #expect(DUMLJoystickCommand.neutral.payload != Data(repeating: 0, count: 10))
    #expect(try DUMLJoystickCommand.encode(x: 0, y: 0, speed: 1) == .neutral)
    #expect(try DUMLJoystickCommand.encode(x: 1, y: 1, speed: 0) == .neutral)
    #expect(try DUMLJoystickCommand.encode(x: 0.06, y: 0, speed: 1) == .neutral)
}

@Test func joystickFrameUsesVerifiedSenderReceiverAndCommandAddress() throws {
    let command = DUMLJoystickCommand.neutral
    let frame = command.frame(sequence: 0x1234)
    #expect(frame.source == 0x02 && frame.destination == 0x04)
    #expect(frame.flags == 0 && frame.commandSet == 4 && frame.commandID == 1)
    let bytes = try command.encodedFrame(sequence: 0x1234)
    #expect(bytes.count == 23)
    #expect(Array(bytes.dropFirst(4).prefix(7)) == [0x02,0x04,0x34,0x12,0,4,1])
    #expect(try DUMLCodec.decode(bytes) == frame)
    #expect(try DUMLCodec.decode(bytes).payload == Data([0,4,0,0,0,4,0,0x80,0x22,0]))
}

@Test func joystickScreenAxesAndNormalizedSpeedHaveBoundedLinearResponse() throws {
    let right = try DUMLJoystickCommand.encode(x: 1, y: 0, speed: 1)
    let down = try DUMLJoystickCommand.encode(x: 0, y: 1, speed: 1)
    let up = try DUMLJoystickCommand.encode(x: 0, y: -1, speed: 1)
    let left = try DUMLJoystickCommand.encode(x: -1, y: 0, speed: 0.5)
    #expect(right.pitch == 1024 && right.yaw == 1354)
    #expect(down.pitch == 694 && down.yaw == 1024)
    #expect(up.pitch == 1354 && up.yaw == 1024)
    #expect(left.pitch == 1024 && left.yaw == 859)
    #expect(right.payload == Data([0,4,0,0,0x4a,5,0,0x80,0x22,0]))
}

@Test func joystickRadiallyClampsHugeFiniteDiagonalInputsWithoutOverflow() throws {
    let diagonal = try DUMLJoystickCommand.encode(x: 1, y: 1, speed: 1)
    let huge = try DUMLJoystickCommand.encode(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, speed: 1)
    #expect(diagonal == huge)
    #expect(abs(Int(diagonal.pitch)-1024) <= 234 && abs(Int(diagonal.yaw)-1024) <= 234)
    #expect(try DUMLJoystickCommand.encode(x: 100, y: 0, speed: 1) == DUMLJoystickCommand.encode(x: 1, y: 0, speed: 1))
    for bad in [Double.nan, .infinity, -.infinity] {
        #expect(throws: DUMLJoystickError.self) { try DUMLJoystickCommand.encode(x: bad, y: 0, speed: 1) }
        #expect(throws: DUMLJoystickError.self) { try DUMLJoystickCommand.encode(x: 0, y: bad, speed: 1) }
        #expect(throws: DUMLJoystickError.self) { try DUMLJoystickCommand.encode(x: 0, y: 0, speed: bad) }
    }
    for speed in [-0.1, 1.1] {
        #expect(throws: DUMLJoystickError.invalidSpeed) { try DUMLJoystickCommand.encode(x: 0, y: 0, speed: speed) }
    }
}
