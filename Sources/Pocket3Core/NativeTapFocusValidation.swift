import Foundation

/// Explicit coordinate metadata for the native tap-AF path.  The four-step
/// payload already uses DJI-normalized coordinates; this value records whether
/// a local camera calibration has proved how a landscape/portrait preview,
/// rotation and mirror map into that space.  No mapping is inferred here.
public enum NativeTapFocusImageOrientation: String, Codable, Sendable,
    Equatable, CaseIterable {
    case landscape
    case portrait
}

public enum NativeTapFocusRotation: Int, Codable, Sendable, Equatable,
    CaseIterable {
    case zero = 0
    case ninety = 90
    case oneEighty = 180
    case twoSeventy = 270
}

public struct NativeTapFocusCoordinateCalibration: Codable, Sendable,
    Equatable {
    public let orientation: NativeTapFocusImageOrientation
    public let rotation: NativeTapFocusRotation
    public let mirrored: Bool
    public let verified: Bool

    public init(orientation: NativeTapFocusImageOrientation,
                rotation: NativeTapFocusRotation = .zero,
                mirrored: Bool = false, verified: Bool = false) {
        self.orientation = orientation
        self.rotation = rotation
        self.mirrored = mirrored
        self.verified = verified
    }

    public static let unverifiedLandscape = Self(orientation: .landscape)
    public static let unverifiedPortrait = Self(orientation: .portrait)
}

public typealias Pocket3TapFocusCoordinateCalibration = NativeTapFocusCoordinateCalibration

public enum NativeTapFocusValidationError: Error, Equatable, Sendable {
    case invalidCoordinate
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

/// Developer-only request for the native datalink's existing four-step
/// `22/30/68/32` tap-AF sequence. The request is dry-run unless `execute` is
/// explicit, and execution still requires a separately verified calibration.
public struct NativeTapFocusValidationRequest: Codable, Sendable, Equatable {
    public static let operation = "validation-wireless-native-tap-focus"

    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let x: Double
    public let y: Double
    public let execute: Bool
    public let timeout: TimeInterval

    public init(expectedSessionID: UUID, peripheralID: UUID,
                generation: UInt64, x: Double, y: Double,
                execute: Bool = false, timeout: TimeInterval = 0.8) throws {
        guard generation > 0, x.isFinite, y.isFinite,
              (0.1...0.9).contains(x), (0.1...0.9).contains(y) else {
            throw NativeTapFocusValidationError.invalidCoordinate
        }
        guard timeout.isFinite, timeout > 0,
              timeout <= NativeCommandTransactionRequest.maximumTimeout else {
            throw NativeTapFocusValidationError.invalidTimeout
        }
        _ = try Pocket3TapFocusSequence(x: x, y: y)
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.x = x
        self.y = y
        self.execute = execute
        self.timeout = timeout
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: ["expectedSessionID", "peripheralID",
                                              "generation", "x", "y", "execute", "timeout"]),
              let expectedSessionID = fields["expectedSessionID"]?.string.flatMap(UUID.init(uuidString:)),
              let peripheralID = fields["peripheralID"]?.string.flatMap(UUID.init(uuidString:)),
              let generationValue = fields["generation"]?.number,
              generationValue.isFinite, generationValue.rounded() == generationValue,
              generationValue >= 1,
              generationValue < 18_446_744_073_709_551_616,
              let generation = UInt64(exactly: generationValue),
              let x = fields["x"]?.number, let y = fields["y"]?.number else {
            throw BridgeFailure("invalid_native_tap_focus_arguments",
                "Pass exact BLE session/peripheral UUIDs, generation and normalized x/y")
        }
        let execute: Bool
        if let value = fields["execute"] {
            guard let parsed = value.bool else {
                throw BridgeFailure("invalid_native_tap_focus_execute",
                    "execute must be a Boolean")
            }
            execute = parsed
        } else {
            execute = false
        }
        let timeout: TimeInterval
        if let value = fields["timeout"] {
            guard let parsed = value.number else {
                throw BridgeFailure("invalid_native_tap_focus_timeout",
                    "timeout must be a finite number of seconds")
            }
            timeout = parsed
        } else {
            timeout = 0.8
        }
        do {
            try self.init(expectedSessionID: expectedSessionID,
                          peripheralID: peripheralID, generation: generation,
                          x: x, y: y, execute: execute, timeout: timeout)
        } catch NativeTapFocusValidationError.invalidCoordinate {
            throw BridgeFailure("invalid_native_tap_focus_coordinates",
                "x and y must be finite normalized DJI coordinates in 0.1...0.9")
        } catch NativeTapFocusValidationError.invalidTimeout {
            throw BridgeFailure("invalid_native_tap_focus_timeout",
                "timeout must be between 0 and 5 seconds")
        } catch {
            throw BridgeFailure("invalid_native_tap_focus_arguments",
                "The native tap-AF request is not valid")
        }
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        let names = ["--session": "expectedSessionID", "--peripheral": "peripheralID",
                     "--generation": "generation", "--x": "x", "--y": "y",
                     "--timeout": "timeout"]
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
                throw BridgeFailure("usage", "Unknown, duplicate or incomplete native tap-AF option")
            }
            let value = cliArguments[index + 1]
            switch key {
            case "expectedSessionID", "peripheralID":
                fields[key] = .string(value)
            case "generation", "x", "y", "timeout":
                guard let number = Double(value), number.isFinite else {
                    throw BridgeFailure("usage", "Native tap-AF numeric options must be finite numbers")
                }
                fields[key] = .number(number)
            default:
                throw BridgeFailure("usage", "Unknown native tap-AF option")
            }
            index += 2
        }
        try self.init(arguments: .object(fields))
    }

    public var arguments: JSONValue {
        .object([
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString),
            "generation": .number(Double(generation)),
            "x": .number(x), "y": .number(y),
            "execute": .bool(execute), "timeout": .number(timeout)
        ])
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "expectedSessionID": .object(["type": .string("string"), "minLength": .number(1)]),
            "peripheralID": .object(["type": .string("string"), "minLength": .number(1)]),
            "generation": .object(["type": .string("integer"), "minimum": .number(1)]),
            "x": .object(["type": .string("number"), "minimum": .number(0.1), "maximum": .number(0.9)]),
            "y": .object(["type": .string("number"), "minimum": .number(0.1), "maximum": .number(0.9)]),
            "execute": .object(["type": .string("boolean")]),
            "timeout": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(5)])
        ]),
        "required": .array([.string("expectedSessionID"), .string("peripheralID"),
                             .string("generation"), .string("x"), .string("y")]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }
}

