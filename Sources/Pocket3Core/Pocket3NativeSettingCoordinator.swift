import Foundation

/// One of the four native setting writes with a capture-confirmed matching
/// readback. The target carries only known values; unknown camera values stay
/// in `Pocket3NativeSettingReadback.raw` and cannot become a no-op.
public enum Pocket3NativeSettingTarget: Codable, Sendable, Equatable {
    case whiteBalance(CameraWhiteBalance)
    case focusMode(CameraFocusMode)
    case colorProfile(CameraColorProfile)
    case productShowcase(Pocket3ProductShowcaseMode)

    public var command: NativeCameraSessionCommand {
        switch self {
        case .whiteBalance: .whiteBalance
        case .focusMode: .focusMode
        case .colorProfile: .colorProfile
        case .productShowcase: .productShowcase
        }
    }

    public var property: CameraSettingsProperty? {
        switch self {
        case .whiteBalance, .colorProfile: .imageEffect
        case .focusMode: .lensState
        case .productShowcase: nil
        }
    }
}

/// Typed readback used by the native setting coordinators. The associated
/// structs retain their complete property bytes, including unknown enum
/// selectors. A malformed value can still be retained as `.unknown` evidence
/// but cannot confirm a requested setting.
public enum Pocket3NativeSettingReadback: Codable, Sendable, Equatable {
    case imageEffect(CameraImageEffectReadback)
    case lensState(CameraLensStateReadback)
    case productShowcase(Pocket3ProductShowcaseReadback)
    case unknown(property: CameraSettingsProperty, raw: Data)

    public var raw: Data {
        switch self {
        case .imageEffect(let value): value.raw
        case .lensState(let value): value.raw
        case .productShowcase(let value): value.raw
        case .unknown(_, let raw): raw
        }
    }

    public var property: CameraSettingsProperty? {
        switch self {
        case .imageEffect: .imageEffect
        case .lensState: .lensState
        case .productShowcase: nil
        case .unknown(let property, _): property
        }
    }

    public var imageEffect: CameraImageEffectReadback? {
        if case .imageEffect(let value) = self { return value }
        return nil
    }

    public var lensState: CameraLensStateReadback? {
        if case .lensState(let value) = self { return value }
        return nil
    }

    public var showcase: Pocket3ProductShowcaseReadback? {
        if case .productShowcase(let value) = self { return value }
        return nil
    }

    public var isUnknown: Bool {
        switch self {
        case .imageEffect(let value):
            value.colorProfile == nil || value.whiteBalance == nil
        case .lensState(let value):
            value.focusMode == nil
        case .productShowcase(let value):
            value.mode == nil
        case .unknown: true
        }
    }

    public var unknownRaw: Data? {
        isUnknown ? raw : nil
    }

    public static func decodeProperty(_ property: CameraSettingsProperty,
                                      raw: Data) -> Self {
        guard let decoded = CameraReadOnlyPropertyDecoder.decode(property, value: raw) else {
            return .unknown(property: property, raw: raw)
        }
        switch decoded {
        case .imageEffect(let value): return .imageEffect(value)
        case .lensState(let value): return .lensState(value)
        default: return .unknown(property: property, raw: raw)
        }
    }

    public func matches(_ target: Pocket3NativeSettingTarget) -> Bool {
        switch (target, self) {
        case let (.whiteBalance(expected), .imageEffect(value)):
            value.whiteBalance == expected
        case let (.focusMode(expected), .lensState(value)):
            value.focusMode == expected
        case let (.colorProfile(expected), .imageEffect(value)):
            value.colorProfile == expected
        case let (.productShowcase(expected), .productShowcase(value)):
            value.mode == expected
        default: false
        }
    }
}

/// A native readback with explicit UUID session and monotonically increasing
/// generation. This is the baseline and observation value used by the pure
/// setting coordinators; it is independent of BLE `CameraSettingsObservation`
/// storage and cannot be confused with a requested value.
public struct Pocket3NativeSettingObservation: Codable, Sendable, Equatable {
    public static let maximumAge: TimeInterval = 5
    public static let maximumRawBytes = 128

    public let sessionID: UUID
    public let generation: UInt64
    public let receivedUptime: TimeInterval
    public let readback: Pocket3NativeSettingReadback

