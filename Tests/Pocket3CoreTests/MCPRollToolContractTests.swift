import Foundation
import Testing
@testable import Pocket3Core

@Suite struct MCPRollToolContractTests {
    @Test func statusAcceptsOnlyItsOptionalSessionBinding() throws {
        #expect(try MCPRollToolContract.operation(name: "camera_roll_status", arguments: .object([:])) == "roll-status")
        #expect(try MCPRollToolContract.operation(name: "camera_roll_status",
            arguments: .object(["expectedSessionID": .string("session-A")])) == "roll-status")
    }

    @Test func statusRejectsMalformedOrWriteLikeArguments() {
        for arguments in [JSONValue.null, .array([]), .object(["expectedSessionID": .string("")]),
                          .object(["expectedSessionID": .number(1)]), .object(["rawValue": .number(0)]),
                          .object(["expectedSessionID": .string("A"), "rawValue": .number(0)])] {
            #expect(throws: BridgeFailure.self) {
                try MCPRollToolContract.operation(name: "camera_roll_status", arguments: arguments)
            }
        }
        #expect(MCPRollToolContract.statusSchema["additionalProperties"] == .bool(false))
    }
}
