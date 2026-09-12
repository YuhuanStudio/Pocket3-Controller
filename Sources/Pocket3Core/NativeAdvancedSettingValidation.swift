import Foundation

/// Developer-only actions over the evidence-led advanced-setting candidates.
/// `selfie-flip-get` is read-only; `selfie-flip-set` is represented so the
/// safety gate can report an explicit unsupported result instead of silently
/// treating the FE09 toggle as a setting write.
public enum NativeAdvancedSettingValidationOperation: String, Codable,
    Sendable, Equatable, CaseIterable {
    case medTele = "med-tele"
    case isoLimit = "iso-limit"
    case audioChannel = "audio-channel"
    case vocalBoost = "vocal-boost"
    case selfieFlipGet = "selfie-flip-get"
    case selfieFlipSet = "selfie-flip-set"
    case breathingCompensation = "breathing-compensation"
    case sharpness
    case noiseReduction = "noise-reduction"
}

public enum NativeAdvancedSettingValidationError: Error, Codable,
    Sendable, Equatable {
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
    case unsupportedNoProtocol
}

/// Strict JSON/CLI contract for one advanced-setting validation attempt.
/// Values are parsed into the existing typed candidates before a command is
/// prepared; omission of `execute` keeps the operation dry-run.
public struct NativeAdvancedSettingValidationRequest: Codable, Sendable,
    Equatable {
    public static let operation = "validation-wireless-native-advanced-setting"

    public let action: NativeAdvancedSettingValidationOperation
    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let value: String?
    public let execute: Bool
    public let timeout: TimeInterval

    public init(action: NativeAdvancedSettingValidationOperation,
                expectedSessionID: UUID, peripheralID: UUID,
                generation: UInt64, value: String? = nil,
                execute: Bool = false, timeout: TimeInterval = 3) throws {
        guard generation > 0, timeout.isFinite, timeout > 0,
              timeout <= NativeCommandTransactionRequest.maximumTimeout else {
            throw NativeAdvancedSettingValidationError.invalidTimeout
        }
        switch action {
        case .medTele:
            guard let value, Self.parseMedTele(value) != nil else {
                throw NativeAdvancedSettingValidationError.invalidValue
            }
        case .isoLimit, .audioChannel, .vocalBoost:
            guard let value, Self.parseTarget(action: action, value: value) != nil else {
                throw NativeAdvancedSettingValidationError.invalidValue
            }
        case .selfieFlipGet, .selfieFlipSet, .breathingCompensation,
             .sharpness, .noiseReduction:
            guard value == nil else {
                throw NativeAdvancedSettingValidationError.invalidArguments
            }
        }
        self.action = action
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.value = value
        self.execute = execute
        self.timeout = timeout
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: ["action", "expectedSessionID",
                                              "peripheralID", "generation",
                                              "value", "execute", "timeout"]),
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
            throw NativeAdvancedSettingValidationError.invalidArguments
        }
        let value: String?
        if let encoded = fields["value"] {
            guard let parsed = encoded.string else {
                throw NativeAdvancedSettingValidationError.invalidValue
            }
            value = parsed
        } else {
            value = nil
        }
        let execute: Bool
        if let encoded = fields["execute"] {
            guard let parsed = encoded.bool else {
                throw NativeAdvancedSettingValidationError.invalidArguments
            }
            execute = parsed
        } else {
            execute = false
        }
        let timeout: TimeInterval
        if let encoded = fields["timeout"] {
            guard let parsed = encoded.number else {
                throw NativeAdvancedSettingValidationError.invalidTimeout
            }
            timeout = parsed
        } else {
            timeout = 3
        }
        try self.init(action: action, expectedSessionID: expectedSessionID,
                      peripheralID: peripheralID, generation: generation,
                      value: value, execute: execute, timeout: timeout)
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
                throw BridgeFailure("usage", "Unknown, duplicate or incomplete advanced-setting option")
            }
            let argumentValue = cliArguments[index + 1]
            switch key {
            case "action", "expectedSessionID", "peripheralID", "value":
                fields[key] = .string(argumentValue)
            case "generation", "timeout":
                guard let number = Double(argumentValue), number.isFinite else {
                    throw BridgeFailure("usage", "Advanced-setting numeric options must be finite")
                }
                fields[key] = .number(number)
            default:
                throw BridgeFailure("usage", "Unknown advanced-setting option")
            }
            index += 2
        }
        do {
            try self.init(arguments: .object(fields))
        } catch let error as NativeAdvancedSettingValidationError {
            throw BridgeFailure("invalid_native_advanced_setting_request",
                String(describing: error))
        }
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
        if let value { fields["value"] = .string(Self.canonicalValue(action: action, value: value)) }
        return .object(fields)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "action": .object(["type": .string("string"),
                "enum": .array(NativeAdvancedSettingValidationOperation.allCases.map { .string($0.rawValue) })]),
            "expectedSessionID": .object(["type": .string("string"), "minLength": .number(1)]),
            "peripheralID": .object(["type": .string("string"), "minLength": .number(1)]),
            "generation": .object(["type": .string("integer"), "minimum": .number(1)]),
            "value": .object(["type": .string("string"), "minLength": .number(1)]),
            "execute": .object(["type": .string("boolean")]),
            "timeout": .object(["type": .string("number"),
                                 "exclusiveMinimum": .number(0),
                                 "maximum": .number(5)])
        ]),
        "required": .array([.string("action"), .string("expectedSessionID"),
                             .string("peripheralID"), .string("generation")]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public var typedTarget: Pocket3AdvancedSettingTarget? {
        guard let value else { return nil }
        return Self.parseTarget(action: action, value: value)
    }

    public var medTeleState: Pocket3MedTeleState? {
        guard action == .medTele, let value else { return nil }
        return Self.parseMedTele(value)
    }

    private static func parseAction(_ raw: String)
        -> NativeAdvancedSettingValidationOperation? {
        if let action = NativeAdvancedSettingValidationOperation(rawValue: raw) {
            return action
        }
        switch raw.lowercased() {
        case "medtele", "med-telephoto": return .medTele
        case "isolimit", "iso-max", "isomax": return .isoLimit
        case "audiochannel", "audio": return .audioChannel
        case "vocalboost", "vocal": return .vocalBoost
        case "selfie-flip", "selfieflip", "selfieflipget": return .selfieFlipGet
        case "selfieflipset": return .selfieFlipSet
        case "breathing", "lens-breathing": return .breathingCompensation
        case "noise", "noise-reduction": return .noiseReduction
        default: return nil
        }
    }

    private static func parseTarget(action: NativeAdvancedSettingValidationOperation,
                                    value: String)
        -> Pocket3AdvancedSettingTarget? {
        switch action {
        case .isoLimit:
            guard let iso = parseISOLimit(value) else { return nil }
            return .isoLimit(iso)
        case .audioChannel:
            guard let channel = parseAudioChannel(value) else { return nil }
            return .audioChannel(channel)
        case .vocalBoost:
            guard let boost = parseVocalBoost(value) else { return nil }
            return .vocalBoost(boost)
        default:
            return nil
        }
    }

    private static func parseMedTele(_ value: String) -> Pocket3MedTeleState? {
        switch value.lowercased() {
        case "enabled", "enable", "on", "1": return .enabled
        case "disabled", "disable", "off", "0": return .disabled
        default: return nil
        }
    }

    private static func parseISOLimit(_ value: String) -> Pocket3ISOLimit? {
        let normalized = value.lowercased().replacingOccurrences(of: "iso", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "100", "1": return .iso100
        case "200", "2": return .iso200
        case "400", "3": return .iso400
        case "800", "4": return .iso800
        case "1600", "5": return .iso1600
        case "3200", "6": return .iso3200
        case "6400", "7": return .iso6400
        default: return nil
        }
    }

    private static func parseAudioChannel(_ value: String) -> Pocket3AudioChannel? {
        switch value.lowercased() {
        case "mono", "1": return .mono
        case "stereo", "2": return .stereo
        default: return nil
        }
    }

    private static func parseVocalBoost(_ value: String) -> Pocket3VocalBoost? {
        switch value.lowercased() {
        case "off", "disabled", "0": return .off
        case "on", "enabled", "1": return .on
        default: return nil
        }
    }

    private static func canonicalValue(
        action: NativeAdvancedSettingValidationOperation, value: String
    ) -> String {
        switch action {
        case .isoLimit: return parseISOLimit(value).map { String($0.iso) } ?? value
        case .audioChannel:
            if let channel = parseAudioChannel(value) {
                return channel == .mono ? "mono" : "stereo"
            }
        case .vocalBoost:
            if let boost = parseVocalBoost(value) {
                return boost == .on ? "on" : "off"
            }
        case .medTele:
            if let state = medTeleCanonical(value) { return state }
        default: break
        }
        return value
    }

    private static func medTeleCanonical(_ value: String) -> String? {
        switch value.lowercased() {
        case "enabled", "enable", "on", "1": return "enabled"
        case "disabled", "disable", "off", "0": return "disabled"
        default: return nil
        }
    }
}

