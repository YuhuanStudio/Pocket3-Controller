import Foundation

/// Developer-only actions for the native `02/B8` and `04/50` paths. These
/// values are deliberately separate from the ordinary UVC zoom/gimbal tools.
public enum NativeMotionValidationOperation: String, Codable, Sendable,
    Equatable, CaseIterable {
    case zoomAbsolute = "zoom-absolute"
    case zoomRelative = "zoom-relative"
    case zoomStop = "zoom-stop"
    case gimbalMode = "gimbal-mode"
    case gimbalSpeed = "gimbal-speed"

    public static let absolute = Self.zoomAbsolute
    public static let relative = Self.zoomRelative
    public static let stop = Self.zoomStop
}

public enum NativeMotionValidationError: Error, Equatable, Sendable {
    case invalidArguments
    case invalidAction
    case invalidRequestIdentity
    case invalidTimeout
    case sessionNotReady
    case missingSessionIdentity
    case zoomBaselineRequired
    case gimbalBaselineRequired
    case invalidBaseline
    case invalidFormat
    case alreadyAtTarget
    case operationInFlight
    case staleTransaction
}

/// Strict JSON/CLI contract for one native motion validation attempt. All
/// writes are opt-in through `execute`; omission means dry-run.
public struct NativeMotionValidationRequest: Codable, Sendable, Equatable {
    public static let operation = "validation-wireless-native-motion"

    public let action: NativeMotionValidationOperation
    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let format: Pocket3NativeZoomFormat?
    public let rawValue: UInt16?
    public let mode: Pocket3GimbalMode?
    public let speed: Pocket3GimbalSpeed?
    public let execute: Bool
    public let timeout: TimeInterval

