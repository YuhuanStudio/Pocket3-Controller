import Foundation
import Pocket3Core
import Testing
@testable import Pocket3BridgeApp

private actor GestureTestTransport: ContinuousGimbalTransport {
    struct Write: Sendable { let command: DUMLJoystickCommand; let lease: ContinuousGimbalLease }
    private(set) var writes: [Write] = []
    private var rejectNeutral = false
    func failNeutral() { rejectNeutral = true }
    func send(_ command: DUMLJoystickCommand, lease: ContinuousGimbalLease, permit: OperationPermit) async throws {
        try permit.perform {
            if command.isNeutral && rejectNeutral { throw BridgeFailure("test_neutral_failure", "No hardware") }
            writes.append(Write(command: command, lease: lease))
        }
    }
}
private actor GesturePreparationGate {
    private var waiter: CheckedContinuation<Void, Never>?
    var waiting: Bool { waiter != nil }
    func wait() async { await withCheckedContinuation { waiter = $0 } }
    func release() { let pending = waiter; waiter = nil; pending?.resume() }
}
private enum GestureTestError: Error { case timeout }
@MainActor private func eventuallyGesture(_ condition: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GestureTestError.timeout
}
private let gestureTestBinding = ContinuousGimbalBinding(sessionID: "gesture-fixture", generation: 1)

@MainActor @Test func unavailableContinuousUICannotStartMotion() async {
    let controller = ContinuousGimbalGestureController(monitorsEnabled: false)
    let transport = GestureTestTransport()
    let scheduler = ContinuousGimbalScheduler(transport: transport)
    #expect(!controller.beginGesture(id: UUID(), input: .init(x: 1, y: 0)))
    controller.configure(scheduler: scheduler, binding: gestureTestBinding, availability: .unsupported)
    #expect(!controller.beginGesture(id: UUID(), input: .init(x: 1, y: 0)))
    #expect(await transport.writes.isEmpty)
}

@MainActor @Test func releaseDuringPreparationNeverStartsAGhostGesture() async throws {
    let controller = ContinuousGimbalGestureController(monitorsEnabled: false)
    let transport = GestureTestTransport(), gate = GesturePreparationGate()
    let scheduler = ContinuousGimbalScheduler(transport: transport)
    controller.configure(scheduler: scheduler, binding: gestureTestBinding, availability: .ready, prepare: { await gate.wait() })
    let id = UUID()
    #expect(controller.beginGesture(id: id, input: .init(x: 1, y: 0)))
    try await eventuallyGesture { await gate.waiting }
    controller.endGesture(id: id)
    await gate.release()
    _ = await controller.stop()
    #expect(controller.gestureID == nil && !controller.isStarting && !controller.isStopping)
    #expect(await transport.writes.isEmpty)
    #expect(await scheduler.status().phase == .idle)
}

@MainActor @Test func heldGestureRenewsHeartbeatAndSpeedUntilMatchingRelease() async throws {
    let controller = ContinuousGimbalGestureController(monitorsEnabled: false)
    let transport = GestureTestTransport()
    let scheduler = ContinuousGimbalScheduler(transport: transport)
    controller.configure(scheduler: scheduler, binding: gestureTestBinding, availability: .ready)
    let id = UUID()
    #expect(controller.beginGesture(id: id, input: .init(x: 1, y: 0)))
    try await eventuallyGesture { controller.isHolding }
    // Longer than Core's 250 ms lease: only the UI's 50 ms renew loop keeps it active.
    try await Task.sleep(for: .milliseconds(330))
    #expect(controller.isHolding && controller.gestureID == id)
    #expect(await scheduler.status().phase == .active)
    controller.setSpeed(0.8)
    try await eventuallyGesture { await transport.writes.last?.command.yaw == 1288 }
    controller.endGesture(id: id)
    let result = await controller.stop()
    #expect(result?.neutralSent == true)
    #expect(await transport.writes.last?.command == .neutral)
    #expect(!controller.isHolding && !controller.isStopping)
}

@MainActor @Test func oldGestureAndOldSurfaceCannotStopNewInteraction() async throws {
    let controller = ContinuousGimbalGestureController(monitorsEnabled: false)
    let transport = GestureTestTransport()
    let scheduler = ContinuousGimbalScheduler(transport: transport)
    controller.configure(scheduler: scheduler, binding: gestureTestBinding, availability: .ready)
    let old = UUID(), oldSurface = UUID()
    #expect(controller.beginGesture(id: old, input: .init(x: 1, y: 0), surfaceID: oldSurface))
    try await eventuallyGesture { controller.isHolding }
    controller.endSurface(oldSurface); _ = await controller.stop()
    let current = UUID(), currentSurface = UUID()
    #expect(controller.beginGesture(id: current, input: .init(x: -1, y: 0), surfaceID: currentSurface))
    try await eventuallyGesture { controller.isHolding }
    controller.endGesture(id: old, reason: .focusLost)
    controller.endSurface(oldSurface)
    #expect(controller.gestureID == current && controller.isHolding)
    #expect(await scheduler.status().phase == .active)
    controller.endSurface(currentSurface)
    #expect((await controller.stop())?.neutralSent == true)
}

