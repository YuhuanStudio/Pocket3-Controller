import Foundation

/// An active capture is user-requested work even when its window is hidden.
/// `userInitiated` prevents idle system sleep/App Nap, but does not include
/// `idleDisplaySleepDisabled`. Explicit sleep remains under macOS control.
/// No token is held merely because the App, IPC server, or model cache exists.
final class CaptureActivityLease: @unchecked Sendable {
    static let options: ProcessInfo.ActivityOptions = .userInitiated
    private let lock = NSLock()
    private let begin: @Sendable (ProcessInfo.ActivityOptions, String) -> any NSObjectProtocol
    private let end: @Sendable (any NSObjectProtocol) -> Void
    private var generation: UInt64?
    private var token: (any NSObjectProtocol)?

    init(begin: @escaping @Sendable (ProcessInfo.ActivityOptions, String) -> any NSObjectProtocol = {
        ProcessInfo.processInfo.beginActivity(options: $0, reason: $1)
    }, end: @escaping @Sendable (any NSObjectProtocol) -> Void = {
        ProcessInfo.processInfo.endActivity($0)
    }) {
        self.begin = begin; self.end = end
    }

    /// Called only after startRunning and the requested format checks succeed.
    func start(generation: UInt64) {
        lock.withLock {
            if self.generation != generation { release(); self.generation = generation }
            acquire()
        }
    }

    /// Notification names alone are not authoritative: a delayed old stop
    /// notification must not release a newly running capture's activity.
    func reconcile(generation: UInt64, isRunning: Bool, deviceConnected: Bool) {
        lock.withLock {
            guard self.generation == generation else { return }
            if isRunning && deviceConnected { acquire() }
            else { release() }
        }
    }

    func stop() {
        lock.withLock { generation = nil; release() }
    }

    private func acquire() {
        if token == nil { token = begin(Self.options, "Pocket 3 active camera capture") }
    }
    private func release() {
        guard let previous = token else { return }
        token = nil
        end(previous)
    }
    deinit { stop() }
}
