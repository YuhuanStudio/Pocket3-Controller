import Foundation

/// The developer validation surface for the body-recording coordinators.
///
/// This request is deliberately separate from a transport request.  The
/// caller supplies the current session and fresh readbacks, while an optional
/// executor remains the only boundary that can submit a command.  A missing
/// executor therefore makes `execute` unavailable; it never causes this type
/// to create a datalink, join Wi-Fi, or retry a command.
public struct NativeBodyValidationRequest: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable, Equatable, CaseIterable {
        case start
        case stop
        case format
    }

    public let operation: Operation
    public let execute: Bool
    public let format: CameraBodyRecordingFormatCommand?
    public let timeout: TimeInterval

    public init(operation: Operation, execute: Bool = false,
                format: CameraBodyRecordingFormatCommand? = nil,
                timeout: TimeInterval = 3) {
        self.operation = operation
        self.execute = execute
        self.format = format
        self.timeout = timeout
    }
}

/// Snapshot captured by the existing BLE/native session owner.  It is an
/// input to validation only: the service does not refresh or synthesize any
/// of these observations.
public struct NativeBodyValidationSnapshot: Codable, Sendable, Equatable {
    public let session: NativeCameraSessionStatus
    public let recordingBaseline: NativeBodyRecordingLifecycleSample?
    public let formatBaseline: NativeBodyFormatReadback?
    public let formatCapabilities: CameraVideoFormatCapabilities?
    public let nowUptime: TimeInterval

    public init(session: NativeCameraSessionStatus,
                recordingBaseline: NativeBodyRecordingLifecycleSample? = nil,
                formatBaseline: NativeBodyFormatReadback? = nil,
                formatCapabilities: CameraVideoFormatCapabilities? = nil,
                nowUptime: TimeInterval) {
        self.session = session
        self.recordingBaseline = recordingBaseline
        self.formatBaseline = formatBaseline
        self.formatCapabilities = formatCapabilities
        self.nowUptime = nowUptime
    }
}

public struct NativeBodyValidationRequestEvidence: Codable, Sendable, Equatable {
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

/// Evidence returned by one validation invocation.  `submissionCount` is
/// bounded by this service to zero or one; it is not a retry counter.
public struct NativeBodyValidationResult: Codable, Sendable, Equatable {
    public let operation: NativeBodyValidationRequest.Operation
    public let executeRequested: Bool
    public let request: NativeBodyValidationRequestEvidence
    public let submissionCount: Int
    public let recording: NativeBodyRecordingResult?
    public let format: NativeBodyFormatResult?
    public let failureCode: String?

    public var dryRun: Bool { !executeRequested }
    public var submitted: Bool { submissionCount == 1 }
    public var acknowledged: Bool {
        recording?.acknowledged == true || format?.acknowledged == true
    }
    public var observed: Bool {
        recording?.observed == true || format?.observed == true
    }
    public var completed: Bool {
        recording?.completed == true || format?.completed == true
    }
}

public enum NativeBodyValidationServiceError: Error, Equatable, Sendable {
    case formatRequired
    case recordingBaselineRequired
    case formatBaselineRequired
    case legalCapabilityRequired
    case invalidClock
    case invalidTimeout
}

/// Injectable command boundary used by developer validation.  Production
/// code can bind this to the existing Pocket3Datalink owner; tests can supply
/// a fake without opening a socket or touching hardware.
public struct NativeBodyValidationExecutorAdapter: Sendable {
    public typealias Execute = @Sendable (
        _ request: NativeCommandTransactionRequest,
        _ readiness: NativeCameraSessionStatus
    ) async throws -> NativeCommandTransactionResult

    private let body: Execute

    public init(_ body: @escaping Execute) {
        self.body = body
    }

    public func execute(_ request: NativeCommandTransactionRequest,
                        readiness: NativeCameraSessionStatus) async throws -> NativeCommandTransactionResult {
        try await body(request, readiness)
    }
}

/// Coordinates one body validation request without owning a transport.
///
/// The executor receives the exact request made by a coordinator and the
/// exact readiness snapshot used to build it.  The closure is called at most
/// once.  A transport owner can return cancellation, timeout, generation or
/// ACK-only evidence; the coordinator preserves that partial result and still
/// requires fresh terminal readback for completion.
public struct NativeBodyValidationService: Sendable {
    public static let defaultTimeout: TimeInterval = 3

    public typealias Executor = @Sendable (
        _ request: NativeCommandTransactionRequest,
        _ readiness: NativeCameraSessionStatus
    ) async throws -> NativeCommandTransactionResult

    private let executor: Executor?

    public init(executor: Executor? = nil) {
        self.executor = executor
    }

    public init(adapter: NativeBodyValidationExecutorAdapter?) {
        if let adapter {
            self.executor = { request, readiness in
                try await adapter.execute(request, readiness: readiness)
            }
        } else {
            self.executor = nil
        }
    }

