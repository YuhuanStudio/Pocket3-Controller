import Foundation
import Testing
@testable import Pocket3Core

private func expectFocusFailure(_ code: String, _ body: () throws -> Void) {
    do { try body(); Issue.record("Expected \(code)") }
    catch { #expect((error as? BridgeFailure)?.code == code) }
}

@Test func focusPointRejectsInvalidCoordinatesIncludingDecodedRequests() throws {
    for value in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
        expectFocusFailure("invalid_focus_point") { _ = try CameraFocusPoint(x: value, y: 0.5) }
        expectFocusFailure("invalid_focus_point") { _ = try CameraFocusPoint(x: 0.5, y: value) }
    }
    expectFocusFailure("invalid_focus_point") {
        _ = try JSONDecoder().decode(CameraFocusPoint.self, from: Data(#"{"x":2,"y":0.5}"#.utf8))
    }
    let topLeft = try CameraFocusPoint(x: 0, y: 0), bottomRight = try CameraFocusPoint(x: 1, y: 1)
    #expect(topLeft.cgPoint.x == 0 && bottomRight.cgPoint.y == 1)
    #expect(try JSONDecoder().decode(CameraFocusPoint.self, from: JSONEncoder().encode(topLeft)) == topLeft)
}

@Test func tapFocusPrefersSingleAutofocusAndRequiresAPointCapableMode() throws {
    #expect(try FocusPointPolicy.mode(supportsPoint: true, supportsAuto: true, supportsContinuous: true) == .autoFocus)
    #expect(try FocusPointPolicy.mode(supportsPoint: true, supportsAuto: false, supportsContinuous: true) == .continuousAutoFocus)
    expectFocusFailure("focus_point_unsupported") {
        _ = try FocusPointPolicy.mode(supportsPoint: false, supportsAuto: true, supportsContinuous: true)
    }
    expectFocusFailure("focus_mode_unsupported") {
        _ = try FocusPointPolicy.mode(supportsPoint: true, supportsAuto: false, supportsContinuous: false)
    }
    #expect(!FocusCapabilities.unavailable.canFocus)
}

@Test func focusTokenRejectsReconnectReconfigureAndDifferentInput() throws {
    let token = CaptureLifecycleToken(generation: 3, sessionID: "capture-A", deviceID: "camera-A")
    try token.validate(generation: 3, sessionID: "capture-A", deviceID: "camera-A")
    for (generation, session, device) in [(UInt64(4), "capture-A", "camera-A"), (3, "capture-B", "camera-A"), (3, "capture-A", "camera-B")] {
        expectFocusFailure("session_changed") { try token.validate(generation: generation, sessionID: session, deviceID: device) }
    }
    let capabilities = FocusCapabilities(supportsPoint: true, supportsAuto: true, supportsContinuous: false,
        currentMode: .locked, sessionToken: token)
    #expect(capabilities.canFocus && capabilities.sessionID == "capture-A")
    #expect(try JSONDecoder().decode(FocusCapabilities.self, from: JSONEncoder().encode(capabilities)) == capabilities)
}

@Test func queuedFocusCannotCommitAfterLifecycleResetOrCancellation() throws {
    let fence = CaptureCallbackFence()
    let old = fence.currentGeneration()
    _ = fence.advance()
    var propertyWrites = 0
    expectFocusFailure("session_changed") {
        try fence.withCurrent(old) { propertyWrites += 1 }
    }
    let permit = OperationPermit()
    permit.invalidate()
    let current = fence.currentGeneration()
    expectFocusFailure("cancelled") {
        try permit.perform { try fence.withCurrent(current) { propertyWrites += 1 } }
    }
    #expect(propertyWrites == 0)
    try fence.withCurrent(current) { propertyWrites += 1 }
    #expect(propertyWrites == 1)
}

@Test func pointReadbackNeverClaimsOpticalFocusAndRejectsMismatchedModeOrPoint() throws {
    let point = try CameraFocusPoint(x: 0.25, y: 0.75)
    let result = FocusResult(sessionID: "capture-A", requestedPoint: point, observedPoint: point,
        requestedMode: .autoFocus, observedMode: .autoFocus, adjustingFocus: false,
        submittedUptime: 1, readbackUptime: 1.01)
    #expect(result.pointAndModeConfirmed && !result.opticalFocusConfirmed)
    #expect(!FocusPointPolicy.confirms(point: point, mode: .autoFocus, observedPoint: point, observedMode: .continuousAutoFocus))
    #expect(!FocusPointPolicy.confirms(point: point, mode: .autoFocus, observedPoint: nil, observedMode: .autoFocus))
    let different = try CameraFocusPoint(x: 0.5, y: 0.5)
    #expect(!FocusPointPolicy.confirms(point: point, mode: .autoFocus, observedPoint: different, observedMode: .autoFocus))
}
