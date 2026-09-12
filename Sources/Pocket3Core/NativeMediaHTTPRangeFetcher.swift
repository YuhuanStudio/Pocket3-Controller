import Foundation
import Darwin

/// Failure codes intentionally carry no URL, path, response body or
/// credential.  A range attempt is one bounded request; callers may choose to
/// start a new developer validation attempt after a failure.
public enum NativeMediaHTTPRangeFetcherError: Error, Sendable, Equatable {
    case invalidRoute
    case invalidRequest
    case invalidTimeout
    case unsupportedScheme
    case unsupportedHost
    case cancelled
    case timeout
    case socket
    case bindFailed
    case connectionFailed
    case sendFailed
    case responseHeaderTooLarge
    case responseTooLarge
    case invalidResponse
    case unexpectedStatus
    case redirectRejected
    case missingContentRange
    case invalidContentRange
    case contentRangeMismatch
    case missingContentLength
    case invalidContentLength
    case contentLengthMismatch
    case unsupportedTransferEncoding
    case unsupportedContentEncoding

    public var failureCode: String {
        switch self {
        case .invalidRoute: "native_media_http_route_invalid"
        case .invalidRequest: "native_media_http_request_invalid"
        case .invalidTimeout: "native_media_http_timeout_invalid"
        case .unsupportedScheme: "native_media_http_scheme_unsupported"
        case .unsupportedHost: "native_media_http_host_unsupported"
        case .cancelled: "cancelled"
        case .timeout: "native_media_http_timeout"
        case .socket: "native_media_http_socket_failed"
        case .bindFailed: "native_media_http_interface_bind_failed"
        case .connectionFailed: "native_media_http_connection_failed"
        case .sendFailed: "native_media_http_send_failed"
        case .responseHeaderTooLarge: "native_media_http_response_headers_too_large"
        case .responseTooLarge: "native_media_http_response_too_large"
        case .invalidResponse: "native_media_http_response_invalid"
        case .unexpectedStatus: "native_media_http_status_unexpected"
        case .redirectRejected: "native_media_http_redirect_rejected"
        case .missingContentRange: "native_media_http_content_range_missing"
        case .invalidContentRange: "native_media_http_content_range_invalid"
        case .contentRangeMismatch: "native_media_http_content_range_mismatch"
        case .missingContentLength: "native_media_http_content_length_missing"
        case .invalidContentLength: "native_media_http_content_length_invalid"
        case .contentLengthMismatch: "native_media_http_content_length_mismatch"
        case .unsupportedTransferEncoding: "native_media_http_transfer_encoding_unsupported"
        case .unsupportedContentEncoding: "native_media_http_content_encoding_unsupported"
        }
    }
}

/// A route proof for the media HTTP transport.  The route must name a live
/// interface and a verified route to the fixed camera host.  The unbound
/// legacy kernel route is deliberately not accepted here.
public struct NativeMediaHTTPRangeRoute: Codable, Sendable, Equatable,
    Hashable {
    public static let cameraHost = Pocket3MediaHTTPRangeRequest.host
    public static let cameraPort: UInt16 = UInt16(Pocket3MediaHTTPRangeRequest.port)

    public let interfaceIndex: UInt32
    public let cameraHost: String
    public let cameraPort: UInt16

    public init(routeStatus: Pocket3DatalinkRouteStatus) throws {
        guard routeStatus.cameraHost == Self.cameraHost,
              let interfaceIndex = routeStatus.interfaceIndex,
              interfaceIndex != 0,
              routeStatus.cameraRouteReachable == true,
              routeStatus.defaultRouteChanged != true,
              routeStatus.samePrimaryRoute != false,
              [.interfaceBound, .samePrimaryRoute].contains(routeStatus.state)
        else {
            throw NativeMediaHTTPRangeFetcherError.invalidRoute
        }
        self.interfaceIndex = interfaceIndex
        cameraHost = Self.cameraHost
        cameraPort = Self.cameraPort
    }

    public init(routePlan: Pocket3DatalinkRoutePlan) throws {
        guard routePlan.allowed,
              routePlan.configuration.isInterfaceBound,
              routePlan.configuration.cameraHost == Self.cameraHost,
              let boundInterfaceIndex = routePlan.boundInterfaceIndex,
              boundInterfaceIndex != 0,
              routePlan.status.interfaceIndex == boundInterfaceIndex else {
            throw NativeMediaHTTPRangeFetcherError.invalidRoute
        }
        try self.init(routeStatus: routePlan.status)
    }
}

