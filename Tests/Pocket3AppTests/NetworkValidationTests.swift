import Foundation
import Testing
import Pocket3Core
@testable import Pocket3BridgeApp

@Suite("Developer native network selection") struct NetworkValidationTests {
    @MainActor @Test func selectionIsStoredReadOnlyAndDoesNotCreateAnOwner() throws {
        let model = WirelessGimbalModel(service: CameraService(),
            controls: ContinuousGimbalGestureController(monitorsEnabled: false),
            prepareManual: {})
        let configuration = Pocket3DatalinkSocketConfiguration(
            interfaceName: "en7", interfaceIndex: 7, cameraHost: "192.168.2.1")

        try model.configureDeveloperNativeNetwork(configuration)

        #expect(model.nativeNetworkConfiguration == configuration)
        #expect(model.nativeRouteStatus.state == .unknown)
        #expect(model.ownsContinuousControls == false)
        let status = try model.validationStatus()
        #expect(status["nativeNetworkConfiguration"]["interfaceIndex"] == .number(7))
        #expect(status["nativeRouteStatus"]["state"] == .string("unknown"))
    }

    @MainActor @Test func selectionCannotChangeWhileConnecting() throws {
        let model = WirelessGimbalModel(service: CameraService(),
            controls: ContinuousGimbalGestureController(monitorsEnabled: false),
            prepareManual: {})
        model.connecting = true
        do {
            try model.configureDeveloperNativeNetwork(.legacy)
            Issue.record("Network selection must not change during connection")
        } catch let error as BridgeFailure {
            #expect(error.code == "wireless_busy")
        }
        #expect(model.nativeNetworkConfiguration == .legacy)
    }
}