    public init(sessionID: UUID, generation: UInt64,
                receivedUptime: TimeInterval,
                readback: Pocket3NativeSettingReadback) {
        self.sessionID = sessionID
        self.generation = generation
        self.receivedUptime = receivedUptime
        self.readback = readback
    }

    public init(sessionID: UUID, generation: UInt64,
                receivedUptime: TimeInterval,
                property: CameraSettingsProperty, raw: Data) {
        self.init(sessionID: sessionID, generation: generation,
                  receivedUptime: receivedUptime,
                  readback: .decodeProperty(property, raw: raw))
    }

    /// Bridges a complete existing named-property observation into the native
    /// generation ledger while retaining the exact raw typed value.
    public init(sessionID: UUID, generation: UInt64,
                observation: CameraSettingsObservation) {
        let readback: Pocket3NativeSettingReadback
        if let value = observation.readOnlyValue {
            switch value {
            case .imageEffect(let image): readback = .imageEffect(image)
            case .lensState(let lens): readback = .lensState(lens)
            default:
                readback = .unknown(property: observation.property, raw: value.raw)
            }
        } else {
            readback = .unknown(property: observation.property, raw: Data())
        }
        self.init(sessionID: sessionID, generation: generation,
                  receivedUptime: observation.receivedUptime, readback: readback)
    }

    public var raw: Data { readback.raw }
    public var property: CameraSettingsProperty? { readback.property }
    public var isUnknown: Bool { readback.isUnknown }

    public func isFresh(nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        generation != 0 && receivedUptime.isFinite && receivedUptime >= 0 &&
            nowUptime.isFinite && maximumAge.isFinite && maximumAge >= 0 &&
            nowUptime >= receivedUptime && nowUptime - receivedUptime <= maximumAge &&
            raw.count <= Self.maximumRawBytes
    }

    public func isFresh(session: NativeCameraSessionStatus,
                        nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        sessionID == session.sessionID && generation == session.generation &&
            session.state.satisfies(.commandReady) &&
            isFresh(nowUptime: nowUptime, maximumAge: maximumAge)
    }
}

public typealias Pocket3NativeSettingBaseline = Pocket3NativeSettingObservation
public typealias Pocket3NativeSettingReadbackObservation = Pocket3NativeSettingObservation

public enum Pocket3NativeSettingCoordinatorPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case idle
    case noOp
    case awaitingAcknowledgment
    case awaitingReadback
    case completed
    case timedOut
    case cancelled
    case generationChanged
    case failed
}

public enum Pocket3NativeSettingCoordinatorError: Error, Codable, Sendable, Equatable {
    case sessionNotReady
    case missingSessionIdentity
    case invalidBaseline
    case alreadyAtTarget
    case operationInFlight
    case staleTransaction
    case invalidClock
}

public struct Pocket3NativeSettingResult: Codable, Sendable, Equatable {
    public let target: Pocket3NativeSettingTarget
    public let sessionID: UUID
    public let generation: UInt64
    public let phase: Pocket3NativeSettingCoordinatorPhase
    public let baseline: Pocket3NativeSettingObservation
    public let transaction: NativeCommandTransactionResult?
    public let readback: Pocket3NativeSettingObservation?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let noOp: Bool
    public let failureCode: String?
}

/// Shared coordinator for WB `02/2C`, focus mode `02/24`, color `02/42`, and
/// Product Showcase `02/8E` PID `003B`. It creates at most one transaction
/// request. ACK is transport evidence only; completion requires a matching,
/// post-submission, fresh readback from this exact session/generation.
public struct Pocket3NativeSettingCoordinator: Sendable {
    public static let maximumReadbackAge: TimeInterval = 5
    public static let defaultTransactionTimeout: TimeInterval = 3

    public let sessionID: UUID
    public let generation: UInt64
    public private(set) var phase: Pocket3NativeSettingCoordinatorPhase = .idle
    public private(set) var target: Pocket3NativeSettingTarget?
    public private(set) var request: NativeCommandTransactionRequest?
    public private(set) var transaction: NativeCommandTransactionResult?
    public private(set) var readback: Pocket3NativeSettingObservation?
    public private(set) var failureCode: String?

