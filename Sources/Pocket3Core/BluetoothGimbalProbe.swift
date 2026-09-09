import Foundation

/// One fixed developer experiment, not a production BLE velocity capability.
public struct BluetoothGimbalProbeResult: Codable, Sendable {
    public var id = UUID()
    public var registrationAcknowledgmentSubmitted = false
    public var baselineStable = false
    public var baseline: Pocket3DatalinkTelemetry?
    public var finalPose: Pocket3DatalinkTelemetry?
    public var baselineSampleCount = 0
    public var baselineDurationSeconds: Double = 0
    public var movementSampleCount = 0
    public var yawDelta: Double?
    public var maximumYawDelta: Double = 0
    public var maximumPitchDelta: Double = 0
    public var maximumRollDelta: Double = 0
    public var movementObserved = false
    public var nonNeutralFramesSent = 0
    public var pulseSubmissionOffsets: [Double] = []
    public var neutralSent = false
    public var stableTelemetry = false
    public var postNeutralSampleCount = 0
    public var postNeutralStableDurationSeconds: Double = 0
    public var postNeutralMaximumSpanDegrees: Double?
    public var startedUptime: Double
    public var pulseStartedUptime: Double?
    public var neutralUptime: Double?
    public var finishedUptime: Double?
    public var cancelled = false
    public var connectionChanged = false
    public var failure: String?
    public var passed = false
    public var submissionEvidence = "corebluetooth_without_response_local_submission"

    init(startedUptime: Double) { self.startedUptime = startedUptime }
}

enum BluetoothGimbalProbePlan {
    static let offsets: [TimeInterval] = [0, 0.05, 0.10, 0.15]
    static let neutralOffset: TimeInterval = 0.20
    static let maximumLateness: TimeInterval = 0.020
    static let minimumBaselineDuration: TimeInterval = 0.50
    static let baselineTimeout: TimeInterval = 1.50
    static let minimumYawMovement: Double = 0.50
    static let neutralSubmissionTimeout: TimeInterval = 0.75
    static let postNeutralTimeout: TimeInterval = 1.50
    static let frameBytes = 23

    static func pulse(sequence: UInt16) throws -> Data {
        try DUMLJoystickCommand.encode(x: 1, y: 0, speed: 0.1).encodedFrame(sequence: sequence)
    }
    static func isOnTime(now: TimeInterval, planned: TimeInterval) -> Bool {
        now.isFinite && planned.isFinite && now >= planned && now - planned <= maximumLateness
    }
    static func angleDelta(_ value: Double, baseline: Double) -> Double {
        var difference = (value - baseline).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference < -180 { difference += 360 }
        return difference
    }
}

/// Fed only by validated, newly admitted BLE 04/05 notifications. The same BLE
/// sequence admission spans baseline, pulse and stop; no UDP IDs are invented.
struct BluetoothGimbalProbeEvidence {
    private var admission = NativeBLETelemetrySequenceAdmission()
    private var baselineVerifier: NativeStopTelemetryVerifier
    private var stopVerifier: NativeStopTelemetryVerifier?
    private var timingValid = true
    private var plannedPulseStart: TimeInterval?
    private var lastTelemetryUptime: TimeInterval?
    private var lastTelemetryDate: Date?
    private(set) var result: BluetoothGimbalProbeResult

    init(startedUptime: TimeInterval, registrationAcknowledgmentSubmitted: Bool) {
        result = BluetoothGimbalProbeResult(startedUptime: startedUptime)
        result.registrationAcknowledgmentSubmitted = registrationAcknowledgmentSubmitted
        baselineVerifier = NativeStopTelemetryVerifier(neutralSentUptime: startedUptime)
    }

