import Foundation
import Testing
@testable import Pocket3Core

private final class AcceptanceTestClock:
    Pocket3NativeGimbalAcceptanceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 10
    var cancelSleep = false
    var now: TimeInterval { lock.withLock { value } }

    func sleep(until deadline: TimeInterval) async throws {
        if cancelSleep { throw CancellationError() }
        lock.withLock { value = max(value, deadline) }
    }
}

private actor AcceptanceFakeOwner: Pocket3NativeGimbalAcceptanceOwner {
    let request: Pocket3NativeGimbalAcceptanceRequest
    private var current: Pocket3NativeGimbalAcceptanceStatus
    private let disconnectAfterSend: Int?
    private var sendCount = 0
    private(set) var inputs: [ContinuousGimbalInput] = []
    private(set) var releases = 0
    private(set) var recenterCount = 0
    private(set) var flipCount = 0
    private(set) var failStopCount = 0

    init(request: Pocket3NativeGimbalAcceptanceRequest,
         disconnectAfterSend: Int? = nil) {
        self.request = request
        self.disconnectAfterSend = disconnectAfterSend
        let telemetry = Pocket3DatalinkTelemetry(
            pitchDegrees: 0, rollDegrees: 0, yawDegrees: 0,
            receivedAt: Date(timeIntervalSince1970: 100))
        current = Pocket3NativeGimbalAcceptanceStatus(
            stationBinding: request.stationBinding,
            lanIdentity: request.stationBinding.bleIdentity,
            lanOwnerRetained: true, nativeBinding: request.nativeBinding,
            nativePhase: .ready, telemetry: telemetry, telemetryFresh: true,
            commandReady: true, observedUptime: 10)
    }

    func status() async -> Pocket3NativeGimbalAcceptanceStatus { current }

    func send(_ input: ContinuousGimbalInput,
              lease: ContinuousGimbalLease,
              permit: OperationPermit) async throws {
        try permit.perform {}
        sendCount += 1
        inputs.append(input)
        guard lease.binding == request.nativeBinding else {
            throw Pocket3NativeGimbalAcceptanceError.connectionChanged
        }
        if let disconnectAfterSend, sendCount >= disconnectAfterSend {
            current = Self.status(current, ready: false)
            throw Pocket3NativeGimbalAcceptanceError.connectionChanged
        }
        current = Self.status(current, ready: true)
    }

    func release(_ lease: ContinuousGimbalLease,
                 permit: OperationPermit) async throws
        -> Pocket3NativeGimbalStopEvidence {
        try permit.perform {}
        releases += 1
        let before = current.telemetry
        current = Self.status(current, ready: true, tick: releases + sendCount)
        return .init(neutralSent: true, telemetryBefore: before,
                     telemetryAfter: current.telemetry)
    }

    func recenter(permit: OperationPermit) async throws
        -> Pocket3DatalinkActionResult {
        try permit.perform {}
        recenterCount += 1
        current = Self.status(current, ready: true, tick: 100 + recenterCount)
        return .init(command: "recenter", requestAccepted: true,
                     responseStatus: 0, physicalCompletionVerified: false)
    }

    func flip(permit: OperationPermit) async throws
        -> Pocket3DatalinkActionResult {
        try permit.perform {}
        flipCount += 1
        current = Self.status(current, ready: true, tick: 200 + flipCount)
        return .init(command: "flip", requestAccepted: true,
                     responseStatus: 0, physicalCompletionVerified: false)
    }

    func failStop() async -> Pocket3NativeGimbalStopEvidence {
        failStopCount += 1
        let before = current.telemetry
        current = Self.status(current, ready: current.commandReady,
                              tick: 300 + failStopCount)
        return .init(neutralSent: current.commandReady,
                     stableTelemetry: current.commandReady,
                     connectionChanged: !current.commandReady,
                     telemetryBefore: before, telemetryAfter: current.telemetry,
                     failureCode: current.commandReady ? nil :
                        "station_acceptance_connection_changed")
    }

    private static func status(
        _ old: Pocket3NativeGimbalAcceptanceStatus,
        ready: Bool, tick: Int = 1
    ) -> Pocket3NativeGimbalAcceptanceStatus {
        let telemetry = Pocket3DatalinkTelemetry(
            pitchDegrees: old.telemetry?.pitchDegrees ?? 0,
            rollDegrees: old.telemetry?.rollDegrees ?? 0,
            yawDegrees: (old.telemetry?.yawDegrees ?? 0) + Double(tick) * 0.01,
            receivedAt: Date(timeIntervalSince1970:
                (old.telemetry?.receivedAt.timeIntervalSince1970 ?? 100) + 1))
        return .init(stationBinding: old.stationBinding,
                     lanIdentity: old.lanIdentity,
                     lanOwnerRetained: old.lanOwnerRetained,
                     nativeBinding: old.nativeBinding,
                     nativePhase: ready ? .ready : .disarmed,
                     telemetry: telemetry, telemetryFresh: ready,
                     commandReady: ready,
                     observedUptime: old.observedUptime + 0.01)
    }
}

