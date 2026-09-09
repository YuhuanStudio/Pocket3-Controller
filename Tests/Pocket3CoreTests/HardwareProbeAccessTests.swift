import Testing
@testable import Pocket3Core

@Test func unvalidatedMotionProbeIsUnavailableInNormalLaunches() async {
    let service = CameraService()
    let reply = await service.handle(ServiceRequest(token: "test", operation: "validation-move", arguments: .object(["direction": .string("up")])))
    #expect(reply.error?.code == "validation_disabled")
}

@Test func hardwareProbeCannotBeUsedForUnvalidatedLargeTargets() async {
    let service = CameraService(validationEnabled: true)
    for direction in ["home", "front", "back", "absolute", ""] {
        let reply = await service.handle(ServiceRequest(token: "test", operation: "validation-move", arguments: .object(["direction": .string(direction), "panDegrees": .number(180)])))
        #expect(reply.error?.code == "validation_disabled")
    }
}
