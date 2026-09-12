import Foundation

/// The coordinate contract required before an ActiveTrack A6 write may run.
/// The current product has no calibrated rotation/mirror mapping, so every
/// live caller supplies `.unverified` and execution is rejected by the
/// validation service. A future owner may opt into native camera coordinates
/// only after independently proving that mapping.
public enum Pocket3TrackingCoordinateCalibration: String, Codable, Sendable,
    Equatable, CaseIterable {
    case unverified
    case cameraNativeCoordinates
}

public enum NativeActiveTrackValidationOperation: String, Codable, Sendable,
    Equatable, CaseIterable {
    case set
    case clear
}

public enum NativeActiveTrackValidationError: Error, Equatable, Sendable {
    case invalidTrackingID
    case invalidRequestIdentity
    case invalidTimeout
    case sessionNotReady
    case missingSessionIdentity
    case baselineRequired
    case invalidBaseline
    case operationInFlight
    case staleTransaction
    case uncalibratedCoordinates
}

/// JSON/CLI contract for one developer-only ActiveTrack validation attempt.
/// Session and generation identity are part of the request so a caller cannot
/// silently reuse a plan after the native session has changed.
public struct NativeActiveTrackValidationRequest: Codable, Sendable, Equatable {
    public static let operation = "validation-wireless-tracking"

    public let action: NativeActiveTrackValidationOperation
    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let trackingID: UInt16?
    public let box: Pocket3TrackingBox?
    public let execute: Bool
    public let timeout: TimeInterval

    public init(action: NativeActiveTrackValidationOperation,
                expectedSessionID: UUID, peripheralID: UUID,
                generation: UInt64, trackingID: UInt16? = nil,
                box: Pocket3TrackingBox? = nil, execute: Bool = false,
                timeout: TimeInterval = 3) throws {
        guard generation > 0, timeout.isFinite, timeout > 0,
              timeout <= NativeCommandTransactionRequest.maximumTimeout else {
            throw NativeActiveTrackValidationError.invalidTimeout
        }
        switch action {
        case .set:
            guard let trackingID, trackingID > 0, box != nil else {
                throw NativeActiveTrackValidationError.invalidTrackingID
            }
        case .clear:
            guard trackingID == nil, box == nil else {
                throw NativeActiveTrackValidationError.invalidTrackingID
            }
        }
        self.action = action
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.trackingID = trackingID
        self.box = box
        self.execute = execute
        self.timeout = timeout
    }

    /// Strict IPC decoder used by the App handler. Coordinates stay as
    /// individual normalized numbers in the external contract so CLI users
    /// can see exactly which value failed validation.
    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments else {
            throw BridgeFailure("invalid_active_track_validation_arguments",
                "ActiveTrack validation requires an object of action and exact session options")
        }
        let allowed = Set(["action", "expectedSessionID", "peripheralID", "generation",
                           "id", "x", "y", "width", "height", "execute", "timeout"])
        guard Set(fields.keys).isSubset(of: allowed),
              let actionRaw = fields["action"]?.string,
              let action = NativeActiveTrackValidationOperation(rawValue: actionRaw),
              let expectedSessionID = fields["expectedSessionID"]?.string.flatMap(UUID.init(uuidString:)),
              let peripheralID = fields["peripheralID"]?.string.flatMap(UUID.init(uuidString:)),
              let generationValue = fields["generation"]?.number,
              generationValue.isFinite, generationValue.rounded() == generationValue,
              generationValue >= 1, generationValue < 18_446_744_073_709_551_616,
              let generation = UInt64(exactly: generationValue) else {
            throw BridgeFailure("invalid_active_track_validation_arguments",
                "Pass action, exact BLE session/peripheral UUIDs and a positive native generation")
        }
        let execute: Bool
        if let value = fields["execute"] {
            guard let parsed = value.bool else {
                throw BridgeFailure("invalid_active_track_validation_execute",
                    "execute must be a Boolean")
            }
            execute = parsed
        } else {
            execute = false
        }
        let timeout: TimeInterval
        if let value = fields["timeout"] {
            guard let parsed = value.number, parsed.isFinite, parsed > 0,
                  parsed <= NativeCommandTransactionRequest.maximumTimeout else {
                throw BridgeFailure("invalid_active_track_validation_timeout",
                    "timeout must be between 0 and 5 seconds")
            }
            timeout = parsed
        } else {
            timeout = 3
        }

