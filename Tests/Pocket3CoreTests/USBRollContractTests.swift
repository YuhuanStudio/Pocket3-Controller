import Foundation
import Testing
@testable import Pocket3Core

@Test func rollRPCRequiresExactTypedArgumentsBeforeAnyCameraWork() throws {
    let valid: JSONValue = .object(["rawValue": .number(-12), "expectedSessionID": .string("current-session")])
    let parsed = try USBRollPolicy.arguments(valid, requiresValue: true)
    #expect(parsed.rawValue == -12 && parsed.sessionID == "current-session")
    let invalidValues: [JSONValue] = [.string("-12"), .bool(true), .null, .number(0.5), .number(-32769), .number(32768)]
    for value in invalidValues {
        #expect(throws: BridgeFailure.self) {
            try USBRollPolicy.arguments(.object(["rawValue": value, "expectedSessionID": .string("current-session")]), requiresValue: true)
        }
    }
    let invalidArguments: [JSONValue] = [.null, .array([]), .object([:]),
        .object(["rawValue": .number(1)]),
        .object(["rawValue": .number(1), "expectedSessionID": .string("")]),
        .object(["rawValue": .number(1), "expectedSessionID": .number(1)]),
        .object(["rawValue": .number(1), "expectedSessionID": .string("current-session"), "manual": .bool(true)])]
    for arguments in invalidArguments {
        #expect(throws: BridgeFailure.self) { try USBRollPolicy.arguments(arguments, requiresValue: true) }
    }
    #expect(try USBRollPolicy.arguments(.object([:]), requiresValue: false).sessionID == nil)
    #expect(throws: BridgeFailure.self) { try USBRollPolicy.arguments(valid, requiresValue: false) }
}

@Test func rollDevelopmentWriteCannotBeEnabledByRequestFields() async {
    let service = CameraService(validationEnabled: false)
    let request = ServiceRequest(token: "test", operation: "validation-roll",
        arguments: .object(["rawValue": .number(1), "expectedSessionID": .string("test-session")]), source: .mcp)
    let reply = await service.handle(request)
    #expect(reply.error?.code == "validation_disabled")
    let malformed = await service.handle(ServiceRequest(token: "test", operation: "roll",
        arguments: .object(["rawValue": .bool(true), "expectedSessionID": .string("test-session")]), source: .mcp))
    #expect(malformed.error?.code == "invalid_roll_value")
}
