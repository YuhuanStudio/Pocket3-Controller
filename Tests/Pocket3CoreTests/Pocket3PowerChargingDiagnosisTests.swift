import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 power and charging diagnosis")
struct Pocket3PowerChargingDiagnosisTests {
    private let sessionID = UUID()
    private let peripheralID = UUID()

    private func input(
        percent: Int = 80,
        chargingRaw: UInt8? = 0,
        received: TimeInterval,
        now: TimeInterval? = nil,
        usbPresent: Bool = true,
        milliamps: Int? = 500,
        linkBitsPerSecond: Int64? = 480_000_000,
        allocationFailed: Bool? = false,
        session: UUID? = nil,
        peripheral: UUID? = nil,
        batterySession: UUID? = nil,
        batteryPeripheral: UUID? = nil
    ) -> Pocket3PowerChargingInput {
        let activeSession = session ?? sessionID
        let activePeripheral = peripheral ?? peripheralID
        let battery = Pocket3PowerChargingBatterySample(
            sessionID: batterySession ?? activeSession,
            peripheralID: batteryPeripheral ?? activePeripheral,
            percent: percent, chargingRaw: chargingRaw,
            receivedUptime: received)
        return Pocket3PowerChargingInput(
            usb: .init(present: usbPresent,
                       configuredMilliamps: milliamps,
                       linkBitsPerSecond: linkBitsPerSecond,
                       allocationFailed: allocationFailed),
            sessionID: activeSession, peripheralID: activePeripheral,
            battery: battery, nowUptime: now ?? received)
    }

    @Test func classificationUsesBatteryRawStateAndNeverTreats500mAAsProof() {
        var reducer = Pocket3PowerChargingDiagnosisReducer()
        let charging = reducer.reduce(input(percent: 40, chargingRaw: 1, received: 10))
        #expect(charging.state == .charging && charging.reason == .chargingReported)

        let full = reducer.reduce(input(percent: 100, chargingRaw: 0, received: 11))
        #expect(full.state == .fullNotCharging && full.reason == .fullBatteryNotCharging)

        let connected = reducer.reduce(input(percent: 70, chargingRaw: 0, received: 12))
        #expect(connected.state == .connectedNotCharging)
        #expect(connected.configuredMilliamps == 500)
        #expect(!connected.insufficientPowerCandidate)

        let withoutUSB = reducer.reduce(input(percent: 70, chargingRaw: 0,
                                               received: 13, usbPresent: false))
        #expect(withoutUSB.state == .unknown && withoutUSB.reason == .noUSBConnection)
    }

    @Test func insufficientPowerCandidateNeedsADeclineWindowAndMultipleSamples() {
        var reducer = Pocket3PowerChargingDiagnosisReducer()
        let first = reducer.reduce(input(percent: 80, received: 10))
        #expect(first.state == .connectedNotCharging)
        let second = reducer.reduce(input(percent: 79, received: 20))
        #expect(second.state == .connectedNotCharging)
        let third = reducer.reduce(input(percent: 78, received: 40))
        #expect(third.state == .insufficientPowerCandidate)
        #expect(third.reason == .batteryDecliningWhileNotCharging)
        #expect(third.observedDropPercent == 2)
        #expect(third.trendDuration == 30)

        var failedAllocation = Pocket3PowerChargingDiagnosisReducer()
        let allocationOnly = failedAllocation.reduce(input(
            percent: 80, received: 10, allocationFailed: true))
        #expect(allocationOnly.state == .connectedNotCharging)
        #expect(allocationOnly.reason == .powerAllocationFailed)
        #expect(!allocationOnly.insufficientPowerCandidate)

        let declining = failedAllocation.reduce(input(
            percent: 79, received: 20, allocationFailed: true))
        #expect(declining.state == .connectedNotCharging)
        let candidate = failedAllocation.reduce(input(
            percent: 78, received: 40, allocationFailed: true))
        #expect(candidate.state == .insufficientPowerCandidate)
        #expect(candidate.reason == .powerAllocationFailedAndBatteryDeclining)
        #expect(candidate.needsAttention)
    }

    @Test func staleTelemetryUnknownRawAndSessionChangesAreFenced() {
        var reducer = Pocket3PowerChargingDiagnosisReducer()
        _ = reducer.reduce(input(received: 10))
        let stale = reducer.reduce(input(received: 10, now: 16))
        #expect(stale.state == .telemetryStale && !stale.batteryFresh)

        let nextSession = UUID()
        let reset = reducer.reduce(input(received: 20, session: nextSession))
        #expect(reset.historyReset && reset.sampleCount == 1)
        #expect(reset.state == .connectedNotCharging)

        let unknownRaw = reducer.reduce(input(chargingRaw: 0xFE, received: 21,
                                              session: nextSession))
        #expect(unknownRaw.state == .unknown)
        #expect(unknownRaw.reason == .chargingStateUnknown)

        let mismatch = reducer.reduce(input(received: 22, session: nextSession,
                                             batterySession: UUID()))
        #expect(mismatch.state == .telemetryStale)
        #expect(mismatch.reason == .sessionMismatch && mismatch.historyReset)
        #expect(reducer.retainedSampleCount == 1)
    }

    @Test func malformedPowerBatteryAndMissingSamplesStayUnknownWithoutHistoryLeak() {
        var reducer = Pocket3PowerChargingDiagnosisReducer()
        let badPower = reducer.reduce(input(received: 10, milliamps: -1))
        #expect(badPower.state == .unknown && badPower.reason == .invalidUSBPower)
        let badLink = reducer.reduce(input(received: 11, linkBitsPerSecond: 0))
        #expect(badLink.state == .unknown && badLink.reason == .invalidUSBPower)
        let badBattery = reducer.reduce(input(percent: 101, received: 12))
        #expect(badBattery.state == .unknown && badBattery.reason == .invalidBatterySample)

        let missing = reducer.reduce(.init(
            usb: .init(present: true, configuredMilliamps: 500),
            sessionID: sessionID, peripheralID: peripheralID,
            battery: nil, nowUptime: 13))
        #expect(missing.state == .telemetryStale && !missing.batteryFresh)
        #expect(missing.reason == .telemetryStale)

        var noUSB = Pocket3PowerChargingDiagnosisReducer()
        let noUSBMissing = noUSB.reduce(.init(
            usb: .init(present: false), sessionID: nil, peripheralID: nil,
            battery: nil, nowUptime: 10))
        #expect(noUSBMissing.state == .unknown && noUSBMissing.reason == .noUSBConnection)
    }

    @Test func diagnosisRoundTripsWithoutTurningRawFieldsIntoInferences() throws {
        var reducer = Pocket3PowerChargingDiagnosisReducer()
        let value = reducer.reduce(input(percent: 100, chargingRaw: 0,
                                          received: 10, milliamps: nil,
                                          linkBitsPerSecond: nil,
                                          allocationFailed: nil))
        let decoded = try JSONDecoder().decode(
            Pocket3PowerChargingDiagnosis.self,
            from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(decoded.state == .fullNotCharging)
        #expect(decoded.configuredMilliamps == nil && decoded.linkBitsPerSecond == nil)
    }
}
