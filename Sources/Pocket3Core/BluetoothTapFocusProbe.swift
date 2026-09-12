import Foundation
import CryptoKit

/// Explicit DJI candidate coordinates, never an AVFoundation preview mapping.
public struct BluetoothTapFocusRequest: Sendable, Equatable, Codable {
    public static let operation = "validation-wireless-tap-focus"
    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let expectedCaptureSessionID: String
    public let x: Double
    public let y: Double

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys) == ["expectedSessionID", "peripheralID", "expectedCaptureSessionID", "x", "y"],
              let session = fields["expectedSessionID"]?.string.flatMap(UUID.init(uuidString:)),
              let peer = fields["peripheralID"]?.string.flatMap(UUID.init(uuidString:)),
              let capture = fields["expectedCaptureSessionID"]?.string, UUID(uuidString: capture) != nil,
              let x = fields["x"]?.number, let y = fields["y"]?.number,
              x.isFinite, y.isFinite, (0.1...0.9).contains(x), (0.1...0.9).contains(y) else {
            throw BridgeFailure("invalid_bluetooth_focus_request", "Pass exact BLE session/peripheral and USB capture session UUIDs, plus DJI x/y in 0.1...0.9; no other arguments are accepted")
        }
        expectedSessionID = session; peripheralID = peer; expectedCaptureSessionID = capture
        self.x = x; self.y = y
    }
    public init(cliArguments: [String]) throws {
        guard cliArguments.count == 10 else { throw BridgeFailure("usage", "Use --session BLE-UUID --peripheral UUID --capture-session USB-UUID --x 0.3 --y 0.3") }
        let names = ["--session": "expectedSessionID", "--peripheral": "peripheralID", "--capture-session": "expectedCaptureSessionID", "--x": "x", "--y": "y"]
        var fields: [String: JSONValue] = [:]
        for index in stride(from: 0, to: cliArguments.count, by: 2) {
            guard let key = names[cliArguments[index]], fields[key] == nil else { throw BridgeFailure("usage", "Unknown or duplicate tap-focus option") }
            let text = cliArguments[index + 1]
            if key == "x" || key == "y" {
                guard let number = Double(text), number.isFinite else { throw BridgeFailure("usage", "Focus coordinates must be finite numbers") }
                fields[key] = .number(number)
            } else { fields[key] = .string(text) }
        }
        try self.init(arguments: .object(fields))
    }
    public var arguments: JSONValue {
        .object(["expectedSessionID": .string(expectedSessionID.uuidString), "peripheralID": .string(peripheralID.uuidString),
                 "expectedCaptureSessionID": .string(expectedCaptureSessionID), "x": .number(x), "y": .number(y)])
    }
    public init(from decoder: Decoder) throws { try self.init(arguments: JSONValue(from: decoder)) }
}

public struct BluetoothTapFocusBaseline: Codable, Sendable {
    public let lens: CameraSettingsObservation
    public let exposure: CameraSettingsObservation
    public init(request: BluetoothTapFocusRequest, observations: [CameraSettingsObservation], now: TimeInterval) throws {
        let binding = ContinuousGimbalBinding(sessionID: "ble:\(request.expectedSessionID.uuidString)", generation: 0)
        guard let lens = observations.first(where: { $0.property == .lensState && $0.binding == binding && $0.isFresh(now: now) }),
              case .focus? = lens.value,
              let exposure = observations.first(where: { $0.property == .exposure && $0.binding == binding && $0.isFresh(now: now) }),
              case .autoEV? = exposure.value, exposure.exposureMode == .automatic else {
            throw BridgeFailure("bluetooth_focus_baseline_unavailable", "Read fresh, known lens mode and automatic-exposure state from this paired BLE session before the probe")
        }
        self.lens = lens; self.exposure = exposure
    }
    func isFresh(now: TimeInterval) -> Bool { lens.isFresh(now: now) && exposure.isFresh(now: now) }
}

