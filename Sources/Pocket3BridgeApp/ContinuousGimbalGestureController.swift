import AppKit
import Foundation
import Observation
import Pocket3Core
import YunDesign

enum ContinuousGimbalAvailability: Equatable {
    case disconnected, unsupported, ready
    case blocked(String)
    var message: String? {
        switch self {
        case .ready: nil
        case .disconnected: loc("Connect the camera to use continuous control.")
        case .unsupported: loc("Continuous control is unavailable for this connection.")
        case .blocked(let message): message
        }
    }
}
struct ContinuousGimbalInput: Equatable, Sendable {
    let x: Double
    let y: Double
    static let center = Self(x: 0, y: 0)
    func clamped() -> Self? {
        guard x.isFinite, y.isFinite else { return nil }
        let scale = max(1, max(abs(x), abs(y)))
        let horizontal = x / scale, vertical = y / scale
        let length = max(1, hypot(horizontal, vertical))
        return Self(x: horizontal / length, y: vertical / length)
    }
}

/// Owns one UI gesture and its exact Core lease. No absolute UVC nudges or
/// synthetic camera animation are used. AppModel supplies the selected USB or
/// native scheduler/binding and its AI-to-manual authorization closures.
@MainActor @Observable final class ContinuousGimbalGestureController {
    private struct Endpoint: Sendable {
        let scheduler: ContinuousGimbalScheduler
        let binding: ContinuousGimbalBinding
    }
    private struct Owner: Sendable {
        let scheduler: ContinuousGimbalScheduler
        let lease: ContinuousGimbalLease
    }
    private(set) var availability: ContinuousGimbalAvailability = .disconnected
    private(set) var speed = 1.0
    private(set) var input = ContinuousGimbalInput.center
    private(set) var gestureID: UUID?
    private(set) var isStarting = false
    private(set) var isHolding = false
    private(set) var isStopping = false
    private(set) var lastError: String?
    private(set) var lastStop: ContinuousGimbalStopResult?
    var canInteract: Bool { availability == .ready && endpoint != nil && !isStopping && failedNeutralBinding != endpoint?.binding }
    var canStop: Bool { gestureID != nil || isStarting || isHolding || isStopping }

    @ObservationIgnored private var endpoint: Endpoint?
    @ObservationIgnored private var configurationID = UUID()
    @ObservationIgnored private var prepare: @MainActor () async throws -> Void = {}
    @ObservationIgnored private var authorize: @MainActor () async throws -> UUID? = { nil }
    @ObservationIgnored private var owner: Owner?
    @ObservationIgnored private var gestureSurfaceID: UUID?
    @ObservationIgnored private var failedNeutralBinding: ContinuousGimbalBinding?
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var eventMonitors: ContinuousGimbalEventMonitors?
    @ObservationIgnored private let monitorsEnabled: Bool

    init(monitorsEnabled: Bool = true) { self.monitorsEnabled = monitorsEnabled }

    func configure(scheduler: ContinuousGimbalScheduler?, binding: ContinuousGimbalBinding?,
                   availability: ContinuousGimbalAvailability,
                   authorize: @escaping @MainActor () async throws -> UUID? = { nil },
                   prepare: @escaping @MainActor () async throws -> Void = {}) {
        let changed = endpoint?.scheduler !== scheduler || endpoint?.binding != binding
        if changed || availability != .ready {
            _ = finishCurrent(reason: .cancelled)
            configurationID = UUID()
        }
        self.availability = availability
        self.prepare = prepare
        self.authorize = authorize
        if let scheduler, let binding { endpoint = Endpoint(scheduler: scheduler, binding: binding) }
        else { endpoint = nil }
        if failedNeutralBinding != binding { failedNeutralBinding = nil }
    }

    func setSpeed(_ value: Double) {
        guard value.isFinite else { lastError = loc("Invalid control input."); _ = finishCurrent(reason: .invalidInput); return }
        speed = max(0, min(1, value))
    }

