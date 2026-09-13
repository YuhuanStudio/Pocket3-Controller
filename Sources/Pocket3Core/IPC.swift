import Foundation
import Darwin

public enum BridgePaths {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pocket3Bridge", isDirectory: true)
    }
    public static var socket: String { directory.appendingPathComponent("bridge.sock").path }
    public static var token: URL { directory.appendingPathComponent("connection-token") }
    public static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
private enum SocketIO {
    static let maximumMessage = 16 * 1024 * 1024
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw BridgeFailure("ipc_path", "本機通訊路徑過長") }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
    static func configure(_ fd: Int32, timeout: Int = 20) {
        var one: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
    }
    static func read(_ fd: Int32) throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= maximumMessage {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw BridgeFailure("ipc_disconnected", "相機服務沒有回應，請確認 App 正在執行", retryable: true) }
            if let end = buffer.prefix(n).firstIndex(of: 10) {
                guard data.count + end <= maximumMessage else { throw BridgeFailure("ipc_size", "本機通訊訊息超過大小上限") }
                data.append(contentsOf: buffer[..<end]); return data
            }
            data.append(contentsOf: buffer.prefix(n))
        }
        throw BridgeFailure("ipc_size", "本機通訊訊息超過大小上限")
    }
    static func write(_ fd: Int32, data: Data) throws {
        guard data.count <= maximumMessage else { throw BridgeFailure("ipc_size", "圖片或訊息過大") }
        var bytes = data; bytes.append(10)
        try bytes.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: written), raw.count-written, MSG_NOSIGNAL)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw BridgeFailure("ipc_write", "本機連接已關閉") }
                written += n
            }
        }
    }
}

