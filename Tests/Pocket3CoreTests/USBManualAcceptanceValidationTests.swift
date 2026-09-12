import Foundation
import Testing
@testable import Pocket3Core

@Suite("USB manual acceptance request contract")
struct USBManualAcceptanceValidationTests {
    @Test func dryRunDefaultsToBoundedPlanArguments() throws {
        let request = try USBManualAcceptanceRequest(cliArguments: [])
        #expect(request.execute == false)
        #expect(request.expectedDeviceID == nil)
        #expect(request.expectedSessionID == nil)
        #expect(request.holdSeconds == USBManualAcceptanceRequest.defaultHoldSeconds)
        #expect(request.timeout == USBManualAcceptanceRequest.maximumTimeout)
        #expect(request.arguments["execute"] == .bool(false))
    }

    @Test func executeRequiresBothExactIdentities() {
        #expect(throws: USBManualAcceptanceRequestError.identityRequired) {
            try USBManualAcceptanceRequest(execute: true)
        }
        #expect(throws: USBManualAcceptanceRequestError.identityRequired) {
            try USBManualAcceptanceRequest(expectedDeviceID: "device", execute: true)
        }
        #expect(throws: USBManualAcceptanceRequestError.identityRequired) {
            try USBManualAcceptanceRequest(expectedSessionID: "session", execute: true)
        }
    }

    @Test func cliParserPreservesExactExecuteContract() throws {
        let request = try USBManualAcceptanceRequest(cliArguments: [
            "--device", "0x123", "--session", "capture-4",
            "--hold-seconds", "1.1", "--timeout", "12", "--execute"
        ])
        #expect(request.execute)
        #expect(request.expectedDeviceID == "0x123")
        #expect(request.expectedSessionID == "capture-4")
        #expect(request.holdSeconds == 1.1)
        #expect(request.timeout == 12)
        #expect(request.arguments["device"] == .string("0x123"))
        #expect(request.arguments["session"] == .string("capture-4"))
    }

    @Test func parserRejectsUnknownFlagsAndUnboundedValues() {
        #expect(throws: USBManualAcceptanceRequestError.invalidArguments) {
            try USBManualAcceptanceRequest(cliArguments: ["--images"])
        }
        #expect(throws: USBManualAcceptanceRequestError.invalidArguments) {
            try USBManualAcceptanceRequest(cliArguments: ["--hold-seconds", "1.3"])
        }
        #expect(throws: USBManualAcceptanceRequestError.invalidArguments) {
            try USBManualAcceptanceRequest(cliArguments: ["--timeout", "46"])
        }
        #expect(throws: USBManualAcceptanceRequestError.invalidArguments) {
            try USBManualAcceptanceRequest(arguments: .object([
                "execute": .string("true")
            ]))
        }
        #expect(throws: USBManualAcceptanceRequestError.invalidArguments) {
            try USBManualAcceptanceRequest(arguments: .object([
                "unexpected": .bool(true)
            ]))
        }
    }

    @Test func schemaDisallowsAdditionalPropertiesAndExecutionIsExplicit() {
        #expect(USBManualAcceptanceRequest.schema["additionalProperties"] == .bool(false))
        #expect(USBManualAcceptanceRequest.schema["properties"]["execute"]["type"] == .string("boolean"))
        #expect(USBManualAcceptanceRequest.schema["properties"]["holdSeconds"]["maximum"] ==
                .number(USBManualAcceptanceRequest.maximumHoldSeconds))
    }
}
