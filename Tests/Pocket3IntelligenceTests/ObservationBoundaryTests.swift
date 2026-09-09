#if DEBUG
import CoreVideo
import Foundation
import Testing
@testable import Pocket3Core
@testable import Pocket3Intelligence

private func camera() throws -> SimulatedObservationCamera {
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, let pixel else { throw BridgeFailure("fixture", "No buffer") }
    let store = FrameStore(); store.reset(deviceID: "simulation"); store.receive(pixel, pts: 0)
    let frame = try store.latest()
    return SimulatedObservationCamera(before: frame, after: frame)
}
private func context(_ camera: SimulatedObservationCamera) async throws -> ObservationContext {
    let start = try await camera.beginObservation(origin: .manual)
    return ObservationContext(service: camera, origin: .manual, stamp: start.stamp, frame: try await camera.frame(origin: .manual, after: 0),
        canMove: start.canMove, canZoom: start.canZoom, zoomCapabilities: start.zoomCapabilities, deadline: ProcessInfo.processInfo.systemUptime+30)
}
@Test func modelCannotExceedThreePhysicalStepRequests() async throws {
    let camera = try camera(), context = try await context(camera)
    for _ in 0..<3 { _ = try await context.move(.left) }
    do { _ = try await context.move(.left); Issue.record("Fourth motion was accepted") } catch {}
    #expect(await camera.report()["directions"] == .array([.string("left"), .string("left"), .string("left")]))
}
@Test func manualTakeoverInvalidatesAnOldModelInteraction() async throws {
    let camera = try camera(), context = try await context(camera)
    await camera.setAccess(.manual)
    do { _ = try await context.move(.right); Issue.record("Old interaction moved after takeover") } catch {}
    #expect(await camera.report()["directions"] == .array([]))
}
@Test func reconnectInvalidatesFrameAndToolAccess() async throws {
    let camera = try camera(), context = try await context(camera)
    await camera.reconnect()
    do { _ = try await context.capture(); Issue.record("Old interaction survived reconnect") } catch {}
}
@Test func cancelledInteractionCannotCaptureOrMove() async throws {
    let camera = try camera(), context = try await context(camera)
    await context.cancel()
    do { _ = try await context.capture(); Issue.record("Cancelled interaction captured") } catch {}
    do { _ = try await context.move(.up); Issue.record("Cancelled interaction moved") } catch {}
    #expect(await camera.report()["directions"] == .array([]))
}
@Test func cancellationDiscardsQueuedModelTools() async throws {
    var pixel: CVPixelBuffer?
    _ = CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &pixel)
    let store = FrameStore(); store.reset(deviceID: "simulation"); store.receive(pixel!, pts: 0)
    let frame = try store.latest()
    let camera = SimulatedObservationCamera(before: frame, after: frame, moveDelay: 0.5)
    let context = try await context(camera)
    let first = Task { try await context.move(.left) }
    try await Task.sleep(for: .milliseconds(30))
    let queued = Task { try await context.move(.right) }
    try await Task.sleep(for: .milliseconds(30))
    await context.cancel()
    _ = try? await first.value
    _ = try? await queued.value
    #expect(await camera.report()["directions"] == .array([]))
    #expect(await camera.report()["stopped"] == .bool(true))
}

@Test func simulatedCameraSupportsZoomWithoutSimulatedGimbalValidation() async throws {
    let seed = try camera()
    let frame = try await seed.frame(origin: .manual, after: 0)
    let camera = SimulatedObservationCamera(before: frame, after: frame, moveValidated: false)
    let start = try await camera.beginObservation(origin: .manual)
    #expect(start.canZoom && !start.canMove)
    let context = try await context(camera)
    _ = try await context.readZoomStatus()
    _ = try await context.zoom(175)
    #expect(await camera.report()["appliedZooms"] == .array([.number(175)]))
    let action = await context.actionEvidence().last
    #expect(action?.zoom?.verification == "simulation_only" && action?.postActionFrame?.timestampSource == "simulated_frame")
}

#endif