public struct NativeTapFocusBaseline: Codable, Sendable, Equatable {
    public let lens: CameraSettingsObservation
    public let exposure: CameraSettingsObservation

    public init(request: NativeTapFocusValidationRequest,
                observations: [CameraSettingsObservation],
                nowUptime: TimeInterval) throws {
        let binding = ContinuousGimbalBinding(
            sessionID: "ble:\(request.expectedSessionID.uuidString)", generation: 0)
        guard let lens = observations.first(where: {
            $0.property == .lensState && $0.binding == binding &&
                $0.isFresh(now: nowUptime)
        }), case .focus? = lens.value,
              let exposure = observations.first(where: {
                  $0.property == .exposure && $0.binding == binding &&
                      $0.isFresh(now: nowUptime)
              }), case .autoEV? = exposure.value,
              exposure.exposureMode == .automatic else {
            throw NativeTapFocusValidationError.baselineRequired
        }
        self.lens = lens
        self.exposure = exposure
    }

    public func isFresh(nowUptime: TimeInterval) -> Bool {
        lens.isFresh(now: nowUptime) && exposure.isFresh(now: nowUptime)
    }
}

public enum NativeTapFocusValidationPhase: String, Codable, Sendable,
    Equatable, CaseIterable {
    case idle
    case awaitingAcknowledgment
    case completed
    case timedOut
    case cancelled
    case generationChanged
    case failed
}

public struct NativeTapFocusStepRequestEvidence: Codable, Sendable,
    Equatable {
    public let id: UUID
    public let step: Pocket3TapFocusStep
    public let command: NativeCameraSessionCommand
    public let generation: UInt64
    public let sessionID: UUID?
    public let frame: NativeCommandFrame
    public let timeout: TimeInterval

    init(step: Pocket3TapFocusStep, request: NativeCommandTransactionRequest) {
        id = request.id
        self.step = step
        command = request.command
        generation = request.generation
        sessionID = request.sessionID
        frame = request.frame
        timeout = request.timeout
    }
}

public struct NativeTapFocusStepResult: Codable, Sendable, Equatable {
    public let step: Pocket3TapFocusStep
    public let commandID: UInt8
    public let request: NativeTapFocusStepRequestEvidence
    public let transaction: NativeCommandTransactionResult?
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let failureCode: String?
    /// Serialized evidence is optional for backward-compatible decoding of
    /// older validation reports; new coordinator results populate it.
    public var evidence: Pocket3NativeActionEvidenceReport?

