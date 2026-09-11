import Foundation
import CoreVideo
import Testing
@testable import Pocket3Core

private final class StatusCameraConnection: CameraControlConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Result<UVCCapabilities, BridgeFailure>]
    private let onStatus: (@Sendable () -> Void)?
    private var currentZoom = 100
    private(set) var statusCalls = 0
    private(set) var zoomWrites: [Int] = []
    private(set) var invalidated = false

    init(outcomes: [Result<UVCCapabilities, BridgeFailure>], onStatus: (@Sendable () -> Void)? = nil) {
        self.outcomes = outcomes
        self.onStatus = onStatus
    }

    func invalidate() {
        lock.withLock { invalidated = true }
    }

    func status() async throws -> UVCCapabilities {
        let outcome = lock.withLock { () -> Result<UVCCapabilities, BridgeFailure> in
            statusCalls += 1
            return outcomes.isEmpty ? .success(statusCapabilities()) : outcomes.removeFirst()
        }
        onStatus?()
        return try outcome.get()
    }

    func set(_ position: GimbalPosition, permit: OperationPermit?) async throws {
        try permit?.perform {}
    }

    func zoomStatus() async throws -> USBZoomCapabilities {
        .init(current: lock.withLock { currentZoom }, minimum: 100, maximum: 400, step: 1, writable: true)
    }

    func setZoom(rawValue: Int, validUntil: TimeInterval, permit: OperationPermit,
                 connectionPermit: OperationPermit?) async throws {
        try connectionPermit?.perform {}
        try permit.perform {
            guard ProcessInfo.processInfo.systemUptime <= validUntil else {
                throw BridgeFailure("zoom_timing", "Synthetic write expired")
            }
            lock.withLock {
                currentZoom = rawValue
                zoomWrites.append(rawValue)
            }
        }
    }

    func rollStatus() async throws -> USBRollCapabilities {
        throw BridgeFailure("fixture_no_roll", "No Roll in this fixture")
    }

    func setRoll(rawValue: Int, validUntil: TimeInterval, permit: OperationPermit,
                 connectionPermit: OperationPermit?) async throws {
        throw BridgeFailure("fixture_no_roll", "No Roll in this fixture")
    }

    func setFast(_ position: GimbalPosition, validUntil: TimeInterval, permit: OperationPermit,
                 connectionPermit: OperationPermit?) async throws {
        try await set(position, permit: permit)
    }

    private func statusCapabilities() -> UVCCapabilities {
        .init(location: 1, position: .init(pan: 0, tilt: 0),
              minimum: .init(pan: -36000, tilt: -36000),
              maximum: .init(pan: 36000, tilt: 36000),
              step: .init(pan: 3600, tilt: 3600), writable: true,
              controls: ["pan-tilt-abs"], uvcVersion: 256)
    }
}

private final class StatusSeamState: @unchecked Sendable {
    private let lock = NSLock()
    private var available: [CameraDevice]
    private var fresh = true
    private(set) var invalidationCount = 0

    init(device: CameraDevice) { available = [device] }

    func devices() -> [CameraDevice] { lock.withLock { available } }
    func setDevices(_ devices: [CameraDevice]) { lock.withLock { available = devices } }
    func isFresh(_ deviceID: String) -> Bool { lock.withLock { fresh } }
    func setFresh(_ value: Bool) { lock.withLock { fresh = value } }
    func noteInvalidation() { lock.withLock { invalidationCount += 1 } }
}

private func statusFixtureFrame(deviceID: String) throws -> FramePacket {
    var pixels: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 32, 16, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess,
          let pixels else { throw BridgeFailure("fixture_pixels", "Could not allocate synthetic pixels") }
    let info = FrameInfo(id: "status-fixture-frame", sessionID: "status-fixture-session", deviceID: deviceID,
                         receivedAt: Date(), receivedUptime: ProcessInfo.processInfo.systemUptime,
                         presentationTime: 1, width: 32, height: 16, timestampSource: "simulation_only")
    return FramePacket(pixelBuffer: pixels, info: info)
}