@MainActor @Test func repeatedReadyConfigurationPreservesHeldLeaseAndDisconnectEndsIt() async throws {
    let controller = ContinuousGimbalGestureController(monitorsEnabled: false)
    let transport = GestureTestTransport()
    let scheduler = ContinuousGimbalScheduler(transport: transport)
    controller.configure(scheduler: scheduler, binding: gestureTestBinding, availability: .ready)
    let id = UUID()
    #expect(controller.beginGesture(id: id, input: .init(x: 0, y: -1)))
    try await eventuallyGesture { controller.isHolding }
    controller.configure(scheduler: scheduler, binding: gestureTestBinding, availability: .ready)
    #expect(controller.gestureID == id && controller.isHolding)
    controller.configure(scheduler: nil, binding: nil, availability: .disconnected)
    _ = await controller.stop()
    #expect(!controller.canInteract && controller.gestureID == nil)
    #expect(await transport.writes.last?.command == .neutral)
}

@MainActor @Test func failedNeutralBlocksAnotherGestureOnTheSameConnection() async throws {
    let controller = ContinuousGimbalGestureController(monitorsEnabled: false)
    let transport = GestureTestTransport()
    let scheduler = ContinuousGimbalScheduler(transport: transport)
    controller.configure(scheduler: scheduler, binding: gestureTestBinding, availability: .ready)
    #expect(controller.beginGesture(id: UUID(), input: .init(x: 1, y: 0)))
    try await eventuallyGesture { controller.isHolding }
    await transport.failNeutral()
    #expect((await controller.stop())?.neutralSent == false)
    #expect(!controller.canInteract && controller.lastError != nil)
    #expect(!controller.beginGesture(id: UUID(), input: .init(x: -1, y: 0)))
}

@MainActor @Test func gestureAuthorizationRunsAfterPreparationAndReachesLease() async throws {
    let controller = ContinuousGimbalGestureController(monitorsEnabled: false)
    let transport = GestureTestTransport()
    let scheduler = ContinuousGimbalScheduler(transport: transport)
    let ticket = UUID()
    var prepared = false
    controller.configure(scheduler: scheduler, binding: gestureTestBinding, availability: .ready,
        authorize: { #expect(prepared); return ticket }, prepare: { prepared = true })
    let id = UUID()
    #expect(controller.beginGesture(id: id, input: .init(x: 1, y: 0)))
    try await eventuallyGesture { await transport.writes.contains { !$0.command.isNeutral } }
    #expect(await transport.writes.first?.lease.authorizationID == ticket)
    controller.endGesture(id: id)
    _ = await controller.stop()
    #expect(await transport.writes.last?.lease.authorizationID == ticket)
    #expect(await transport.writes.last?.command == .neutral)
}

@MainActor @Test func releaseDuringAuthorizationNeverStartsOrClaimsAGhostLease() async throws {
    let controller = ContinuousGimbalGestureController(monitorsEnabled: false)
    let transport = GestureTestTransport(), gate = GesturePreparationGate()
    let scheduler = ContinuousGimbalScheduler(transport: transport)
    let ticket = UUID()
    controller.configure(scheduler: scheduler, binding: gestureTestBinding, availability: .ready,
        authorize: { await gate.wait(); return ticket })
    let id = UUID()
    #expect(controller.beginGesture(id: id, input: .init(x: 1, y: 0)))
    try await eventuallyGesture { await gate.waiting }
    controller.endGesture(id: id)
    await gate.release()
    _ = await controller.stop()
    #expect(controller.gestureID == nil && !controller.isStarting && !controller.isStopping)
    #expect(await transport.writes.isEmpty)
    #expect(await scheduler.status().phase == .idle)
}

@MainActor @Test func wirelessWithoutNativeOwnerPreservesSharedUSBControls() async throws {
    let controller = ContinuousGimbalGestureController(monitorsEnabled: false)
    let transport = GestureTestTransport()
    let scheduler = ContinuousGimbalScheduler(transport: transport)
    controller.configure(scheduler: scheduler, binding: gestureTestBinding, availability: .ready)
    let wireless = WirelessGimbalModel(service: CameraService(), controls: controller, prepareManual: {})
    let id = UUID()
    #expect(controller.beginGesture(id: id, input: .init(x: 1, y: 0)))
    try await eventuallyGesture { controller.isHolding }
    await wireless.refresh()
    await wireless.disconnectNative()
    #expect(!wireless.ownsContinuousControls && !wireless.bluetooth.isBluetoothInitialized)
    #expect(controller.canInteract && controller.isHolding && controller.gestureID == id)
    #expect(await scheduler.status().phase == .active)
    #expect(await transport.writes.allSatisfy { !$0.command.isNeutral })
    _ = await controller.stop()
}