/// Public, synchronous response contract used by the production transport
/// and by fake protocol/server tests.  It validates the complete response
/// before any bytes are returned to a caller.
public enum NativeMediaHTTPRangeResponseValidator {
    public static let maximumHeaderBytes = 32 * 1024

    public static func validate(
        _ response: Data,
        request: Pocket3MediaHTTPRangeRequest,
        maximumBytes: Int = Int(Pocket3MediaByteRange.maximumLength)
    ) throws -> Data {
        guard maximumBytes > 0,
              maximumBytes <= Int(Pocket3MediaByteRange.maximumLength),
              request.range.length <= UInt64(maximumBytes) else {
            throw NativeMediaHTTPRangeFetcherError.responseTooLarge
        }
        let bytes = Array(response)
        guard let separator = separator(in: bytes) else {
            throw response.count > maximumHeaderBytes
                ? NativeMediaHTTPRangeFetcherError.responseHeaderTooLarge
                : NativeMediaHTTPRangeFetcherError.invalidResponse
        }
        guard separator <= maximumHeaderBytes else {
            throw NativeMediaHTTPRangeFetcherError.responseHeaderTooLarge
        }
        let metadata = try parseHeader(
            Data(bytes[0..<separator]), request: request,
            maximumBytes: maximumBytes)
        let bodyStart = separator + 4
        let bodyEnd = bodyStart + metadata.contentLength
        guard bodyEnd >= bodyStart else {
            throw NativeMediaHTTPRangeFetcherError.responseTooLarge
        }
        guard bytes.count >= bodyEnd else {
            throw NativeMediaHTTPRangeFetcherError.invalidResponse
        }
        // A single request uses Connection: close and has no framing after the
        // declared body.  Extra bytes are rejected rather than silently
        // turning a pipelined or smuggled response into media evidence.
        guard bytes.count == bodyEnd else {
            throw NativeMediaHTTPRangeFetcherError.invalidResponse
        }
        return Data(bytes[bodyStart..<bodyEnd])
    }

    fileprivate struct HeaderMetadata {
        let contentLength: Int
    }

