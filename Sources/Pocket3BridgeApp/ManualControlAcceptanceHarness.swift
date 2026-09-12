import Foundation
import Pocket3Core

/// Compact result for the developer-only GUI ownership harness. It records
/// event/lease outcomes, never frame pixels or hardware state.
struct ManualControlAcceptanceStep: Codable, Sendable, Equatable {
    let trigger: String
    let stopReason: ContinuousGimbalStopReason?
    let neutralSent: Bool
    let schedulerIdle: Bool
    let passed: Bool
}

struct ManualControlReconnectAcceptanceStep: Codable, Sendable, Equatable {
    let oldStopReason: ContinuousGimbalStopReason?
    let oldNeutralSent: Bool
    let oldSchedulerIdle: Bool
    let newSessionStarted: Bool
    let staleOldGestureDidNotStopNew: Bool
    let passed: Bool
}

struct ManualControlAcceptanceProjection: Codable, Sendable, Equatable {
    let version: Int
    let developerOnly: Bool
    let hardwareExecuted: Bool
    let nearInputMagnitude: Double
    let farInputMagnitude: Double
    let nearCommandOffset: Int?
    let farCommandOffset: Int?
    let mappingPassed: Bool
    let mouseRelease: ManualControlAcceptanceStep
    let keyRelease: ManualControlAcceptanceStep
    let explicitStop: ManualControlAcceptanceStep
    let focusLoss: ManualControlAcceptanceStep
    let accessTakeover: ManualControlAcceptanceStep
    let reconnect: ManualControlReconnectAcceptanceStep
    let passed: Bool
    let failureCode: String?

    static func unavailable() -> Self {
        let missing = ManualControlAcceptanceStep(
            trigger: "unavailable", stopReason: nil, neutralSent: false,
            schedulerIdle: true, passed: false)
        return Self(
            version: 1, developerOnly: true, hardwareExecuted: false,
            nearInputMagnitude: USBManualGimbalControlMapping.nearInputMagnitude,
            farInputMagnitude: USBManualGimbalControlMapping.farInputMagnitude,
            nearCommandOffset: nil, farCommandOffset: nil,
            mappingPassed: false, mouseRelease: missing, keyRelease: missing,
            explicitStop: missing, focusLoss: missing, accessTakeover: missing,
            reconnect: .init(oldStopReason: nil, oldNeutralSent: false,
                             oldSchedulerIdle: true, newSessionStarted: false,
                             staleOldGestureDidNotStopNew: false, passed: false),
            passed: false, failureCode: "developer_mode_required")
    }
}

/// Exercises the same AppKit-facing controller ownership lifecycle used by
/// the visible manual controls, with an injected Core fake transport. This is
/// intentionally a diagnostic harness: it cannot open a camera or send a
/// hardware command, and every poll has a fixed upper bound.
@MainActor
enum ManualControlAcceptanceHarness {
    private actor FakeTransport: ContinuousGimbalTransport {
        private(set) var commands: [DUMLJoystickCommand] = []

        func send(_ command: DUMLJoystickCommand,
                  lease: ContinuousGimbalLease,
                  permit: OperationPermit) async throws {
            try permit.perform {}
            commands.append(command)
        }

        func nonNeutralCommands() -> [DUMLJoystickCommand] {
            commands.filter { !$0.isNeutral }
        }
    }

    private struct Fixture {
        let controller: ContinuousGimbalGestureController
        let scheduler: ContinuousGimbalScheduler
        let transport: FakeTransport
    }

    static let version = 1