    private var baseline: Pocket3NativeSettingObservation?
    private var readbackBeforeTransaction: Pocket3NativeSettingObservation?

    public init(session: NativeCameraSessionStatus) throws {
        guard session.generation != 0, session.state.satisfies(.commandReady) else {
            throw Pocket3NativeSettingCoordinatorError.sessionNotReady
        }
        guard let sessionID = session.sessionID else {
            throw Pocket3NativeSettingCoordinatorError.missingSessionIdentity
        }
        self.sessionID = sessionID
        generation = session.generation
    }

    /// Validates a fresh exact baseline and creates the one request. A known
    /// target already present in the baseline throws `alreadyAtTarget` and
    /// leaves a serializable `.noOp` result without producing a frame.
    public mutating func prepare(
        _ target: Pocket3NativeSettingTarget,
        baseline: Pocket3NativeSettingObservation,
        nowUptime: TimeInterval,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        guard phase == .idle else {
            throw Pocket3NativeSettingCoordinatorError.operationInFlight
        }
        guard baseline.sessionID == sessionID,
              baseline.generation == generation,
              baseline.isFresh(nowUptime: nowUptime,
                               maximumAge: Self.maximumReadbackAge),
              Self.baselineSupports(target, baseline: baseline) else {
            throw Pocket3NativeSettingCoordinatorError.invalidBaseline
        }

        self.target = target
        self.baseline = baseline
        transaction = nil
        readback = nil
        readbackBeforeTransaction = nil
        failureCode = nil

        if baseline.readback.matches(target) {
            phase = .noOp
            throw Pocket3NativeSettingCoordinatorError.alreadyAtTarget
        }

        let sessionID = self.sessionID
        let generation = self.generation
        let frame = try Pocket3NativeCommandAdapter.frame(for: target)
        let request = try NativeCommandTransactionRequest(
            command: target.command, generation: generation, sessionID: sessionID,
            frame: frame, timeout: timeout) { frame in
                Pocket3NativeSettingCoordinator.observationPayload(from: frame,
                                                                    target: target)
            }
        self.request = request
        phase = .awaitingAcknowledgment
        return request
    }

    public mutating func prepareWhiteBalance(
        _ value: CameraWhiteBalance,
        baseline: Pocket3NativeSettingObservation,
        nowUptime: TimeInterval,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        try prepare(.whiteBalance(value), baseline: baseline,
                    nowUptime: nowUptime, timeout: timeout)
    }

    public mutating func prepareFocusMode(
        _ value: CameraFocusMode,
        baseline: Pocket3NativeSettingObservation,
        nowUptime: TimeInterval,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        try prepare(.focusMode(value), baseline: baseline,
                    nowUptime: nowUptime, timeout: timeout)
    }

    public mutating func prepareColorProfile(
        _ value: CameraColorProfile,
        baseline: Pocket3NativeSettingObservation,
        nowUptime: TimeInterval,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        try prepare(.colorProfile(value), baseline: baseline,
                    nowUptime: nowUptime, timeout: timeout)
    }

    public mutating func prepareProductShowcase(
        _ value: Pocket3ProductShowcaseMode,
        baseline: Pocket3NativeSettingObservation,
        nowUptime: TimeInterval,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        try prepare(.productShowcase(value), baseline: baseline,
                    nowUptime: nowUptime, timeout: timeout)
    }

    /// Applies the one transaction result. A positive ACK without a matching
    /// readback remains pending and can never be reported as completed.
    @discardableResult
    public mutating func apply(_ transaction: NativeCommandTransactionResult,
                               nowUptime: TimeInterval? = nil) -> Bool {
        guard let request, let target, let baseline,
              request.id == transaction.id,
              transaction.generation == generation,
              transaction.sessionID == sessionID else {
            failureCode = "native_setting_stale_transaction"
            phase = .generationChanged
            return false
        }
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            if self.transaction == nil { self.transaction = transaction }
            return false
        }
        if let nowUptime, !nowUptime.isFinite {
            self.transaction = transaction
            failureCode = "native_setting_invalid_clock"
            phase = .failed
            return false
        }

