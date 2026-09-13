import Foundation

/// MCP contract for the camera's internal ordinary-Video recorder. The tool
/// delegates to the same CameraBodyRecordingService used by the CLI; it never
/// represents USB preview recording or a second native transport.
public enum MCPBodyRecordingToolContract {
    public static let name = "camera_body_recording"
    public static let operation = CameraBodyRecordingRequest.operation
    public static let description = "Start or stop the Pocket 3 internal Video recorder, or set one legal resolution/FPS pair. Requires the exact native session, peer and generation from camera_body_status; execute defaults to false and completion requires ACK plus matching camera readback."
    public static let actions = CameraBodyRecordingAction.allCases.map(\.rawValue)

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "action": .object(["type": .string("string"),
                                "enum": .array(actions.map(JSONValue.string))]),
            "session": .object(["type": .string("string"), "minLength": .number(1)]),
            "peripheral": .object(["type": .string("string"), "minLength": .number(1)]),
            "generation": .object(["type": .string("integer"), "minimum": .number(1)]),
            "resolution": .object(["type": .string("string")]),
            "fps": .object(["type": .string("string")]),
            "execute": .object(["type": .string("boolean")]),
            "timeout": .object(["type": .string("number"),
                                 "exclusiveMinimum": .number(0),
                                 "maximum": .number(CameraBodyRecordingRequest.maximumTimeout)])
        ]),
        "required": .array([
            .string("action"), .string("session"), .string("peripheral"),
            .string("generation")
        ]),
        "additionalProperties": .bool(false)
    ])

    public static func operation(name: String, arguments: JSONValue) throws -> String {
        guard name == Self.name else {
            throw BridgeFailure("unknown_tool", "Unknown body recording tool")
        }
        _ = try CameraBodyRecordingRequest(arguments: arguments)
        return operation
    }
}

public typealias Pocket3MCPBodyRecordingToolContract = MCPBodyRecordingToolContract
