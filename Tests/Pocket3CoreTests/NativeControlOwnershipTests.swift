import Foundation
import Testing
@testable import Pocket3Core

private actor StopRecorder {
    var calls = 0
    func stop() -> MotionResult {
        calls += 1
        return MotionResult(accepted: true, completed: false, verified: false,
            verification: "native_neutral_sent", target: nil, observed: nil, message: "neutral sent")
    }
}

@Test func nativeOwnershipRoutesStopAndRejectsUSBProbes() async throws {
    let service = CameraService(validationEnabled: true)
    let recorder = StopRecorder()
    let binding = ContinuousGimbalBinding(sessionID: "native", generation: 1)
    try await service.reserveNativeControl(binding: binding) { await recorder.stop() }
    let stopped = try await service.stop()
    #expect(stopped.verification == "native_neutral_sent")
    #expect(!stopped.verified)
    #expect(await recorder.calls == 1)
    let probe = await service.handle(ServiceRequest(token: "test", operation: "validation-move", arguments: .object(["direction": .string("up")])))
    #expect(probe.error?.code == "native_control_active")
    // A late disconnect from an older native session cannot reopen USB writes.
    await service.releaseNativeControl(binding: .init(sessionID: "native", generation: 0))
    _ = try await service.stop()
    #expect(await recorder.calls == 2)
    await service.releaseNativeControl(binding: binding)
    let inactive = try await service.stop()
    #expect(inactive.verification == "no_active_action")
    #expect(await recorder.calls == 2)
}

@Test func competingNativeConnectionCannotReplaceTheCurrentOwner() async throws {
    let service = CameraService()
    let owner = StopRecorder(), challenger = StopRecorder()
    try await service.reserveNativeControl(binding: .init(sessionID: "one", generation: 1)) { await owner.stop() }
    await #expect(throws: BridgeFailure.self) {
        try await service.reserveNativeControl(binding: .init(sessionID: "two", generation: 2)) { await challenger.stop() }
    }
    _ = try await service.stop()
    #expect(await owner.calls == 1)
    #expect(await challenger.calls == 0)
}

@Test func serviceStatusPublishesNativeIntentAndDiscardsReleasedOwnerReadback() async throws {
    let service = CameraService()
    let binding = ContinuousGimbalBinding(sessionID: "private-native-binding", generation: 1)
    var transport = Pocket3DatalinkStatus()
    transport.phase = .ready; transport.binding = binding
    transport.lastTelemetryAge = 0.01; transport.lastHeartbeatAge = 0.01
    let native = NativeControlStatus(transport: transport, expectedBinding: binding,
        holding: true, controlsAvailable: true)
    let recorder = StopRecorder()
    try await service.reserveNativeControl(binding: binding, readStatus: { native }) { await recorder.stop() }
    let reply = await service.handle(ServiceRequest(token: "test", operation: "status"))
    let status = try #require(reply.result).decode(ServiceStatus.self)
    #expect(status.nativeControl == native)
    #expect(status.motionActive)
    #expect(status.controlTransport == "native_joystick")
    #expect(!status.stopValidated)
    #expect(status.nativeControl?.automationAvailable == false)
    await service.releaseNativeControl(binding: binding)
    try await service.reserveNativeControl(binding: binding, readStatus: {
        await service.releaseNativeControl(binding: binding)
        return native
    }) { await recorder.stop() }
    let changed = await service.status()
    #expect(changed.nativeControl?.availability == .connectionChanged)
    #expect(!changed.motionActive)
    #expect(changed.controlTransport == "usb_position")
}
