import Foundation
import Testing
@testable import Pocket3Core

private let zoomCaps = USBZoomCapabilities(current: 100, minimum: 100, maximum: 400, step: 10, writable: true)

@Test func usbZoomRejectsNarrowingOverflowFractionalAndNonfiniteInput() throws {
    #expect(try USBZoomPolicy.rawValue(65535) == 65535)
    for value in [-1, 65536, 100.5, Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
        #expect(throws: BridgeFailure.self) { try USBZoomPolicy.rawValue(value) }
    }
}

@Test func usbZoomUsesAdvertisedBoundsAndStepWithoutRoundingOrInventingRatio() throws {
    try USBZoomPolicy.validate(100, capabilities: zoomCaps)
    try USBZoomPolicy.validate(400, capabilities: zoomCaps)
    for value in [99, 401, Int.max, Int.min, 111] {
        #expect(throws: BridgeFailure.self) { try USBZoomPolicy.validate(value, capabilities: zoomCaps) }
    }
    var noGrid = zoomCaps; noGrid.step = nil
    try USBZoomPolicy.validate(111, capabilities: noGrid)
    noGrid.step = 0
    try USBZoomPolicy.validate(111, capabilities: noGrid)
    let encoded = String(decoding: try JSONEncoder().encode(zoomCaps), as: UTF8.self)
    #expect(!encoded.contains("ratio") && !encoded.contains("multiplier"))
    #expect(try JSONDecoder().decode(USBZoomCapabilities.self, from: Data(encoded.utf8)) == zoomCaps)
}

@Test func usbZoomRequiresWritableCapabilityAndCompleteValidBounds() throws {
    var cases: [USBZoomCapabilities] = []
    var value = zoomCaps; value.writable = false; cases.append(value)
    value = zoomCaps; value.minimum = nil; cases.append(value)
    value = zoomCaps; value.maximum = 99; cases.append(value)
    value = zoomCaps; value.step = -1; cases.append(value)
    value = zoomCaps; value.minimum = -1; cases.append(value)
    for capabilities in cases {
        #expect(throws: BridgeFailure.self) { try USBZoomPolicy.validate(100, capabilities: capabilities) }
    }
}

@Test func usbZoomIPCFailsBeforeHardwareForInvalidValuesMissingSessionAndDisabledValidation() async {
    let service = CameraService()
    let invalid = await service.handle(.init(token: "fake", operation: "zoom", arguments: .object(["rawValue": .number(1.5)])))
    #expect(invalid.error?.code == "invalid_zoom_value")
    let missing = await service.handle(.init(token: "fake", operation: "zoom", arguments: .object(["rawValue": .number(100)])))
    #expect(missing.error?.code == "session_required")
    let disabled = await service.handle(.init(token: "fake", operation: "validation-zoom", arguments: .object(["rawValue": .number(100)])))
    #expect(disabled.error?.code == "validation_disabled")
    let status = await service.handle(.init(token: "fake", operation: "zoom-status"))
    #expect(status.error?.code == "camera_not_ready")
}
