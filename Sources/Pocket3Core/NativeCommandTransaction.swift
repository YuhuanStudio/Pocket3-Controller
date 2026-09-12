import Foundation

/// A wire-independent DUML command template.  The sequence is intentionally
/// absent: `Pocket3Datalink` is the only sequence owner and assigns it at the
/// final serialized send point.
public struct NativeCommandFrame: Codable, Sendable, Equatable {
    public let source: UInt8
    public let destination: UInt8
    public let flags: UInt8
    public let commandSet: UInt8
    public let commandID: UInt8
    public let payload: Data

    public init(source: UInt8, destination: UInt8, flags: UInt8 = 0x40,
                commandSet: UInt8, commandID: UInt8, payload: Data = Data()) throws {
        guard payload.count <= DUMLCodec.maximumPayloadLength else {
            throw NativeCommandTransactionError.invalidPayload
        }
        self.source = source; self.destination = destination; self.flags = flags
        self.commandSet = commandSet; self.commandID = commandID; self.payload = payload
    }

    public init(frame: DUMLFrame) {
        source = frame.source; destination = frame.destination; flags = frame.flags
        commandSet = frame.commandSet; commandID = frame.commandID; payload = frame.payload
    }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: source, destination: destination, sequence: sequence,
                  flags: flags, commandSet: commandSet, commandID: commandID,
                  payload: payload)
    }
}

/// Exact response route for one command.  Sequence matching is supplied by
/// the transaction owner because it is allocated only when the request is
/// submitted.  The default accepts the two response flag forms observed in
/// the existing Pocket 3 datalink path.
public struct NativeCommandResponseMatcher: Sendable, Equatable {
    public let source: UInt8
    public let destination: UInt8
    public let commandSet: UInt8
    public let commandID: UInt8
    public let acceptedFlags: Set<UInt8>

    public init(source: UInt8, destination: UInt8, commandSet: UInt8,
                commandID: UInt8, acceptedFlags: Set<UInt8> = [0x80, 0xc0]) {
        self.source = source; self.destination = destination
        self.commandSet = commandSet; self.commandID = commandID
        self.acceptedFlags = acceptedFlags
    }

    public init(for frame: NativeCommandFrame) {
        self.init(source: frame.destination, destination: frame.source,
                  commandSet: frame.commandSet, commandID: frame.commandID)
    }

    public func matches(_ frame: DUMLFrame, sequence: UInt16) -> Bool {
        frame.source == source && frame.destination == destination
            && frame.sequence == sequence && acceptedFlags.contains(frame.flags)
            && frame.commandSet == commandSet && frame.commandID == commandID
    }
}

public enum NativeCommandTransactionEnd: String, Codable, Sendable, Equatable, CaseIterable {
    case acknowledged
    case observed
    case timedOut
    case cancelled
    case generationChanged
    case rejected
    case failed
}

/// Typed evidence for one bounded command attempt.  `acknowledged` means a
/// correlated response explicitly carried a zero status byte.  It does not
/// mean the camera applied a setting; `observed` is reserved for a caller's
/// validated response/readback decoder.
public struct NativeCommandTransactionResult: Codable, Sendable, Equatable {
    public var id: UUID
    public var command: NativeCameraSessionCommand
    public var generation: UInt64
    public var sessionID: UUID?
    public var sequence: UInt16?
    public var requested: Bool
    public var submitted: Bool
    public var responseReceived: Bool
    public var acknowledged: Bool
    public var observed: Bool
    public var responseStatus: UInt8?
    public var observedPayload: Data?
    public var startedUptime: TimeInterval?
    public var submittedUptime: TimeInterval?
    public var acknowledgedUptime: TimeInterval?
    public var observedUptime: TimeInterval?
    public var finishedUptime: TimeInterval?
    public var end: NativeCommandTransactionEnd
    public var failureCode: String?

    public init(id: UUID, command: NativeCameraSessionCommand, generation: UInt64,
                sessionID: UUID? = nil,
                requested: Bool = true, end: NativeCommandTransactionEnd = .failed) {
        self.id = id; self.command = command; self.generation = generation; self.sessionID = sessionID
        sequence = nil; self.requested = requested; submitted = false
        responseReceived = false; acknowledged = false; observed = false
        responseStatus = nil; observedPayload = nil
        startedUptime = nil; submittedUptime = nil; acknowledgedUptime = nil
        observedUptime = nil; finishedUptime = nil; self.end = end; failureCode = nil
    }

    public var completed: Bool { end == .acknowledged || end == .observed }
}

public enum NativeCommandTransactionError: Error, Equatable, Sendable {
    case invalidPayload
    case invalidTimeout
    case commandNotReady
    case staleGeneration
    case datalinkUnavailable
    case nativeBusy
}

