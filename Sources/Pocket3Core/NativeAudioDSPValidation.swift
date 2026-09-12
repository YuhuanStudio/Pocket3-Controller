import Foundation

public enum NativeAudioDSPValidationError: Error, Equatable, Sendable {
    case noRequestedChange
    case invalidRequestIdentity
    case invalidTimeout
    case sessionNotReady
    case missingSessionIdentity
    case invalidBinding
    case baselineRequired
    case invalidBaseline
    case operationInFlight
    case staleTransaction
}

/// Developer-only request for the variable-length `02/A0` GET and the safe
/// `02/9F` byte-2 patch. No arbitrary audio blob can enter this contract.
public struct NativeAudioDSPValidationRequest: Codable, Sendable, Equatable {
    public static let operation = "validation-wireless-audio-dsp"

    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let wind: Pocket3WindNoiseReduction?
    public let directional: Pocket3DirectionalAudio?
    public let execute: Bool
    public let timeout: TimeInterval

    public init(expectedSessionID: UUID, peripheralID: UUID,
                generation: UInt64,
                wind: Pocket3WindNoiseReduction? = nil,
                directional: Pocket3DirectionalAudio? = nil,
                execute: Bool = false, timeout: TimeInterval = 3) throws {
        guard wind != nil || directional != nil else {
            throw NativeAudioDSPValidationError.noRequestedChange
        }
        guard generation > 0, timeout.isFinite, timeout > 0,
              timeout <= NativeCommandTransactionRequest.maximumTimeout else {
            throw NativeAudioDSPValidationError.invalidTimeout
        }
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.wind = wind
        self.directional = directional
        self.execute = execute
        self.timeout = timeout
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: ["expectedSessionID", "peripheralID",
                                              "generation", "wind", "direction",
                                              "execute", "timeout"]),
              let expectedSessionID = fields["expectedSessionID"]?.string.flatMap(UUID.init(uuidString:)),
              let peripheralID = fields["peripheralID"]?.string.flatMap(UUID.init(uuidString:)),
              let generationValue = fields["generation"]?.number,
              generationValue.isFinite, generationValue.rounded() == generationValue,
              generationValue >= 1,
              generationValue < 18_446_744_073_709_551_616,
              let generation = UInt64(exactly: generationValue) else {
            throw BridgeFailure("invalid_audio_dsp_arguments",
                "Pass exact BLE session/peripheral UUIDs and a positive native generation")
        }
        let wind: Pocket3WindNoiseReduction?
        if let value = fields["wind"] {
            guard let raw = value.string else {
                throw BridgeFailure("invalid_audio_dsp_wind", "wind must be off or on")
            }
            switch raw {
            case "off": wind = .off
            case "on": wind = .on
            default: throw BridgeFailure("invalid_audio_dsp_wind", "wind must be off or on")
            }
        } else {
            wind = nil
        }
        let directional: Pocket3DirectionalAudio?
        if let value = fields["direction"] {
            guard let raw = value.string else {
                throw BridgeFailure("invalid_audio_dsp_direction", "direction must be all, front or frontAndBack")
            }
            switch raw {
            case "all": directional = .all
            case "front": directional = .front
            case "frontAndBack": directional = .frontAndBack
            default: throw BridgeFailure("invalid_audio_dsp_direction", "direction must be all, front or frontAndBack")
            }
        } else {
            directional = nil
        }
        let execute: Bool
        if let value = fields["execute"] {
            guard let parsed = value.bool else {
                throw BridgeFailure("invalid_audio_dsp_execute", "execute must be a Boolean")
            }
            execute = parsed
        } else {
            execute = false
        }
        let timeout: TimeInterval
        if let value = fields["timeout"] {
            guard let parsed = value.number else {
                throw BridgeFailure("invalid_audio_dsp_timeout", "timeout must be a finite number of seconds")
            }
            timeout = parsed
        } else {
            timeout = 3
        }
        do {
            try self.init(expectedSessionID: expectedSessionID,
                          peripheralID: peripheralID, generation: generation,
                          wind: wind, directional: directional,
                          execute: execute, timeout: timeout)
        } catch NativeAudioDSPValidationError.noRequestedChange {
            throw BridgeFailure("invalid_audio_dsp_change", "Pass wind, direction or both")
        } catch NativeAudioDSPValidationError.invalidTimeout {
            throw BridgeFailure("invalid_audio_dsp_timeout", "timeout must be between 0 and 5 seconds")
        } catch {
            throw BridgeFailure("invalid_audio_dsp_arguments", "The audio DSP validation request is not valid")
        }
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        let names = ["--session": "expectedSessionID", "--peripheral": "peripheralID",
                     "--generation": "generation", "--wind": "wind",
                     "--direction": "direction", "--timeout": "timeout"]
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
                throw BridgeFailure("usage", "Unknown, duplicate or incomplete audio DSP option")
            }
            let value = cliArguments[index + 1]
            switch key {
            case "expectedSessionID", "peripheralID", "wind", "direction":
                fields[key] = .string(value)
            case "generation", "timeout":
                guard let number = Double(value), number.isFinite else {
                    throw BridgeFailure("usage", "Audio DSP numeric options must be finite numbers")
                }
                fields[key] = .number(number)
            default:
                throw BridgeFailure("usage", "Unknown audio DSP option")
            }
            index += 2
        }
        try self.init(arguments: .object(fields))
    }

    public var arguments: JSONValue {
        var fields: [String: JSONValue] = [
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString),
            "generation": .number(Double(generation)),
            "execute": .bool(execute), "timeout": .number(timeout)
        ]
        if let wind { fields["wind"] = .string(wind == .off ? "off" : "on") }
        if let directional {
            let value: String = switch directional {
            case .all: "all"
            case .front: "front"
            case .frontAndBack: "frontAndBack"
            }
            fields["direction"] = .string(value)
        }
        return .object(fields)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "expectedSessionID": .object(["type": .string("string"), "minLength": .number(1)]),
            "peripheralID": .object(["type": .string("string"), "minLength": .number(1)]),
            "generation": .object(["type": .string("integer"), "minimum": .number(1)]),
            "wind": .object(["type": .string("string"), "enum": .array([.string("off"), .string("on")])]),
            "direction": .object(["type": .string("string"), "enum": .array([.string("all"), .string("front"), .string("frontAndBack")])]),
            "execute": .object(["type": .string("boolean")]),
            "timeout": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(5)])
        ]),
        "required": .array([.string("expectedSessionID"), .string("peripheralID"), .string("generation")]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }
}

