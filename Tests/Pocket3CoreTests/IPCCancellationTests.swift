import Foundation
import Darwin
import Testing
@testable import Pocket3Core

private actor RequestsSeen {
    var started = Set<String>()
    var cancelled = Set<String>()
    func run(_ request: ServiceRequest) async -> ServiceReply {
        started.insert(request.id)
        if request.operation == "stop" { return ServiceReply(id: request.id, result: .bool(true)) }
        do { try await Task.sleep(for: .seconds(5)); return ServiceReply(id: request.id, result: .bool(true)) }
        catch { cancelled.insert(request.id); return ServiceReply(id: request.id, error: BridgeFailure("cancelled", "cancelled")) }
    }
    func counts() -> (Int, Int) { (started.count, cancelled.count) }
}
private func address() -> IPCAddress { IPCAddress(directory: URL(fileURLWithPath: "/tmp/p3-" + String(UUID().uuidString.prefix(8)))) }

@Test func cancelledClientCancelsItsServerWork() async throws {
    let address = address(), server = IPCServer(address: address), seen = RequestsSeen()
    defer { server.stop(); try? FileManager.default.removeItem(at: address.directory) }
    try server.start { await seen.run($0) }
    let task = Task { try await IPCClient.call("slow", address: address) }
    for _ in 0..<100 { if await seen.counts().0 == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled client returned success") } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
    for _ in 0..<100 { if await seen.counts().1 == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await seen.counts().1 == 1)
}
@Test func stopBypassesOccupiedWorkSlots() async throws {
    let address = address(), server = IPCServer(address: address), seen = RequestsSeen()
    defer { server.stop(); try? FileManager.default.removeItem(at: address.directory) }
    try server.start { await seen.run($0) }
    let work = (0..<8).map { _ in Task { try await IPCClient.call("slow", address: address) } }
    for _ in 0..<100 { if await seen.counts().0 == 8 { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await seen.counts().0 == 8)
    let start = ContinuousClock.now
    let reply = try await IPCClient.call("stop", address: address)
    #expect(reply.result == .bool(true))
    #expect(start.duration(to: .now) < .seconds(1))
    for task in work { task.cancel(); _ = try? await task.value }
}
@Test func cancellationCanArriveBeforeTheOriginalRequestIsRegistered() {
    let registry = IPCRequestRegistry(), id = UUID().uuidString
    registry.cancel(id)
    let state = try! registry.reserve(id)
    #expect(state.isCancelled)
    registry.finish(id, state: state)
}
@Test func aConnectionClosesOnlyAfterItsWriterAndMonitorFinish() {
    let counter = CloseCounter()
    let lifetime = IPCConnectionLifetime { counter.increment() }
    lifetime.completeMonitoring()
    #expect(counter.value == 0)
    lifetime.completeWork(); lifetime.completeMonitoring(); lifetime.completeWork()
    #expect(counter.value == 1)
}
private final class CloseCounter: @unchecked Sendable {
    let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@Test func peerDisconnectCancelsWithoutAnExplicitCancelMessage() async throws {
    let address = address(), server = IPCServer(address: address), seen = RequestsSeen()
    defer { server.stop(); try? FileManager.default.removeItem(at: address.directory) }
    try server.start { await seen.run($0) }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(descriptor >= 0)
    var socketAddress = sockaddr_un(); socketAddress.sun_family = sa_family_t(AF_UNIX)
    socketAddress.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let path = Array(address.socket.utf8) + [0]
    withUnsafeMutableBytes(of: &socketAddress.sun_path) { $0.copyBytes(from: path) }
    let connected = withUnsafePointer(to: &socketAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    #expect(connected == 0)
    let token = try String(contentsOf: address.token, encoding: .utf8)
    var data = try JSONEncoder().encode(ServiceRequest(token: token, operation: "slow")); data.append(10)
    let sent = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!, $0.count, MSG_NOSIGNAL) }
    #expect(sent == data.count, "Unable to send test request; errno \(errno)")
    for _ in 0..<100 { if await seen.counts().0 == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
    Darwin.close(descriptor)
    for _ in 0..<100 { if await seen.counts().1 == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await seen.counts().1 == 1)
}
@Test func aSecondServerCannotReplaceTheActiveCredential() async throws {
    let address = address(), first = IPCServer(address: address), second = IPCServer(address: address)
    defer { second.stop(); first.stop(); try? FileManager.default.removeItem(at: address.directory) }
    try first.start { ServiceReply(id: $0.id, result: .bool(true)) }
    let token = try Data(contentsOf: address.token)
    #expect(throws: BridgeFailure.self) { try second.start { ServiceReply(id: $0.id, result: .bool(false)) } }
    second.stop()
    #expect(try Data(contentsOf: address.token) == token)
    #expect(try await IPCClient.call("status", address: address).result == .bool(true))
}