public final class IPCServer: @unchecked Sendable {
    private let lock = NSLock()
    private let address: IPCAddress
    private let registry = IPCRequestRegistry()
    private var fd: Int32 = -1
    private var lockFD: Int32 = -1
    private var generation = UUID()
    private var openClients = Set<Int32>()
    private let queue = DispatchQueue(label: "studio.yuhuan.pocket3.ipc", qos: .userInitiated)
    private let clients = DispatchQueue(label: "studio.yuhuan.pocket3.clients", qos: .userInitiated, attributes: .concurrent)
    private let connections = DispatchSemaphore(value: 16)
    private let workCapacity = DispatchSemaphore(value: 8)
    public init(address: IPCAddress = .default) { self.address = address }
    public func start(handler: @escaping @Sendable (ServiceRequest) async -> ServiceReply) throws {
        guard lock.withLock({ fd < 0 }) else { throw BridgeFailure("already_running", "服務已經啟動") }
        try address.prepare()
        let owner = open(address.directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard owner >= 0 else { throw BridgeFailure("ipc_lock", "無法建立本機服務鎖定") }
        guard flock(owner, LOCK_EX | LOCK_NB) == 0 else { close(owner); throw BridgeFailure("already_running", "另一個 \(Pocket3Product.displayName) 已在執行") }
        var started = false
        defer { if !started { flock(owner, LOCK_UN); close(owner) } }
        let credential = UUID().uuidString + UUID().uuidString
        try Data(credential.utf8).write(to: address.token, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: address.token.path)
        var addr = try SocketIO.address(address.socket)
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw BridgeFailure("ipc_socket", "無法建立本機相機服務") }
        unlink(address.socket)
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, listen(s, 16) == 0 else { close(s); throw BridgeFailure("ipc_bind", "無法啟動本機通訊") }
        chmod(address.socket, 0o600)
        let launch = UUID()
        lock.withLock { fd = s; lockFD = owner; generation = launch }
        started = true
        queue.async { [self] in
            while lock.withLock({ fd == s && generation == launch }) {
                let client = accept(s, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                guard connections.wait(timeout: .now()) == .success else { close(client); continue }
                lock.withLock { _ = openClients.insert(client) }
                SocketIO.configure(client)
                clients.async { [self] in
                    var occupiesWorkSlot = false
                    do {
                        var uid: uid_t = 0, gid: gid_t = 0
                        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { throw BridgeFailure("ipc_identity", "本機使用者不符") }
                        let request = try JSONDecoder().decode(ServiceRequest.self, from: SocketIO.read(client))
                        guard request.version == 1, request.token == credential else { throw BridgeFailure("ipc_auth", "本機連接憑證無效，請重新啟動 bridge") }
                        if request.operation == "cancel-request" {
                            guard let id = request.arguments["id"].string, UUID(uuidString: id) != nil else { throw BridgeFailure("invalid_request", "取消請求需要有效識別碼") }
                            registry.cancel(id)
                            try SocketIO.write(client, data: JSONEncoder().encode(ServiceReply(id: request.id, result: .object(["cancelled": .bool(true)]))))
                            finishClient(client); return
                        }
                        // Stop and cancellation remain available while ordinary
                        // work slots are occupied by slow model requests.
                        if request.operation != "stop" {
                            guard workCapacity.wait(timeout: .now()) == .success else { throw BridgeFailure("service_busy", "本機服務忙碌，請稍後再試", retryable: true) }
                            occupiesWorkSlot = true
                        }
                        let state = try registry.reserve(request.id)
                        let occupied = occupiesWorkSlot
                        let lifetime = IPCConnectionLifetime { [self] in
                            finishClient(client)
                            if occupied { workCapacity.signal() }
                        }
                        let monitor = DispatchSource.makeReadSource(fileDescriptor: client, queue: clients)
                        monitor.setEventHandler {
                            var byte: UInt8 = 0
                            let count = recv(client, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                            // One request per socket: EOF means its caller left;
                            // extra bytes after the request are not another job.
                            if count >= 0 { state.cancel(); monitor.cancel() }
                        }
                        monitor.setCancelHandler { lifetime.completeMonitoring() }
                        monitor.resume()
                        let task = Task { [self] in
                            let reply: ServiceReply
                            if state.isCancelled || Task.isCancelled { reply = ServiceReply(id: request.id, error: BridgeFailure("cancelled", "請求已取消")) }
                            else { reply = await handler(request) }
                            let finalReply = state.isCancelled ? ServiceReply(id: request.id, error: BridgeFailure("cancelled", "請求已取消")) : reply
                            if let data = try? JSONEncoder().encode(finalReply) { try? SocketIO.write(client, data: data) }
                            registry.finish(request.id, state: state)
                            lifetime.completeWork()
                            monitor.cancel()
                        }
                        state.attach(task)
                    } catch {
                        let failure = error as? BridgeFailure ?? BridgeFailure("invalid_request", "無效的本機請求")
                        if let data = try? JSONEncoder().encode(ServiceReply(id: "", error: failure)) { try? SocketIO.write(client, data: data) }
                        finishClient(client)
                        if occupiesWorkSlot { workCapacity.signal() }
                    }
                }
            }
        }
    }
    private func finishClient(_ client: Int32) {
        lock.withLock { _ = openClients.remove(client) }
        close(client); connections.signal()
    }
    public func stop() {
        registry.cancelAll()
        let descriptors = lock.withLock { () -> (Int32, Int32) in
            // Keep removal/close from recycling a descriptor while shutdown
            // walks the set of live connections.
            for client in openClients { shutdown(client, SHUT_RDWR) }
            let values = (fd, lockFD); fd = -1; lockFD = -1; generation = UUID(); return values
        }
        if descriptors.0 >= 0 { shutdown(descriptors.0, SHUT_RDWR); close(descriptors.0); unlink(address.socket); try? FileManager.default.removeItem(at: address.token) }
        if descriptors.1 >= 0 { flock(descriptors.1, LOCK_UN); close(descriptors.1) }
    }
    deinit { stop() }
}

public enum IPCClient {
    static func timeoutSeconds(for operation: String) -> Int {
        if ["cancel-request", "bridge-ping"].contains(operation) { return 2 }
        if ["ask", "detect", "evaluate-image", "evaluate-workflow", "evaluate-perception",
            "evaluate-grounding", "image-workspace", "validation-connect", "validation-manual-preset",
            "validation-wireless-read-settings",
            "move", BluetoothCameraEventRecordingRequest.operation,
            NativeActiveTrackObservationWindowRequest.operation,
            NativeActiveTrackObservationWindowLifecycleRequest.operation,
            HostHEVCValidationRequest.operation,
            HostHEVCProductStartRequest.startOperation,
            HostHEVCProductStartRequest.statusOperation,
            HostHEVCProductStartRequest.stopOperation,
            NativeCaptureFormatValidationRequest.operation].contains(operation) { return 120 }
        return 20
    }
    public static func call(_ operation: String, arguments: JSONValue = .object([:]), address: IPCAddress = .default, source: ServiceRequestSource? = nil) async throws -> ServiceReply {
        guard let token = try? String(contentsOf: address.token, encoding: .utf8) else { throw BridgeFailure("app_not_running", "請先開啟 \(Pocket3Product.displayName) App") }
        let request = ServiceRequest(token: token, operation: operation, arguments: arguments, source: source)
        let socketState = IPCCancellableSocket()
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { throw BridgeFailure("ipc_socket", "無法建立本機連接") }
            defer { socketState.remove(); close(s) }
            try socketState.install(s)
            SocketIO.configure(s, timeout: timeoutSeconds(for: operation))
            var addr = try SocketIO.address(address.socket)
            let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0 else { throw BridgeFailure("app_not_running", "\(Pocket3Product.displayName) App 尚未啟動或已退出") }
            try Task.checkCancellation()
            try SocketIO.write(s, data: JSONEncoder().encode(request))
            let reply = try JSONDecoder().decode(ServiceReply.self, from: SocketIO.read(s))
            if let error = reply.error { throw error }
            guard reply.id == request.id, reply.version == 1 else { throw BridgeFailure("ipc_protocol", "本機服務版本或回覆不符") }
            return reply
        }
        return try await withTaskCancellationHandler {
            do { return try await work.value }
            catch { if Task.isCancelled { throw CancellationError() }; throw error }
        } onCancel: {
            work.cancel(); socketState.cancel()
            if operation != "cancel-request" {
                Task.detached { _ = try? await call("cancel-request", arguments: .object(["id": .string(request.id)]), address: address) }
            }
        }
    }
}
