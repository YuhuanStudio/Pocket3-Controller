import Foundation
import Darwin

public struct IPCAddress: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public static var `default`: Self { .init(directory: BridgePaths.directory) }
    var token: URL { directory.appendingPathComponent("connection-token") }
    var socket: String { directory.appendingPathComponent("bridge.sock").path }
    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
final class IPCRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: Task<Void, Never>?
    var isCancelled: Bool { lock.withLock { cancelled } }
    func attach(_ task: Task<Void, Never>) { lock.withLock { self.task = task; if cancelled { task.cancel() } } }
    func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
    func finish() { lock.withLock { task = nil } }
}
final class IPCRequestRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String: IPCRequestState] = [:]
    private var cancelled: [String: Double] = [:]
    func reserve(_ id: String) throws -> IPCRequestState {
        try lock.withLock {
            guard requests[id] == nil else { throw BridgeFailure("duplicate_request", "此請求識別碼正在使用中") }
            let cutoff = ProcessInfo.processInfo.systemUptime - 60
            cancelled = cancelled.filter { $0.value >= cutoff }
            let state = IPCRequestState()
            if cancelled[id] != nil { state.cancel() }
            requests[id] = state
            return state
        }
    }
    func cancel(_ id: String) {
        lock.withLock {
            if cancelled.count >= 512, let oldest = cancelled.min(by: { $0.value < $1.value })?.key { cancelled.removeValue(forKey: oldest) }
            cancelled[id] = ProcessInfo.processInfo.systemUptime
            requests[id]?.cancel()
        }
    }
    func finish(_ id: String, state: IPCRequestState) {
        lock.withLock {
            if requests[id] === state { requests.removeValue(forKey: id) }
            state.finish()
        }
    }
    func cancelAll() { lock.withLock { for state in requests.values { state.cancel() } } }
}
final class IPCCancellableSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false
    func install(_ descriptor: Int32) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            fd = descriptor
        }
    }
    func remove() { lock.withLock { fd = -1 } }
    func cancel() { lock.withLock { cancelled = true; if fd >= 0 { shutdown(fd, SHUT_RDWR) } } }
}

/// The descriptor cannot be recycled until both its reader monitor and reply
/// writer have ended. Closing on EOF alone can redirect a late write to a new fd.
final class IPCConnectionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var monitoringEnded = false
    private var workEnded = false
    private var close: (@Sendable () -> Void)?
    init(close: @escaping @Sendable () -> Void) { self.close = close }
    func completeMonitoring() { finish(monitoring: true) }
    func completeWork() { finish(monitoring: false) }
    private func finish(monitoring: Bool) {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            if monitoring { monitoringEnded = true } else { workEnded = true }
            guard monitoringEnded && workEnded else { return nil }
            let action = close; close = nil; return action
        }
        action?()
    }
}