    public init(action: NativeMotionValidationOperation,
                expectedSessionID: UUID, peripheralID: UUID,
                generation: UInt64, format: Pocket3NativeZoomFormat? = nil,
                rawValue: UInt16? = nil, mode: Pocket3GimbalMode? = nil,
                speed: Pocket3GimbalSpeed? = nil, execute: Bool = false,
                timeout: TimeInterval = 3) throws {
        guard generation > 0, timeout.isFinite, timeout > 0,
              timeout <= NativeCommandTransactionRequest.maximumTimeout else {
            throw NativeMotionValidationError.invalidTimeout
        }
        switch action {
        case .zoomAbsolute, .zoomRelative:
            guard format != nil, rawValue != nil, mode == nil, speed == nil else {
                throw NativeMotionValidationError.invalidArguments
            }
        case .zoomStop:
            guard format == nil, rawValue == nil, mode == nil, speed == nil else {
                throw NativeMotionValidationError.invalidArguments
            }
        case .gimbalMode:
            guard format == nil, rawValue == nil, mode != nil, speed == nil else {
                throw NativeMotionValidationError.invalidArguments
            }
        case .gimbalSpeed:
            guard format == nil, rawValue == nil, mode == nil, speed != nil else {
                throw NativeMotionValidationError.invalidArguments
            }
        }
        self.action = action
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.format = format
        self.rawValue = rawValue
        self.mode = mode
        self.speed = speed
        self.execute = execute
        self.timeout = timeout
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              let actionRaw = fields["action"]?.string,
              let action = Self.parseAction(actionRaw),
              let sessionText = fields["expectedSessionID"]?.string,
              let expectedSessionID = UUID(uuidString: sessionText),
              let peripheralText = fields["peripheralID"]?.string,
              let peripheralID = UUID(uuidString: peripheralText),
              let generationNumber = fields["generation"]?.number,
              generationNumber.isFinite, generationNumber.rounded() == generationNumber,
              generationNumber >= 1,
              let generation = UInt64(exactly: generationNumber) else {
            throw NativeMotionValidationError.invalidArguments
        }
        let allowed = Set(["action", "expectedSessionID", "peripheralID", "generation",
                           "format", "rawValue", "mode", "speed", "execute", "timeout"])
        guard Set(fields.keys).isSubset(of: allowed) else {
            throw NativeMotionValidationError.invalidArguments
        }
        let execute: Bool
        if let value = fields["execute"] {
            guard let parsed = value.bool else { throw NativeMotionValidationError.invalidArguments }
            execute = parsed
        } else {
            execute = false
        }
        let timeout: TimeInterval
        if let value = fields["timeout"] {
            guard let parsed = value.number else { throw NativeMotionValidationError.invalidTimeout }
            timeout = parsed
        } else {
            timeout = 3
        }
        let format = fields["format"]?.string.flatMap(Self.parseFormat)
        if fields["format"] != nil && format == nil {
            throw NativeMotionValidationError.invalidFormat
        }
        let rawValue = try Self.parseRaw(fields["rawValue"])
        let mode = try Self.parseMode(fields["mode"])
        let speed = try Self.parseSpeed(fields["speed"])
        try self.init(action: action, expectedSessionID: expectedSessionID,
                      peripheralID: peripheralID, generation: generation,
                      format: format, rawValue: rawValue, mode: mode,
                      speed: speed, execute: execute, timeout: timeout)
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        let names = ["--action": "action", "--session": "expectedSessionID",
                     "--peripheral": "peripheralID", "--generation": "generation",
                     "--format": "format", "--raw": "rawValue",
                     "--mode": "mode", "--speed": "speed", "--timeout": "timeout"]
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
                throw BridgeFailure("usage", "Unknown, duplicate or incomplete native motion option")
            }
            let value = cliArguments[index + 1]
            switch key {
            case "expectedSessionID", "peripheralID", "action", "format", "mode", "speed":
                fields[key] = .string(value)
            case "generation", "rawValue", "timeout":
                guard let number = Double(value), number.isFinite else {
                    throw BridgeFailure("usage", "Native motion numeric options must be finite")
                }
                fields[key] = .number(number)
            default:
                throw BridgeFailure("usage", "Unknown native motion option")
            }
            index += 2
        }
        do {
            try self.init(arguments: .object(fields))
        } catch let error as NativeMotionValidationError {
            throw BridgeFailure("invalid_native_motion_request", String(describing: error))
        }
    }

    public var arguments: JSONValue {
        var fields: [String: JSONValue] = [
            "action": .string(action.rawValue),
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString),
            "generation": .number(Double(generation)),
            "execute": .bool(execute), "timeout": .number(timeout)
        ]
        if let format { fields["format"] = .string(format.rawValue) }
        if let rawValue { fields["rawValue"] = .number(Double(rawValue)) }
        if let mode { fields["mode"] = .string(mode == .follow ? "follow" : "tiltLocked") }
        if let speed {
            let speedName: String
            switch speed {
            case .fast: speedName = "fast"
            case .default: speedName = "default"
            case .slow: speedName = "slow"
            }
            fields["speed"] = .string(speedName)
        }
        return .object(fields)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "action": .object(["type": .string("string"),
                "enum": .array(NativeMotionValidationOperation.allCases.map { .string($0.rawValue) })]),
            "expectedSessionID": .object(["type": .string("string"), "minLength": .number(1)]),
            "peripheralID": .object(["type": .string("string"), "minLength": .number(1)]),
            "generation": .object(["type": .string("integer"), "minimum": .number(1)]),
            "format": .object(["type": .string("string"),
                "enum": .array(Pocket3NativeZoomFormat.allCases.map { .string($0.rawValue) })]),
            "rawValue": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(65_535)]),
            "mode": .object(["type": .string("string"),
                "enum": .array(Pocket3GimbalMode.allCases.map { .string(String($0.rawValue)) })]),
            "speed": .object(["type": .string("string"),
                "enum": .array(Pocket3GimbalSpeed.allCases.map { .string(String($0.rawValue)) })]),
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

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }

    private static func parseAction(_ raw: String) -> NativeMotionValidationOperation? {
        if let value = NativeMotionValidationOperation(rawValue: raw) { return value }
        return switch raw {
        case "zoomAbsolute", "absolute": .zoomAbsolute
        case "zoomRelative", "relative": .zoomRelative
        case "zoomStop", "stop": .zoomStop
        case "gimbalMode", "mode": .gimbalMode
        case "gimbalSpeed", "speed": .gimbalSpeed
        default: nil
        }
    }

    private static func parseFormat(_ raw: String) -> Pocket3NativeZoomFormat? {
        if let value = Pocket3NativeZoomFormat(rawValue: raw) { return value }
        return switch raw.lowercased() {
        case "4k", "2160p": .fourK
        case "2.7k", "2700p", "3k": .twoPointSevenK
        case "1080p", "1080": .fullHD
        default: nil
        }
    }

    private static func parseRaw(_ value: JSONValue?) throws -> UInt16? {
        guard let value else { return nil }
        guard let number = value.number, number.isFinite,
              number.rounded() == number, number >= 0,
              number <= Double(UInt16.max), let raw = UInt16(exactly: number) else {
            throw NativeMotionValidationError.invalidArguments
        }
        return raw
    }

    private static func parseMode(_ value: JSONValue?) throws -> Pocket3GimbalMode? {
        guard let value else { return nil }
        if let raw = value.string {
            switch raw.lowercased() {
            case "follow", "0": return .follow
            case "tiltlocked", "tilt-locked", "locked", "1": return .tiltLocked
            default: throw NativeMotionValidationError.invalidArguments
            }
        }
        guard let number = value.number, number.isFinite,
              number.rounded() == number, let raw = UInt8(exactly: number),
              let mode = Pocket3GimbalMode(rawValue: raw) else {
            throw NativeMotionValidationError.invalidArguments
        }
        return mode
    }

    private static func parseSpeed(_ value: JSONValue?) throws -> Pocket3GimbalSpeed? {
        guard let value else { return nil }
        if let raw = value.string {
            switch raw.lowercased() {
            case "fast", "0": return .fast
            case "default", "normal", "1": return .default
            case "slow", "2": return .slow
            default: throw NativeMotionValidationError.invalidArguments
            }
        }
        guard let number = value.number, number.isFinite,
              number.rounded() == number, let raw = UInt8(exactly: number),
              let speed = Pocket3GimbalSpeed(rawValue: raw) else {
            throw NativeMotionValidationError.invalidArguments
        }
        return speed
    }
}

