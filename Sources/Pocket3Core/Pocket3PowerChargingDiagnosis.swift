import Foundation

// MARK: - Power and charging diagnosis

/// A diagnosis is deliberately separate from `USBPowerStatus.chargingState`:
/// macOS USB allocation properties do not report the camera's battery state.
public enum Pocket3PowerChargingDiagnosisState: String, Codable, Sendable,
    Equatable, CaseIterable {
    case charging
    case fullNotCharging = "full_not_charging"
    case connectedNotCharging = "connected_not_charging"
    case insufficientPowerCandidate = "insufficient_power_candidate"
    case telemetryStale = "telemetry_stale"
    case unknown
}

public enum Pocket3PowerChargingDiagnosisReason: String, Codable, Sendable,
    Equatable, CaseIterable {
    case chargingReported = "charging_reported"
    case fullBatteryNotCharging = "full_battery_not_charging"
    case connectedNotCharging = "connected_not_charging"
    case batteryDecliningWhileNotCharging = "battery_declining_while_not_charging"
    case powerAllocationFailedAndBatteryDeclining = "power_allocation_failed_and_battery_declining"
    case powerAllocationFailed = "power_allocation_failed"
    case telemetryStale = "telemetry_stale"
    case noUSBConnection = "no_usb_connection"
    case chargingStateUnknown = "charging_state_unknown"
    case sessionMismatch = "session_mismatch"
    case invalidUSBPower = "invalid_usb_power"
    case invalidBatterySample = "invalid_battery_sample"
    case invalidClock = "invalid_clock"
}

/// Exact USB facts available from the matched Pocket 3 registry entry. The
/// allocation is an OS request/description, never a current measurement.
public struct Pocket3PowerChargingUSBInput: Codable, Sendable, Equatable,
    Hashable {
    public let present: Bool
    public let configuredMilliamps: Int?
    public let linkBitsPerSecond: Int64?
    public let allocationFailed: Bool?

    public init(present: Bool, configuredMilliamps: Int? = nil,
                linkBitsPerSecond: Int64? = nil,
                allocationFailed: Bool? = nil) {
        self.present = present
        self.configuredMilliamps = configuredMilliamps
        self.linkBitsPerSecond = linkBitsPerSecond
        self.allocationFailed = allocationFailed
    }

    public init(_ status: USBPowerStatus?) {
        self.init(present: status?.present == true,
                  configuredMilliamps: status?.configuredMilliamps,
                  linkBitsPerSecond: status?.linkBitsPerSecond,
                  allocationFailed: status?.isPowerAllocationFailed)
    }

    public var isWellFormed: Bool {
        (configuredMilliamps == nil || configuredMilliamps! >= 0) &&
            (linkBitsPerSecond == nil || linkBitsPerSecond! > 0)
    }
}

/// One raw BLE battery observation. The binding is part of the sample so an
/// old peer cannot contribute to the current camera's power diagnosis.
public struct Pocket3PowerChargingBatterySample: Codable, Sendable,
    Equatable, Hashable {
    public let sessionID: UUID
    public let peripheralID: UUID
    public let percent: Int
    public let chargingRaw: UInt8?
    public let receivedUptime: TimeInterval

    public init(sessionID: UUID, peripheralID: UUID, percent: Int,
                chargingRaw: UInt8?, receivedUptime: TimeInterval) {
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.percent = percent
        self.chargingRaw = chargingRaw
        self.receivedUptime = receivedUptime
    }

    public init(_ observation: BluetoothBatteryObservation,
                receivedUptime: TimeInterval) {
        self.init(sessionID: observation.sessionID,
                  peripheralID: observation.peripheralID,
                  percent: observation.telemetry.percent,
                  chargingRaw: observation.telemetry.chargingStateRaw,
                  receivedUptime: receivedUptime)
    }

    public var isWellFormed: Bool {
        (0...100).contains(percent) && receivedUptime.isFinite &&
            receivedUptime >= 0
    }

    public var chargingState: Pocket3ChargingState? {
        switch chargingRaw {
        case 0: .notCharging
        case 1: .charging
        default: nil
        }
    }
}

/// Reducer input. `sessionID`/`peripheralID` identify the currently selected
/// BLE session; `battery` must carry the same pair before it is admitted.
public struct Pocket3PowerChargingInput: Codable, Sendable, Equatable,
    Hashable {
    public let usb: Pocket3PowerChargingUSBInput
    public let sessionID: UUID?
    public let peripheralID: UUID?
    public let battery: Pocket3PowerChargingBatterySample?
    public let nowUptime: TimeInterval

    public init(usb: Pocket3PowerChargingUSBInput,
                sessionID: UUID?, peripheralID: UUID?,
                battery: Pocket3PowerChargingBatterySample?,
                nowUptime: TimeInterval) {
        self.usb = usb
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.battery = battery
        self.nowUptime = nowUptime
    }

    /// Bridges existing status objects without creating Bluetooth or USB
    /// resources. The wall-clock age is converted to the caller's monotonic
    /// uptime only for freshness comparison; the exact peer/session IDs stay
    /// untouched.
    public init(usb: USBPowerStatus?, battery: BluetoothBatteryObservation?,
                now: Date = Date(), nowUptime: TimeInterval) {
        self.usb = Pocket3PowerChargingUSBInput(usb)
        self.sessionID = battery?.sessionID
        self.peripheralID = battery?.peripheralID
        if let battery {
            let age = now.timeIntervalSince(battery.telemetry.receivedAt)
            let receivedUptime = nowUptime - age
            self.battery = Pocket3PowerChargingBatterySample(
                sessionID: battery.sessionID, peripheralID: battery.peripheralID,
                percent: battery.telemetry.percent,
                chargingRaw: battery.telemetry.chargingStateRaw,
                receivedUptime: receivedUptime)
        } else {
            self.battery = nil
        }
        self.nowUptime = nowUptime
    }
}

