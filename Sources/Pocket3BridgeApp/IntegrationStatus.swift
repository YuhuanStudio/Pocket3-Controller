import Foundation
import Pocket3Core

/// Counts dispatched tool work, not sockets or persistent MCP client sessions.
struct MCPRequestHistory {
    enum Outcome: Equatable { case active, succeeded, failed, cancelled }
    struct Entry: Identifiable {
        let id: String
        let tool: String
        let startedAt: Date
        var outcome: Outcome
    }
    private var active: [String: Entry] = [:]
    private var completed: [Entry] = []
    var activeCount: Int { active.count }
    var recent: [Entry] { (Array(active.values) + completed).sorted { $0.startedAt > $1.startedAt } }

    mutating func begin(_ request: ServiceRequest, at date: Date = Date()) {
        let tools = ["status": "camera_status", "snapshot": "capture_frame", "move": "move_gimbal", "stop": "stop_gimbal",
                     "zoom-status": "camera_zoom_status", "zoom": "camera_set_zoom"]
        guard request.source == .mcp, let tool = tools[request.operation],
              request.id.utf8.count == 36, UUID(uuidString: request.id) != nil,
              active[request.id] == nil else { return }
        // Authenticated IPC admits at most 16 simultaneous connections. Keep
        // this independent bound as well; never retain arbitrary arguments.
        guard active.count < 16 else { return }
        active[request.id] = Entry(id: request.id, tool: tool, startedAt: date, outcome: .active)
    }
    mutating func finish(_ id: String, failed: Bool, cancelled: Bool) {
        guard var entry = active.removeValue(forKey: id) else { return }
        entry.outcome = cancelled ? .cancelled : failed ? .failed : .succeeded
        completed.insert(entry, at: 0)
        if completed.count > 20 { completed.removeLast(completed.count - 20) }
    }
}

enum LocalBridgeProbe {
    static func reply(to request: ServiceRequest) throws -> ServiceReply {
        guard let nonce = request.arguments["nonce"].string, UUID(uuidString: nonce) != nil else {
            throw BridgeFailure("invalid_probe", "Local connection check requires a valid nonce")
        }
        return ServiceReply(id: request.id, result: .object(["service": .string("pocket3-mcp"), "nonce": .string(nonce)]))
    }
    static func validate(_ reply: ServiceReply, nonce: String) throws {
        guard reply.error == nil, reply.version == 1,
              reply.result?["service"].string == "pocket3-mcp", reply.result?["nonce"].string == nonce else {
            throw BridgeFailure("invalid_probe_reply", "Local connection check returned an unexpected response")
        }
    }
}

extension AppModel {
    func performMCPRequest(_ request: ServiceRequest) async -> ServiceReply {
        mcpRequests.begin(request)
        let reply = await service.handle(request)
        mcpRequests.finish(request.id, failed: reply.error != nil, cancelled: Task.isCancelled)
        return reply
    }
    func testBridgeConnection() async {
        guard !testingBridgeConnection else { return }
        testingBridgeConnection = true; bridgeConnectionCheckedAt = nil; bridgeConnectionError = nil
        defer { testingBridgeConnection = false }
        do {
            let nonce = UUID().uuidString
            let reply = try await IPCClient.call("bridge-ping", arguments: .object(["nonce": .string(nonce)]))
            try LocalBridgeProbe.validate(reply, nonce: nonce)
            bridgeConnectionCheckedAt = Date()
        } catch { bridgeConnectionError = AppErrorPresentation.message(error, fallback: .bridge) }
    }
}
