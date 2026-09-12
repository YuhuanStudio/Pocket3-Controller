import Foundation

// MARK: - Native zoom (`02/B8`)

/// Body-format zoom limits confirmed by the protocol source. These limits are
/// raw slider positions, not optical magnification values.
public enum Pocket3NativeZoomFormat: String, Codable, Sendable, Equatable, CaseIterable {
    case fourK
    case twoPointSevenK
    case fullHD

    public var maximumMultiplier: Double {
        switch self {
        case .fourK: 2
        case .twoPointSevenK: 3
        case .fullHD: 4
        }
    }

    public var minimumRawPosition: UInt16 { Pocket3NativeZoomCommand.minimumLensPosition }
    public var maximumRawPosition: UInt16 {
        switch self {
        case .fourK: 200
        case .twoPointSevenK: 300
        case .fullHD: 400
        }
    }

    public func acceptsAbsolute(_ position: UInt16) -> Bool {
        (minimumRawPosition...maximumRawPosition).contains(position)
    }

    public init(resolution: CameraVideoResolution) {
        switch resolution {
        case .p4K, .square2160:
            self = .fourK
        case .p2_7K, .square3K, .portrait2_7K, .portrait3K:
            self = .twoPointSevenK
        case .p1080, .square1080, .portrait1080:
            self = .fullHD
        }
    }

    public static func forResolution(_ resolution: CameraVideoResolution) -> Self {
        Self(resolution: resolution)
    }
}

public typealias Pocket3NativeZoomCapability = Pocket3NativeZoomFormat

/// Complete bounded lens readback used by native zoom. The focus selector and
/// all bytes remain available; offset 14 is only named as a candidate raw
/// zoom position because no optical multiplier or moving-bit mapping is
/// established here.
public struct Pocket3NativeLensStateReadback: Codable, Sendable, Equatable {
    public static let zoomPositionOffset = 14
    public static let minimumZoomReadbackBytes = zoomPositionOffset + 2

    public let raw: Data
    public let focusModeRaw: UInt8?
    public let focusMode: CameraFocusMode?
    public let zoomPositionRaw: UInt16?
    /// Optional caller-supplied motion classification. It is not inferred
    /// from an unverified byte offset.
    public let movingRaw: UInt8?
    public let moving: Bool?

    public init(raw: Data, focusModeRaw: UInt8? = nil,
                zoomPositionRaw: UInt16? = nil, movingRaw: UInt8? = nil,
                moving: Bool? = nil) {
        self.raw = raw
        let focusRaw = focusModeRaw ?? raw.first
        self.focusModeRaw = focusRaw
        self.focusMode = Self.decodeFocusMode(focusRaw)
        if let zoomPositionRaw {
            self.zoomPositionRaw = zoomPositionRaw
        } else if raw.count >= Self.minimumZoomReadbackBytes {
            self.zoomPositionRaw = UInt16(raw[Self.zoomPositionOffset])
                | UInt16(raw[Self.zoomPositionOffset + 1]) << 8
        } else {
            self.zoomPositionRaw = nil
        }
        self.movingRaw = movingRaw
        self.moving = moving
    }

    public static func decode(_ raw: Data, movingRaw: UInt8? = nil,
                              moving: Bool? = nil) -> Self? {
        guard !raw.isEmpty, raw.count <= DUMLCodec.maximumPayloadLength else { return nil }
        return Self(raw: raw, movingRaw: movingRaw, moving: moving)
    }

    public static func parse(_ raw: Data) -> Self? { decode(raw) }

    private static func decodeFocusMode(_ raw: UInt8?) -> CameraFocusMode? {
        switch raw {
        case 0xB1: .single
        case 0xB2: .continuous
        default: nil
        }
    }
}

public struct Pocket3NativeLensStateObservation: Codable, Sendable, Equatable {
    public static let maximumAge: TimeInterval = 5
    public static let maximumRawBytes = 128

    public let sessionID: UUID
    public let generation: UInt64
    public let receivedUptime: TimeInterval
    public let readback: Pocket3NativeLensStateReadback

