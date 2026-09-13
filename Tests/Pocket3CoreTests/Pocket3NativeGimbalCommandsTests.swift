import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 native gimbal command shapes")
struct Pocket3NativeGimbalCommandsTests {
    @Test func timedStopUsesReviewedNotifyPayloadAndNoAckFlags() throws {
        let command = Pocket3GimbalTimedStopCommand()
        let frame = command.frame(sequence: 0x1234)
        #expect(frame.source == 0x02 && frame.destination == 0x04)
        #expect(frame.flags == 0x00)
        #expect(frame.commandSet == 0x04 && frame.commandID == 0x14)
        #expect(frame.payload == Data([
            0, 0, 0, 0, 0, 0, 0x04, 0x01
        ]))
        #expect(Pocket3GimbalTimedStopCommand.durationSeconds == 0.1)
        let encoded = try command.encodedFrame(sequence: 0x1234)
        #expect(try DUMLCodec.decode(encoded) == frame)
    }

    @Test func joystickUsesPocket3CenterAndSigned550NotifyRange() throws {
        let right = try DUMLJoystickCommand.encode(x: 1, y: 0, speed: 1)
        let left = try DUMLJoystickCommand.encode(x: -1, y: 0, speed: 1)
        let up = try DUMLJoystickCommand.encode(x: 0, y: -1, speed: 1)
        let down = try DUMLJoystickCommand.encode(x: 0, y: 1, speed: 1)
        #expect(DUMLJoystickCommand.center == 1024)
        #expect(right.yaw == 1574 && left.yaw == 474)
        #expect(up.pitch == 1574 && down.pitch == 474)
        #expect(right.frame(sequence: 1).flags == 0)
        #expect(right.payload.count == 10)
    }
}
