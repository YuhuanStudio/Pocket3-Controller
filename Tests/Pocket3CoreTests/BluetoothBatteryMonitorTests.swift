import Foundation
import Testing
@testable import Pocket3Core

private let batterySession = UUID()
private let batteryPeripheral = UUID()
private let batteryEpoch = Date(timeIntervalSince1970: 1_700_000_000)
private func batterySample(_ percent: Int, at seconds: Double, charging: Pocket3ChargingState = .notCharging,
                           session: UUID = batterySession, peripheral: UUID = batteryPeripheral,
                           source: DUMLTelemetrySource = .bluetooth) -> BluetoothBatteryObservation {
    BluetoothBatteryObservation(sessionID: session, peripheralID: peripheral,
        telemetry: Pocket3BatteryTelemetry(percent: percent, chargingState: charging, source: source,
            receivedAt: batteryEpoch.addingTimeInterval(seconds)))
}
private func batteryUpdate(_ monitor: inout BluetoothBatteryMonitor, _ percent: Int, at seconds: Double,
                           charging: Pocket3ChargingState = .notCharging) -> BluetoothBatteryAssessment? {
    monitor.update(observation: batterySample(percent, at: seconds, charging: charging), sessionID: batterySession,
        peripheralID: batteryPeripheral, now: batteryEpoch.addingTimeInterval(seconds))
}
private func confirmedBatteryDrop(_ monitor: inout BluetoothBatteryMonitor) -> BluetoothBatteryAssessment? {
    var result: BluetoothBatteryAssessment?
    for time in stride(from: 0.0, through: 30.0, by: 5.0) {
        result = batteryUpdate(&monitor, time < 15 ? 60 : time < 30 ? 59 : 58, at: time)
    }
    return result
}

@Test func batteryLowThresholdIsInformationalAndFullNotChargingNeedsNoAttention() {
    var monitor = BluetoothBatteryMonitor()
    let full = batteryUpdate(&monitor, 100, at: 0)
    #expect(full?.chargingState == .notCharging && full?.lowBattery == false && full?.falling == false && full?.needsAttention == false)
    let above = batteryUpdate(&monitor, 21, at: 1)
    #expect(above?.lowBattery == false && above?.falling == false)
    let low = batteryUpdate(&monitor, 20, at: 2, charging: .charging)
    #expect(low?.lowBattery == true && low?.needsAttention == true && low?.chargingState == .charging)
    let empty = batteryUpdate(&monitor, 0, at: 3, charging: .unknown)
    #expect(empty?.percent == 0 && empty?.lowBattery == true && empty?.chargingState == .unknown)
}

@Test func freshContinuousTwoStepDeclineReportsItsMeasuredDropAndDuration() throws {
    var monitor = BluetoothBatteryMonitor()
    let updated = confirmedBatteryDrop(&monitor)
    let assessment = try #require(updated)
    #expect(assessment.percent == 58 && assessment.falling && assessment.needsAttention)
    #expect(assessment.observedDropPercent == 2 && assessment.observationDuration == 30)
    #expect(assessment.sessionID == batterySession && assessment.peripheralID == batteryPeripheral)
    #expect(assessment.receivedAt == batteryEpoch.addingTimeInterval(30))
    #expect(assessment.isFresh(now: batteryEpoch.addingTimeInterval(35)))
    #expect(!assessment.isFresh(now: batteryEpoch.addingTimeInterval(35.01)))
    #expect(!assessment.isFresh(now: batteryEpoch.addingTimeInterval(29)))
    #expect(try JSONDecoder().decode(BluetoothBatteryAssessment.self, from: JSONEncoder().encode(assessment)) == assessment)
}