    public init(sessionID: UUID, generation: UInt64, receivedUptime: TimeInterval,
                readback: Pocket3NativeLensStateReadback) {
        self.sessionID = sessionID
        self.generation = generation
        self.receivedUptime = receivedUptime
        self.readback = readback
    }

    public init(sessionID: UUID, generation: UInt64, receivedUptime: TimeInterval,
                raw: Data, movingRaw: UInt8? = nil, moving: Bool? = nil) {
        self.init(sessionID: sessionID, generation: generation,
                  receivedUptime: receivedUptime,
                  readback: Pocket3NativeLensStateReadback(raw: raw,
                      movingRaw: movingRaw, moving: moving))
    }

    public init?(sessionID: UUID, generation: UInt64,
                observation: CameraSettingsObservation,
                movingRaw: UInt8? = nil, moving: Bool? = nil) {
        guard observation.property == .lensState,
              case .lensState(let value) = observation.readOnlyValue else { return nil }
        self.init(sessionID: sessionID, generation: generation,
                  receivedUptime: observation.receivedUptime, raw: value.raw,
                  movingRaw: movingRaw, moving: moving)
    }

    public var raw: Data { readback.raw }
    public var zoomPositionRaw: UInt16? { readback.zoomPositionRaw }
    public var zoomPosition: UInt16? { zoomPositionRaw }
    public var moving: Bool? { readback.moving }

    public func isFresh(nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        generation != 0 && raw.count <= Self.maximumRawBytes &&
            receivedUptime.isFinite && receivedUptime >= 0 &&
            nowUptime.isFinite && maximumAge.isFinite && maximumAge >= 0 &&
            nowUptime >= receivedUptime && nowUptime - receivedUptime <= maximumAge
    }

    public func isFresh(session: NativeCameraSessionStatus,
                        nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        sessionID == session.sessionID && generation == session.generation &&
            session.state.satisfies(.commandReady) &&
            isFresh(nowUptime: nowUptime, maximumAge: maximumAge)
    }
}

public typealias Pocket3NativeZoomReadback = Pocket3NativeLensStateReadback
public typealias Pocket3NativeZoomBaseline = Pocket3NativeLensStateObservation
public typealias Pocket3NativeZoomObservation = Pocket3NativeLensStateObservation

public enum Pocket3NativeZoomCoordinatorPhase: String, Codable, Sendable, Equatable, CaseIterable {
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

public enum Pocket3NativeZoomCoordinatorError: Error, Codable, Sendable, Equatable {
    case sessionNotReady
    case missingSessionIdentity
    case invalidBaseline
    case invalidFormat
    case invalidAction
    case alreadyAtTarget
    case operationInFlight
    case staleTransaction
    case invalidClock
}

public struct Pocket3NativeZoomResult: Codable, Sendable, Equatable {
    public let action: Pocket3NativeZoomPayload
    public let format: Pocket3NativeZoomFormat
    public let sessionID: UUID
    public let generation: UInt64
    public let phase: Pocket3NativeZoomCoordinatorPhase
    public let baseline: Pocket3NativeLensStateObservation
    public let transaction: NativeCommandTransactionResult?
    public let readback: Pocket3NativeLensStateObservation?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let noOp: Bool
    public let stopRequestedWhileMoving: Bool
    public let failureCode: String?
}

/// Native `02/B8` coordinator. It bounds absolute targets by the current
/// body format, requires fresh same-generation lens readback, and never
/// treats a transport ACK as zoom completion. Relative slew is retained as a
/// bounded action but has no invented direction or optical-ratio semantics.
public struct Pocket3NativeZoomCoordinator: Sendable {
    public static let maximumReadbackAge: TimeInterval = 5
    public static let defaultTransactionTimeout: TimeInterval = 3

    public let sessionID: UUID
    public let generation: UInt64
    public private(set) var phase: Pocket3NativeZoomCoordinatorPhase = .idle
    public private(set) var action: Pocket3NativeZoomPayload?
    public private(set) var format: Pocket3NativeZoomFormat?
    public private(set) var request: NativeCommandTransactionRequest?
    public private(set) var transaction: NativeCommandTransactionResult?
    public private(set) var readback: Pocket3NativeLensStateObservation?
    public private(set) var failureCode: String?

