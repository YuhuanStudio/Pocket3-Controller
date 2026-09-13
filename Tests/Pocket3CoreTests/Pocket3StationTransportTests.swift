import Foundation
import Testing
@testable import Pocket3Core

private struct StationRouteObservationFake:
    Pocket3DatalinkNetworkObservationProviding {
    let before: UInt32?
    let after: UInt32?
    func captureBaseline() -> Pocket3DatalinkRouteBaseline {
        .init(primaryInterfaceIndex: before)
    }
    func observe(configuration: Pocket3DatalinkSocketConfiguration,
                 baseline: Pocket3DatalinkRouteBaseline?)
        -> Pocket3DatalinkRouteObservation {
        .init(currentPrimaryInterfaceIndex: after,
              baselinePrimaryInterfaceIndex: baseline?.primaryInterfaceIndex)
    }
}

@Suite("Pocket 3 station transport seams")
struct Pocket3StationTransportTests {
    @Test func BLEAdmissionRejectsUnreviewedRequestVariants() throws {
        let valid = Pocket3StationProtocol.enterStationMode(sequence: 1)
        #expect(Pocket3StationProtocol.isValidRequest(valid))
        #expect(Pocket3StationProtocol.isValidReplyCharacteristic("FFF4"))
        #expect(Pocket3StationProtocol.isValidReplyCharacteristic("FFF5"))
        #expect(!Pocket3StationProtocol.isValidReplyCharacteristic("FFF0"))
        let wrongPayload = Pocket3StationBLECommand(
            operation: .enterStationMode,
            frame: DUMLFrame(source: 2, destination: 7, sequence: 1,
                             flags: 0x40, commandSet: 7, commandID: 0x48,
                             payload: Data([0])))
        #expect(!Pocket3StationProtocol.isValidRequest(wrongPayload))
        let wrongRoute = Pocket3StationBLECommand(
            operation: .enterStationMode,
            frame: DUMLFrame(source: 2, destination: 7, sequence: 1,
                             flags: 0x40, commandSet: 7, commandID: 0x49,
                             payload: Data([1])))
        #expect(!Pocket3StationProtocol.isValidRequest(wrongRoute))
        for (source, destination, flags) in [(1, 7, 0x40), (2, 6, 0x40),
                                              (2, 7, 0x00)] {
            let forged = Pocket3StationBLECommand(
                operation: .enterStationMode,
                frame: DUMLFrame(source: UInt8(source),
                                 destination: UInt8(destination), sequence: 1,
                                 flags: UInt8(flags), commandSet: 7,
                                 commandID: 0x48, payload: Data([1])))
            #expect(!Pocket3StationProtocol.isValidRequest(forged))
        }
        let malformedJoin = Pocket3StationBLECommand(
            operation: .joinNetwork,
            frame: DUMLFrame(source: 2, destination: 7, sequence: 1,
                             flags: 0x40, commandSet: 7, commandID: 0x47,
                             payload: Data([1, 0x41, 2, 0x42])))
        #expect(!Pocket3StationProtocol.isValidRequest(malformedJoin))
    }

    @Test func LANExecutorRejectsInvalidHostAndDefaultRouteChangeWithoutSocket()
        async throws {
        let identity = try Pocket3StationIdentity(cameraSSID: "Pocket-3")
        let binding = try Pocket3StationSessionBinding(
            bleSessionID: UUID(), peripheralID: UUID(), generation: 1,
            bleIdentity: identity)
        let changedRoute = StationRouteObservationFake(before: 4, after: 5)
        let executor = Pocket3StationDatalinkLANExecutor(
            clientIdentifier: "client",
            networkObservation: changedRoute)
        do {
            _ = try await executor.discoverAndConnect(
                host: "192.168.1.42", binding: binding,
                expectedIdentity: identity)
            Issue.record("A changed default route must block station setup")
        } catch let error as BridgeFailure {
            #expect(error.code == "station_default_route_changed")
        }
        do {
            _ = try await executor.discoverAndConnect(
                host: "camera.local", binding: binding,
                expectedIdentity: identity)
            Issue.record("Station setup must require an explicit IPv4 host")
        } catch let error as Pocket3StationSessionError {
            #expect(error == .invalidHost)
        }

        let unobserved = Pocket3StationDatalinkLANExecutor(
            clientIdentifier: "client",
            networkObservation: StationRouteObservationFake(before: nil, after: nil))
        do {
            _ = try await unobserved.discoverAndConnect(
                host: "192.168.1.42", binding: binding,
                expectedIdentity: identity)
            Issue.record("An unobserved default route must fail closed")
        } catch let error as BridgeFailure {
            #expect(error.code == "station_default_route_unobserved")
        }
    }
}
