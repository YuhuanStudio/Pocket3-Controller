import Foundation

/// One development-only FE08 experiment. No field claims that the native
/// preset is supported, physically centered, or mechanically stopped.
public struct BluetoothNativeRecenterResult: Codable, Sendable {
    public var id = UUID()
    public var querySequence: UInt16
    public var registrationAcknowledgmentSubmitted = false
    public var baselineStable = false
    public var baseline: Pocket3DatalinkTelemetry?
    public var finalPose: Pocket3DatalinkTelemetry?
    public var baselineSampleCount = 0
    public var baselineDurationSeconds: TimeInterval = 0
    public var baselineSampleUptimes: [TimeInterval] = []
    public var movementSampleCount = 0
    public var sampleUptimes: [TimeInterval] = []
    public var sampleTimesTruncated = false
    public var maximumYawDelta: Double = 0
    public var maximumPitchDelta: Double = 0
    public var maximumRollDelta: Double = 0
    public var movementObserved = false
    public var localSubmitted = false
    public var responseReceived = false
    public var replyHeader: BluetoothDUMLHeader?
    /// At most 16 bytes, only from the exact source/sequence/opcode ACK.
    public var payloadHex: String?
    public var payloadByteCount: Int?
    public var payloadTruncated = false
    public var startedUptime: TimeInterval
    public var submittedUptime: TimeInterval?
    public var responseUptime: TimeInterval?
    public var finishedUptime: TimeInterval?
    public var observationWindowCompleted = false
    public var timedOut = false
    public var cancelled = false
    public var connectionChanged = false
    public var failure: String?
    public var interpretation = "single_ble_FE08_submission_reply_and_telemetry_only"

    init(sequence: UInt16, startedUptime: TimeInterval) {
        querySequence = sequence; self.startedUptime = startedUptime
    }
}

/// Pure evidence reducer; no CoreBluetooth, USB, retry, or fallback command.
/// Command provenance: research/native-presets.md (pinned Kaze FE08).
struct BluetoothNativePresetProbe {
    static let frameBytes = 15
    static let minimumBaselineDuration: TimeInterval = 0.5
    static let baselineTimeout: TimeInterval = 1.5
    static let observationDuration: TimeInterval = 3
    static let maximumRecordedTimes = 128
    private var admission = NativeBLETelemetrySequenceAdmission()
    private var baselineVerifier: NativeStopTelemetryVerifier
    private var lastTelemetryUptime: TimeInterval?
    private var lastTelemetryDate: Date?
    private(set) var result: BluetoothNativeRecenterResult

    var request: DUMLFrame {
        DUMLFrame(source: 2, destination: 4, sequence: result.querySequence, flags: 0x40,
            commandSet: 4, commandID: 0x4c, payload: Data([0xfe, 0x08]))
    }

    init(sequence: UInt16, startedUptime: TimeInterval, registrationAcknowledgmentSubmitted: Bool) {
        result = BluetoothNativeRecenterResult(sequence: sequence, startedUptime: startedUptime)
        result.registrationAcknowledgmentSubmitted = registrationAcknowledgmentSubmitted
        baselineVerifier = NativeStopTelemetryVerifier(neutralSentUptime: startedUptime)
    }

    func baselineIsReady(at now: TimeInterval) -> Bool {
        !result.localSubmitted && result.finishedUptime == nil
            && now.isFinite && now >= result.startedUptime
            && now - result.startedUptime <= Self.baselineTimeout
            && baselineVerifier.isStable(now: now)
            && baselineVerifier.stableDurationSeconds + 1e-9 >= Self.minimumBaselineDuration
    }

    /// Called inside the final write permit, immediately before writeValue.
    /// The slot is consumed once; a second call cannot authorize a retry.
    mutating func submitted(at now: TimeInterval) throws {
        guard baselineIsReady(at: now) else {
            throw BridgeFailure("bluetooth_recenter_baseline", "Fresh stable BLE telemetry is required before the single recenter command.")
        }
        result.baselineStable = true; result.baseline = baselineVerifier.finalTelemetry
        result.baselineSampleCount = baselineVerifier.sampleCount
        result.baselineDurationSeconds = baselineVerifier.stableDurationSeconds
        result.localSubmitted = true; result.submittedUptime = now
    }