private func statusCapabilities() -> UVCCapabilities {
    .init(location: 1, position: .init(pan: 0, tilt: 0),
          minimum: .init(pan: -36000, tilt: -36000),
          maximum: .init(pan: 36000, tilt: 36000),
          step: .init(pan: 3600, tilt: 3600), writable: true,
          controls: ["pan-tilt-abs"], uvcVersion: 256)
}

@Test func transientUVCStatusReadKeepsFreshCaptureAndCapabilities() async throws {
    let device = CameraDevice(id: "status-camera", name: "Status Camera", location: nil)
    let seamState = StatusSeamState(device: device)
    let invalidations = seamState
    let connection = StatusCameraConnection(outcomes: [
        .success(statusCapabilities()),
        .failure(BridgeFailure("uvc_control_read_failed", "temporary GET_CUR failure")),
        .failure(BridgeFailure("uvc_control_read_failed", "temporary GET_CUR failure")),
    ])
    let seam = CameraServiceStatusSeam(
        devices: { seamState.devices() },
        captureIsFreshForSelectedDevice: { deviceID in seamState.isFresh(deviceID) },
        onAttachmentInvalidated: { invalidations.noteInvalidation() })
    let service = CameraService(testConnection: connection, testFrame: try statusFixtureFrame(deviceID: device.id), statusSeam: seam)

    let initial = await service.status()
    #expect(initial.phase == "ready")
    #expect(initial.gimbal?.position == statusCapabilities().position)

    let degraded = await service.status()
    #expect(degraded.phase == "ready")
    #expect(degraded.capture.frames == 1)
    #expect(degraded.selected?.id == device.id)
    #expect(degraded.gimbal?.position == statusCapabilities().position)
    #expect(degraded.controlReadIssueCode == "uvc_control_read_failed")
    #expect(degraded.lastControlReadFailureAt != nil)
    #expect(degraded.controlTransport?.contains("degraded") == true)
    #expect(seamState.invalidationCount == 0)
    #expect(!connection.invalidated)

    // Repeated generic failures remain degraded; count-based unplug guesses are forbidden.
    let repeated = await service.status()
    #expect(repeated.phase == "ready")
    #expect(repeated.capture.frames == 1)
    #expect(seamState.invalidationCount == 0)
}

@Test func successfulUVCStatusReadClearsTransientIssue() async throws {
    let device = CameraDevice(id: "status-recovery-camera", name: "Status Camera", location: nil)
    let seamState = StatusSeamState(device: device)
    let connection = StatusCameraConnection(outcomes: [
        .failure(BridgeFailure("uvc_control_read_failed", "temporary GET_CUR failure")),
        .success(statusCapabilities()),
    ])
    let seam = CameraServiceStatusSeam(
        devices: { seamState.devices() },
        captureIsFreshForSelectedDevice: { deviceID in seamState.isFresh(deviceID) })
    let service = CameraService(testConnection: connection, testFrame: try statusFixtureFrame(deviceID: device.id), statusSeam: seam)

    let degraded = await service.status()
    #expect(degraded.controlReadIssueCode == "uvc_control_read_failed")
    let recovered = await service.status()
    #expect(recovered.phase == "ready")
    #expect(recovered.controlReadIssueCode == nil)
    #expect(recovered.lastControlReadFailureAt == nil)
    #expect(recovered.controlTransport == "usb_position")
    #expect(seamState.invalidationCount == 0)
}

@Test func identityUVCStatusFailuresInvalidateCapture() async throws {
    for code in ["uvc_attachment_changed", "hardware_identity", "uvc_connection_closed", "uvc_device_missing"] {
        let device = CameraDevice(id: "identity-\(code)", name: "Status Camera", location: nil)
        let seamState = StatusSeamState(device: device)
        let connection = StatusCameraConnection(outcomes: [
            .failure(BridgeFailure(code, "identity failure")),
        ])
        let seam = CameraServiceStatusSeam(
            devices: { seamState.devices() },
            captureIsFreshForSelectedDevice: { deviceID in seamState.isFresh(deviceID) },
            onAttachmentInvalidated: { seamState.noteInvalidation() })
        let service = CameraService(testConnection: connection, testFrame: try statusFixtureFrame(deviceID: device.id), statusSeam: seam)

        let status = await service.status()
        #expect(status.phase == "disconnected")
        #expect(status.capture.frames == 0)
        #expect(seamState.invalidationCount == 1)
        #expect(connection.invalidated)
    }
}

