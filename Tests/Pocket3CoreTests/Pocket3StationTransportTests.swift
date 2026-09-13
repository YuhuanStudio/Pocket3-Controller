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
        let interfaces = configuration.interfaceIndex.map {
            [Pocket3NetworkInterfaceObservation(name: "en0", index: $0,
                                                 isUp: true, isRunning: true,
                                                 hasIPv4Address: true)]
        } ?? []
        return .init(interfaces: interfaces,
                     cameraRouteInterfaceIndex: configuration.interfaceIndex,
                     cameraRouteReachable: configuration.interfaceIndex.map { _ in true },
                     currentPrimaryInterfaceIndex: after,
                     baselinePrimaryInterfaceIndex: baseline?.primaryInterfaceIndex)
    }
}

private struct StationCandidateProviderFake:
    Pocket3StationLANCandidateProviding {
    let values: [Pocket3StationLANCandidate]
    func candidates() async throws -> [Pocket3StationLANCandidate] { values }
}

private actor StationTCPProbeFake: Pocket3StationLANTCPProbe {
    let hits: Set<String>
    private(set) var calls: [Pocket3StationLANCandidate] = []
    private var inFlight = 0
    private(set) var maximumInFlight = 0

    init(hits: Set<String> = []) { self.hits = hits }

    func probeTCP7001(candidate: Pocket3StationLANCandidate,
                      timeout: TimeInterval) async -> Bool {
        calls.append(candidate)
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        try? await Task.sleep(for: .milliseconds(1))
        return hits.contains(candidate.host)
    }
}

private actor StationCandidateConnectorFake:
    Pocket3StationLANCandidateConnecting {
    let results: [String: Pocket3StationLANEvidence]
    private(set) var requests: [Pocket3StationLANCandidateProbeRequest] = []
    private(set) var closedHosts: [String] = []

    init(results: [String: Pocket3StationLANEvidence]) {
        self.results = results
    }

    func connect(_ request: Pocket3StationLANCandidateProbeRequest) async throws
        -> Pocket3StationLANCandidateProbeConnection {
        requests.append(request)
        guard let evidence = results[request.host] else {
            throw Pocket3StationSessionError.lanTransportUnavailable
        }
        return Pocket3StationLANCandidateProbeConnection(evidence: evidence)
    }

    func close(_ connection: Pocket3StationLANCandidateProbeConnection) async {
        closedHosts.append(connection.evidence.host)
    }
}

