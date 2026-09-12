import Foundation

/// Camera network selection is explicit and never owns the Mac's Wi-Fi
/// association.  `joinPolicy` has one possible value so a decoded
/// configuration cannot opt into automatic joining by accident.
public enum Pocket3DatalinkJoinPolicy: String, Codable, Sendable, Equatable {
    case never
}

public struct Pocket3DatalinkSocketConfiguration: Codable, Sendable, Equatable {
    public static let defaultCameraHost = "192.168.2.1"

    public let interfaceName: String?
    public let interfaceIndex: UInt32?
    public let cameraHost: String
    public let joinPolicy: Pocket3DatalinkJoinPolicy

    /// The legacy configuration leaves interface selection to the existing
    /// kernel route.  An explicit interface requires a route plan before the
    /// socket can be opened.
    public static let legacy = Self()

    public init(interfaceName: String? = nil, interfaceIndex: UInt32? = nil,
                cameraHost: String = Self.defaultCameraHost,
                joinPolicy: Pocket3DatalinkJoinPolicy = .never) {
        self.interfaceName = interfaceName
        self.interfaceIndex = interfaceIndex
        self.cameraHost = cameraHost
        self.joinPolicy = joinPolicy
    }

    public var isInterfaceBound: Bool {
        interfaceName != nil || interfaceIndex != nil
    }
}

public struct Pocket3NetworkInterfaceObservation: Codable, Sendable, Equatable {
    public let name: String
    public let index: UInt32
    public let isUp: Bool
    public let isRunning: Bool
    public let hasIPv4Address: Bool

    public init(name: String, index: UInt32, isUp: Bool, isRunning: Bool,
                hasIPv4Address: Bool) {
        self.name = name
        self.index = index
        self.isUp = isUp
        self.isRunning = isRunning
        self.hasIPv4Address = hasIPv4Address
    }

    public var usableForCameraRoute: Bool {
        index != 0 && isUp && isRunning && hasIPv4Address
    }
}

/// A route probe result supplied by an owner outside the planner.  `nil`
/// means the relevant fact was not observed; callers must not turn it into a
/// positive route claim.
public struct Pocket3DatalinkRouteObservation: Codable, Sendable, Equatable {
    public let interfaces: [Pocket3NetworkInterfaceObservation]
    public let cameraRouteInterfaceIndex: UInt32?
    public let cameraRouteReachable: Bool?
    public let currentPrimaryInterfaceIndex: UInt32?
    public let baselinePrimaryInterfaceIndex: UInt32?

    public init(interfaces: [Pocket3NetworkInterfaceObservation] = [],
                cameraRouteInterfaceIndex: UInt32? = nil,
                cameraRouteReachable: Bool? = nil,
                currentPrimaryInterfaceIndex: UInt32? = nil,
                baselinePrimaryInterfaceIndex: UInt32? = nil) {
        self.interfaces = interfaces
        self.cameraRouteInterfaceIndex = cameraRouteInterfaceIndex
        self.cameraRouteReachable = cameraRouteReachable
        self.currentPrimaryInterfaceIndex = currentPrimaryInterfaceIndex
        self.baselinePrimaryInterfaceIndex = baselinePrimaryInterfaceIndex
    }
}

public enum Pocket3DatalinkRouteState: String, Codable, Sendable, Equatable {
    case unknown
    case legacyUnbound
    case interfaceUnavailable
    case interfaceNotReady
    case cameraRouteUnavailable
    case interfaceBound
    case samePrimaryRoute
    case defaultRouteChanged
}

/// Status deliberately keeps route comparisons optional.  A missing primary
/// route baseline is reported as unknown rather than inferred from interface
/// names, addresses or the fact that a socket was created.
public struct Pocket3DatalinkRouteStatus: Codable, Sendable, Equatable {
    public let state: Pocket3DatalinkRouteState
    public let interfaceName: String?
    public let interfaceIndex: UInt32?
    public let cameraHost: String
    public let interfacePresent: Bool?
    public let cameraRouteReachable: Bool?
    public let samePrimaryRoute: Bool?
    public let defaultRouteChanged: Bool?
    public let evidence: String

