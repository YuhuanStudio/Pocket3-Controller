import Foundation

/// Read-only MCP boundary for the experimental UVC roll control. Roll writes
/// intentionally remain unavailable to MCP until their independent physical
/// moving-stop validation is complete.
public enum MCPRollToolContract {
    public static let statusName = "camera_roll_status"
    public static let statusSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["expectedSessionID": .object(["type": .string("string")])]),
        "additionalProperties": .bool(false)
    ])

    public static func operation(name: String, arguments: JSONValue) throws -> String {
        guard name == statusName, case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: ["expectedSessionID"]),
              fields["expectedSessionID"].map({ $0.string.map { !$0.isEmpty } ?? false }) ?? true else {
            throw BridgeFailure("invalid_roll_arguments", "camera_roll_status accepts only an optional non-empty expectedSessionID")
        }
        return "roll-status"
    }
}
