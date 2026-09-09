import XCTest
@testable import Pocket3Core
import CoreVideo
import Pocket3UVC

final class CoreTests: XCTestCase {
    func testUVCCacheOutlivesOneHundredAutoreleasePools() {
        XCTAssertEqual(p3_uvc_contract_selftest(), 1)
    }
    func testDeviceIdentityRequiresMatchingUSBIDs() {
        XCTAssertEqual(CameraDevice.location(from: "0x11000002ca30023"), 0x01100000)
        XCTAssertNil(CameraDevice.location(from: "0x11000002ca30024"))
        XCTAssertNil(CameraDevice.location(from: "Camera 0"))
    }
    func testFrameInvalidationDoesNotReturnPreviousSession() throws {
        let store = FrameStore()
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        store.reset(deviceID: "camera-a")
        store.receive(pixel!, pts: 1)
        let first = try store.latest()
        store.reset(deviceID: "camera-b")
        XCTAssertThrowsError(try store.latest())
        store.receive(pixel!, pts: 2)
        XCTAssertNotEqual(try store.latest().info.sessionID, first.info.sessionID)
        XCTAssertEqual(try store.latest().info.deviceID, "camera-b")
        XCTAssertThrowsError(try store.latest(after: ProcessInfo.processInfo.systemUptime + 10))
    }
    func testMotionRejectsUnknownDirectionAndLimitInsteadOfClamping() throws {
        let cap = UVCCapabilities(location: 1, position: .init(pan: 0, tilt: 0), minimum: .init(pan: -3600, tilt: -3600), maximum: .init(pan: 3600, tilt: 3600), step: .init(pan: 3600, tilt: 3600), writable: true, controls: [], uvcVersion: 256)
        XCTAssertEqual(try MotionPolicy.target(direction: "left", origin: cap.position, capabilities: cap), .init(pan: -3600, tilt: 0))
        XCTAssertThrowsError(try MotionPolicy.target(direction: "left", origin: .init(pan: -3600, tilt: 0), capabilities: cap))
        XCTAssertThrowsError(try MotionPolicy.target(direction: "spin", origin: cap.position, capabilities: cap))
    }
    func testJSONContractRoundTripPreservesTypes() throws {
        let value = JSONValue.object(["enabled": .bool(true), "count": .number(3), "missing": .null, "items": .array([.string("a")])])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }
    func testIdleAutomationDoesNotOpenHardware() async {
        let service = CameraService()
        let reply = await service.handle(ServiceRequest(token: "test", operation: "snapshot"))
        XCTAssertEqual(reply.error?.code, "access_denied")
        XCTAssertNil(reply.imageJPEG)
    }
}