/// Readiness/readback snapshot supplied by the current owner. The service
/// never queries the camera for a baseline or creates another transport.
public struct NativeMotionValidationSnapshot: Codable, Sendable, Equatable {
    public let session: NativeCameraSessionStatus
    public let zoomBaseline: Pocket3NativeLensStateObservation?
    public let gimbalBaseline: Pocket3NativeGimbalParameterObservation?
    public let nowUptime: TimeInterval

    public init(session: NativeCameraSessionStatus,
                zoomBaseline: Pocket3NativeLensStateObservation? = nil,
                gimbalBaseline: Pocket3NativeGimbalParameterObservation? = nil,
                nowUptime: TimeInterval) {
        self.session = session
        self.zoomBaseline = zoomBaseline
        self.gimbalBaseline = gimbalBaseline
        self.nowUptime = nowUptime
    }
}

public struct NativeMotionValidationRequestEvidence: Codable, Sendable, Equatable {
    public let id: UUID
    public let command: NativeCameraSessionCommand
    public let sessionID: UUID?
    public let generation: UInt64
    public let frame: NativeCommandFrame
    public let timeout: TimeInterval

    init(_ request: NativeCommandTransactionRequest) {
        id = request.id; command = request.command; sessionID = request.sessionID
        generation = request.generation; frame = request.frame; timeout = request.timeout
    }
}

public struct NativeMotionValidationResult: Codable, Sendable, Equatable {
    public let action: NativeMotionValidationOperation
    public let executeRequested: Bool
    public let request: NativeMotionValidationRequestEvidence?
    public let phase: String
    public let zoom: Pocket3NativeZoomResult?
    public let gimbal: Pocket3NativeGimbalResult?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let noOp: Bool
    public let failureCode: String?

