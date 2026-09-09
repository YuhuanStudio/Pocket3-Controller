import Foundation
import Testing
@testable import Pocket3Core

@Test func diagnosticsDoNotExposeDeviceImagesActivityOrErrorPaths() throws {
    let marker = "PRIVATE-DEVICE-AND-PATH"
    let input: JSONValue = .object([
        "phase": .string("error"), "access": .string("manual"), "permission": .string("denied"),
        "devices": .array([.object(["id":.string(marker),"name":.string(marker)])]),
        "selected": .object(["id":.string(marker),"name":.string(marker)]),
        "capture": .object(["sessionID":.string(marker),"frames":.number(8),"recentFPS":.number(30),"audio":.object(["buffers":.number(0),"sampleFrames":.number(0),"sampleRate":.number(0),"channels":.number(0),"rms":.number(0),"peak":.number(0)])]),
        "motionActive":.bool(false),"stopValidated":.bool(false),"stopStrategy":.string("hold"),
        "lastError":.string(marker),"activities":.array([try .encode(Activity("capture",marker))]),"appVersion":.string("0.1.0")
    ])
    let result = try Diagnostics.redacted(input.decode(ServiceStatus.self))
    #expect(!result.pretty.contains(marker))
    #expect(result["hasError"] == .bool(true))
    #expect(result["capture"]["frames"] == .number(8))
    #expect(result["redacted"] == .bool(true))
}
