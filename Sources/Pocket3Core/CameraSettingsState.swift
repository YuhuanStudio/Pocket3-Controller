import Foundation

public struct CameraSettingRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let binding: ContinuousGimbalBinding
    public let command: CameraSettingCommand
    public let sequence: UInt16
    public var frame: DUMLFrame { command.frame(sequence: sequence) }
}
public enum CameraSettingOperationPhase: String, Codable, Sendable {
    case prepared, pending, confirmed, unconfirmed, cancelled
}
public struct CameraSettingConfirmation: Codable, Sendable, Equatable {
    public let observed: CameraSettingValue
    public let property: CameraSettingsProperty
    public let transactionID: UInt32
    public let receivedUptime: TimeInterval
    /// A fresh matching camera state is observed after submission. This does
    /// not assert that a property transaction ID echoes a setter request ID.
    public let basis: String
}
public struct CameraSettingOperation: Codable, Sendable, Equatable {
    public let request: CameraSettingRequest
    public let baseline: CameraSettingsObservation
    public let createdUptime: TimeInterval
    public let deadlineUptime: TimeInterval
    public var phase: CameraSettingOperationPhase
    public var submittedUptime: TimeInterval?
    public var confirmation: CameraSettingConfirmation?
    public var failureCode: String?
}

/// Pure, single-owner value state for a future datalink adapter. It performs no
/// I/O. A new connection must get a new state instance with its new binding.
/// Sequence allocation, permission, peer validation, replay rejection and the
/// final write fence remain owned by the transport/App integration.
public struct CameraSettingsState: Sendable {
    // Host-side policy bounds, not claimed Pocket 3 protocol timing constants.
    public static let maximumObservationAge: TimeInterval = 5
    public static let maximumPendingDuration: TimeInterval = 5
    public let binding: ContinuousGimbalBinding
    public private(set) var operation: CameraSettingOperation?
    private var observations: [CameraSettingsProperty: CameraSettingsObservation] = [:]

    public init(binding: ContinuousGimbalBinding) throws {
        guard !binding.sessionID.isEmpty else { throw CameraSettingsError.invalidSession }
        self.binding = binding
    }
    public func observation(for property: CameraSettingsProperty) -> CameraSettingsObservation? { observations[property] }
    public func currentValue(for property: CameraSettingsProperty, now: TimeInterval) -> CameraSettingValue? {
        guard let observation = observations[property], observation.isFresh(now: now, maximumAge: Self.maximumObservationAge) else { return nil }
        return observation.value
    }

    /// Creates an intent only; actual state is never updated from this request.
    /// One pending setting prevents ambiguous overlapping writes to a property.
    public mutating func prepare(_ command: CameraSettingCommand, sequence: UInt16, now: TimeInterval,
                                 timeout: TimeInterval = 3) throws -> CameraSettingRequest {
        guard now.isFinite, now >= 0, timeout.isFinite, timeout > 0, timeout <= Self.maximumPendingDuration,
              (now + timeout).isFinite, now + timeout > now else { throw CameraSettingsError.invalidTime }
        expire(at: now)
        guard operation?.phase != .prepared && operation?.phase != .pending else { throw CameraSettingsError.busy }
        let baseline = try freshBaseline(for: command, now: now)
        let request = CameraSettingRequest(id: UUID(), binding: binding, command: command, sequence: sequence)
        operation = CameraSettingOperation(request: request, baseline: baseline, createdUptime: now,
            deadlineUptime: now + timeout, phase: .prepared, submittedUptime: nil, confirmation: nil, failureCode: nil)
        return request
    }

    /// Call within the transport's existing permit/serialized final-write fence,
    /// immediately before sending request.frame. A stale callback cannot submit
    /// a cancelled, replaced, timed-out or externally changed setting request.
    public func validateForSubmission(_ request: CameraSettingRequest, binding: ContinuousGimbalBinding, now: TimeInterval) throws {
        guard binding == self.binding && request.binding == binding else { throw CameraSettingsError.wrongSession }
        guard let operation, operation.request == request else { throw CameraSettingsError.unknownRequest }
        guard now.isFinite, now >= operation.createdUptime else { throw CameraSettingsError.invalidTime }
        guard now < operation.deadlineUptime else { throw CameraSettingsError.requestExpired }
        guard operation.phase == .prepared else { throw CameraSettingsError.invalidTransition }
        let current = try freshBaseline(for: request.command, now: now)
        guard baselineMatches(current, operation.baseline, for: request.command) else {
            throw CameraSettingsError.baselineChanged
        }
    }

    /// Record the actual final-write timestamp, not the time an intent entered
    /// an async queue. An earlier matching property is never retro-confirmed.
    public mutating func markSubmitted(_ request: CameraSettingRequest, binding: ContinuousGimbalBinding,
                                       at sentUptime: TimeInterval) throws {
        guard binding == self.binding && request.binding == binding else { throw CameraSettingsError.wrongSession }
        guard var operation, operation.request == request else { throw CameraSettingsError.unknownRequest }
        guard operation.phase == .prepared else { throw CameraSettingsError.invalidTransition }
        guard sentUptime.isFinite, sentUptime >= operation.createdUptime else { throw CameraSettingsError.invalidTime }
        guard sentUptime < operation.deadlineUptime else { expire(at: sentUptime); throw CameraSettingsError.requestExpired }
        operation.phase = .pending; operation.submittedUptime = sentUptime
        self.operation = operation
    }