    public var dryRun: Bool { !executeRequested }
}

public struct NativeMotionValidationExecutorAdapter: Sendable {
    public typealias Execute = @Sendable (
        _ request: NativeCommandTransactionRequest,
        _ readiness: NativeCameraSessionStatus
    ) async throws -> NativeCommandTransactionResult

    private let body: Execute

    public init(_ body: @escaping Execute) { self.body = body }

    public func execute(_ request: NativeCommandTransactionRequest,
                        readiness: NativeCameraSessionStatus) async throws
        -> NativeCommandTransactionResult {
        try await body(request, readiness)
    }
}

/// Developer-only service that owns no transport. A supplied executor is the
/// existing single `Pocket3Datalink` owner; this service invokes it at most
/// once and preserves the coordinator's partial ACK/readback evidence.
public struct NativeMotionValidationService: Sendable {
    public static let defaultTimeout: TimeInterval = 3
    private let executor: NativeMotionValidationExecutorAdapter?

    public init(adapter: NativeMotionValidationExecutorAdapter? = nil) {
        executor = adapter
    }

    public func run(_ request: NativeMotionValidationRequest,
                    snapshot: NativeMotionValidationSnapshot) async throws
        -> NativeMotionValidationResult {
        guard request.expectedSessionID == snapshot.session.sessionID,
              request.peripheralID == snapshot.session.peerID,
              request.generation == snapshot.session.generation else {
            throw NativeMotionValidationError.invalidRequestIdentity
        }
        guard snapshot.nowUptime.isFinite else {
            throw NativeMotionValidationError.invalidTimeout
        }
        switch request.action {
        case .zoomAbsolute, .zoomRelative, .zoomStop:
            guard let baseline = snapshot.zoomBaseline else {
                throw NativeMotionValidationError.zoomBaselineRequired
            }
            var coordinator = try mapZoomInit(snapshot.session)
            let action = try zoomAction(request)
            guard let format = request.format ?? (request.action == .zoomStop ? .fullHD : nil) else {
                throw NativeMotionValidationError.invalidFormat
            }
            do {
                let nativeRequest = try coordinator.prepare(action, format: format,
                    baseline: baseline, nowUptime: snapshot.nowUptime,
                    timeout: request.timeout)
                return await executeZoom(request: request, nativeRequest: nativeRequest,
                    snapshot: snapshot, coordinator: &coordinator)
            } catch Pocket3NativeZoomCoordinatorError.alreadyAtTarget {
                return zoomResult(request: request, coordinator: coordinator,
                                  executeRequested: request.execute)
            } catch let error as Pocket3NativeZoomCoordinatorError {
                throw mapZoomError(error)
            }

        case .gimbalMode, .gimbalSpeed:
            guard let baseline = snapshot.gimbalBaseline else {
                throw NativeMotionValidationError.gimbalBaselineRequired
            }
            var coordinator = try mapGimbalInit(snapshot.session)
            let target: Pocket3NativeGimbalTarget
            switch request.action {
            case .gimbalMode: guard let mode = request.mode else { throw NativeMotionValidationError.invalidAction }; target = .mode(mode)
            case .gimbalSpeed: guard let speed = request.speed else { throw NativeMotionValidationError.invalidAction }; target = .speed(speed)
            default: throw NativeMotionValidationError.invalidAction
            }
            do {
                let nativeRequest = try coordinator.prepare(target, baseline: baseline,
                    nowUptime: snapshot.nowUptime, timeout: request.timeout)
                return await executeGimbal(request: request, nativeRequest: nativeRequest,
                    snapshot: snapshot, coordinator: &coordinator)
            } catch Pocket3NativeGimbalCoordinatorError.alreadyAtTarget {
                return gimbalResult(request: request, coordinator: coordinator,
                                    executeRequested: request.execute)
            } catch let error as Pocket3NativeGimbalCoordinatorError {
                throw mapGimbalError(error)
            }
        }
    }

