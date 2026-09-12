import Foundation
import Pocket3Core

extension AppModel {
    /// Read-only developer route check. It observes the current kernel route
    /// and primary interface, then lets the Core planner decide whether an
    /// explicit datalink binding is safe. It never associates Wi-Fi or opens
    /// the camera datalink.
    func handleNativeNetworkRouteValidation(_ request: ServiceRequest) throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled", "Network route validation requires a development launch")
        }
        guard case .object(let fields) = request.arguments else {
            throw BridgeFailure("invalid_network_route_arguments", "Network route validation requires an object")
        }
        guard Set(fields.keys).isSubset(of: ["interfaceName", "interfaceIndex", "cameraHost"]) else {
            throw BridgeFailure("invalid_network_route_arguments", "Use interfaceName, interfaceIndex and cameraHost only")
        }
        let interfaceName: String?
        if let value = fields["interfaceName"] {
            guard let name = value.string, !name.isEmpty else {
                throw BridgeFailure("invalid_network_interface", "interfaceName must be a non-empty BSD interface name")
            }
            interfaceName = name
        } else {
            interfaceName = nil
        }
        let interfaceIndex: UInt32?
        if let value = fields["interfaceIndex"] {
            guard let number = value.number, number.isFinite,
                  number.rounded() == number,
                  number >= 1, number <= Double(UInt32.max) else {
                throw BridgeFailure("invalid_network_interface", "interfaceIndex must be a positive UInt32")
            }
            interfaceIndex = UInt32(number)
        } else {
            interfaceIndex = nil
        }
        let cameraHost: String
        if let value = fields["cameraHost"] {
            guard let host = value.string, !host.isEmpty else {
                throw BridgeFailure("invalid_camera_host", "cameraHost must be a non-empty IPv4 address")
            }
            cameraHost = host
        } else {
            cameraHost = Pocket3DatalinkSocketConfiguration.defaultCameraHost
        }

        let configuration = Pocket3DatalinkSocketConfiguration(
            interfaceName: interfaceName, interfaceIndex: interfaceIndex,
            cameraHost: cameraHost)
        let provider = SystemPocket3DatalinkNetworkObservationProvider()
        let result = Pocket3DatalinkRouteCheckResult.check(
            provider: provider, configuration: configuration)
        return ServiceReply(id: request.id, result: try .encode(result))
    }
}
