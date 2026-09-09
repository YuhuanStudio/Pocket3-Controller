import Foundation

/// The model's camera boundary. The production conformer owns USB and capture;
/// evaluation can supply an explicitly simulated camera without opening hardware.
public protocol ObservationCamera: Sendable {
    func beginObservation(origin: RequestOrigin) async throws -> ObservationStart
    func frame(origin: RequestOrigin, after: Double) async throws -> FramePacket
    func validateInteraction(_ stamp: InteractionStamp, origin: RequestOrigin) async throws
    func move(direction: String, origin: RequestOrigin, interaction: InteractionStamp?) async throws -> MotionResult
    func zoomCapabilitiesForObservation(interaction: InteractionStamp) async throws -> USBZoomCapabilities
    func zoomForObservation(rawValue: Int, interaction: InteractionStamp) async throws -> USBZoomResult
    func stopIfInteractionCurrent(_ stamp: InteractionStamp) async throws -> MotionResult?
}
public extension ObservationCamera {
    func frame(origin: RequestOrigin) async throws -> FramePacket { try await frame(origin: origin, after: 0) }
    func zoomCapabilitiesForObservation(interaction: InteractionStamp) async throws -> USBZoomCapabilities {
        throw BridgeFailure("zoom_unavailable", "此相機介面尚未提供 AI 縮放")
    }
    func zoomForObservation(rawValue: Int, interaction: InteractionStamp) async throws -> USBZoomResult {
        throw BridgeFailure("zoom_unavailable", "此相機介面尚未提供 AI 縮放")
    }
}
public struct ObservationStart: Sendable {
    public let stamp: InteractionStamp
    public let canMove: Bool
    public let canZoom: Bool
    public let zoomCapabilities: USBZoomCapabilities?
    public init(stamp: InteractionStamp, canMove: Bool, canZoom: Bool = false, zoomCapabilities: USBZoomCapabilities? = nil) {
        self.stamp = stamp; self.canMove = canMove
        self.canZoom = canZoom && zoomCapabilities.map(ObservationZoomPolicy.isAvailable) == true
        self.zoomCapabilities = self.canZoom ? zoomCapabilities : nil
    }
}
extension CameraService: ObservationCamera {
    public func beginObservation(origin: RequestOrigin) async throws -> ObservationStart {
        let stamp = try interactionStamp(origin: origin)
        let snapshot = await status()
        try validateInteraction(stamp, origin: origin)
        let zoom: USBZoomCapabilities?
        if snapshot.access == .control { zoom = try? await zoomCapabilities(expectedSessionID: stamp.sessionID) }
        else { zoom = nil }
        try Task.checkCancellation()
        try validateInteraction(stamp, origin: origin)
        return ObservationStart(stamp: stamp, canMove: observationMovementIsAllowed,
            canZoom: snapshot.access == .control, zoomCapabilities: zoom)
    }
    public func zoomCapabilitiesForObservation(interaction: InteractionStamp) async throws -> USBZoomCapabilities {
        try validateInteraction(interaction, origin: .automation)
        let result = try await zoomCapabilities(expectedSessionID: interaction.sessionID)
        try validateInteraction(interaction, origin: .automation)
        return result
    }
    public func zoomForObservation(rawValue: Int, interaction: InteractionStamp) async throws -> USBZoomResult {
        // This actor-isolated call validates the original interaction before
        // entering zoom(), whose own epoch/permit checks fence its first await
        // and final hardware write. It never requests manual privilege.
        try validateInteraction(interaction, origin: .automation)
        let result = try await zoom(rawValue: rawValue, expectedSessionID: interaction.sessionID, origin: .automation)
        try validateInteraction(interaction, origin: .automation)
        return result
    }
}

/// Shares the service's raw-value policy with model tools. Neither availability
/// nor a zoom result grants gimbal permission or implies an optical multiplier.
public enum ObservationZoomPolicy {
    public static func isAvailable(_ capabilities: USBZoomCapabilities) -> Bool {
        guard let low = capabilities.minimum, let high = capabilities.maximum, low <= high,
              (0...65535).contains(capabilities.current), (low...high).contains(capabilities.current) else { return false }
        do { try USBZoomPolicy.validate(low, capabilities: capabilities); return true } catch { return false }
    }
    public static func validate(rawValue: Int, capabilities: USBZoomCapabilities) throws {
        try USBZoomPolicy.validate(rawValue, capabilities: capabilities)
    }
    public static func confirms(_ result: USBZoomResult, requested: Int) -> Bool {
        guard result.accepted, result.completed, result.verified, result.target == requested,
              isAvailable(result.capabilities), result.observed == result.capabilities.current else { return false }
        let tolerance = result.toleranceRaw ?? 0
        guard tolerance >= 0, tolerance <= USBZoomPolicy.readbackTolerance(capabilities: result.capabilities),
              (0...65535).contains(requested) else { return false }
        return abs(result.observed - requested) <= tolerance
    }
}
