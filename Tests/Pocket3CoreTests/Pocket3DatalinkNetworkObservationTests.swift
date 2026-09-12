import Foundation
import Testing
@testable import Pocket3Core

private struct FakeRouteObservationProvider: Pocket3DatalinkNetworkObservationProviding {
    let baseline: Pocket3DatalinkRouteBaseline
    let observation: Pocket3DatalinkRouteObservation

    func captureBaseline() -> Pocket3DatalinkRouteBaseline { baseline }

    func observe(configuration: Pocket3DatalinkSocketConfiguration,
                 baseline: Pocket3DatalinkRouteBaseline?) -> Pocket3DatalinkRouteObservation {
        observation
    }
}

@Suite("Pocket 3 read-only network observation") struct Pocket3DatalinkNetworkObservationTests {
    private func interface() -> Pocket3NetworkInterfaceObservation {
        Pocket3NetworkInterfaceObservation(name: "en7", index: 7,
            isUp: true, isRunning: true, hasIPv4Address: true)
    }

    @Test func fakeProviderFlowsBaselineAndCurrentRouteThroughPlanner() throws {
        let configuration = Pocket3DatalinkSocketConfiguration(
            interfaceName: "en7", interfaceIndex: 7)
        let baseline = Pocket3DatalinkRouteBaseline(primaryInterfaceIndex: 7)
        let observation = Pocket3DatalinkRouteObservation(
            interfaces: [interface()], cameraRouteInterfaceIndex: 7,
            cameraRouteReachable: true, currentPrimaryInterfaceIndex: 7,
            baselinePrimaryInterfaceIndex: 7)
        let result = Pocket3DatalinkRouteCheckResult.check(
            provider: FakeRouteObservationProvider(baseline: baseline,
                observation: observation), configuration: configuration)

        #expect(result.readOnly)
        #expect(result.baseline == baseline)
        #expect(result.observation == observation)
        #expect(result.plan.allowed)
        #expect(result.plan.status.state == .samePrimaryRoute)
        #expect(result.plan.status.defaultRouteChanged == false)
    }

    @Test func fakeProviderCannotPromoteUnknownRouteOrPrimaryBaseline() throws {
        let configuration = Pocket3DatalinkSocketConfiguration(
            interfaceName: "en7", interfaceIndex: 7)
        let observation = Pocket3DatalinkRouteObservation(
            interfaces: [interface()], cameraRouteInterfaceIndex: nil,
            cameraRouteReachable: nil, currentPrimaryInterfaceIndex: nil,
            baselinePrimaryInterfaceIndex: nil)
        let result = Pocket3DatalinkRouteCheckResult.check(
            provider: FakeRouteObservationProvider(
                baseline: Pocket3DatalinkRouteBaseline(primaryInterfaceIndex: nil),
                observation: observation), configuration: configuration)

        #expect(!result.plan.allowed)
        #expect(result.plan.status.state == .cameraRouteUnavailable)
        #expect(result.plan.status.samePrimaryRoute == nil)
        #expect(result.plan.status.defaultRouteChanged == nil)
        #expect(result.plan.failureCode == "native_camera_route_unavailable")
    }

    @Test func routeCheckResultRoundTripsWithoutNetworkAccess() throws {
        let configuration = Pocket3DatalinkSocketConfiguration.legacy
        let baseline = Pocket3DatalinkRouteBaseline(primaryInterfaceIndex: nil)
        let observation = Pocket3DatalinkRouteObservation()
        let result = Pocket3DatalinkRouteCheckResult.check(
            provider: FakeRouteObservationProvider(baseline: baseline,
                observation: observation), configuration: configuration)
        let encoded = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(Pocket3DatalinkRouteCheckResult.self,
            from: encoded) == result)
    }
}