@Test func oneLargeDropOrShortMultiStepDropDoesNotManufactureAFallingTrend() {
    var single = BluetoothBatteryMonitor()
    for time in stride(from: 0.0, through: 35.0, by: 5.0) { _ = batteryUpdate(&single, time < 30 ? 80 : 70, at: time) }
    let result = batteryUpdate(&single, 70, at: 40)
    #expect(result?.observedDropPercent == 10 && result?.falling == false)

    var quick = BluetoothBatteryMonitor()
    _ = batteryUpdate(&quick, 80, at: 0)
    _ = batteryUpdate(&quick, 79, at: 1)
    _ = batteryUpdate(&quick, 78, at: 2)
    var plateau: BluetoothBatteryAssessment?
    for time in 3...40 { plateau = batteryUpdate(&quick, 78, at: Double(time)) }
    #expect(plateau?.falling == false && plateau?.observationDuration == 2)
}

@Test func repeatedOrContradictorySameTimestampSamplesCannotCountAsNewDeclines() {
    var monitor = BluetoothBatteryMonitor()
    _ = batteryUpdate(&monitor, 80, at: 0)
    _ = batteryUpdate(&monitor, 79, at: 5)
    let sample = batterySample(79, at: 5)
    var repeated: BluetoothBatteryAssessment?
    for now in [5.0, 6, 7, 8, 9, 10] {
        repeated = monitor.update(observation: sample, sessionID: batterySession, peripheralID: batteryPeripheral,
            now: batteryEpoch.addingTimeInterval(now))
    }
    #expect(repeated?.falling == false && repeated?.observedDropPercent == 1 && repeated?.observationDuration == 5)
    #expect(monitor.retainedLevelCount == 2)
    let contradictory = monitor.update(observation: batterySample(77, at: 5), sessionID: batterySession,
        peripheralID: batteryPeripheral, now: batteryEpoch.addingTimeInterval(10))
    #expect(contradictory?.falling == false && contradictory?.observedDropPercent == nil)
}

@Test func staleDisconnectAndSourceOrIdentityMismatchClearBatteryTrend() {
    var monitor = BluetoothBatteryMonitor()
    _ = confirmedBatteryDrop(&monitor)
    let stale = monitor.update(observation: batterySample(58, at: 30), sessionID: batterySession,
        peripheralID: batteryPeripheral, now: batteryEpoch.addingTimeInterval(36))
    #expect(stale == nil && monitor.retainedLevelCount == 0)
    let resumed = batteryUpdate(&monitor, 57, at: 36)
    #expect(resumed?.falling == false && resumed?.observedDropPercent == nil)
    let invalid: [BluetoothBatteryObservation?] = [nil, batterySample(55, at: 37, source: .wifi),
        batterySample(55, at: 37, session: UUID()), batterySample(55, at: 37, peripheral: UUID())]
    for observation in invalid {
        _ = batteryUpdate(&monitor, 57, at: 36)
        let result = monitor.update(observation: observation, sessionID: batterySession, peripheralID: batteryPeripheral,
            now: batteryEpoch.addingTimeInterval(37))
        #expect(result == nil && monitor.retainedLevelCount == 0)
    }
    let noPeer = monitor.update(observation: batterySample(55, at: 38), sessionID: batterySession, peripheralID: nil,
        now: batteryEpoch.addingTimeInterval(38))
    #expect(noPeer == nil)
}

@Test func newlySelectedSessionOrPeripheralStartsItsOwnBatteryBaseline() {
    var monitor = BluetoothBatteryMonitor()
    _ = confirmedBatteryDrop(&monitor)
    let nextSession = UUID(), nextPeer = UUID()
    let changedSession = monitor.update(observation: batterySample(40, at: 31, session: nextSession), sessionID: nextSession,
        peripheralID: batteryPeripheral, now: batteryEpoch.addingTimeInterval(31))
    #expect(changedSession?.falling == false && changedSession?.observedDropPercent == nil && changedSession?.sessionID == nextSession)
    let changedPeer = monitor.update(observation: batterySample(30, at: 32, session: nextSession, peripheral: nextPeer),
        sessionID: nextSession, peripheralID: nextPeer, now: batteryEpoch.addingTimeInterval(32))
    #expect(changedPeer?.falling == false && changedPeer?.observedDropPercent == nil && changedPeer?.peripheralID == nextPeer)
}