    mutating func receive(_ frame: DUMLFrame, receivedAt: Date, uptime: TimeInterval) {
        guard uptime.isFinite, uptime > result.startedUptime,
              lastTelemetryUptime == nil || uptime > lastTelemetryUptime!,
              receivedAt.timeIntervalSinceReferenceDate.isFinite,
              lastTelemetryDate == nil || receivedAt > lastTelemetryDate! else { return }
        guard let values = BluetoothPoseValues.parse(frame), let identity = admission.accept(frame) else { return }
        lastTelemetryUptime = uptime; lastTelemetryDate = receivedAt
        let telemetry = values.telemetry(receivedAt: receivedAt)
        if plannedPulseStart == nil {
            baselineVerifier.receive(telemetry, receivedUptime: uptime, identity: identity, now: uptime)
        } else if result.nonNeutralFramesSent > 0, let baseline = result.baseline {
            result.finalPose = telemetry; result.movementSampleCount += 1
            let yaw = BluetoothGimbalProbePlan.angleDelta(telemetry.yawDegrees, baseline: baseline.yawDegrees)
            result.yawDelta = yaw
            result.maximumYawDelta = max(result.maximumYawDelta, abs(yaw))
            result.maximumPitchDelta = max(result.maximumPitchDelta,
                abs(BluetoothGimbalProbePlan.angleDelta(telemetry.pitchDegrees, baseline: baseline.pitchDegrees)))
            result.maximumRollDelta = max(result.maximumRollDelta,
                abs(BluetoothGimbalProbePlan.angleDelta(telemetry.rollDegrees, baseline: baseline.rollDegrees)))
            stopVerifier?.receive(telemetry, receivedUptime: uptime, identity: identity, now: uptime)
        }
    }

    func baselineIsReady(at now: TimeInterval) -> Bool {
        baselineVerifier.isStable(now: now)
            && baselineVerifier.stableDurationSeconds + 1e-9 >= BluetoothGimbalProbePlan.minimumBaselineDuration
    }
    func hasFreshTelemetry(at now: TimeInterval) -> Bool {
        guard let lastTelemetryUptime, now.isFinite, now >= lastTelemetryUptime else { return false }
        return now - lastTelemetryUptime <= NativeStopTelemetryVerifier.maximumSampleAge
    }
    mutating func beginPulse(at now: TimeInterval) throws {
        guard baselineIsReady(at: now), plannedPulseStart == nil else {
            throw BridgeFailure("bluetooth_probe_baseline", "Fresh stable BLE gimbal telemetry is required before the probe.")
        }
        result.baselineStable = true; result.baseline = baselineVerifier.finalTelemetry
        result.baselineSampleCount = baselineVerifier.sampleCount
        result.baselineDurationSeconds = baselineVerifier.stableDurationSeconds
        plannedPulseStart = now; result.pulseStartedUptime = now
    }
    mutating func pulseSubmitted(index: Int, at now: TimeInterval) throws {
        guard let start = plannedPulseStart, index == result.nonNeutralFramesSent,
              BluetoothGimbalProbePlan.offsets.indices.contains(index),
              BluetoothGimbalProbePlan.isOnTime(now: now, planned: start + BluetoothGimbalProbePlan.offsets[index]) else {
            timingValid = false
            throw BridgeFailure("bluetooth_probe_timing", "The fixed pulse timing was missed; the probe will not catch up or retry.")
        }
        result.nonNeutralFramesSent += 1
        result.pulseSubmissionOffsets.append(now - start)
    }
    mutating func neutralSubmitted(at now: TimeInterval) {
        guard !result.neutralSent else { return }
        result.neutralSent = true; result.neutralUptime = now
        stopVerifier = NativeStopTelemetryVerifier(neutralSentUptime: now)
        if let start = plannedPulseStart,
           !BluetoothGimbalProbePlan.isOnTime(now: now, planned: start + BluetoothGimbalProbePlan.neutralOffset) { timingValid = false }
    }
    func stopIsStable(at now: TimeInterval) -> Bool { stopVerifier?.isStable(now: now) == true }
    mutating func finish(at now: TimeInterval, cancelled: Bool, connectionChanged: Bool, failure: String?) -> BluetoothGimbalProbeResult {
        if result.baseline == nil {
            result.baseline = baselineVerifier.finalTelemetry
            result.baselineSampleCount = baselineVerifier.sampleCount
            result.baselineDurationSeconds = baselineVerifier.stableDurationSeconds
        }
        result.finishedUptime = now; result.cancelled = cancelled; result.connectionChanged = connectionChanged
        result.failure = failure
        result.stableTelemetry = stopIsStable(at: now) && !connectionChanged
        result.postNeutralSampleCount = stopVerifier?.sampleCount ?? 0
        result.postNeutralStableDurationSeconds = stopVerifier?.stableDurationSeconds ?? 0
        result.postNeutralMaximumSpanDegrees = stopVerifier?.maximumObservedSpan
        result.movementObserved = result.maximumYawDelta >= BluetoothGimbalProbePlan.minimumYawMovement
        result.passed = result.registrationAcknowledgmentSubmitted && result.baselineStable
            && result.nonNeutralFramesSent == 4 && timingValid && result.neutralSent
            && result.movementObserved && result.stableTelemetry
            && !cancelled && !connectionChanged && failure == nil
        return result
    }
}
