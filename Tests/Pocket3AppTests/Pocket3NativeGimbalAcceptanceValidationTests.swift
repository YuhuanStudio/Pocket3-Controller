import Foundation
import Pocket3Core
import Testing
@testable import Pocket3BridgeApp

@Suite("Pocket 3 native gimbal acceptance route")
struct Pocket3NativeGimbalAcceptanceValidationTests {
    private func request() throws ->
        Pocket3NativeGimbalAcceptanceValidationRequest {
        try .init(expectedSessionID: UUID(), peripheralID: UUID(),
                  stationGeneration: 2, nativeSessionID: "lan-owner",
                  nativeGeneration: 3)
    }

    @MainActor @Test func contextFailsClosedBeforeAStationOwnerExists()
        async throws {
        let model = WirelessGimbalModel(
            service: CameraService(),
            controls: ContinuousGimbalGestureController(monitorsEnabled: false),
            prepareManual: {})
        var failure: BridgeFailure?
        do {
            _ = try await model.nativeGimbalAcceptanceContext(request())
        } catch let error as BridgeFailure {
            failure = error
        }
        #expect(failure?.code == "native_gimbal_acceptance_session_changed")
        #expect(model.nativeGimbalAcceptanceBusy == false)
    }

    @MainActor @Test func routeRequiresExplicitDeveloperLaunch() async throws {
        let model = AppModel()
        let request = ServiceRequest(
            token: "test",
            operation: Pocket3NativeGimbalAcceptanceValidationRequest.operation,
            arguments: try request().arguments)
        var failure: BridgeFailure?
        do {
            _ = try await model.handleNativeGimbalAcceptanceValidation(request)
        } catch let error as BridgeFailure {
            failure = error
        }
        #expect(failure?.code == "validation_disabled")
        #expect(model.wireless.nativeGimbalAcceptanceBusy == false)
    }
}
