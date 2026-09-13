import Foundation
import Darwin
import SystemConfiguration

public enum Pocket3StationLANCandidateSource: String, Codable, Sendable,
    Equatable {
    case primaryIPv4Subnet
    case explicitHost
}

public struct Pocket3StationLANCandidate: Codable, Sendable, Equatable {
    public let host: String
    public let source: Pocket3StationLANCandidateSource
    /// The interface selected from the current primary route. Automatic
    /// candidates without this evidence are discarded before any probe.
    public let interfaceIndex: UInt32?
    public let localAddress: String?

    public init(host: String, source: Pocket3StationLANCandidateSource,
                interfaceIndex: UInt32? = nil, localAddress: String? = nil) {
        self.host = host
        self.source = source
        self.interfaceIndex = interfaceIndex
        self.localAddress = localAddress
    }
}

public struct Pocket3StationLANCandidateProbeRequest: Sendable, Equatable {
    public let host: String
    public let binding: Pocket3StationSessionBinding
    public let expectedIdentity: Pocket3StationIdentity
    public let interfaceIndex: UInt32
    public let discoveryMode: String
    public let candidatesConsidered: Int
    public let deadline: TimeInterval

    public init(host: String, binding: Pocket3StationSessionBinding,
                expectedIdentity: Pocket3StationIdentity,
                interfaceIndex: UInt32, discoveryMode: String,
                candidatesConsidered: Int, deadline: TimeInterval) {
        self.host = host; self.binding = binding
        self.expectedIdentity = expectedIdentity
        self.interfaceIndex = interfaceIndex
        self.discoveryMode = discoveryMode
        self.candidatesConsidered = candidatesConsidered
        self.deadline = deadline
    }
}

/// A connector result is intentionally small and contains only the owner
/// handle plus scalar evidence. The connector closes every rejected result.
public struct Pocket3StationLANCandidateProbeConnection: Sendable {
    public let evidence: Pocket3StationLANEvidence
    public let datalink: Pocket3Datalink?

    public init(evidence: Pocket3StationLANEvidence,
                datalink: Pocket3Datalink? = nil) {
        self.evidence = evidence
        self.datalink = datalink
    }
}

/// Injection boundary for tests and alternate local discovery backends. A
/// production connector must return one bounded owner per candidate and close
/// it when the executor rejects or loses it.
public protocol Pocket3StationLANCandidateConnecting: Sendable {
    func connect(_ request: Pocket3StationLANCandidateProbeRequest) async throws
        -> Pocket3StationLANCandidateProbeConnection
    func close(_ connection: Pocket3StationLANCandidateProbeConnection) async
}

/// Limits automatic LAN probing before any socket is opened.  The defaults
/// are intentionally small: the user can still provide an explicit host when
/// the camera is outside the first bounded primary-subnet candidates.
public struct Pocket3StationLANDiscoveryPolicy: Codable, Sendable, Equatable {
    public static let defaultMaximumCandidates = 254
    /// First-stage TCP probes are cheap and bounded; full DUML handshakes
    /// below remain sequential and are limited by `defaultMaximumTCPHits`.
    public static let defaultMaximumConcurrent = 24
    public static let defaultMaximumTCPHits = 8
    public static let defaultTCPProbeTimeout: TimeInterval = 0.8
    public static let defaultCandidateTimeout: TimeInterval = 3
    public static let defaultOverallTimeout: TimeInterval = 15

    public let maximumCandidates: Int
    public let maximumConcurrent: Int
    public let maximumTCPHits: Int
    public let tcpProbeTimeout: TimeInterval
    public let candidateTimeout: TimeInterval
    public let overallTimeout: TimeInterval

    public init(maximumCandidates: Int = Self.defaultMaximumCandidates,
                maximumConcurrent: Int = Self.defaultMaximumConcurrent,
                maximumTCPHits: Int = Self.defaultMaximumTCPHits,
                tcpProbeTimeout: TimeInterval = Self.defaultTCPProbeTimeout,
                candidateTimeout: TimeInterval = Self.defaultCandidateTimeout,
                overallTimeout: TimeInterval = Self.defaultOverallTimeout) {
        self.maximumCandidates = max(1, min(maximumCandidates, 256))
        self.maximumConcurrent = max(1, min(maximumConcurrent, 24))
        self.maximumTCPHits = max(1, min(maximumTCPHits, 8))
        self.tcpProbeTimeout = tcpProbeTimeout.isFinite
            ? max(0.25, min(tcpProbeTimeout, 1))
            : Self.defaultTCPProbeTimeout
        self.candidateTimeout = candidateTimeout.isFinite
            ? max(0.25, min(candidateTimeout, 5))
            : Self.defaultCandidateTimeout
        self.overallTimeout = overallTimeout.isFinite
            ? max(self.candidateTimeout, min(overallTimeout, 60))
            : Self.defaultOverallTimeout
    }

    public static let bounded = Self()
}

public protocol Pocket3StationLANCandidateProviding: Sendable {
    func candidates() async throws -> [Pocket3StationLANCandidate]
}