        let trackingID: UInt16?
        let box: Pocket3TrackingBox?
        switch action {
        case .set:
            guard let id = fields["id"]?.number, id.isFinite,
                  id.rounded() == id, id >= 1, id <= 65_535,
                  let x = fields["x"]?.number, let y = fields["y"]?.number,
                  let width = fields["width"]?.number, let height = fields["height"]?.number,
                  let parsedID = UInt16(exactly: id) else {
                throw BridgeFailure("invalid_active_track_box",
                    "set requires id and finite x/y/width/height in normalized camera coordinates")
            }
            do {
                box = try Pocket3TrackingBox(centerX: x, centerY: y,
                                             width: width, height: height)
            } catch {
                throw BridgeFailure("invalid_active_track_box",
                    "The normalized tracking box must stay within 0...1 and have sides between 0.02 and 1")
            }
            trackingID = parsedID
        case .clear:
            guard fields["id"] == nil, fields["x"] == nil, fields["y"] == nil,
                  fields["width"] == nil, fields["height"] == nil else {
                throw BridgeFailure("invalid_active_track_validation_arguments",
                    "clear accepts no id or box coordinates")
            }
            trackingID = nil
            box = nil
        }
        try self.init(action: action, expectedSessionID: expectedSessionID,
                      peripheralID: peripheralID, generation: generation,
                      trackingID: trackingID, box: box, execute: execute,
                      timeout: timeout)
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        let names = ["--action": "action", "--session": "expectedSessionID",
                     "--peripheral": "peripheralID", "--generation": "generation",
                     "--id": "id", "--x": "x", "--y": "y",
                     "--width": "width", "--height": "height", "--timeout": "timeout"]
        while index < cliArguments.count {
            let argument = cliArguments[index]
            if argument == "--execute" {
                guard fields["execute"] == nil else {
                    throw BridgeFailure("usage", "Duplicate --execute")
                }
                fields["execute"] = .bool(true)
                index += 1
                continue
            }
            guard let key = names[argument], index + 1 < cliArguments.count,
                  fields[key] == nil else {
                throw BridgeFailure("usage", "Unknown, duplicate or incomplete ActiveTrack validation option")
            }
            let value = cliArguments[index + 1]
            switch key {
            case "action", "expectedSessionID", "peripheralID":
                fields[key] = .string(value)
            case "generation", "id", "x", "y", "width", "height", "timeout":
                guard let number = Double(value), number.isFinite else {
                    throw BridgeFailure("usage", "ActiveTrack numeric options must be finite numbers")
                }
                fields[key] = .number(number)
            default:
                throw BridgeFailure("usage", "Unknown ActiveTrack validation option")
            }
            index += 2
        }
        try self.init(arguments: .object(fields))
    }

    public var arguments: JSONValue {
        var fields: [String: JSONValue] = [
            "action": .string(action.rawValue),
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString),
            "generation": .number(Double(generation)),
            "execute": .bool(execute),
            "timeout": .number(timeout)
        ]
        if let trackingID { fields["id"] = .number(Double(trackingID)) }
        if let box {
            fields["x"] = .number(box.centerX)
            fields["y"] = .number(box.centerY)
            fields["width"] = .number(box.width)
            fields["height"] = .number(box.height)
        }
        return .object(fields)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "action": .object(["type": .string("string"),
                                 "enum": .array([.string("set"), .string("clear")])]),
            "expectedSessionID": .object(["type": .string("string"), "minLength": .number(1)]),
            "peripheralID": .object(["type": .string("string"), "minLength": .number(1)]),
            "generation": .object(["type": .string("integer"), "minimum": .number(1)]),
            "id": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(65_535)]),
            "x": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)]),
            "y": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)]),
            "width": .object(["type": .string("number"), "minimum": .number(0.02), "maximum": .number(1)]),
            "height": .object(["type": .string("number"), "minimum": .number(0.02), "maximum": .number(1)]),
            "execute": .object(["type": .string("boolean")]),
            "timeout": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(5)])
        ]),
        "required": .array([.string("action"), .string("expectedSessionID"),
                             .string("peripheralID"), .string("generation")]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }
}