    private var baseline: Pocket3NativeLensStateObservation?
    private var readbackBeforeTransaction: Pocket3NativeLensStateObservation?

    public init(session: NativeCameraSessionStatus) throws {
        guard session.generation != 0, session.state.satisfies(.commandReady) else {
            throw Pocket3NativeZoomCoordinatorError.sessionNotReady
        }
        guard let sessionID = session.sessionID else {
            throw Pocket3NativeZoomCoordinatorError.missingSessionIdentity
        }
        self.sessionID = sessionID
        generation = session.generation
    }

    public mutating func prepare(
        _ action: Pocket3NativeZoomPayload,
        format: Pocket3NativeZoomFormat,
        baseline: Pocket3NativeLensStateObservation,
        nowUptime: TimeInterval,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        guard phase == .idle else {
            throw Pocket3NativeZoomCoordinatorError.operationInFlight
        }
        guard baseline.sessionID == sessionID,
              baseline.generation == generation,
              baseline.isFresh(nowUptime: nowUptime,
                               maximumAge: Self.maximumReadbackAge),
              Self.baselineSupports(baseline) else {
            throw Pocket3NativeZoomCoordinatorError.invalidBaseline
        }
        guard Self.valid(action: action, format: format) else {
            throw Self.invalidActionError(action: action, format: format)
        }

        self.action = action
        self.format = format
        self.baseline = baseline
        transaction = nil
        readback = nil
        readbackBeforeTransaction = nil
        failureCode = nil

        if Self.isNoOp(action: action, baseline: baseline) {
            phase = .noOp
            throw Pocket3NativeZoomCoordinatorError.alreadyAtTarget
        }

        let frame = try Self.frame(for: action)
        let sessionID = self.sessionID
        let generation = self.generation
        let request = try NativeCommandTransactionRequest(
            command: .zoom, generation: generation, sessionID: sessionID,
            frame: frame, timeout: timeout) { frame in
                Pocket3NativeZoomCoordinator.observationPayload(from: frame)
            }
        self.request = request
        phase = .awaitingAcknowledgment
        return request
    }

    public mutating func prepare(
        _ command: Pocket3NativeZoomCommand,
        format: Pocket3NativeZoomFormat,
        baseline: Pocket3NativeLensStateObservation,
        nowUptime: TimeInterval,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        try prepare(command.action, format: format, baseline: baseline,
                    nowUptime: nowUptime, timeout: timeout)
    }

