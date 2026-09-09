import Foundation
import SwiftUI
import Pocket3Core
import YunDesign

/// Development screenshot fixture: it never updates the live discovery model,
/// starts Bluetooth, or supplies evidence to camera/AI operations.
@MainActor enum BluetoothTelemetryFixture {
    static func view(state: String) throws -> AnyView {
        let session = UUID(), peer = UUID(), now = Date()
        let percent: Int
        let low: Bool, falling: Bool
        switch state {
        case "full": (percent, low, falling) = (100, false, false)
        case "low": (percent, low, falling) = (12, true, false)
        case "falling": (percent, low, falling) = (78, false, true)
        case "low-falling": (percent, low, falling) = (10, true, true)
        default: throw BridgeFailure("invalid_fixture", "Choose a known Bluetooth presentation fixture")
        }
        let battery = BluetoothBatteryAssessment(percent: percent, chargingState: .notCharging,
            lowBattery: low, falling: falling, observedDropPercent: falling ? 2 : nil,
            observationDuration: falling ? 35 : nil, receivedAt: now, sessionID: session, peripheralID: peer)
        let data = try JSONSerialization.data(withJSONObject: [
            "sessionID": session.uuidString, "peripheralID": peer.uuidString, "sequence": 1,
            "pitchRaw": -125, "rollRaw": 5, "yawRaw": 420,
            "receivedAt": now.timeIntervalSinceReferenceDate,
            "receivedUptime": ProcessInfo.processInfo.systemUptime,
            "unit": "device_reported_deci_degrees", "calibration": "not_calibrated_to_usb"
        ])
        let pose = try JSONDecoder().decode(BluetoothPoseObservation.self, from: data)
        return AnyView(VStack(alignment: .leading, spacing: Yun.Space.md) {
            BluetoothBatteryView(assessment: battery)
            YunDivider()
            BluetoothPoseView(observation: pose)
            if let warning = BluetoothBatteryPresentation.warningTitle(battery) {
                YunDivider()
                YunStatusPill(warning, value: "\(percent)%", tone: .warning, showsDot: true)
            }
        }.padding(Yun.Space.lg).frame(width: 340, alignment: .leading).background(Yun.Palette.background))
    }
}