/// Readback supplied by a transport owner after one A6 transaction. The
/// executor may wait for unsolicited A5/A89 notifications, but it may not
/// submit another command or transform their coordinates.
public struct NativeActiveTrackExecutionResult: Codable, Sendable, Equatable {
    public let transaction: NativeCommandTransactionResult
    public let observations: [Pocket3ActiveTrackObservation]

    public init(transaction: NativeCommandTransactionResult,
                observations: [Pocket3ActiveTrackObservation] = []) {
        self.transaction = transaction
        self.observations = observations
    }
}

public struct NativeActiveTrackValidationExecutorAdapter: Sendable {
    public typealias Execute = @Sendable (
        _ request: NativeCommandTransactionRequest,
        _ readiness: NativeCameraSessionStatus
    ) async throws -> NativeActiveTrackExecutionResult

    private let body: Execute

    public init(_ body: @escaping Execute) { self.body = body }

    public func execute(_ request: NativeCommandTransactionRequest,
                        readiness: NativeCameraSessionStatus) async throws -> NativeActiveTrackExecutionResult {
        try await body(request, readiness)
    }
}

/// Snapshot captured by the selected BLE/native owner. It is input only; the
/// coordinator never polls, pairs, joins Wi-Fi, or starts a transport.
public struct NativeActiveTrackValidationSnapshot: Codable, Sendable, Equatable {
    public let session: NativeCameraSessionStatus
    public let baseline: [Pocket3ActiveTrackObservation]
    public let coordinateCalibration: Pocket3TrackingCoordinateCalibration
    public let nowUptime: TimeInterval

    public init(session: NativeCameraSessionStatus,
                baseline: [Pocket3ActiveTrackObservation],
                coordinateCalibration: Pocket3TrackingCoordinateCalibration = .unverified,
                nowUptime: TimeInterval) {
        self.session = session
        self.baseline = baseline
        self.coordinateCalibration = coordinateCalibration
        self.nowUptime = nowUptime
    }
}

public struct NativeActiveTrackValidationRequestEvidence: Codable, Sendable, Equatable {
    public let id: UUID
    public let command: NativeCameraSessionCommand
    public let sessionID: UUID?
    public let generation: UInt64
    public let frame: NativeCommandFrame
    public let timeout: TimeInterval

    init(_ request: NativeCommandTransactionRequest) {
        id = request.id
        command = request.command
        sessionID = request.sessionID
        generation = request.generation
        frame = request.frame
        timeout = request.timeout
    }
}

public enum NativeActiveTrackValidationPhase: String, Codable, Sendable,
    Equatable, CaseIterable {
    case idle
    case awaitingAcknowledgment
    case awaitingReadback
    case completed
    case timedOut
    case cancelled
    case generationChanged
    case failed
}

/// One bounded set/clear result. A5 and A89 observations are exposed as
/// separate evidence; neither field implies a rotation, mirror or physical
/// camera association beyond the exact session fence.
public struct NativeActiveTrackValidationResult: Codable, Sendable, Equatable {
    public let action: NativeActiveTrackValidationOperation
    public let trackingID: UInt16?
    public let targetBox: Pocket3TrackingBox?
    public let executeRequested: Bool
    public let request: NativeActiveTrackValidationRequestEvidence
    public let phase: NativeActiveTrackValidationPhase
    public let transaction: NativeCommandTransactionResult?
    public let a5Readback: Pocket3ActiveTrackObservation?
    public let a89Readback: Pocket3ActiveTrackObservation?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let failureCode: String?

