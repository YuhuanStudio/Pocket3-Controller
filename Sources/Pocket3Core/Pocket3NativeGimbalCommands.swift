import Foundation

/// The explicit timed stop for a preceding native 04/14 timed-target sequence.
/// A held 04/01 joystick lease releases with its 04/01 center neutral instead;
/// this command is kept separate until a timed-target coordinator has its own
/// evidence. It is notify/no-ACK: transport completion is only evidence that
/// the packet was handed to the single UDP owner, not that the gimbal stopped.
/// Payload cross-check: OpenPocketCine Commands.swift at
/// 9b30b93572797c94db5ad9236fb746410f8d761f.
public struct Pocket3GimbalTimedStopCommand: Codable, Sendable, Equatable {
    public static let commandSet: UInt8 = 0x04
    public static let commandID: UInt8 = 0x14
    public static let source: UInt8 = 0x02
    public static let destination: UInt8 = 0x04
    public static let requestFlags: UInt8 = 0x00
    public static let durationSeconds: TimeInterval = 0.1
    public static let payload = Data([
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x04, 0x01
    ])

    public init() {}

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: Self.source, destination: Self.destination,
                  sequence: sequence, flags: Self.requestFlags,
                  commandSet: Self.commandSet, commandID: Self.commandID,
                  payload: Self.payload)
    }

    public func encodedFrame(sequence: UInt16) throws -> Data {
        try DUMLCodec.encode(frame(sequence: sequence))
    }
}

public typealias Pocket3NativeGimbalTimedStop = Pocket3GimbalTimedStopCommand
