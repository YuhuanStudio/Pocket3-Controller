import Foundation
import Darwin
import SystemConfiguration

public struct Pocket3DatalinkRouteBaseline: Codable, Sendable, Equatable {
    public let primaryInterfaceIndex: UInt32?

    public init(primaryInterfaceIndex: UInt32?) {
        self.primaryInterfaceIndex = primaryInterfaceIndex
    }
}

/// Read-only network observation boundary. Implementations must not associate
/// with a network, mutate routes, or send camera payloads.
public protocol Pocket3DatalinkNetworkObservationProviding: Sendable {
    func captureBaseline() -> Pocket3DatalinkRouteBaseline
    func observe(configuration: Pocket3DatalinkSocketConfiguration,
                baseline: Pocket3DatalinkRouteBaseline?) -> Pocket3DatalinkRouteObservation
}

public struct Pocket3DatalinkRouteCheckResult: Codable, Sendable, Equatable {
    public let plan: Pocket3DatalinkRoutePlan
    public let baseline: Pocket3DatalinkRouteBaseline
    public let observation: Pocket3DatalinkRouteObservation
    public let readOnly: Bool

    public init(plan: Pocket3DatalinkRoutePlan,
                baseline: Pocket3DatalinkRouteBaseline,
                observation: Pocket3DatalinkRouteObservation,
                readOnly: Bool = true) {
        self.plan = plan
        self.baseline = baseline
        self.observation = observation
        self.readOnly = readOnly
    }

    public static func check(
        provider: any Pocket3DatalinkNetworkObservationProviding,
        configuration: Pocket3DatalinkSocketConfiguration
    ) -> Self {
        let baseline = provider.captureBaseline()
        let observation = provider.observe(configuration: configuration, baseline: baseline)
        let plan = Pocket3DatalinkRoutePlanner.plan(configuration: configuration,
                                                     observation: observation)
        return Self(plan: plan, baseline: baseline, observation: observation)
    }
}

/// macOS read-only provider. `getifaddrs` describes local interfaces,
/// SystemConfiguration supplies the current primary service, and a UDP
/// connect/getsockname pair asks the kernel which local interface would route
/// to the camera. UDP connect does not transmit a datagram or alter routes.
public struct SystemPocket3DatalinkNetworkObservationProvider: Pocket3DatalinkNetworkObservationProviding {
    private static let maximumInterfaces = 64
    private static let maximumIPv4AddressesPerInterface = 16

    private struct InterfaceRecord {
        var name: String
        var index: UInt32
        var isUp: Bool
        var isRunning: Bool
        var ipv4Addresses: [String]

        var observation: Pocket3NetworkInterfaceObservation {
            Pocket3NetworkInterfaceObservation(name: name, index: index,
                isUp: isUp, isRunning: isRunning,
                hasIPv4Address: !ipv4Addresses.isEmpty)
        }
    }

    public init() {}

    public func captureBaseline() -> Pocket3DatalinkRouteBaseline {
        Pocket3DatalinkRouteBaseline(primaryInterfaceIndex: primaryInterfaceIndex())
    }

    public func observe(configuration: Pocket3DatalinkSocketConfiguration,
                        baseline: Pocket3DatalinkRouteBaseline? = nil) -> Pocket3DatalinkRouteObservation {
        let records = interfaceRecords()
        let interfaces = records.map(\.observation)
        let selectedIndex = selectedInterfaceIndex(configuration: configuration,
                                                   interfaces: interfaces)
        let route = cameraRoute(configuration: configuration,
                                records: records, selectedIndex: selectedIndex)
        return Pocket3DatalinkRouteObservation(
            interfaces: interfaces,
            cameraRouteInterfaceIndex: route.interfaceIndex,
            cameraRouteReachable: route.reachable,
            currentPrimaryInterfaceIndex: primaryInterfaceIndex(),
            baselinePrimaryInterfaceIndex: baseline?.primaryInterfaceIndex)
    }

    private func selectedInterfaceIndex(
        configuration: Pocket3DatalinkSocketConfiguration,
        interfaces: [Pocket3NetworkInterfaceObservation]
    ) -> UInt32? {
        let byName = configuration.interfaceName.flatMap { name in
            interfaces.first { $0.name == name }
        }?.index
        let byIndex = configuration.interfaceIndex.flatMap { index in
            interfaces.first { $0.index == index }
        }?.index
        if configuration.interfaceName != nil && configuration.interfaceIndex != nil,
           byName != nil, byIndex != nil, byName != byIndex {
            return nil
        }
        return byName ?? byIndex
    }

    private func interfaceRecords() -> [InterfaceRecord] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }

        var records: [String: InterfaceRecord] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let pointer = cursor {
            let value = pointer.pointee
            guard let namePointer = value.ifa_name else {
                cursor = value.ifa_next
                continue
            }
            let name = String(cString: namePointer)
            let index = if_nametoindex(namePointer)
            let flags = Int32(value.ifa_flags)
            var record = records[name] ?? InterfaceRecord(name: name, index: index,
                isUp: flags & IFF_UP != 0, isRunning: flags & IFF_RUNNING != 0,
                ipv4Addresses: [])
            record.index = index
            record.isUp = flags & IFF_UP != 0
            record.isRunning = flags & IFF_RUNNING != 0
            if let address = value.ifa_addr,
               let ipv4 = ipv4String(address),
               !record.ipv4Addresses.contains(ipv4),
               record.ipv4Addresses.count < Self.maximumIPv4AddressesPerInterface {
                record.ipv4Addresses.append(ipv4)
            }
            records[name] = record
            cursor = value.ifa_next
        }
        return records.values
            .sorted { ($0.index, $0.name) < ($1.index, $1.name) }
            .prefix(Self.maximumInterfaces)
            .map { $0 }
    }

    private func primaryInterfaceIndex() -> UInt32? {
        guard let store = SCDynamicStoreCreate(nil, "Pocket3Datalink" as CFString,
                                               nil, nil),
              let value = SCDynamicStoreCopyValue(
                store, "State:/Network/Global/IPv4" as CFString) as? NSDictionary,
              let name = value["PrimaryInterface"] as? String else { return nil }
        return name.withCString { if_nametoindex($0) }
    }

    private func cameraRoute(
        configuration: Pocket3DatalinkSocketConfiguration,
        records: [InterfaceRecord],
        selectedIndex: UInt32?
    ) -> (interfaceIndex: UInt32?, reachable: Bool?) {
        guard let destination = ipv4Address(configuration.cameraHost) else {
            return (nil, nil)
        }
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return (nil, nil) }
        defer { Darwin.close(descriptor) }

        if let selectedIndex {
            var value = selectedIndex
            guard setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &value,
                             socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
                return (nil, false)
            }
        } else if configuration.isInterfaceBound {
            // The requested interface was not observed. Do not allow the
            // kernel's ordinary route to stand in for an explicit selector.
            return (nil, nil)
        }

        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(9004).bigEndian
        target.sin_addr = destination
        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return (nil, false) }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let localResult = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        let localAddress = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                ipv4String($0)
            }
        }
        guard localResult == 0, let localAddress else {
            return (nil, nil)
        }
        let routeInterface = records.first {
            $0.ipv4Addresses.contains(localAddress)
        }?.index
        return (routeInterface, routeInterface != nil)
    }

    private func ipv4Address(_ value: String) -> in_addr? {
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else { return nil }
        return address
    }

    private func ipv4String(_ address: UnsafePointer<sockaddr>) -> String? {
        guard address.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        var value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee.sin_addr
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                      as: UTF8.self)
    }
}