    public init(state: Pocket3DatalinkRouteState,
                interfaceName: String? = nil,
                interfaceIndex: UInt32? = nil,
                cameraHost: String = Pocket3DatalinkSocketConfiguration.defaultCameraHost,
                interfacePresent: Bool? = nil,
                cameraRouteReachable: Bool? = nil,
                samePrimaryRoute: Bool? = nil,
                defaultRouteChanged: Bool? = nil,
                evidence: String = "unobserved") {
        self.state = state
        self.interfaceName = interfaceName
        self.interfaceIndex = interfaceIndex
        self.cameraHost = cameraHost
        self.interfacePresent = interfacePresent
        self.cameraRouteReachable = cameraRouteReachable
        self.samePrimaryRoute = samePrimaryRoute
        self.defaultRouteChanged = defaultRouteChanged
        self.evidence = evidence
    }

    public static let unknown = Self(state: .unknown)
}

public struct Pocket3DatalinkRoutePlan: Codable, Sendable, Equatable {
    public let configuration: Pocket3DatalinkSocketConfiguration
    public let status: Pocket3DatalinkRouteStatus
    public let allowed: Bool
    public let boundInterfaceIndex: UInt32?

    public init(configuration: Pocket3DatalinkSocketConfiguration,
                status: Pocket3DatalinkRouteStatus,
                allowed: Bool,
                boundInterfaceIndex: UInt32? = nil) {
        self.configuration = configuration
        self.status = status
        self.allowed = allowed
        self.boundInterfaceIndex = boundInterfaceIndex
    }

    public var failureCode: String? {
        guard !allowed else { return nil }
        switch status.state {
        case .interfaceUnavailable: return "native_interface_unavailable"
        case .interfaceNotReady: return "native_interface_not_ready"
        case .cameraRouteUnavailable: return "native_camera_route_unavailable"
        case .defaultRouteChanged: return "native_default_route_changed"
        case .unknown: return "native_route_unvalidated"
        case .legacyUnbound, .interfaceBound, .samePrimaryRoute: return "native_route_invalid"
        }
    }
}

