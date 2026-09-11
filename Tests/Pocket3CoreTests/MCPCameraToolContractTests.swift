import Foundation
import Testing
@testable import Pocket3Core

@Suite struct MCPCameraToolContractTests {
    @Test func validCallsMapToNormalServiceOperations() throws {
        #expect(try MCPCameraToolContract.operation(name: "camera_status", arguments: .object([:])) == "status")
        #expect(try MCPCameraToolContract.operation(name: "stop_gimbal", arguments: .object([:])) == "stop")
        #expect(try MCPCameraToolContract.operation(name: "camera_pause", arguments: .object([:])) == "pause")
        #expect(try MCPCameraToolContract.operation(name: "camera_compare_frames", arguments: .object([:])) == "compare-frames")
        #expect(try MCPCameraToolContract.operation(name: "camera_connect", arguments: .object([
            "modeID": .string("1920x1080@30"), "pixelFormat": .string("nv12"), "outputPolicy": .string("h264")])) == "connect")
        #expect(try MCPCameraToolContract.operation(name: "camera_connect", arguments: .object(["outputPolicy": .string("hevc")])) == "connect")
        #expect(try MCPCameraToolContract.operation(name: "capture_frame", arguments: .object([:])) == "snapshot")
        #expect(try MCPCameraToolContract.captureDimension(arguments: .object([:])) == 1920)
        for size in [320, 1280, 3840] {
            #expect(try MCPCameraToolContract.captureDimension(arguments: .object(["maxDimension": .number(Double(size))])) == size)
        }
        for direction in MCPCameraToolContract.directions {
            #expect(try MCPCameraToolContract.operation(name: "move_gimbal", arguments: .object(["direction": .string(direction)])) == "move")
        }
        for angles in [JSONValue.object(["panDegrees": .number(0)]), .object(["tiltDegrees": .number(-0.5)]),
                                  .object(["panDegrees": .number(10.25), "tiltDegrees": .number(20)])] {
            #expect(try MCPCameraToolContract.operation(name: "move_gimbal", arguments: angles) == "move")
        }
        #expect(throws: BridgeFailure.self) { try MCPCameraToolContract.operation(name: "validation-move", arguments: .object([:])) }
    }

    @Test func allToolsRequireObjectsAndStatusStopAcceptNoFields() {
        for name in ["camera_status", "capture_frame", "move_gimbal", "stop_gimbal", "camera_connect", "camera_pause", "camera_compare_frames"] {
            for arguments in [JSONValue.null, .array([]), .string("{}"), .number(1), .bool(false)] {
                #expect(throws: BridgeFailure.self) { try MCPCameraToolContract.operation(name: name, arguments: arguments) }
            }
        }
        for name in ["camera_status", "stop_gimbal", "camera_pause", "camera_compare_frames"] {
            #expect(throws: BridgeFailure.self) {
                try MCPCameraToolContract.operation(name: name, arguments: .object(["unknown": .null]))
            }
        }
    }

    @Test func connectRejectsMalformedOrInventedOutputChoices() {
        for arguments in [
            JSONValue.object(["deviceID": .string("")]),
            .object(["pixelFormat": .string("avc1")]),
            .object(["outputPolicy": .string("unknown")]),
            .object(["modeID": .number(1)]),
            .object(["unexpected": .bool(true)])
        ] {
            #expect(throws: BridgeFailure.self) { try MCPCameraToolContract.operation(name: "camera_connect", arguments: arguments) }
        }
        #expect(MCPCameraToolContract.connectSchema["additionalProperties"] == .bool(false))
    }

    @Test func explicitMalformedImageSizeNeverBecomesTheDefault() {
        let invalid: [JSONValue] = [.null, .bool(true), .string("1280"), .array([]), .object([:]),
            .number(319), .number(3841), .number(320.5), .number(.nan), .number(.infinity), .number(1e100)]
        for value in invalid {
            #expect(throws: BridgeFailure.self) {
                try MCPCameraToolContract.captureDimension(arguments: .object(["maxDimension": value]))
            }
        }
        #expect(throws: BridgeFailure.self) {
            try MCPCameraToolContract.captureDimension(arguments: .object(["maxDimension": .number(1280), "origin": .string("manual")]))
        }
    }

    @Test func movementRequiresOneModeAndRejectsUnknownOrMalformedFields() {
        let invalid: [JSONValue] = [
            .object([:]), .object(["direction": .null]), .object(["direction": .bool(true)]),
            .object(["direction": .string("LEFT")]), .object(["direction": .string("absolute")]),
            .object(["direction": .string("left"), "panDegrees": .null]),
            .object(["direction": .string("left"), "tiltDegrees": .number(0)]),
            .object(["panDegrees": .string("0")]), .object(["tiltDegrees": .bool(false)]),
            .object(["panDegrees": .number(0), "tiltDegrees": .null]),
            .object(["panDegrees": .number(0), "origin": .string("manual")]),
            .object(["amount": .number(1)]), .object(["direction": .string("left"), "unexpected": .number(1)])
        ]
        for arguments in invalid {
            #expect(throws: BridgeFailure.self) { try MCPCameraToolContract.operation(name: "move_gimbal", arguments: arguments) }
        }
        for angle in [Double.nan, .infinity, -.infinity, 1e100, MCPCameraToolContract.maximumAngle + 1, MCPCameraToolContract.minimumAngle - 1] {
            #expect(throws: BridgeFailure.self) {
                try MCPCameraToolContract.operation(name: "move_gimbal", arguments: .object(["panDegrees": .number(angle)]))
            }
        }
    }

    @Test func publishedSchemasMatchStaticRuntimeBounds() {
        #expect(MCPCameraToolContract.captureSchema["properties"]["maxDimension"]["type"].string == "integer")
        #expect(MCPCameraToolContract.captureSchema["properties"]["maxDimension"]["minimum"].number == 320)
        #expect(MCPCameraToolContract.captureSchema["properties"]["maxDimension"]["maximum"].number == 3840)
        #expect(MCPCameraToolContract.moveSchema["properties"]["panDegrees"]["minimum"].number == MCPCameraToolContract.minimumAngle)
        #expect(MCPCameraToolContract.moveSchema["properties"]["tiltDegrees"]["maximum"].number == MCPCameraToolContract.maximumAngle)
        for schema in [MCPCameraToolContract.emptySchema, MCPCameraToolContract.captureSchema, MCPCameraToolContract.moveSchema] {
            #expect(schema["additionalProperties"] == .bool(false))
        }
    }

    @Test func directIPCSnapshotRejectsMalformedSizeBeforeCameraReadiness() async {
        let service = CameraService()
        for value in [JSONValue.string("1280"), .bool(true), .null, .number(320.5)] {
            let reply = await service.handle(ServiceRequest(token: "test", operation: "snapshot", arguments: .object(["maxDimension": value])))
            #expect(reply.error?.code == "invalid_size")
            #expect(reply.imageJPEG == nil)
        }
        let unknown = await service.handle(ServiceRequest(token: "test", operation: "snapshot", arguments: .object(["extra": .bool(true)])))
        #expect(unknown.error?.code == "invalid_camera_arguments")
    }
}