    @discardableResult
    public mutating func apply(_ transaction: NativeCommandTransactionResult,
                               nowUptime: TimeInterval? = nil) -> Bool {
        guard let request, let action, let baseline,
              request.id == transaction.id,
              transaction.generation == generation,
              transaction.sessionID == sessionID else {
            failureCode = "native_zoom_stale_transaction"
            phase = .generationChanged
            return false
        }
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            if self.transaction == nil { self.transaction = transaction }
            return false
        }
        if let nowUptime, !nowUptime.isFinite {
            self.transaction = transaction
            failureCode = "native_zoom_invalid_clock"
            phase = .failed
            return false
        }
        self.transaction = transaction
        if let observed = Self.decodeObserved(transaction.observedPayload,
                                              sessionID: sessionID,
                                              generation: generation,
                                              receivedUptime: transaction.observedUptime) {
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
            failureCode = transaction.failureCode ?? "native_zoom_timeout"
            phase = .timedOut
            return false
        case .rejected, .failed:
            failureCode = transaction.failureCode ?? "native_zoom_failed"
            phase = .failed
            return false
        case .acknowledged, .observed:
            guard transaction.acknowledged else {
                failureCode = transaction.failureCode ?? "native_zoom_ack_invalid"
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
        _ = action; _ = baseline
        return phase == .completed
    }

    @discardableResult
    public mutating func observe(_ observation: Pocket3NativeLensStateObservation,
                                 nowUptime: TimeInterval) -> Bool {
        guard let action, let baseline,
              observation.sessionID == sessionID,
              observation.generation == generation,
              observation.isFresh(nowUptime: nowUptime,
                                  maximumAge: Self.maximumReadbackAge),
              Self.baselineSupports(observation),
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
        guard transaction.acknowledged,
              Self.matches(action: action, baseline: baseline,
                           observation: observation) else { return false }
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

    /// Leaves a dry-run or unavailable-executor attempt with explicit partial
    /// evidence. It never creates a request or submits a frame.
    @discardableResult
    public mutating func blockExecution(reason: String) -> Bool {
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            return false
        }
        phase = .failed
        failureCode = String(reason.prefix(128))
        return true
    }

    public var result: Pocket3NativeZoomResult? {
        guard let action, let format, let baseline else { return nil }
        return Pocket3NativeZoomResult(action: action, format: format,
            sessionID: sessionID, generation: generation, phase: phase,
            baseline: baseline, transaction: transaction, readback: readback,
            requested: true, submitted: transaction?.submitted == true,
            acknowledged: transaction?.acknowledged == true,
            observed: readback != nil, completed: phase == .completed,
            noOp: phase == .noOp,
            stopRequestedWhileMoving: action == .stop && baseline.readback.moving == true,
            failureCode: failureCode)
    }

    private static func baselineSupports(_ observation: Pocket3NativeLensStateObservation) -> Bool {
        guard observation.zoomPositionRaw != nil,
              observation.raw.count >= Pocket3NativeLensStateReadback.minimumZoomReadbackBytes,
              let canonical = Pocket3NativeLensStateReadback.decode(observation.raw) else {
            return false
        }
        return canonical.raw == observation.raw
    }

    private static func valid(action: Pocket3NativeZoomPayload,
                              format: Pocket3NativeZoomFormat) -> Bool {
        switch action {
        case .absoluteLens(let position):
            return format.acceptsAbsolute(position)
        case .relativeSlew(let value):
            return value <= Pocket3NativeZoomCommand.maximumSlewValue
        case .stop:
            return true
        case .unknown:
            return false
        }
    }

    private static func invalidActionError(action: Pocket3NativeZoomPayload,
                                           format: Pocket3NativeZoomFormat)
        -> Pocket3NativeZoomCoordinatorError {
        switch action {
        case .absoluteLens:
            return format.acceptsAbsolute(0)
                ? .invalidAction : .invalidFormat
        case .relativeSlew, .stop, .unknown:
            return .invalidAction
        }
    }

    private static func isNoOp(action: Pocket3NativeZoomPayload,
                               baseline: Pocket3NativeLensStateObservation) -> Bool {
        switch action {
        case .absoluteLens(let position):
            return baseline.zoomPositionRaw == position
        case .relativeSlew(let value):
            return value == 0
        case .stop:
            return baseline.readback.moving == false
        case .unknown:
            return false
        }
    }

    fileprivate static func frame(for action: Pocket3NativeZoomPayload)
        throws -> NativeCommandFrame {
        let command: Pocket3NativeZoomCommand
        switch action {
        case .absoluteLens(let position):
            command = try Pocket3NativeZoomCommand(absoluteLens: position)
        case .relativeSlew(let value):
            command = try Pocket3NativeZoomCommand(relativeSlew: value)
        case .stop:
            command = .stop
        case .unknown:
            throw Pocket3NativeZoomCoordinatorError.invalidAction
        }
        return NativeCommandFrame(frame: command.frame(sequence: 0))
    }

    private static func matches(action: Pocket3NativeZoomPayload,
                                baseline: Pocket3NativeLensStateObservation,
                                observation: Pocket3NativeLensStateObservation) -> Bool {
        switch action {
        case .absoluteLens(let position):
            return observation.zoomPositionRaw == position
        case .relativeSlew:
            // Relative slew has no confirmed direction or final raw target;
            // the required evidence is a fresh complete lens state after the
            // one request, while preserving the exact position bytes.
            return observation.zoomPositionRaw != nil
        case .stop:
            if baseline.readback.moving == true {
                return observation.readback.moving == false
            }
            return observation.readback.moving != true
        case .unknown:
            return false
        }
    }

    private enum ObservationMarker { static let lensState: UInt8 = 0x71 }

    fileprivate static func observationPayload(from frame: DUMLFrame) -> Data? {
        guard frame.source == 0x28, frame.destination == 0x02,
              frame.flags == 0, frame.commandSet == 0,
              frame.commandID == 0x99,
              let push = try? CameraPropertyCodec.decodePush(from: frame),
              push.property == .lensState,
              let value = Pocket3NativeLensStateReadback.decode(push.value) else {
            return nil
        }
        return Data([ObservationMarker.lensState]) + value.raw
    }

    private static func decodeObserved(_ payload: Data?, sessionID: UUID,
                                       generation: UInt64,
                                       receivedUptime: TimeInterval?)
        -> Pocket3NativeLensStateObservation? {
        guard let payload, payload.count >= 2,
              payload.count <= DUMLCodec.maximumPayloadLength,
              payload[0] == ObservationMarker.lensState,
              let receivedUptime,
              let value = Pocket3NativeLensStateReadback.decode(
                Data(payload.dropFirst())) else { return nil }
        return Pocket3NativeLensStateObservation(sessionID: sessionID,
            generation: generation, receivedUptime: receivedUptime, readback: value)
    }
}

public typealias NativePocket3ZoomCoordinator = Pocket3NativeZoomCoordinator

// MARK: - Native gimbal parameters (`04/50`)

public enum Pocket3NativeGimbalTarget: Codable, Sendable, Equatable {
    case mode(Pocket3GimbalMode)
    case speed(Pocket3GimbalSpeed)