    public func run(_ request: NativeBodyValidationRequest,
                    snapshot: NativeBodyValidationSnapshot) async throws -> NativeBodyValidationResult {
        guard snapshot.nowUptime.isFinite else {
            throw NativeBodyValidationServiceError.invalidClock
        }
        guard request.timeout.isFinite, request.timeout > 0,
              request.timeout <= NativeCommandTransactionRequest.maximumTimeout else {
            throw NativeBodyValidationServiceError.invalidTimeout
        }

        switch request.operation {
        case .start, .stop:
            guard let baseline = snapshot.recordingBaseline else {
                throw NativeBodyValidationServiceError.recordingBaselineRequired
            }
            var coordinator = try NativeBodyRecordingCoordinator(session: snapshot.session)
            let operation: NativeBodyRecordingOperation = request.operation == .start ? .start : .stop
            let nativeRequest = try coordinator.prepareRecord(operation,
                baseline: baseline, nowUptime: snapshot.nowUptime,
                timeout: request.timeout)
            return try await finish(request: request, nativeRequest: nativeRequest,
                                    readiness: snapshot.session, nowUptime: snapshot.nowUptime,
                                    recording: &coordinator)

        case .format:
            guard let target = request.format else {
                throw NativeBodyValidationServiceError.formatRequired
            }
            // A format operation always starts from a current parameter
            // readback and an independent legal capability table.  A caller
            // cannot use a capability table as a fake selected-format readback.
            guard let baseline = snapshot.formatBaseline else {
                throw NativeBodyValidationServiceError.formatBaselineRequired
            }
            guard let capabilities = snapshot.formatCapabilities else {
                throw NativeBodyValidationServiceError.legalCapabilityRequired
            }
            var coordinator = try NativeBodyFormatCoordinator(session: snapshot.session)
            let nativeRequest = try coordinator.prepare(target, baseline: baseline,
                capabilities: capabilities, nowUptime: snapshot.nowUptime,
                timeout: request.timeout)
            return try await finish(request: request, nativeRequest: nativeRequest,
                                    readiness: snapshot.session, nowUptime: snapshot.nowUptime,
                                    format: &coordinator)
        }
    }

    private func finish(request: NativeBodyValidationRequest,
                        nativeRequest: NativeCommandTransactionRequest,
                        readiness: NativeCameraSessionStatus,
                        nowUptime: TimeInterval,
                        recording coordinator: inout NativeBodyRecordingCoordinator) async throws -> NativeBodyValidationResult {
        guard request.execute else {
            return NativeBodyValidationResult(operation: request.operation,
                executeRequested: false, request: .init(nativeRequest), submissionCount: 0,
                recording: coordinator.result, format: nil, failureCode: nil)
        }
        guard let executor else {
            return NativeBodyValidationResult(operation: request.operation,
                executeRequested: true, request: .init(nativeRequest), submissionCount: 0,
                recording: coordinator.result, format: nil,
                failureCode: "native_body_executor_unavailable")
        }

        let transaction: NativeCommandTransactionResult
        do {
            // This is the sole executor call in the entire operation.  There
            // is intentionally no retry branch around it.
            transaction = try await executor(nativeRequest, readiness)
        } catch is CancellationError {
            var partial = NativeCommandTransactionResult(id: nativeRequest.id,
                command: nativeRequest.command, generation: nativeRequest.generation,
                sessionID: nativeRequest.sessionID, end: .cancelled)
            partial.failureCode = "cancelled"
            _ = coordinator.apply(partial, nowUptime: nil)
            return NativeBodyValidationResult(operation: request.operation,
                executeRequested: true, request: .init(nativeRequest), submissionCount: 0,
                recording: coordinator.result, format: nil, failureCode: "cancelled")
        } catch let error as NativeCommandTransactionError {
            var partial = NativeCommandTransactionResult(id: nativeRequest.id,
                command: nativeRequest.command, generation: nativeRequest.generation,
                sessionID: nativeRequest.sessionID, end: .failed)
            partial.end = error == .staleGeneration ? .generationChanged : .failed
            partial.failureCode = nativeBodyValidationFailureCode(error)
            _ = coordinator.apply(partial, nowUptime: nil)
            return NativeBodyValidationResult(operation: request.operation,
                executeRequested: true, request: .init(nativeRequest), submissionCount: 0,
                recording: coordinator.result, format: nil, failureCode: partial.failureCode)
        } catch {
            var partial = NativeCommandTransactionResult(id: nativeRequest.id,
                command: nativeRequest.command, generation: nativeRequest.generation,
                sessionID: nativeRequest.sessionID, end: .failed)
            if let error = error as? BridgeFailure, error.code == "cancelled" {
                partial.end = .cancelled
                partial.failureCode = "cancelled"
            } else {
                partial.failureCode = String(describing: error)
            }
            _ = coordinator.apply(partial, nowUptime: nil)
            return NativeBodyValidationResult(operation: request.operation,
                executeRequested: true, request: .init(nativeRequest), submissionCount: 0,
                recording: coordinator.result, format: nil, failureCode: partial.failureCode)
        }
        _ = coordinator.apply(transaction,
            nowUptime: observationClock(snapshot: nowUptime, transaction: transaction))
        return NativeBodyValidationResult(operation: request.operation,
            executeRequested: true, request: .init(nativeRequest),
            submissionCount: transaction.submitted ? 1 : 0,
            recording: coordinator.result, format: nil,
            failureCode: coordinator.failureCode)
    }

