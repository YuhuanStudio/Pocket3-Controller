#if DEBUG
import Foundation
import Pocket3Core

/// Only present in development builds. Reports always identify the simulation;
/// its successful moves are never accepted as physical stopping evidence.
public actor SimulatedObservationCamera: ObservationCamera {
    private let before: FramePacket
    private let after: FramePacket
    private var access: AccessMode
    private var epoch = 0
    private var session = UUID().uuidString
    private var counter = 0
    private var directions: [String] = []
    private var stopped = false
    private var moveDelay: Double
    private let moveValidated: Bool
    private var zoomCapabilities: USBZoomCapabilities?
    private let zoomDelay: Double
    private let zoomConfirmed: Bool
    private var zoomRequests: [Int] = []
    private var appliedZooms: [Int] = []
    public init(before: FramePacket, after: FramePacket, access: AccessMode = .control, moveDelay: Double = 0,
                moveValidated: Bool = true,
                zoomCapabilities: USBZoomCapabilities? = .init(current: 100, minimum: 100, maximum: 400, step: 1, writable: true),
                zoomDelay: Double = 0, zoomConfirmed: Bool = true) {
        self.before = before; self.after = after; self.access = access; self.moveDelay = min(5, max(0, moveDelay))
        self.moveValidated = moveValidated; self.zoomCapabilities = zoomCapabilities
        self.zoomDelay = zoomDelay.isFinite ? min(5, max(0, zoomDelay)) : 0
        self.zoomConfirmed = zoomConfirmed
    }
    public func beginObservation(origin: RequestOrigin) throws -> ObservationStart {
        if origin == .automation && access == .manual { throw BridgeFailure("access_denied", "Simulated observation is not permitted") }
        return .init(stamp: .init(sessionID: session, epoch: epoch), canMove: access == .control && moveValidated,
            canZoom: access == .control, zoomCapabilities: zoomCapabilities)
    }
    public func frame(origin: RequestOrigin, after: Double) throws -> FramePacket {
        if origin == .automation && access == .manual { throw BridgeFailure("access_denied", "Simulated observation is not permitted") }
        counter += 1
        let base = directions.isEmpty && appliedZooms.isEmpty ? before : self.after
        var info = base.info
        info.id = "simulated-\(session):\(counter)"; info.sessionID = session
        info.deviceID = "simulated-evaluation"; info.timestampSource = "simulated_frame"
        info.receivedAt = Date(); info.receivedUptime = ProcessInfo.processInfo.systemUptime
        return FramePacket(pixelBuffer: base.pixelBuffer, info: info)
    }
    public func validateInteraction(_ stamp: InteractionStamp, origin: RequestOrigin) throws {
        guard stamp.epoch == epoch && stamp.sessionID == session && !stopped else { throw BridgeFailure("interaction_changed", "Simulated session or control changed") }
        if origin == .automation && access == .manual { throw BridgeFailure("access_denied", "Simulated access was revoked") }
    }
    public func move(direction: String, origin: RequestOrigin, interaction: InteractionStamp?) async throws -> MotionResult {
        guard access == .control && moveValidated && !stopped && ["left","right","up","down"].contains(direction) else { throw BridgeFailure("movement_denied", "Simulated movement is not permitted") }
        if let interaction { try validateInteraction(interaction, origin: origin) }
        let generation = epoch
        if moveDelay > 0 { try await Task.sleep(for: .seconds(moveDelay)) }
        guard generation == epoch && !stopped else { throw BridgeFailure("cancelled", "Simulated movement was cancelled") }
        try Task.checkCancellation()
        directions.append(direction)
        return MotionResult(accepted: true, completed: true, verified: true, verification: "simulation_only", target: nil, observed: nil, message: "Simulated step completed; this is not hardware evidence")
    }
    public func zoomCapabilitiesForObservation(interaction: InteractionStamp) async throws -> USBZoomCapabilities {
        try validateInteraction(interaction, origin: .automation)
        guard access == .control, let zoomCapabilities, ObservationZoomPolicy.isAvailable(zoomCapabilities) else {
            throw BridgeFailure("zoom_denied", "Simulated zoom is not permitted")
        }
        return zoomCapabilities
    }
    public func zoomForObservation(rawValue: Int, interaction: InteractionStamp) async throws -> USBZoomResult {
        var capabilities = try await zoomCapabilitiesForObservation(interaction: interaction)
        try ObservationZoomPolicy.validate(rawValue: rawValue, capabilities: capabilities)
        zoomRequests.append(rawValue)
        if zoomDelay > 0 { try await Task.sleep(for: .seconds(zoomDelay)) }
        try Task.checkCancellation()
        try validateInteraction(interaction, origin: .automation)
        guard access == .control else { throw BridgeFailure("zoom_denied", "Simulated zoom was revoked") }
        if zoomConfirmed { capabilities.current = rawValue; appliedZooms.append(rawValue); zoomCapabilities = capabilities }
        return USBZoomResult(target: rawValue, observed: capabilities.current, accepted: true,
            completed: zoomConfirmed, verified: zoomConfirmed, verification: "simulation_only",
            capabilities: capabilities, message: "Simulated zoom readback; not hardware or zoom-ratio evidence", toleranceRaw: 0)
    }
    public func stopIfInteractionCurrent(_ stamp: InteractionStamp) throws -> MotionResult? {
        guard stamp.epoch == epoch && stamp.sessionID == session else { return nil }
        epoch += 1; stopped = true
        return MotionResult(accepted: true, completed: true, verified: true, verification: "simulation_only", target: nil, observed: nil, message: "Simulation stopped")
    }
    public func setAccess(_ value: AccessMode) { epoch += 1; access = value }
    public func reconnect() { epoch += 1; session = UUID().uuidString; stopped = false }
    public func report() -> JSONValue { .object(["simulation": .bool(true), "directions": .array(directions.map(JSONValue.string)),
        "zoomRequests": .array(zoomRequests.map { .number(Double($0)) }), "appliedZooms": .array(appliedZooms.map { .number(Double($0)) }),
        "frames": .number(Double(counter)), "stopped": .bool(stopped)]) }
}
#endif
