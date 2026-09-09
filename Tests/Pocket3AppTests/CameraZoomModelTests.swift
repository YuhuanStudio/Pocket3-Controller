import Foundation
import Testing
@testable import Pocket3Core
@testable import Pocket3BridgeApp

@MainActor private final class ZoomModelFixture {
    enum Delay: Equatable { case beforeWrite, afterWrite }
    struct Write: Equatable { let value: Int; let session: String }
    var session = "zoom-A"
    var capabilities = USBZoomCapabilities(current: 100, minimum: 100, maximum: 400, step: 1, writable: true)
    var delayNextWrite: Delay?
    var delayNextRead = false
    var returnUnverified = false
    private(set) var writeGate: CheckedContinuation<Void, Never>?
    private(set) var readGate: CheckedContinuation<Void, Never>?
    private(set) var writes: [Write] = []
    private(set) var reads: [String] = []
    private(set) var prepares = 0
    private(set) var inFlight = 0
    private(set) var maximumInFlight = 0
    var errors: [String] = []

    func read(_ expected: String) async throws -> USBZoomCapabilities {
        reads.append(expected)
        guard expected == session else { throw BridgeFailure("session_changed", "Fake read session changed") }
        let snapshot = capabilities
        if delayNextRead {
            delayNextRead = false
            await withCheckedContinuation { readGate = $0 }
        }
        return snapshot // Deliberately permit a late old-session response.
    }
    func prepare() { prepares += 1 }
    func apply(_ value: Int, expected: String) async throws -> USBZoomResult {
        inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        let delay = delayNextWrite; delayNextWrite = nil
        if delay == .beforeWrite { await withCheckedContinuation { writeGate = $0 } }
        try Task.checkCancellation()
        guard expected == session else { throw BridgeFailure("session_changed", "Fake write session changed") }
        writes.append(.init(value: value, session: expected)); capabilities.current = value
        let response = capabilities
        if delay == .afterWrite { await withCheckedContinuation { writeGate = $0 } }
        // A submitted operation may deliver its old result after cancellation;
        // the UI must reject it independently of the Core cancellation fence.
        return USBZoomResult(target: value, observed: value, accepted: true,
            completed: !returnUnverified, verified: !returnUnverified, verification: "fake_readback",
            capabilities: response, message: "Fake response", toleranceRaw: 1)
    }
    func releaseWrite() { let gate = writeGate; writeGate = nil; gate?.resume() }
    func releaseRead() { let gate = readGate; readGate = nil; gate?.resume() }
}

@MainActor private func zoomModel(_ fixture: ZoomModelFixture) -> CameraZoomModel {
    .init(readCapabilities: { try await fixture.read($0) },
          applyZoom: { try await fixture.apply($0, expected: $1) },
          prepare: { fixture.prepare() }, reportError: { fixture.errors.append($0) })
}
@MainActor private func eventuallyZoom(_ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw BridgeFailure("fake_wait_timeout", "Zoom model did not reach its fixture gate")
}

@MainActor @Test func zoomModelCoalescesLatestDragAndKeepsSliderEnabledDuringOwnMovingState() async throws {
    let io = ZoomModelFixture(), model = zoomModel(io)
    await model.refresh(sessionID: io.session, phase: "ready")
    io.delayNextWrite = .afterWrite
    model.request(fraction: 0.2)
    try await eventuallyZoom { io.writeGate != nil }
    model.request(fraction: 0.4); model.request(fraction: 0.8)
    await model.refresh(sessionID: io.session, phase: "moving")
    #expect(model.canInteract && model.isWorking && model.fraction == 0.8)
    #expect(io.reads.count == 1)
    io.releaseWrite()
    try await eventuallyZoom { !model.isWorking }
    #expect(io.writes.map(\.value) == [160,340])
    #expect(io.prepares == 1 && io.maximumInFlight == 1)
    #expect(model.capabilities?.current == 340 && io.errors.isEmpty)
}

@MainActor @Test func zoomModelLatestTargetCanWithdrawAnOlderQueuedTarget() async throws {
    let io = ZoomModelFixture(), model = zoomModel(io)
    await model.refresh(sessionID: io.session, phase: "ready")
    io.delayNextWrite = .afterWrite
    model.request(fraction: 0.2)
    try await eventuallyZoom { io.writeGate != nil }
    model.request(fraction: 0.8); model.request(fraction: 0.2)
    io.releaseWrite()
    try await eventuallyZoom { !model.isWorking }
    #expect(io.writes.map(\.value) == [160])
    #expect(model.capabilities?.current == 160)
}

@MainActor @Test func zoomModelCancellationFencesUnsentWriteAndClearsPendingTargets() async throws {
    let io = ZoomModelFixture(), model = zoomModel(io)
    await model.refresh(sessionID: io.session, phase: "ready")
    io.delayNextWrite = .beforeWrite
    model.request(fraction: 0.2)
    try await eventuallyZoom { io.writeGate != nil }
    model.request(fraction: 0.8); model.cancel()
    #expect(!model.canInteract && model.isCancelling)
    io.releaseWrite()
    try await eventuallyZoom { !model.isWorking }
    #expect(io.writes.isEmpty && io.errors.isEmpty)
    await model.refresh(sessionID: io.session, phase: "ready")
    model.request(fraction: 0.5)
    try await eventuallyZoom { !model.isWorking }
    #expect(io.writes.map(\.value) == [250])
    #expect(io.maximumInFlight == 1)
}

