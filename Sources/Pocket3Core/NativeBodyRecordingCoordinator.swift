import Foundation

public enum NativeBodyRecordingOperation: String, Codable, Sendable, Equatable, CaseIterable {
    case start
    case stop

    public static let startRecording = Self.start
    public static let stopRecording = Self.stop

    var targetRecording: Bool { self == .start }
}

public enum NativeBodyRecordingCoordinatorPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case idle
    case awaitingAcknowledgment
    case awaitingReadback
    case completed
    case timedOut
    case cancelled
    case generationChanged
    case failed
}

public struct NativeBodyRecordingLifecycleSample: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let generation: UInt64
    public let receivedUptime: TimeInterval
    public let status: Pocket3BodyRecordingStatus

    public init(sessionID: UUID, generation: UInt64, receivedUptime: TimeInterval,
                status: Pocket3BodyRecordingStatus) {
        self.sessionID = sessionID; self.generation = generation
        self.receivedUptime = receivedUptime; self.status = status
    }

    public init(sessionID: UUID, generation: UInt64, receivedUptime: TimeInterval,
                statusByte: UInt8) {
        self.init(sessionID: sessionID, generation: generation,
                  receivedUptime: receivedUptime,
                  status: Pocket3BodyRecordingStatus(rawValue: statusByte))
    }

    public func isFresh(nowUptime: TimeInterval,
                        maximumAge: TimeInterval = 5) -> Bool {
        nowUptime.isFinite && receivedUptime.isFinite && maximumAge.isFinite
            && maximumAge >= 0 && nowUptime >= receivedUptime
            && nowUptime - receivedUptime <= maximumAge
    }
}

public struct NativeBodyRecordingResult: Codable, Sendable, Equatable {
    public let operation: NativeBodyRecordingOperation
    public let sessionID: UUID
    public let generation: UInt64
    public let phase: NativeBodyRecordingCoordinatorPhase
    public let transaction: NativeCommandTransactionResult?
    public let lifecycle: NativeBodyRecordingLifecycleSample?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let failureCode: String?
}

public enum NativeBodyRecordingCoordinatorError: Error, Equatable, Sendable {
    case sessionNotReady
    case missingSessionIdentity
    case invalidBaseline
    case alreadyAtTarget
    case operationInFlight
    case staleTransaction
    case staleObservation
    case invalidReadback
}

/// Pure coordinator for one body-recording start/stop transaction.
///
/// `NativeCommandTransaction` owns the one DUML send and ACK correlation. This
/// type owns the higher-level completion rule: only a fresh, same-session,
/// same-generation `02/80` sample in the requested terminal state completes
/// the operation. A transition sample (`0x41`/`0xC1`) is deliberately not a
/// completion, and ACK alone never flips the recording state.
public struct NativeBodyRecordingCoordinator: Sendable {
    public static let maximumReadbackAge: TimeInterval = 5
    public static let defaultTransactionTimeout: TimeInterval = 3

    public let sessionID: UUID
    public let generation: UInt64
    public private(set) var phase: NativeBodyRecordingCoordinatorPhase = .idle
    public private(set) var operation: NativeBodyRecordingOperation?
    public private(set) var request: NativeCommandTransactionRequest?
    public private(set) var transaction: NativeCommandTransactionResult?
    public private(set) var lifecycle: NativeBodyRecordingLifecycleSample?
    public private(set) var failureCode: String?

    private var baseline: NativeBodyRecordingLifecycleSample?
    private var observedBeforeTransaction: NativeBodyRecordingLifecycleSample?

    public init(session: NativeCameraSessionStatus) throws {
        guard session.generation != 0, session.state.satisfies(.commandReady) else {
            throw NativeBodyRecordingCoordinatorError.sessionNotReady
        }
        guard let sessionID = session.sessionID else {
            throw NativeBodyRecordingCoordinatorError.missingSessionIdentity
        }
        self.sessionID = sessionID; generation = session.generation
    }