@Test func increasingLevelFreshStreamGapAndReversedClocksResetTrend() {
    var monitor = BluetoothBatteryMonitor()
    _ = confirmedBatteryDrop(&monitor)
    let rise = batteryUpdate(&monitor, 59, at: 31)
    #expect(rise?.falling == false && rise?.observedDropPercent == nil)
    _ = confirmedBatteryDrop(&monitor)
    let gap = batteryUpdate(&monitor, 57, at: 36)
    #expect(gap?.falling == false && gap?.observedDropPercent == nil)
    _ = confirmedBatteryDrop(&monitor)
    let backwardsNow = batteryUpdate(&monitor, 57, at: 29)
    #expect(backwardsNow?.falling == false && backwardsNow?.observedDropPercent == nil)
    _ = confirmedBatteryDrop(&monitor)
    let backwardsSample = monitor.update(observation: batterySample(57, at: 29), sessionID: batterySession,
        peripheralID: batteryPeripheral, now: batteryEpoch.addingTimeInterval(31))
    #expect(backwardsSample?.falling == false && backwardsSample?.observedDropPercent == nil)
}

@Test func invalidPercentAndNonfiniteOrFutureTimesNeverProduceAnAssessment() {
    var monitor = BluetoothBatteryMonitor()
    for value in [-1, 101] {
        let result = batteryUpdate(&monitor, value, at: 0)
        #expect(result == nil)
    }
    let future = monitor.update(observation: batterySample(10, at: 1), sessionID: batterySession,
        peripheralID: batteryPeripheral, now: batteryEpoch)
    #expect(future == nil)
    let invalidNow = monitor.update(observation: batterySample(10, at: 0), sessionID: batterySession,
        peripheralID: batteryPeripheral, now: Date(timeIntervalSinceReferenceDate: .nan))
    #expect(invalidNow == nil)
    let invalidSample = batteryUpdate(&monitor, 10, at: .infinity)
    #expect(invalidSample == nil)
}

@Test func oldDropsExpireAndHighFrequencyUpdatesHaveBoundedMemory() {
    var monitor = BluetoothBatteryMonitor()
    _ = confirmedBatteryDrop(&monitor)
    var result: BluetoothBatteryAssessment?
    for time in stride(from: 35.0, through: 635.0, by: 5.0) { result = batteryUpdate(&monitor, 58, at: time) }
    #expect(result?.falling == false && result?.observedDropPercent == nil)
    #expect(monitor.retainedLevelCount == 1)
    var dense = BluetoothBatteryMonitor()
    for index in 0...20_000 {
        _ = batteryUpdate(&dense, max(0, 100 - index / 100), at: Double(index) / 100)
        #expect(dense.retainedLevelCount <= 101)
    }
}

@Test func freshPlateauAfterSixtySecondsClearsFallingButPreservesLowBattery() {
    for initialPercent in [60, 20] {
        var monitor = BluetoothBatteryMonitor()
        var result: BluetoothBatteryAssessment?
        for time in stride(from: 0.0, through: 90.0, by: 5.0) {
            let percent = time < 15 ? initialPercent : time < 30 ? initialPercent - 1 : initialPercent - 2
            result = batteryUpdate(&monitor, percent, at: time)
        }
        #expect(result?.falling == true) // Last actual decline was exactly 60 seconds ago.
        let settled = batteryUpdate(&monitor, initialPercent - 2, at: 91)
        #expect(settled?.falling == false && settled?.isFresh(now: batteryEpoch.addingTimeInterval(91)) == true)
        #expect(settled?.observedDropPercent == 2 && settled?.observationDuration == 30)
        #expect(settled?.lowBattery == (initialPercent == 20))
        #expect(settled?.needsAttention == (initialPercent == 20))
    }
}

@Test func publicAssessmentFixtureDoesNotEquateNotChargingWithAFault() {
    let fixture = BluetoothBatteryAssessment(percent: 100, chargingState: .notCharging, lowBattery: false, falling: false,
        receivedAt: batteryEpoch, sessionID: batterySession, peripheralID: batteryPeripheral)
    #expect(!fixture.needsAttention && fixture.isFresh(now: batteryEpoch))
    #expect(!fixture.isFresh(now: Date(timeIntervalSinceReferenceDate: .infinity)))
}
