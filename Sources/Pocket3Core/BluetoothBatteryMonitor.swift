import Foundation

/// A Bluetooth peer's reported battery level, not the USB camera's power state.
/// lowBattery/falling are informational App thresholds, not charging faults.
public struct BluetoothBatteryAssessment: Codable, Sendable, Equatable {
    public let percent: Int
    public let chargingState: Pocket3ChargingState
    public let lowBattery: Bool
    public let falling: Bool
    public let observedDropPercent: Int?
    public let observationDuration: TimeInterval?
    public let receivedAt: Date
    public let sessionID: UUID
    public let peripheralID: UUID

    public init(percent: Int, chargingState: Pocket3ChargingState, lowBattery: Bool, falling: Bool,
                observedDropPercent: Int? = nil, observationDuration: TimeInterval? = nil,
                receivedAt: Date, sessionID: UUID, peripheralID: UUID) {
        self.percent = percent; self.chargingState = chargingState
        self.lowBattery = lowBattery; self.falling = falling
        self.observedDropPercent = observedDropPercent; self.observationDuration = observationDuration
        self.receivedAt = receivedAt; self.sessionID = sessionID; self.peripheralID = peripheralID
    }
    public var needsAttention: Bool { lowBattery || falling }
    public func isFresh(now: Date) -> Bool {
        let age = now.timeIntervalSince(receivedAt)
        return age.isFinite && age >= 0 && age <= BluetoothBatteryMonitor.freshnessInterval
    }
}

/// Value-only policy. It neither scans nor connects, reads USB state, or infers
/// external power. Non-increasing percentage levels bound history to 101 entries.
public struct BluetoothBatteryMonitor: Sendable {
    public static let freshnessInterval: TimeInterval = 5
    public static let lowBatteryThreshold = 20
    private static let minimumTrendDuration: TimeInterval = 30
    private static let maximumWindow: TimeInterval = 600
    private static let recentDeclineInterval: TimeInterval = 60

    private struct Binding: Equatable, Sendable {
        let sessionID: UUID
        let peripheralID: UUID
    }
    private struct Sample: Sendable {
        let percent: Int
        let receivedAt: Date
    }
    private struct Level: Sendable {
        let percent: Int
        var firstReceivedAt: Date
        var lastReceivedAt: Date
    }
    private var binding: Binding?
    private var latest: Sample?
    private var lastUpdateAt: Date?
    private var levels: [Level] = []
    var retainedLevelCount: Int { levels.count }

    public init() {}

    public mutating func update(observation: BluetoothBatteryObservation?, sessionID: UUID,
                                peripheralID: UUID?, now: Date) -> BluetoothBatteryAssessment? {
        guard now.timeIntervalSinceReferenceDate.isFinite, let peripheralID, let observation,
              observation.sessionID == sessionID, observation.peripheralID == peripheralID,
              observation.telemetry.source == .bluetooth, (0...100).contains(observation.telemetry.percent),
              observation.telemetry.receivedAt.timeIntervalSinceReferenceDate.isFinite,
              observation.telemetry.isFresh(now: now, maxAge: Self.freshnessInterval) else {
            self = Self()
            return nil
        }
        let expected = Binding(sessionID: sessionID, peripheralID: peripheralID)
        let sample = Sample(percent: observation.telemetry.percent, receivedAt: observation.telemetry.receivedAt)
        let clockMovedBack = lastUpdateAt.map { now < $0 } ?? false
        if binding != expected || latest == nil || clockMovedBack {
            seed(sample, binding: expected, now: now)
            return assessment(observation, now: now)
        }
        guard let previous = latest else { return nil }
        let gap = sample.receivedAt.timeIntervalSince(previous.receivedAt)
        // A fresh current sample cannot establish what happened across a gap,
        // a reversed receive clock, or a percentage rebound.
        if gap < 0 || gap > Self.freshnessInterval || sample.percent > previous.percent {
            seed(sample, binding: expected, now: now)
            return assessment(observation, now: now)
        }
        lastUpdateAt = now
        if gap == 0 {
            // Contradictory values stamped at the same instant are not two
            // independent observations. Keep the latest value as a new base.
            if sample.percent != previous.percent { seed(sample, binding: expected, now: now) }
            return assessment(observation, now: now)
        }
        if sample.percent == previous.percent {
            levels[levels.count - 1].lastReceivedAt = sample.receivedAt
        } else {
            levels.append(Level(percent: sample.percent, firstReceivedAt: sample.receivedAt, lastReceivedAt: sample.receivedAt))
        }
        latest = sample
        trim(endingAt: sample.receivedAt)
        return assessment(observation, now: now)
    }

    private mutating func seed(_ sample: Sample, binding: Binding, now: Date) {
        self.binding = binding; latest = sample; lastUpdateAt = now
        levels = [Level(percent: sample.percent, firstReceivedAt: sample.receivedAt, lastReceivedAt: sample.receivedAt)]
    }
    private mutating func trim(endingAt time: Date) {
        let cutoff = time.addingTimeInterval(-Self.maximumWindow)
        while let first = levels.first, first.lastReceivedAt < cutoff { levels.removeFirst() }
        if !levels.isEmpty, levels[0].firstReceivedAt < cutoff {
            // Use a real accepted plateau sample, never fabricate a timestamp
            // at the cutoff. This may conservatively shorten the trend span.
            levels[0].firstReceivedAt = levels[0].lastReceivedAt
        }
    }
    private func assessment(_ observation: BluetoothBatteryObservation, now: Date) -> BluetoothBatteryAssessment {
        let telemetry = observation.telemetry
        var drop: Int?
        var duration: TimeInterval?
        var falling = false
        if levels.count >= 2, let first = levels.first, let last = levels.last {
            drop = first.percent - last.percent
            // Equal-value updates keep the stream fresh but do not turn two
            // quick fluctuations into a >=30-second decline merely by waiting.
            let elapsed = last.firstReceivedAt.timeIntervalSince(first.firstReceivedAt)
            if elapsed.isFinite, elapsed >= 0, elapsed <= Self.maximumWindow {
                duration = elapsed
                let lastDeclineAge = now.timeIntervalSince(last.firstReceivedAt)
                falling = levels.count >= 3 && (drop ?? 0) >= 2 && elapsed >= Self.minimumTrendDuration
                    && lastDeclineAge.isFinite && lastDeclineAge >= 0 && lastDeclineAge <= Self.recentDeclineInterval
            }
        }
        return BluetoothBatteryAssessment(percent: telemetry.percent, chargingState: telemetry.chargingState,
            lowBattery: telemetry.percent <= Self.lowBatteryThreshold, falling: falling,
            observedDropPercent: drop, observationDuration: duration,
            receivedAt: telemetry.receivedAt, sessionID: observation.sessionID, peripheralID: observation.peripheralID)
    }
}
