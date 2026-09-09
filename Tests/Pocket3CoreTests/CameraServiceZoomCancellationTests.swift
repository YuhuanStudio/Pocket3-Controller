import Foundation
import CoreVideo
import Testing
@testable import Pocket3Core

/// Records real service calls to a synthetic transport. No UVCConnection or
/// AVF session is started. First SET represents a device still slewing at 160.
private actor CancellationCameraConnection: CameraControlConnection {
    nonisolated let lifetime = OperationPermit()
    private let failHold: Bool
    private var firstSetWaiter: CheckedContinuation<Void, Never>?
    private var current = 100
    private(set) var zoomWrites: [Int] = []
    private(set) var panWrites: [GimbalPosition] = []
    var waitingAfterSet: Bool { firstSetWaiter != nil }
    init(failHold: Bool = false) { self.failHold = failHold }
    nonisolated func invalidate() { lifetime.invalidate() }
    func status() throws -> UVCCapabilities {
        try lifetime.perform {}
        return .init(location: 1, position: .init(pan: 0, tilt: 0),
            minimum: .init(pan: -36000, tilt: -36000), maximum: .init(pan: 36000, tilt: 36000),
            step: .init(pan: 3600, tilt: 3600), writable: true, controls: ["pan-tilt-abs", "zoom-abs"], uvcVersion: 256)
    }
    func set(_ position: GimbalPosition, permit: OperationPermit?) throws {
        try lifetime.perform { try permit?.perform {}; panWrites.append(position) }
    }
    func zoomStatus() throws -> USBZoomCapabilities {
        try lifetime.perform {}
        return .init(current: current, minimum: 100, maximum: 400, step: 1, writable: true)
    }
    func setZoom(rawValue: Int, validUntil: TimeInterval, permit: OperationPermit, connectionPermit: OperationPermit?) async throws {
        try lifetime.perform {
            try connectionPermit?.perform {}
            try permit.perform {
                guard ProcessInfo.processInfo.systemUptime <= validUntil else { throw BridgeFailure("zoom_timing", "Expired fixture write") }
                zoomWrites.append(rawValue)
                if zoomWrites.count == 1 { current = 160 }
                else if failHold { throw BridgeFailure("fixture_hold_failed", "Synthetic hold failed") }
                else { current = rawValue }
            }
        }
        if zoomWrites.count == 1 {
            await withCheckedContinuation { firstSetWaiter = $0 }
            try Task.checkCancellation()
            try lifetime.perform {}
        }
    }
    func releaseFirstSet() { let waiter = firstSetWaiter; firstSetWaiter = nil; waiter?.resume() }
    func rollStatus() throws -> USBRollCapabilities { throw BridgeFailure("fixture_no_roll", "No Roll in this fixture") }
    func setRoll(rawValue: Int, validUntil: TimeInterval, permit: OperationPermit, connectionPermit: OperationPermit?) throws {
        throw BridgeFailure("fixture_no_roll", "No Roll in this fixture")
    }
    func setFast(_ position: GimbalPosition, validUntil: TimeInterval, permit: OperationPermit, connectionPermit: OperationPermit?) throws {
        try set(position, permit: permit)
    }
}

private actor CancelledReplies {
    private(set) var replies: [ServiceReply] = []
    private(set) var sources: [ServiceRequestSource?] = []
    func record(_ reply: ServiceReply, source: ServiceRequestSource?) { replies.append(reply); sources.append(source) }
}