    /// Prepares one 02/02 request from a fresh, known, non-transitioning
    /// baseline. No frame is sent by this method.
    public mutating func prepareRecord(_ operation: NativeBodyRecordingOperation,
                                       baseline: NativeBodyRecordingLifecycleSample,
                                       nowUptime: TimeInterval,
                                       timeout: TimeInterval = defaultTransactionTimeout) throws -> NativeCommandTransactionRequest {
        guard phase == .idle else { throw NativeBodyRecordingCoordinatorError.operationInFlight }
        try validateBaseline(baseline, nowUptime: nowUptime)
        guard baseline.status.recording != operation.targetRecording else {
            throw NativeBodyRecordingCoordinatorError.alreadyAtTarget
        }
        let frame = try NativeCommandFrame(source: 0x02, destination: 0x01,
            flags: 0x40, commandSet: 0x02, commandID: 0x02,
            payload: Data([operation.targetRecording ? 0x01 : 0x00]))
        let sessionID = self.sessionID, generation = self.generation,
            target = operation.targetRecording
        let request = try NativeCommandTransactionRequest(command: .record,
            generation: generation, sessionID: sessionID, frame: frame,
            timeout: timeout) { response in
                guard response.source == 0x01, response.destination == 0x02,
                      response.flags == 0, response.commandSet == 0x02,
                      response.commandID == 0x80,
                      let raw = response.payload.first else { return nil }
                let status = Pocket3BodyRecordingStatus(rawValue: raw)
                guard status.isKnown, !status.transitioning,
                      status.recording == target else { return nil }
                return Data([raw])
            }
        self.operation = operation; self.baseline = baseline
        self.request = request; transaction = nil; lifecycle = nil
        observedBeforeTransaction = nil; failureCode = nil
        phase = .awaitingAcknowledgment
        return request
    }

    /// Applies the result returned by the one-send transaction.  A positive
    /// ACK moves the coordinator to readback waiting unless a validated 02/80
    /// sample was already observed by the transaction.
    @discardableResult
    public mutating func apply(_ transaction: NativeCommandTransactionResult,
                               nowUptime: TimeInterval? = nil) -> Bool {
        guard let request, request.id == transaction.id,
              transaction.generation == generation,
              transaction.sessionID == sessionID else {
            failureCode = "native_record_stale_transaction"
            phase = .generationChanged
            return false
        }
        if ![.awaitingAcknowledgment, .awaitingReadback].contains(phase) {
            // A caller may cancel locally and still receive the transport's
            // final partial-evidence result. Preserve the terminal phase
            // instead of rewriting cancellation as a generation failure.
            if self.transaction == nil { self.transaction = transaction }
            return false
        }
        self.transaction = transaction
        if let nowUptime, !nowUptime.isFinite {
            failureCode = "native_record_invalid_clock"; phase = .failed; return false
        }
        switch transaction.end {
        case .cancelled:
            failureCode = transaction.failureCode ?? "cancelled"; phase = .cancelled; return false
        case .generationChanged:
            failureCode = transaction.failureCode ?? "native_connection_changed"
            phase = .generationChanged; return false
        case .timedOut:
            failureCode = transaction.failureCode ?? "native_record_timeout"
            phase = .timedOut
            if let observed = decodeLifecycle(from: transaction) { lifecycle = observed }
            return false
        case .rejected, .failed:
            failureCode = transaction.failureCode ?? "native_record_failed"
            phase = .failed; return false
        case .acknowledged, .observed:
            break
        }
        if transaction.acknowledged {
            phase = .awaitingReadback
        } else {
            failureCode = transaction.failureCode ?? "native_record_ack_invalid"
            phase = .failed; return false
        }
        if let observed = decodeLifecycle(from: transaction) {
            _ = observe(observed, nowUptime: nowUptime ?? observed.receivedUptime)
        } else if let observedBeforeTransaction {
            _ = observe(observedBeforeTransaction,
                        nowUptime: nowUptime ?? observedBeforeTransaction.receivedUptime)
        }
        return phase == .completed
    }

