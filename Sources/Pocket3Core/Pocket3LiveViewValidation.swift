import Foundation

/// Developer-only request for the bounded live-view session coordinator.  The
/// default is dry-run; `execute` is the only bit that permits command
/// submission in the App route.
public struct Pocket3LiveViewValidationRequest: Codable, Sendable,
    Equatable {
    public static let operation = "validation-wireless-live-view"
    public static let defaultTimeout: TimeInterval = 2
    public static let defaultWaitSeconds: TimeInterval = 5
    public static let maximumWaitSeconds: TimeInterval = 30

    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let execute: Bool
    public let sendPreEnableHint: Bool
    public let timeout: TimeInterval
    public let waitSeconds: TimeInterval

    public init(
        expectedSessionID: UUID,
        peripheralID: UUID,
        generation: UInt64,
        execute: Bool = false,
        sendPreEnableHint: Bool = false,
        timeout: TimeInterval = Self.defaultTimeout,
        waitSeconds: TimeInterval = Self.defaultWaitSeconds
    ) throws {
        guard generation != 0,
              timeout.isFinite, timeout > 0,
              timeout <= NativeCommandTransactionRequest.maximumTimeout,
              waitSeconds.isFinite, waitSeconds >= 0,
              waitSeconds <= Self.maximumWaitSeconds else {
            throw Pocket3LiveViewValidationError.invalidArguments
        }
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.execute = execute
        self.sendPreEnableHint = sendPreEnableHint
        self.timeout = timeout
        self.waitSeconds = waitSeconds
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                "expectedSessionID", "peripheralID", "generation", "execute",
                "sendPreEnableHint", "timeout", "waitSeconds"
              ]),
              let sessionText = fields["expectedSessionID"]?.string,
              let expectedSessionID = UUID(uuidString: sessionText),
              let peripheralText = fields["peripheralID"]?.string,
              let peripheralID = UUID(uuidString: peripheralText),
              let generationNumber = fields["generation"]?.number,
              generationNumber.isFinite,
              generationNumber.rounded() == generationNumber,
              generationNumber >= 1,
              let generation = UInt64(exactly: generationNumber) else {
            throw Pocket3LiveViewValidationError.invalidArguments
        }
        let execute = try Self.boolean(fields["execute"])
        let sendPreEnableHint = try Self.boolean(fields["sendPreEnableHint"])
        let timeout = try Self.number(fields["timeout"], default: Self.defaultTimeout)
        let waitSeconds = try Self.number(fields["waitSeconds"], default: Self.defaultWaitSeconds)
        try self.init(expectedSessionID: expectedSessionID,
                      peripheralID: peripheralID, generation: generation,
                      execute: execute, sendPreEnableHint: sendPreEnableHint,
                      timeout: timeout, waitSeconds: waitSeconds)
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        let names = [
            "--session": "expectedSessionID",
            "--peripheral": "peripheralID",
            "--generation": "generation",
            "--timeout": "timeout",
            "--wait": "waitSeconds"
        ]
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
            if argument == "--hint" {
                guard fields["sendPreEnableHint"] == nil else {
                    throw BridgeFailure("usage", "Duplicate --hint")
                }
                fields["sendPreEnableHint"] = .bool(true)
                index += 1
                continue
            }
            guard let key = names[argument], index + 1 < cliArguments.count,
                  fields[key] == nil else {
                throw BridgeFailure("usage", "Unknown, duplicate or incomplete live-view option")
            }
            let value = cliArguments[index + 1]
            switch key {
            case "expectedSessionID", "peripheralID":
                fields[key] = .string(value)
            case "generation", "timeout", "waitSeconds":
                guard let number = Double(value), number.isFinite else {
                    throw BridgeFailure("usage", "Live-view numeric options must be finite")
                }
                fields[key] = .number(number)
            default:
                throw BridgeFailure("usage", "Unknown live-view option")
            }
            index += 2
        }
        do {
            try self.init(arguments: .object(fields))
        } catch let error as Pocket3LiveViewValidationError {
            throw BridgeFailure("invalid_native_live_view_request",
                                String(describing: error))
        }
    }

    public var arguments: JSONValue {
        let fields: [String: JSONValue] = [
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString),
            "generation": .number(Double(generation)),
            "execute": .bool(execute),
            "sendPreEnableHint": .bool(sendPreEnableHint),
            "timeout": .number(timeout),
            "waitSeconds": .number(waitSeconds)
        ]
        return .object(fields)
    }

    private static func boolean(_ value: JSONValue?) throws -> Bool {
        guard let value else { return false }
        guard let parsed = value.bool else {
            throw Pocket3LiveViewValidationError.invalidArguments
        }
        return parsed
    }

    private static func number(_ value: JSONValue?, default valueDefault: Double)
        throws -> Double {
        guard let value else { return valueDefault }
        guard let parsed = value.number else {
            throw Pocket3LiveViewValidationError.invalidArguments
        }
        return parsed
    }
}