@MainActor @Test func zoomModelReconnectRejectsOldResponseAndWaitsForOldWorkerToFinish() async throws {
    let io = ZoomModelFixture(), model = zoomModel(io)
    await model.refresh(sessionID: io.session, phase: "ready")
    io.delayNextWrite = .afterWrite
    model.request(fraction: 0.2)
    try await eventuallyZoom { io.writeGate != nil }
    model.request(fraction: 0.8)
    io.session = "zoom-B"; io.capabilities.current = 300
    await model.refresh(sessionID: io.session, phase: "ready")
    #expect(model.sessionID == "zoom-B" && model.capabilities == nil && !model.canInteract)
    model.request(fraction: 1) // Must not create a second concurrent worker.
    io.releaseWrite()
    try await eventuallyZoom { !model.isWorking }
    #expect(model.capabilities == nil)
    await model.refresh(sessionID: io.session, phase: "ready")
    #expect(model.capabilities?.current == 300 && model.canInteract)
    model.request(fraction: 0.5)
    try await eventuallyZoom { !model.isWorking }
    #expect(io.writes == [.init(value: 160, session: "zoom-A"), .init(value: 250, session: "zoom-B")])
    #expect(io.maximumInFlight == 1 && io.errors.isEmpty)
}

@MainActor @Test func zoomModelReconnectAlsoRejectsLateCapabilityRead() async throws {
    let io = ZoomModelFixture(), model = zoomModel(io)
    io.delayNextRead = true
    let old = Task { await model.refresh(sessionID: "zoom-A", phase: "ready") }
    try await eventuallyZoom { io.readGate != nil }
    io.session = "zoom-B"; io.capabilities.current = 300
    await model.refresh(sessionID: "zoom-B", phase: "ready")
    io.releaseRead(); await old.value
    #expect(model.capabilities == nil && model.sessionID == "zoom-B")
    await model.refresh(sessionID: "zoom-B", phase: "ready")
    #expect(model.capabilities?.current == 300 && model.canInteract)
}

@MainActor @Test func zoomModelExternalBlockingCancelsOwnMovingWorker() async throws {
    let io = ZoomModelFixture(), model = zoomModel(io)
    await model.refresh(sessionID: io.session, phase: "ready")
    io.delayNextWrite = .beforeWrite
    model.request(fraction: 0.5)
    try await eventuallyZoom { io.writeGate != nil }
    await model.refresh(sessionID: io.session, phase: "moving", blocked: true)
    io.releaseWrite()
    try await eventuallyZoom { !model.isWorking }
    #expect(io.writes.isEmpty && !model.canInteract)
}

@MainActor @Test func zoomModelUnsupportedAndUnreadyStatesNeverStartAWrite() async {
    let io = ZoomModelFixture(), model = zoomModel(io)
    await model.refresh(sessionID: io.session, phase: "connecting")
    model.request(fraction: 0.5)
    #expect(io.reads.isEmpty && io.writes.isEmpty && io.prepares == 0)
    io.capabilities.writable = false
    await model.refresh(sessionID: io.session, phase: "ready")
    model.request(fraction: 0.5); model.request(fraction: .nan)
    #expect(!model.canInteract && !model.isWorking && io.writes.isEmpty && io.prepares == 0)
}

@MainActor @Test func zoomModelUnconfirmedReadbackDropsQueuedTargetsWithoutRetrying() async throws {
    let io = ZoomModelFixture(), model = zoomModel(io)
    await model.refresh(sessionID: io.session, phase: "ready")
    io.delayNextWrite = .afterWrite; io.returnUnverified = true
    model.request(fraction: 0.2)
    try await eventuallyZoom { io.writeGate != nil }
    model.request(fraction: 0.8)
    io.releaseWrite()
    try await eventuallyZoom { !model.isWorking }
    #expect(io.writes.map(\.value) == [160])
    #expect(io.errors.count == 1 && model.lastError != nil)
}

@MainActor @Test func zoomModelRangeUsesAdvertisedGridAndNeverProducesFractionalRawTargets() throws {
    let caps = USBZoomCapabilities(current: 100, minimum: 100, maximum: 400, step: 10, writable: true)
    let range = try #require(CameraZoomRange(caps))
    #expect(range.rawValue(fraction: 0.51) == 250)
    #expect(range.rawValue(fraction: -1) == 100 && range.rawValue(fraction: 2) == 400)
    #expect(range.fraction(rawValue: 250) == 0.5)
    let invalidGrid = USBZoomCapabilities(current: 100, minimum: 100, maximum: 105, step: 10, writable: true)
    #expect(CameraZoomRange(invalidGrid) == nil)
}
