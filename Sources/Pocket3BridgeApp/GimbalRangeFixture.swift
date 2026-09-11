import SwiftUI
import Pocket3Core
import YunDesign

/// Isolated presentation only. It creates no capture/UVC/Bluetooth connection;
/// the controls' callbacks are never invoked while rendering this fixture.
@MainActor enum GimbalRangeFixture {
    static func view() -> AnyView {
        let data = Data("""
        {
          "appVersion":"fixture","buildVersion":"fixture","phase":"ready","devices":[],"selected":null,
          "access":"manual","permission":"authorized",
          "capture":{"sessionID":"gimbal-range-fixture","frames":1,"recentFPS":30,"frame":null,"age":0,
            "audio":{"buffers":0,"sampleFrames":0,"sampleRate":0,"channels":0,"rms":0,"peak":0}},
          "gimbal":{"location":17825792,"position":{"pan":0,"tilt":0},
            "minimum":{"pan":-126000,"tilt":-324000},"maximum":{"pan":774000,"tilt":324000},
            "step":{"pan":3600,"tilt":3600},"writable":true,"controls":[],"uvcVersion":0,
            "registryID":null,"bootSessionID":null,"defaultPosition":{"pan":0,"tilt":0}},
          "motionActive":false,"stopStrategy":"hold_current_uvc_target_and_verify_readback",
          "stopValidated":false,"lastError":null,"activities":[]
        }
        """.utf8)
        let model = AppModel()
        model.status = try! JSONDecoder().decode(ServiceStatus.self, from: data)
        return AnyView(GimbalRangeControls(model: model).padding(Yun.Space.lg).frame(width: 340)
            .background(Yun.Palette.background))
    }
}