    /// Accepts a readback that arrived outside the transaction callback. It
    /// must belong to this exact session/generation, be fresh, follow the
    /// baseline and submitted timestamps, and be a known terminal state.
    @discardableResult
    public mutating func observe(_ sample: NativeBodyRecordingLifecycleSample,
                                 nowUptime: TimeInterval) -> Bool {
        guard let operation, let baseline else { return false }
        guard sample.sessionID == sessionID, sample.generation == generation,
              sample.status.isKnown, !sample.status.transitioning,
              sample.status.recording == operation.targetRecording,
              sample.isFresh(nowUptime: nowUptime,
                             maximumAge: Self.maximumReadbackAge),
              sample.receivedUptime > baseline.receivedUptime else { return false }
        if let submitted = transaction?.submittedUptime,
           sample.receivedUptime <= submitted { return false }
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            return false
        }
        if transaction == nil {
            observedBeforeTransaction = sample
            return false
        }
        guard transaction?.acknowledged == true else { return false }
        lifecycle = sample; phase = .completed; failureCode = nil
        return true
    }

    @discardableResult
    public mutating func cancel(generation callbackGeneration: UInt64) -> Bool {
        guard callbackGeneration == generation,
              phase == .awaitingAcknowledgment || phase == .awaitingReadback else { return false }
        phase = .cancelled; failureCode = "cancelled"; return true
    }

    public var result: NativeBodyRecordingResult? {
        guard let operation else { return nil }
        let transaction = self.transaction
        return NativeBodyRecordingResult(operation: operation, sessionID: sessionID,
            generation: generation, phase: phase, transaction: transaction,
            lifecycle: lifecycle, requested: true,
            submitted: transaction?.submitted == true,
            acknowledged: transaction?.acknowledged == true,
            observed: lifecycle != nil,
            completed: phase == .completed, failureCode: failureCode)
    }

    private func validateBaseline(_ baseline: NativeBodyRecordingLifecycleSample,
                                  nowUptime: TimeInterval) throws {
        guard baseline.sessionID == sessionID, baseline.generation == generation,
              baseline.status.isKnown, !baseline.status.transitioning,
              baseline.isFresh(nowUptime: nowUptime,
                               maximumAge: Self.maximumReadbackAge) else {
            throw NativeBodyRecordingCoordinatorError.invalidBaseline
        }
    }

    private func decodeLifecycle(from transaction: NativeCommandTransactionResult) -> NativeBodyRecordingLifecycleSample? {
        guard let payload = transaction.observedPayload,
              let raw = payload.first,
              let observedUptime = transaction.observedUptime else { return nil }
        return NativeBodyRecordingLifecycleSample(sessionID: sessionID,
            generation: generation, receivedUptime: observedUptime, statusByte: raw)
    }
}

public struct NativeBodyFormatReadback: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let generation: UInt64
    public let receivedUptime: TimeInterval
    public let parameters: CameraVideoParameters?
    public let capabilities: CameraVideoFormatCapabilities?

    public init(sessionID: UUID, generation: UInt64, receivedUptime: TimeInterval,
                parameters: CameraVideoParameters? = nil,
                capabilities: CameraVideoFormatCapabilities? = nil) {
        self.sessionID = sessionID; self.generation = generation
        self.receivedUptime = receivedUptime; self.parameters = parameters
        self.capabilities = capabilities
    }

    public func isFresh(nowUptime: TimeInterval,
                        maximumAge: TimeInterval = 5) -> Bool {
        nowUptime.isFinite && receivedUptime.isFinite && maximumAge.isFinite
            && maximumAge >= 0 && nowUptime >= receivedUptime
            && nowUptime - receivedUptime <= maximumAge
    }

    public func matches(_ command: CameraBodyRecordingFormatCommand) -> Bool {
        let parameterMatches = parameters.map {
            $0.resolutionRaw == command.resolution.rawValue
                && $0.frameRateRaw == command.frameRate.rawValue
        } ?? false
        let capabilityMatches = capabilities?.contains(
            resolution: command.resolution, frameRate: command.frameRate) == true
        return parameterMatches || capabilityMatches
    }

    /// A capability table proves that a pair is legal; only the selected
    /// `cam_video_param_v2` readback proves that the SET took effect.
    public func confirms(_ command: CameraBodyRecordingFormatCommand) -> Bool {
        parameters?.resolutionRaw == command.resolution.rawValue
            && parameters?.frameRateRaw == command.frameRate.rawValue
    }
}

public enum NativeBodyFormatCoordinatorPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case idle
    case awaitingAcknowledgment
    case awaitingReadback
    case completed
    case timedOut
    case cancelled
    case generationChanged
    case failed
}

public struct NativeBodyFormatResult: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let generation: UInt64
    public let phase: NativeBodyFormatCoordinatorPhase
    public let target: CameraBodyRecordingFormatCommand
    public let transaction: NativeCommandTransactionResult?
    public let readback: NativeBodyFormatReadback?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let failureCode: String?
}

public enum NativeBodyFormatCoordinatorError: Error, Equatable, Sendable {
    case sessionNotReady
    case missingSessionIdentity
    case invalidBaseline
    case missingCapabilityEvidence
    case unsupportedFormat
    case alreadyAtTarget
    case operationInFlight
}

