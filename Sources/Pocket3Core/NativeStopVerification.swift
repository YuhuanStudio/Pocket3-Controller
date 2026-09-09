import Foundation

/// Native sensor-readback evidence after a neutral command. This is not a
/// mechanical emergency stop, calibrated angle proof, or a target simulation.
public struct Pocket3DatalinkStopResult: Codable, Sendable {
    public var binding: ContinuousGimbalBinding
    public var neutralSent: Bool
    public var stableTelemetry: Bool
    public var timedOut: Bool
    public var replacedByNewMotion: Bool
    public var connectionChanged: Bool
    public var sampleCount: Int
    public var stableDurationSeconds: TimeInterval
    public var elapsedSeconds: TimeInterval
    /// Span within the final candidate/stable window, not total braking travel.
    public var maximumSpanDegrees: Double?
    public var finalTelemetry: Pocket3DatalinkTelemetry?
    public var failure: String?
    public var verification: String = "post_neutral_duml_04_05_stability"

    public init(binding: ContinuousGimbalBinding, neutralSent: Bool = false, stableTelemetry: Bool = false,
                timedOut: Bool = false, replacedByNewMotion: Bool = false, connectionChanged: Bool = false,
                sampleCount: Int = 0, stableDurationSeconds: TimeInterval = 0, elapsedSeconds: TimeInterval = 0,
                maximumSpanDegrees: Double? = nil, finalTelemetry: Pocket3DatalinkTelemetry? = nil, failure: String? = nil) {
        self.binding = binding; self.neutralSent = neutralSent; self.stableTelemetry = stableTelemetry
        self.timedOut = timedOut; self.replacedByNewMotion = replacedByNewMotion; self.connectionChanged = connectionChanged
        self.sampleCount = sampleCount; self.stableDurationSeconds = stableDurationSeconds; self.elapsedSeconds = elapsedSeconds
        self.maximumSpanDegrees = maximumSpanDegrees; self.finalTelemetry = finalTelemetry; self.failure = failure
    }
}

enum NativeStopReceiveIdentity: Hashable, Sendable {
    case udp(packetSequence: UInt16, messageSequence: UInt16)
    case bluetooth(source: UInt8, messageSequence: UInt16)

    fileprivate enum Domain: Equatable { case udp, bluetooth(UInt8) }
    fileprivate var domain: Domain {
        switch self {
        case .udp: .udp
        case .bluetooth(let source, _): .bluetooth(source)
        }
    }
}

/// Pure, bounded reducer fed only by actual decoded 04/05 receive callbacks.
/// Transport-native sequence identities prevent duplicate packets adding samples;
/// strictly increasing host receive times prevent repeated snapshot polling
/// from manufacturing the duration needed for a stable window.
struct NativeStopTelemetryVerifier {
    static let maximumDuration: TimeInterval = 1.5
    static let minimumStableDuration: TimeInterval = 0.2
    static let maximumSpanDegrees = 0.25
    static let minimumSamples = 3
    static let maximumSampleAge: TimeInterval = 0.35
    private let neutralSentUptime: TimeInterval
    private var identities: Set<NativeStopReceiveIdentity> = []
    private var identityDomain: NativeStopReceiveIdentity.Domain?
    private var lastUptime: TimeInterval?
    private var lastReceiveDate: Date?
    private var windowStart: TimeInterval?
    private var windowCount = 0
    private var anchor: [Double] = []
    private var minimum: [Double] = []
    private var maximum: [Double] = []
    private(set) var sampleCount = 0
    private(set) var finalTelemetry: Pocket3DatalinkTelemetry?
    var stableDurationSeconds: TimeInterval {
        guard let first = windowStart, let last = lastUptime else { return 0 }
        return max(0, last - first)
    }
    var maximumObservedSpan: Double? {
        guard windowCount > 0 else { return nil }
        return zip(minimum, maximum).map { $1 - $0 }.max()
    }
    init(neutralSentUptime: TimeInterval) { self.neutralSentUptime = neutralSentUptime }

    mutating func receive(_ telemetry: Pocket3DatalinkTelemetry, receivedUptime: TimeInterval,
                          packetSequence: UInt16, messageSequence: UInt16, now: TimeInterval) {
        receive(telemetry, receivedUptime: receivedUptime,
            identity: .udp(packetSequence: packetSequence, messageSequence: messageSequence), now: now)
    }