public struct NativeAdvancedSettingValidationSnapshot: Codable, Sendable,
    Equatable {
    public let session: NativeCameraSessionStatus
    public let baseline: Pocket3AdvancedSettingObservation?
    public let nowUptime: TimeInterval

    public init(session: NativeCameraSessionStatus,
                baseline: Pocket3AdvancedSettingObservation? = nil,
                nowUptime: TimeInterval) {
        self.session = session
        self.baseline = baseline
        self.nowUptime = nowUptime
    }
}

public enum NativeAdvancedSettingValidationPhase: String, Codable, Sendable,
    Equatable, CaseIterable {
    case dryRun
    case candidateOnly
    case noOp
    case awaitingAcknowledgment
    case awaitingReadback
    case completed
    case timedOut
    case cancelled
    case generationChanged
    case failed
    case unsupported
}

public struct NativeAdvancedSettingRequestEvidence: Codable, Sendable,
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

public struct NativeAdvancedSettingValidationResult: Codable, Sendable,
    Equatable {
    public let action: NativeAdvancedSettingValidationOperation
    public let executeRequested: Bool
    public let request: NativeAdvancedSettingRequestEvidence?
    public let transaction: NativeCommandTransactionResult?
    public let setting: Pocket3AdvancedSettingResult?
    public let readback: Pocket3AdvancedSettingObservation?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let noOp: Bool
    public let phase: NativeAdvancedSettingValidationPhase
    public let failureCode: String?

    public var dryRun: Bool { !executeRequested }
    public var partial: Bool { submitted && !completed }
}