private func transportEvidence(
    host: String, identity: Pocket3StationIdentity,
    mode: String = "primary_ipv4_subnet", count: Int = 2
) throws -> Pocket3StationLANEvidence {
    try Pocket3StationLANEvidence(
        host: host, tcp7001Connected: true, udp9004Connected: true,
        identity: identity, identityRaw: identity.raw,
        datalinkOwnerRetained: true, identityReplyValidated: true,
        discoveryMode: mode, candidatesConsidered: count)
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

    @Test func automaticDiscoveryFiltersUnboundCandidatesAndCapsTCPStage()
        async throws {
        let identity = try Pocket3StationIdentity(cameraSSID: "Pocket-3")
        let binding = try Pocket3StationSessionBinding(
            bleSessionID: UUID(), peripheralID: UUID(), generation: 1,
            bleIdentity: identity)
        let candidates = [
            // Explicit candidates are never mixed into automatic discovery.
            Pocket3StationLANCandidate(host: "192.168.1.2",
                                       source: .explicitHost,
                                       interfaceIndex: 4),
            // Missing interface evidence cannot become an unbound probe.
            Pocket3StationLANCandidate(host: "192.168.1.3",
                                       source: .primaryIPv4Subnet),
        ] + (4...15).map {
            Pocket3StationLANCandidate(host: "192.168.1.\($0)",
                                       source: .primaryIPv4Subnet,
                                       interfaceIndex: 4,
                                       localAddress: "192.168.1.100")
        }
        let tcp = StationTCPProbeFake()
        let executor = Pocket3StationDatalinkLANExecutor(
            clientIdentifier: "client",
            networkObservation: StationRouteObservationFake(before: 4, after: 4),
            candidateProvider: StationCandidateProviderFake(values: candidates),
            tcpProbe: tcp,
            discoveryPolicy: Pocket3StationLANDiscoveryPolicy(
                maximumCandidates: 20, maximumConcurrent: 3,
                maximumTCPHits: 2, tcpProbeTimeout: 0.25,
                candidateTimeout: 0.25, overallTimeout: 1))
        do {
            _ = try await executor.discoverAndConnect(
                host: nil, binding: binding, expectedIdentity: identity)
            Issue.record("No TCP hit should not start a full datalink handshake")
        } catch let error as Pocket3StationSessionError {
            #expect(error == .lanDiscoveryNoTCPHits)
        }
        let calls = await tcp.calls
        #expect(calls.count == 12)
        #expect(calls.allSatisfy { $0.source == .primaryIPv4Subnet })
        #expect(calls.allSatisfy { $0.interfaceIndex == 4 })
        #expect(await tcp.maximumInFlight <= 3)
    }

    @Test func automaticDiscoveryPolicyKeepsSubnetAndProbeBounds() {
        let policy = Pocket3StationLANDiscoveryPolicy.bounded
        #expect(policy.maximumCandidates == 254)
        #expect(policy.maximumConcurrent == 24)
        #expect(policy.maximumTCPHits == 8)
        #expect(policy.tcpProbeTimeout <= 1)
        #expect(policy.overallTimeout <= 60)
    }

    @Test func automaticDiscoveryClosesWrongIdentityAndRetainsFirstExactOwner()
        async throws {
        let expected = try Pocket3StationIdentity(cameraSSID: "Pocket-3")
        let wrong = try Pocket3StationIdentity(cameraSSID: "Other-camera")
        let binding = try Pocket3StationSessionBinding(
            bleSessionID: UUID(), peripheralID: UUID(), generation: 1,
            bleIdentity: expected)
        let candidates = [2, 3].map {
            Pocket3StationLANCandidate(host: "192.168.1.\($0)",
                                       source: .primaryIPv4Subnet,
                                       interfaceIndex: 4,
                                       localAddress: "192.168.1.100")
        }
        let tcp = StationTCPProbeFake(hits: Set(candidates.map(\.host)))
        let connector = StationCandidateConnectorFake(results: [
            "192.168.1.2": try transportEvidence(
                host: "192.168.1.2", identity: wrong),
            "192.168.1.3": try transportEvidence(
                host: "192.168.1.3", identity: expected)
        ])
        let executor = Pocket3StationDatalinkLANExecutor(
            clientIdentifier: "client",
            networkObservation: StationRouteObservationFake(before: 4, after: 4),
            candidateProvider: StationCandidateProviderFake(values: candidates),
            tcpProbe: tcp, candidateConnector: connector,
            discoveryPolicy: Pocket3StationLANDiscoveryPolicy(
                maximumCandidates: 10, maximumConcurrent: 2,
                maximumTCPHits: 2, tcpProbeTimeout: 0.25,
                candidateTimeout: 0.25, overallTimeout: 2))
        let result = try await executor.discoverAndConnect(
            host: nil, binding: binding, expectedIdentity: expected)
        #expect(result.host == "192.168.1.3")
        #expect(result.discoveryMode == "primary_ipv4_subnet")
        #expect(result.candidatesConsidered == 2)
        #expect(await tcp.calls.count == 2)
        #expect(await connector.requests.map(\.host) == [
            "192.168.1.2", "192.168.1.3"
        ])
        #expect(await connector.closedHosts == ["192.168.1.2"])
    }

    @Test func explicitHostOverrideSkipsAutomaticTCPStage() async throws {
        let identity = try Pocket3StationIdentity(cameraSSID: "Pocket-3")
        let binding = try Pocket3StationSessionBinding(
            bleSessionID: UUID(), peripheralID: UUID(), generation: 1,
            bleIdentity: identity)
        let tcp = StationTCPProbeFake()
        let connector = StationCandidateConnectorFake(results: [
            "192.168.1.99": try transportEvidence(
                host: "192.168.1.99", identity: identity,
                mode: "explicit_host", count: 1)
        ])
        let executor = Pocket3StationDatalinkLANExecutor(
            clientIdentifier: "client",
            networkObservation: StationRouteObservationFake(before: 4, after: 4),
            candidateProvider: StationCandidateProviderFake(values: []),
            tcpProbe: tcp, candidateConnector: connector,
            discoveryPolicy: .bounded)
        let result = try await executor.discoverAndConnect(
            host: "192.168.1.99", binding: binding, expectedIdentity: identity)
        #expect(result.discoveryMode == "explicit_host")
        #expect(result.candidatesConsidered == 1)
        #expect(await tcp.calls.isEmpty)
        #expect(await connector.requests.map(\.host) == ["192.168.1.99"])
    }
}