        self.transaction = transaction
        if let observed = Self.decodeObserved(transaction.observedPayload,
                                              sessionID: sessionID,
                                              generation: generation,
                                              receivedUptime: transaction.observedUptime,
                                              target: target) {
            readback = observed
        }

        switch transaction.end {
        case .cancelled:
            failureCode = transaction.failureCode ?? "cancelled"
            phase = .cancelled
            return false
        case .generationChanged:
            failureCode = transaction.failureCode ?? "native_connection_changed"
            phase = .generationChanged
            return false
        case .timedOut:
            failureCode = transaction.failureCode ?? "native_setting_timeout"
            phase = .timedOut
            return false
        case .rejected, .failed:
            failureCode = transaction.failureCode ?? "native_setting_failed"
            phase = .failed
            return false
        case .acknowledged, .observed:
            guard transaction.acknowledged else {
                failureCode = transaction.failureCode ?? "native_setting_ack_invalid"
                phase = .failed
                return false
            }
        }

        phase = .awaitingReadback
        if let observed = readback {
            _ = observe(observed, nowUptime: nowUptime ?? observed.receivedUptime)
        } else if let readbackBeforeTransaction {
            _ = observe(readbackBeforeTransaction,
                        nowUptime: nowUptime ?? readbackBeforeTransaction.receivedUptime)
        }
        _ = baseline // Keep the exact baseline in the state machine scope.
        return phase == .completed
    }

    /// Accepts a readback arriving outside the transaction callback. It must
    /// be newer than the baseline and any submission, and it still needs the
    /// correlated successful ACK before completing.
    @discardableResult
    public mutating func observe(_ observation: Pocket3NativeSettingObservation,
                                 nowUptime: TimeInterval) -> Bool {
        guard let target, let baseline,
              observation.sessionID == sessionID,
              observation.generation == generation,
              observation.isFresh(nowUptime: nowUptime,
                                  maximumAge: Self.maximumReadbackAge),
              Self.baselineSupports(target, baseline: observation),
              observation.receivedUptime > baseline.receivedUptime,
              phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            return false
        }
        if let submitted = transaction?.submittedUptime,
           observation.receivedUptime <= submitted {
            return false
        }
        readback = observation
        guard let transaction else {
            readbackBeforeTransaction = observation
            return false
        }
        guard transaction.acknowledged else { return false }
        guard observation.readback.matches(target) else { return false }
        phase = .completed
        failureCode = nil
        return true
    }

    @discardableResult
    public mutating func cancel(generation callbackGeneration: UInt64) -> Bool {
        guard callbackGeneration == generation,
              phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            return false
        }
        phase = .cancelled
        failureCode = "cancelled"
        return true
    }

    public var result: Pocket3NativeSettingResult? {
        guard let target, let baseline else { return nil }
        return Pocket3NativeSettingResult(target: target, sessionID: sessionID,
            generation: generation, phase: phase, baseline: baseline,
            transaction: transaction, readback: readback, requested: true,
            submitted: transaction?.submitted == true,
            acknowledged: transaction?.acknowledged == true,
            observed: readback != nil, completed: phase == .completed,
            noOp: phase == .noOp, failureCode: failureCode)
    }

    private static func baselineSupports(_ target: Pocket3NativeSettingTarget,
                                         baseline: Pocket3NativeSettingObservation) -> Bool {
        switch target {
        case .whiteBalance, .colorProfile:
            guard case .imageEffect(let value) = baseline.readback,
                  let decoded = CameraReadOnlyPropertyDecoder.decode(
                    .imageEffect, value: value.raw),
                  case .imageEffect(let canonical) = decoded else { return false }
            return canonical == value
        case .focusMode:
            guard case .lensState(let value) = baseline.readback,
                  let decoded = CameraReadOnlyPropertyDecoder.decode(
                    .lensState, value: value.raw),
                  case .lensState(let canonical) = decoded else { return false }
            return canonical == value
        case .productShowcase:
            guard case .productShowcase(let value) = baseline.readback else { return false }
            return Pocket3ProductShowcaseReadback.decode(value.raw) == value
        }
    }

    fileprivate enum ObservationMarker {
        static let imageEffect: UInt8 = 0x01
        static let lensState: UInt8 = 0x02
        static let productShowcase: UInt8 = 0x03
    }

    fileprivate static func observationPayload(from frame: DUMLFrame,
                                               target: Pocket3NativeSettingTarget) -> Data? {
        switch target {
        case .whiteBalance, .colorProfile:
            guard frame.source == 0x28, frame.destination == 0x02,
                  frame.flags == 0, frame.commandSet == 0,
                  frame.commandID == 0x99,
                  let push = try? CameraPropertyCodec.decodePush(from: frame),
                  push.property == .imageEffect,
                  let decoded = CameraReadOnlyPropertyDecoder.decode(
                    .imageEffect, value: push.value),
                  case .imageEffect(let value) = decoded else { return nil }
            return Data([ObservationMarker.imageEffect]) + value.raw

        case .focusMode:
            guard frame.source == 0x28, frame.destination == 0x02,
                  frame.flags == 0, frame.commandSet == 0,
                  frame.commandID == 0x99,
                  let push = try? CameraPropertyCodec.decodePush(from: frame),
                  push.property == .lensState,
                  let decoded = CameraReadOnlyPropertyDecoder.decode(
                    .lensState, value: push.value),
                  case .lensState(let value) = decoded else { return nil }
            return Data([ObservationMarker.lensState]) + value.raw

        case .productShowcase:
            guard frame.source == 0x01, frame.destination == 0x02,
                  frame.flags == 0 || frame.flags == 0x80 || frame.flags == 0xC0,
                  frame.commandSet == Pocket3ProductShowcaseCommand.commandSet,
                  frame.commandID == Pocket3ProductShowcaseCommand.commandID,
                  let value = Pocket3ProductShowcaseReadback.decode(frame.payload) else {
                return nil
            }
            return Data([ObservationMarker.productShowcase]) + value.raw
        }
    }

    private static func decodeObserved(_ payload: Data?, sessionID: UUID,
                                       generation: UInt64,
                                       receivedUptime: TimeInterval?,
                                       target: Pocket3NativeSettingTarget)
        -> Pocket3NativeSettingObservation? {
        guard let payload, payload.count >= 2,
              payload.count <= DUMLCodec.maximumPayloadLength,
              let receivedUptime,
              receivedUptime.isFinite, receivedUptime >= 0 else { return nil }
        let raw = Data(payload.dropFirst())
        switch (payload[0], target) {
        case (ObservationMarker.imageEffect, .whiteBalance),
             (ObservationMarker.imageEffect, .colorProfile):
            guard let decoded = CameraReadOnlyPropertyDecoder.decode(
                .imageEffect, value: raw), case .imageEffect = decoded else { return nil }
            return Pocket3NativeSettingObservation(sessionID: sessionID,
                generation: generation, receivedUptime: receivedUptime,
                property: .imageEffect, raw: raw)
        case (ObservationMarker.lensState, .focusMode):
            guard let decoded = CameraReadOnlyPropertyDecoder.decode(
                .lensState, value: raw), case .lensState = decoded else { return nil }
            return Pocket3NativeSettingObservation(sessionID: sessionID,
                generation: generation, receivedUptime: receivedUptime,
                property: .lensState, raw: raw)
        case (ObservationMarker.productShowcase, .productShowcase):
            guard let value = Pocket3ProductShowcaseReadback.decode(raw) else { return nil }
            return Pocket3NativeSettingObservation(sessionID: sessionID,
                generation: generation, receivedUptime: receivedUptime,
                readback: .productShowcase(value))
        default:
            return nil
        }
    }
}