    public var command: NativeCameraSessionCommand { .gimbal }
}

public struct Pocket3NativeGimbalParameterObservation: Codable, Sendable, Equatable {
    public static let maximumAge: TimeInterval = 5
    public static let maximumRawBytes = 128

    public let sessionID: UUID
    public let generation: UInt64
    public let receivedUptime: TimeInterval
    public let raw: Data
    public let readback: Pocket3GimbalParameterReadback?

    public init(sessionID: UUID, generation: UInt64, receivedUptime: TimeInterval,
                raw: Data) {
        self.sessionID = sessionID
        self.generation = generation
        self.receivedUptime = receivedUptime
        self.raw = raw
        self.readback = Pocket3GimbalParameterReadback.decode(raw)
    }

    public init(sessionID: UUID, generation: UInt64, receivedUptime: TimeInterval,
                readback: Pocket3GimbalParameterReadback) {
        self.sessionID = sessionID
        self.generation = generation
        self.receivedUptime = receivedUptime
        self.raw = readback.raw
        self.readback = readback
    }

    public var modeRaw: UInt8? { readback?.modeRaw }
    public var speedRaw: UInt8? { readback?.speedRaw }
    public var mode: Pocket3GimbalMode? { readback?.mode }
    public var speed: Pocket3GimbalSpeed? { readback?.speed }

    public func isFresh(nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        generation != 0 && raw.count <= Self.maximumRawBytes &&
            receivedUptime.isFinite && receivedUptime >= 0 &&
            nowUptime.isFinite && maximumAge.isFinite && maximumAge >= 0 &&
            nowUptime >= receivedUptime && nowUptime - receivedUptime <= maximumAge
    }

    public func isFresh(session: NativeCameraSessionStatus,
                        nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        sessionID == session.sessionID && generation == session.generation &&
            session.state.satisfies(.commandReady) &&
            isFresh(nowUptime: nowUptime, maximumAge: maximumAge)
    }
}

public typealias Pocket3NativeGimbalReadback = Pocket3GimbalParameterReadback
public typealias Pocket3NativeGimbalBaseline = Pocket3NativeGimbalParameterObservation

public enum Pocket3NativeGimbalCoordinatorPhase: String, Codable, Sendable, Equatable, CaseIterable {
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

public enum Pocket3NativeGimbalCoordinatorError: Error, Codable, Sendable, Equatable {
    case sessionNotReady
    case missingSessionIdentity
    case invalidBaseline
    case alreadyAtTarget
    case operationInFlight
    case staleTransaction
    case invalidClock
}

public struct Pocket3NativeGimbalResult: Codable, Sendable, Equatable {
    public let target: Pocket3NativeGimbalTarget
    public let sessionID: UUID
    public let generation: UInt64
    public let phase: Pocket3NativeGimbalCoordinatorPhase
    public let baseline: Pocket3NativeGimbalParameterObservation
    public let transaction: NativeCommandTransactionResult?
    public let readback: Pocket3NativeGimbalParameterObservation?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let noOp: Bool
    public let failureCode: String?
}

/// Shared coordinator for `04/50` Follow/Tilt-Locked mode and speed. A valid
/// response with an unknown selector is retained, but never completes a known
/// requested target.
public struct Pocket3NativeGimbalCoordinator: Sendable {
    public static let maximumReadbackAge: TimeInterval = 5
    public static let defaultTransactionTimeout: TimeInterval = 3