    public var dryRun: Bool { !executeRequested }
}

/// Pure ActiveTrack A6 coordinator. It only builds one request and consumes
/// one transaction plus post-ACK readbacks supplied by an owner.
public struct NativeActiveTrackValidationCoordinator: Sendable {
    public static let maximumReadbackAge: TimeInterval = 5
    public static let defaultTransactionTimeout: TimeInterval = 3

    public let sessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public private(set) var phase: NativeActiveTrackValidationPhase = .idle
    public private(set) var action: NativeActiveTrackValidationOperation?
    public private(set) var trackingID: UInt16?
    public private(set) var targetBox: Pocket3TrackingBox?
    public private(set) var request: NativeCommandTransactionRequest?
    public private(set) var transaction: NativeCommandTransactionResult?
    public private(set) var a5Readback: Pocket3ActiveTrackObservation?
    public private(set) var a89Readback: Pocket3ActiveTrackObservation?
    public private(set) var failureCode: String?

    private var baselineA5: Pocket3ActiveTrackObservation?
    private var baselineA89: Pocket3ActiveTrackObservation?

    public init(session: NativeCameraSessionStatus) throws {
        guard session.generation > 0 else {
            throw NativeActiveTrackValidationError.sessionNotReady
        }
        guard session.state.satisfies(.commandReady) else {
            throw NativeActiveTrackValidationError.sessionNotReady
        }
        guard let sessionID = session.sessionID,
              let peripheralID = session.peerID else {
            throw NativeActiveTrackValidationError.missingSessionIdentity
        }
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        generation = session.generation
    }

    public mutating func prepare(
        _ request: NativeActiveTrackValidationRequest,
        baseline: [Pocket3ActiveTrackObservation],
        nowUptime: TimeInterval
    ) throws -> NativeCommandTransactionRequest {
        guard phase == .idle else {
            throw NativeActiveTrackValidationError.operationInFlight
        }
        guard request.expectedSessionID == sessionID,
              request.peripheralID == peripheralID,
              request.generation == generation else {
            throw NativeActiveTrackValidationError.invalidRequestIdentity
        }
        guard nowUptime.isFinite else {
            throw NativeActiveTrackValidationError.invalidTimeout
        }
        let expectedBinding = Pocket3ActiveTrackObservation.bluetoothBinding(sessionID: sessionID)
        let fresh = baseline.filter {
            $0.sessionID == sessionID && $0.peripheralID == peripheralID &&
                $0.binding == expectedBinding &&
                $0.isFresh(nowUptime: nowUptime, maximumAge: Self.maximumReadbackAge) &&
                $0.receivedUptime < nowUptime
        }
        guard let a5 = fresh.last(where: { $0.commandID == 0xA5 }),
              let a89 = fresh.last(where: { $0.commandID == 0x89 }) else {
            throw NativeActiveTrackValidationError.baselineRequired
        }
        guard Self.isKnownBaseline(a5, commandID: 0xA5),
              Self.isKnownBaseline(a89, commandID: 0x89) else {
            throw NativeActiveTrackValidationError.invalidBaseline
        }

        let command: Pocket3TrackingCommand
        switch request.action {
        case .set:
            guard let trackingID = request.trackingID, let box = request.box else {
                throw NativeActiveTrackValidationError.invalidTrackingID
            }
            self.trackingID = trackingID
            targetBox = box
            command = .setBox(id: trackingID, box: box)
        case .clear:
            trackingID = nil
            targetBox = nil
            command = .clearBox
        }
        let frame = NativeCommandFrame(frame: command.frame(sequence: 0))
        let nativeRequest = try NativeCommandTransactionRequest(
            command: .tracking, generation: generation, sessionID: sessionID,
            frame: frame, timeout: request.timeout)
        self.action = request.action
        self.request = nativeRequest
        transaction = nil
        a5Readback = nil
        a89Readback = nil
        failureCode = nil
        baselineA5 = a5
        baselineA89 = a89
        phase = .awaitingAcknowledgment
        return nativeRequest
    }

