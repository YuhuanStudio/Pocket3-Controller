import Foundation

/// The concrete LAN seam for station mode. It accepts an optional explicit
/// IPv4 address; when absent it first probes a bounded primary-subnet list on
/// the primary interface, then uses the existing TCP7001/UDP9004 datalink
/// owner for one correlated LAN 07/07 reply. It never changes the Mac's route
/// or associates with Wi-Fi.
public actor Pocket3StationDatalinkLANExecutor: Pocket3StationLANExecutor {
    private let clientIdentifier: String
    private let networkObservation:
        any Pocket3DatalinkNetworkObservationProviding
    private let candidateProvider: any Pocket3StationLANCandidateProviding
    private let tcpProbe: any Pocket3StationLANTCPProbe
    private let candidateConnector: (any Pocket3StationLANCandidateConnecting)?
    private let discoveryPolicy: Pocket3StationLANDiscoveryPolicy
    private var datalink: Pocket3Datalink?
    private var stationBinding: Pocket3StationSessionBinding?

    public init(clientIdentifier: String,
                networkObservation: any Pocket3DatalinkNetworkObservationProviding =
                    SystemPocket3DatalinkNetworkObservationProvider(),
                candidateProvider: any Pocket3StationLANCandidateProviding =
                    Pocket3StationPrimarySubnetCandidateProvider(),
                tcpProbe: any Pocket3StationLANTCPProbe =
                    Pocket3StationSystemTCP7001Probe(),
                candidateConnector: (any Pocket3StationLANCandidateConnecting)? = nil,
                discoveryPolicy: Pocket3StationLANDiscoveryPolicy = .bounded) {
        self.clientIdentifier = clientIdentifier
        self.networkObservation = networkObservation
        self.candidateProvider = candidateProvider
        self.tcpProbe = tcpProbe
        self.candidateConnector = candidateConnector
        self.discoveryPolicy = discoveryPolicy
    }

    public func discoverAndConnect(
        host: String?, binding: Pocket3StationSessionBinding,
        expectedIdentity: Pocket3StationIdentity
    ) async throws -> Pocket3StationLANEvidence {
        guard datalink == nil else {
            throw Pocket3StationSessionError.busy
        }

        if let host {
            guard Self.isIPv4(host) else {
                throw Pocket3StationSessionError.invalidHost
            }
            let baseline = networkObservation.captureBaseline()
            let connection = try await connectCandidate(
                host: host, binding: binding, expectedIdentity: expectedIdentity,
                routeBaseline: baseline, discoveryMode: "explicit_host",
                candidatesConsidered: 1,
                candidateInterfaceIndex: baseline.primaryInterfaceIndex,
                tcpCandidatesProbed: 0)
            datalink = connection.link
            stationBinding = binding
            return connection.evidence
        }

        return try await discoverOnPrimaryLAN(
            binding: binding, expectedIdentity: expectedIdentity)
    }

    private struct CandidateConnection: Sendable {
        let evidence: Pocket3StationLANEvidence
        let link: Pocket3Datalink?
    }

    private enum CandidateProbeOutcome: Sendable {
        case connected(CandidateConnection)
        case failed(String)
        case cancelled
    }

    private struct TCPProbeResult: Sendable {
        let hits: [Pocket3StationLANCandidate]
        let probed: Int
    }

    private func discoverOnPrimaryLAN(
        binding: Pocket3StationSessionBinding,
        expectedIdentity: Pocket3StationIdentity
    ) async throws -> Pocket3StationLANEvidence {
        let baseline = networkObservation.captureBaseline()
        guard baseline.primaryInterfaceIndex != nil else {
            throw BridgeFailure("station_default_route_unobserved",
                "The current primary LAN route could not be observed.")
        }
        let rawCandidates = try await candidateProvider.candidates()
        var candidates: [Pocket3StationLANCandidate] = []
        var seen = Set<String>()
        for candidate in rawCandidates {
            guard candidate.source == .primaryIPv4Subnet,
                  candidate.interfaceIndex == baseline.primaryInterfaceIndex,
                  Self.isIPv4(candidate.host),
                  seen.insert(candidate.host).inserted else { continue }
            candidates.append(candidate)
            if candidates.count == discoveryPolicy.maximumCandidates { break }
        }
        guard !candidates.isEmpty else {
            throw Pocket3StationSessionError.lanDiscoveryNoCandidates
        }

        let deadline = ProcessInfo.processInfo.systemUptime +
            discoveryPolicy.overallTimeout
        let tcpResult = try await tcpProbeCandidates(
            candidates, baseline: baseline, deadline: deadline)
        guard !tcpResult.hits.isEmpty else {
            throw Pocket3StationSessionError.lanDiscoveryNoTCPHits
        }

        var lastFailure = "station_lan_candidate_rejected"
        var fullAttempts = 0
        for candidate in tcpResult.hits {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw Pocket3StationSessionError.lanDiscoveryTimeout
            }
            fullAttempts += 1
            switch await probeCandidate(
                candidate.host, binding: binding,
                expectedIdentity: expectedIdentity,
                routeBaseline: baseline,
                candidatesConsidered: fullAttempts,
                candidateInterfaceIndex: candidate.interfaceIndex,
                tcpCandidatesProbed: tcpResult.probed,
                deadline: deadline) {
            case .connected(let connection):
                datalink = connection.link
                stationBinding = binding
                return connection.evidence
            case .failed(let code):
                lastFailure = code
            case .cancelled:
                try Task.checkCancellation()
                lastFailure = "station_candidate_cancelled"
            }
        }
        try Task.checkCancellation()
        if lastFailure == "station_candidate_timeout" ||
            ProcessInfo.processInfo.systemUptime >= deadline {
            throw Pocket3StationSessionError.lanDiscoveryTimeout
        }
        throw Pocket3StationSessionError.lanIdentityMismatch
    }

    private func tcpProbeCandidates(
        _ candidates: [Pocket3StationLANCandidate],
        baseline: Pocket3DatalinkRouteBaseline,
        deadline: TimeInterval
    ) async throws -> TCPProbeResult {
        var hits: [Pocket3StationLANCandidate] = []
        var offset = 0
        let routeConfiguration = Pocket3DatalinkSocketConfiguration.legacy
        while offset < candidates.count,
              hits.count < discoveryPolicy.maximumTCPHits {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw Pocket3StationSessionError.lanDiscoveryTimeout
            }
            let routeObservation = networkObservation.observe(
                configuration: routeConfiguration, baseline: baseline)
            if let failure = Self.defaultRouteFailureCode(
                baseline: baseline, observation: routeObservation) {
                throw BridgeFailure(failure,
                    failure == "station_default_route_changed"
                        ? "The primary LAN route changed during discovery."
                        : "The primary LAN route could not be observed.")
            }
            let end = min(offset + discoveryPolicy.maximumConcurrent,
                          candidates.count)
            let batch = Array(candidates[offset..<end])
            let results = await withTaskGroup(
                of: (Pocket3StationLANCandidate, Bool).self,
                returning: [(Pocket3StationLANCandidate, Bool)].self) { group in
                for candidate in batch {
                    group.addTask { [tcpProbe, timeout = discoveryPolicy.tcpProbeTimeout] in
                        let hit = await tcpProbe.probeTCP7001(
                            candidate: candidate, timeout: timeout)
                        return (candidate, hit)
                    }
                }
                var values: [(Pocket3StationLANCandidate, Bool)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (candidate, hit) in results where hit {
                hits.append(candidate)
                if hits.count == discoveryPolicy.maximumTCPHits { break }
            }
            offset = end
        }
        let order = Dictionary(uniqueKeysWithValues: candidates.enumerated().map {
            ($0.element.host, $0.offset)
        })
        return TCPProbeResult(
            hits: hits.sorted { (order[$0.host] ?? .max) < (order[$1.host] ?? .max) },
            probed: offset)
    }

    private func probeCandidate(
        _ host: String, binding: Pocket3StationSessionBinding,
        expectedIdentity: Pocket3StationIdentity,
        routeBaseline: Pocket3DatalinkRouteBaseline,
        candidatesConsidered: Int,
        candidateInterfaceIndex: UInt32?,
        tcpCandidatesProbed: Int,
        deadline: TimeInterval
    ) async -> CandidateProbeOutcome {
        do {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return .failed("station_candidate_timeout")
            }
            return await withTaskGroup(of: CandidateProbeOutcome.self) { group in
                group.addTask { [self] in
                    do {
                        let connection = try await self.connectCandidate(
                            host: host, binding: binding,
                            expectedIdentity: expectedIdentity,
                            routeBaseline: routeBaseline,
                            discoveryMode: "primary_ipv4_subnet",
                            candidatesConsidered: candidatesConsidered,
                            candidateInterfaceIndex: candidateInterfaceIndex,
                            tcpCandidatesProbed: tcpCandidatesProbed,
                            deadline: deadline)
                        return .connected(connection)
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .failed(Self.errorCode(error))
                    }
                }
                group.addTask { [timeout = discoveryPolicy.candidateTimeout] in
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        return .failed("station_candidate_timeout")
                    } catch {
                        return .cancelled
                    }
                }
                let first = await group.next() ?? .failed("station_candidate_failed")
                group.cancelAll()
                return first
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(Self.errorCode(error))
        }
    }

    private func connectCandidate(
        host: String, binding: Pocket3StationSessionBinding,
        expectedIdentity: Pocket3StationIdentity,
        routeBaseline: Pocket3DatalinkRouteBaseline,
        discoveryMode: String,
        candidatesConsidered: Int,
        candidateInterfaceIndex: UInt32?,
        tcpCandidatesProbed: Int,
        deadline: TimeInterval = .infinity
    ) async throws -> CandidateConnection {
        guard Self.isIPv4(host) else {
            throw Pocket3StationSessionError.invalidHost
        }

        if let candidateConnector {
            guard let interfaceIndex = candidateInterfaceIndex,
                  interfaceIndex != 0 else {
                throw BridgeFailure("station_default_route_unobserved",
                    "The current primary LAN interface could not be selected.")
            }
            let configuration = Pocket3DatalinkSocketConfiguration(
                interfaceIndex: interfaceIndex, cameraHost: host,
                joinPolicy: .never)
            let beforeRoute = networkObservation.observe(
                configuration: configuration, baseline: routeBaseline)
            if let failure = Self.defaultRouteFailureCode(
                baseline: routeBaseline, observation: beforeRoute) {
                throw BridgeFailure(failure,
                    failure == "station_default_route_changed"
                        ? "The primary LAN route changed before this candidate."
                        : "The primary LAN route could not be observed.")
            }
            let beforePlan = Pocket3DatalinkRoutePlanner.plan(
                configuration: configuration, observation: beforeRoute)
            guard beforePlan.allowed else {
                throw BridgeFailure(beforePlan.failureCode ?? "station_route_invalid",
                    "The current primary LAN route cannot reach this candidate.")
            }
            let request = Pocket3StationLANCandidateProbeRequest(
                host: host, binding: binding, expectedIdentity: expectedIdentity,
                interfaceIndex: interfaceIndex, discoveryMode: discoveryMode,
                candidatesConsidered: candidatesConsidered, deadline: deadline)
            let connection = try await candidateConnector.connect(request)
            let evidence = connection.evidence
            let afterRoute = networkObservation.observe(
                configuration: configuration, baseline: routeBaseline)
            if let failure = Self.defaultRouteFailureCode(
                baseline: routeBaseline, observation: afterRoute) {
                await candidateConnector.close(connection)
                throw BridgeFailure(failure,
                    failure == "station_default_route_changed"
                        ? "The primary LAN route changed during this candidate."
                        : "The primary LAN route could not be observed after this candidate.")
            }
            guard evidence.transportReady,
                  evidence.identityReplyValidated,
                  evidence.identity.matches(expectedIdentity),
                  evidence.identityRaw == expectedIdentity.raw else {
                await candidateConnector.close(connection)
                throw Pocket3StationSessionError.lanIdentityMismatch
            }
            let normalized = try Pocket3StationLANEvidence(
                host: evidence.host,
                tcp7001Connected: evidence.tcp7001Connected,
                udp9004Connected: evidence.udp9004Connected,
                identity: evidence.identity,
                identityRaw: evidence.identityRaw,
                identityCommand: evidence.identityCommand,
                datalinkOwnerRetained: evidence.datalinkOwnerRetained,
                identityReplyValidated: evidence.identityReplyValidated,
                discoveryMode: discoveryMode,
                candidatesConsidered: candidatesConsidered,
                tcpCandidatesProbed: tcpCandidatesProbed)
            return CandidateConnection(evidence: normalized,
                                       link: connection.datalink)
        }

        guard let interfaceIndex = candidateInterfaceIndex,
              interfaceIndex != 0 else {
            throw BridgeFailure("station_default_route_unobserved",
                "The current primary LAN interface could not be selected.")
        }
        let configuration = Pocket3DatalinkSocketConfiguration(
            interfaceIndex: interfaceIndex, cameraHost: host,
            joinPolicy: .never)
        let beforeRoute = networkObservation.observe(
            configuration: configuration, baseline: routeBaseline)
        if let failure = Self.defaultRouteFailureCode(
            baseline: routeBaseline, observation: beforeRoute) {
            throw BridgeFailure(failure,
                failure == "station_default_route_changed"
                    ? "The current LAN route changed before station setup."
                    : "The current default LAN route could not be observed.")
        }
        let beforePlan = Pocket3DatalinkRoutePlanner.plan(
            configuration: configuration, observation: beforeRoute)
        guard beforePlan.allowed else {
            throw BridgeFailure(beforePlan.failureCode ?? "station_route_invalid",
                "The current primary LAN route cannot reach this candidate.")
        }
        let link = Pocket3Datalink(
            clientIdentifier: clientIdentifier,
            pairedDeviceID: binding.peripheralID.uuidString,
            networkConfiguration: configuration, routePlan: beforePlan)
        do {
            let linkBinding = try await link.connect()
            let linkStatus = await link.status()
            guard linkStatus.phase == .ready,
                  linkStatus.tcpBootstrapErrorCode == nil else {
                throw Pocket3StationSessionError.lanTransportUnavailable
            }
            let afterRoute = networkObservation.observe(
                configuration: configuration, baseline: routeBaseline)
            if let failure = Self.defaultRouteFailureCode(
                baseline: routeBaseline, observation: afterRoute) {
                throw BridgeFailure(failure,
                    failure == "station_default_route_changed"
                        ? "Station setup changed the Mac's default route."
                        : "The default LAN route could not be observed after setup.")
            }
            let afterPlan = Pocket3DatalinkRoutePlanner.plan(
                configuration: configuration, observation: afterRoute)
            guard afterPlan.allowed else {
                throw BridgeFailure(afterPlan.failureCode ?? "station_route_invalid",
                    "The primary LAN route is no longer valid for this candidate.")
            }

            let frame = try NativeCommandFrame(
                source: 0x02, destination: 0x07, flags: 0x40,
                commandSet: 0x07, commandID: 0x07)
            let request = try NativeCommandTransactionRequest(
                command: .stationIdentity, generation: linkBinding.generation,
                sessionID: UUID(uuidString: linkBinding.sessionID), frame: frame,
                timeout: 2) { response in
                    guard response.source == 0x07,
                          response.destination == 0x02,
                          response.commandSet == 0x07,
                          response.commandID == 0x07 else { return nil }
                    // Preserve the complete opaque 07/07 payload only inside
                    // this transaction. The mapper below extracts the AP
                    // SSID in memory and stores only its digest in evidence;
                    // no serial/model is inferred from unknown bytes.
                    return response.payload
                }
            let readiness = NativeCameraSessionStatus(
                state: .commandReady, generation: linkBinding.generation,
                sessionID: UUID(uuidString: linkBinding.sessionID),
                peerID: binding.peripheralID)
            let transaction = try await link.transact(request, readiness: readiness)
            guard transaction.responseReceived, transaction.acknowledged,
                  transaction.observed, let raw = transaction.observedPayload else {
                throw Pocket3StationSessionError.unsupportedReply
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw Pocket3StationSessionError.lanDiscoveryTimeout
            }
            guard let identity = Pocket3StationProtocol.cameraSSIDIdentity(
                from: raw) else {
                throw Pocket3StationSessionError.unsupportedReply
            }
            guard identity.matches(expectedIdentity),
                  identity.raw == expectedIdentity.raw else {
                throw Pocket3StationSessionError.lanIdentityMismatch
            }
            let evidence = try Pocket3StationLANEvidence(
                host: host, tcp7001Connected: true, udp9004Connected: true,
                identity: identity,
                identityRaw: identity.raw, identityCommand: "07/07",
                datalinkOwnerRetained: true,
                identityReplyValidated: true,
                discoveryMode: discoveryMode,
                candidatesConsidered: candidatesConsidered,
                tcpCandidatesProbed: tcpCandidatesProbed)
            return CandidateConnection(evidence: evidence, link: link)
        } catch {
            _ = await link.disconnect()
            throw error
        }
    }

    /// Returns the same owner instance used for the station identity check.
    /// The caller must retain the station binding and use this only while the
    /// coordinator remains command-ready.
    public func connectedDatalink(
        for binding: Pocket3StationSessionBinding
    ) -> Pocket3Datalink? {
        guard stationBinding == binding else { return nil }
        return datalink
    }

    public func close(_ evidence: Pocket3StationLANEvidence,
                      binding: Pocket3StationSessionBinding) async {
        guard stationBinding == binding else { return }
        if let datalink { _ = await datalink.disconnect() }
        datalink = nil
        stationBinding = nil
    }

    private static func defaultRouteFailureCode(
        baseline: Pocket3DatalinkRouteBaseline,
        observation: Pocket3DatalinkRouteObservation
    ) -> String? {
        guard let before = baseline.primaryInterfaceIndex,
              let after = observation.currentPrimaryInterfaceIndex else {
            return "station_default_route_unobserved"
        }
        return before == after ? nil : "station_default_route_changed"
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3,
                  let value = UInt16(part) else { return false }
            return value <= 255 && (part.count == 1 || part.first != "0")
        }
    }

    private static func errorCode(_ error: Error) -> String {
        switch error {
        case Pocket3StationSessionError.invalidHost: return "station_invalid_host"
        case Pocket3StationSessionError.lanDiscoveryNoCandidates:
            return "station_lan_discovery_no_candidates"
        case Pocket3StationSessionError.lanDiscoveryNoTCPHits:
            return "station_lan_discovery_no_tcp_hits"
        case Pocket3StationSessionError.lanDiscoveryTimeout:
            return "station_lan_discovery_timeout"
        case Pocket3StationSessionError.lanIdentityMismatch:
            return "station_lan_identity_mismatch"
        case Pocket3StationSessionError.lanTransportUnavailable:
            return "station_lan_transport_unavailable"
        default: return String(String(describing: error).prefix(96))
        }
    }
}

/// Bridges the existing MainActor CoreBluetooth owner to the pure station
/// coordinator.  No second manager, FFF5 subscription, or BLE writer is
/// created by this adapter.
public final class Pocket3BluetoothStationBLEExecutor:
    Pocket3StationBLEExecutor, @unchecked Sendable {
    private weak var discovery: Pocket3BluetoothDiscovery?

    public init(discovery: Pocket3BluetoothDiscovery) {
        self.discovery = discovery
    }

    public func send(_ command: Pocket3StationBLECommand,
                     binding: Pocket3StationSessionBinding) async throws
        -> Pocket3StationBLEReply {
        guard let discovery else {
            throw Pocket3StationSessionError.staleBinding
        }
        return try await Task { @MainActor in
            try await discovery.sendStationCommand(command, binding: binding)
        }.value
    }

    public func revalidate(_ binding: Pocket3StationSessionBinding) async throws
        -> Pocket3StationSessionBinding {
        guard let discovery else {
            throw Pocket3StationSessionError.staleBinding
        }
        return try await Task { @MainActor in
            try discovery.revalidateStationBinding(binding)
        }.value
    }
}