    public let sessionID: UUID
    public let generation: UInt64
    public private(set) var phase: Pocket3NativeGimbalCoordinatorPhase = .idle
    public private(set) var target: Pocket3NativeGimbalTarget?
    public private(set) var request: NativeCommandTransactionRequest?
    public private(set) var transaction: NativeCommandTransactionResult?
    public private(set) var readback: Pocket3NativeGimbalParameterObservation?
    public private(set) var failureCode: String?

    private var baseline: Pocket3NativeGimbalParameterObservation?
    private var readbackBeforeTransaction: Pocket3NativeGimbalParameterObservation?

    public init(session: NativeCameraSessionStatus) throws {
        guard session.generation != 0, session.state.satisfies(.commandReady) else {
            throw Pocket3NativeGimbalCoordinatorError.sessionNotReady
        }
        guard let sessionID = session.sessionID else {
            throw Pocket3NativeGimbalCoordinatorError.missingSessionIdentity
        }
        self.sessionID = sessionID
        generation = session.generation
    }

    public mutating func prepare(
        _ target: Pocket3NativeGimbalTarget,
        baseline: Pocket3NativeGimbalParameterObservation,
        nowUptime: TimeInterval,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        guard phase == .idle else {
            throw Pocket3NativeGimbalCoordinatorError.operationInFlight
        }
        guard baseline.sessionID == sessionID,
              baseline.generation == generation,
              baseline.isFresh(nowUptime: nowUptime,
                               maximumAge: Self.maximumReadbackAge),
              Self.baselineSupports(baseline) else {
            throw Pocket3NativeGimbalCoordinatorError.invalidBaseline
        }

        self.target = target
        self.baseline = baseline
        transaction = nil
        readback = nil
        readbackBeforeTransaction = nil
        failureCode = nil
        if Self.isNoOp(target: target, baseline: baseline) {
            phase = .noOp
            throw Pocket3NativeGimbalCoordinatorError.alreadyAtTarget
        }

        let frame = try Self.frame(for: target)
        let sessionID = self.sessionID
        let generation = self.generation
        let request = try NativeCommandTransactionRequest(
            command: .gimbal, generation: generation, sessionID: sessionID,
            frame: frame, timeout: timeout) { frame in
                Pocket3NativeGimbalCoordinator.observationPayload(from: frame)
            }
        self.request = request
        phase = .awaitingAcknowledgment
        return request
    }

    public mutating func prepareMode(
        _ mode: Pocket3GimbalMode,
        baseline: Pocket3NativeGimbalParameterObservation,
        nowUptime: TimeInterval,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        try prepare(.mode(mode), baseline: baseline,
                    nowUptime: nowUptime, timeout: timeout)
    }

    public mutating func prepareSpeed(
        _ speed: Pocket3GimbalSpeed,
        baseline: Pocket3NativeGimbalParameterObservation,
        nowUptime: TimeInterval,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        try prepare(.speed(speed), baseline: baseline,
                    nowUptime: nowUptime, timeout: timeout)
    }

