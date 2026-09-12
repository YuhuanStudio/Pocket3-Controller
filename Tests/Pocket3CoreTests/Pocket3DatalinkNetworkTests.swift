import Foundation
import Testing
@testable import Pocket3Core

private final class RecordingSocketOptionApplier: Pocket3DatalinkSocketOptionApplying, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var options: [Pocket3DatalinkSocketOption] = []

    func apply(_ option: Pocket3DatalinkSocketOption, descriptor: Int32) throws {
        lock.withLock { options.append(option) }
    }
}

@Suite("Pocket 3 datalink route safety") struct Pocket3DatalinkNetworkTests {
    private func interface(name: String = "en7", index: UInt32 = 7,
                           usable: Bool = true) -> Pocket3NetworkInterfaceObservation {
        Pocket3NetworkInterfaceObservation(name: name, index: index,
            isUp: usable, isRunning: usable, hasIPv4Address: usable)
    }

    private func configuration(interfaceName: String? = "en7",
                               interfaceIndex: UInt32? = 7) -> Pocket3DatalinkSocketConfiguration {
        Pocket3DatalinkSocketConfiguration(interfaceName: interfaceName,
            interfaceIndex: interfaceIndex, cameraHost: "192.168.2.1")
    }

    @Test func legacyConfigurationRemainsExplicitOnlyAndMakesNoRouteClaim() {
        let plan = Pocket3DatalinkRoutePlanner.plan(
            configuration: .legacy,
            observation: .init())
        #expect(plan.allowed)
        #expect(plan.status.state == .legacyUnbound)
        #expect(plan.status.samePrimaryRoute == nil)
        #expect(plan.status.defaultRouteChanged == nil)
        #expect(plan.boundInterfaceIndex == nil)
        #expect(plan.failureCode == nil)
    }

    @Test func matchingInterfaceAndRouteCanProduceSamePrimaryRoute() {
        let plan = Pocket3DatalinkRoutePlanner.plan(
            configuration: configuration(),
            observation: .init(interfaces: [interface()],
                cameraRouteInterfaceIndex: 7, cameraRouteReachable: true,
                currentPrimaryInterfaceIndex: 7,
                baselinePrimaryInterfaceIndex: 7))
        #expect(plan.allowed)
        #expect(plan.boundInterfaceIndex == 7)
        #expect(plan.status.state == .samePrimaryRoute)
        #expect(plan.status.interfacePresent == true)
        #expect(plan.status.cameraRouteReachable == true)
        #expect(plan.status.samePrimaryRoute == true)
        #expect(plan.status.defaultRouteChanged == false)
    }

    @Test func missingRouteEvidenceIsNotPromotedToReachable() {
        let plan = Pocket3DatalinkRoutePlanner.plan(
            configuration: configuration(),
            observation: .init(interfaces: [interface()],
                cameraRouteInterfaceIndex: 7, cameraRouteReachable: nil))
        #expect(!plan.allowed)
        #expect(plan.status.state == .cameraRouteUnavailable)
        #expect(plan.status.cameraRouteReachable == nil)
        #expect(plan.status.samePrimaryRoute == nil)
        #expect(plan.failureCode == "native_camera_route_unavailable")

        let unknownInterface = Pocket3DatalinkRoutePlanner.plan(
            configuration: configuration(),
            observation: .init(interfaces: [interface()],
                cameraRouteReachable: true))
        #expect(!unknownInterface.allowed)
        #expect(unknownInterface.status.evidence == "camera_route_interface_unknown")
    }

    @Test func interfaceMismatchAndDownInterfaceAreRejectedBeforeSocketOptions() {
        let mismatched = Pocket3DatalinkRoutePlanner.plan(
            configuration: configuration(interfaceName: "en7", interfaceIndex: 8),
            observation: .init(interfaces: [interface(index: 7)],
                cameraRouteInterfaceIndex: 7, cameraRouteReachable: true))
        #expect(!mismatched.allowed)
        #expect(mismatched.status.state == .interfaceUnavailable)
        #expect(mismatched.status.evidence == "interface_name_index_mismatch")

        let down = Pocket3DatalinkRoutePlanner.plan(
            configuration: configuration(),
            observation: .init(interfaces: [interface(usable: false)],
                cameraRouteInterfaceIndex: 7, cameraRouteReachable: true))
        #expect(!down.allowed)
        #expect(down.status.state == .interfaceNotReady)
        #expect(down.failureCode == "native_interface_not_ready")
    }

    @Test func defaultRouteChangeIsReportedAndBlocksExplicitPlan() {
        let plan = Pocket3DatalinkRoutePlanner.plan(
            configuration: configuration(),
            observation: .init(interfaces: [interface()],
                cameraRouteInterfaceIndex: 7, cameraRouteReachable: true,
                currentPrimaryInterfaceIndex: 9,
                baselinePrimaryInterfaceIndex: 7))
        #expect(!plan.allowed)
        #expect(plan.status.state == .defaultRouteChanged)
        #expect(plan.status.samePrimaryRoute == false)
        #expect(plan.status.defaultRouteChanged == true)
        #expect(plan.failureCode == "native_default_route_changed")
    }

    @Test func socketOptionPlanContainsOnlyIPBoundInterfaceForAllowedBoundRoute() {
        let plan = Pocket3DatalinkRoutePlanner.plan(
            configuration: configuration(),
            observation: .init(interfaces: [interface()],
                cameraRouteInterfaceIndex: 7, cameraRouteReachable: true))
        #expect(Pocket3DatalinkSocketOptionPlan(routePlan: plan).options ==
                [.bindIPv4Interface(index: 7)])

        let legacy = Pocket3DatalinkRoutePlanner.plan(
            configuration: .legacy, observation: .init())
        #expect(Pocket3DatalinkSocketOptionPlan(routePlan: legacy).options.isEmpty)
    }

    @Test func explicitSocketRefusesUnplannedRouteWithoutOpeningNetwork() throws {
        let applier = RecordingSocketOptionApplier()
        let socket = Pocket3DatalinkSocket(configuration: configuration(),
                                            routePlan: nil, optionApplier: applier)
        do {
            try socket.tcpPoke(Data([0]), permit: OperationPermit())
            Issue.record("An explicit interface must require an allowed route plan")
        } catch let error as BridgeFailure {
            #expect(error.code == "native_route_unvalidated")
        }
        #expect(applier.options.isEmpty)
        #expect(!socket.isOpen)
    }
}
