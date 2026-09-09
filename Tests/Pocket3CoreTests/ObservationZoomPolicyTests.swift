import Testing
@testable import Pocket3Core

private let observationZoomCaps = USBZoomCapabilities(current: 100, minimum: 100, maximum: 400, step: 1, writable: true)

@Test func observationZoomPermissionIsIndependentOfGimbalStopValidation() {
    let stamp = InteractionStamp(sessionID: "test-session", epoch: 1)
    let zoomOnly = ObservationStart(stamp: stamp, canMove: false, canZoom: true, zoomCapabilities: observationZoomCaps)
    #expect(zoomOnly.canZoom && !zoomOnly.canMove)
    let denied = ObservationStart(stamp: stamp, canMove: true, canZoom: false, zoomCapabilities: observationZoomCaps)
    #expect(!denied.canZoom && denied.canMove)
    let missing = ObservationStart(stamp: stamp, canMove: false, canZoom: true)
    #expect(!missing.canZoom && missing.zoomCapabilities == nil)
}

@Test func observationZoomRequiresWritableValidDeviceLimits() {
    let invalid = [
        USBZoomCapabilities(current: 100, minimum: 100, maximum: 400, step: 1, writable: false),
        USBZoomCapabilities(current: 100, minimum: nil, maximum: 400, step: 1, writable: true),
        USBZoomCapabilities(current: 100, minimum: 400, maximum: 100, step: 1, writable: true),
        USBZoomCapabilities(current: 99, minimum: 100, maximum: 400, step: 1, writable: true),
        USBZoomCapabilities(current: 100, minimum: 100, maximum: 400, step: -1, writable: true)
    ]
    for capabilities in invalid { #expect(!ObservationZoomPolicy.isAvailable(capabilities)) }
    #expect(ObservationZoomPolicy.isAvailable(observationZoomCaps))
    #expect(throws: BridgeFailure.self) { try ObservationZoomPolicy.validate(rawValue: Int.max, capabilities: observationZoomCaps) }
    #expect(throws: BridgeFailure.self) {
        try ObservationZoomPolicy.validate(rawValue: 101, capabilities: .init(current: 100, minimum: 100, maximum: 400, step: 5, writable: true))
    }
}

@Test func observationZoomEvidenceHonorsOnlyTheReportedBoundedRawTolerance() {
    let capabilities = USBZoomCapabilities(current: 146, minimum: 100, maximum: 400, step: 1, writable: true)
    func result(tolerance: Int?, verified: Bool = true, target: Int = 147) -> USBZoomResult {
        USBZoomResult(target: target, observed: 146, accepted: true, completed: verified, verified: verified,
            verification: "fixture", capabilities: capabilities, message: "Fixture only", toleranceRaw: tolerance)
    }
    #expect(ObservationZoomPolicy.confirms(result(tolerance: 1), requested: 147))
    #expect(!ObservationZoomPolicy.confirms(result(tolerance: nil), requested: 147))
    #expect(!ObservationZoomPolicy.confirms(result(tolerance: 2), requested: 147))
    #expect(!ObservationZoomPolicy.confirms(result(tolerance: 1, verified: false), requested: 147))
    #expect(!ObservationZoomPolicy.confirms(result(tolerance: 1, target: 148), requested: 147))
}