    @discardableResult
    func beginGesture(id: UUID, input requested: ContinuousGimbalInput, window: NSWindow? = nil, surfaceID: UUID? = nil) -> Bool {
        guard canInteract, let endpoint, let requested = requested.clamped() else { return false }
        let priorOwner = owner, previous = transition, configuration = configurationID, prepare = self.prepare, authorize = self.authorize
        previous?.cancel(); heartbeat?.cancel(); heartbeat = nil
        owner = nil; gestureID = id; gestureSurfaceID = surfaceID; input = requested
        isStarting = true; isHolding = false; isStopping = false; lastError = nil
        eventMonitors?.invalidate()
        if monitorsEnabled {
            eventMonitors = ContinuousGimbalEventMonitors(window: window) { [weak self] reason in
                self?.endGesture(id: id, reason: reason)
            }
        }
        transition = Task { @MainActor [weak self] in
            await previous?.value
            if let priorOwner {
                let result = await priorOwner.scheduler.stop(priorOwner.lease, reason: .cancelled)
                self?.recordStop(result)
                if result.matchedLease && !result.neutralSent && priorOwner.lease.binding == endpoint.binding {
                    guard let self, self.matches(id, configuration) else { return }
                    self.failGesture(id, message: loc("Stop could not be sent. Reconnect camera control."))
                    return
                }
            }
            guard let self, self.matches(id, configuration), !Task.isCancelled else { return }
            guard self.failedNeutralBinding != endpoint.binding else {
                self.failGesture(id, message: loc("Stop could not be sent. Reconnect camera control.")); return
            }
            do {
                try await prepare()
                guard self.matches(id, configuration), !Task.isCancelled else { return }
                let authorizationID = try await authorize()
                guard self.matches(id, configuration), !Task.isCancelled else { return }
                let lease = try await endpoint.scheduler.begin(binding: endpoint.binding,
                    x: self.input.x, y: self.input.y, speed: self.speed, authorizationID: authorizationID)
                guard self.matches(id, configuration), !Task.isCancelled else {
                    self.recordStop(await endpoint.scheduler.stop(lease, reason: .cancelled))
                    return
                }
                self.owner = Owner(scheduler: endpoint.scheduler, lease: lease)
                self.isStarting = false; self.isHolding = true
                self.heartbeat = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                        guard let self, self.matches(id, configuration) else { return }
                        await self.renewGesture(id, configuration: configuration)
                    }
                }
            } catch {
                guard self.matches(id, configuration) else { return }
                self.failGesture(id, message: self.message(for: error))
            }
        }
        return true
    }

    func updateGesture(id: UUID, input requested: ContinuousGimbalInput) {
        guard gestureID == id else { return }
        guard let requested = requested.clamped() else {
            lastError = loc("Invalid control input."); endGesture(id: id, reason: .invalidInput); return
        }
        input = requested
    }

    func endGesture(id: UUID, reason: ContinuousGimbalStopReason = .released) {
        guard gestureID == id else { return }
        _ = finishCurrent(reason: reason)
    }

    func endSurface(_ id: UUID) {
        guard gestureSurfaceID == id, let gestureID else { return }
        endGesture(id: gestureID, reason: .focusLost)
    }

    /// Global Stop/Pause/Quit integration. Old view callbacks must instead use
    /// endGesture(id:) so they cannot stop a newer input interaction.
    @discardableResult
    func stop(reason: ContinuousGimbalStopReason = .cancelled) async -> ContinuousGimbalStopResult? {
        let stopping = finishCurrent(reason: reason)
        await stopping?.value
        return lastStop
    }

    private func matches(_ id: UUID, _ configuration: UUID) -> Bool {
        gestureID == id && configurationID == configuration && availability == .ready
    }

    private func renewGesture(_ id: UUID, configuration: UUID) async {
        guard matches(id, configuration), let owner else { return }
        do { try await owner.scheduler.renew(owner.lease, x: input.x, y: input.y, speed: speed) }
        catch {
            guard matches(id, configuration) else { return }
            lastError = message(for: error)
            endGesture(id: id, reason: .cancelled)
        }
    }

    private func finishCurrent(reason: ContinuousGimbalStopReason) -> Task<Void, Never>? {
        guard gestureID != nil || owner != nil || isStarting else { return transition }
        let previous = transition, previousOwner = owner
        previous?.cancel(); heartbeat?.cancel(); heartbeat = nil
        gestureID = nil; gestureSurfaceID = nil; owner = nil; input = .center
        isStarting = false; isHolding = false; isStopping = true
        eventMonitors?.invalidate(); eventMonitors = nil
        let task = Task { @MainActor [weak self] in
            // An in-progress begin owns its own cancellation cleanup. Joining
            // it ensures a newly acquired but already-released lease is neutral.
            await previous?.value
            var result: ContinuousGimbalStopResult?
            if let previousOwner { result = await previousOwner.scheduler.stop(previousOwner.lease, reason: reason) }
            if let result { self?.recordStop(result) }
            guard let self, self.gestureID == nil else { return }
            self.isStopping = false
        }
        transition = task
        return task
    }

    private func recordStop(_ result: ContinuousGimbalStopResult) {
        lastStop = result
        if result.matchedLease && !result.neutralSent && endpoint?.binding == result.lease.binding {
            failedNeutralBinding = result.lease.binding
            lastError = AppErrorPresentation.message(code: "stop_unverified", details: result.failure)
        }
    }

    private func failGesture(_ id: UUID, message: String) {
        guard gestureID == id else { return }
        gestureID = nil; gestureSurfaceID = nil; input = .center; isStarting = false; isHolding = false
        eventMonitors?.invalidate(); eventMonitors = nil
        lastError = message
    }

    private func message(for error: Error) -> String {
        AppErrorPresentation.message(error, fallback: .controlUnavailable)
    }

    isolated deinit {
        heartbeat?.cancel(); transition?.cancel(); eventMonitors?.invalidate()
        if let owner {
            Task { _ = await owner.scheduler.stop(owner.lease, reason: .cancelled) }
        }
    }
}

@MainActor private final class ContinuousGimbalEventMonitors {
    private var local: Any?
    private var global: Any?
    private var notifications: [NSObjectProtocol] = []

    init(window: NSWindow?, end: @escaping @MainActor (ContinuousGimbalStopReason) -> Void) {
        local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { event in
            if event.type == .leftMouseUp || (event.type == .keyDown && event.keyCode == 53) {
                let reason: ContinuousGimbalStopReason = event.type == .leftMouseUp ? .released : .cancelled
                Task { @MainActor in end(reason) }
            }
            return event
        }
        // Observe mouse-up outside our window; never monitor global keys.
        global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            Task { @MainActor in end(.released) }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in end(.focusLost) }
        })
        if let window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                notifications.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    Task { @MainActor in end(.focusLost) }
                })
            }
        }
    }
    func invalidate() {
        if let local { NSEvent.removeMonitor(local); self.local = nil }
        if let global { NSEvent.removeMonitor(global); self.global = nil }
        notifications.forEach { NotificationCenter.default.removeObserver($0) }; notifications = []
    }
    isolated deinit { invalidate() }
}
