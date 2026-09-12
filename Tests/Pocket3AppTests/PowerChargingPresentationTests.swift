import AppKit
import Foundation
import SwiftUI
import Testing
import Pocket3Core
@testable import Pocket3BridgeApp

@Suite("Power and charging presentation")
struct PowerChargingPresentationTests {
    private let sessionID = UUID()
    private let peripheralID = UUID()

    private func diagnosis(
        state: Pocket3PowerChargingDiagnosisState = .charging,
        reason: Pocket3PowerChargingDiagnosisReason = .chargingReported,
        percent: Int = 74,
        chargingRaw: UInt8? = 1,
        allocationFailed: Bool? = false,
        drop: Int? = nil,
        duration: TimeInterval? = nil,
        samples: Int = 1
    ) -> Pocket3PowerChargingDiagnosis {
        let battery = Pocket3PowerChargingBatterySample(
            sessionID: sessionID, peripheralID: peripheralID,
            percent: percent, chargingRaw: chargingRaw,
            receivedUptime: 10)
        return Pocket3PowerChargingDiagnosis(
            state: state, reason: reason,
            usb: .init(present: true, configuredMilliamps: 500,
                       linkBitsPerSecond: 480_000_000,
                       allocationFailed: allocationFailed),
            sessionID: sessionID, peripheralID: peripheralID,
            battery: battery, batteryFresh: true, sampleCount: samples,
            observedDropPercent: drop, trendDuration: duration,
            historyReset: false, evaluatedUptime: 10)
    }

    @MainActor @Test func statusMapsDiagnosisIntoTheExistingPowerPill() {
        let model = AppModel()
        model.powerChargingDiagnosis = diagnosis(
            state: .insufficientPowerCandidate,
            reason: .batteryDecliningWhileNotCharging,
            percent: 72, chargingRaw: 0, drop: 2, duration: 30, samples: 3)
        let pills = StatusPills.pills(for: model)
        let power = pills.filter { $0.id == "power" }
        #expect(power.count == 1)
        #expect(power.first?.label == "Power check needed")
        #expect(power.first?.value == "72%")
        #expect(power.first?.tone == .warning && power.first?.showsDot == true)
        #expect(!model.wireless.bluetooth.isBluetoothInitialized)
    }

    @Test func presentationKeepsNormalFullAndStaleStatesDistinct() {
        let charging = diagnosis()
        #expect(PowerChargingPresentation.title(charging) == "Charging")
        #expect(PowerChargingPresentation.tone(charging) == .success)
        #expect(PowerChargingPresentation.reason(charging) == "Camera reports charging")

        let full = diagnosis(state: .fullNotCharging,
                             reason: .fullBatteryNotCharging,
                             percent: 100, chargingRaw: 0)
        #expect(PowerChargingPresentation.title(full) == "Full · not charging")
        #expect(PowerChargingPresentation.tone(full) == .neutral)

        let stale = diagnosis(state: .telemetryStale,
                              reason: .telemetryStale,
                              percent: 74, chargingRaw: nil)
        #expect(PowerChargingPresentation.title(stale) == "Charging telemetry stale")
        #expect(PowerChargingPresentation.tone(stale) == .warning)
        #expect(PowerChargingPresentation.linkSpeed(stale) == "480 Mbps")
    }

    @MainActor @Test func diagnosticsCardRendersCompactPowerEvidenceWithoutHardware() throws {
        let value = diagnosis(
            state: .insufficientPowerCandidate,
            reason: .powerAllocationFailedAndBatteryDeclining,
            percent: 68, chargingRaw: 0, allocationFailed: true,
            drop: 3, duration: 45, samples: 4)
        let renderer = ImageRenderer(content: PowerChargingDiagnosticsCard(
            diagnosis: value).frame(width: 560))
        renderer.proposedSize = ProposedViewSize(width: 560, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width <= 560)
        #expect(image.size.height > 180 && image.size.height < 700)
        if ProcessInfo.processInfo.environment["POCKET3_RENDER_ARTIFACT"] == "1",
           let data = image.tiffRepresentation {
            try data.write(to: URL(fileURLWithPath: "/tmp/Pocket3PowerChargingDiagnosticsCard.tiff"), options: .atomic)
        }
    }
}