public typealias NativePocket3SettingCoordinator = Pocket3NativeSettingCoordinator
public typealias Pocket3NativeCameraSettingCoordinator = Pocket3NativeSettingCoordinator
public typealias Pocket3NativeWhiteBalanceCoordinator = Pocket3NativeSettingCoordinator
public typealias Pocket3NativeFocusModeCoordinator = Pocket3NativeSettingCoordinator
public typealias Pocket3NativeColorProfileCoordinator = Pocket3NativeSettingCoordinator
public typealias Pocket3NativeProductShowcaseCoordinator = Pocket3NativeSettingCoordinator

// MARK: - Native command adapters

public extension Pocket3NativeCommandAdapter {
    static func whiteBalance(_ value: CameraWhiteBalance,
                             generation: UInt64, sessionID: UUID? = nil,
                             timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        let command = try CameraSettingCommand(.whiteBalance(value))
        return try makeRequest(command: .whiteBalance,
            frame: NativeCommandFrame(frame: command.frame(sequence: 0)),
            generation: generation, sessionID: sessionID, timeout: timeout,
            observationTarget: .whiteBalance(value))
    }

    static func focusMode(_ value: CameraFocusMode,
                          generation: UInt64, sessionID: UUID? = nil,
                          timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        let command = try CameraSettingCommand(.focus(value))
        return try makeRequest(command: .focusMode,
            frame: NativeCommandFrame(frame: command.frame(sequence: 0)),
            generation: generation, sessionID: sessionID, timeout: timeout,
            observationTarget: .focusMode(value))
    }

