import Foundation

/// Developer-only actions for the typed native setting candidates. The
/// ordinary camera settings writer remains a separate BLE validation path.
public enum NativeSettingValidationOperation: String, Codable, Sendable,
    Equatable, CaseIterable {
    case whiteBalance = "white-balance"
    case focusMode = "focus-mode"
    case colorProfile = "color-profile"
    case productShowcase = "product-showcase"

    public static let wb = Self.whiteBalance
    public static let focus = Self.focusMode
    public static let color = Self.colorProfile
    public static let showcase = Self.productShowcase
}

public enum NativeSettingValidationError: Error, Equatable, Sendable {
    case invalidArguments
    case invalidAction
    case invalidValue
    case invalidRequestIdentity
    case invalidTimeout
    case sessionNotReady
    case missingSessionIdentity
    case baselineRequired
    case invalidBaseline
    case alreadyAtTarget
    case operationInFlight
    case staleTransaction
}

/// Strict JSON/CLI contract for one native setting validation attempt. The
/// request contains one typed target and exact native session identity; value
/// encoding is kept compact at the IPC boundary and is expanded into the
/// existing `Pocket3NativeSettingTarget` before any command is prepared.
public struct NativeSettingValidationRequest: Codable, Sendable, Equatable {
    public static let operation = "validation-wireless-native-setting"

    public let action: NativeSettingValidationOperation
    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let target: Pocket3NativeSettingTarget
    public let execute: Bool
    public let timeout: TimeInterval

    public init(action: NativeSettingValidationOperation,
                expectedSessionID: UUID, peripheralID: UUID,
                generation: UInt64, target: Pocket3NativeSettingTarget,
                execute: Bool = false, timeout: TimeInterval = 3) throws {
        guard generation > 0, timeout.isFinite, timeout > 0,
              timeout <= NativeCommandTransactionRequest.maximumTimeout else {
            throw NativeSettingValidationError.invalidTimeout
        }
        guard Self.action(for: target) == action else {
            throw NativeSettingValidationError.invalidArguments
        }
        self.action = action
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.target = target
        self.execute = execute
        self.timeout = timeout
    }

    public init(action: NativeSettingValidationOperation,
                expectedSessionID: UUID, peripheralID: UUID,
                generation: UInt64, whiteBalance: CameraWhiteBalance? = nil,
                focusMode: CameraFocusMode? = nil,
                colorProfile: CameraColorProfile? = nil,
                productShowcase: Pocket3ProductShowcaseMode? = nil,
                execute: Bool = false, timeout: TimeInterval = 3) throws {
        let values = [
            whiteBalance.map { Pocket3NativeSettingTarget.whiteBalance($0) },
            focusMode.map { Pocket3NativeSettingTarget.focusMode($0) },
            colorProfile.map { Pocket3NativeSettingTarget.colorProfile($0) },
            productShowcase.map { Pocket3NativeSettingTarget.productShowcase($0) }
        ].compactMap { $0 }
        guard values.count == 1, let target = values.first else {
            throw NativeSettingValidationError.invalidArguments
        }
        try self.init(action: action, expectedSessionID: expectedSessionID,
                      peripheralID: peripheralID, generation: generation,
                      target: target, execute: execute, timeout: timeout)
    }

