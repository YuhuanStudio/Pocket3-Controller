import SwiftUI
import Pocket3Core
import YunDesign

/// Isolated UI model. Its callbacks only update in-memory fixture values and
/// never reach CameraService, USB, Bluetooth, or AI observation evidence.
@MainActor enum RollControlFixture {
    static func view(state: String) async throws -> AnyView {
        let initial: Int
        let writable: Bool
        switch state {
        case "negative": (initial, writable) = (-10, true)
        case "maximum": (initial, writable) = (30, true)
        case "unavailable": (initial, writable) = (0, false)
        default: throw BridgeFailure("invalid_fixture", "Choose a known roll presentation fixture")
        }
        var capabilities = USBRollCapabilities(current: initial, minimum: -30, maximum: 30,
            step: writable ? 1 : nil, defaultValue: 8, writable: writable)
        let model = CameraRollModel(readCapabilities: { _ in capabilities }, applyRoll: { value, _ in
            capabilities.current = value
            return USBRollResult(target: value, observed: value, accepted: true, completed: true,
                verified: true, verification: "simulation_only", capabilities: capabilities,
                message: "In-memory UI fixture only")
        })
        await model.refresh(sessionID: "roll-interface-fixture", phase: "ready")
        return AnyView(CameraRollControls(model: model).padding(Yun.Space.md).frame(width: 268)
            .background(Yun.Palette.background))
    }
}