/// A request carries the generation captured by the caller's
/// `NativeCameraSession`.  `observation` is intentionally an optional pure
/// decoder: returning bytes is evidence of an observed, validated response;
/// returning nil leaves the result at ACK-only evidence.
public struct NativeCommandTransactionRequest: Sendable {
    public static let maximumTimeout: TimeInterval = 5

    public let id: UUID
    public let command: NativeCameraSessionCommand
    public let generation: UInt64
    public let sessionID: UUID?
    public let frame: NativeCommandFrame
    public let responseMatcher: NativeCommandResponseMatcher
    public let timeout: TimeInterval
    private let observation: (@Sendable (DUMLFrame) -> Data?)?

    public init(id: UUID = UUID(), command: NativeCameraSessionCommand,
                generation: UInt64, sessionID: UUID? = nil, frame: NativeCommandFrame,
                responseMatcher: NativeCommandResponseMatcher? = nil,
                timeout: TimeInterval = 2,
                observation: (@Sendable (DUMLFrame) -> Data?)? = nil) throws {
        guard generation != 0, timeout.isFinite, timeout > 0,
              timeout <= Self.maximumTimeout else {
            throw NativeCommandTransactionError.invalidTimeout
        }
        self.id = id; self.command = command; self.generation = generation; self.sessionID = sessionID
        self.frame = frame; self.responseMatcher = responseMatcher ?? .init(for: frame)
        self.timeout = timeout; self.observation = observation
    }

    public init(id: UUID = UUID(), command: NativeCameraSessionCommand,
                generation: UInt64, sessionID: UUID? = nil, frame: DUMLFrame,
                responseMatcher: NativeCommandResponseMatcher? = nil,
                timeout: TimeInterval = 2,
                observation: (@Sendable (DUMLFrame) -> Data?)? = nil) throws {
        try self.init(id: id, command: command, generation: generation, sessionID: sessionID,
                      frame: NativeCommandFrame(frame: frame),
                      responseMatcher: responseMatcher, timeout: timeout,
                      observation: observation)
    }

    func observedPayload(from frame: DUMLFrame) -> Data? { observation?(frame) }
    var hasObservation: Bool { observation != nil }
    func observationHandler() -> (@Sendable (DUMLFrame) -> Data?)? { observation }
}

/// Safe, explicit candidate requests for the Phase 1 protocol replay path.
/// These functions only construct requests; the caller must own a
/// command-ready session and explicitly invoke `Pocket3Datalink.transact`.
public enum Pocket3NativeCommandAdapter {
    public static func readGimbalParameters(generation: UInt64, sessionID: UUID? = nil,
                                            timeout: TimeInterval = 2) throws -> NativeCommandTransactionRequest {
        let frame = try NativeCommandFrame(source: Pocket3GimbalParameterCommand.source,
                                           destination: Pocket3GimbalParameterCommand.destination,
                                           flags: Pocket3GimbalParameterCommand.requestFlags,
                                           commandSet: Pocket3GimbalParameterCommand.commandSet,
                                           commandID: Pocket3GimbalParameterCommand.commandID,
                                           payload: Pocket3GimbalParameterCommand.get.payload)
        return try NativeCommandTransactionRequest(command: .gimbal, generation: generation,
            sessionID: sessionID, frame: frame, timeout: timeout) { response in
                guard response.source == frame.destination, response.destination == frame.source,
                      response.commandSet == frame.commandSet, response.commandID == frame.commandID else { return nil }
                return Pocket3GimbalParameterReadback.decode(response.payload)?.raw
            }
    }

    /// Candidate body-format SET.  It remains opt-in and does not claim that
    /// a response applied the format; a caller must provide a readback decoder
    /// in a later transaction if the camera returns one.
    public static func bodyRecordingFormatCandidate(
        _ command: CameraBodyRecordingFormatCommand,
        generation: UInt64, sessionID: UUID? = nil,
        timeout: TimeInterval = 2) throws -> NativeCommandTransactionRequest {
        let frame = try NativeCommandFrame(source: CameraBodyRecordingFormatCommand.source,
                                           destination: CameraBodyRecordingFormatCommand.destination,
                                           flags: CameraBodyRecordingFormatCommand.requestFlags,
                                           commandSet: CameraBodyRecordingFormatCommand.commandSet,
                                           commandID: CameraBodyRecordingFormatCommand.commandID,
                                           payload: command.payload)
        return try NativeCommandTransactionRequest(command: .bodyFormat, generation: generation,
            sessionID: sessionID, frame: frame, timeout: timeout)
    }
}
