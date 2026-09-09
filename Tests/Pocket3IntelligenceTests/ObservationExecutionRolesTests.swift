import Foundation
import CoreVideo
import Testing
@testable import Pocket3Core
@testable import Pocket3Intelligence

/// Pure orchestration fixtures: no CameraService, model status, model loading,
/// USB, downloads or model generation is reached through the stage override.
private actor RoleCamera: ObservationCamera {
    private let pixels: CVPixelBuffer
    private let canMove: Bool
    private let canZoom: Bool
    private var capabilities = USBZoomCapabilities(current: 100, minimum: 100, maximum: 400, step: 1, writable: true)
    private let stamp = InteractionStamp(sessionID: "role-fixture-session", epoch: 1)
    private(set) var frames: [FrameInfo] = []
    private(set) var writes: [Int] = []
    private(set) var stopCount = 0

    init(canMove: Bool = false, canZoom: Bool = true) throws {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer else {
            throw BridgeFailure("fixture", "Cannot allocate synthetic pixels")
        }
        pixels = buffer; self.canMove = canMove; self.canZoom = canZoom
    }
    func beginObservation(origin: RequestOrigin) -> ObservationStart {
        .init(stamp: stamp, canMove: canMove, canZoom: canZoom, zoomCapabilities: canZoom ? capabilities : nil)
    }
    func validateInteraction(_ value: InteractionStamp, origin: RequestOrigin) throws {
        guard value == stamp else { throw BridgeFailure("interaction_changed", "Fixture session mismatch") }
    }
    func frame(origin: RequestOrigin, after: Double) throws -> FramePacket {
        let now = ProcessInfo.processInfo.systemUptime
        guard now > after else { throw BridgeFailure("fixture_clock", "Fresh frame threshold has not passed") }
        let info = FrameInfo(id: "role-frame-\(frames.count)", sessionID: stamp.sessionID,
            deviceID: "synthetic-roles", receivedAt: Date(), receivedUptime: now, presentationTime: now,
            width: 64, height: 32, timestampSource: "simulation_only")
        frames.append(info)
        return FramePacket(pixelBuffer: pixels, info: info)
    }
    func move(direction: String, origin: RequestOrigin, interaction: InteractionStamp?) throws -> MotionResult {
        throw BridgeFailure("fixture_move", "No movement implemented by this synthetic fixture")
    }
    func zoomCapabilitiesForObservation(interaction: InteractionStamp) throws -> USBZoomCapabilities {
        try validateInteraction(interaction, origin: .automation)
        guard canZoom else { throw BridgeFailure("zoom_denied", "Read-only fixture") }
        return capabilities
    }
    func zoomForObservation(rawValue: Int, interaction: InteractionStamp) throws -> USBZoomResult {
        try validateInteraction(interaction, origin: .automation)
        guard canZoom else { throw BridgeFailure("zoom_denied", "Read-only fixture") }
        try ObservationZoomPolicy.validate(rawValue: rawValue, capabilities: capabilities)
        writes.append(rawValue); capabilities.current = rawValue
        return .init(target: rawValue, observed: rawValue, accepted: true, completed: true, verified: true,
            verification: "simulation_only", capabilities: capabilities, message: "Synthetic readback", toleranceRaw: 0)
    }
    func stopIfInteractionCurrent(_ value: InteractionStamp) -> MotionResult? {
        guard value == stamp else { return nil }
        stopCount += 1
        return nil
    }
}

private actor RoleResponder {
    private let zoom: Bool
    private let fail: String?
    private let pause: ObservationModelStage.Role?
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var stages: [ObservationModelStage] = []
    private(set) var retiredToolFailure: String?
    var waiting: Bool { pending != nil }
    init(zoom: Bool = false, fail: String? = nil, pause: ObservationModelStage.Role? = nil) {
        self.zoom = zoom; self.fail = fail; self.pause = pause
    }
    func answer(_ stage: ObservationModelStage) async throws -> ObservationAnswer {
        stages.append(stage)
        if stage.role == pause { await withCheckedContinuation { pending = $0 } }
        if let fail { throw BridgeFailure(fail, "Synthetic model preparation failure") }
        if zoom, stage.role != .finalAnswer {
            _ = try await stage.context.readZoomStatus()
            _ = try await stage.context.zoom(200)
            _ = try await stage.context.capture()
        }
        if stage.role == .finalAnswer {
            // A stale controller Tool still cannot act even if retained by an
            // SDK caller after the model stage has completed.
            do { _ = try await stage.context.zoom(300); Issue.record("Retired controller accepted a write") }
            catch let failure as BridgeFailure { retiredToolFailure = failure.code }
            return ObservationAnswer(answer: "Apple 的模擬畫面回答。", evidence: [], uncertainties: [])
        }
        return ObservationAnswer(answer: "MLX 的模擬中間回答。", evidence: [], uncertainties: [])
    }
    func release() { let continuation = pending; pending = nil; continuation?.resume() }
}

