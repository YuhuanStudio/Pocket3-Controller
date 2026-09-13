import Foundation
import Pocket3Core
import Testing
@testable import Pocket3BridgeApp

@Suite("Pocket 3 station-mode presentation")
struct Pocket3StationModeTests {
    @MainActor @Test func stationInputsStayOutOfCredentialFreeStatus() async throws {
        let model = WirelessGimbalModel(
            service: CameraService(),
            controls: ContinuousGimbalGestureController(monitorsEnabled: false),
            prepareManual: {})
        model.stationHostInput = "192.168.1.42"
        model.stationSSIDInput = "private-network"
        model.stationPasswordInput = "never-persist-this"

        let status = try model.validationStatus()
        let encoded = try JSONEncoder().encode(status)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("private-network"))
        #expect(!text.contains("never-persist-this"))
        #expect(status["stationPhase"] == .string("idle"))
        #expect(status["stationCredentialsPersisted"] == .bool(false))

        await model.disconnect()
        #expect(model.stationSSIDInput.isEmpty)
        #expect(model.stationPasswordInput.isEmpty)
        #expect(model.stationHostInput.isEmpty)
    }

    @MainActor @Test func stationActionDoesNotRunWithoutExplicitValidationFlag() async {
        let model = WirelessGimbalModel(
            service: CameraService(),
            controls: ContinuousGimbalGestureController(monitorsEnabled: false),
            prepareManual: {})
        model.stationHostInput = "192.168.1.42"
        model.stationSSIDInput = "network"
        model.stationPasswordInput = "password"
        await model.connectStationMode()
        #expect(model.stationPhase == .idle)
        #expect(model.issue != nil)
        #expect(model.ownsContinuousControls == false)
    }
}
