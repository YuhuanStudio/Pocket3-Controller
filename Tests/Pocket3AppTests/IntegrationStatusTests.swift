import Foundation
import Pocket3Core
import Testing
@testable import Pocket3BridgeApp

@Suite("Local integration status") struct IntegrationStatusTests {
    @Test func olderRequestsRemainCompatibleAndMCPSourceIsOptional() throws {
        let legacy = ServiceRequest(token: "test", operation: "status")
        let decoded = try JSONDecoder().decode(ServiceRequest.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.source == nil)
        let mcp = ServiceRequest(token: "test", operation: "status", source: .mcp)
        #expect(try JSONDecoder().decode(ServiceRequest.self, from: JSONEncoder().encode(mcp)).source == .mcp)
    }

    @Test func requestCountDoesNotClaimIdleClientsOrCountRegularCLIRequests() {
        var history = MCPRequestHistory()
        let ordinary = ServiceRequest(token: "test", operation: "status")
        history.begin(ordinary)
        history.begin(ServiceRequest(token: "test", operation: "ask", source: .mcp))
        var invalidID = ServiceRequest(token: "test", operation: "status", source: .mcp)
        invalidID.id = String(repeating: "unbounded caller text", count: 100)
        history.begin(invalidID)
        #expect(history.recent.isEmpty)
        let request = ServiceRequest(token: "test", operation: "snapshot", arguments: .object(["privateValue": .string("not retained")]), source: .mcp)
        history.begin(request)
        #expect(history.activeCount == 1)
        #expect(history.recent.first?.tool == "capture_frame")
        history.finish(request.id, failed: false, cancelled: false)
        #expect(history.activeCount == 0)
        #expect(history.recent.first?.outcome == .succeeded)
        history.finish(request.id, failed: true, cancelled: true)
        #expect(history.recent.count == 1)
        #expect(history.recent.first?.outcome == .succeeded)
    }

    @Test func retainedHistoryIsBoundedWithoutEvictingActiveWork() {
        var history = MCPRequestHistory()
        let pending = ServiceRequest(token: "test", operation: "move", source: .mcp)
        history.begin(pending)
        for index in 0..<25 {
            let request = ServiceRequest(token: "test", operation: "status", source: .mcp)
            history.begin(request)
            history.finish(request.id, failed: index == 24, cancelled: false)
        }
        #expect(history.activeCount == 1)
        #expect(history.recent.count == 21)
        #expect(history.recent.contains { $0.id == pending.id })
        #expect(history.recent.contains { $0.outcome == .failed })
        history.finish(pending.id, failed: true, cancelled: true)
        #expect(history.activeCount == 0)
        #expect(history.recent.count == 20)
        #expect(history.recent.first { $0.id == pending.id }?.outcome == .cancelled)
    }

    @Test func probeRejectsInvalidOrReplayedResponses() throws {
        let nonce = UUID().uuidString
        let reply = try LocalBridgeProbe.reply(to: ServiceRequest(token: "test", operation: "bridge-ping", arguments: .object(["nonce": .string(nonce)])))
        try LocalBridgeProbe.validate(reply, nonce: nonce)
        #expect(throws: BridgeFailure.self) { try LocalBridgeProbe.validate(reply, nonce: UUID().uuidString) }
        #expect(throws: BridgeFailure.self) { try LocalBridgeProbe.reply(to: ServiceRequest(token: "test", operation: "bridge-ping")) }
        #expect(throws: BridgeFailure.self) { try LocalBridgeProbe.validate(ServiceReply(id: "other", result: .object(["nonce": .string(nonce)])), nonce: nonce) }
    }

    @Test func localProbeUsesTheAuthenticatedSocketWithoutCameraService() async throws {
        let address = IPCAddress(directory: URL(fileURLWithPath: "/tmp/p3-probe-" + String(UUID().uuidString.prefix(8))))
        let server = IPCServer(address: address)
        defer { server.stop(); try? FileManager.default.removeItem(at: address.directory) }
        try server.start { request in
            do { return try LocalBridgeProbe.reply(to: request) }
            catch { return ServiceReply(id: request.id, error: BridgeFailure("invalid_probe", "Invalid test probe")) }
        }
        let nonce = UUID().uuidString
        let reply = try await IPCClient.call("bridge-ping", arguments: .object(["nonce": .string(nonce)]), address: address)
        try LocalBridgeProbe.validate(reply, nonce: nonce)
    }
}
