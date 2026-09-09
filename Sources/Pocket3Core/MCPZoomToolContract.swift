import Foundation

/// MCP argument/schema boundary only. The existing zoom-status/zoom service
/// operations own actual capability, access, session, cancellation and writes.
public enum MCPZoomToolContract {
    public static let statusName = "camera_zoom_status"
    public static let setName = "camera_set_zoom"
    private static let sessionProperty: JSONValue = .object([
        "type": .string("string"), "minLength": .number(1),
        "description": .string("Use capture.sessionID from camera_status for the same selected camera connection.")
    ])
    public static let statusSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["expectedSessionID": sessionProperty]),
        "additionalProperties": .bool(false)
    ])
    public static let setSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "rawValue": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(65535),
                "description": .string("Device UVC raw integer. First read camera_zoom_status; obey its minimum, maximum and step. This is not an x zoom multiplier.")]),
            "expectedSessionID": sessionProperty
        ]),
        "required": .array([.string("rawValue"), .string("expectedSessionID")]),
        "additionalProperties": .bool(false)
    ])

    /// Validate even when a client ignores tools/list schemas. Malformed calls
    /// are rejected before IPC; valid calls still receive all service checks.
    public static func operation(name: String, arguments: JSONValue) throws -> String {
        guard case .object(let fields) = arguments else {
            throw BridgeFailure("invalid_zoom_arguments", "Zoom tool arguments must be an object")
        }
        switch name {
        case statusName:
            guard Set(fields.keys).isSubset(of: ["expectedSessionID"]) else {
                throw BridgeFailure("invalid_zoom_arguments", "camera_zoom_status accepts only expectedSessionID")
            }
            if fields["expectedSessionID"] != nil { try validateSession(arguments["expectedSessionID"]) }
            return "zoom-status"
        case setName:
            guard Set(fields.keys) == ["rawValue", "expectedSessionID"] else {
                throw BridgeFailure("invalid_zoom_arguments", "camera_set_zoom requires only rawValue and expectedSessionID")
            }
            guard let number = arguments["rawValue"].number else {
                throw BridgeFailure("invalid_zoom_value", "rawValue must be a device UVC integer")
            }
            _ = try USBZoomPolicy.rawValue(number)
            try validateSession(arguments["expectedSessionID"])
            return "zoom"
        default:
            throw BridgeFailure("unknown_tool", "Unknown camera zoom tool")
        }
    }
    private static func validateSession(_ value: JSONValue) throws {
        guard let session = value.string, !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeFailure("session_required", "Use capture.sessionID from camera_status")
        }
    }
}
