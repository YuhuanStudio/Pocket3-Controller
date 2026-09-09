import Testing
@testable import Pocket3Core

@Suite struct CaptureIsolationPolicyTests {
    @Test func skipUVCRequiresValidatedDevelopmentCallBeforeDeviceAccess() async {
        let ordinary = CameraService()
        let disabled = await ordinary.handle(ServiceRequest(token: "fixture", operation: "validation-connect",
            arguments: .object(["skipUVC": .bool(true)])))
        #expect(disabled.error?.code == "validation_disabled")
        let developer = CameraService(validationEnabled: true)
        for flag in [true, false] {
            let wrongOperation = await developer.handle(ServiceRequest(token: "fixture", operation: "status",
                arguments: .object(["skipUVC": .bool(flag)])))
            #expect(wrongOperation.error?.code == "validation_disabled")
        }
        do {
            try await ordinary.connect(id: "no-device-access", validationSkipUVC: true)
            Issue.record("Non-development direct connect accepted skip-UVC")
        } catch { #expect((error as? BridgeFailure)?.code == "validation_disabled") }
    }

    @Test func skipUVCRejectsNonBooleanArgumentsBeforeEnumeratingDevices() async {
        let service = CameraService(validationEnabled: true)
        for invalid in [JSONValue.string("true"), .number(1), .array([]), .object([:])] {
            let reply = await service.handle(ServiceRequest(token: "fixture", operation: "validation-connect",
                arguments: .object(["skipUVC": invalid])))
            #expect(reply.error?.code == "invalid_skip_uvc")
        }
        // A valid false is accepted by the option parser, then rejected by a
        // deliberately invalid format before any camera discovery or opening.
        let falseFlag = await service.handle(ServiceRequest(token: "fixture", operation: "validation-connect",
            arguments: .object(["skipUVC": .bool(false), "pixelFormat": .string("not-a-format")])))
        #expect(falseFlag.error?.code == "invalid_input_format")
    }
}