public struct Pocket3PowerChargingDiagnosis: Codable, Sendable, Equatable,
    Hashable {
    public let state: Pocket3PowerChargingDiagnosisState
    public let reason: Pocket3PowerChargingDiagnosisReason
    public let usbPresent: Bool
    public let configuredMilliamps: Int?
    public let linkBitsPerSecond: Int64?
    public let allocationFailed: Bool?
    public let sessionID: UUID?
    public let peripheralID: UUID?
    public let batteryPercent: Int?
    public let chargingRaw: UInt8?
    public let batteryFresh: Bool
    public let sampleCount: Int
    public let observedDropPercent: Int?
    public let trendDuration: TimeInterval?
    public let historyReset: Bool
    public let evaluatedUptime: TimeInterval

    public var needsAttention: Bool {
        state == .telemetryStale || state == .insufficientPowerCandidate ||
            reason == .powerAllocationFailed
    }

    public var warning: Bool { needsAttention }

    public var charging: Bool { state == .charging }
    public var fullNotCharging: Bool { state == .fullNotCharging }
    public var connectedNotCharging: Bool { state == .connectedNotCharging }
    public var insufficientPowerCandidate: Bool {
        state == .insufficientPowerCandidate
    }

    public init(state: Pocket3PowerChargingDiagnosisState,
                reason: Pocket3PowerChargingDiagnosisReason,
                usb: Pocket3PowerChargingUSBInput,
                sessionID: UUID?, peripheralID: UUID?,
                battery: Pocket3PowerChargingBatterySample?,
                batteryFresh: Bool, sampleCount: Int,
                observedDropPercent: Int?, trendDuration: TimeInterval?,
                historyReset: Bool, evaluatedUptime: TimeInterval) {
        self.state = state
        self.reason = reason
        usbPresent = usb.present
        configuredMilliamps = usb.configuredMilliamps
        linkBitsPerSecond = usb.linkBitsPerSecond
        allocationFailed = usb.allocationFailed
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        batteryPercent = battery?.percent
        chargingRaw = battery?.chargingRaw
        self.batteryFresh = batteryFresh
        self.sampleCount = sampleCount
        self.observedDropPercent = observedDropPercent
        self.trendDuration = trendDuration
        self.historyReset = historyReset
        self.evaluatedUptime = evaluatedUptime
    }
}

/// Pure reducer for USB/battery diagnosis. It owns only a bounded monotonic
/// time series; it never reads IOKit, CoreBluetooth, or a transport.
public struct Pocket3PowerChargingDiagnosisReducer: Sendable {
    public static let batteryFreshnessInterval: TimeInterval = 5
    public static let trendWindow: TimeInterval = 600
    public static let warningTrendDuration: TimeInterval = 30
    public static let warningTrendDropPercent = 2
    public static let warningMinimumSamples = 3
    public static let recentDeclineInterval: TimeInterval = 60
    public static let maximumSamples = 101

    private struct Binding: Equatable, Sendable {
        let sessionID: UUID
        let peripheralID: UUID
    }

    private var binding: Binding?
    private var samples: [Pocket3PowerChargingBatterySample] = []

    public init() {}

    public var retainedSampleCount: Int { samples.count }
    public var currentSessionID: UUID? { binding?.sessionID }
    public var currentPeripheralID: UUID? { binding?.peripheralID }

