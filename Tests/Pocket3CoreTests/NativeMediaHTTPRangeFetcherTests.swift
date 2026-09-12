import Foundation
import Testing
@testable import Pocket3Core

private final class HTTPRangeCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("Native media HTTP range transport")
struct NativeMediaHTTPRangeFetcherTests {
    private let sessionID = UUID()
    private let peerID = UUID()

    private func readySession() -> NativeCameraSessionStatus {
        var session = NativeCameraSession()
        let generation = session.begin(sessionID: sessionID, peerID: peerID)
        _ = session.markPaired(generation: generation)
        _ = session.markCredentialsAvailable(generation: generation)
        _ = session.observeDatalink(.connecting, generation: generation)
        _ = session.observeDatalink(.ready, generation: generation)
        return session.status
    }

    private func routeStatus(
        state: Pocket3DatalinkRouteState = .interfaceBound,
        host: String = Pocket3MediaHTTPRangeRequest.host,
        interfaceIndex: UInt32? = 7,
        cameraReachable: Bool? = true,
        samePrimary: Bool? = nil,
        defaultChanged: Bool? = nil
    ) -> Pocket3DatalinkRouteStatus {
        Pocket3DatalinkRouteStatus(
            state: state, interfaceName: "en7", interfaceIndex: interfaceIndex,
            cameraHost: host, interfacePresent: true,
            cameraRouteReachable: cameraReachable,
            samePrimaryRoute: samePrimary,
            defaultRouteChanged: defaultChanged,
            evidence: "test_explicit_interface_route")
    }

    private func request(
        start: UInt64 = 0, end: UInt64 = 7,
        generation: UInt64 = 1
    ) throws -> Pocket3MediaHTTPRangeRequest {
        try Pocket3MediaHTTPRangeRequest(
            sessionID: sessionID, peripheralID: peerID, generation: generation,
            storage: 0, path: "DCIM/DJI_001/clip.MP4",
            range: try Pocket3MediaByteRange(start: start,
                                              endInclusive: end))
    }