    /// Evidence for this exact 22/30/68/32 transaction. A successful ACK
    /// remains separate from optical focus confirmation.
    public var actionEvidence: Pocket3NativeActionEvidenceReport {
        if let evidence { return evidence }
        let transaction = self.transaction
        return Pocket3NativeActionEvidenceReport(
            commandSet: request.frame.commandSet,
            commandID: request.frame.commandID,
            requestPayload: request.frame.payload,
            submitted: submitted,
            responseReceived: transaction?.responseReceived == true,
            responseStatusRaw: transaction?.responseStatus,
            acknowledged: acknowledged,
            readbackObserved: observed,
            physicalEvidence: false,
            cancelled: transaction?.end == .cancelled,
            connectionChanged: transaction?.end == .generationChanged)
    }

    public var transportEvidence: Pocket3NativeActionEvidenceReport {
        actionEvidence
    }
}

public struct NativeTapFocusValidationResult: Codable, Sendable,
    Equatable {
    public let request: NativeTapFocusValidationRequest
    public let baseline: NativeTapFocusBaseline
    public let coordinateCalibration: NativeTapFocusCoordinateCalibration
    public let phase: NativeTapFocusValidationPhase
    public let steps: [NativeTapFocusStepResult]
    public let requested: Bool
    public let submittedCount: Int
    public let acknowledgedCount: Int
    public let completed: Bool
    public let failureCode: String?
    /// Per-step serialized evidence. It remains optional when decoding a
    /// report produced before this classification layer existed.
    public let evidence: [Pocket3NativeActionEvidenceReport]?

    public var partialSequence: Bool {
        submittedCount > 0 && !completed
    }
    /// The four ACKs only prove the native command sequence. They do not prove
    /// optical focus or an AVFoundation-to-DJI coordinate mapping.
    public var verification: String {
        "four_step_ack_only_no_optical_focus_readback"
    }

    /// Per-step evidence makes a missing transport reply distinguishable from
    /// a correlated command rejection or an ACK without focus readback.
    public var transportEvidence: [Pocket3NativeActionEvidenceReport] {
        evidence ?? steps.map(\.actionEvidence)
    }

    public var aggregateTransportEvidence: Pocket3NativeActionEvidenceLevel {
        Pocket3NativeActionEvidenceReport.summarize(transportEvidence)
    }
}

public struct NativeTapFocusValidationSnapshot: Codable, Sendable,
    Equatable {
    public let session: NativeCameraSessionStatus
    public let observations: [CameraSettingsObservation]
    public let coordinateCalibration: NativeTapFocusCoordinateCalibration
    public let nowUptime: TimeInterval

    public init(session: NativeCameraSessionStatus,
                observations: [CameraSettingsObservation],
                coordinateCalibration: NativeTapFocusCoordinateCalibration,
                nowUptime: TimeInterval) {
        self.session = session
        self.observations = observations
        self.coordinateCalibration = coordinateCalibration
        self.nowUptime = nowUptime
    }
}

public struct NativeTapFocusValidationExecutorAdapter: Sendable {
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

/// Pure ordered coordinator for the native datalink four-step sequence. Each
/// step owns one transaction ID and one correlated ACK; no retry or reordering
/// branch exists. Cancellation retains earlier partial evidence.
public struct NativeTapFocusValidationCoordinator: Sendable {
    public static let maximumReadbackAge: TimeInterval = 5
    public static let defaultTransactionTimeout: TimeInterval = 0.8

    public let sessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public private(set) var phase: NativeTapFocusValidationPhase = .idle
    public private(set) var request: NativeTapFocusValidationRequest?
    public private(set) var baseline: NativeTapFocusBaseline?
    public private(set) var sequence: Pocket3TapFocusSequence?
    public private(set) var stepRequests: [NativeCommandTransactionRequest] = []
    public private(set) var stepTransactions: [NativeCommandTransactionResult?] = []
    public private(set) var nextStepIndex = 0
    public private(set) var failureCode: String?

    public init(session: NativeCameraSessionStatus) throws {
        guard session.generation > 0 else {
            throw NativeTapFocusValidationError.sessionNotReady
        }
        guard session.state.satisfies(.commandReady) else {
            throw NativeTapFocusValidationError.sessionNotReady
        }
        guard let sessionID = session.sessionID,
              let peripheralID = session.peerID else {
            throw NativeTapFocusValidationError.missingSessionIdentity
        }
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        generation = session.generation
    }

