import Foundation

/// MCP boundary for the general typed native setting writer. The service
/// still requires exact native session IDs and explicit execution; this
/// contract does not create a transport or relax capability admission.
public enum MCPNativeSettingToolContract {
    public static let setName = "camera_set_native_setting"
    public static let statusName = "camera_native_setting_status"
    public static let operation = "native-setting"
    public static let statusOperation = "native-setting-status"
    public static let emptySchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false)
    ])
    public static let setSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array(NativeSettingValidationOperation.allCases.map {
                    .string($0.rawValue)
                })
            ]),
            "expectedSessionID": .object([
                "type": .string("string"), "minLength": .number(36),
                "description": .string("Use nativeReadiness.sessionID from camera status.")
            ]),
            "peripheralID": .object([
                "type": .string("string"), "minLength": .number(36),
                "description": .string("Use nativeReadiness.peerID from camera status.")
            ]),
            "generation": .object([
                "type": .string("integer"), "minimum": .number(1)
            ]),
            "value": .object([
                "oneOf": .array([
                    .object(["type": .string("string")]),
                    .object(["type": .string("integer")])
                ])
            ]),
            "execute": .object([
                "type": .string("boolean"),
                "const": .bool(true),
                "description": .string("Must be true; writes are always explicit.")
            ]),
            "timeout": .object([
                "type": .string("number"), "exclusiveMinimum": .number(0),
                "maximum": .number(NativeCommandTransactionRequest.maximumTimeout)
            ])
        ]),
        "required": .array([
            .string("action"), .string("expectedSessionID"),
            .string("peripheralID"), .string("generation"),
            .string("value"), .string("execute")
        ]),
        "additionalProperties": .bool(false)
    ])

    public static func operation(
        name: String,
        arguments: JSONValue
    ) throws -> String {
        if name == statusName {
            guard arguments == .object([:]) else {
                throw BridgeFailure(
                    "invalid_native_setting_arguments",
                    "camera_native_setting_status accepts no arguments")
            }
            return statusOperation
        }
        guard name == setName else {
            throw BridgeFailure("unknown_tool", "Unknown native camera setting tool")
        }
        let request: NativeSettingValidationRequest
        do {
            request = try NativeSettingValidationRequest(arguments: arguments)
        } catch let error as NativeSettingValidationError {
            throw BridgeFailure(
                "invalid_native_setting_request", error.localizedDescription)
        }
        guard request.execute else {
            throw BridgeFailure(
                "native_setting_execute_required",
                "camera_set_native_setting requires execute=true")
        }
        return operation
    }
}