    /// Blocks execution while retaining the prepared request as a dry-run
    /// plan. This is the explicit safety fence for unknown rotation/mirror.
    @discardableResult
    public mutating func blockExecution(reason: String = "active_track_coordinate_uncalibrated") -> Bool {
        guard phase == .awaitingAcknowledgment else { return false }
        failureCode = reason
        phase = .failed
        return true
    }

    @discardableResult
    public mutating func apply(_ transaction: NativeCommandTransactionResult,
                               nowUptime: TimeInterval? = nil) -> Bool {
        guard let request, request.id == transaction.id,
              transaction.command == .tracking,
              transaction.generation == generation,
              transaction.sessionID == sessionID else {
            failureCode = "active_track_stale_transaction"
            phase = .generationChanged
            return false
        }
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            if self.transaction == nil { self.transaction = transaction }
            return false
        }
        self.transaction = transaction
        if let nowUptime, !nowUptime.isFinite {
            failureCode = "active_track_invalid_clock"
            phase = .failed
            return false
        }
        switch transaction.end {
        case .cancelled:
            failureCode = transaction.failureCode ?? "cancelled"
            phase = .cancelled
            return false
        case .generationChanged:
            failureCode = transaction.failureCode ?? "active_track_connection_changed"
            phase = .generationChanged
            return false
        case .timedOut:
            failureCode = transaction.failureCode ?? "active_track_ack_timeout"
            phase = .timedOut
            return false
        case .rejected, .failed:
            failureCode = transaction.failureCode ?? "active_track_command_failed"
            phase = .failed
            return false
        case .acknowledged, .observed:
            guard transaction.acknowledged else {
                failureCode = transaction.failureCode ?? "active_track_ack_invalid"
                phase = .failed
                return false
            }
            phase = .awaitingReadback
        }
        return tryComplete(nowUptime: nowUptime ?? transaction.finishedUptime ?? transaction.acknowledgedUptime ?? 0)
    }

    /// Accepts only a fresh, same-session A5/A89 observation received after
    /// the correlated ACK. No coordinate transform or orientation inference
    /// occurs here.
    @discardableResult
    public mutating func observe(_ observation: Pocket3ActiveTrackObservation,
                                 nowUptime: TimeInterval) -> Bool {
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback,
              let transaction,
              transaction.acknowledged,
              let ackUptime = transaction.acknowledgedUptime,
              observation.sessionID == sessionID,
              observation.peripheralID == peripheralID,
              observation.binding == Pocket3ActiveTrackObservation.bluetoothBinding(sessionID: sessionID),
              observation.receivedUptime > ackUptime,
              observation.isFresh(nowUptime: nowUptime, maximumAge: Self.maximumReadbackAge) else {
            return false
        }
        switch observation.commandID {
        case 0xA5:
            guard Self.isKnownBaseline(observation, commandID: 0xA5) else {
                failureCode = "active_track_a5_invalid"
                return false
            }
            a5Readback = observation
        case 0x89:
            guard Self.isKnownBaseline(observation, commandID: 0x89) else {
                failureCode = "active_track_a89_invalid"
                return false
            }
            a89Readback = observation
        default:
            return false
        }
        return tryComplete(nowUptime: nowUptime)
    }

    private mutating func tryComplete(nowUptime: TimeInterval) -> Bool {
        guard let action, let a5Readback, let a89Readback else { return false }
        guard a5Readback.receivedUptime > (transaction?.acknowledgedUptime ?? 0),
              a89Readback.receivedUptime > (transaction?.acknowledgedUptime ?? 0) else { return false }
        switch action {
        case .set:
            guard case .locked = a5Readback.state,
                  case .subjectBox(let observedBox) = a89Readback.state,
                  observedBox == targetBox else {
                failureCode = "active_track_box_readback_mismatch"
                return false
            }
        case .clear:
            // A5 idle is the clear state. A89 is required as an independent
            // post-ACK camera readback, but its box is never interpreted as a
            // transformed target after a clear.
            guard case .idle = a5Readback.state,
                  case .subjectBox = a89Readback.state else {
                failureCode = "active_track_clear_readback_incomplete"
                return false
            }
        }
        phase = .completed
        failureCode = nil
        _ = nowUptime
        return true
    }

    public func result(executeRequested: Bool) -> NativeActiveTrackValidationResult {
        guard let request else {
            preconditionFailure("ActiveTrack validation result requires a prepared request")
        }
        return NativeActiveTrackValidationResult(
            action: action ?? .clear, trackingID: trackingID, targetBox: targetBox,
            executeRequested: executeRequested,
            request: .init(request),
            phase: phase, transaction: transaction, a5Readback: a5Readback,
            a89Readback: a89Readback, requested: true,
            submitted: transaction?.submitted == true,
            acknowledged: transaction?.acknowledged == true,
            observed: a5Readback != nil && a89Readback != nil,
            completed: phase == .completed, failureCode: failureCode)
    }

    private static func isKnownBaseline(_ observation: Pocket3ActiveTrackObservation,
                                        commandID: UInt8) -> Bool {
        guard observation.commandID == commandID else { return false }
        switch observation.state {
        case .unknown:
            return false
        case .idle, .locked:
            return commandID == 0xA5
        case .subjectBox:
            return commandID == 0x89
        }
    }
}