private func acceptanceFixture(execute: Bool = false,
                               hold: TimeInterval = 0.1,
                               clock: AcceptanceTestClock? = nil)
    throws -> (Pocket3NativeGimbalAcceptanceRequest, AcceptanceTestClock) {
    let identity = try Pocket3StationIdentity(cameraSSID: "Pocket-3")
    let stationBinding = try Pocket3StationSessionBinding(
        bleSessionID: UUID(), peripheralID: UUID(), generation: 2,
        bleIdentity: identity)
    let evidence = try Pocket3StationLANEvidence(
        host: "192.168.1.42", tcp7001Connected: true,
        udp9004Connected: true, identity: identity, identityRaw: identity.raw,
        datalinkOwnerRetained: true, identityReplyValidated: true)
    let nativeBinding = ContinuousGimbalBinding(sessionID: "lan-session",
                                                 generation: 7)
    let request = try Pocket3NativeGimbalAcceptanceRequest(
        stationBinding: stationBinding, lanEvidence: evidence,
        nativeBinding: nativeBinding, holdSeconds: hold,
        pumpInterval: 0.05, telemetryTimeout: 0.2, execute: execute)
    return (request, clock ?? AcceptanceTestClock())
}

@Suite("Pocket 3 station native gimbal acceptance")
struct Pocket3NativeGimbalAcceptanceTests {
    @Test func dryRunDoesNotTouchTheInjectedOwner() async throws {
        let (request, clock) = try acceptanceFixture()
        let owner = AcceptanceFakeOwner(request: request)
        let result = await Pocket3NativeGimbalAcceptanceExecutor(
            owner: owner, clock: clock).run(request)
        #expect(result.phase == .dryRun && result.dryRun)
        #expect(result.plan.steps == [
            .nearPan, .midPan, .farPan, .nearTilt, .midTilt, .farTilt,
            .recenterFE08, .flipFE09, .releaseNeutral
        ])
        let dryRunInputCount = await owner.inputs.count
        #expect(dryRunInputCount == 0)
        let dryRunRecenterCount = await owner.recenterCount
        let dryRunFlipCount = await owner.flipCount
        #expect(dryRunRecenterCount == 0 && dryRunFlipCount == 0)
        #expect(result.plan.requiresExactStationOwner)
        #expect(!result.plan.sendsImages && !result.plan.changesMacWiFi)
    }

    @Test func executeRunsBoundedDistancesNeutralAndBothNativePresets()
        async throws {
        let (request, clock) = try acceptanceFixture(execute: true)
        let owner = AcceptanceFakeOwner(request: request)
        let result = await Pocket3NativeGimbalAcceptanceExecutor(
            owner: owner, clock: clock).run(request)
        #expect(result.phase == .completed && result.completed)
        #expect(result.steps.count == 9)
        #expect(result.steps.allSatisfy { $0.completed })
        #expect(result.steps.filter {
            $0.kind == .recenterFE08 || $0.kind == .flipFE09
        }.allSatisfy { $0.acknowledged })
        #expect(result.steps.dropLast().allSatisfy { $0.telemetryObserved })
        let inputCount = await owner.inputs.count
        let releaseCount = await owner.releases
        #expect(inputCount >= 12 && releaseCount == 6)
        let recenterCount = await owner.recenterCount
        let flipCount = await owner.flipCount
        #expect(recenterCount == 1 && flipCount == 1)
        let failStopCount = await owner.failStopCount
        #expect(failStopCount == 1)
    }

    @Test func cancellationCallsFailStopAndPreservesPartialEvidence()
        async throws {
        let (request, clock) = try acceptanceFixture(execute: true, hold: 0.5)
        let owner = AcceptanceFakeOwner(request: request)
        let executor = Pocket3NativeGimbalAcceptanceExecutor(
            owner: owner, clock: clock)
        let task = Task { await executor.run(request) }
        task.cancel()
        let result = await task.value
        #expect(result.phase == .cancelled && !result.completed)
        #expect(result.failStop?.neutralSent == true)
        let failStopCount = await owner.failStopCount
        #expect(failStopCount == 1)
        #expect(!result.steps.isEmpty)
    }

    @Test func connectionChangeFailsStopAndCannotCompleteLaterSteps()
        async throws {
        let (request, clock) = try acceptanceFixture(execute: true)
        let owner = AcceptanceFakeOwner(request: request,
                                        disconnectAfterSend: 1)
        let result = await Pocket3NativeGimbalAcceptanceExecutor(
            owner: owner, clock: clock).run(request)
        #expect(result.phase == .connectionChanged && !result.completed)
        #expect(result.failStop?.connectionChanged == true)
        let failStopCount = await owner.failStopCount
        #expect(failStopCount == 1)
        #expect(result.steps.first?.kind == .nearPan)
        #expect(result.steps.count == 1)
    }
}