    mutating func receive(_ telemetry: Pocket3DatalinkTelemetry, receivedUptime: TimeInterval,
                          identity: NativeStopReceiveIdentity, now: TimeInterval) {
        let values = [telemetry.pitchDegrees, telemetry.rollDegrees, telemetry.yawDegrees]
        guard neutralSentUptime.isFinite, now.isFinite, receivedUptime.isFinite,
              receivedUptime > neutralSentUptime, receivedUptime <= now,
              now - receivedUptime <= Self.maximumSampleAge,
              receivedUptime - neutralSentUptime <= Self.maximumDuration,
              telemetry.receivedAt.timeIntervalSinceReferenceDate.isFinite,
              lastReceiveDate == nil || telemetry.receivedAt > lastReceiveDate!,
              values.allSatisfy({ $0.isFinite && abs($0) <= 360 }),
              lastUptime == nil || receivedUptime > lastUptime!,
              identityDomain == nil || identityDomain == identity.domain,
              identities.count < 128, !identities.contains(identity) else { return }
        identities.insert(identity); identityDomain = identity.domain; sampleCount += 1
        let gapExpired = lastUptime.map { receivedUptime - $0 > Self.maximumSampleAge } ?? false
        if windowCount == 0 || gapExpired {
            resetWindow(values, at: receivedUptime)
        } else {
            let deltas = zip(values, anchor).map { Self.wrappedDifference($0, $1) }
            let lower = zip(minimum, deltas).map { min($0, $1) }
            let upper = zip(maximum, deltas).map { max($0, $1) }
            if zip(lower, upper).contains(where: { $1 - $0 > Self.maximumSpanDegrees + 1e-9 }) {
                resetWindow(values, at: receivedUptime)
            } else {
                minimum = lower; maximum = upper; windowCount += 1
            }
        }
        lastUptime = receivedUptime; lastReceiveDate = telemetry.receivedAt; finalTelemetry = telemetry
    }
    func isStable(now: TimeInterval) -> Bool {
        guard now.isFinite, let lastUptime, now >= lastUptime,
              now - lastUptime <= Self.maximumSampleAge else { return false }
        return windowCount >= Self.minimumSamples && stableDurationSeconds + 1e-9 >= Self.minimumStableDuration
            && (maximumObservedSpan ?? .infinity) <= Self.maximumSpanDegrees + 1e-9
    }
    private mutating func resetWindow(_ values: [Double], at time: TimeInterval) {
        anchor = values; minimum = [0, 0, 0]; maximum = [0, 0, 0]
        windowStart = time; windowCount = 1
    }
    private static func wrappedDifference(_ a: Double, _ b: Double) -> Double {
        var delta = (a - b).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }
}

/// Independent freshness admission for control telemetry, separate from the
/// protocol's receive/ACK cursor processing. Sequence semantics still need
/// live-wire validation; unknown initial zero sequences cannot prove freshness.
struct NativeTelemetrySequenceAdmission {
    private var latest: [UInt8: UInt16] = [:]
    mutating func accept(type: DJIUDPPacketType, sequence: UInt16) -> Bool {
        guard type == .channel3 || type == .command else { return false }
        guard let previous = latest[type.rawValue] else {
            guard sequence != 0 else { return false }
            latest[type.rawValue] = sequence; return true
        }
        let distance = sequence &- previous
        guard distance > 0, distance < 0x8000 else { return false }
        latest[type.rawValue] = sequence
        return true
    }
}

/// BLE has no UDP packet sequence. Feed CRC-validated Pocket 3 source-04
/// gimbal notifications, using their real DUML sequence and a baseline from
/// the same connection. A constant/reordered sequence cannot prove freshness.
struct NativeBLETelemetrySequenceAdmission {
    private(set) var lastAcceptedSequence: UInt16?
    init(baselineSequence: UInt16? = nil) { lastAcceptedSequence = baselineSequence }

    mutating func accept(_ frame: DUMLFrame) -> NativeStopReceiveIdentity? {
        guard BluetoothPoseValues.parse(frame) != nil else { return nil }
        if let previous = lastAcceptedSequence {
            let distance = frame.sequence &- previous
            guard distance > 0, distance < 0x8000 else { return nil }
        }
        lastAcceptedSequence = frame.sequence
        return .bluetooth(source: frame.source, messageSequence: frame.sequence)
    }
}