    /// Run only when the caller explicitly enables the developer validation
    /// mode. Tests pass `developerMode: true` while still using fake I/O.
    static func run(developerMode: Bool = CommandLine.arguments.contains("--hardware-validation")) async -> ManualControlAcceptanceProjection {
        guard developerMode else { return .unavailable() }

        let near = runFixture()
        let nearBegan = near.controller.beginGesture(
            id: UUID(), input: .init(
                x: USBManualGimbalControlMapping.nearInputMagnitude, y: 0))
        let nearStarted = await waitUntil { near.controller.isHolding }
        let nearCommand = await firstNonNeutral(near.transport)
        let nearOffset = nearCommand.map {
            abs(Int($0.yaw) - Int(DUMLJoystickCommand.center))
        }
        let nearRelease = await release(
            near.controller, trigger: "mouse_release", reason: .released,
            scheduler: near.scheduler)

        let far = runFixture()
        let farInput = ContinuousGimbalInput(
            x: USBManualGimbalControlMapping.farInputMagnitude, y: 0)
        let farBegan = far.controller.beginGesture(id: UUID(), input: farInput)
        let farStarted = await waitUntil { far.controller.isHolding }
        let farCommand = await firstNonNeutral(far.transport)
        let farOffset = farCommand.map {
            abs(Int($0.yaw) - Int(DUMLJoystickCommand.center))
        }
        let keyRelease = await release(
            far.controller, trigger: "key_release", reason: .released,
            scheduler: far.scheduler)

        let explicit = runFixture()
        _ = explicit.controller.beginGesture(
            id: UUID(), input: .init(x: USBManualGimbalControlMapping.nearInputMagnitude, y: 0))
        let explicitStarted = await waitUntil { explicit.controller.isHolding }
        let explicitStop = await stop(
            explicit.controller, trigger: "explicit_stop", scheduler: explicit.scheduler)

        let focus = runFixture()
        let focusSurface = UUID()
        let focusID = UUID()
        _ = focus.controller.beginGesture(
            id: focusID, input: .init(x: 0, y: -USBManualGimbalControlMapping.nearInputMagnitude),
            surfaceID: focusSurface)
        let focusStarted = await waitUntil { focus.controller.isHolding }
        focus.controller.endSurface(focusSurface)
        let focusLoss = await finish(
            focus.controller, trigger: "focus_loss", scheduler: focus.scheduler)

        let takeover = runFixture()
        _ = takeover.controller.beginGesture(
            id: UUID(), input: .init(x: USBManualGimbalControlMapping.nearInputMagnitude, y: 0))
        let takeoverStarted = await waitUntil { takeover.controller.isHolding }
        takeover.controller.configure(
            scheduler: nil, binding: nil,
            availability: .blocked("access_takeover"))
        let accessTakeover = await finish(
            takeover.controller, trigger: "access_takeover", scheduler: takeover.scheduler)

        let reconnect = await reconnectFixture()
        let mappingPassed = nearBegan && nearStarted && farBegan && farStarted &&
            nearOffset != nil && farOffset != nil &&
            farOffset! > nearOffset!
        let checks = [
            mappingPassed, nearRelease.passed, keyRelease.passed,
            explicitStarted && explicitStop.passed,
            focusStarted && focusLoss.passed,
            takeoverStarted && accessTakeover.passed,
            reconnect.passed
        ]
        return ManualControlAcceptanceProjection(
            version: version, developerOnly: true, hardwareExecuted: false,
            nearInputMagnitude: USBManualGimbalControlMapping.nearInputMagnitude,
            farInputMagnitude: USBManualGimbalControlMapping.farInputMagnitude,
            nearCommandOffset: nearOffset, farCommandOffset: farOffset,
            mappingPassed: mappingPassed,
            mouseRelease: nearRelease, keyRelease: keyRelease,
            explicitStop: explicitStop, focusLoss: focusLoss,
            accessTakeover: accessTakeover, reconnect: reconnect,
            passed: checks.allSatisfy { $0 },
            failureCode: checks.allSatisfy { $0 } ? nil : "controller_acceptance_failed")
    }

