import Foundation
import CryptoKit

public struct BluetoothCameraSettingWriteRequest: Sendable, Codable {
    public static let operation = "validation-wireless-setting"
    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let expectedCaptureSessionID: String
    public let command: CameraSettingCommand
    public let expectedBaseline: CameraSettingsObservation
    public var property: CameraSettingsProperty { command.value.property }

    public init(expectedSessionID: UUID, peripheralID: UUID, expectedCaptureSessionID: String,
                command: CameraSettingCommand, expectedBaseline: CameraSettingsObservation) throws {
        let binding = ContinuousGimbalBinding(sessionID: "ble:\(expectedSessionID.uuidString)", generation: 0)
        guard UUID(uuidString: expectedCaptureSessionID) != nil,
              expectedBaseline.binding == binding, expectedBaseline.property == command.value.property,
              expectedBaseline.value?.property == command.value.property,
              expectedBaseline.receivedUptime.isFinite, expectedBaseline.receivedUptime >= 0 else {
            throw BridgeFailure("invalid_bluetooth_setting_request", "Pass the exact capture/BLE sessions and a known matching-property baseline")
        }
        self.expectedSessionID = expectedSessionID; self.peripheralID = peripheralID
        self.expectedCaptureSessionID = expectedCaptureSessionID; self.command = command
        self.expectedBaseline = expectedBaseline
    }
    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys) == ["expectedSessionID", "peripheralID", "expectedCaptureSessionID", "property", "value", "expectedBaseline"],
              let session = fields["expectedSessionID"]?.string.flatMap(UUID.init(uuidString:)),
              let peer = fields["peripheralID"]?.string.flatMap(UUID.init(uuidString:)),
              let capture = fields["expectedCaptureSessionID"]?.string,
              let property = fields["property"]?.string.flatMap(CameraSettingsProperty.init(rawValue:)),
              let value = fields["value"], let baseline = fields["expectedBaseline"] else {
            throw BridgeFailure("invalid_bluetooth_setting_request", "Use exact session/peripheral/capture/property/value/expectedBaseline arguments")
        }
        let command = try value.decode(CameraSettingCommand.self)
        // A command value has a fixed Codable shape; ignored extra nested keys
        // must not silently turn into a different operator request.
        guard property == command.value.property,
              value.pretty == (try JSONValue.encode(command)).pretty else {
            throw BridgeFailure("invalid_bluetooth_setting_request", "Property and the exact CameraSettingCommand JSON value must agree")
        }
        try self.init(expectedSessionID: session, peripheralID: peer, expectedCaptureSessionID: capture,
                      command: command, expectedBaseline: baseline.decode(CameraSettingsObservation.self))
    }
    public init(cliArguments: [String]) throws {
        guard cliArguments.count == 12 else { throw BridgeFailure("usage", "Use --session --peripheral --capture-session --property --value-json --baseline-json exactly once") }
        let names = ["--session": "expectedSessionID", "--peripheral": "peripheralID", "--capture-session": "expectedCaptureSessionID",
                     "--property": "property", "--value-json": "value", "--baseline-json": "expectedBaseline"]
        var fields: [String: JSONValue] = [:]
        for index in stride(from: 0, to: cliArguments.count, by: 2) {
            guard let key = names[cliArguments[index]], fields[key] == nil else { throw BridgeFailure("usage", "Unknown or duplicate camera-setting option") }
            let text = cliArguments[index + 1]
            guard text.utf8.count <= 8192 else { throw BridgeFailure("usage", "Camera-setting arguments are oversized") }
            fields[key] = ["value", "expectedBaseline"].contains(key)
                ? try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) : .string(text)
        }
        try self.init(arguments: .object(fields))
    }
    public var arguments: JSONValue {
        get throws {
            .object(["expectedSessionID": .string(expectedSessionID.uuidString), "peripheralID": .string(peripheralID.uuidString),
                     "expectedCaptureSessionID": .string(expectedCaptureSessionID), "property": .string(property.rawValue),
                     "value": try .encode(command), "expectedBaseline": try .encode(expectedBaseline)])
        }
    }
    public init(from decoder: Decoder) throws { try self.init(arguments: JSONValue(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try arguments.encode(to: encoder) }

    func validateBaseline(_ current: CameraSettingsObservation, now: TimeInterval) throws {
        guard expectedBaseline.isFresh(now: now), current.isFresh(now: now),
              current.binding == expectedBaseline.binding, current.property == property, current.value != nil,
              current.receivedUptime >= expectedBaseline.receivedUptime else {
            throw BridgeFailure("bluetooth_setting_baseline_stale", "Read the current paired camera setting again before submitting")
        }
        guard current.value == expectedBaseline.value, current.exposureMode == expectedBaseline.exposureMode else {
            throw BridgeFailure("bluetooth_setting_baseline_changed", "The camera setting changed after the supplied baseline")
        }
        if case .autoEV = command.value, current.exposureMode != .automatic {
            throw BridgeFailure("bluetooth_setting_exposure_not_auto", "Auto EV requires confirmed automatic exposure")
        }
    }
}

public enum BluetoothCameraSettingWriteEnd: String, Codable, Sendable {
    case applied, stateMatchedWithoutACK, noOp, nack, invalidACK, readbackTimeout, valueChangedAfterMatch
    case creditTimeout, cancelled, connectionChanged, baselineChanged, invalidClock, observationBudgetExceeded, failed
}
public struct BluetoothCameraSettingCreditWait: Codable, Sendable {
    public var startedUptime: TimeInterval?
    public var deadlineUptime: TimeInterval?
    public var endedUptime: TimeInterval?
    public var durationSeconds: TimeInterval = 0
    public var reason: String?
    public var outcome: String?
}
public struct BluetoothCameraSettingWriteResult: Codable, Sendable {
    public let request: BluetoothCameraSettingWriteRequest
    public let baseline: CameraSettingsObservation
    public let sequence: UInt16
    public let startedUptime: TimeInterval
    public var submittedUptime: TimeInterval?
    public var submissionBaseline: CameraSettingsObservation?
    public var submissionBaselineSequence: UInt16?
    public var finishedUptime: TimeInterval?
    public var end: BluetoothCameraSettingWriteEnd?
    public var failure: String?
    public var localSubmitted = false
    public var noOp = false
    public var applied = false
    public var stateMatched = false
    public var ackReceived = false
    public var acknowledged = false
    public var ackHeader: BluetoothDUMLHeader?
    public var ackUptime: TimeInterval?
    public var ackStatus: UInt8?
    public var ackPayloadBytes: Int?
    public var ackLate = false
    public var ackTimedOut = false
    public var creditWait = BluetoothCameraSettingCreditWait()
    public var observationWindowComplete = false
    public var observations: [CameraSettingsObservation] = []
    public var matchingReadbackCount = 0
    public var valueChangedAfterMatch = false
    public var latestObservation: CameraSettingsObservation?
    public var observationBudgetExceeded = false
    public private(set) var verification = "post_submission_matching_property_and_successful_ack_after_full_three_second_window"
    public private(set) var focusVerification = "mode_only_not_optical_focus"
    public private(set) var retryPerformed = false
    public private(set) var restorePerformed = false
}

/// A single existing CameraSettingCommand, with no subscription, retry or restore.
/// CameraSettingsState owns typed baseline/confirmation semantics. This adapter
/// adds transport admission, submission-relative timing and a full observation
/// window so a first matching state followed by another value is not called applied.
struct BluetoothCameraSettingWriter {
    static let creditTimeout: TimeInterval = BluetoothTapFocusProbe.creditWaitTimeout
    static let acknowledgmentTimeout: TimeInterval = 0.8
    static let observationDuration: TimeInterval = 3
    static let maximumObservations = 64
    static let maximumPreparationDuration = CameraSettingsState.maximumPendingDuration - observationDuration
    private(set) var result: BluetoothCameraSettingWriteResult
    private var state: CameraSettingsState
    private let intent: CameraSettingRequest
    private var lastEvent: TimeInterval
    private var lastPropertySequence: UInt16
    private var fingerprints: Set<Data>
    private var invalidACK = false
    private var nack = false
    private var admittedPropertyCount = 0

    init(request: BluetoothCameraSettingWriteRequest, baseline: BluetoothCameraSettingsStore.AdmissionSnapshot,
         sequence: UInt16, now: TimeInterval) throws {
        guard Self.validTime(now), baseline.fingerprints.count <= BluetoothCameraSettingsStore.maximumFingerprintsPerProperty,
              baseline.fingerprints.allSatisfy({ $0.count == 32 }) else { throw CameraSettingsError.invalidTime }
        try request.validateBaseline(baseline.observation, now: now)
        var state = try CameraSettingsState(binding: baseline.observation.binding)
        guard state.apply(baseline.observation, now: now) else { throw CameraSettingsError.noFreshBaseline }
        let intent = try state.prepare(request.command, sequence: sequence, now: now, timeout: 5)
        self.state = state; self.intent = intent; lastEvent = now; lastPropertySequence = baseline.sequence
        fingerprints = Set(baseline.fingerprints)
        result = BluetoothCameraSettingWriteResult(request: request, baseline: baseline.observation, sequence: sequence, startedUptime: now)
        if baseline.observation.value == request.command.value {
            result.noOp = true; result.latestObservation = baseline.observation
            finish(at: now, reason: .noOp)
        }
    }
    var frame: DUMLFrame { intent.frame }

    mutating func submitIfReady(currentBaseline: BluetoothCameraSettingsStore.AdmissionSnapshot, hasCredit: Bool,
        maximumWriteBytes: Int, at now: TimeInterval, write: (DUMLFrame, Data) -> Void) throws -> Bool {
        tick(at: now)
        guard result.end == nil, !result.localSubmitted else { return false }
        try result.request.validateBaseline(currentBaseline.observation, now: now)
        let sequenceDistance = currentBaseline.sequence &- lastPropertySequence
        guard sequenceDistance < 0x8000,
              currentBaseline.fingerprints.count <= BluetoothCameraSettingsStore.maximumFingerprintsPerProperty,
              currentBaseline.fingerprints.allSatisfy({ $0.count == 32 }) else {
            throw BridgeFailure("bluetooth_setting_baseline_changed", "The property's sequence baseline changed before submission")
        }
        lastPropertySequence = currentBaseline.sequence
        fingerprints.formUnion(currentBaseline.fingerprints)
        _ = state.apply(currentBaseline.observation, now: now)
        try state.validateForSubmission(intent, binding: state.binding, now: now)
        guard hasCredit else {
            if result.creditWait.startedUptime == nil {
                result.creditWait.startedUptime = now; result.creditWait.deadlineUptime = now + Self.creditTimeout
                result.creditWait.reason = "corebluetooth_without_response_credit"
            }
            return false
        }
        let data = try DUMLCodec.encode(frame)
        guard maximumWriteBytes >= data.count else { throw BridgeFailure("bluetooth_setting_mtu", "The setting must fit one whole BLE write") }
        try state.markSubmitted(intent, binding: state.binding, at: now)
        result.localSubmitted = true; result.submittedUptime = now; lastEvent = now
        result.submissionBaseline = currentBaseline.observation
        result.submissionBaselineSequence = currentBaseline.sequence
        if result.creditWait.startedUptime != nil {
            result.creditWait.endedUptime = now; result.creditWait.outcome = "credit_restored"
        }
        write(frame, data)
        return true
    }

    mutating func receive(_ packet: ValidatedDUMLPacket, propertyAdmitted: Bool, characteristic: String,
                         sessionID: UUID, peripheralID: UUID, at now: TimeInterval) {
        guard result.end == nil, sessionID == result.request.expectedSessionID, peripheralID == result.request.peripheralID,
              ["FFF4", "FFF5"].contains(characteristic) else { return }
        tick(at: now)
        guard result.end == nil else { return }
        let frame = packet.frame
        if let sent = result.submittedUptime, now >= sent, frame.source == 1, frame.destination == 2,
           frame.flags == 0x80 || frame.flags == 0xc0, frame.sequence == result.sequence,
           frame.commandSet == 2, frame.commandID == intent.command.commandID {
            let status = frame.payload.first
            // An explicit negative/empty reply wins over a prior success; it
            // cannot be erased by another duplicate positive ACK.
            if !result.ackReceived || status != 0 {
                result.ackReceived = true; result.ackUptime = now; result.ackStatus = status
                result.ackPayloadBytes = frame.payload.count; result.ackLate = now - sent > Self.acknowledgmentTimeout
                result.ackHeader = BluetoothDUMLHeader(direction: "received", characteristic: characteristic,
                    source: frame.source, destination: frame.destination, sequence: frame.sequence, flags: frame.flags,
                    commandSet: frame.commandSet, commandID: frame.commandID)
                nack = nack || (status != nil && status != 0); invalidACK = invalidACK || status == nil
                result.acknowledged = !nack && !invalidACK && status == 0 && !result.ackLate
            }
            lastEvent = now
            return // ACK never confirms applied, even with a property-looking body.
        }
        guard propertyAdmitted, frame.source == 0x28, frame.destination == 2, frame.flags == 0,
              frame.commandSet == 0, frame.commandID == 0x99,
              let push = try? CameraPropertyCodec.decodePush(from: frame), push.property == result.request.property,
              push.value.count <= BluetoothCameraPropertyQuery.maximumValueBytes,
              let observation = CameraSettingsObservation.decode(push, binding: state.binding, receivedUptime: now) else { return }
        let distance = frame.sequence &- lastPropertySequence, fingerprint = Data(SHA256.hash(data: packet.frameData))
        guard distance > 0, distance < 0x8000, !fingerprints.contains(fingerprint) else { return }
        if admittedPropertyCount >= Self.maximumObservations {
            result.observationBudgetExceeded = true
            if !result.localSubmitted { finish(at: now, reason: .observationBudgetExceeded) }
            return
        }
        admittedPropertyCount += 1
        fingerprints.insert(fingerprint); lastPropertySequence = frame.sequence; lastEvent = now
        _ = state.apply(observation, now: now)
        guard let sent = result.submittedUptime, now > sent else {
            do { try result.request.validateBaseline(observation, now: now) }
            catch { finish(at: now, reason: .baselineChanged, failure: "bluetooth_setting_baseline_changed") }
            return
        }
        result.observations.append(observation); result.latestObservation = observation
        let matches = targetMatches(observation)
        if matches { result.matchingReadbackCount += 1 }
        else if result.matchingReadbackCount > 0 { result.valueChangedAfterMatch = true }
    }

    mutating func tick(at now: TimeInterval) {
        guard result.end == nil else { return }
        guard Self.validTime(now), now >= lastEvent else { finish(at: lastEvent, reason: .invalidClock); return }
        if let started = result.creditWait.startedUptime, result.creditWait.endedUptime == nil {
            result.creditWait.durationSeconds = now - started
            if let deadline = result.creditWait.deadlineUptime, now >= deadline {
                finish(at: now, reason: .creditTimeout, failure: "bluetooth_setting_credit_timeout"); return
            }
        }
        if let sent = result.submittedUptime {
            if !result.ackReceived, now - sent >= Self.acknowledgmentTimeout { result.ackTimedOut = true }
            if now - sent >= Self.observationDuration {
                result.observationWindowComplete = true
                result.stateMatched = result.matchingReadbackCount > 0 && result.latestObservation.map {
                    $0.receivedUptime > sent && $0.isFresh(now: now) && targetMatches($0)
                } == true
                    && !result.valueChangedAfterMatch && !result.observationBudgetExceeded
                let end: BluetoothCameraSettingWriteEnd
                if nack { end = .nack }
                else if invalidACK { end = .invalidACK }
                else if result.observationBudgetExceeded { end = .observationBudgetExceeded }
                else if result.valueChangedAfterMatch { end = .valueChangedAfterMatch }
                else if result.stateMatched { end = result.acknowledged ? .applied : .stateMatchedWithoutACK }
                else { end = .readbackTimeout }
                result.applied = end == .applied
                finish(at: now, reason: end, failure: result.applied ? nil : end.rawValue)
                return
            }
        } else if now - result.startedUptime >= Self.maximumPreparationDuration {
            // Keep the complete post-SET three-second window inside the
            // underlying CameraSettingsState's five-second intent deadline.
            finish(at: now, reason: .creditTimeout, failure: "bluetooth_setting_preparation_timeout"); return
        }
        lastEvent = now
    }
    @discardableResult
    mutating func finish(at now: TimeInterval, reason: BluetoothCameraSettingWriteEnd, failure: String? = nil) -> BluetoothCameraSettingWriteResult {
        guard result.end == nil else { return result }
        result.finishedUptime = Self.validTime(now) && now >= lastEvent ? now : lastEvent
        result.end = reason; result.failure = failure.map { String($0.prefix(128)) }
        if reason != .applied { result.applied = false }
        if let started = result.creditWait.startedUptime, result.creditWait.endedUptime == nil {
            result.creditWait.endedUptime = result.finishedUptime
            result.creditWait.durationSeconds = max(0, result.finishedUptime! - started)
            result.creditWait.outcome = reason.rawValue
        }
        if reason == .cancelled || reason == .connectionChanged { state.cancel(intent) }
        else if !result.applied { state.markUnconfirmed(intent, failureCode: failure ?? reason.rawValue) }
        return result
    }
    private func targetMatches(_ observation: CameraSettingsObservation) -> Bool {
        guard observation.property == result.request.property, observation.value == result.request.command.value else { return false }
        if case .autoEV = result.request.command.value { return observation.exposureMode == .automatic }
        return true
    }
    private static func validTime(_ value: TimeInterval) -> Bool { value.isFinite && value >= 0 && value + 5 > value }
}