public enum NativeAudioDSPValidationPhase: String, Codable, Sendable,
    Equatable, CaseIterable {
    case idle
    case awaitingInitialReadback
    case awaitingSetAcknowledgment
    case awaitingVerificationReadback
    case completed
    case timedOut
    case cancelled
    case generationChanged
    case failed
}

public enum NativeAudioDSPValidationStep: String, Codable, Sendable,
    Equatable, CaseIterable {
    case initialGet
    case set
    case verificationGet
}

public struct NativeAudioDSPValidationSnapshot: Codable, Sendable,
    Equatable {
    public let session: NativeCameraSessionStatus
    public let binding: ContinuousGimbalBinding
    public let baseline: Pocket3AudioDSPBaseline?
    public let nowUptime: TimeInterval

    public init(session: NativeCameraSessionStatus,
                binding: ContinuousGimbalBinding,
                baseline: Pocket3AudioDSPBaseline? = nil,
                nowUptime: TimeInterval) {
        self.session = session
        self.binding = binding
        self.baseline = baseline
        self.nowUptime = nowUptime
    }
}

public struct NativeAudioDSPRequestEvidence: Codable, Sendable,
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

public struct NativeAudioDSPStepResult: Codable, Sendable, Equatable {
    public let step: NativeAudioDSPValidationStep
    public let request: NativeAudioDSPRequestEvidence
    public let transaction: NativeCommandTransactionResult?
    public let readback: Pocket3AudioDSPReadback?
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let failureCode: String?
}