    private static func runFixture() -> Fixture {
        let transport = FakeTransport()
        let scheduler = ContinuousGimbalScheduler(transport: transport)
        let binding = ContinuousGimbalBinding(
            sessionID: "gui-fixture-\(UUID().uuidString)", generation: 1)
        let controller = ContinuousGimbalGestureController(monitorsEnabled: false)
        controller.configure(scheduler: scheduler, binding: binding,
                             availability: .ready)
        return Fixture(controller: controller, scheduler: scheduler,
                       transport: transport)
    }

    private static func release(
        _ controller: ContinuousGimbalGestureController,
        trigger: String,
        reason: ContinuousGimbalStopReason,
        scheduler: ContinuousGimbalScheduler
    ) async -> ManualControlAcceptanceStep {
        _ = await waitUntil { controller.isHolding }
        return await finish(controller, trigger: trigger, reason: reason,
                            scheduler: scheduler)
    }

    private static func stop(
        _ controller: ContinuousGimbalGestureController,
        trigger: String,
        scheduler: ContinuousGimbalScheduler
    ) async -> ManualControlAcceptanceStep {
        await finish(controller, trigger: trigger, reason: .cancelled,
                     scheduler: scheduler)
    }

    private static func finish(
        _ controller: ContinuousGimbalGestureController,
        trigger: String,
        reason: ContinuousGimbalStopReason = .cancelled,
        scheduler: ContinuousGimbalScheduler
    ) async -> ManualControlAcceptanceStep {
        let result = await controller.stop(reason: reason)
        let schedulerIdle = await scheduler.status().phase == .idle
        let controllerIdle = await waitUntil { !controller.canStop }
        let passed = result?.reason == reason &&
            result?.matchedLease == true && result?.neutralSent == true &&
            schedulerIdle && controllerIdle
        return ManualControlAcceptanceStep(
            trigger: trigger, stopReason: result?.reason,
            neutralSent: result?.neutralSent == true,
            schedulerIdle: schedulerIdle, passed: passed)
    }

    private static func reconnectFixture() async -> ManualControlReconnectAcceptanceStep {
        let old = runFixture()
        let oldGestureID = UUID()
        _ = old.controller.beginGesture(
            id: oldGestureID,
            input: .init(x: USBManualGimbalControlMapping.farInputMagnitude, y: 0))
        let oldStarted = await waitUntil { old.controller.isHolding }

        let replacement = runFixture()
        old.controller.configure(
            scheduler: replacement.scheduler, binding: replacement.binding,
            availability: .ready)
        _ = await old.controller.stop(reason: .cancelled)
        let oldStop = old.controller.lastStop
        let oldIdle = await old.scheduler.status().phase == .idle

        let newGestureID = UUID()
        let newStartedImmediately = old.controller.beginGesture(
            id: newGestureID,
            input: .init(x: USBManualGimbalControlMapping.nearInputMagnitude, y: 0))
        let newHeld = await waitUntil { old.controller.isHolding }
        let newSessionStarted = newStartedImmediately && newHeld
        old.controller.endGesture(id: oldGestureID, reason: .focusLost)
        let staleOldGestureDidNotStopNew = old.controller.gestureID == newGestureID &&
            old.controller.isHolding
        _ = await old.controller.stop(reason: .released)
        return ManualControlReconnectAcceptanceStep(
            oldStopReason: oldStop?.reason,
            oldNeutralSent: oldStop?.neutralSent == true,
            oldSchedulerIdle: oldIdle,
            newSessionStarted: oldStarted && newSessionStarted,
            staleOldGestureDidNotStopNew: staleOldGestureDidNotStopNew,
            passed: oldStarted && oldIdle && oldStop?.reason == .cancelled &&
                oldStop?.neutralSent == true && newSessionStarted &&
                staleOldGestureDidNotStopNew)
    }

    private static func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func firstNonNeutral(
        _ transport: FakeTransport
    ) async -> DUMLJoystickCommand? {
        for _ in 0..<80 {
            if let command = await transport.nonNeutralCommands().first {
                return command
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await transport.nonNeutralCommands().first
    }
}