    private func executeZoom(request: NativeMotionValidationRequest,
                             nativeRequest: NativeCommandTransactionRequest,
                             snapshot: NativeMotionValidationSnapshot,
                             coordinator: inout Pocket3NativeZoomCoordinator)
        async -> NativeMotionValidationResult {
        guard request.execute else {
            return zoomResult(request: request, coordinator: coordinator,
                              executeRequested: false)
        }
        guard let executor else {
            _ = coordinator.blockExecution(reason: "native_motion_executor_unavailable")
            return zoomResult(request: request, coordinator: coordinator,
                              executeRequested: true)
        }
        do {
            let transaction = try await executor.execute(nativeRequest,
                readiness: snapshot.session)
            _ = coordinator.apply(transaction,
                nowUptime: transaction.finishedUptime ?? transaction.observedUptime ?? snapshot.nowUptime)
        } catch is CancellationError {
            _ = coordinator.apply(partial(nativeRequest, end: .cancelled,
                                           failureCode: "cancelled"), nowUptime: nil)
        } catch let error as NativeCommandTransactionError {
            let end: NativeCommandTransactionEnd = error == .staleGeneration
                ? .generationChanged : .failed
            _ = coordinator.apply(partial(nativeRequest, end: end,
                                           failureCode: motionFailureCode(error)), nowUptime: nil)
        } catch {
            _ = coordinator.apply(partial(nativeRequest, end: .failed,
                                           failureCode: "native_motion_executor_failed"), nowUptime: nil)
        }
        return zoomResult(request: request, coordinator: coordinator,
                          executeRequested: true)
    }

    private func executeGimbal(request: NativeMotionValidationRequest,
                               nativeRequest: NativeCommandTransactionRequest,
                               snapshot: NativeMotionValidationSnapshot,
                               coordinator: inout Pocket3NativeGimbalCoordinator)
        async -> NativeMotionValidationResult {
        guard request.execute else {
            return gimbalResult(request: request, coordinator: coordinator,
                                executeRequested: false)
        }
        guard let executor else {
            _ = coordinator.blockExecution(reason: "native_motion_executor_unavailable")
            return gimbalResult(request: request, coordinator: coordinator,
                                executeRequested: true)
        }
        do {
            let transaction = try await executor.execute(nativeRequest,
                readiness: snapshot.session)
            _ = coordinator.apply(transaction,
                nowUptime: transaction.finishedUptime ?? transaction.observedUptime ?? snapshot.nowUptime)
        } catch is CancellationError {
            _ = coordinator.apply(partial(nativeRequest, end: .cancelled,
                                           failureCode: "cancelled"), nowUptime: nil)
        } catch let error as NativeCommandTransactionError {
            let end: NativeCommandTransactionEnd = error == .staleGeneration
                ? .generationChanged : .failed
            _ = coordinator.apply(partial(nativeRequest, end: end,
                                           failureCode: motionFailureCode(error)), nowUptime: nil)
        } catch {
            _ = coordinator.apply(partial(nativeRequest, end: .failed,
                                           failureCode: "native_motion_executor_failed"), nowUptime: nil)
        }
        return gimbalResult(request: request, coordinator: coordinator,
                            executeRequested: true)
    }

    private func zoomResult(request: NativeMotionValidationRequest,
                            coordinator: Pocket3NativeZoomCoordinator,
                            executeRequested: Bool) -> NativeMotionValidationResult {
        let result = coordinator.result!
        return NativeMotionValidationResult(action: request.action,
            executeRequested: executeRequested,
            request: coordinator.request.map(NativeMotionValidationRequestEvidence.init),
            phase: result.phase.rawValue, zoom: result, gimbal: nil,
            requested: result.requested, submitted: result.submitted,
            acknowledged: result.acknowledged, observed: result.observed,
            completed: result.completed, noOp: result.noOp,
            failureCode: result.failureCode)
    }