public struct NativeAdvancedSettingValidationExecutorAdapter: Sendable {
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

/// Developer-only coordinator service. It calls one injected datalink owner
/// at most once for a supported operation. It never performs a GET to invent a
/// baseline, retries a failed request, or treats an ACK as setting completion.
public struct NativeAdvancedSettingValidationService: Sendable {
    public static let defaultTimeout: TimeInterval = 3
    private let executor: NativeAdvancedSettingValidationExecutorAdapter?

    public init(adapter: NativeAdvancedSettingValidationExecutorAdapter? = nil) {
        executor = adapter
    }

    public func run(_ request: NativeAdvancedSettingValidationRequest,
                    snapshot: NativeAdvancedSettingValidationSnapshot) async throws
        -> NativeAdvancedSettingValidationResult {
        guard request.expectedSessionID == snapshot.session.sessionID,
              request.peripheralID == snapshot.session.peerID,
              request.generation == snapshot.session.generation else {
            throw NativeAdvancedSettingValidationError.invalidRequestIdentity
        }
        guard snapshot.nowUptime.isFinite else {
            throw NativeAdvancedSettingValidationError.invalidTimeout
        }
        switch request.action {
        case .breathingCompensation, .sharpness, .noiseReduction, .selfieFlipSet:
            throw NativeAdvancedSettingValidationError.unsupportedNoProtocol
        case .medTele:
            return try medTeleResult(request, snapshot: snapshot)
        case .selfieFlipGet:
            return try await runSelfieFlipGet(request, snapshot: snapshot)
        case .isoLimit, .audioChannel, .vocalBoost:
            guard let target = request.typedTarget,
                  let baseline = snapshot.baseline else {
                throw snapshot.baseline == nil
                    ? NativeAdvancedSettingValidationError.baselineRequired
                    : NativeAdvancedSettingValidationError.invalidValue
            }
            return try await runTypedSetting(request, target: target,
                                             baseline: baseline, snapshot: snapshot)
        }
    }