    @discardableResult
    public mutating func apply(_ transaction: NativeCommandTransactionResult,
                               nowUptime: TimeInterval? = nil) -> Bool {
        guard let request, let target, let baseline,
              request.id == transaction.id,
              transaction.generation == generation,
              transaction.sessionID == sessionID else {
            failureCode = "native_gimbal_stale_transaction"
            phase = .generationChanged
            return false
        }
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            if self.transaction == nil { self.transaction = transaction }
            return false
        }
        if let nowUptime, !nowUptime.isFinite {
            self.transaction = transaction
            failureCode = "native_gimbal_invalid_clock"
            phase = .failed
            return false
        }
        self.transaction = transaction
        if let observed = Self.decodeObserved(transaction.observedPayload,
                                              sessionID: sessionID,
                                              generation: generation,
                                              receivedUptime: transaction.observedUptime) {
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
            failureCode = transaction.failureCode ?? "native_gimbal_timeout"
            phase = .timedOut
            return false
        case .rejected, .failed:
            failureCode = transaction.failureCode ?? "native_gimbal_failed"
            phase = .failed
            return false
        case .acknowledged, .observed:
            guard transaction.acknowledged else {
                failureCode = transaction.failureCode ?? "native_gimbal_ack_invalid"
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
        _ = target; _ = baseline
        return phase == .completed
    }

    @discardableResult
    public mutating func observe(_ observation: Pocket3NativeGimbalParameterObservation,
                                 nowUptime: TimeInterval) -> Bool {
        guard let target, let baseline,
              observation.sessionID == sessionID,
              observation.generation == generation,
              observation.isFresh(nowUptime: nowUptime,
                                  maximumAge: Self.maximumReadbackAge),
              Self.baselineSupports(observation),
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
        guard transaction.acknowledged,
              Self.matches(target: target, observation: observation) else { return false }
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

    /// Marks an explicit execute gate as unavailable without submitting a
    /// command. The caller retains the prepared request as dry-run evidence.
    @discardableResult
    public mutating func blockExecution(reason: String) -> Bool {
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            return false
        }
        phase = .failed
        failureCode = String(reason.prefix(128))
        return true
    }

    public var result: Pocket3NativeGimbalResult? {
        guard let target, let baseline else { return nil }
        return Pocket3NativeGimbalResult(target: target, sessionID: sessionID,
            generation: generation, phase: phase, baseline: baseline,
            transaction: transaction, readback: readback, requested: true,
            submitted: transaction?.submitted == true,
            acknowledged: transaction?.acknowledged == true,
            observed: readback != nil, completed: phase == .completed,
            noOp: phase == .noOp, failureCode: failureCode)
    }

    private static func baselineSupports(
        _ observation: Pocket3NativeGimbalParameterObservation) -> Bool {
        guard let decoded = Pocket3GimbalParameterReadback.decode(observation.raw),
              decoded.raw == observation.raw else { return false }
        return true
    }

    private static func isNoOp(target: Pocket3NativeGimbalTarget,
                               baseline: Pocket3NativeGimbalParameterObservation) -> Bool {
        switch target {
        case .mode(let mode): return baseline.mode == mode
        case .speed(let speed): return baseline.speed == speed
        }
    }

    private static func frame(for target: Pocket3NativeGimbalTarget)
        throws -> NativeCommandFrame {
        let command: Pocket3GimbalParameterCommand
        switch target {
        case .mode(let mode): command = .setMode(mode)
        case .speed(let speed): command = .setSpeed(speed)
        }
        return NativeCommandFrame(frame: command.frame(sequence: 0))
    }

    private static func matches(target: Pocket3NativeGimbalTarget,
                               observation: Pocket3NativeGimbalParameterObservation) -> Bool {
        switch target {
        case .mode(let mode): return observation.mode == mode
        case .speed(let speed): return observation.speed == speed
        }
    }

    private enum ObservationMarker { static let gimbal: UInt8 = 0x72 }

    fileprivate static func observationPayload(from frame: DUMLFrame) -> Data? {
        guard frame.source == 0x04, frame.destination == 0x02,
              frame.flags == 0 || frame.flags == 0x80 || frame.flags == 0xC0,
              frame.commandSet == 0x04, frame.commandID == 0x50,
              let value = Pocket3GimbalParameterReadback.decode(frame.payload) else {
            return nil
        }
        return Data([ObservationMarker.gimbal]) + value.raw
    }

    private static func decodeObserved(_ payload: Data?, sessionID: UUID,
                                       generation: UInt64,
                                       receivedUptime: TimeInterval?)
        -> Pocket3NativeGimbalParameterObservation? {
        guard let payload, payload.count >= 2,
              payload.count <= DUMLCodec.maximumPayloadLength,
              payload[0] == ObservationMarker.gimbal,
              let receivedUptime,
              let value = Pocket3GimbalParameterReadback.decode(
                Data(payload.dropFirst())) else { return nil }
        return Pocket3NativeGimbalParameterObservation(sessionID: sessionID,
            generation: generation, receivedUptime: receivedUptime, readback: value)
    }
}

public typealias Pocket3NativeGimbalParametersCoordinator = Pocket3NativeGimbalCoordinator
public typealias NativePocket3GimbalCoordinator = Pocket3NativeGimbalCoordinator

// MARK: - Native motion command adapters

public extension Pocket3NativeCommandAdapter {
    static func nativeZoom(_ action: Pocket3NativeZoomPayload,
                           generation: UInt64, sessionID: UUID? = nil,
                           timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        let frame = try Pocket3NativeZoomCoordinator.frame(for: action)
        return try NativeCommandTransactionRequest(command: .zoom,
            generation: generation, sessionID: sessionID, frame: frame,
            timeout: timeout) { frame in
                Pocket3NativeZoomCoordinator.observationPayload(from: frame)
            }
    }

