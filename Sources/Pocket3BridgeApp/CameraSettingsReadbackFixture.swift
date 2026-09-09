import SwiftUI
import Pocket3Core
import YunDesign

@MainActor enum CameraSettingsReadbackFixture {
    static func view(state: String) throws -> AnyView {
        guard ["available", "stale", "manual"].contains(state) else {
            throw BridgeFailure("invalid_fixture", "Choose a known readback presentation fixture")
        }
        let binding: [String: Any] = ["sessionID": "ble:interface-fixture", "generation": 0]
        let uptime = ProcessInfo.processInfo.systemUptime - (state == "stale" ? 10 : 0)
        let values: [(String, [String: Any])] = [
            ("cam_image_effect", ["whiteBalance": ["_0": ["customKelvin": ["_0": 5600]]]]),
            ("cam_lens_state", ["focus": ["_0": 2]]),
            ("cam_expo_param", ["autoEV": ["thirdStops": 1]])
        ]
        let rows = try values.enumerated().map { index, entry in
            var object: [String: Any] = ["property": entry.0, "value": entry.1,
                "binding": binding, "transactionID": index, "receivedUptime": uptime]
            if entry.0 == "cam_expo_param" { object["exposureMode"] = state == "manual" ? 4 : 1 }
            return try JSONDecoder().decode(CameraSettingsObservation.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        return AnyView(BluetoothCameraSettingsView(observations: rows, reading: false, refresh: {})
            .padding(Yun.Space.lg).frame(width: 340).background(Yun.Palette.background))
    }
}
