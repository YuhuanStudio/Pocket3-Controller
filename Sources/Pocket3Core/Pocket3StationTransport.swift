import Foundation

/// The concrete LAN seam for station mode.  It accepts an operator-supplied
/// IPv4 address, uses the existing TCP7001/UDP9004 datalink owner, and asks
/// that owner for one correlated LAN 07/07 reply.  It never changes the Mac's
/// route or associates with Wi-Fi.
public actor Pocket3StationDatalinkLANExecutor: Pocket3StationLANExecutor {
    private let clientIdentifier: String
    private let networkObservation:
        any Pocket3DatalinkNetworkObservationProviding
    private var datalink: Pocket3Datalink?
    private var stationBinding: Pocket3StationSessionBinding?

    public init(clientIdentifier: String,
                networkObservation: any Pocket3DatalinkNetworkObservationProviding =
                    SystemPocket3DatalinkNetworkObservationProvider()) {
        self.clientIdentifier = clientIdentifier
        self.networkObservation = networkObservation
    }

    public func discoverAndConnect(
        host: String?, binding: Pocket3StationSessionBinding,
        expectedIdentity: Pocket3StationIdentity
    ) async throws -> Pocket3StationLANEvidence {
        guard let host, Self.isIPv4(host) else {
            throw Pocket3StationSessionError.invalidHost
        }
        guard datalink == nil else {
            throw Pocket3StationSessionError.busy
        }

        let configuration = Pocket3DatalinkSocketConfiguration(
            cameraHost: host, joinPolicy: .never)
        let routeBaseline = networkObservation.captureBaseline()
        let beforeRoute = networkObservation.observe(
            configuration: configuration, baseline: routeBaseline)
        if let failure = Self.defaultRouteFailureCode(
            baseline: routeBaseline, observation: beforeRoute) {
            throw BridgeFailure(failure,
                failure == "station_default_route_changed"
                    ? "The current LAN route changed before station setup."
                    : "The current default LAN route could not be observed.")
        }
        let link = Pocket3Datalink(
            clientIdentifier: clientIdentifier,
            pairedDeviceID: binding.peripheralID.uuidString,
            networkConfiguration: configuration)
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
                identityReplyValidated: true)
            datalink = link
            stationBinding = binding
            return evidence
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
        guard stationBinding == binding, datalink != nil else { return }
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