    static func colorProfile(_ value: CameraColorProfile,
                             generation: UInt64, sessionID: UUID? = nil,
                             timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        let command = Pocket3ColorProfileCommand(value)
        return try makeRequest(command: .colorProfile,
            frame: NativeCommandFrame(frame: command.frame(sequence: 0)),
            generation: generation, sessionID: sessionID, timeout: timeout,
            observationTarget: .colorProfile(value))
    }

    static func productShowcase(_ command: Pocket3ProductShowcaseCommand,
                                generation: UInt64, sessionID: UUID? = nil,
                                timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        let target: Pocket3NativeSettingTarget = switch command {
        case .get: .productShowcase(.off)
        case .set(let value): .productShowcase(value)
        }
        return try makeRequest(command: .productShowcase,
            frame: NativeCommandFrame(frame: command.frame(sequence: 0)),
            generation: generation, sessionID: sessionID, timeout: timeout,
            observationTarget: target)
    }

    static func productShowcase(_ value: Pocket3ProductShowcaseMode,
                                generation: UInt64, sessionID: UUID? = nil,
                                timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        try productShowcase(.set(value), generation: generation,
                            sessionID: sessionID, timeout: timeout)
    }

    static func showcase(_ command: Pocket3ProductShowcaseCommand,
                         generation: UInt64, sessionID: UUID? = nil,
                         timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        try productShowcase(command, generation: generation,
                            sessionID: sessionID, timeout: timeout)
    }

    static func showcase(_ value: Pocket3ProductShowcaseMode,
                         generation: UInt64, sessionID: UUID? = nil,
                         timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        try productShowcase(.set(value), generation: generation,
                            sessionID: sessionID, timeout: timeout)
    }

    fileprivate static func frame(for target: Pocket3NativeSettingTarget)
        throws -> NativeCommandFrame {
        switch target {
        case .whiteBalance(let value):
            let command = try CameraSettingCommand(.whiteBalance(value))
            return NativeCommandFrame(frame: command.frame(sequence: 0))
        case .focusMode(let value):
            let command = try CameraSettingCommand(.focus(value))
            return NativeCommandFrame(frame: command.frame(sequence: 0))
        case .colorProfile(let value):
            return NativeCommandFrame(frame: Pocket3ColorProfileCommand(value)
                .frame(sequence: 0))
        case .productShowcase(let value):
            return NativeCommandFrame(frame: Pocket3ProductShowcaseCommand
                .set(value).frame(sequence: 0))
        }
    }

    private static func makeRequest(command: NativeCameraSessionCommand,
                                    frame: NativeCommandFrame,
                                    generation: UInt64, sessionID: UUID?,
                                    timeout: TimeInterval,
                                    observationTarget: Pocket3NativeSettingTarget? = nil)
        throws -> NativeCommandTransactionRequest {
        var observation: (@Sendable (DUMLFrame) -> Data?)?
        if let target = observationTarget {
            observation = { frame in
                Pocket3NativeSettingCoordinator.observationPayload(from: frame,
                                                                    target: target)
            }
        }
        return try NativeCommandTransactionRequest(command: command,
            generation: generation, sessionID: sessionID, frame: frame,
            timeout: timeout, observation: observation)
    }
}