private func cancellationFrame(_ deviceID: String = "synthetic-cancellation-camera") throws -> FramePacket {
    var pixels: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 32, 16, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess, let pixels else {
        throw BridgeFailure("fixture_pixels", "Could not allocate synthetic pixels")
    }
    return FramePacket(pixelBuffer: pixels, info: .init(id: "synthetic-source", sessionID: "synthetic-source-session", deviceID: deviceID,
        receivedAt: Date(), receivedUptime: ProcessInfo.processInfo.systemUptime, presentationTime: 1,
        width: 32, height: 16, timestampSource: "simulation_only"))
}
private func zoomArguments(_ service: CameraService) -> JSONValue {
    .object(["rawValue": .number(200), "expectedSessionID": .string(service.capture.store.stats().sessionID)])
}
private func waitForFirstSet(_ connection: CancellationCameraConnection) async throws {
    for _ in 0..<200 {
        if await connection.waitingAfterSet { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw BridgeFailure("fixture_timeout", "Service never submitted the first zoom")
}

@Test func cancelledIPCZoomJoinsIndependentServiceHoldAndRevokesAutomation() async throws {
    let connection = CancellationCameraConnection(), frame = try cancellationFrame()
    let service = CameraService(testConnection: connection, testFrame: frame)
    let address = IPCAddress(directory: URL(fileURLWithPath: "/tmp/p3-zoom-cancel-" + String(UUID().uuidString.prefix(8))))
    let server = IPCServer(address: address), receipt = CancelledReplies()
    defer { server.stop(); try? FileManager.default.removeItem(at: address.directory) }
    try server.start { request in
        let reply = await service.handle(request)
        await receipt.record(reply, source: request.source)
        return reply
    }
    let task = Task { try await IPCClient.call("zoom", arguments: zoomArguments(service), address: address, source: .mcp) }
    try await waitForFirstSet(connection)
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled IPC returned success") } catch is CancellationError {}
    await connection.releaseFirstSet()
    for _ in 0..<400 {
        if await !receipt.replies.isEmpty { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let reply = try #require(await receipt.replies.first)
    #expect(reply.error?.code == "cancelled" && reply.result == nil)
    #expect(await receipt.sources == [.mcp])
    #expect(await connection.zoomWrites == [200, 160])
    #expect(await connection.panWrites == [.init(pan: 0, tilt: 0)])
    // The independent Stop completed before the service cancellation reply.
    // The original destination is never resent, and old AI access is revoked.
    service.capture.store.receive(frame.pixelBuffer, pts: 2)
    let denied = await service.handle(ServiceRequest(token: "fixture", operation: "zoom", arguments: zoomArguments(service), source: .mcp))
    #expect(denied.error?.code == "zoom_denied")
    #expect(await connection.zoomWrites == [200, 160])
}

@Test func failedCancellationHoldBlocksFurtherZoomAndPanEvenAfterAccessIsReenabled() async throws {
    let connection = CancellationCameraConnection(failHold: true), frame = try cancellationFrame()
    let service = CameraService(testConnection: connection, testFrame: frame)
    let task = Task { await service.handle(ServiceRequest(token: "fixture", operation: "zoom", arguments: zoomArguments(service), source: .mcp)) }
    try await waitForFirstSet(connection)
    task.cancel(); await connection.releaseFirstSet()
    let cancelled = await task.value
    #expect(cancelled.error?.code == "cancelled")
    #expect(await connection.zoomWrites == [200, 160])
    await service.setAccess(.control)
    service.capture.store.receive(frame.pixelBuffer, pts: 2)
    let zoom = await service.handle(ServiceRequest(token: "fixture", operation: "zoom", arguments: zoomArguments(service), source: .mcp))
    let pan = await service.handle(ServiceRequest(token: "fixture", operation: "move", arguments: .object(["direction": .string("right")]), source: .mcp))
    #expect(zoom.error?.code == "zoom_stop_required" && pan.error?.code == "zoom_stop_required")
    #expect(await connection.zoomWrites == [200, 160])
    #expect(await connection.panWrites == [.init(pan: 0, tilt: 0)])
}

@Test func cancelledOldZoomCannotHoldAReplacementConnection() async throws {
    let old = CancellationCameraConnection(), replacement = CancellationCameraConnection()
    let service = CameraService(testConnection: old, testFrame: try cancellationFrame())
    let task = Task { await service.handle(ServiceRequest(token: "fixture", operation: "zoom", arguments: zoomArguments(service), source: .mcp)) }
    try await waitForFirstSet(old)
    task.cancel()
    try await service.replaceTestConnection(replacement, frame: cancellationFrame("replacement-synthetic-camera"))
    await old.releaseFirstSet()
    let reply = await task.value
    #expect(reply.error?.code == "cancelled")
    let oldZooms = await old.zoomWrites, oldPans = await old.panWrites
    let newZooms = await replacement.zoomWrites, newPans = await replacement.panWrites
    #expect(oldZooms == [200] && oldPans.isEmpty)
    #expect(newZooms.isEmpty && newPans.isEmpty)
    let current = try await service.zoomCapabilities(expectedSessionID: service.capture.store.stats().sessionID)
    #expect(current.current == 100)
}

@Test func explicitStopAndCancelledZoomDeduplicateTheSameHold() async throws {
    let connection = CancellationCameraConnection()
    let service = CameraService(testConnection: connection, testFrame: try cancellationFrame())
    let task = Task { await service.handle(ServiceRequest(token: "fixture", operation: "zoom", arguments: zoomArguments(service), source: .mcp)) }
    try await waitForFirstSet(connection)
    let stop = Task { try await service.stop() }
    for _ in 0..<200 {
        if await connection.zoomWrites.count == 2 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    task.cancel(); await connection.releaseFirstSet()
    let result = try await stop.value
    let cancelled = await task.value
    #expect(result.verified && result.zoomStop?.verified == true)
    #expect((result.zoomStop?.stableDurationSeconds ?? 0) >= 0.8)
    #expect(cancelled.error?.code == "cancelled")
    #expect(await connection.zoomWrites == [200, 160])
    #expect(await connection.panWrites == [.init(pan: 0, tilt: 0)])
}

@Test func regrantingControlDuringZoomDoesNotSuppressItsCancellationHold() async throws {
    let connection = CancellationCameraConnection(), frame = try cancellationFrame()
    let service = CameraService(testConnection: connection, testFrame: frame)
    let task = Task { await service.handle(ServiceRequest(token: "fixture", operation: "zoom", arguments: zoomArguments(service), source: .mcp)) }
    try await waitForFirstSet(connection)
    // This advances the interaction epoch but does not replace the active
    // motion owner. Its eventual cancellation still owes the device a hold.
    await service.setAccess(.control)
    task.cancel(); await connection.releaseFirstSet()
    let reply = await task.value
    #expect(reply.error?.code == "cancelled")
    #expect(await connection.zoomWrites == [200, 160])
    #expect(await connection.panWrites == [.init(pan: 0, tilt: 0)])
    service.capture.store.receive(frame.pixelBuffer, pts: 2)
    let denied = await service.handle(ServiceRequest(token: "fixture", operation: "zoom", arguments: zoomArguments(service), source: .mcp))
    #expect(denied.error?.code == "zoom_denied")
}