    mutating func receive(_ data: Data, characteristic: String, receivedAt: Date, uptime: TimeInterval) {
        guard result.finishedUptime == nil, !result.cancelled, !result.connectionChanged,
              uptime.isFinite, uptime > result.startedUptime,
              characteristic == "FFF4" || characteristic == "FFF5",
              let frame = try? DUMLCodec.decode(data) else { return }
        if let submitted = result.submittedUptime {
            guard uptime >= submitted, uptime - submitted <= Self.observationDuration else { return }
            if !result.responseReceived, frame.source == 4, frame.destination == 2,
               frame.commandSet == 4, frame.commandID == 0x4c,
               frame.sequence == result.querySequence, frame.flags == 0x80 || frame.flags == 0xc0 {
                result.responseReceived = true; result.responseUptime = uptime
                result.replyHeader = BluetoothDUMLHeader(direction: "received", characteristic: characteristic,
                    source: frame.source, destination: frame.destination, sequence: frame.sequence,
                    flags: frame.flags, commandSet: frame.commandSet, commandID: frame.commandID)
                result.payloadByteCount = frame.payload.count
                result.payloadTruncated = frame.payload.count > 16
                result.payloadHex = frame.payload.prefix(16).map { String(format: "%02x", $0) }.joined()
            }
        } else if uptime - result.startedUptime > Self.baselineTimeout { return }

        guard lastTelemetryUptime == nil || uptime > lastTelemetryUptime!,
              receivedAt.timeIntervalSinceReferenceDate.isFinite,
              lastTelemetryDate == nil || receivedAt > lastTelemetryDate!,
              let values = BluetoothPoseValues.parse(frame), let identity = admission.accept(frame) else { return }
        lastTelemetryUptime = uptime; lastTelemetryDate = receivedAt
        let telemetry = values.telemetry(receivedAt: receivedAt)
        if !result.localSubmitted {
            baselineVerifier.receive(telemetry, receivedUptime: uptime, identity: identity, now: uptime)
            if result.baselineSampleUptimes.count < Self.maximumRecordedTimes { result.baselineSampleUptimes.append(uptime) }
            else { result.sampleTimesTruncated = true }
        } else if let baseline = result.baseline, let submitted = result.submittedUptime, uptime > submitted {
            result.finalPose = telemetry; result.movementSampleCount += 1
            if result.sampleUptimes.count < Self.maximumRecordedTimes { result.sampleUptimes.append(uptime) }
            else { result.sampleTimesTruncated = true }
            result.maximumYawDelta = max(result.maximumYawDelta, abs(BluetoothGimbalProbePlan.angleDelta(telemetry.yawDegrees, baseline: baseline.yawDegrees)))
            result.maximumPitchDelta = max(result.maximumPitchDelta, abs(BluetoothGimbalProbePlan.angleDelta(telemetry.pitchDegrees, baseline: baseline.pitchDegrees)))
            result.maximumRollDelta = max(result.maximumRollDelta, abs(BluetoothGimbalProbePlan.angleDelta(telemetry.rollDegrees, baseline: baseline.rollDegrees)))
        }
    }

    mutating func finish(at now: TimeInterval, cancelled: Bool, connectionChanged: Bool, failure: String?) -> BluetoothNativeRecenterResult {
        guard result.finishedUptime == nil else { return result }
        if result.baseline == nil {
            result.baseline = baselineVerifier.finalTelemetry
            result.baselineSampleCount = baselineVerifier.sampleCount
            result.baselineDurationSeconds = baselineVerifier.stableDurationSeconds
        }
        result.finishedUptime = now; result.cancelled = cancelled; result.connectionChanged = connectionChanged
        result.failure = failure
        result.observationWindowCompleted = now.isFinite && !cancelled && !connectionChanged && failure == nil
            && result.submittedUptime.map { now - $0 >= Self.observationDuration } == true
        result.timedOut = result.observationWindowCompleted && !result.responseReceived
        result.movementObserved = max(result.maximumPitchDelta, result.maximumRollDelta, result.maximumYawDelta) >= 0.5
        return result
    }
}