/// Pure route policy.  It never enumerates interfaces, opens sockets, sends
/// packets or changes a default route.
public enum Pocket3DatalinkRoutePlanner {
    public static func plan(
        configuration: Pocket3DatalinkSocketConfiguration,
        observation: Pocket3DatalinkRouteObservation
    ) -> Pocket3DatalinkRoutePlan {
        guard configuration.joinPolicy == .never else {
            return .init(configuration: configuration,
                status: .init(state: .unknown, cameraHost: configuration.cameraHost,
                              evidence: "automatic_join_policy_rejected"), allowed: false)
        }

        guard configuration.isInterfaceBound else {
            return .init(configuration: configuration,
                status: .init(state: .legacyUnbound, cameraHost: configuration.cameraHost,
                              evidence: "legacy_kernel_route_unmodified"), allowed: true)
        }

        guard configuration.interfaceName?.isEmpty != true,
              configuration.interfaceIndex != 0 else {
            return .init(configuration: configuration,
                status: .init(state: .interfaceUnavailable,
                              interfaceName: configuration.interfaceName,
                              interfaceIndex: configuration.interfaceIndex,
                              cameraHost: configuration.cameraHost,
                              interfacePresent: false,
                              evidence: "invalid_interface_selector"), allowed: false)
        }

        let byName = configuration.interfaceName.flatMap { name in
            observation.interfaces.first { $0.name == name }
        }
        let byIndex = configuration.interfaceIndex.flatMap { index in
            observation.interfaces.first { $0.index == index }
        }
        let selected: Pocket3NetworkInterfaceObservation?
        if configuration.interfaceName != nil, configuration.interfaceIndex != nil {
            guard let byName, let byIndex, byName.index == byIndex.index else {
                return .init(configuration: configuration,
                    status: .init(state: .interfaceUnavailable,
                                  interfaceName: configuration.interfaceName,
                                  interfaceIndex: configuration.interfaceIndex,
                                  cameraHost: configuration.cameraHost,
                                  interfacePresent: false,
                                  evidence: "interface_name_index_mismatch"), allowed: false)
            }
            selected = byName
        } else {
            selected = byName ?? byIndex
        }
        guard let selected else {
            return .init(configuration: configuration,
                status: .init(state: .interfaceUnavailable,
                              interfaceName: configuration.interfaceName,
                              interfaceIndex: configuration.interfaceIndex,
                              cameraHost: configuration.cameraHost,
                              interfacePresent: false,
                              evidence: "interface_not_observed"), allowed: false)
        }
        let selectedIndex = selected.index
        let common = {
            Pocket3DatalinkRouteStatus(state: .interfaceBound,
                interfaceName: selected.name, interfaceIndex: selectedIndex,
                cameraHost: configuration.cameraHost, interfacePresent: true,
                cameraRouteReachable: observation.cameraRouteReachable,
                evidence: "explicit_interface_observation")
        }
        guard selected.usableForCameraRoute else {
            return .init(configuration: configuration,
                status: .init(state: .interfaceNotReady,
                              interfaceName: selected.name, interfaceIndex: selectedIndex,
                              cameraHost: configuration.cameraHost, interfacePresent: true,
                              evidence: "interface_not_up_running_with_ipv4"), allowed: false)
        }
        guard observation.cameraRouteReachable == true,
              observation.cameraRouteInterfaceIndex == selectedIndex else {
            return .init(configuration: configuration,
                status: .init(state: .cameraRouteUnavailable,
                              interfaceName: selected.name, interfaceIndex: selectedIndex,
                              cameraHost: configuration.cameraHost, interfacePresent: true,
                              cameraRouteReachable: observation.cameraRouteReachable,
                              evidence: observation.cameraRouteInterfaceIndex == nil
                                  ? "camera_route_interface_unknown" : "camera_route_uses_other_interface"), allowed: false)
        }

        if let baseline = observation.baselinePrimaryInterfaceIndex,
           let current = observation.currentPrimaryInterfaceIndex {
            let same = baseline == current
            let status = Pocket3DatalinkRouteStatus(
                state: same ? .samePrimaryRoute : .defaultRouteChanged,
                interfaceName: selected.name, interfaceIndex: selectedIndex,
                cameraHost: configuration.cameraHost, interfacePresent: true,
                cameraRouteReachable: true, samePrimaryRoute: same,
                defaultRouteChanged: !same,
                evidence: "primary_route_baseline_compared")
            return .init(configuration: configuration, status: status,
                         allowed: same, boundInterfaceIndex: same ? selectedIndex : nil)
        }

        return .init(configuration: configuration, status: common(),
                     allowed: true, boundInterfaceIndex: selectedIndex)
    }
}

/// The only socket option used for explicit interface binding.  Keeping this
/// as a value type makes the Darwin call independently testable without
/// creating a socket or touching the current network.
public enum Pocket3DatalinkSocketOption: Sendable, Equatable {
    case bindIPv4Interface(index: UInt32)
}

public enum Pocket3DatalinkSocketOptionError: Error, Equatable, Sendable {
    case invalidInterfaceIndex
    case bindFailed
}

public protocol Pocket3DatalinkSocketOptionApplying: Sendable {
    func apply(_ option: Pocket3DatalinkSocketOption, descriptor: Int32) throws
}

public struct Pocket3DatalinkSocketOptionPlan: Sendable, Equatable {
    public let options: [Pocket3DatalinkSocketOption]

    public init(routePlan: Pocket3DatalinkRoutePlan) {
        if routePlan.allowed, let index = routePlan.boundInterfaceIndex {
            options = [.bindIPv4Interface(index: index)]
        } else {
            options = []
        }
    }
}