    /// Convenience initializer for callers that already own the typed target.
    public init(target: Pocket3NativeSettingTarget,
                expectedSessionID: UUID, peripheralID: UUID,
                generation: UInt64, execute: Bool = false,
                timeout: TimeInterval = 3) throws {
        try self.init(action: Self.action(for: target),
                      expectedSessionID: expectedSessionID,
                      peripheralID: peripheralID, generation: generation,
                      target: target, execute: execute, timeout: timeout)
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments else {
            throw NativeSettingValidationError.invalidArguments
        }
        let allowed = Set(["action", "expectedSessionID", "peripheralID",
                           "generation", "value", "execute", "timeout"])
        guard Set(fields.keys).isSubset(of: allowed),
              let actionRaw = fields["action"]?.string,
              let action = Self.parseAction(actionRaw),
              let sessionText = fields["expectedSessionID"]?.string,
              let expectedSessionID = UUID(uuidString: sessionText),
              let peripheralText = fields["peripheralID"]?.string,
              let peripheralID = UUID(uuidString: peripheralText),
              let generationNumber = fields["generation"]?.number,
              generationNumber.isFinite,
              generationNumber.rounded() == generationNumber,
              generationNumber >= 1,
              generationNumber < 18_446_744_073_709_551_616,
              let generation = UInt64(exactly: generationNumber) else {
            throw NativeSettingValidationError.invalidArguments
        }

        let execute: Bool
        if let value = fields["execute"] {
            guard let parsed = value.bool else {
                throw NativeSettingValidationError.invalidArguments
            }
            execute = parsed
        } else {
            execute = false
        }

        let timeout: TimeInterval
        if let value = fields["timeout"] {
            guard let parsed = value.number else {
                throw NativeSettingValidationError.invalidTimeout
            }
            timeout = parsed
        } else {
            timeout = 3
        }

        guard let value = fields["value"] else {
            throw NativeSettingValidationError.invalidValue
        }
        let target = try Self.parseTarget(action: action, value: value)
        try self.init(action: action, expectedSessionID: expectedSessionID,
                      peripheralID: peripheralID, generation: generation,
                      target: target, execute: execute, timeout: timeout)
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        let names = ["--action": "action", "--session": "expectedSessionID",
                     "--peripheral": "peripheralID", "--generation": "generation",
                     "--value": "value", "--timeout": "timeout"]
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
                throw BridgeFailure("usage", "Unknown, duplicate or incomplete native setting option")
            }
            let value = cliArguments[index + 1]
            switch key {
            case "action", "expectedSessionID", "peripheralID", "value":
                fields[key] = .string(value)
            case "generation", "timeout":
                guard let number = Double(value), number.isFinite else {
                    throw BridgeFailure("usage", "Native setting numeric options must be finite")
                }
                fields[key] = .number(number)
            default:
                throw BridgeFailure("usage", "Unknown native setting option")
            }
            index += 2
        }
        do {
            try self.init(arguments: .object(fields))
        } catch let error as NativeSettingValidationError {
            throw BridgeFailure("invalid_native_setting_request", String(describing: error))
        }
    }

    public var value: JSONValue {
        switch target {
        case .whiteBalance(.automatic): .string("automatic")
        case .whiteBalance(.customKelvin(let kelvin)): .number(Double(kelvin))
        case .focusMode(.single): .string("single")
        case .focusMode(.continuous): .string("continuous")
        case .colorProfile(.normal): .string("normal")
        case .colorProfile(.hlg): .string("hlg")
        case .colorProfile(.dLogM): .string("dLogM")
        case .productShowcase(.off): .string("off")
        case .productShowcase(.on): .string("on")
        }
    }

    public var whiteBalance: CameraWhiteBalance? {
        if case .whiteBalance(let value) = target { return value }
        return nil
    }

    public var focusMode: CameraFocusMode? {
        if case .focusMode(let value) = target { return value }
        return nil
    }

    public var colorProfile: CameraColorProfile? {
        if case .colorProfile(let value) = target { return value }
        return nil
    }

    public var productShowcase: Pocket3ProductShowcaseMode? {
        if case .productShowcase(let value) = target { return value }
        return nil
    }

    public var arguments: JSONValue {
        .object([
            "action": .string(action.rawValue),
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString),
            "generation": .number(Double(generation)),
            "value": value,
            "execute": .bool(execute),
            "timeout": .number(timeout)
        ])
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "action": .object(["type": .string("string"),
                "enum": .array(Self.allActions.map { .string($0.rawValue) })]),
            "expectedSessionID": .object(["type": .string("string"), "minLength": .number(1)]),
            "peripheralID": .object(["type": .string("string"), "minLength": .number(1)]),
            "generation": .object(["type": .string("integer"), "minimum": .number(1)]),
            "value": .object(["oneOf": .array([
                .object(["type": .string("string")]),
                .object(["type": .string("integer")])
            ])]),
            "execute": .object(["type": .string("boolean")]),
            "timeout": .object(["type": .string("number"),
                                 "exclusiveMinimum": .number(0),
                                 "maximum": .number(5)])
        ]),
        "required": .array([.string("action"), .string("expectedSessionID"),
                             .string("peripheralID"), .string("generation"),
                             .string("value")]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }

    private static let allActions = NativeSettingValidationOperation.allCases

    private static func action(for target: Pocket3NativeSettingTarget)
        -> NativeSettingValidationOperation {
        switch target {
        case .whiteBalance: .whiteBalance
        case .focusMode: .focusMode
        case .colorProfile: .colorProfile
        case .productShowcase: .productShowcase
        }
    }

    private static func parseAction(_ raw: String)
        -> NativeSettingValidationOperation? {
        if let action = NativeSettingValidationOperation(rawValue: raw) {
            return action
        }
        switch raw.lowercased() {
        case "whitebalance", "wb": return .whiteBalance
        case "focusmode", "focus", "af": return .focusMode
        case "colorprofile", "color": return .colorProfile
        case "productshowcase", "showcase": return .productShowcase
        default: return nil
        }
    }

    private static func parseTarget(action: NativeSettingValidationOperation,
                                    value: JSONValue)
        throws -> Pocket3NativeSettingTarget {
        switch action {
        case .whiteBalance:
            return .whiteBalance(try parseWhiteBalance(value))
        case .focusMode:
            return .focusMode(try parseFocusMode(value))
        case .colorProfile:
            return .colorProfile(try parseColorProfile(value))
        case .productShowcase:
            return .productShowcase(try parseShowcase(value))
        }
    }

    private static func parseWhiteBalance(_ value: JSONValue)
        throws -> CameraWhiteBalance {
        if let raw = value.string {
            switch raw.lowercased() {
            case "auto", "automatic": return .automatic
            default:
                guard let kelvin = Int(raw), (2_000...10_000).contains(kelvin),
                      kelvin.isMultiple(of: 100) else {
                    throw NativeSettingValidationError.invalidValue
                }
                return .customKelvin(kelvin)
            }
        }
        guard let number = value.number, number.isFinite,
              number.rounded() == number, number >= 2_000,
              number <= 10_000, number.truncatingRemainder(dividingBy: 100) == 0,
              let kelvin = Int(exactly: number) else {
            throw NativeSettingValidationError.invalidValue
        }
        return .customKelvin(kelvin)
    }

    private static func parseFocusMode(_ value: JSONValue)
        throws -> CameraFocusMode {
        if let raw = value.string {
            switch raw.lowercased() {
            case "single", "single-shot", "1", "0x01": return .single
            case "continuous", "2", "0x02": return .continuous
            default: throw NativeSettingValidationError.invalidValue
            }
        }
        guard let number = value.number, number.isFinite,
              number.rounded() == number, let raw = UInt8(exactly: number),
              let mode = CameraFocusMode(rawValue: raw) else {
            throw NativeSettingValidationError.invalidValue
        }
        return mode
    }

    private static func parseColorProfile(_ value: JSONValue)
        throws -> CameraColorProfile {
        if let raw = value.string {
            switch raw.lowercased() {
            case "normal", "standard", "0", "0x00": return .normal
            case "hlg", "60", "0x3c": return .hlg
            case "dlogm", "d-log-m", "d_log_m", "61", "0x3d": return .dLogM
            default: throw NativeSettingValidationError.invalidValue
            }
        }
        guard let number = value.number, number.isFinite,
              number.rounded() == number, let raw = UInt8(exactly: number),
              let profile = CameraColorProfile(rawValue: raw) else {
            throw NativeSettingValidationError.invalidValue
        }
        return profile
    }

    private static func parseShowcase(_ value: JSONValue)
        throws -> Pocket3ProductShowcaseMode {
        if let raw = value.string {
            switch raw.lowercased() {
            case "off", "disabled", "0", "0x00": return .off
            case "on", "enabled", "1", "0x01": return .on
            default: throw NativeSettingValidationError.invalidValue
            }
        }
        guard let number = value.number, number.isFinite,
              number.rounded() == number, let raw = UInt8(exactly: number),
              let mode = Pocket3ProductShowcaseMode(rawValue: raw) else {
            throw NativeSettingValidationError.invalidValue
        }
        return mode
    }
}