    private func medTeleResult(
        _ request: NativeAdvancedSettingValidationRequest,
        snapshot: NativeAdvancedSettingValidationSnapshot
    ) throws -> NativeAdvancedSettingValidationResult {
        guard snapshot.session.generation > 0,
              snapshot.session.state.satisfies(.commandReady),
              let sessionID = snapshot.session.sessionID else {
            throw NativeAdvancedSettingValidationError.sessionNotReady
        }
        guard let state = request.medTeleState else {
            throw NativeAdvancedSettingValidationError.invalidValue
        }
        let candidate = Pocket3MedTeleCommand(state)
        let nativeRequest = try NativeCommandTransactionRequest(
            command: .advancedSetting, generation: snapshot.session.generation,
            sessionID: sessionID,
            frame: NativeCommandFrame(frame: candidate.frame(sequence: 0)),
            timeout: request.timeout)
        let evidence = NativeAdvancedSettingRequestEvidence(nativeRequest)
        let phase: NativeAdvancedSettingValidationPhase = request.execute
            ? .unsupported : .candidateOnly
        return NativeAdvancedSettingValidationResult(
            action: request.action, executeRequested: request.execute,
            request: evidence, transaction: nil, setting: nil, readback: nil,
            requested: true, submitted: false, acknowledged: false,
            observed: false, completed: false, noOp: false, phase: phase,
            failureCode: request.execute ? "unsupported_no_protocol" : nil)
    }