public enum BluetoothTapFocusStep: String, Codable, Sendable, CaseIterable {
    case prepareAE, point, hintAE, commitMetering
    var commandID: UInt8 { switch self { case .prepareAE: 0x22; case .point: 0x30; case .hintAE: 0x68; case .commitMetering: 0x32 } }
}
public struct BluetoothTapFocusStepResult: Codable, Sendable {
    public let step: BluetoothTapFocusStep
    public let sequence: UInt16
    public let commandID: UInt8
    public let payloadBytes: Int
    public var submittedUptime: TimeInterval?
    public var locallySubmitted = false
    public var acknowledged = false
    public var ackHeader: BluetoothDUMLHeader?
    public var ackUptime: TimeInterval?
    public var ackStatus: UInt8?
    public var ackPayloadBytes: Int?
    public var ackPayloadPrefixHex: String?
    public var ackLate = false
    public var ackTimedOut = false
    public var creditWaitStartedUptime: TimeInterval?
    public var creditWaitDeadlineUptime: TimeInterval?
    public var creditWaitEndedUptime: TimeInterval?
    public var creditWaitDurationSeconds: TimeInterval = 0
    public var creditWaitReason: String?
    public var creditWaitOutcome: String?
}
public enum BluetoothTapFocusEnd: String, Codable, Sendable {
    case observationComplete, cancelled, connectionChanged, ackTimeout, creditTimeout, nack, invalidACK, invalidClock, failed, overallTimeout
}
public struct BluetoothTapFocusResult: Codable, Sendable {
    public let request: BluetoothTapFocusRequest
    public let baseline: BluetoothTapFocusBaseline
    public let startedUptime: TimeInterval
    public var finishedUptime: TimeInterval?
    public var end: BluetoothTapFocusEnd?
    public var failure: String?
    public var steps: [BluetoothTapFocusStepResult]
    public var lensPoints: [BluetoothFocusPointObservation] = []
    public var invalidLensCandidates = 0
    public private(set) var sequencePolicy = "prepare_untracked_then_point_ack_800ms_hint_ack_required_before_commit_commit_ack_800ms_unsent_credit_wait_800ms_no_retry"
    public private(set) var hintPolicyDiffersFromUpstream = true
    public private(set) var coordinateMapping = "explicit_dji_normalized_candidate_not_calibrated_avfoundation_mapping"
    public private(set) var opticalFocusVerification = "not_available"
    public private(set) var retryPerformed = false
    public private(set) var restorePerformed = false
    public var submittedCount = 0
    public var partialSequence = false
    public var possibleAEsideEffects = false
    public var sequenceAcknowledged = false
    /// Bounded rejection evidence for the readback-session diagnostic. The
    /// probe still keeps packet bytes private and never retries a rejected
    /// envelope.
    public var wrongEnvelopeCount: Int? = 0
    public var wrongSequenceCount: Int? = 0
    public var foreignSessionNotificationCount: Int? = 0
    public var lastRejectedHeader: BluetoothDUMLHeader?
}

/// Independent implementation of the four fixed OpenPocketCine commands at
/// 9c4e7334ca4d935c5d467abecaf8f968f7927d84 (Commands.swift 270–314,
/// CameraSession.swift 2197–2214). Upstream sends via datalink, not proof of BLE
/// support. CameraReply success is exactly payload.first == 0 (empty is failure).
struct BluetoothTapFocusProbe {
    static let acknowledgmentTimeout: TimeInterval = 0.8
    static let creditWaitTimeout: TimeInterval = 0.8
    static let readbackDuration: TimeInterval = 2
    static let maximumDuration: TimeInterval = 5
    static let maximumLensPoints = 32
    private(set) var result: BluetoothTapFocusResult
    private var lastEvent: TimeInterval
    private var lastLensSequence: UInt16?
    private var lensFingerprints = Set<Data>()
    private var observationDeadline: TimeInterval?

