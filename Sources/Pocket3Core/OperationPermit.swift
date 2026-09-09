import Foundation

/// A USB write may already be queued on another actor when Stop is requested.
/// The permit is checked under the same lock as the synchronous hardware call,
/// so invalidation fences queued writes before the hold command is sent.
public final class OperationPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    public init() {}
    var isValid: Bool { lock.withLock { valid } }
    public func invalidate() { lock.withLock { valid = false } }
    public func perform<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            try Task.checkCancellation()
            guard valid else { throw BridgeFailure("cancelled", "動作已取消，未送出控制指令") }
            return try operation()
        }
    }
}
public struct InteractionStamp: Codable, Sendable, Equatable {
    public let sessionID: String
    public let epoch: Int
    public init(sessionID: String, epoch: Int) { self.sessionID = sessionID; self.epoch = epoch }
}