    static func nativeZoom(_ command: Pocket3NativeZoomCommand,
                           generation: UInt64, sessionID: UUID? = nil,
                           timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        try nativeZoom(command.action, generation: generation,
                       sessionID: sessionID, timeout: timeout)
    }

    static func zoom(_ action: Pocket3NativeZoomPayload,
                     generation: UInt64, sessionID: UUID? = nil,
                     timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        try nativeZoom(action, generation: generation, sessionID: sessionID,
                       timeout: timeout)
    }

    static func gimbalParameters(_ command: Pocket3GimbalParameterCommand,
                                 generation: UInt64, sessionID: UUID? = nil,
                                 timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        switch command {
        case .get:
            return try readGimbalParameters(generation: generation,
                sessionID: sessionID, timeout: timeout)
        case .setMode(let mode):
            return try gimbalMode(mode, generation: generation,
                sessionID: sessionID, timeout: timeout)
        case .setSpeed(let speed):
            return try gimbalSpeed(speed, generation: generation,
                sessionID: sessionID, timeout: timeout)
        }
    }

    static func gimbalMode(_ mode: Pocket3GimbalMode,
                           generation: UInt64, sessionID: UUID? = nil,
                           timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        let frame = NativeCommandFrame(frame: Pocket3GimbalParameterCommand
            .setMode(mode).frame(sequence: 0))
        return try NativeCommandTransactionRequest(command: .gimbal,
            generation: generation, sessionID: sessionID, frame: frame,
            timeout: timeout) { frame in
                Pocket3NativeGimbalCoordinator.observationPayload(from: frame)
            }
    }

    static func gimbalSpeed(_ speed: Pocket3GimbalSpeed,
                            generation: UInt64, sessionID: UUID? = nil,
                            timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        let frame = NativeCommandFrame(frame: Pocket3GimbalParameterCommand
            .setSpeed(speed).frame(sequence: 0))
        return try NativeCommandTransactionRequest(command: .gimbal,
            generation: generation, sessionID: sessionID, frame: frame,
            timeout: timeout) { frame in
                Pocket3NativeGimbalCoordinator.observationPayload(from: frame)
            }
    }

    static func gimbal(_ target: Pocket3NativeGimbalTarget,
                       generation: UInt64, sessionID: UUID? = nil,
                       timeout: TimeInterval = 2)
        throws -> NativeCommandTransactionRequest {
        switch target {
        case .mode(let mode):
            return try gimbalMode(mode, generation: generation, sessionID: sessionID,
                                  timeout: timeout)
        case .speed(let speed):
            return try gimbalSpeed(speed, generation: generation, sessionID: sessionID,
                                   timeout: timeout)
        }
    }
}