/// Pure coordinator for the body-format `02/18` candidate.
///
/// ACK is only transport evidence. Completion requires a later, same-session
/// and same-generation `cam_video_param_v2` readback that matches the selected
/// resolution and frame rate. A `camcap_video_format` table can prove that the
/// pair is legal, but it never proves that the SET took effect. No requested
/// value is copied into readback state.
public struct NativeBodyFormatCoordinator: Sendable {
    public static let maximumReadbackAge: TimeInterval = 5
    public static let defaultTransactionTimeout: TimeInterval = 3

    public let sessionID: UUID
    public let generation: UInt64
    public private(set) var phase: NativeBodyFormatCoordinatorPhase = .idle
    public private(set) var request: NativeCommandTransactionRequest?
    public private(set) var transaction: NativeCommandTransactionResult?
    public private(set) var readback: NativeBodyFormatReadback?
    public private(set) var failureCode: String?

    private var target: CameraBodyRecordingFormatCommand?
    private var baseline: NativeBodyFormatReadback?
    private var readbackBeforeTransaction: NativeBodyFormatReadback?

    public init(session: NativeCameraSessionStatus) throws {
        guard session.generation != 0, session.state.satisfies(.commandReady) else {
            throw NativeBodyFormatCoordinatorError.sessionNotReady
        }
        guard let sessionID = session.sessionID else {
            throw NativeBodyFormatCoordinatorError.missingSessionIdentity
        }
        self.sessionID = sessionID; generation = session.generation
    }

    public mutating func prepare(
        _ command: CameraBodyRecordingFormatCommand,
        baseline: NativeBodyFormatReadback?,
        capabilities: CameraVideoFormatCapabilities? = nil,
        nowUptime: TimeInterval,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        guard phase == .idle else { throw NativeBodyFormatCoordinatorError.operationInFlight }
        guard baseline != nil || capabilities != nil else {
            throw NativeBodyFormatCoordinatorError.missingCapabilityEvidence
        }
        if let baseline {
            guard baseline.sessionID == sessionID, baseline.generation == generation,
                  baseline.parameters != nil || baseline.capabilities != nil,
                  baseline.isFresh(nowUptime: nowUptime, maximumAge: Self.maximumReadbackAge) else {
                throw NativeBodyFormatCoordinatorError.invalidBaseline
            }
            guard !baseline.confirms(command) else {
                throw NativeBodyFormatCoordinatorError.alreadyAtTarget
            }
        }
        if let capabilities,
           !capabilities.contains(resolution: command.resolution, frameRate: command.frameRate) {
            throw NativeBodyFormatCoordinatorError.unsupportedFormat
        }
        let base = try Pocket3NativeCommandAdapter.bodyRecordingFormatCandidate(
            command, generation: generation, sessionID: sessionID, timeout: timeout)
        let target = command, sessionID = self.sessionID, generation = self.generation
        let request = try NativeCommandTransactionRequest(id: base.id, command: .bodyFormat,
            generation: generation, sessionID: sessionID, frame: base.frame,
            responseMatcher: base.responseMatcher, timeout: timeout) { frame in
                NativeBodyFormatCoordinator.observationPayload(
                    from: frame, target: target)
            }
        self.target = command; self.baseline = baseline; self.request = request
        transaction = nil; readback = nil; readbackBeforeTransaction = nil
        failureCode = nil; phase = .awaitingAcknowledgment
        return request
    }

    @discardableResult
    public mutating func apply(_ transaction: NativeCommandTransactionResult,
                               nowUptime: TimeInterval? = nil) -> Bool {
        guard let request, request.id == transaction.id,
              transaction.generation == generation,
              transaction.sessionID == sessionID else {
            failureCode = "native_format_stale_transaction"
            phase = .generationChanged
            return false
        }
        if ![.awaitingAcknowledgment, .awaitingReadback].contains(phase) {
            if self.transaction == nil { self.transaction = transaction }
            return false
        }
        self.transaction = transaction
        if let nowUptime, !nowUptime.isFinite {
            failureCode = "native_format_invalid_clock"; phase = .failed; return false
        }
        switch transaction.end {
        case .cancelled:
            failureCode = transaction.failureCode ?? "cancelled"; phase = .cancelled; return false
        case .generationChanged:
            failureCode = transaction.failureCode ?? "native_connection_changed"
            phase = .generationChanged; return false
        case .timedOut:
            failureCode = transaction.failureCode ?? "native_format_timeout"
            phase = .timedOut
            if let observed = decodeReadback(from: transaction) { readback = observed }
            return false
        case .rejected, .failed:
            failureCode = transaction.failureCode ?? "native_format_failed"
            phase = .failed; return false
        case .acknowledged, .observed:
            break
        }
        guard transaction.acknowledged else {
            failureCode = transaction.failureCode ?? "native_format_ack_invalid"
            phase = .failed; return false
        }
        phase = .awaitingReadback
        if let observed = decodeReadback(from: transaction) {
            _ = observe(observed, nowUptime: nowUptime ?? observed.receivedUptime)
        } else if let readbackBeforeTransaction {
            _ = observe(readbackBeforeTransaction,
                        nowUptime: nowUptime ?? readbackBeforeTransaction.receivedUptime)
        }
        return phase == .completed
    }