    public mutating func prepare(
        _ request: NativeTapFocusValidationRequest,
        observations: [CameraSettingsObservation],
        nowUptime: TimeInterval
    ) throws {
        guard phase == .idle else {
            throw NativeTapFocusValidationError.operationInFlight
        }
        guard request.expectedSessionID == sessionID,
              request.peripheralID == peripheralID,
              request.generation == generation else {
            throw NativeTapFocusValidationError.invalidRequestIdentity
        }
        guard nowUptime.isFinite else {
            throw NativeTapFocusValidationError.invalidTimeout
        }
        let checkedBaseline = try NativeTapFocusBaseline(
            request: request, observations: observations, nowUptime: nowUptime)
        let sequence = try Pocket3TapFocusSequence(x: request.x, y: request.y)
        let frames = Pocket3TapFocusStep.allCases.map {
            sequence.frame(for: $0, sequence: 0)
        }
        let requests = try zip(Pocket3TapFocusStep.allCases, frames).map { step, frame in
            try NativeCommandTransactionRequest(
                command: .focusMode, generation: generation, sessionID: sessionID,
                frame: NativeCommandFrame(frame: frame), timeout: request.timeout)
        }
        self.request = request
        baseline = checkedBaseline
        self.sequence = sequence
        stepRequests = requests
        stepTransactions = Array(repeating: nil, count: requests.count)
        nextStepIndex = 0
        failureCode = nil
        phase = .awaitingAcknowledgment
    }

    public var nextRequest: NativeCommandTransactionRequest? {
        guard phase == .awaitingAcknowledgment,
              stepRequests.indices.contains(nextStepIndex) else { return nil }
        return stepRequests[nextStepIndex]
    }

    @discardableResult
    public mutating func apply(_ transaction: NativeCommandTransactionResult,
                               nowUptime: TimeInterval? = nil) -> Bool {
        guard phase == .awaitingAcknowledgment,
              stepRequests.indices.contains(nextStepIndex),
              stepRequests[nextStepIndex].id == transaction.id,
              transaction.command == .focusMode,
              transaction.generation == generation,
              transaction.sessionID == sessionID else {
            failureCode = "native_tap_focus_stale_transaction"
            phase = .generationChanged
            return false
        }
        if let nowUptime, !nowUptime.isFinite {
            failureCode = "native_tap_focus_invalid_clock"
            phase = .failed
            return false
        }
        stepTransactions[nextStepIndex] = transaction
        guard transaction.submitted else {
            failureCode = transaction.failureCode ?? "native_tap_focus_not_submitted"
            phase = .failed
            return false
        }
        switch transaction.end {
        case .acknowledged, .observed:
            guard transaction.acknowledged else {
                failureCode = transaction.failureCode ?? "native_tap_focus_ack_invalid"
                phase = .failed
                return false
            }
            if nextStepIndex == stepRequests.count - 1 {
                phase = .completed
                failureCode = nil
                return true
            }
            nextStepIndex += 1
            return true
        case .timedOut:
            failureCode = transaction.failureCode ?? "native_tap_focus_timeout"
            phase = .timedOut
            return false
        case .cancelled:
            failureCode = transaction.failureCode ?? "cancelled"
            phase = .cancelled
            return false
        case .generationChanged:
            failureCode = transaction.failureCode ?? "native_tap_focus_connection_changed"
            phase = .generationChanged
            return false
        case .rejected, .failed:
            failureCode = transaction.failureCode ?? "native_tap_focus_failed"
            phase = .failed
            return false
        }
    }

    @discardableResult
    public mutating func cancel(reason: String = "cancelled") -> Bool {
        guard phase == .awaitingAcknowledgment else { return false }
        failureCode = reason
        phase = .cancelled
        return true
    }

    @discardableResult
    public mutating func blockExecution(
        reason: String = "native_tap_focus_coordinates_uncalibrated"
    ) -> Bool {
        guard phase == .awaitingAcknowledgment else { return false }
        failureCode = reason
        phase = .failed
        return true
    }