public struct NativeAudioDSPValidationResult: Codable, Sendable,
    Equatable {
    public let request: NativeAudioDSPValidationRequest
    public let baseline: Pocket3AudioDSPBaseline?
    public let phase: NativeAudioDSPValidationPhase
    public let steps: [NativeAudioDSPStepResult]
    public let requested: Bool
    public let submittedCount: Int
    public let acknowledgedCount: Int
    public let observedCount: Int
    public let completed: Bool
    public let failureCode: String?

    public var dryRun: Bool { !request.execute }
    public var partial: Bool { submittedCount > 0 && !completed }
}

public struct NativeAudioDSPValidationExecutorAdapter: Sendable {
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

/// Coordinates `A0 GET -> 9F SET -> A0 GET`. The SET payload can only be
/// produced from the first variable-length readback, preserving every byte
/// other than the confirmed byte 2. Every transaction is sent at most once.
public struct NativeAudioDSPValidationCoordinator: Sendable {
    public static let maximumReadbackAge: TimeInterval = 5
    public static let defaultTransactionTimeout: TimeInterval = 3

    public let sessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let binding: ContinuousGimbalBinding
    public private(set) var phase: NativeAudioDSPValidationPhase = .idle
    public private(set) var request: NativeAudioDSPValidationRequest?
    public private(set) var baseline: Pocket3AudioDSPBaseline?
    public private(set) var initialGetRequest: NativeCommandTransactionRequest?
    public private(set) var setRequest: NativeCommandTransactionRequest?
    public private(set) var verificationGetRequest: NativeCommandTransactionRequest?
    public private(set) var initialGetTransaction: NativeCommandTransactionResult?
    public private(set) var setTransaction: NativeCommandTransactionResult?
    public private(set) var verificationGetTransaction: NativeCommandTransactionResult?
    public private(set) var initialReadback: Pocket3AudioDSPReadback?
    public private(set) var verificationReadback: Pocket3AudioDSPReadback?
    public private(set) var expectedBlob: Data?
    public private(set) var failureCode: String?

    public init(session: NativeCameraSessionStatus,
                binding: ContinuousGimbalBinding) throws {
        guard session.generation > 0, session.state.satisfies(.commandReady) else {
            throw NativeAudioDSPValidationError.sessionNotReady
        }
        guard let sessionID = session.sessionID,
              let peripheralID = session.peerID else {
            throw NativeAudioDSPValidationError.missingSessionIdentity
        }
        guard binding == ContinuousGimbalBinding(
            sessionID: "ble:\(sessionID.uuidString)", generation: 0) else {
            throw NativeAudioDSPValidationError.invalidBinding
        }
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        generation = session.generation
        self.binding = binding
    }

    public mutating func prepare(
        _ request: NativeAudioDSPValidationRequest,
        baseline: Pocket3AudioDSPBaseline?,
        nowUptime: TimeInterval
    ) throws {
        guard phase == .idle else {
            throw NativeAudioDSPValidationError.operationInFlight
        }
        guard request.expectedSessionID == sessionID,
              request.peripheralID == peripheralID,
              request.generation == generation else {
            throw NativeAudioDSPValidationError.invalidRequestIdentity
        }
        guard nowUptime.isFinite else {
            throw NativeAudioDSPValidationError.invalidTimeout
        }
        if let baseline {
            try validateBaseline(baseline, nowUptime: nowUptime)
        }
        let get = try makeGetRequest(timeout: request.timeout)
        self.request = request
        self.baseline = baseline
        initialGetRequest = get
        setRequest = nil
        verificationGetRequest = nil
        initialGetTransaction = nil
        setTransaction = nil
        verificationGetTransaction = nil
        initialReadback = nil
        verificationReadback = nil
        expectedBlob = nil
        failureCode = nil
        if let baseline {
            try prepareSetAndVerification(baseline, request: request,
                                           nowUptime: nowUptime)
        }
        phase = .awaitingInitialReadback
    }

    public var nextRequest: NativeCommandTransactionRequest? {
        switch phase {
        case .awaitingInitialReadback: initialGetRequest
        case .awaitingSetAcknowledgment: setRequest
        case .awaitingVerificationReadback: verificationGetRequest
        default: nil
        }
    }