    public mutating func reset() {
        binding = nil
        samples.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func reduce(_ input: Pocket3PowerChargingInput)
        -> Pocket3PowerChargingDiagnosis {
        let historyReset = updateBinding(sessionID: input.sessionID,
                                         peripheralID: input.peripheralID)
        guard input.nowUptime.isFinite, input.nowUptime >= 0 else {
            return diagnosis(input, state: .unknown, reason: .invalidClock,
                             battery: nil, fresh: false,
                             historyReset: historyReset)
        }
        guard input.usb.isWellFormed else {
            return diagnosis(input, state: .unknown, reason: .invalidUSBPower,
                             battery: nil, fresh: false,
                             historyReset: historyReset)
        }

        guard let sessionID = input.sessionID,
              let peripheralID = input.peripheralID,
              let battery = input.battery else {
            return diagnosis(input,
                             state: input.usb.present ? .telemetryStale : .unknown,
                             reason: input.usb.present ? .telemetryStale : .noUSBConnection,
                             battery: nil, fresh: false,
                             historyReset: historyReset)
        }
        guard battery.sessionID == sessionID,
              battery.peripheralID == peripheralID else {
            return diagnosis(input, state: input.usb.present ? .telemetryStale : .unknown,
                             reason: .sessionMismatch, battery: battery,
                             fresh: false, historyReset: true)
        }
        guard battery.isWellFormed else {
            return diagnosis(input, state: .unknown,
                             reason: .invalidBatterySample, battery: battery,
                             fresh: false, historyReset: historyReset)
        }
        let age = input.nowUptime - battery.receivedUptime
        guard age.isFinite, age >= 0,
              age <= Self.batteryFreshnessInterval else {
            return diagnosis(input, state: .telemetryStale,
                             reason: .telemetryStale, battery: battery,
                             fresh: false, historyReset: historyReset)
        }
        guard let chargingRaw = battery.chargingRaw,
              chargingRaw == 0 || chargingRaw == 1 else {
            return diagnosis(input, state: .unknown,
                             reason: .chargingStateUnknown, battery: battery,
                             fresh: true, historyReset: historyReset)
        }

        admit(battery, nowUptime: input.nowUptime)
        let trend = trend(nowUptime: input.nowUptime)
        let state: Pocket3PowerChargingDiagnosisState
        let reason: Pocket3PowerChargingDiagnosisReason
        switch chargingRaw {
        case 1:
            state = .charging
            reason = .chargingReported
        case 0 where battery.percent >= 100:
            state = .fullNotCharging
            reason = .fullBatteryNotCharging
        case 0 where input.usb.present && trend.qualifies:
            state = .insufficientPowerCandidate
            reason = input.usb.allocationFailed == true
                ? .powerAllocationFailedAndBatteryDeclining
                : .batteryDecliningWhileNotCharging
        case 0 where input.usb.present:
            state = .connectedNotCharging
            reason = input.usb.allocationFailed == true
                ? .powerAllocationFailed : .connectedNotCharging
        default:
            state = .unknown
            reason = .noUSBConnection
        }
        return diagnosis(input, state: state, reason: reason,
                         battery: battery, fresh: true,
                         drop: trend.drop, duration: trend.duration,
                         historyReset: historyReset)
    }

    private mutating func updateBinding(sessionID: UUID?, peripheralID: UUID?) -> Bool {
        guard let sessionID, let peripheralID else {
            let changed = binding != nil || !samples.isEmpty
            binding = nil
            samples.removeAll(keepingCapacity: true)
            return changed
        }
        let next = Binding(sessionID: sessionID, peripheralID: peripheralID)
        guard binding != next else { return false }
        binding = next
        samples.removeAll(keepingCapacity: true)
        return true
    }

    private mutating func admit(_ sample: Pocket3PowerChargingBatterySample,
                                nowUptime: TimeInterval) {
        guard let previous = samples.last else {
            samples = [sample]
            return
        }
        if sample.receivedUptime < previous.receivedUptime ||
            sample.percent > previous.percent {
            // A reversed timestamp or rebound cannot extend a decline trend.
            samples = [sample]
            return
        }
        if sample.receivedUptime == previous.receivedUptime {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        let cutoff = nowUptime - Self.trendWindow
        samples.removeAll { $0.receivedUptime < cutoff }
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }

    private func trend(nowUptime: TimeInterval)
        -> (qualifies: Bool, drop: Int?, duration: TimeInterval?) {
        guard let first = samples.first, let last = samples.last,
              samples.count >= 2 else { return (false, nil, nil) }
        let duration = last.receivedUptime - first.receivedUptime
        let drop = first.percent - last.percent
        let lastAge = nowUptime - last.receivedUptime
        let qualifies = samples.count >= Self.warningMinimumSamples &&
            drop >= Self.warningTrendDropPercent &&
            duration >= Self.warningTrendDuration &&
            lastAge >= 0 && lastAge <= Self.recentDeclineInterval
        return (qualifies, drop, duration)
    }

    private func diagnosis(
        _ input: Pocket3PowerChargingInput,
        state: Pocket3PowerChargingDiagnosisState,
        reason: Pocket3PowerChargingDiagnosisReason,
        battery: Pocket3PowerChargingBatterySample?,
        fresh: Bool,
        drop: Int? = nil,
        duration: TimeInterval? = nil,
        historyReset: Bool
    ) -> Pocket3PowerChargingDiagnosis {
        Pocket3PowerChargingDiagnosis(
            state: state, reason: reason, usb: input.usb,
            sessionID: input.sessionID, peripheralID: input.peripheralID,
            battery: battery, batteryFresh: fresh,
            sampleCount: samples.count, observedDropPercent: drop,
            trendDuration: duration, historyReset: historyReset,
            evaluatedUptime: input.nowUptime)
    }
}

public typealias Pocket3PowerChargingReducer = Pocket3PowerChargingDiagnosisReducer
public typealias Pocket3PowerDiagnosis = Pocket3PowerChargingDiagnosis
