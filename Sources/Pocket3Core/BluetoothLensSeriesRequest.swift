import Foundation

/// Shared strict contract for the development CLI/RPC. No duration, property,
/// route, setter or implicit peer-selection override is accepted.
public struct BluetoothLensSeriesRequest: Sendable, Equatable {
    public static let operation = "validation-wireless-lens-series"
    public let expectedSessionID: UUID
    public let peripheralID: UUID

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys) == ["expectedSessionID", "peripheralID"],
              let sessionText = fields["expectedSessionID"]?.string,
              let peerText = fields["peripheralID"]?.string,
              let session = UUID(uuidString: sessionText), let peer = UUID(uuidString: peerText) else {
            throw BridgeFailure("invalid_lens_series_request", "Pass the exact Bluetooth session and peripheral UUIDs; no other arguments are accepted")
        }
        expectedSessionID = session; peripheralID = peer
    }

    public init(cliArguments: [String]) throws {
        guard cliArguments.count == 4 else {
            throw BridgeFailure("usage", "pocket3 validation-wireless-lens-series --session BLE-SESSION-UUID --peripheral PERIPHERAL-UUID")
        }
        var fields: [String: JSONValue] = [:]
        for index in stride(from: 0, to: cliArguments.count, by: 2) {
            let key: String
            switch cliArguments[index] {
            case "--session": key = "expectedSessionID"
            case "--peripheral": key = "peripheralID"
            default: throw BridgeFailure("usage", "Only --session and --peripheral are accepted for lens-series")
            }
            guard fields[key] == nil else { throw BridgeFailure("usage", "Duplicate lens-series option") }
            fields[key] = .string(cliArguments[index + 1])
        }
        try self.init(arguments: .object(fields))
    }

    public var arguments: JSONValue {
        .object(["expectedSessionID": .string(expectedSessionID.uuidString), "peripheralID": .string(peripheralID.uuidString)])
    }
}