    @discardableResult
    public mutating func applyInitialGet(
        _ transaction: NativeCommandTransactionResult,
        nowUptime: TimeInterval
    ) -> Bool {
        guard phase == .awaitingInitialReadback,
              let validationRequest = request,
              let initialGetRequest,
              transaction.id == initialGetRequest.id,
              transaction.command == .audioDSP,
              transaction.generation == generation,
              transaction.sessionID == sessionID else {
            return fail("native_audio_dsp_stale_transaction", phase: .generationChanged)
        }
        initialGetTransaction = transaction
        guard transaction.submitted else {
            return fail(transaction.failureCode ?? "native_audio_dsp_not_submitted")
        }
        guard transaction.acknowledged else {
            return finishTransactionFailure(transaction, fallback: "native_audio_dsp_ack_invalid")
        }
        guard let readback = decodeReadback(transaction, at: nowUptime) else {
            return finishTransactionFailure(transaction, fallback: "native_audio_dsp_readback_missing")
        }
        do {
            let nextBaseline = try Pocket3AudioDSPBaseline(readback: readback,
                                                            binding: binding)
            guard let byte2 = nextBaseline.byte2, byte2.isKnown else {
                return fail("native_audio_dsp_unknown_byte2")
            }
            try validateBaseline(nextBaseline, nowUptime: nowUptime)
            initialReadback = readback
            baseline = nextBaseline
            try prepareSetAndVerification(nextBaseline, request: validationRequest,
                                          nowUptime: nowUptime)
            phase = .awaitingSetAcknowledgment
            return true
        } catch {
            return fail("native_audio_dsp_readback_invalid")
        }
    }

    @discardableResult
    public mutating func applySet(
        _ transaction: NativeCommandTransactionResult,
        nowUptime: TimeInterval
    ) -> Bool {
        guard phase == .awaitingSetAcknowledgment,
              let setRequest,
              transaction.id == setRequest.id,
              transaction.command == .audioDSP,
              transaction.generation == generation,
              transaction.sessionID == sessionID else {
            return fail("native_audio_dsp_stale_transaction", phase: .generationChanged)
        }
        setTransaction = transaction
        guard transaction.submitted else {
            return fail(transaction.failureCode ?? "native_audio_dsp_not_submitted")
        }
        guard transaction.acknowledged else {
            return finishTransactionFailure(transaction, fallback: "native_audio_dsp_ack_invalid")
        }
        phase = .awaitingVerificationReadback
        _ = nowUptime
        return true
    }

    @discardableResult
    public mutating func applyVerificationGet(
        _ transaction: NativeCommandTransactionResult,
        nowUptime: TimeInterval
    ) -> Bool {
        guard phase == .awaitingVerificationReadback,
              let verificationGetRequest,
              transaction.id == verificationGetRequest.id,
              transaction.command == .audioDSP,
              transaction.generation == generation,
              transaction.sessionID == sessionID else {
            return fail("native_audio_dsp_stale_transaction", phase: .generationChanged)
        }
        verificationGetTransaction = transaction
        guard transaction.submitted else {
            return fail(transaction.failureCode ?? "native_audio_dsp_not_submitted")
        }
        guard transaction.acknowledged else {
            return finishTransactionFailure(transaction, fallback: "native_audio_dsp_ack_invalid")
        }
        guard let readback = decodeReadback(transaction, at: nowUptime) else {
            return finishTransactionFailure(transaction, fallback: "native_audio_dsp_readback_missing")
        }
        verificationReadback = readback
        guard let expectedBlob, readback.blob == expectedBlob else {
            return fail("native_audio_dsp_readback_mismatch")
        }
        phase = .completed
        failureCode = nil
        return true
    }

    @discardableResult
    public mutating func cancel(reason: String = "cancelled") -> Bool {
        guard [.awaitingInitialReadback, .awaitingSetAcknowledgment,
               .awaitingVerificationReadback].contains(phase) else { return false }
        failureCode = reason
        phase = .cancelled
        return true
    }

    @discardableResult
    public mutating func fail(_ reason: String,
                              phase: NativeAudioDSPValidationPhase = .failed) -> Bool {
        guard [.awaitingInitialReadback, .awaitingSetAcknowledgment,
               .awaitingVerificationReadback].contains(self.phase) else { return false }
        failureCode = reason
        self.phase = phase
        return false
    }