    /// Unknown codes replace the affected observation with a fresh unknown;
    /// malformed, stale or wrong-generation deliveries cannot confirm anything.
    @discardableResult
    public mutating func apply(_ push: CameraPropertyPush, binding: ContinuousGimbalBinding,
                               receivedUptime: TimeInterval, now: TimeInterval) -> Bool {
        guard let observation = CameraSettingsObservation.decode(push, binding: binding, receivedUptime: receivedUptime) else { return false }
        return apply(observation, now: now)
    }

    /// Seed/update from the transport's already-decoded, session-bound store.
    /// This avoids fabricating a wire payload from a displayed baseline value.
    @discardableResult
    public mutating func apply(_ observation: CameraSettingsObservation, now: TimeInterval) -> Bool {
        let receivedUptime = observation.receivedUptime
        if let value = observation.value, (try? CameraSettingCommand(value)) == nil { return false }
        guard observation.binding == binding,
              observation.value == nil || observation.value?.property == observation.property,
              observation.isFresh(now: now, maximumAge: Self.maximumObservationAge),
              receivedUptime > (observations[observation.property]?.receivedUptime ?? -1) else { return false }
        expire(at: now)
        observations[observation.property] = observation // Update freshness even when the value is unchanged.
        guard var operation, operation.phase == .pending,
              let submitted = operation.submittedUptime, receivedUptime > submitted,
              operation.request.command.value.property == observation.property,
              observation.value == operation.request.command.value else { return true }
        if case .autoEV = operation.request.command.value, observation.exposureMode != .automatic { return true }
        operation.phase = .confirmed
        operation.confirmation = CameraSettingConfirmation(observed: operation.request.command.value,
            property: observation.property, transactionID: observation.transactionID, receivedUptime: receivedUptime,
            basis: "fresh_matching_property_after_submission")
        operation.failureCode = nil
        self.operation = operation
        return true
    }

    public mutating func expire(at now: TimeInterval) {
        guard now.isFinite, var operation, operation.phase == .prepared || operation.phase == .pending,
              now >= operation.deadlineUptime else { return }
        operation.failureCode = operation.phase == .prepared ? "request_not_submitted" : "readback_timeout"
        operation.phase = .unconfirmed; self.operation = operation
    }
    public mutating func cancel(_ request: CameraSettingRequest) {
        guard var operation, operation.request == request,
              operation.phase == .prepared || operation.phase == .pending else { return }
        operation.phase = .cancelled; operation.failureCode = "cancelled"
        self.operation = operation
    }
    public mutating func markUnconfirmed(_ request: CameraSettingRequest, failureCode: String) {
        guard var operation, operation.request == request,
              operation.phase == .prepared || operation.phase == .pending else { return }
        operation.phase = .unconfirmed
        operation.failureCode = String(failureCode.prefix(128))
        self.operation = operation
    }

    private func freshBaseline(for command: CameraSettingCommand, now: TimeInterval) throws -> CameraSettingsObservation {
        guard let observation = observations[command.value.property], observation.value != nil,
              observation.isFresh(now: now, maximumAge: Self.maximumObservationAge) else { throw CameraSettingsError.noFreshBaseline }
        if case .autoEV = command.value, observation.exposureMode != .automatic { throw CameraSettingsError.exposureNotAutomatic }
        if command.requiresExactVideoParametersBaseline && !isExactVideoParametersBaseline(observation) {
            throw CameraSettingsError.noFreshBaseline
        }
        return observation
    }

    private func baselineMatches(_ current: CameraSettingsObservation,
                                 _ baseline: CameraSettingsObservation,
                                 for command: CameraSettingCommand) -> Bool {
        guard current.value == baseline.value,
              current.exposureMode == baseline.exposureMode else { return false }
        guard !command.requiresExactVideoParametersBaseline else {
            // A compression SET addresses only the codec selector. Keep the
            // whole named-property baseline stable until the final write so a
            // concurrent format change cannot be authorized by a matching
            // compression byte alone.
            return isExactVideoParametersBaseline(current)
                && isExactVideoParametersBaseline(baseline)
                && current.readOnlyValue == baseline.readOnlyValue
        }
        return true
    }

    private func isExactVideoParametersBaseline(_ observation: CameraSettingsObservation) -> Bool {
        guard observation.property == .videoParameters,
              case .videoParameters(let video) = observation.readOnlyValue,
              video.raw.count >= 9,
              video.raw[0] == video.resolutionRaw,
              video.raw[1] == video.frameRateRaw,
              video.raw[8] == video.compressionRaw,
              let compression = video.compression,
              video.compressionRaw == compression.rawValue,
              observation.value == .videoCompression(compression) else { return false }
        return true
    }
}
