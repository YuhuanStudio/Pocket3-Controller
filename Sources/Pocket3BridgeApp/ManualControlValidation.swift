import AppKit
import Pocket3Core
import YunDesign

@MainActor private var manualValidationRunning = false

extension AppModel {
    /// Exercises the actual AppKit input surface of this App. It does not
    /// synthesize global input or grant movement to ordinary remote clients.
    func handleManualControlValidation(_ request: ServiceRequest) async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation"), !manualValidationRunning else {
            throw BridgeFailure("validation_disabled", "Manual control validation requires an idle development launch")
        }
        let kind = request.arguments["gesture"].string ?? "button"
        let ending = request.arguments["ending"].string ?? "release"
        guard ["button", "drag", "near", "far"].contains(kind), ["release", "focus", "stop", "remote"].contains(ending) else {
            throw BridgeFailure("validation_input", "Use button/drag/near/far and release/focus/stop/remote")
        }
        manualValidationRunning = true
        defer { manualValidationRunning = false }
        openMainWindow?(); selectedPage = "camera"
        await refresh()
        guard continuousGimbal.canInteract else { throw BridgeFailure("manual_control_disabled", "The actual manual control is disabled") }
        guard let window = NSApp.windows.first(where: { $0.title == Pocket3Product.displayName }), let root = window.contentView else {
            throw BridgeFailure("window_missing", "Open Pocket 3 Controller first")
        }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        root.layoutSubtreeIfNeeded()
        let label = loc(kind == "button" ? "Hold to move right" : "Drag to move the camera")
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityLabel() == label && String(describing: type(of: view)).contains("TrackingView") { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let surface = find(root), surface.window === window,
              surface.isAccessibilityEnabled(), !surface.isHiddenOrHasHiddenAncestor,
              surface.bounds.width > 10, surface.bounds.height > 10 else {
            throw BridgeFailure("control_surface_missing", "No enabled manual input surface is visible")
        }
        let oldSpeed = continuousGimbal.speed
        continuousGimbal.setSpeed(1)
        defer { continuousGimbal.setSpeed(oldSpeed) }
        let before = await service.status()
        let displacement: Double = kind == "near" ? 8 : kind == "far" ? 40 : kind == "drag" ? 32 : 0
        let localStart = CGPoint(x: surface.bounds.midX + displacement, y: surface.bounds.midY)
        func event(_ type: NSEvent.EventType, local: CGPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: surface.convert(local, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
                throw BridgeFailure("event_failed", "Unable to create AppKit validation event")
            }
            return event
        }
        var observations: [JSONValue] = []
        var failure: String?
        var held = false
        var releaseElapsed: Double?
        let started = ProcessInfo.processInfo.systemUptime
        do {
            window.sendEvent(try event(.leftMouseDown, local: localStart))
            for _ in 0..<150 {
                if continuousGimbal.isHolding { held = true; break }
                if continuousGimbal.lastError != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard held else { throw BridgeFailure("manual_begin_failed", continuousGimbal.lastError ?? "The button did not begin a gesture") }
            for tick in 0..<6 {
                try await Task.sleep(for: .milliseconds(100))
                if kind == "drag", tick == 2 {
                    window.sendEvent(try event(.leftMouseDragged,
                        local: CGPoint(x: surface.bounds.midX, y: surface.bounds.midY - 32)))
                }
                let state = await service.status()
                observations.append(.object(["elapsed": .number(ProcessInfo.processInfo.systemUptime - started),
                    "holding": .bool(continuousGimbal.isHolding), "motionActive": .bool(state.motionActive),
                    "inputX": .number(continuousGimbal.input.x), "inputY": .number(continuousGimbal.input.y),
                    "phase": .string(state.phase), "frameAge": state.capture.age.map(JSONValue.number) ?? .null]))
            }
            let released = ProcessInfo.processInfo.systemUptime
            if ending == "focus" { _ = window.makeFirstResponder(nil) }
            else if ending == "stop" { await stop() }
            else if ending == "remote" { _ = try await service.stop() }
            else { window.sendEvent(try event(.leftMouseUp, local: localStart)) }
            for _ in 0..<200 {
                if !continuousGimbal.canStop { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            releaseElapsed = ProcessInfo.processInfo.systemUptime - released
        } catch { failure = (error as? BridgeFailure)?.code ?? "manual_validation_failed" }
        // Both success and failure clean the actual surface's matching gesture.
        // Cancellation cleanup is independent inside the scheduler/transport.
        if let up = try? event(.leftMouseUp, local: localStart) { window.sendEvent(up) }
        _ = await continuousGimbal.stop(reason: .cancelled)
        let after = await service.status()
        let stopResult = continuousGimbal.lastStop
        let passed = failure == nil && held && observations.allSatisfy { $0["holding"].bool == true && $0["motionActive"].bool == true }
            && stopResult?.neutralSent == true && !after.motionActive && after.phase == "ready"
        return ServiceReply(id: request.id, result: .object([
            "passed": .bool(passed), "gesture": .string(kind), "ending": .string(ending),
            "method": .string("NSWindow.sendEvent through the visible AppKit input surface; no global input synthesis"),
            "surfaceEnabled": .bool(surface.isAccessibilityEnabled()), "beganHolding": .bool(held),
            "before": try .encode(before.gimbal), "after": try .encode(after.gimbal),
            "observations": .array(observations), "stop": try .encode(stopResult),
            "releaseToCleanupSeconds": releaseElapsed.map(JSONValue.number) ?? .null,
            "failure": failure.map(JSONValue.string) ?? .null,
            "physicalStopLatencyVerified": .bool(false)]))
    }
}