    public func result() -> NativeAudioDSPValidationResult {
        guard let request else {
            preconditionFailure("Audio DSP validation result requires a prepared request")
        }
        var steps: [NativeAudioDSPStepResult] = []
        if let initialGetRequest {
            steps.append(step(.initialGet, request: initialGetRequest,
                               transaction: initialGetTransaction,
                               readback: initialReadback,
                               completed: initialReadback != nil))
        }
        if let setRequest {
            steps.append(step(.set, request: setRequest,
                               transaction: setTransaction, readback: nil,
                               completed: phase == .awaitingVerificationReadback || phase == .completed))
        }
        if let verificationGetRequest {
            steps.append(step(.verificationGet, request: verificationGetRequest,
                               transaction: verificationGetTransaction,
                               readback: verificationReadback,
                               completed: phase == .completed))
        }
        return NativeAudioDSPValidationResult(
            request: request, baseline: baseline, phase: phase, steps: steps,
            requested: true, submittedCount: steps.filter(\.submitted).count,
            acknowledgedCount: steps.filter(\.acknowledged).count,
            observedCount: steps.filter(\.observed).count,
            completed: phase == .completed, failureCode: failureCode)
    }

    private func step(_ step: NativeAudioDSPValidationStep,
                      request: NativeCommandTransactionRequest,
                      transaction: NativeCommandTransactionResult?,
                      readback: Pocket3AudioDSPReadback?,
                      completed: Bool) -> NativeAudioDSPStepResult {
        NativeAudioDSPStepResult(step: step, request: .init(request),
            transaction: transaction, readback: readback,
            submitted: transaction?.submitted == true,
            acknowledged: transaction?.acknowledged == true,
            observed: readback != nil || transaction?.observed == true,
            completed: completed,
            failureCode: transaction?.failureCode)
    }

    private mutating func prepareSetAndVerification(
        _ baseline: Pocket3AudioDSPBaseline,
        request: NativeAudioDSPValidationRequest,
        nowUptime: TimeInterval
    ) throws {
        let command = try Pocket3AudioDSPSetCommand(
            baseline: baseline, binding: binding, nowUptime: nowUptime,
            wind: request.wind, directional: request.directional)
        expectedBlob = command.blob
        setRequest = try NativeCommandTransactionRequest(
            command: .audioDSP, generation: generation, sessionID: sessionID,
            frame: NativeCommandFrame(frame: command.frame(sequence: 0)),
            timeout: request.timeout)
        verificationGetRequest = try makeGetRequest(timeout: request.timeout)
    }

    private func validateBaseline(_ baseline: Pocket3AudioDSPBaseline,
                                  nowUptime: TimeInterval) throws {
        guard baseline.binding == binding,
              baseline.isFresh(nowUptime: nowUptime,
                               maximumAge: Self.maximumReadbackAge),
              baseline.statusRaw == 0,
              baseline.blob.count > 2,
              baseline.blob.count <= DUMLCodec.maximumPayloadLength,
              let byte2 = baseline.byte2,
              byte2.isKnown else {
            if baseline.binding != binding { throw NativeAudioDSPValidationError.invalidBaseline }
            if !baseline.isFresh(nowUptime: nowUptime,
                                 maximumAge: Self.maximumReadbackAge) {
                throw NativeAudioDSPValidationError.baselineRequired
            }
            throw NativeAudioDSPValidationError.invalidBaseline
        }
    }

    private func makeGetRequest(timeout: TimeInterval)
        throws -> NativeCommandTransactionRequest {
        let frame = NativeCommandFrame(frame: Pocket3AudioDSPGetCommand().frame(sequence: 0))
        return try NativeCommandTransactionRequest(
            command: .audioDSP, generation: generation, sessionID: sessionID,
            frame: frame, timeout: timeout) { response in
                guard response.source == Pocket3AudioDSPGetCommand.destination,
                      response.destination == Pocket3AudioDSPGetCommand.source,
                      response.flags == 0x80 || response.flags == 0xC0,
                      response.commandSet == Pocket3AudioDSPGetCommand.commandSet,
                      response.commandID == Pocket3AudioDSPGetCommand.commandID,
                      let readback = Pocket3AudioDSPReadback.decode(response.payload) else {
                    return nil
                }
                return readback.raw
            }
    }