    @discardableResult
    public mutating func observe(_ value: NativeBodyFormatReadback,
                                 nowUptime: TimeInterval) -> Bool {
        guard let target, let baseline else { return false }
        guard value.sessionID == sessionID, value.generation == generation,
              value.parameters != nil || value.capabilities != nil,
              value.confirms(target),
              value.isFresh(nowUptime: nowUptime,
                            maximumAge: Self.maximumReadbackAge),
              value.receivedUptime > baseline.receivedUptime else { return false }
        if let submitted = transaction?.submittedUptime,
           value.receivedUptime <= submitted { return false }
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            return false
        }
        if transaction == nil {
            readbackBeforeTransaction = value; return false
        }
        guard transaction?.acknowledged == true else { return false }
        readback = value; phase = .completed; failureCode = nil
        return true
    }

    @discardableResult
    public mutating func cancel(generation callbackGeneration: UInt64) -> Bool {
        guard callbackGeneration == generation,
              phase == .awaitingAcknowledgment || phase == .awaitingReadback else { return false }
        phase = .cancelled; failureCode = "cancelled"; return true
    }

    public var result: NativeBodyFormatResult? {
        guard let target else { return nil }
        return NativeBodyFormatResult(sessionID: sessionID, generation: generation,
            phase: phase, target: target, transaction: transaction, readback: readback,
            requested: true, submitted: transaction?.submitted == true,
            acknowledged: transaction?.acknowledged == true, observed: readback != nil,
            completed: phase == .completed, failureCode: failureCode)
    }

    private func decodeReadback(from transaction: NativeCommandTransactionResult) -> NativeBodyFormatReadback? {
        guard let payload = transaction.observedPayload, let marker = payload.first,
              let observedUptime = transaction.observedUptime,
              let target else { return nil }
        let raw = Data(payload.dropFirst())
        switch marker {
        case 1:
            guard let value = CameraReadOnlyPropertyDecoder.decode(.videoParameters, value: raw),
                  case .videoParameters(let parameters) = value else { return nil }
            return NativeBodyFormatReadback(sessionID: sessionID, generation: generation,
                receivedUptime: observedUptime, parameters: parameters)
        case 2:
            guard let capabilities = CameraVideoFormatCapabilityDecoder.decode(raw),
                  capabilities.contains(resolution: target.resolution, frameRate: target.frameRate) else { return nil }
            return NativeBodyFormatReadback(sessionID: sessionID, generation: generation,
                receivedUptime: observedUptime, capabilities: capabilities)
        default:
            return nil
        }
    }

    private static func observationPayload(from frame: DUMLFrame,
                                           target: CameraBodyRecordingFormatCommand) -> Data? {
        guard frame.source == 0x28, frame.destination == 0x02, frame.flags == 0,
              frame.commandSet == 0x00, frame.commandID == 0x99,
              let push = try? CameraPropertyCodec.decodePush(from: frame) else { return nil }
        switch push.property {
        case .videoParameters:
            guard let value = CameraReadOnlyPropertyDecoder.decode(push.property, value: push.value),
                  case .videoParameters(let parameters) = value,
                  parameters.resolutionRaw == target.resolution.rawValue,
                  parameters.frameRateRaw == target.frameRate.rawValue else { return nil }
            return Data([1]) + parameters.raw
        case .videoFormatCapabilities:
            guard let capabilities = CameraVideoFormatCapabilityDecoder.decode(push.value),
                  capabilities.contains(resolution: target.resolution, frameRate: target.frameRate) else { return nil }
            return Data([2]) + capabilities.raw
        default:
            return nil
        }
    }
}