public enum Pocket3LiveViewValidationError: Error, Codable, Sendable,
    Equatable {
    case invalidArguments
    case invalidRequestIdentity
    case sessionNotReady
    case routeUnavailable
    case executorUnavailable
    case ingestTimeout
    case coordinatorBusy
}

/// Credential-free snapshot evidence exposed by the developer dry-run route.
/// It makes the hardware preflight useful without opening a new link or
/// reading the stored Wi-Fi credentials.
public struct Pocket3LiveViewValidationDiagnostics: Codable, Sendable,
    Equatable {
    public let requestedSessionID: UUID
    public let requestedPeripheralID: UUID
    public let requestedGeneration: UInt64
    public let currentSessionID: UUID?
    public let currentPeerID: UUID?
    public let currentGeneration: UInt64
    public let nativeState: NativeCameraSessionState
    public let datalinkAvailable: Bool
    public let datalinkPhase: Pocket3DatalinkPhase?
    public let datalinkBindingGeneration: UInt64?
    public let routeStatus: Pocket3DatalinkRouteStatus
    public let liveViewSinkAttached: Bool
    public let noNetworkMutation: Bool
    public let noCredentialRead: Bool

    public init(
        requestedSessionID: UUID,
        requestedPeripheralID: UUID,
        requestedGeneration: UInt64,
        currentSessionID: UUID?,
        currentPeerID: UUID?,
        currentGeneration: UInt64,
        nativeState: NativeCameraSessionState,
        datalinkAvailable: Bool,
        datalinkPhase: Pocket3DatalinkPhase?,
        datalinkBindingGeneration: UInt64?,
        routeStatus: Pocket3DatalinkRouteStatus,
        liveViewSinkAttached: Bool = false,
        noNetworkMutation: Bool = true,
        noCredentialRead: Bool = true
    ) {
        self.requestedSessionID = requestedSessionID
        self.requestedPeripheralID = requestedPeripheralID
        self.requestedGeneration = requestedGeneration
        self.currentSessionID = currentSessionID
        self.currentPeerID = currentPeerID
        self.currentGeneration = currentGeneration
        self.nativeState = nativeState
        self.datalinkAvailable = datalinkAvailable
        self.datalinkPhase = datalinkPhase
        self.datalinkBindingGeneration = datalinkBindingGeneration
        self.routeStatus = routeStatus
        self.liveViewSinkAttached = liveViewSinkAttached
        self.noNetworkMutation = noNetworkMutation
        self.noCredentialRead = noCredentialRead
    }
}

/// The App route returns this even when execute is false or an explicit gate
/// rejects the attempt, so developer tooling can inspect the reason without
/// guessing whether a packet was sent.
public struct Pocket3LiveViewValidationResult: Codable, Sendable,
    Equatable {
    public let request: Pocket3LiveViewValidationRequest
    public let executeRequested: Bool
    public let dryRun: Bool
    public let exactSessionMatch: Bool
    public let routeAllowed: Bool
    public let commandReady: Bool
    public let diagnostics: Pocket3LiveViewValidationDiagnostics?
    public let attachBeforeEnable: Bool
    public let automaticJoinAttempted: Bool
    public let plannedCommands: [Pocket3LiveViewSessionCommandKind]
    public let coordinator: Pocket3LiveViewSessionSnapshot?
    public let sessionResult: Pocket3LiveViewSessionResult?
    public let failureCode: String?

    public init(
        request: Pocket3LiveViewValidationRequest,
        exactSessionMatch: Bool,
        routeAllowed: Bool,
        commandReady: Bool,
        diagnostics: Pocket3LiveViewValidationDiagnostics? = nil,
        coordinator: Pocket3LiveViewSessionSnapshot? = nil,
        sessionResult: Pocket3LiveViewSessionResult? = nil,
        failureCode: String? = nil
    ) {
        self.request = request
        executeRequested = request.execute
        dryRun = !request.execute
        self.exactSessionMatch = exactSessionMatch
        self.routeAllowed = routeAllowed
        self.commandReady = commandReady
        self.diagnostics = diagnostics
        attachBeforeEnable = true
        automaticJoinAttempted = false
        plannedCommands = request.sendPreEnableHint
            ? [.preEnableHint, .enable, .requestIDR]
            : [.enable, .requestIDR]
        self.coordinator = coordinator
        self.sessionResult = sessionResult
        self.failureCode = failureCode.map { String($0.prefix(128)) }
    }
}
