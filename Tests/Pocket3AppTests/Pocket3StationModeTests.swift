import Foundation
import Pocket3Core
import Testing
@testable import Pocket3BridgeApp

@Suite("Pocket 3 station-mode presentation")
struct Pocket3StationModeTests {
    @MainActor @Test func stationIdentityUsesSelectedPairedAdvertisementWithoutAPCredentials() throws {
        let peer = UUID()
        #expect(WirelessGimbalModel.stationCameraSSID(
            peerReportedPaired: true, selectedPeripheralID: peer,
            credentialSSID: nil,
            advertisedCandidates: [(peer, "OsmoPocket3-7CF5", true)]) ==
            "OsmoPocket3-7CF5")
        #expect(WirelessGimbalModel.stationCameraSSID(
            peerReportedPaired: true, selectedPeripheralID: peer,
            credentialSSID: "OsmoPocket3-ABCD",
            advertisedCandidates: []) ==
            "OsmoPocket3-ABCD")
    }

    @MainActor @Test func stationIdentityRejectsUnpairedStaleOrInvalidAdvertisement() throws {
        let selected = UUID()
        let other = UUID()
        #expect(WirelessGimbalModel.stationCameraSSID(
            peerReportedPaired: false, selectedPeripheralID: selected,
            credentialSSID: nil,
            advertisedCandidates: [(selected, "OsmoPocket3-7CF5", true)]) == nil)
        #expect(WirelessGimbalModel.stationCameraSSID(
            peerReportedPaired: true, selectedPeripheralID: selected,
            credentialSSID: nil,
            advertisedCandidates: [(other, "OsmoPocket3-7CF5", true)]) == nil)
    }

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