public struct NativeSettingValidationSnapshot: Codable, Sendable, Equatable {
    public let session: NativeCameraSessionStatus
    public let baseline: Pocket3NativeSettingObservation?
    public let nowUptime: TimeInterval

    public init(session: NativeCameraSessionStatus,
                baseline: Pocket3NativeSettingObservation? = nil,
                nowUptime: TimeInterval) {
        self.session = session
        self.baseline = baseline
        self.nowUptime = nowUptime
    }
}

public struct NativeSettingValidationRequestEvidence: Codable, Sendable,
    Equatable {
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

public struct NativeSettingValidationResult: Codable, Sendable, Equatable {
    public let action: NativeSettingValidationOperation
    public let executeRequested: Bool
    public let request: NativeSettingValidationRequestEvidence?
    public let setting: Pocket3NativeSettingResult?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let noOp: Bool
    public let phase: Pocket3NativeSettingCoordinatorPhase
    public let failureCode: String?

    public var dryRun: Bool { !executeRequested }
}

public struct NativeSettingValidationExecutorAdapter: Sendable {
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

/// Developer-only service for the four typed native setting candidates. It
/// owns no BLE or socket object. An injected adapter is the current single
/// datalink owner and is called at most once for one prepared request.
public struct NativeSettingValidationService: Sendable {
    public static let defaultTimeout: TimeInterval = 3

    private let executor: NativeSettingValidationExecutorAdapter?

    public init(adapter: NativeSettingValidationExecutorAdapter? = nil) {
        executor = adapter
    }

    public func run(_ request: NativeSettingValidationRequest,
                    snapshot: NativeSettingValidationSnapshot) async throws
        -> NativeSettingValidationResult {
        guard request.expectedSessionID == snapshot.session.sessionID,
              request.peripheralID == snapshot.session.peerID,
              request.generation == snapshot.session.generation else {
            throw NativeSettingValidationError.invalidRequestIdentity
        }
        guard snapshot.nowUptime.isFinite else {
            throw NativeSettingValidationError.invalidTimeout
        }
        guard let baseline = snapshot.baseline else {
            throw NativeSettingValidationError.baselineRequired
        }

        var coordinator: Pocket3NativeSettingCoordinator
        do {
            coordinator = try Pocket3NativeSettingCoordinator(session: snapshot.session)
        } catch let error as Pocket3NativeSettingCoordinatorError {
            throw map(error)
        }

        let nativeRequest: NativeCommandTransactionRequest
        do {
            nativeRequest = try coordinator.prepare(request.target,
                baseline: baseline, nowUptime: snapshot.nowUptime,
                timeout: request.timeout)
        } catch Pocket3NativeSettingCoordinatorError.alreadyAtTarget {
            return result(request: request, coordinator: coordinator)
        } catch let error as Pocket3NativeSettingCoordinatorError {
            throw map(error)
        } catch NativeCommandTransactionError.invalidTimeout {
            throw NativeSettingValidationError.invalidTimeout
        } catch {
            throw NativeSettingValidationError.invalidArguments
        }

        guard request.execute else {
            return result(request: request, coordinator: coordinator)
        }
        guard let executor else {
            _ = coordinator.blockExecution(reason: "native_setting_executor_unavailable")
            return result(request: request, coordinator: coordinator)
        }

        do {
            // This is the sole executor invocation. There is deliberately no
            // retry or fallback transport branch after a partial result.
            let transaction = try await executor.execute(nativeRequest,
                readiness: snapshot.session)
            let now = transaction.finishedUptime
                ?? transaction.observedUptime ?? snapshot.nowUptime
            _ = coordinator.apply(transaction, nowUptime: now)
        } catch is CancellationError {
            _ = coordinator.apply(partial(nativeRequest, end: .cancelled,
                                           failureCode: "cancelled"), nowUptime: nil)
        } catch let error as NativeCommandTransactionError {
            let end: NativeCommandTransactionEnd = error == .staleGeneration
                ? .generationChanged : .failed
            _ = coordinator.apply(partial(nativeRequest, end: end,
                                           failureCode: settingFailureCode(error)),
                                  nowUptime: nil)
        } catch {
            _ = coordinator.apply(partial(nativeRequest, end: .failed,
                                           failureCode: "native_setting_executor_failed"),
                                  nowUptime: nil)
        }
        return result(request: request, coordinator: coordinator)
    }

    private func result(request: NativeSettingValidationRequest,
                        coordinator: Pocket3NativeSettingCoordinator)
        -> NativeSettingValidationResult {
        let setting = coordinator.result!
        return NativeSettingValidationResult(action: request.action,
            executeRequested: request.execute,
            request: coordinator.request.map(NativeSettingValidationRequestEvidence.init),
            setting: setting, requested: setting.requested,
            submitted: setting.submitted, acknowledged: setting.acknowledged,
            observed: setting.observed, completed: setting.completed,
            noOp: setting.noOp, phase: setting.phase,
            failureCode: setting.failureCode)
    }

    private func partial(_ request: NativeCommandTransactionRequest,
                         end: NativeCommandTransactionEnd,
                         failureCode: String)
        -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: request.generation,
            sessionID: request.sessionID, end: end)
        result.failureCode = failureCode
        return result
    }

    private func map(_ error: Pocket3NativeSettingCoordinatorError)
        -> NativeSettingValidationError {
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

private func settingFailureCode(_ error: NativeCommandTransactionError) -> String {
    switch error {
    case .invalidPayload: "native_setting_invalid_payload"
    case .invalidTimeout: "native_setting_invalid_timeout"
    case .commandNotReady: "native_setting_command_not_ready"
    case .staleGeneration: "native_setting_generation_changed"
    case .datalinkUnavailable: "native_setting_datalink_unavailable"
    case .nativeBusy: "native_setting_busy"
    }
}

public typealias Pocket3NativeSettingValidationRequest = NativeSettingValidationRequest
public typealias Pocket3NativeSettingValidationResult = NativeSettingValidationResult
public typealias Pocket3NativeSettingValidationService = NativeSettingValidationService
