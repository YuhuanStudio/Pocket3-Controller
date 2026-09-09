import Foundation

/// Schema and runtime validation for the original four MCP tools. Validation
/// happens before IPC; actual permissions, freshness, device bounds and motion
/// verification remain CameraService responsibilities.
public enum MCPCameraToolContract {
    public static let statusName = "camera_status"
    public static let captureName = "capture_frame"
    public static let moveName = "move_gimbal"
    public static let stopName = "stop_gimbal"
    public static let directions = ["left", "right", "up", "down", "home", "front", "back"]
    public static let minimumAngle = Double(Int32.min) / 3600
    public static let maximumAngle = Double(Int32.max) / 3600
    public static let emptySchema: JSONValue = .object([
        "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)
    ])
    public static let captureSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["maxDimension": .object([
            "type": .string("integer"), "minimum": .number(320), "maximum": .number(3840)
        ])]), "additionalProperties": .bool(false)
    ])
    private static let angleSchema: JSONValue = .object([
        "type": .string("number"), "minimum": .number(minimumAngle), "maximum": .number(maximumAngle),
        "description": .string("Nominal UVC angle, not calibrated physical degrees. Also obey the current camera_status device bounds.")
    ])
    public static let moveSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "direction": .object(["type": .string("string"), "enum": .array(directions.map(JSONValue.string))]),
            "panDegrees": angleSchema, "tiltDegrees": angleSchema
        ]),
        "oneOf": .array([
            .object(["required": .array([.string("direction")]), "not": .object(["anyOf": .array([
                .object(["required": .array([.string("panDegrees")])]), .object(["required": .array([.string("tiltDegrees")])])
            ])])]),
            .object(["anyOf": .array([
                .object(["required": .array([.string("panDegrees")])]), .object(["required": .array([.string("tiltDegrees")])])
            ]), "not": .object(["required": .array([.string("direction")])])])
        ]), "additionalProperties": .bool(false)
    ])

    public static func operation(name: String, arguments: JSONValue) throws -> String {
        switch name {
        case statusName, stopName:
            let fields = try object(arguments)
            guard fields.isEmpty else { throw BridgeFailure("invalid_camera_arguments", "This tool accepts no arguments") }
            return name == statusName ? "status" : "stop"
        case captureName:
            _ = try captureDimension(arguments: arguments)
            return "snapshot"
        case moveName:
            let fields = try object(arguments)
            guard Set(fields.keys).isSubset(of: ["direction", "panDegrees", "tiltDegrees"]) else {
                throw BridgeFailure("invalid_camera_arguments", "move_gimbal accepts only direction, panDegrees and tiltDegrees")
            }
            if let direction = fields["direction"] {
                guard fields.count == 1, let value = direction.string, directions.contains(value) else {
                    throw BridgeFailure("invalid_target", "Choose one supported direction without angle arguments")
                }
            } else {
                guard !fields.isEmpty else { throw BridgeFailure("invalid_target", "Specify a direction or at least one angle") }
                for value in fields.values {
                    guard let angle = value.number, angle.isFinite, (minimumAngle...maximumAngle).contains(angle) else {
                        throw BridgeFailure("invalid_target", "Angles must be finite numbers representable in signed 32-bit UVC units")
                    }
                }
            }
            return "move"
        default: throw BridgeFailure("unknown_tool", "Unknown camera tool")
        }
    }

    /// The same snapshot boundary is usable by IPC callers. Explicit null,
    /// strings or booleans never silently become the default image size.
    public static func captureDimension(arguments: JSONValue) throws -> Int {
        let fields = try object(arguments)
        guard Set(fields.keys).isSubset(of: ["maxDimension"]) else {
            throw BridgeFailure("invalid_camera_arguments", "capture_frame accepts only maxDimension")
        }
        guard let value = fields["maxDimension"] else { return 1920 }
        guard let number = value.number, number.isFinite, number.rounded() == number,
              (320...3840).contains(number) else {
            throw BridgeFailure("invalid_size", "maxDimension must be an integer from 320 through 3840")
        }
        return Int(number)
    }
    private static func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let fields) = value else { throw BridgeFailure("invalid_camera_arguments", "Tool arguments must be an object") }
        return fields
    }
}