    private func gimbalResult(request: NativeMotionValidationRequest,
                              coordinator: Pocket3NativeGimbalCoordinator,
                              executeRequested: Bool) -> NativeMotionValidationResult {
        let result = coordinator.result!
        return NativeMotionValidationResult(action: request.action,
            executeRequested: executeRequested,
            request: coordinator.request.map(NativeMotionValidationRequestEvidence.init),
            phase: result.phase.rawValue, zoom: nil, gimbal: result,
            requested: result.requested, submitted: result.submitted,
            acknowledged: result.acknowledged, observed: result.observed,
            completed: result.completed, noOp: result.noOp,
            failureCode: result.failureCode)
    }

    private func partial(_ request: NativeCommandTransactionRequest,
                         end: NativeCommandTransactionEnd,
                         failureCode: String) -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: request.generation,
            sessionID: request.sessionID, end: end)
        result.failureCode = failureCode
        return result
    }

    private func zoomAction(_ request: NativeMotionValidationRequest)
        throws -> Pocket3NativeZoomPayload {
        switch request.action {
        case .zoomAbsolute:
            guard let raw = request.rawValue else { throw NativeMotionValidationError.invalidAction }
            return .absoluteLens(position: raw)
        case .zoomRelative:
            guard let raw = request.rawValue else { throw NativeMotionValidationError.invalidAction }
            return .relativeSlew(value: raw)
        case .zoomStop: return .stop
        default: throw NativeMotionValidationError.invalidAction
        }
    }

    private func mapZoomInit(_ session: NativeCameraSessionStatus)
        throws -> Pocket3NativeZoomCoordinator {
        do { return try Pocket3NativeZoomCoordinator(session: session) }
        catch Pocket3NativeZoomCoordinatorError.sessionNotReady { throw NativeMotionValidationError.sessionNotReady }
        catch Pocket3NativeZoomCoordinatorError.missingSessionIdentity { throw NativeMotionValidationError.missingSessionIdentity }
    }

    private func mapGimbalInit(_ session: NativeCameraSessionStatus)
        throws -> Pocket3NativeGimbalCoordinator {
        do { return try Pocket3NativeGimbalCoordinator(session: session) }
        catch Pocket3NativeGimbalCoordinatorError.sessionNotReady { throw NativeMotionValidationError.sessionNotReady }
        catch Pocket3NativeGimbalCoordinatorError.missingSessionIdentity { throw NativeMotionValidationError.missingSessionIdentity }
    }

    private func mapZoomError(_ error: Pocket3NativeZoomCoordinatorError)
        -> NativeMotionValidationError {
        switch error {
        case .sessionNotReady: .sessionNotReady
        case .missingSessionIdentity: .missingSessionIdentity
        case .invalidBaseline: .invalidBaseline
        case .invalidFormat: .invalidFormat
        case .invalidAction: .invalidAction
        case .alreadyAtTarget: .alreadyAtTarget
        case .operationInFlight: .operationInFlight
        case .staleTransaction: .staleTransaction
        case .invalidClock: .invalidTimeout
        }
    }

    private func mapGimbalError(_ error: Pocket3NativeGimbalCoordinatorError)
        -> NativeMotionValidationError {
        switch error {
        case .sessionNotReady: .sessionNotReady
        case .missingSessionIdentity: .missingSessionIdentity
        case .invalidBaseline: .invalidBaseline
        case .alreadyAtTarget: .alreadyAtTarget
        case .operationInFlight: .operationInFlight
        case .staleTransaction: .staleTransaction
        case .invalidClock: .invalidTimeout
        }
    }
}

private func motionFailureCode(_ error: NativeCommandTransactionError) -> String {
    switch error {
    case .invalidPayload: "native_motion_invalid_payload"
    case .invalidTimeout: "native_motion_invalid_timeout"
    case .commandNotReady: "native_motion_command_not_ready"
    case .staleGeneration: "native_motion_generation_changed"
    case .datalinkUnavailable: "native_motion_datalink_unavailable"
    case .nativeBusy: "native_motion_busy"
    }
}
