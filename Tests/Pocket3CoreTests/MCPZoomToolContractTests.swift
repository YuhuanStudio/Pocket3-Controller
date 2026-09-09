import Foundation
import Testing
@testable import Pocket3Core

@Test func zoomToolsRouteOnlyThroughNormalServiceOperations() throws {
    let bound: JSONValue = .object(["expectedSessionID": .string("capture-session")])
    #expect(try MCPZoomToolContract.operation(name: "camera_zoom_status", arguments: .object([:])) == "zoom-status")
    #expect(try MCPZoomToolContract.operation(name: "camera_zoom_status", arguments: bound) == "zoom-status")
    let write: JSONValue = .object(["rawValue": .number(173), "expectedSessionID": .string("capture-session")])
    #expect(try MCPZoomToolContract.operation(name: "camera_set_zoom", arguments: write) == "zoom")
    #expect(throws: BridgeFailure.self) {
        try MCPZoomToolContract.operation(name: "validation-zoom", arguments: write)
    }
}

@Test func zoomToolSchemaRequiresRawIntegerAndExactSessionNotMultiplier() {
    let schema = MCPZoomToolContract.setSchema
    #expect(schema["properties"]["rawValue"]["type"].string == "integer")
    #expect(schema["properties"]["rawValue"]["minimum"].number == 0)
    #expect(schema["properties"]["rawValue"]["maximum"].number == 65535)
    #expect(schema["required"] == .array([.string("rawValue"), .string("expectedSessionID")]))
    #expect(schema["additionalProperties"].bool == false)
    #expect(MCPZoomToolContract.statusSchema["additionalProperties"].bool == false)
}

@Test func zoomToolRejectsFractionalNonfiniteMissingAndExtraArgumentsBeforeIPC() {
    for raw in [Double.nan, .infinity, -.infinity, -1, 0.5, 65536, 1e100] {
        #expect(throws: BridgeFailure.self) {
            try MCPZoomToolContract.operation(name: "camera_set_zoom",
                arguments: .object(["rawValue": .number(raw), "expectedSessionID": .string("capture-session")]))
        }
    }
    let invalid: [JSONValue] = [
        .object([:]),
        .object(["rawValue": .number(100)]),
        .object(["rawValue": .number(100), "expectedSessionID": .string("")]),
        .object(["rawValue": .number(100), "expectedSessionID": .string(" \n ")]),
        .object(["rawValue": .bool(true), "expectedSessionID": .string("capture-session")]),
        .object(["rawValue": .string("100"), "expectedSessionID": .string("capture-session")]),
        .object(["factor": .number(2), "expectedSessionID": .string("capture-session")]),
        .object(["rawValue": .number(100), "expectedSessionID": .string("capture-session"), "origin": .string("manual")]),
        .array([])
    ]
    for arguments in invalid {
        #expect(throws: BridgeFailure.self) {
            try MCPZoomToolContract.operation(name: "camera_set_zoom", arguments: arguments)
        }
    }
}

@Test func zoomStatusRejectsWritePayloadAndMalformedSession() {
    let invalid: [JSONValue] = [
        .object(["rawValue": .number(100)]),
        .object(["expectedSessionID": .number(1)]),
        .object(["expectedSessionID": .null]),
        .object(["expectedSessionID": .string("")])
    ]
    for arguments in invalid {
        #expect(throws: BridgeFailure.self) {
            try MCPZoomToolContract.operation(name: "camera_zoom_status", arguments: arguments)
        }
    }
}