    private func decodeReadback(_ transaction: NativeCommandTransactionResult,
                                at nowUptime: TimeInterval) -> Pocket3AudioDSPReadback? {
        guard let payload = transaction.observedPayload,
              let receivedUptime = transaction.observedUptime ?? Optional(nowUptime),
              receivedUptime.isFinite else { return nil }
        return Pocket3AudioDSPReadback.decode(payload,
                                              receivedUptime: receivedUptime)
    }

    private mutating func finishTransactionFailure(
        _ transaction: NativeCommandTransactionResult,
        fallback: String
    ) -> Bool {
        switch transaction.end {
        case .timedOut: phase = .timedOut
        case .cancelled: phase = .cancelled
        case .generationChanged: phase = .generationChanged
        default: phase = .failed
        }
        failureCode = transaction.failureCode ?? fallback
        return false
    }

}

/// Executes the three-step plan through an injected owner. The default App
/// path provides the existing datalink adapter; dry-run never calls it.
public struct NativeAudioDSPValidationService: Sendable {
    private let executor: NativeAudioDSPValidationExecutorAdapter?

    public init(adapter: NativeAudioDSPValidationExecutorAdapter? = nil) {
        executor = adapter
    }

    public func run(_ request: NativeAudioDSPValidationRequest,
                    snapshot: NativeAudioDSPValidationSnapshot) async throws
        -> NativeAudioDSPValidationResult {
        guard request.expectedSessionID == snapshot.session.sessionID,
              request.peripheralID == snapshot.session.peerID,
              request.generation == snapshot.session.generation else {
            throw NativeAudioDSPValidationError.invalidRequestIdentity
        }
        var coordinator = try NativeAudioDSPValidationCoordinator(
            session: snapshot.session, binding: snapshot.binding)
        try coordinator.prepare(request, baseline: snapshot.baseline,
                                nowUptime: snapshot.nowUptime)
        guard request.execute else { return coordinator.result() }
        guard let executor else {
            _ = coordinator.fail("native_audio_dsp_executor_unavailable")
            return coordinator.result()
        }
        while let nativeRequest = coordinator.nextRequest {
            do {
                let transaction = try await executor.execute(
                    nativeRequest, readiness: snapshot.session)
                switch coordinator.phase {
                case .awaitingInitialReadback:
                    _ = coordinator.applyInitialGet(transaction,
                        nowUptime: transaction.finishedUptime ?? snapshot.nowUptime)
                case .awaitingSetAcknowledgment:
                    _ = coordinator.applySet(transaction,
                        nowUptime: transaction.finishedUptime ?? snapshot.nowUptime)
                case .awaitingVerificationReadback:
                    _ = coordinator.applyVerificationGet(transaction,
                        nowUptime: transaction.finishedUptime ?? snapshot.nowUptime)
                default:
                    break
                }
            } catch is CancellationError {
                _ = coordinator.cancel()
            } catch let error as NativeCommandTransactionError {
                _ = coordinator.fail(nativeAudioDSPFailureCode(error))
            } catch {
                _ = coordinator.fail("native_audio_dsp_executor_failed")
            }
            if coordinator.phase == .completed ||
                [.timedOut, .cancelled, .generationChanged, .failed].contains(coordinator.phase) {
                break
            }
        }
        return coordinator.result()
    }
}

private func nativeAudioDSPFailureCode(_ error: NativeCommandTransactionError) -> String {
    switch error {
    case .invalidPayload: "native_audio_dsp_invalid_payload"
    case .invalidTimeout: "native_audio_dsp_invalid_timeout"
    case .commandNotReady: "native_audio_dsp_command_not_ready"
    case .staleGeneration: "native_audio_dsp_generation_changed"
    case .datalinkUnavailable: "native_audio_dsp_datalink_unavailable"
    case .nativeBusy: "native_audio_dsp_busy"
    }
}

public typealias Pocket3NativeAudioDSPValidationRequest = NativeAudioDSPValidationRequest
public typealias Pocket3NativeAudioDSPValidationResult = NativeAudioDSPValidationResult
public typealias Pocket3NativeAudioDSPValidationCoordinator = NativeAudioDSPValidationCoordinator