    public func result(
        coordinateCalibration: NativeTapFocusCoordinateCalibration,
        executeRequested: Bool
    ) -> NativeTapFocusValidationResult {
        guard let request, let baseline else {
            preconditionFailure("Tap focus validation result requires a prepared request")
        }
        let steps = zip(Pocket3TapFocusStep.allCases.indices, Pocket3TapFocusStep.allCases).map {
            index, step in
            let transaction = stepTransactions.indices.contains(index)
                ? stepTransactions[index] : nil
            let requestEvidence = NativeTapFocusStepRequestEvidence(
                step: step, request: stepRequests[index])
            var stepResult = NativeTapFocusStepResult(
                step: step, commandID: step.commandID, request: requestEvidence,
                transaction: transaction, submitted: transaction?.submitted == true,
                acknowledged: transaction?.acknowledged == true,
                observed: transaction?.observed == true,
                failureCode: transaction?.failureCode)
            stepResult.evidence = stepResult.actionEvidence
            return stepResult
        }
        return NativeTapFocusValidationResult(
            request: request, baseline: baseline,
            coordinateCalibration: coordinateCalibration, phase: phase,
            steps: steps, requested: true,
            submittedCount: steps.filter(\.submitted).count,
            acknowledgedCount: steps.filter(\.acknowledged).count,
            completed: phase == .completed, failureCode: failureCode,
            evidence: steps.map(\.actionEvidence))
    }
}

/// Runs the pure coordinator through an injected native datalink owner. The
/// default caller supplies no adapter and an unverified calibration, so no A6
/// equivalent tap-AF write can occur from the current App/CLI path.
public struct NativeTapFocusValidationService: Sendable {
    private let executor: NativeTapFocusValidationExecutorAdapter?

    public init(adapter: NativeTapFocusValidationExecutorAdapter? = nil) {
        executor = adapter
    }

    public func run(_ request: NativeTapFocusValidationRequest,
                    snapshot: NativeTapFocusValidationSnapshot) async throws
        -> NativeTapFocusValidationResult {
        guard request.expectedSessionID == snapshot.session.sessionID,
              request.peripheralID == snapshot.session.peerID,
              request.generation == snapshot.session.generation else {
            throw NativeTapFocusValidationError.invalidRequestIdentity
        }
        var coordinator = try NativeTapFocusValidationCoordinator(
            session: snapshot.session)
        try coordinator.prepare(request, observations: snapshot.observations,
                                nowUptime: snapshot.nowUptime)
        guard request.execute else {
            return coordinator.result(coordinateCalibration: snapshot.coordinateCalibration,
                                      executeRequested: false)
        }
        guard snapshot.coordinateCalibration.verified else {
            _ = coordinator.blockExecution()
            return coordinator.result(coordinateCalibration: snapshot.coordinateCalibration,
                                      executeRequested: true)
        }
        guard let executor else {
            _ = coordinator.blockExecution(reason: "native_tap_focus_executor_unavailable")
            return coordinator.result(coordinateCalibration: snapshot.coordinateCalibration,
                                      executeRequested: true)
        }
        while let nativeRequest = coordinator.nextRequest {
            do {
                let transaction = try await executor.execute(
                    nativeRequest, readiness: snapshot.session)
                _ = coordinator.apply(transaction,
                    nowUptime: transaction.finishedUptime)
            } catch is CancellationError {
                _ = coordinator.cancel()
            } catch let error as NativeCommandTransactionError {
                _ = coordinator.blockExecution(reason: nativeTapFocusFailureCode(error))
            } catch {
                _ = coordinator.blockExecution(reason: "native_tap_focus_executor_failed")
            }
            if coordinator.phase != .awaitingAcknowledgment { break }
        }
        return coordinator.result(coordinateCalibration: snapshot.coordinateCalibration,
                                  executeRequested: true)
    }
}

private func nativeTapFocusFailureCode(_ error: NativeCommandTransactionError) -> String {
    switch error {
    case .invalidPayload: "native_tap_focus_invalid_payload"
    case .invalidTimeout: "native_tap_focus_invalid_timeout"
    case .commandNotReady: "native_tap_focus_command_not_ready"
    case .staleGeneration: "native_tap_focus_generation_changed"
    case .datalinkUnavailable: "native_tap_focus_datalink_unavailable"
    case .nativeBusy: "native_tap_focus_busy"
    }
}

public typealias Pocket3NativeTapFocusValidationRequest = NativeTapFocusValidationRequest
public typealias Pocket3NativeTapFocusValidationResult = NativeTapFocusValidationResult
public typealias Pocket3NativeTapFocusValidationCoordinator = NativeTapFocusValidationCoordinator
