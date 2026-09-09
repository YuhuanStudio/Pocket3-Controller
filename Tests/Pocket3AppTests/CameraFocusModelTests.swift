import Foundation
import Testing
@testable import Pocket3Core
@testable import Pocket3BridgeApp

private actor FocusModelFixture {
    struct Write: Sendable { let point: CameraFocusPoint; let token: CaptureLifecycleToken }
    private(set) var capabilities: FocusCapabilities
    private(set) var writes: [Write] = []
    init(token: CaptureLifecycleToken, supported: Bool = true) {
        capabilities = FocusCapabilities(supportsPoint: supported, supportsAuto: supported,
            supportsContinuous: supported, currentMode: .autoFocus, sessionToken: token)
    }
    func changeToken(_ token: CaptureLifecycleToken) {
        capabilities = FocusCapabilities(supportsPoint: true, supportsAuto: true,
            supportsContinuous: true, currentMode: .autoFocus, sessionToken: token)
    }
    func apply(_ point: CGPoint, token: CaptureLifecycleToken) throws -> FocusResult {
        let selected = try CameraFocusPoint(point)
        writes.append(Write(point: selected, token: token))
        return FocusResult(sessionID: token.sessionID, requestedPoint: selected, observedPoint: selected,
            requestedMode: .autoFocus, observedMode: .autoFocus, adjustingFocus: false,
            submittedUptime: 1, readbackUptime: 1.01)
    }
}
private let focusToken = CaptureLifecycleToken(generation: 1, sessionID: "focus-A", deviceID: "camera-A")
private func focusStats(_ token: CaptureLifecycleToken = focusToken) -> CaptureStats {
    let frame = FrameInfo(id: "frame-1", sessionID: token.sessionID, deviceID: token.deviceID,
        receivedAt: Date(), receivedUptime: 1, presentationTime: 1, width: 1920, height: 1080)
    return CaptureStats(sessionID: token.sessionID, frames: 1, recentFPS: 30, frame: frame, age: 0.1, audio: .init())
}
private enum FocusModelTestFailure: Error { case timeout }
@MainActor private func eventuallyFocus(_ condition: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw FocusModelTestFailure.timeout
}
@MainActor private func focusModel(_ fixture: FocusModelFixture) -> CameraFocusModel {
    CameraFocusModel(readCapabilities: { await fixture.capabilities }, apply: { point, token in
        try await fixture.apply(point, token: token)
    })
}

@MainActor @Test func unsupportedPreviewFocusReportsConnectionLimitWithoutSending() async {
    let fixture = FocusModelFixture(token: focusToken, supported: false)
    let model = focusModel(fixture)
    await model.refresh(capture: focusStats(), phase: "ready")
    #expect(!model.request(at: CGPoint(x: 0.5, y: 0.5), previewSessionID: focusToken.sessionID, previewDeviceID: focusToken.deviceID))
    #expect(model.message != nil && model.requestedPoint == nil && !model.isSettingPoint)
    #expect(await fixture.writes.isEmpty)
}

@MainActor @Test func oldPreviewSessionOrDeviceCannotTargetCurrentFocusInput() async {
    let fixture = FocusModelFixture(token: focusToken)
    let model = focusModel(fixture)
    await model.refresh(capture: focusStats(), phase: "ready")
    #expect(!model.request(at: .zero, previewSessionID: "old-session", previewDeviceID: focusToken.deviceID))
    #expect(!model.request(at: .zero, previewSessionID: focusToken.sessionID, previewDeviceID: "old-camera"))
    #expect(await fixture.writes.isEmpty)
}

@MainActor @Test func previewFocusCoalescesToLatestPointAndCancelFencesPendingClick() async throws {
    let fixture = FocusModelFixture(token: focusToken)
    let model = focusModel(fixture)
    await model.refresh(capture: focusStats(), phase: "ready")
    #expect(model.request(at: CGPoint(x: 0.1, y: 0.2), previewSessionID: focusToken.sessionID, previewDeviceID: focusToken.deviceID))
    model.cancel()
    try await Task.sleep(for: .milliseconds(100))
    #expect(await fixture.writes.isEmpty)
    #expect(model.requestedPoint == nil && !model.isSettingPoint)

    #expect(model.request(at: CGPoint(x: 0.2, y: 0.3), previewSessionID: focusToken.sessionID, previewDeviceID: focusToken.deviceID))
    #expect(model.request(at: CGPoint(x: 0.7, y: 0.8), previewSessionID: focusToken.sessionID, previewDeviceID: focusToken.deviceID))
    try await eventuallyFocus { !model.isSettingPoint }
    let writes = await fixture.writes
    #expect(writes.count == 1 && writes[0].point.x == 0.7 && writes[0].point.y == 0.8)
    #expect(model.lastResult?.pointAndModeConfirmed == true && model.lastResult?.opticalFocusConfirmed == false)
}

@MainActor @Test func previewReconnectCancelsQueuedPointAndClearsRequestedMarker() async throws {
    let fixture = FocusModelFixture(token: focusToken)
    let model = focusModel(fixture)
    await model.refresh(capture: focusStats(), phase: "ready")
    #expect(model.request(at: CGPoint(x: 0.7, y: 0.8), previewSessionID: focusToken.sessionID, previewDeviceID: focusToken.deviceID))
    let replacement = CaptureLifecycleToken(generation: 2, sessionID: "focus-B", deviceID: "camera-A")
    await fixture.changeToken(replacement)
    await model.refresh(capture: focusStats(replacement), phase: "ready")
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.requestedPoint == nil && model.lastResult == nil && !model.isSettingPoint)
    #expect(model.capabilities.sessionToken == replacement)
    #expect(await fixture.writes.isEmpty)
}

@MainActor @Test func oldPreviewTeardownCannotCancelNewSurfaceFocusRequest() async throws {
    let fixture = FocusModelFixture(token: focusToken)
    let model = focusModel(fixture)
    await model.refresh(capture: focusStats(), phase: "ready")
    let oldSurface = UUID(), newSurface = UUID()
    #expect(model.request(at: CGPoint(x: 0.1, y: 0.2), previewSessionID: focusToken.sessionID,
        previewDeviceID: focusToken.deviceID, surfaceID: oldSurface))
    #expect(model.request(at: CGPoint(x: 0.8, y: 0.9), previewSessionID: focusToken.sessionID,
        previewDeviceID: focusToken.deviceID, surfaceID: newSurface))
    model.cancel(surfaceID: oldSurface)
    try await eventuallyFocus { !model.isSettingPoint }
    let writes = await fixture.writes
    #expect(writes.count == 1 && writes[0].point.x == 0.8 && writes[0].point.y == 0.9)
}