/// Validation service with an injectable owner boundary. The current CLI
/// passes no adapter and `.unverified` calibration, so execute can never send
/// A6. Tests may inject a fake owner to prove ACK/readback completion rules.
public struct NativeActiveTrackValidationService: Sendable {
    public static let defaultTimeout: TimeInterval = 3

    private let executor: NativeActiveTrackValidationExecutorAdapter?

    public init(adapter: NativeActiveTrackValidationExecutorAdapter? = nil) {
        self.executor = adapter
    }

    public func run(_ request: NativeActiveTrackValidationRequest,
                    snapshot: NativeActiveTrackValidationSnapshot) async throws
        -> NativeActiveTrackValidationResult {
        guard request.expectedSessionID == snapshot.session.sessionID,
              request.peripheralID == snapshot.session.peerID,
              request.generation == snapshot.session.generation else {
            throw NativeActiveTrackValidationError.invalidRequestIdentity
        }
        guard snapshot.nowUptime.isFinite else {
            throw NativeActiveTrackValidationError.invalidTimeout
        }
        var coordinator = try NativeActiveTrackValidationCoordinator(session: snapshot.session)
        _ = try coordinator.prepare(request, baseline: snapshot.baseline,
                                    nowUptime: snapshot.nowUptime)
        guard request.execute else {
            return coordinator.result(executeRequested: false)
        }
        guard snapshot.coordinateCalibration == .cameraNativeCoordinates else {
            _ = coordinator.blockExecution()
            return coordinator.result(executeRequested: true)
        }
        guard let executor else {
            _ = coordinator.blockExecution(reason: "active_track_executor_unavailable")
            return coordinator.result(executeRequested: true)
        }
        let execution: NativeActiveTrackExecutionResult
        do {
            execution = try await executor.execute(
                coordinator.request!, readiness: snapshot.session)
        } catch is CancellationError {
            _ = coordinator.blockExecution(reason: "cancelled")
            return coordinator.result(executeRequested: true)
        } catch {
            _ = coordinator.blockExecution(reason: "active_track_executor_failed")
            return coordinator.result(executeRequested: true)
        }
        _ = coordinator.apply(execution.transaction,
                              nowUptime: execution.transaction.finishedUptime)
        for observation in execution.observations {
            _ = coordinator.observe(observation,
                                    nowUptime: max(snapshot.nowUptime,
                                                   observation.receivedUptime))
        }
        return coordinator.result(executeRequested: true)
    }
}