@Test func appleControlUsesMLXThenToolFreeAppleWithOneUncountedFreshFrame() async throws {
    let camera = try RoleCamera()
    let responder = RoleResponder(zoom: true)
    let engine = IntelligenceEngine(observationStage: { try await responder.answer($0) })
    let result = try await engine.observe(service: camera, question: "模擬縮放後描述畫面", engine: "apple")
    let stages = await responder.stages
    #expect(stages.count == 2)
    let controller = try #require(stages.first), answer = try #require(stages.last)
    #expect(controller.engine == "mlx" && controller.role == .controller)
    #expect(answer.engine == "apple" && answer.role == .finalAnswer)
    #expect(controller.context === answer.context && controller.deadline == answer.deadline)
    #expect(Set(controller.tools.map(\.name)) == ["capture_frame", "read_visible_text", "read_barcodes", "camera_zoom_status", "camera_set_zoom"])
    #expect(answer.tools.isEmpty && answer.toolCallingMode == .disallowed)
    #expect(await responder.retiredToolFailure == "model_tools_retired")
    #expect(await camera.writes == [200])
    #expect(result.actions.map(\.tool) == ["camera_zoom_status", "camera_set_zoom", "capture_frame"])
    #expect(answer.evidence.map(\.tool) == result.actions.map(\.tool))
    let frames = await camera.frames
    #expect(frames.count == 4) // initial, post-zoom, model capture, one host capture
    #expect(answer.frame.info.id == result.frame.id && answer.frame.info.id == frames.last?.id)
    #expect(answer.frame.info.receivedUptime > frames[2].receivedUptime)
    #expect(result.answer.answer == "Apple 的模擬畫面回答。")
    #expect(result.engine == "apple")
    #expect(result.executionRoles == .init(controllerEngine: "mlx", answerEngine: "apple", finalFrameRefresh: "app"))
    let metadata = try result.metadata()
    #expect(metadata["executionRoles"]["controllerEngine"] == .string("mlx"))
    #expect(metadata["executionRoles"]["answerEngine"] == .string("apple"))
    #expect(metadata["executionRoles"]["finalFrameRefresh"] == .string("app"))
}

@Test func readOnlyAppleAndSelectedMLXKeepTheirSingleStageRoutes() async throws {
    for (selected, zoom) in [("apple", false), ("mlx", true)] {
        let camera = try RoleCamera(canZoom: zoom)
        let responder = RoleResponder()
        let engine = IntelligenceEngine(observationStage: { try await responder.answer($0) })
        let result = try await engine.observe(service: camera, question: "描述模擬畫面", engine: selected)
        let stages = await responder.stages
        #expect(stages.count == 1)
        let stage = try #require(stages.first)
        #expect(stage.engine == selected && stage.role == .standard && stage.toolCallingMode == nil)
        #expect(stage.tools.count == (zoom ? 5 : 3))
        #expect(await camera.frames.count == 1)
        #expect(result.actions.isEmpty)
        #expect(result.executionRoles == .init(controllerEngine: zoom ? "mlx" : nil, answerEngine: selected))
    }
    #expect(ObservationExecutionRoles.route(selectedEngine: "apple", canMove: true, canZoom: false) ==
        .init(controllerEngine: "mlx", answerEngine: "apple", finalFrameRefresh: "app"))
}

@Test func unavailableControllerFailsBeforeAppleAnswerOrAnyCameraWrite() async throws {
    let camera = try RoleCamera()
    let responder = RoleResponder(fail: "model_not_downloaded")
    let engine = IntelligenceEngine(observationStage: { try await responder.answer($0) })
    do { _ = try await engine.observe(service: camera, question: "模擬縮放", engine: "apple"); Issue.record("Missing controller should fail") }
    catch let failure as BridgeFailure { #expect(failure.code == "model_not_downloaded") }
    #expect(await responder.stages.count == 1)
    #expect(await camera.frames.count == 1)
    #expect(await camera.writes.isEmpty)
}

@Test func cancellationDuringEitherModelStageCannotYieldALateAnswer() async throws {
    for paused in [ObservationModelStage.Role.controller, .finalAnswer] {
        let camera = try RoleCamera()
        let responder = RoleResponder(pause: paused)
        let engine = IntelligenceEngine(observationStage: { try await responder.answer($0) })
        let task = Task { try await engine.observe(service: camera, question: "描述模擬畫面", engine: "apple") }
        for _ in 0..<1000 {
            if await responder.waiting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard await responder.waiting else { task.cancel(); throw BridgeFailure("fixture_timeout", "Stage never reached cancellation gate") }
        await engine.cancelObservation()
        await responder.release()
        do { _ = try await task.value; Issue.record("Cancelled observation returned a late answer") }
        catch is CancellationError {}
        catch let failure as BridgeFailure { #expect(failure.code == "observation_cancelled") }
        #expect(await responder.stages.count == (paused == .controller ? 1 : 2))
        #expect(await camera.frames.count == (paused == .controller ? 1 : 2))
        #expect(await camera.writes.isEmpty)
    }
}
