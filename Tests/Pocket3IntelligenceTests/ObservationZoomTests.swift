import Foundation
import CoreVideo
import Testing
@testable import Pocket3Core
@testable import Pocket3Intelligence

private actor ZoomObservationFixture: ObservationCamera {
    enum Behavior: Sendable { case verified, unconfirmed, throwing, staleFrame, wrongFrameSession, delayed }
    private let pixels: CVPixelBuffer
    private let behavior: Behavior
    private var access: AccessMode
    private let moveValidated: Bool
    private var capabilities: USBZoomCapabilities?
    private var epoch = 0
    private var sessionID = "zoom-session-A"
    private var frameCount = 0
    private var stopped = false
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var zoomAttempts = 0
    private(set) var writes: [Int] = []
    private(set) var stopCount = 0
    private(set) var frameAfter: [Double] = []
    var waiting: Bool { pending != nil }

    init(behavior: Behavior = .verified, access: AccessMode = .control, moveValidated: Bool = false,
         capabilities: USBZoomCapabilities? = .init(current: 100, minimum: 100, maximum: 400, step: 1, writable: true)) throws {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer else {
            throw BridgeFailure("fixture", "No synthetic image buffer")
        }
        pixels = buffer; self.behavior = behavior; self.access = access
        self.moveValidated = moveValidated; self.capabilities = capabilities
    }
    func beginObservation(origin: RequestOrigin) throws -> ObservationStart {
        .init(stamp: .init(sessionID: sessionID, epoch: epoch), canMove: access == .control && moveValidated,
            canZoom: access == .control, zoomCapabilities: capabilities)
    }
    func frame(origin: RequestOrigin, after: Double) throws -> FramePacket {
        frameCount += 1; frameAfter.append(after)
        let time = behavior == .staleFrame && after > 0 ? after - 0.1 : ProcessInfo.processInfo.systemUptime
        let frameSession = behavior == .wrongFrameSession && after > 0 ? "different-session" : sessionID
        return FramePacket(pixelBuffer: pixels, info: FrameInfo(id: "synthetic:\(frameSession):\(frameCount)", sessionID: frameSession,
            deviceID: "simulated-zoom", receivedAt: Date(), receivedUptime: time, presentationTime: time, width: 64, height: 32,
            timestampSource: "simulation_only"))
    }
    func validateInteraction(_ stamp: InteractionStamp, origin: RequestOrigin) throws {
        guard !stopped, stamp.epoch == epoch, stamp.sessionID == sessionID else { throw BridgeFailure("interaction_changed", "Fixture owner changed") }
    }
    func move(direction: String, origin: RequestOrigin, interaction: InteractionStamp?) async throws -> MotionResult {
        throw BridgeFailure("movement_denied", "Fixture has no gimbal movement")
    }
    func zoomCapabilitiesForObservation(interaction: InteractionStamp) async throws -> USBZoomCapabilities {
        try validateInteraction(interaction, origin: .automation)
        guard access == .control, let capabilities else { throw BridgeFailure("zoom_denied", "Fixture zoom denied") }
        return capabilities
    }
    func zoomForObservation(rawValue: Int, interaction: InteractionStamp) async throws -> USBZoomResult {
        var capabilities = try await zoomCapabilitiesForObservation(interaction: interaction)
        try ObservationZoomPolicy.validate(rawValue: rawValue, capabilities: capabilities)
        zoomAttempts += 1
        if behavior == .delayed { await withCheckedContinuation { pending = $0 } }
        try Task.checkCancellation()
        try validateInteraction(interaction, origin: .automation)
        guard access == .control else { throw BridgeFailure("zoom_denied", "Fixture zoom revoked") }
        if behavior == .throwing { throw BridgeFailure("zoom_transport_failed", "Simulated send failure") }
        writes.append(rawValue)
        let confirmed = behavior != .unconfirmed
        if confirmed { capabilities.current = rawValue; self.capabilities = capabilities }
        return USBZoomResult(target: rawValue, observed: capabilities.current, accepted: true, completed: confirmed,
            verified: confirmed, verification: "simulation_only", capabilities: capabilities, message: "Synthetic zoom only", toleranceRaw: 0)
    }
    func stopIfInteractionCurrent(_ stamp: InteractionStamp) -> MotionResult? {
        guard stamp.epoch == epoch, stamp.sessionID == sessionID else { return nil }
        epoch += 1; stopCount += 1; stopped = true
        return MotionResult(accepted: true, completed: true, verified: true, verification: "simulation_only", target: nil, observed: nil, message: "Fixture stopped")
    }
    func release() { let continuation = pending; pending = nil; continuation?.resume() }
    func revoke() { epoch += 1; access = .observe }
    func reconnect() { epoch += 1; sessionID = "zoom-session-B"; stopped = false }
}
private func zoomContext(_ camera: ZoomObservationFixture) async throws -> (ObservationContext, ObservationStart) {
    let start = try await camera.beginObservation(origin: .manual)
    let frame = try await camera.frame(origin: .manual, after: 0)
    return (ObservationContext(service: camera, origin: .manual, stamp: start.stamp, frame: frame,
        canMove: start.canMove, canZoom: start.canZoom, zoomCapabilities: start.zoomCapabilities,
        deadline: ProcessInfo.processInfo.systemUptime + 30), start)
}
private enum ZoomTestFailure: Error { case timeout }
private func waitForZoom(_ camera: ZoomObservationFixture) async throws {
    for _ in 0..<1000 {
        if await camera.waiting { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ZoomTestFailure.timeout
}

@Test func bothAIBackendsGetZoomToolsWithoutGimbalPermission() async throws {
    let camera = try ZoomObservationFixture()
    let (context, start) = try await zoomContext(camera)
    let names = Set(ObservationToolSet.make(context: context, canMove: start.canMove, canZoom: start.canZoom).map(\.name))
    #expect(start.canZoom && !start.canMove)
    #expect(names.contains("camera_zoom_status") && names.contains("camera_set_zoom") && !names.contains("move_gimbal"))
    for camera in [try ZoomObservationFixture(access: .observe), try ZoomObservationFixture(capabilities: nil),
                   try ZoomObservationFixture(capabilities: .init(current: 100, minimum: 100, maximum: 400, step: 1, writable: false))] {
        let (context, start) = try await zoomContext(camera)
        let tools = ObservationToolSet.make(context: context, canMove: start.canMove, canZoom: start.canZoom)
        #expect(!tools.contains { $0.name == "camera_zoom_status" || $0.name == "camera_set_zoom" })
    }
}

@Test func zoomRequiresStatusAndValidatesAdvertisedRawStepBeforeSending() async throws {
    let camera = try ZoomObservationFixture(capabilities: .init(current: 100, minimum: 100, maximum: 400, step: 5, writable: true))
    let (context, _) = try await zoomContext(camera)
    do { _ = try await context.zoom(150); Issue.record("Zoom skipped its capability read") } catch {}
    _ = try await context.readZoomStatus()
    for raw in [99, 401, 151] {
        do { _ = try await context.zoom(raw); Issue.record("Invalid raw zoom was sent") } catch {}
    }
    #expect(await camera.zoomAttempts == 0)
}

@Test func successfulZoomCarriesReadbackAndStrictlyPostCompletionFrameEvidence() async throws {
    let camera = try ZoomObservationFixture()
    let (context, start) = try await zoomContext(camera)
    _ = try await context.readZoomStatus()
    _ = try await context.zoom(147)
    let actions = await context.actionEvidence()
    let zoom = try #require(actions.last)
    #expect(zoom.tool == "camera_set_zoom" && zoom.zoom?.target == 147 && zoom.zoom?.observed == 147)
    #expect(zoom.zoom?.verified == true && zoom.failureCode == nil)
    let frame = try #require(zoom.postActionFrame)
    let threshold = try #require(await camera.frameAfter.last)
    #expect(threshold > 0 && frame.receivedUptime > threshold)
    #expect(frame.sessionID == start.stamp.sessionID && frame.id == zoom.frameID)
    #expect(frame.timestampSource == "simulation_only")
}

@Test func uncertainOrFailedZoomCannotBeBlindlyRetried() async throws {
    for behavior in [ZoomObservationFixture.Behavior.unconfirmed, .throwing] {
        let camera = try ZoomObservationFixture(behavior: behavior)
        let (context, _) = try await zoomContext(camera)
        _ = try await context.readZoomStatus()
        do { _ = try await context.zoom(150); Issue.record("Unconfirmed zoom succeeded") } catch {}
        do { _ = try await context.zoom(150); Issue.record("Failed zoom was retried") } catch {}
        #expect(await camera.zoomAttempts == 1)
        #expect(await camera.stopCount == 1)
        let action = await context.actionEvidence().last
        #expect(action?.failureCode != nil && action?.postActionFrame == nil)
    }
}

@Test func staleOrForeignPostZoomFrameCannotBecomeActionEvidence() async throws {
    for behavior in [ZoomObservationFixture.Behavior.staleFrame, .wrongFrameSession] {
        let camera = try ZoomObservationFixture(behavior: behavior)
        let (context, _) = try await zoomContext(camera)
        _ = try await context.readZoomStatus()
        do { _ = try await context.zoom(150); Issue.record("Invalid post-zoom frame was accepted") } catch {}
        let action = await context.actionEvidence().last
        #expect(action?.failureCode == "stale_zoom_frame" && action?.postActionFrame == nil)
        #expect(await camera.zoomAttempts == 1)
        #expect(await camera.stopCount == 1)
    }
}

@Test func cancellationStopsDelayedZoomAndDiscardsQueuedModelTools() async throws {
    let camera = try ZoomObservationFixture(behavior: .delayed)
    let (context, _) = try await zoomContext(camera)
    _ = try await context.readZoomStatus()
    let first = Task { try await context.zoom(150) }
    try await waitForZoom(camera)
    let queued = Task { try await context.zoom(200) }
    await context.cancel()
    await camera.release()
    _ = try? await first.value; _ = try? await queued.value
    #expect(await camera.zoomAttempts == 1)
    #expect(await camera.stopCount == 1)
    #expect(await camera.writes.isEmpty)
}

@Test func takeoverOrReconnectPreventsQueuedZoomAndDoesNotStopTheNewOwner() async throws {
    for reconnect in [false, true] {
        let camera = try ZoomObservationFixture(behavior: .delayed)
        let (context, _) = try await zoomContext(camera)
        _ = try await context.readZoomStatus()
        let task = Task { try await context.zoom(150) }
        try await waitForZoom(camera)
        if reconnect { await camera.reconnect() } else { await camera.revoke() }
        await camera.release()
        do { _ = try await task.value; Issue.record("A stale owner completed zoom") } catch {}
        #expect(await camera.writes.isEmpty)
        #expect(await camera.stopCount == 0)
    }
}

@Test func callerCancellationAlsoHoldsZoomWithoutExplicitContextCancel() async throws {
    let camera = try ZoomObservationFixture(behavior: .delayed)
    let (context, _) = try await zoomContext(camera)
    _ = try await context.readZoomStatus()
    let task = Task { try await context.zoom(150) }
    try await waitForZoom(camera)
    task.cancel(); await camera.release()
    do { _ = try await task.value; Issue.record("Cancelled zoom returned success") } catch {}
    #expect(await camera.stopCount == 1)
    #expect(await camera.writes.isEmpty)
}

@Test func zoomBudgetIsIndependentButStillBoundedToThreeRequests() async throws {
    let camera = try ZoomObservationFixture()
    let (context, _) = try await zoomContext(camera)
    _ = try await context.readZoomStatus()
    for raw in [110, 120, 130] { _ = try await context.zoom(raw) }
    do { _ = try await context.zoom(140); Issue.record("Fourth zoom was accepted") } catch {}
    #expect(await camera.writes == [110, 120, 130])
}

@Test func olderActionLedgerDecodesWithoutInventingZoomEvidence() throws {
    let old = Data(#"{"tool":"capture_frame","detail":"old frame","motion":null,"frameID":"old-id"}"#.utf8)
    let action = try JSONDecoder().decode(ObservationAction.self, from: old)
    #expect(action.zoom == nil && action.postActionFrame == nil && action.failureCode == nil)
}