    fileprivate static func parseHeader(
        _ header: Data,
        request: Pocket3MediaHTTPRangeRequest,
        maximumBytes: Int
    ) throws -> HeaderMetadata {
        let headerBytes = Array(header)
        guard headerBytes.count <= maximumHeaderBytes,
              headerBytes.allSatisfy({
                  $0 == 9 || (32...126).contains($0) || $0 == 13 || $0 == 10
              }) else {
            throw NativeMediaHTTPRangeFetcherError.responseHeaderTooLarge
        }
        let text = String(decoding: headerBytes, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, !statusLine.isEmpty else {
            throw NativeMediaHTTPRangeFetcherError.invalidResponse
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2,
                                            omittingEmptySubsequences: true)
        guard statusParts.count >= 2,
              statusParts[0] == "HTTP/1.0" || statusParts[0] == "HTTP/1.1",
              let status = Int(statusParts[1]), (100...599).contains(status)
        else {
            throw NativeMediaHTTPRangeFetcherError.invalidResponse
        }
        if (300...399).contains(status) {
            throw NativeMediaHTTPRangeFetcherError.redirectRejected
        }
        guard status == 206 else {
            throw NativeMediaHTTPRangeFetcherError.unexpectedStatus
        }

        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else {
                throw NativeMediaHTTPRangeFetcherError.invalidResponse
            }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.utf8.allSatisfy({ byte in
                      (65...90).contains(byte) || (97...122).contains(byte) ||
                      (48...57).contains(byte) || byte == 45 || byte == 95
                  }), fields[name] == nil else {
                throw NativeMediaHTTPRangeFetcherError.invalidResponse
            }
            fields[name] = value
        }

        if let transferEncoding = fields["transfer-encoding"],
           transferEncoding.lowercased() != "identity" {
            throw NativeMediaHTTPRangeFetcherError.unsupportedTransferEncoding
        }
        if let contentEncoding = fields["content-encoding"],
           contentEncoding.lowercased() != "identity" {
            throw NativeMediaHTTPRangeFetcherError.unsupportedContentEncoding
        }
        if fields["location"] != nil {
            throw NativeMediaHTTPRangeFetcherError.redirectRejected
        }

        guard let contentRange = fields["content-range"] else {
            throw NativeMediaHTTPRangeFetcherError.missingContentRange
        }
        let rangeParts = contentRange.split(separator: "/", maxSplits: 1,
                                             omittingEmptySubsequences: false)
        guard rangeParts.count == 2, rangeParts[1] != "*",
              let total = decimal(rangeParts[1]) else {
            throw NativeMediaHTTPRangeFetcherError.invalidContentRange
        }
        let value = rangeParts[0]
        guard value.hasPrefix("bytes ") else {
            throw NativeMediaHTTPRangeFetcherError.invalidContentRange
        }
        let bounds = value.dropFirst(6).split(separator: "-", maxSplits: 1,
                                                omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = decimal(bounds[0]), let end = decimal(bounds[1]),
              start <= end, total > end else {
            throw NativeMediaHTTPRangeFetcherError.invalidContentRange
        }
        guard start == request.range.start,
              end <= request.range.endInclusive,
              end - start < UInt64(maximumBytes) else {
            throw NativeMediaHTTPRangeFetcherError.contentRangeMismatch
        }
        let bodyLength = end - start + 1
        guard bodyLength <= request.range.length else {
            throw NativeMediaHTTPRangeFetcherError.contentRangeMismatch
        }

        guard let rawLength = fields["content-length"],
              let length = decimal(rawLength),
              let contentLength = Int(exactly: length) else {
            throw fields["content-length"] == nil
                ? NativeMediaHTTPRangeFetcherError.missingContentLength
                : NativeMediaHTTPRangeFetcherError.invalidContentLength
        }
        guard contentLength >= 0,
              UInt64(contentLength) == bodyLength,
              contentLength <= maximumBytes else {
            throw NativeMediaHTTPRangeFetcherError.contentLengthMismatch
        }
        return HeaderMetadata(contentLength: contentLength)
    }

    private static func decimal(_ value: Substring) -> UInt64? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        return UInt64(value)
    }

    private static func decimal(_ value: String) -> UInt64? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        return UInt64(value)
    }

    private static func separator(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where
            bytes[index] == 13 && bytes[index + 1] == 10 &&
            bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index
        }
        return nil
    }
}