    private func response(
        status: String = "HTTP/1.1 206 Partial Content",
        contentRange: String? = "bytes 0-7/1024",
        contentLength: String? = "8",
        body: Data = Data([0, 1, 2, 3, 4, 5, 6, 7]),
        extraHeaders: [String: String] = [:]
    ) -> Data {
        var headers = extraHeaders
        if let contentRange { headers["Content-Range"] = contentRange }
        if let contentLength { headers["Content-Length"] = contentLength }
        var result = Data("\(status)\r\n".utf8)
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            result.append(contentsOf: "\(name): \(value)\r\n".utf8)
        }
        result.append(contentsOf: "\r\n".utf8)
        result.append(body)
        return result
    }

    private func snapshot(_ session: NativeCameraSessionStatus,
                          route: Pocket3DatalinkRouteStatus,
                          now: TimeInterval = 10) -> NativeMediaValidationSnapshot {
        NativeMediaValidationSnapshot(session: session, routeStatus: route,
                                      nowUptime: now)
    }

    @Test func productionRouteRequiresVerifiedExplicitInterface() throws {
        #expect(throws: NativeMediaHTTPRangeFetcherError.invalidRoute) {
            try NativeMediaHTTPRangeRoute(routeStatus: .init(
                state: .legacyUnbound, evidence: "test_legacy"))
        }
        #expect(throws: NativeMediaHTTPRangeFetcherError.invalidRoute) {
            try NativeMediaHTTPRangeRoute(routeStatus: routeStatus(
                cameraReachable: nil))
        }
        #expect(throws: NativeMediaHTTPRangeFetcherError.invalidRoute) {
            try NativeMediaHTTPRangeRoute(routeStatus: routeStatus(
                host: "192.168.2.2"))
        }

        let route = try NativeMediaHTTPRangeRoute(
            routeStatus: routeStatus())
        let fetcher = try NativeMediaHTTPRangeFetcher(route: route)
        #expect(fetcher.route.interfaceIndex == 7)
        #expect(fetcher.route.cameraHost == "192.168.2.1")
    }

    @Test func validatorAcceptsOnlyMatching206RangeAndLength() throws {
        let request = try request()
        let body = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let result = try NativeMediaHTTPRangeResponseValidator.validate(
            response(body: body), request: request)
        #expect(result == body)

        let shorterRequest = try request(start: 10, end: 31)
        let shorterBody = Data([9, 8, 7, 6])
        let shorterResponse = response(
            contentRange: "bytes 10-13/64", contentLength: "4",
            body: shorterBody)
        #expect(try NativeMediaHTTPRangeResponseValidator.validate(
            shorterResponse, request: shorterRequest) == shorterBody)
    }

    @Test func validatorRejectsRedirectsFramingAndMismatchedEvidence() throws {
        let request = try request()
        #expect(throws: NativeMediaHTTPRangeFetcherError.redirectRejected) {
            try NativeMediaHTTPRangeResponseValidator.validate(
                response(status: "HTTP/1.1 302 Found",
                         extraHeaders: ["Location": "http://elsewhere"]),
                request: request)
        }
        #expect(throws: NativeMediaHTTPRangeFetcherError.unexpectedStatus) {
            try NativeMediaHTTPRangeResponseValidator.validate(
                response(status: "HTTP/1.1 200 OK"), request: request)
        }
        #expect(throws: NativeMediaHTTPRangeFetcherError.contentRangeMismatch) {
            try NativeMediaHTTPRangeResponseValidator.validate(
                response(contentRange: "bytes 1-8/1024"), request: request)
        }
        #expect(throws: NativeMediaHTTPRangeFetcherError.contentLengthMismatch) {
            try NativeMediaHTTPRangeResponseValidator.validate(
                response(contentLength: "7"), request: request)
        }
        #expect(throws: NativeMediaHTTPRangeFetcherError.missingContentRange) {
            try NativeMediaHTTPRangeResponseValidator.validate(
                response(contentRange: nil), request: request)
        }
        #expect(throws: NativeMediaHTTPRangeFetcherError.unsupportedTransferEncoding) {
            try NativeMediaHTTPRangeResponseValidator.validate(
                response(extraHeaders: ["Transfer-Encoding": "chunked"]),
                request: request)
        }
        #expect(throws: NativeMediaHTTPRangeFetcherError.invalidResponse) {
            try NativeMediaHTTPRangeResponseValidator.validate(
                response(body: Data(repeating: 1, count: 8)) + Data([0]),
                request: request)
        }
    }

    @Test func serviceUsesOneFakeServerResponseAndReturnsBoundedBytes() async throws {
        let session = readySession()
        let rangeRequest = try request(generation: session.generation)
        let request = try NativeMediaValidationRequest(
            action: .range, expectedSessionID: sessionID, peripheralID: peerID,
            generation: session.generation, rangeRequest: rangeRequest,
            execute: true, timeout: 2)
        let counter = HTTPRangeCallCounter()
        let body = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let fake = NativeMediaHTTPRangeFetcherAdapter { request, _ in
            counter.increment()
            let response = self.response(
                contentRange: "bytes 0-3/32", contentLength: "4", body: body)
            return try NativeMediaHTTPRangeResponseValidator.validate(
                response, request: request)
        }
        let result = try await NativeMediaValidationService(
            rangeFetcher: fake).run(request, snapshot: snapshot(
                session, route: routeStatus()))
        #expect(counter.count == 1)
        #expect(result.phase == .completed && result.completed)
        #expect(result.submitted && result.observed)
        #expect(result.range?.data == body)
        #expect(result.range?.byteCount == body.count)
    }

    @Test func invalidFakeResponseFailsOnceWithoutRetryOrDataLeak() async throws {
        let session = readySession()
        let rangeRequest = try request(generation: session.generation)
        let request = try NativeMediaValidationRequest(
            action: .range, expectedSessionID: sessionID, peripheralID: peerID,
            generation: session.generation, rangeRequest: rangeRequest,
            execute: true)
        let counter = HTTPRangeCallCounter()
        let fake = NativeMediaHTTPRangeFetcherAdapter { request, _ in
            counter.increment()
            return try NativeMediaHTTPRangeResponseValidator.validate(
                self.response(contentLength: "7"), request: request)
        }
        let result = try await NativeMediaValidationService(
            rangeFetcher: fake).run(request, snapshot: snapshot(
                session, route: routeStatus()))
        #expect(counter.count == 1)
        #expect(result.phase == .failed && !result.completed)
        #expect(result.failureCode == "native_media_http_content_length_mismatch")
        #expect(result.range?.data == nil && result.range?.byteCount == 0)
    }
}