    private func runTypedSetting(
        _ request: NativeAdvancedSettingValidationRequest,
        target: Pocket3AdvancedSettingTarget,
        baseline: Pocket3AdvancedSettingObservation,
        snapshot: NativeAdvancedSettingValidationSnapshot
    ) async throws -> NativeAdvancedSettingValidationResult {
        var coordinator: Pocket3AdvancedSettingCoordinator
        do {
            coordinator = try Pocket3AdvancedSettingCoordinator(session: snapshot.session)
        } catch let error as Pocket3AdvancedSettingCoordinatorError {
            throw validationError(error)
        } catch {
            throw NativeAdvancedSettingValidationError.sessionNotReady
        }

        let nativeRequest: NativeCommandTransactionRequest
        do {
            nativeRequest = try coordinator.prepare(target, baseline: baseline,
                nowUptime: snapshot.nowUptime, timeout: request.timeout)
        } catch Pocket3AdvancedSettingCoordinatorError.alreadyAtTarget {
            return result(request: request, coordinator: coordinator,
                          phase: .noOp, transaction: nil, readback: nil,
                          failureCode: nil)
        } catch let error as Pocket3AdvancedSettingCoordinatorError {
            throw validationError(error)
        } catch NativeCommandTransactionError.invalidTimeout {
            throw NativeAdvancedSettingValidationError.invalidTimeout
        } catch {
            throw NativeAdvancedSettingValidationError.invalidArguments
        }

        guard request.execute else {
            return result(request: request, coordinator: coordinator,
                          phase: .dryRun, transaction: nil, readback: nil,
                          failureCode: nil)
        }
        guard let executor else {
            _ = coordinator.blockExecution(
                reason: "native_advanced_setting_executor_unavailable")
            return result(request: request, coordinator: coordinator,
                          phase: .failed, transaction: coordinator.transaction,
                          readback: coordinator.readback,
                          failureCode: coordinator.failureCode)
        }

        do {
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
                                           failureCode: failureCode(error)),
                                  nowUptime: nil)
        } catch {
            _ = coordinator.apply(partial(nativeRequest, end: .failed,
                                           failureCode: "native_advanced_setting_executor_failed"),
                                  nowUptime: nil)
        }
        return result(request: request, coordinator: coordinator,
                      phase: map(coordinator.phase),
                      transaction: coordinator.transaction,
                      readback: coordinator.readback,
                      failureCode: coordinator.failureCode)
    }

    private func runSelfieFlipGet(
        _ request: NativeAdvancedSettingValidationRequest,
        snapshot: NativeAdvancedSettingValidationSnapshot
    ) async throws -> NativeAdvancedSettingValidationResult {
        guard snapshot.session.generation > 0,
              snapshot.session.state.satisfies(.commandReady),
              let sessionID = snapshot.session.sessionID else {
            throw snapshot.session.generation == 0 ||
                !snapshot.session.state.satisfies(.commandReady)
                ? NativeAdvancedSettingValidationError.sessionNotReady
                : NativeAdvancedSettingValidationError.missingSessionIdentity
        }
        let command: Pocket3KeyedParameterCommand
        do {
            command = try .selfieFlipGet()
        } catch {
            throw NativeAdvancedSettingValidationError.invalidArguments
        }
        let nativeRequest: NativeCommandTransactionRequest
        do {
            nativeRequest = try NativeCommandTransactionRequest(
                command: .advancedSetting, generation: snapshot.session.generation,
                sessionID: sessionID,
                frame: NativeCommandFrame(frame: command.frame(sequence: 0)),
                timeout: request.timeout) { response in
                    guard response.source == Pocket3KeyedParameterCommand.destination,
                          response.destination == Pocket3KeyedParameterCommand.source,
                          response.flags == 0x80 || response.flags == 0xC0,
                          response.commandSet == Pocket3KeyedParameterCommand.commandSet,
                          response.commandID == Pocket3KeyedParameterCommand.commandID,
                          Pocket3KeyedParameterReadback.decode(response.payload,
                              parameterID: command.parameterID) != nil else {
                        return nil
                    }
                    return response.payload
                }
        } catch {
            throw NativeAdvancedSettingValidationError.invalidTimeout
        }
        guard request.execute else {
            return NativeAdvancedSettingValidationResult(
                action: request.action, executeRequested: false,
                request: .init(nativeRequest), transaction: nil, setting: nil,
                readback: nil, requested: true, submitted: false,
                acknowledged: false, observed: false, completed: false,
                noOp: false, phase: .dryRun, failureCode: nil)
        }
        guard let executor else {
            return NativeAdvancedSettingValidationResult(
                action: request.action, executeRequested: true,
                request: .init(nativeRequest), transaction: nil, setting: nil,
                readback: nil, requested: true, submitted: false,
                acknowledged: false, observed: false, completed: false,
                noOp: false, phase: .failed,
                failureCode: "native_advanced_setting_executor_unavailable")
        }

        var transaction: NativeCommandTransactionResult?
        var readback: Pocket3AdvancedSettingObservation?
        var phase: NativeAdvancedSettingValidationPhase = .awaitingAcknowledgment
        var failure: String?
        do {
            let received = try await executor.execute(nativeRequest,
                readiness: snapshot.session)
            transaction = received
            let now = received.finishedUptime
                ?? received.observedUptime ?? snapshot.nowUptime
            guard received.id == nativeRequest.id,
                  received.command == .advancedSetting,
                  received.generation == snapshot.session.generation,
                  received.sessionID == snapshot.session.sessionID else {
                phase = .generationChanged
                failure = "native_advanced_setting_stale_transaction"
                return readOnlyResult(request, nativeRequest: nativeRequest,
                    transaction: transaction, readback: nil, phase: phase,
                    failureCode: failure)
            }
            guard received.submitted else {
                phase = .failed
                failure = received.failureCode ?? "native_advanced_setting_not_submitted"
                return readOnlyResult(request, nativeRequest: nativeRequest,
                    transaction: transaction, readback: nil, phase: phase,
                    failureCode: failure)
            }
            switch received.end {
            case .cancelled:
                phase = .cancelled; failure = received.failureCode ?? "cancelled"
            case .generationChanged:
                phase = .generationChanged
                failure = received.failureCode ?? "native_advanced_setting_generation_changed"
            case .timedOut:
                phase = .timedOut
                failure = received.failureCode ?? "native_advanced_setting_timeout"
            case .rejected, .failed:
                phase = .failed
                failure = received.failureCode ?? "native_advanced_setting_failed"
            case .acknowledged, .observed:
                guard received.acknowledged else {
                    phase = .failed
                    failure = received.failureCode ?? "native_advanced_setting_ack_invalid"
                    return readOnlyResult(request, nativeRequest: nativeRequest,
                        transaction: transaction, readback: nil, phase: phase,
                        failureCode: failure)
                }
                if let payload = received.observedPayload,
                   payload.count <= DUMLCodec.maximumPayloadLength,
                   let observedUptime = received.observedUptime ?? received.finishedUptime,
                   let observed = Pocket3AdvancedSettingObservation(
                       sessionID: sessionID,
                       generation: snapshot.session.generation,
                       receivedUptime: observedUptime,
                       setting: .selfieFlip, payload: payload),
                   observed.isFresh(nowUptime: now,
                                   maximumAge: Pocket3AdvancedSettingObservation.maximumAge) {
                    readback = observed
                    phase = .completed
                } else {
                    phase = .awaitingReadback
                }
            }
        } catch is CancellationError {
            phase = .cancelled; failure = "cancelled"
            transaction = partial(nativeRequest, end: .cancelled,
                                  failureCode: "cancelled")
        } catch let error as NativeCommandTransactionError {
            phase = error == .staleGeneration ? .generationChanged : .failed
            failure = failureCode(error)
            transaction = partial(nativeRequest,
                end: error == .staleGeneration ? .generationChanged : .failed,
                failureCode: failure!)
        } catch {
            phase = .failed
            failure = "native_advanced_setting_executor_failed"
            transaction = partial(nativeRequest, end: .failed,
                                  failureCode: failure!)
        }
        return readOnlyResult(request, nativeRequest: nativeRequest,
                              transaction: transaction,
                              readback: readback, phase: phase,
                              failureCode: failure)
    }

    private func readOnlyResult(
        _ request: NativeAdvancedSettingValidationRequest,
        nativeRequest: NativeCommandTransactionRequest,
        transaction: NativeCommandTransactionResult?,
        readback: Pocket3AdvancedSettingObservation?,
        phase: NativeAdvancedSettingValidationPhase,
        failureCode: String?
    ) -> NativeAdvancedSettingValidationResult {
        NativeAdvancedSettingValidationResult(
            action: request.action, executeRequested: request.execute,
            request: .init(nativeRequest),
            transaction: transaction, setting: nil, readback: readback,
            requested: true, submitted: transaction?.submitted == true,
            acknowledged: transaction?.acknowledged == true,
            observed: readback != nil, completed: phase == .completed,
            noOp: false, phase: phase, failureCode: failureCode)
    }

    private func result(
        request: NativeAdvancedSettingValidationRequest,
        coordinator: Pocket3AdvancedSettingCoordinator,
        phase: NativeAdvancedSettingValidationPhase,
        transaction: NativeCommandTransactionResult?,
        readback: Pocket3AdvancedSettingObservation?,
        failureCode: String?
    ) -> NativeAdvancedSettingValidationResult {
        let setting = coordinator.result!
        return NativeAdvancedSettingValidationResult(
            action: request.action, executeRequested: request.execute,
            request: coordinator.request.map(NativeAdvancedSettingRequestEvidence.init),
            transaction: transaction ?? setting.transaction, setting: setting,
            readback: readback ?? setting.readback,
            requested: setting.requested,
            submitted: setting.submitted, acknowledged: setting.acknowledged,
            observed: setting.observed, completed: setting.completed,
            noOp: setting.noOp, phase: phase, failureCode: failureCode)
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

    private func validationError(_ error: Pocket3AdvancedSettingCoordinatorError)
        -> NativeAdvancedSettingValidationError {
        switch error {
        case .sessionNotReady: .sessionNotReady
        case .missingSessionIdentity: .missingSessionIdentity
        case .invalidBaseline: .invalidBaseline
        case .alreadyAtTarget: .alreadyAtTarget
        case .unsupportedTarget: .unsupportedNoProtocol
        case .operationInFlight: .operationInFlight
        case .invalidClock: .invalidTimeout
        }
    }

    private func map(_ phase: Pocket3AdvancedSettingCoordinatorPhase)
        -> NativeAdvancedSettingValidationPhase {
        switch phase {
        case .idle: .failed
        case .noOp: .noOp
        case .awaitingAcknowledgment: .awaitingAcknowledgment
        case .awaitingReadback: .awaitingReadback
        case .completed: .completed
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .generationChanged: .generationChanged
        case .failed: .failed
        }
    }

    private func failureCode(_ error: NativeCommandTransactionError) -> String {
        switch error {
        case .invalidPayload: "native_advanced_setting_invalid_payload"
        case .invalidTimeout: "native_advanced_setting_invalid_timeout"
        case .commandNotReady: "native_advanced_setting_command_not_ready"
        case .staleGeneration: "native_advanced_setting_generation_changed"
        case .datalinkUnavailable: "native_advanced_setting_datalink_unavailable"
        case .nativeBusy: "native_advanced_setting_busy"
        }
    }
}

public typealias Pocket3NativeAdvancedSettingValidationRequest =
    NativeAdvancedSettingValidationRequest
public typealias Pocket3NativeAdvancedSettingValidationResult =
    NativeAdvancedSettingValidationResult
public typealias Pocket3NativeAdvancedSettingValidationService =
    NativeAdvancedSettingValidationService
