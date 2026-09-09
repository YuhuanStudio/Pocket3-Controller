import Foundation
import Testing
@testable import Pocket3Core
@testable import Pocket3BridgeApp

@MainActor @Test func wirelessBatteryAdvisoryUsesOnlyCurrentPairedTelemetryWithoutStartingBluetooth() {
    let model = WirelessGimbalModel(service: CameraService(),
        controls: ContinuousGimbalGestureController(monitorsEnabled: false), prepareManual: {})
    let session = UUID(), peer = UUID(), now = Date()
    func status(percent: Int, paired: Bool = true, selected: UUID? = nil) -> BluetoothDiscoveryStatus {
        BluetoothDiscoveryStatus(phase: .gattPaired, sessionID: session, candidates: [],
            selectedPeripheralID: selected ?? peer, issueCode: nil,
            identityVerification: "offline fixture", authentication: "offline fixture",
            fff4NotificationEnabled: true, fff5NotificationEnabled: true,
            fff4Properties: nil, fff5Properties: nil, receivedFrames: 1, fragments: [:],
            pairing: BluetoothPairingStatus(phase: .paired, peerReportedPaired: paired,
                credentialsAvailable: false, issueCode: nil),
            battery: BluetoothBatteryObservation(sessionID: session, peripheralID: peer,
                telemetry: Pocket3BatteryTelemetry(percent: percent, chargingState: .notCharging,
                    source: .bluetooth, receivedAt: now)))
    }
    model.applyDiscoveryStatus(status(percent: 12), now: now)
    #expect(model.freshBatteryAssessment?.percent == 12)
    #expect(model.freshBatteryAssessment?.lowBattery == true)
    model.applyDiscoveryStatus(status(percent: 12), now: now.addingTimeInterval(6))
    #expect(model.freshBatteryAssessment == nil)
    model.applyDiscoveryStatus(status(percent: 12, paired: false), now: now)
    #expect(model.freshBatteryAssessment == nil)
    model.applyDiscoveryStatus(status(percent: 12, selected: UUID()), now: now)
    #expect(model.freshBatteryAssessment == nil)
    model.applyDiscoveryStatus(status(percent: 100), now: now)
    #expect(model.freshBatteryAssessment?.needsAttention == false)
    if let full = model.freshBatteryAssessment {
        #expect(BluetoothBatteryPresentation.warningTitle(full) == nil)
    }
    #expect(!model.bluetooth.isBluetoothInitialized)
}

@MainActor @Test func readingCameraSettingsWithoutPairingDoesNotStartBluetooth() {
    let model = WirelessGimbalModel(service: CameraService(),
        controls: ContinuousGimbalGestureController(monitorsEnabled: false), prepareManual: {})
    model.readCameraSettings()
    #expect(!model.readingCameraSettings)
    #expect(!model.bluetooth.isBluetoothInitialized)
    #expect(model.discovery.cameraSettingsObservations.isEmpty)
}