    init(request: BluetoothTapFocusRequest, baseline: BluetoothTapFocusBaseline, sequences: [UInt16], now: TimeInterval) throws {
        guard validTime(now), baseline.isFresh(now: now), sequences.count == 4, Set(sequences).count == 4 else {
            throw BridgeFailure("bluetooth_focus_probe_setup", "Fresh baseline and four distinct coordinated sequences are required")
        }
        let checkedBaseline = try BluetoothTapFocusBaseline(request: request, observations: [baseline.lens, baseline.exposure], now: now)
        let steps = zip(BluetoothTapFocusStep.allCases, sequences).map { step, sequence in
            BluetoothTapFocusStepResult(step: step, sequence: sequence, commandID: step.commandID,
                payloadBytes: Self.payload(step, x: request.x, y: request.y).count)
        }
        result = BluetoothTapFocusResult(request: request, baseline: checkedBaseline, startedUptime: now, steps: steps)
        lastEvent = now
    }

    var nextStep: BluetoothTapFocusStep? {
        guard result.end == nil else { return nil }
        if result.steps[0].submittedUptime == nil { return .prepareAE }
        if result.steps[1].submittedUptime == nil { return .point }
        if result.steps[1].acknowledged && result.steps[2].submittedUptime == nil { return .hintAE }
        if result.steps[2].acknowledged && result.steps[3].submittedUptime == nil { return .commitMetering }
        return nil
    }
    func frame(for step: BluetoothTapFocusStep) -> DUMLFrame {
        let entry = result.steps.first { $0.step == step }!
        return DUMLFrame(source: 2, destination: 1, sequence: entry.sequence, flags: 0x40,
            commandSet: 2, commandID: step.commandID, payload: Self.payload(step, x: result.request.x, y: result.request.y))
    }
    private static func payload(_ step: BluetoothTapFocusStep, x: Double, y: Double) -> Data {
        func bytes(_ value: Double) -> [UInt8] {
            let bits = Float(value).bitPattern
            return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8), UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 24)]
        }
        switch step {
        case .prepareAE: return Data([2])
        case .point: return Data(bytes(x) + bytes(y) + [UInt8](repeating: 0, count: 13))
        case .hintAE: return Data([8])
        case .commitMetering: return Data([0,2,1,0] + bytes(x) + bytes(y) + [UInt8](repeating: 0, count: 8))
        }
    }

    /// One production submission pass, also usable with fake writes. Lack of
    /// CoreBluetooth credit leaves this step unsent and opens one fixed wait
    /// window; it never puts the frame in a queue or repeats an earlier step.
    /// The caller holds the final session/capture permit around this method.
    mutating func submitNextIfReady(hasCredit: Bool, maximumWriteBytes: Int, at now: TimeInterval,
                                   write: (DUMLFrame, Data) -> Void) throws -> Bool {
        tick(at: now)
        guard result.end == nil, let step = nextStep,
              let index = result.steps.firstIndex(where: { $0.step == step }) else { return false }
        guard hasCredit else {
            if result.steps[index].creditWaitStartedUptime == nil {
                result.steps[index].creditWaitStartedUptime = now
                result.steps[index].creditWaitDeadlineUptime = now + Self.creditWaitTimeout
                result.steps[index].creditWaitReason = "corebluetooth_without_response_credit"
            }
            return false
        }
        let frame = frame(for: step), data = try DUMLCodec.encode(frame)
        guard maximumWriteBytes >= data.count else {
            throw BridgeFailure("bluetooth_focus_mtu", "The focus step must fit one whole BLE write")
        }
        try submitted(step, at: now)
        if result.steps[index].creditWaitStartedUptime != nil {
            result.steps[index].creditWaitEndedUptime = now
            result.steps[index].creditWaitOutcome = "credit_restored"
        }
        write(frame, data)
        return true
    }

    mutating func submitted(_ step: BluetoothTapFocusStep, at now: TimeInterval) throws {
        tick(at: now)
        guard result.end == nil, nextStep == step, result.baseline.isFresh(now: now),
              let index = result.steps.firstIndex(where: { $0.step == step }) else {
            throw BridgeFailure("bluetooth_focus_submission_blocked", "No repeated, expired or out-of-order focus step may be sent")
        }
        result.steps[index].submittedUptime = now; result.steps[index].locallySubmitted = true; lastEvent = now
        result.submittedCount = result.steps.filter { $0.submittedUptime != nil }.count
        result.partialSequence = result.submittedCount > 0 && result.submittedCount < 4
        result.possibleAEsideEffects = result.submittedCount > 0
    }

    mutating func receive(_ packet: ValidatedDUMLPacket, characteristic: String,
        sessionID: UUID, peripheralID: UUID, hostReceivedAt: Date, uptime: TimeInterval) {
        guard result.end == nil else { return }
        guard sessionID == result.request.expectedSessionID,
              peripheralID == result.request.peripheralID else {
            result.foreignSessionNotificationCount =
                (result.foreignSessionNotificationCount ?? 0) + 1
            return
        }
        guard ["FFF4", "FFF5"].contains(characteristic) else {
            result.wrongEnvelopeCount = (result.wrongEnvelopeCount ?? 0) + 1
            return
        }
        tick(at: uptime)
        guard result.end == nil else { return }
        let frame = packet.frame
        let header = BluetoothDUMLHeader(direction: "received", characteristic: characteristic,
            source: frame.source, destination: frame.destination, sequence: frame.sequence,
            flags: frame.flags, commandSet: frame.commandSet, commandID: frame.commandID)
        let isExpectedACKCommand = result.steps.contains {
            $0.commandID == frame.commandID
        }
        if isExpectedACKCommand, frame.commandSet == 2,
           frame.flags == 0x80 || frame.flags == 0xc0 {
            guard frame.source == 1, frame.destination == 2 else {
                result.wrongEnvelopeCount = (result.wrongEnvelopeCount ?? 0) + 1
                result.lastRejectedHeader = header
                return
            }
            guard let index = result.steps.firstIndex(where: {
                $0.sequence == frame.sequence && $0.commandID == frame.commandID
            }), let sent = result.steps[index].submittedUptime,
                  uptime >= sent, result.steps[index].ackUptime == nil else {
                result.wrongSequenceCount = (result.wrongSequenceCount ?? 0) + 1
                result.lastRejectedHeader = header
                return
            }
            result.steps[index].ackHeader = BluetoothDUMLHeader(direction: "received", characteristic: characteristic,
                source: frame.source, destination: frame.destination, sequence: frame.sequence,
                flags: frame.flags, commandSet: frame.commandSet, commandID: frame.commandID)
            result.steps[index].ackUptime = uptime; result.steps[index].ackStatus = frame.payload.first
            result.steps[index].ackPayloadBytes = frame.payload.count
            result.steps[index].ackPayloadPrefixHex = frame.payload.prefix(16).map { String(format: "%02x", $0) }.joined()
            result.steps[index].ackLate = uptime - sent > Self.acknowledgmentTimeout
            result.steps[index].acknowledged = frame.payload.first == 0 && !result.steps[index].ackLate
            lastEvent = uptime
            if frame.payload.first == nil { finish(at: uptime, reason: .invalidACK, failure: "empty_camera_ack"); return }
            if frame.payload.first != 0 { finish(at: uptime, reason: .nack, failure: "camera_nack"); return }
            result.sequenceAcknowledged = result.steps.dropFirst().allSatisfy(\.acknowledged)
            if index == 3, result.steps[index].acknowledged { observationDeadline = uptime + Self.readbackDuration }
            return
        }
        guard frame.commandSet == 0, frame.commandID == 0x99 else { return }
        guard frame.source == 0x28, frame.destination == 2, frame.flags == 0,
              frame.commandSet == 0, frame.commandID == 0x99,
              let pointSubmitted = result.steps[1].submittedUptime, uptime > pointSubmitted,
              hostReceivedAt.timeIntervalSinceReferenceDate.isFinite,
              result.lensPoints.count + result.invalidLensCandidates < Self.maximumLensPoints,
              let push = try? CameraPropertyCodec.decodePush(from: frame) else {
            result.wrongEnvelopeCount = (result.wrongEnvelopeCount ?? 0) + 1
            result.lastRejectedHeader = header
            return
        }
        guard push.property == .lensState else {
            result.wrongEnvelopeCount = (result.wrongEnvelopeCount ?? 0) + 1
            result.lastRejectedHeader = header
            return
        }
        let fingerprint = Data(SHA256.hash(data: packet.frameData))
        guard !lensFingerprints.contains(fingerprint) else { return }
        if let lastLensSequence {
            let distance = frame.sequence &- lastLensSequence
            guard distance > 0, distance < 0x8000 else {
                result.wrongSequenceCount = (result.wrongSequenceCount ?? 0) + 1
                result.lastRejectedHeader = header
                return
            }
        }
        lensFingerprints.insert(fingerprint); lastLensSequence = frame.sequence; lastEvent = uptime
        guard let candidate = LensPointCandidate.decode(push.value) else { result.invalidLensCandidates += 1; return }
        result.lensPoints.append(BluetoothFocusPointObservation(sessionID: sessionID, peripheralID: peripheralID,
            sequence: frame.sequence, propertyTransactionID: push.transactionID, candidate: candidate,
            hostReceivedAt: hostReceivedAt, receivedUptime: uptime))
    }

    mutating func tick(at now: TimeInterval) {
        guard result.end == nil else { return }
        guard validTime(now), now >= lastEvent else { finish(at: lastEvent, reason: .invalidClock); return }
        for index in result.steps.indices {
            if let waitStarted = result.steps[index].creditWaitStartedUptime,
               result.steps[index].creditWaitEndedUptime == nil {
                result.steps[index].creditWaitDurationSeconds = now - waitStarted
                if let deadline = result.steps[index].creditWaitDeadlineUptime, now >= deadline {
                    finish(at: now, reason: .creditTimeout, failure: "bluetooth_focus_credit_timeout")
                    return
                }
            }
            if let sent = result.steps[index].submittedUptime, result.steps[index].ackUptime == nil,
               now - sent > Self.acknowledgmentTimeout {
                result.steps[index].ackTimedOut = true
                if index != 0 { finish(at: now, reason: .ackTimeout, failure: result.steps[index].step.rawValue); return }
            }
        }
        if let deadline = observationDeadline, now >= deadline { finish(at: now, reason: .observationComplete); return }
        if now - result.startedUptime >= Self.maximumDuration { finish(at: now, reason: .overallTimeout); return }
        lastEvent = now
    }
    @discardableResult
    mutating func finish(at now: TimeInterval, reason: BluetoothTapFocusEnd, failure: String? = nil) -> BluetoothTapFocusResult {
        guard result.end == nil else { return result }
        result.finishedUptime = validTime(now) && now >= lastEvent ? now : lastEvent
        for index in result.steps.indices {
            if let started = result.steps[index].creditWaitStartedUptime,
               result.steps[index].creditWaitEndedUptime == nil {
                result.steps[index].creditWaitEndedUptime = result.finishedUptime
                result.steps[index].creditWaitDurationSeconds = max(0, result.finishedUptime! - started)
                result.steps[index].creditWaitOutcome = reason.rawValue
            }
        }
        result.end = reason; result.failure = failure.map { String($0.prefix(128)) }
        return result
    }
}

private func validTime(_ value: TimeInterval) -> Bool {
    value.isFinite && value >= 0 && value + BluetoothTapFocusProbe.maximumDuration > value
}
