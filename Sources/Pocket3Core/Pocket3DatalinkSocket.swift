import Foundation
import Darwin

/// Internal injection boundary for deterministic tests. Implementations are
/// used exclusively by the datalink I/O queue; now must be thread-safe.
protocol Pocket3DatalinkIO: AnyObject, Sendable {
    var now: TimeInterval { get }
    var isOpen: Bool { get }
    func tcpPoke(_ frame: Data, permit: OperationPermit) throws
    func openUDP() throws
    func send(_ packet: Data) throws
    func receive(timeoutMS: Int) throws -> [Data]
    func close()
}

final class Pocket3DatalinkSocket: Pocket3DatalinkIO, @unchecked Sendable {
    private var udp: Int32 = -1
    private let configuration: Pocket3DatalinkSocketConfiguration
    private let routePlan: Pocket3DatalinkRoutePlan?
    private let optionApplier: any Pocket3DatalinkSocketOptionApplying
    private var resolvedInterfaceIndex: UInt32?

    init(configuration: Pocket3DatalinkSocketConfiguration = .legacy,
         routePlan: Pocket3DatalinkRoutePlan? = nil,
         optionApplier: any Pocket3DatalinkSocketOptionApplying = DarwinPocket3DatalinkSocketOptionApplier()) {
        self.configuration = configuration
        self.routePlan = routePlan
        self.optionApplier = optionApplier
    }

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var isOpen: Bool { udp >= 0 }
    private func address(port: UInt16) throws -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); value.sin_family = sa_family_t(AF_INET)
        value.sin_port = port.bigEndian
        guard inet_pton(AF_INET, configuration.cameraHost, &value.sin_addr) == 1 else { throw failure("native_address") }
        return value
    }
    private func failure(_ code: String) -> BridgeFailure { BridgeFailure(code, "Pocket 3 無線通訊失敗（\(code)）") }
    private func validateRoute() throws {
        guard configuration.isInterfaceBound else { return }
        guard let routePlan,
              routePlan.configuration == configuration,
              routePlan.allowed,
              let index = routePlan.boundInterfaceIndex, index != 0 else {
            throw failure(routePlan?.failureCode ?? "native_route_unvalidated")
        }
        resolvedInterfaceIndex = index
    }
    private func socket(_ type: Int32) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, type, 0)
        guard descriptor >= 0 else { throw failure("native_socket") }
        do {
            if let index = resolvedInterfaceIndex {
                try optionApplier.apply(.bindIPv4Interface(index: index), descriptor: descriptor)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor); throw failure("native_nonblocking")
        }
        var one: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        return descriptor
    }
    private func connect(_ descriptor: Int32, port: UInt16) throws -> Int32 {
        var destination = try address(port: port)
        return withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
    func tcpPoke(_ frame: Data, permit: OperationPermit) throws {
        try validateRoute()
        let tcp = try socket(SOCK_STREAM); defer { Darwin.close(tcp) }
        let result = try connect(tcp, port: 7001)
        if result != 0 {
            guard errno == EINPROGRESS else { throw failure("native_tcp_connect") }
            let deadline = now + 1.2
            while true {
                try permit.perform {}
                guard now < deadline else { throw failure("native_tcp_timeout") }
                var event = pollfd(fd: tcp, events: Int16(POLLOUT), revents: 0)
                let count = poll(&event, 1, 20)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw failure("native_tcp_poll") }
                if count > 0 {
                    var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                    guard getsockopt(tcp, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw failure("native_tcp_connect") }
                    break
                }
            }
        }
        let deadline = now + 1
        var offset = 0
        try frame.withUnsafeBytes { bytes in
            while offset < bytes.count {
                try permit.perform {}
                guard now < deadline else { throw failure("native_tcp_send_timeout") }
                let count = try permit.perform { Darwin.send(tcp, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, MSG_NOSIGNAL) }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var event = pollfd(fd: tcp, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&event, 1, 20); continue
                }
                guard count > 0 else { throw failure("native_tcp_send") }
                offset += count
            }
        }
        // The reference leaves the completed bootstrap connected for 400 ms.
        let settle = now + 0.4
        while now < settle { try permit.perform {}; _ = poll(nil, 0, 20) }
    }
    func openUDP() throws {
        try validateRoute()
        close()
        let descriptor = try socket(SOCK_DGRAM)
        do {
            guard try connect(descriptor, port: 9004) == 0 else { throw failure("native_udp_connect") }
            udp = descriptor
        } catch { Darwin.close(descriptor); throw error }
    }
    func send(_ packet: Data) throws {
        guard udp >= 0, (8...DJIUDPFraming.maximumDatagramLength).contains(packet.count) else { throw failure("native_udp_unavailable") }
        let count = packet.withUnsafeBytes { Darwin.send(udp, $0.baseAddress!, $0.count, MSG_NOSIGNAL) }
        guard count == packet.count else { throw failure("native_udp_send") }
    }
    func receive(timeoutMS: Int) throws -> [Data] {
        guard udp >= 0 else { throw failure("native_udp_unavailable") }
        var event = pollfd(fd: udp, events: Int16(POLLIN), revents: 0)
        let ready = poll(&event, 1, Int32(max(0, min(timeoutMS, 20))))
        if ready < 0 && errno == EINTR { return [] }
        guard ready >= 0, event.revents & Int16(POLLNVAL) == 0 else { throw failure("native_udp_receive") }
        guard ready > 0 else { return [] }
        // One IPv4 UDP payload is bounded; read the full packet so truncation
        // cannot create a falsely well-formed shorter datagram.
        var bytes = [UInt8](repeating: 0, count: 65536), result: [Data] = []
        for _ in 0..<32 {
            let count = Darwin.recv(udp, &bytes, bytes.count, MSG_DONTWAIT)
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure("native_udp_receive") }
            if count > 0 { result.append(Data(bytes.prefix(count))) }
        }
        return result
    }
    func close() { if udp >= 0 { Darwin.close(udp); udp = -1 } }
    deinit { close() }
}

/// Darwin's public `IP_BOUND_IF` option keeps each TCP/UDP descriptor on the
/// selected interface without changing the process or system default route.
private struct DarwinPocket3DatalinkSocketOptionApplier: Pocket3DatalinkSocketOptionApplying {
    func apply(_ option: Pocket3DatalinkSocketOption, descriptor: Int32) throws {
        switch option {
        case .bindIPv4Interface(let index):
            guard index != 0 else {
                throw Pocket3DatalinkSocketOptionError.invalidInterfaceIndex
            }
            var value = index
            let result = withUnsafePointer(to: &value) {
                setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, $0,
                           socklen_t(MemoryLayout<UInt32>.size))
            }
            guard result == 0 else {
                throw BridgeFailure("native_interface_bind", "指定的相機網路介面無法綁定")
            }
        }
    }
}
