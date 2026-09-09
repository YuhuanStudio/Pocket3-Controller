import Foundation
import CoreGraphics
import Observation
import Pocket3Core
import YunDesign

/// Owns only manual focus-point requests. A white marker denotes the requested
/// device coordinate; neither an API return nor a stopped AF loop proves focus.
@MainActor @Observable final class CameraFocusModel {
    private(set) var capabilities: FocusCapabilities = .unavailable
    private(set) var requestedPoint: CameraFocusPoint?
    private(set) var pointSessionID: String?
    private(set) var lastResult: FocusResult?
    private(set) var isSettingPoint = false
    private(set) var message: String?
    var canFocus: Bool { capabilities.canFocus }
    var helpText: String {
        if canFocus { return loc("Click the preview to choose a focus point.") }
        if capabilities.sessionToken != nil { return loc("This camera connection does not expose point focus control.") }
        return loc("Connect the camera to choose a focus point.")
    }

    @ObservationIgnored private let readCapabilities: @Sendable () async -> FocusCapabilities
    @ObservationIgnored private let apply: @Sendable (CGPoint, CaptureLifecycleToken) async throws -> FocusResult
    @ObservationIgnored private let onMessage: @MainActor (String) -> Void
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var requestSurfaceID: UUID?
    @ObservationIgnored private var refreshID = UUID()

    convenience init(capture: CaptureEngine, onMessage: @escaping @MainActor (String) -> Void = { _ in }) {
        self.init(readCapabilities: { await capture.focusCapabilities() },
            apply: { point, token in try await capture.focus(at: point, sessionToken: token) }, onMessage: onMessage)
    }
    init(readCapabilities: @escaping @Sendable () async -> FocusCapabilities,
         apply: @escaping @Sendable (CGPoint, CaptureLifecycleToken) async throws -> FocusResult,
         onMessage: @escaping @MainActor (String) -> Void = { _ in }) {
        self.readCapabilities = readCapabilities; self.apply = apply; self.onMessage = onMessage
    }

    func refresh(capture stats: CaptureStats?, phase: String?) async {
        let update = UUID(); refreshID = update
        guard let stats, let frame = stats.frame, let age = stats.age, age.isFinite, age >= 0, age <= 1,
              ["ready", "moving", "stopping"].contains(phase ?? "") else {
            cancel(); capabilities = .unavailable; return
        }
        let next = await readCapabilities()
        guard refreshID == update else { return }
        guard next.sessionID == frame.sessionID, next.sessionToken?.deviceID == frame.deviceID else {
            cancel(); capabilities = .unavailable; return
        }
        if next.sessionToken != capabilities.sessionToken || !next.canFocus { cancel() }
        capabilities = next
    }

    /// Coalesces fast successive clicks. Tokens come from the displayed frame
    /// and current capabilities, so a stale preview cannot target a new input.
    @discardableResult
    func request(at point: CGPoint, previewSessionID: String, previewDeviceID: String, surfaceID: UUID? = nil) -> Bool {
        guard let token = capabilities.sessionToken, token.sessionID == previewSessionID,
              token.deviceID == previewDeviceID else {
            report(loc("The preview changed. Choose the focus point again.")); return false
        }
        guard canFocus else { report(loc("This camera connection does not expose point focus control.")); return false }
        let selected: CameraFocusPoint
        do { selected = try CameraFocusPoint(point) }
        catch { report(loc("Choose a focus point inside the image.")); return false }
        pending?.cancel()
        let id = UUID(); requestID = id; requestSurfaceID = surfaceID
        requestedPoint = selected; pointSessionID = token.sessionID
        lastResult = nil; message = nil; isSettingPoint = true
        let apply = self.apply
        pending = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(75))
                guard let self, self.requestID == id, self.capabilities.sessionToken == token,
                      self.canFocus, !Task.isCancelled else { return }
                let result = try await apply(selected.cgPoint, token)
                guard self.requestID == id, self.capabilities.sessionToken == token, !Task.isCancelled else { return }
                self.lastResult = result
                if !result.pointAndModeConfirmed { self.report(loc("The camera has not confirmed the selected focus point.")) }
                self.isSettingPoint = false; self.pending = nil
            } catch {
                guard let self, self.requestID == id else { return }
                self.isSettingPoint = false; self.pending = nil
                self.requestedPoint = nil; self.pointSessionID = nil
                if !(error is CancellationError) {
                    self.report(AppErrorPresentation.message(error, fallback: .focusUnconfirmed))
                }
            }
        }
        return true
    }

    /// Synchronous entry fence for Stop, pause, connect, and view teardown.
    /// Cancellation propagates to CaptureEngine's final-write permit.
    func cancel() {
        requestID = UUID(); refreshID = UUID()
        requestSurfaceID = nil
        pending?.cancel(); pending = nil; isSettingPoint = false
        requestedPoint = nil; pointSessionID = nil; lastResult = nil; message = nil
    }
    func cancel(surfaceID: UUID) {
        guard requestSurfaceID == surfaceID else { return }
        cancel()
    }
    private func report(_ text: String) { message = text; onMessage(text) }
    isolated deinit { pending?.cancel() }
}