@Test func genericUVCStatusFailureRetiresAttachmentWhenCaptureIsNotFresh() async throws {
    let device = CameraDevice(id: "stale-capture-camera", name: "Status Camera", location: nil)
    let seamState = StatusSeamState(device: device)
    seamState.setFresh(false)
    let connection = StatusCameraConnection(outcomes: [
        .failure(BridgeFailure("uvc_position_unavailable", "position read unavailable")),
    ])
    let seam = CameraServiceStatusSeam(
        devices: { seamState.devices() },
        captureIsFreshForSelectedDevice: { deviceID in seamState.isFresh(deviceID) },
        onAttachmentInvalidated: { seamState.noteInvalidation() })
    let service = CameraService(testConnection: connection, testFrame: try statusFixtureFrame(deviceID: device.id), statusSeam: seam)

    let status = await service.status()
    #expect(status.phase == "disconnected")
    #expect(status.capture.frames == 0)
    #expect(status.controlReadIssueCode == nil)
    #expect(seamState.invalidationCount == 1)
}

@Test func statusReadUsesCurrentDeviceDiscoveryAfterAsyncFailure() async throws {
    let device = CameraDevice(id: "disappearing-camera", name: "Status Camera", location: nil)
    let seamState = StatusSeamState(device: device)
    let connection = StatusCameraConnection(
        outcomes: [.failure(BridgeFailure("uvc_position_unavailable", "position read unavailable"))],
        onStatus: { seamState.setDevices([]) })
    let seam = CameraServiceStatusSeam(
        devices: { seamState.devices() },
        captureIsFreshForSelectedDevice: { deviceID in seamState.isFresh(deviceID) },
        onAttachmentInvalidated: { seamState.noteInvalidation() })
    let service = CameraService(testConnection: connection, testFrame: try statusFixtureFrame(deviceID: device.id), statusSeam: seam)

    let status = await service.status()
    #expect(status.phase == "disconnected")
    #expect(status.devices.isEmpty)
    #expect(status.capture.frames == 0)
    #expect(seamState.invalidationCount == 1)
}

@Test func missingSelectedDeviceInvalidatesWithoutReadingUVC() async throws {
    let device = CameraDevice(id: "removed-camera", name: "Status Camera", location: nil)
    let seamState = StatusSeamState(device: device)
    seamState.setDevices([])
    let connection = StatusCameraConnection(outcomes: [.success(statusCapabilities())])
    let seam = CameraServiceStatusSeam(
        devices: { seamState.devices() },
        captureIsFreshForSelectedDevice: { deviceID in seamState.isFresh(deviceID) },
        onAttachmentInvalidated: { seamState.noteInvalidation() })
    let service = CameraService(testConnection: connection, testFrame: try statusFixtureFrame(deviceID: device.id), statusSeam: seam)

    let status = await service.status()
    #expect(status.phase == "disconnected")
    #expect(status.capture.frames == 0)
    #expect(connection.statusCalls == 0)
    #expect(seamState.invalidationCount == 1)
}

@Test func degradedStatusRequiresSuccessfulAttachmentReadBeforeZoomWrite() async throws {
    let device = CameraDevice(id: "write-fence-camera", name: "Status Camera", location: nil)
    let seamState = StatusSeamState(device: device)
    let connection = StatusCameraConnection(outcomes: [
        .failure(BridgeFailure("uvc_control_read_failed", "temporary GET_CUR failure")),
        .success(statusCapabilities()),
    ])
    let seam = CameraServiceStatusSeam(
        devices: { seamState.devices() },
        captureIsFreshForSelectedDevice: { deviceID in seamState.isFresh(deviceID) })
    let service = CameraService(testConnection: connection, testFrame: try statusFixtureFrame(deviceID: device.id), statusSeam: seam)
    _ = await service.status()
    let sessionID = service.capture.store.stats().sessionID

    _ = try await service.zoom(rawValue: 200, expectedSessionID: sessionID, origin: .manual)
    #expect(connection.statusCalls == 2)
    #expect(connection.zoomWrites == [200])
    let recovered = await service.status()
    #expect(recovered.controlReadIssueCode == nil)
}