/// Read-only primary-interface subnet evidence.  It does not send packets,
/// change routes, query credentials, or perform an ARP/port sweep.
public struct Pocket3StationPrimarySubnetCandidateProvider:
    Pocket3StationLANCandidateProviding {
    private let maximumCandidates: Int

    public init(maximumCandidates: Int =
                    Pocket3StationLANDiscoveryPolicy.defaultMaximumCandidates) {
        self.maximumCandidates = max(1, min(maximumCandidates, 256))
    }

    public func candidates() async throws -> [Pocket3StationLANCandidate] {
        try Task.checkCancellation()
        guard let interfaceName = Self.primaryInterfaceName(),
              let range = Self.primaryIPv4Range(interfaceName: interfaceName) else {
            return []
        }
        var result: [Pocket3StationLANCandidate] = []
        result.reserveCapacity(min(maximumCandidates, 254))
        var host = range.network &+ 1
        while host < range.broadcast, result.count < maximumCandidates {
            if host != range.local {
                result.append(.init(host: Self.string(host),
                                    source: .primaryIPv4Subnet,
                                    interfaceIndex: range.interfaceIndex,
                                    localAddress: Self.string(range.local)))
            }
            host &+= 1
        }
        return result
    }

    private struct IPv4Range {
        let local: UInt32
        let network: UInt32
        let broadcast: UInt32
        let interfaceIndex: UInt32
    }

    private static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(
            nil, "Pocket3StationLAN" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(
                  store, "State:/Network/Global/IPv4" as CFString)
                as? NSDictionary else { return nil }
        return value["PrimaryInterface"] as? String
    }

    private static func primaryIPv4Range(interfaceName: String)
        -> IPv4Range? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let pointer = cursor {
            let value = pointer.pointee
            defer { cursor = value.ifa_next }
            guard let namePointer = value.ifa_name,
                  String(cString: namePointer) == interfaceName,
                  let address = value.ifa_addr,
                  let netmask = value.ifa_netmask,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  netmask.pointee.sa_family == sa_family_t(AF_INET),
                  let local = Self.address(address),
                  let mask = Self.address(netmask),
                  let interfaceIndex = Self.interfaceIndex(namePointer),
                  interfaceIndex != 0 else { continue }
            let trailing = mask.trailingZeroBitCount
            let prefix = 32 - trailing
            // A /24-or-narrower mask is the only automatically enumerated
            // scope. Wider networks remain available through explicit IP.
            guard (24...31).contains(prefix),
                  mask == UInt32.max << trailing else { continue }
            let network = local & mask
            let broadcast = network | ~mask
            return IPv4Range(local: local, network: network,
                             broadcast: broadcast, interfaceIndex: interfaceIndex)
        }
        return nil
    }

    private static func address(_ pointer: UnsafePointer<sockaddr>)
        -> UInt32? {
        let value = pointer.withMemoryRebound(to: sockaddr_in.self,
                                              capacity: 1) {
            $0.pointee.sin_addr.s_addr
        }
        return UInt32(bigEndian: value)
    }

    private static func interfaceIndex(_ pointer: UnsafePointer<CChar>)
        -> UInt32? {
        let value = if_nametoindex(pointer)
        return value == 0 ? nil : value
    }

    private static func string(_ value: UInt32) -> String {
        "\((value >> 24) & 255).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
    }
}

public protocol Pocket3StationLANTCPProbe: Sendable {
    /// Opens one bounded TCP7001 connect and closes it before returning. It
    /// never sends station credentials or changes the host route.
    func probeTCP7001(candidate: Pocket3StationLANCandidate,
                      timeout: TimeInterval) async -> Bool
}

/// A cancellation-aware nonblocking TCP7001 probe. It is intentionally kept
/// separate from the full Pocket3Datalink owner so automatic discovery can
/// cheaply discard most subnet hosts before starting a DUML handshake.
public struct Pocket3StationSystemTCP7001Probe: Pocket3StationLANTCPProbe {
    public init() {}

    public func probeTCP7001(candidate: Pocket3StationLANCandidate,
                             timeout: TimeInterval) async -> Bool {
        guard candidate.source == .primaryIPv4Subnet,
              let interfaceIndex = candidate.interfaceIndex,
              interfaceIndex != 0 else { return false }
        let bounded = timeout.isFinite ? max(0.1, min(timeout, 1)) : 0.8
        return await Task.detached(priority: .utility) {
            Self.blockingProbe(host: candidate.host,
                               interfaceIndex: interfaceIndex,
                               timeout: bounded)
        }.value
    }

    private static func blockingProbe(host: String, interfaceIndex: UInt32,
                                     timeout: TimeInterval) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return false }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }
        var interface = interfaceIndex
        guard setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &interface,
                         socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
            return false
        }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(7001).bigEndian
        destination.sin_addr = address
        let result = withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return !Task.isCancelled }
        guard errno == EINPROGRESS else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if Task.isCancelled { return false }
            var event = pollfd(fd: descriptor, events: Int16(POLLOUT),
                               revents: 0)
            let count = poll(&event, 1, 20)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return false }
            guard count > 0 else { continue }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error,
                             &length) == 0 else { return false }
            return error == 0 && !Task.isCancelled
        }
        return false
    }
}