    private func finish(request: NativeBodyValidationRequest,
                        nativeRequest: NativeCommandTransactionRequest,
                        readiness: NativeCameraSessionStatus,
                        nowUptime: TimeInterval,
                        format coordinator: inout NativeBodyFormatCoordinator) async throws -> NativeBodyValidationResult {
        guard request.execute else {
            return NativeBodyValidationResult(operation: request.operation,
                executeRequested: false, request: .init(nativeRequest), submissionCount: 0,
                recording: nil, format: coordinator.result, failureCode: nil)
        }
        guard let executor else {
            return NativeBodyValidationResult(operation: request.operation,
                executeRequested: true, request: .init(nativeRequest), submissionCount: 0,
                recording: nil, format: coordinator.result,
                failureCode: "native_body_executor_unavailable")
        }

        let transaction: NativeCommandTransactionResult
        do {
            // See the recording overload: exactly one injected call, with no
            // retry or fallback transport.
            transaction = try await executor(nativeRequest, readiness)
        } catch is CancellationError {
            var partial = NativeCommandTransactionResult(id: nativeRequest.id,
                command: nativeRequest.command, generation: nativeRequest.generation,
                sessionID: nativeRequest.sessionID, end: .cancelled)
            partial.failureCode = "cancelled"
            _ = coordinator.apply(partial, nowUptime: nil)
            return NativeBodyValidationResult(operation: request.operation,
                executeRequested: true, request: .init(nativeRequest), submissionCount: 0,
                recording: nil, format: coordinator.result, failureCode: "cancelled")
        } catch let error as NativeCommandTransactionError {
            var partial = NativeCommandTransactionResult(id: nativeRequest.id,
                command: nativeRequest.command, generation: nativeRequest.generation,
                sessionID: nativeRequest.sessionID, end: .failed)
            partial.end = error == .staleGeneration ? .generationChanged : .failed
            partial.failureCode = nativeBodyValidationFailureCode(error)
            _ = coordinator.apply(partial, nowUptime: nil)
            return NativeBodyValidationResult(operation: request.operation,
                executeRequested: true, request: .init(nativeRequest), submissionCount: 0,
                recording: nil, format: coordinator.result, failureCode: partial.failureCode)
        } catch {
            var partial = NativeCommandTransactionResult(id: nativeRequest.id,
                command: nativeRequest.command, generation: nativeRequest.generation,
                sessionID: nativeRequest.sessionID, end: .failed)
            if let error = error as? BridgeFailure, error.code == "cancelled" {
                partial.end = .cancelled
                partial.failureCode = "cancelled"
            } else {
                partial.failureCode = String(describing: error)
            }
            _ = coordinator.apply(partial, nowUptime: nil)
            return NativeBodyValidationResult(operation: request.operation,
                executeRequested: true, request: .init(nativeRequest), submissionCount: 0,
                recording: nil, format: coordinator.result, failureCode: partial.failureCode)
        }
        _ = coordinator.apply(transaction,
            nowUptime: observationClock(snapshot: nowUptime, transaction: transaction))
        return NativeBodyValidationResult(operation: request.operation,
            executeRequested: true, request: .init(nativeRequest),
            submissionCount: transaction.submitted ? 1 : 0,
            recording: nil, format: coordinator.result,
            failureCode: coordinator.failureCode)
    }

    private func observationClock(snapshot: TimeInterval,
                                  transaction: NativeCommandTransactionResult) -> TimeInterval {
        max(snapshot, transaction.finishedUptime ?? transaction.observedUptime ?? snapshot)
    }

}

private func nativeBodyValidationFailureCode(_ error: NativeCommandTransactionError) -> String {
    switch error {
    case .invalidPayload: "native_command_invalid_payload"
    case .invalidTimeout: "native_command_invalid_timeout"
    case .commandNotReady: "native_command_not_ready"
    case .staleGeneration: "native_command_generation_changed"
    case .datalinkUnavailable: "native_datalink_unavailable"
    case .nativeBusy: "native_busy"
    }
}