/// A single HTTP/1.x GET over an interface-bound Darwin TCP socket.  The
/// operation is reference-backed so cancellation can close the descriptor
/// while a poll is waiting; it never changes the system/default route.
public struct NativeMediaHTTPRangeFetcher: NativeMediaHTTPRangeFetching,
    Sendable {
    public let route: NativeMediaHTTPRangeRoute
    public let maximumResponseBytes: Int

    public init(route: NativeMediaHTTPRangeRoute,
                maximumResponseBytes: Int = Int(Pocket3MediaByteRange.maximumLength))
        throws {
        guard maximumResponseBytes > 0,
              maximumResponseBytes <= Int(Pocket3MediaByteRange.maximumLength)
        else {
            throw NativeMediaHTTPRangeFetcherError.responseTooLarge
        }
        self.route = route
        self.maximumResponseBytes = maximumResponseBytes
    }

    public init(routeStatus: Pocket3DatalinkRouteStatus,
                maximumResponseBytes: Int = Int(Pocket3MediaByteRange.maximumLength))
        throws {
        try self.init(route: NativeMediaHTTPRangeRoute(routeStatus: routeStatus),
                      maximumResponseBytes: maximumResponseBytes)
    }

    public init(routePlan: Pocket3DatalinkRoutePlan,
                maximumResponseBytes: Int = Int(Pocket3MediaByteRange.maximumLength))
        throws {
        try self.init(route: NativeMediaHTTPRangeRoute(routePlan: routePlan),
                      maximumResponseBytes: maximumResponseBytes)
    }

    public func fetch(_ request: Pocket3MediaHTTPRangeRequest,
                      readiness: NativeCameraSessionStatus) async throws -> Data {
        try await fetch(request, readiness: readiness,
                        timeout: NativeMediaValidationService.defaultTimeout)
    }

    public func fetch(_ request: Pocket3MediaHTTPRangeRequest,
                      readiness: NativeCameraSessionStatus,
                      timeout: TimeInterval) async throws -> Data {
        guard timeout.isFinite, timeout > 0,
              timeout <= NativeCommandTransactionRequest.maximumTimeout else {
            throw NativeMediaHTTPRangeFetcherError.invalidTimeout
        }
        guard route.cameraHost == Pocket3MediaHTTPRangeRequest.host,
              route.cameraPort == Pocket3MediaHTTPRangeRequest.port,
              route.interfaceIndex != 0 else {
            throw NativeMediaHTTPRangeFetcherError.invalidRoute
        }
        guard request.range.length <= UInt64(maximumResponseBytes) else {
            throw NativeMediaHTTPRangeFetcherError.responseTooLarge
        }
        guard let sessionID = readiness.sessionID,
              let peerID = readiness.peerID,
              readiness.commandReady,
              request.identity.sessionID == sessionID,
              request.identity.generation == readiness.generation,
              request.identity.peripheralID == peerID else {
            throw NativeMediaHTTPRangeFetcherError.invalidRequest
        }
        guard let url = request.url,
              url.scheme == Pocket3MediaHTTPRangeRequest.scheme,
              url.host == Pocket3MediaHTTPRangeRequest.host,
              url.port == Pocket3MediaHTTPRangeRequest.port,
              url.path == Pocket3MediaHTTPRangeRequest.endpoint else {
            throw urlSchemeOrHostError(request)
        }
        guard let target = Self.target(url: url) else {
            throw NativeMediaHTTPRangeFetcherError.invalidRequest
        }

        let operation = NativeMediaHTTPRangeFetchOperation(
            route: route, request: request, target: target,
            maximumResponseBytes: maximumResponseBytes, timeout: timeout)
        do {
            return try await withTaskCancellationHandler(operation: {
                try await Task.detached(priority: .userInitiated) {
                    try operation.run()
                }.value
            }, onCancel: {
                operation.cancel()
            })
        } catch NativeMediaHTTPRangeFetcherError.cancelled {
            throw CancellationError()
        }
    }

    private func urlSchemeOrHostError(
        _ request: Pocket3MediaHTTPRangeRequest
    ) -> NativeMediaHTTPRangeFetcherError {
        guard let url = request.url else {
            return .invalidRequest
        }
        if url.scheme != Pocket3MediaHTTPRangeRequest.scheme {
            return .unsupportedScheme
        }
        if url.host != Pocket3MediaHTTPRangeRequest.host ||
            url.port != Pocket3MediaHTTPRangeRequest.port {
            return .unsupportedHost
        }
        return .invalidRequest
    }

    private static func target(url: URL) -> Data? {
        guard let components = URLComponents(
            url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath.isEmpty
            ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let target = "\(path)\(query)"
        guard !target.contains("\r"), !target.contains("\n") else { return nil }
        let value = "GET \(target) HTTP/1.1\r\n" +
            "Host: \(Pocket3MediaHTTPRangeRequest.host)\r\n" +
            "Range: \(urlRangeHeaderPlaceholder)\r\n" +
            "Accept: */*\r\nConnection: close\r\n\r\n"
        // This helper is only used after the request is validated; the range
        // header is replaced by the operation with the exact request value.
        return Data(value.utf8)
    }

    private static let urlRangeHeaderPlaceholder = "bytes=0-0"
}

private final class NativeMediaHTTPRangeFetchOperation: @unchecked Sendable {
    private let route: NativeMediaHTTPRangeRoute
    private let request: Pocket3MediaHTTPRangeRequest
    private let target: Data
    private let maximumResponseBytes: Int
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false

    init(route: NativeMediaHTTPRangeRoute,
         request: Pocket3MediaHTTPRangeRequest,
         target: Data,
         maximumResponseBytes: Int,
         timeout: TimeInterval) {
        self.route = route; self.request = request; self.target = target
        self.maximumResponseBytes = maximumResponseBytes; self.timeout = timeout
    }

    func cancel() {
        let fd: Int32 = lock.withLock {
            cancelled = true
            let current = descriptor
            descriptor = -1
            return current
        }
        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    func run() throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try checkCancellation()
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeMediaHTTPRangeFetcherError.socket }
        guard install(fd) else {
            Darwin.close(fd)
            throw NativeMediaHTTPRangeFetcherError.cancelled
        }
        defer { closeCurrent() }

        do {
            try configure(fd)
            try connect(fd, deadline: deadline)
            var outbound = Data(target)
            let range = request.rangeHeader
            let replacement = Data("Range: \(range)".utf8)
            let placeholder = Data("Range: bytes=0-0".utf8)
            guard let rangeOffset = outbound.range(of: placeholder) else {
                throw NativeMediaHTTPRangeFetcherError.invalidRequest
            }
            outbound.replaceSubrange(rangeOffset, with: replacement)
            try send(outbound, fd: fd, deadline: deadline)
            return try receive(fd: fd, deadline: deadline)
        } catch let error as NativeMediaHTTPRangeFetcherError {
            throw error
        } catch is CancellationError {
            throw NativeMediaHTTPRangeFetcherError.cancelled
        } catch {
            throw NativeMediaHTTPRangeFetcherError.invalidResponse
        }
    }

    private func install(_ fd: Int32) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            descriptor = fd
            return true
        }
    }

    private func closeCurrent() {
        let fd: Int32 = lock.withLock {
            let current = descriptor
            descriptor = -1
            return current
        }
        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private func checkCancellation() throws {
        if lock.withLock({ cancelled }) || Task.isCancelled {
            throw NativeMediaHTTPRangeFetcherError.cancelled
        }
    }

    private func configure(_ fd: Int32) throws {
        var interfaceIndex = route.interfaceIndex
        guard Darwin.setsockopt(fd, IPPROTO_IP, IP_BOUND_IF,
                                &interfaceIndex,
                                socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
            throw NativeMediaHTTPRangeFetcherError.bindFailed
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw NativeMediaHTTPRangeFetcherError.socket
        }
        var one: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one,
                              socklen_t(MemoryLayout<Int32>.size))
    }

    private func connect(_ fd: Int32, deadline: TimeInterval) throws {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = route.cameraPort.bigEndian
        guard inet_pton(AF_INET, route.cameraHost, &destination.sin_addr) == 1 else {
            throw NativeMediaHTTPRangeFetcherError.invalidRoute
        }
        let result = withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return }
        guard errno == EINPROGRESS else {
            throw NativeMediaHTTPRangeFetcherError.connectionFailed
        }
        try wait(fd: fd, events: Int16(POLLOUT), deadline: deadline)
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
              socketError == 0 else {
            throw NativeMediaHTTPRangeFetcherError.connectionFailed
        }
    }

    private func send(_ data: Data, fd: Int32, deadline: TimeInterval) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw NativeMediaHTTPRangeFetcherError.invalidRequest
            }
            while offset < raw.count {
                try checkCancellation()
                let result = Darwin.send(fd, base.advanced(by: offset),
                                         raw.count - offset, MSG_NOSIGNAL)
                if result > 0 {
                    offset += result
                } else if result < 0 && errno == EINTR {
                    continue
                } else if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    try wait(fd: fd, events: Int16(POLLOUT), deadline: deadline)
                } else {
                    throw NativeMediaHTTPRangeFetcherError.sendFailed
                }
            }
        }
    }

    private func receive(fd: Int32, deadline: TimeInterval) throws -> Data {
        var response = Data()
        var headerEnd: Int?
        var contentLength: Int?
        while headerEnd == nil {
            try checkCancellation()
            try wait(fd: fd, events: Int16(POLLIN), deadline: deadline)
            try appendReceive(to: &response, fd: fd,
                              maximum: NativeMediaHTTPRangeResponseValidator.maximumHeaderBytes)
            let bytes = Array(response)
            if let separator = separator(in: bytes) {
                guard separator <= NativeMediaHTTPRangeResponseValidator.maximumHeaderBytes else {
                    throw NativeMediaHTTPRangeFetcherError.responseHeaderTooLarge
                }
                let metadata = try NativeMediaHTTPRangeResponseValidator.parseHeader(
                    Data(bytes[0..<separator]), request: request,
                    maximumBytes: maximumResponseBytes)
                let bodyStart = separator + 4
                guard metadata.contentLength <= maximumResponseBytes,
                      metadata.contentLength <= Int(request.range.length),
                      response.count <= bodyStart + metadata.contentLength else {
                    throw NativeMediaHTTPRangeFetcherError.responseTooLarge
                }
                headerEnd = separator
                contentLength = metadata.contentLength
            } else if response.count > NativeMediaHTTPRangeResponseValidator.maximumHeaderBytes {
                throw NativeMediaHTTPRangeFetcherError.responseHeaderTooLarge
            }
        }

        guard let headerEnd, let contentLength else {
            throw NativeMediaHTTPRangeFetcherError.invalidResponse
        }
        let bodyStart = headerEnd + 4
        let bodyEnd = bodyStart + contentLength
        while response.count < bodyEnd {
            try checkCancellation()
            try wait(fd: fd, events: Int16(POLLIN), deadline: deadline)
            try appendReceive(to: &response, fd: fd, maximum: bodyEnd)
        }
        guard response.count == bodyEnd else {
            throw NativeMediaHTTPRangeFetcherError.invalidResponse
        }
        return try NativeMediaHTTPRangeResponseValidator.validate(
            response, request: request, maximumBytes: maximumResponseBytes)
    }

    private func appendReceive(to response: inout Data, fd: Int32,
                               maximum: Int) throws {
        let remaining = maximum - response.count
        guard remaining > 0 else {
            throw NativeMediaHTTPRangeFetcherError.responseTooLarge
        }
        var bytes = [UInt8](repeating: 0, count: min(64 * 1024, remaining))
        let count = bytes.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.recv(fd, base, raw.count, 0)
        }
        if count > 0 {
            response.append(contentsOf: bytes.prefix(count))
            return
        }
        if count == 0 {
            throw NativeMediaHTTPRangeFetcherError.invalidResponse
        }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
            return
        }
        if lock.withLock({ cancelled }) {
            throw NativeMediaHTTPRangeFetcherError.cancelled
        }
        throw NativeMediaHTTPRangeFetcherError.invalidResponse
    }

    private func wait(fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            try checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw NativeMediaHTTPRangeFetcherError.timeout
            }
            var event = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(max(1, min(25, Int(ceil(remaining * 1000)))))
            let result = poll(&event, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0, event.revents & Int16(POLLNVAL) == 0 else {
                if lock.withLock({ cancelled }) {
                    throw NativeMediaHTTPRangeFetcherError.cancelled
                }
                throw NativeMediaHTTPRangeFetcherError.socket
            }
            if result > 0 {
                if event.revents & Int16(POLLERR | POLLHUP) != 0,
                   event.revents & events == 0 {
                    throw NativeMediaHTTPRangeFetcherError.connectionFailed
                }
                if event.revents & events != 0 { return }
            }
        }
    }

    private func separator(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where
            bytes[index] == 13 && bytes[index + 1] == 10 &&
            bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index
        }
        return nil
    }
}

public typealias Pocket3NativeMediaHTTPRangeFetcher = NativeMediaHTTPRangeFetcher
public typealias Pocket3NativeMediaHTTPRangeRoute = NativeMediaHTTPRangeRoute
