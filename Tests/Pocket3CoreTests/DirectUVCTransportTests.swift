import Foundation
import Testing
@testable import Pocket3Core

private final class FakeNormalOpenHandle: @unchecked Sendable,
    DirectUVCNormalOpenHandle {
    let openObservation: DirectUVCOpenObservation
    private let lock = NSLock()
    private let statusObservation: DirectUVCOpenObservation
    private let closeResult: Result<DirectCaptureReleaseEvidence, Error>
    private var closeCount = 0

    init(openObservation: DirectUVCOpenObservation,
         statusObservation: DirectUVCOpenObservation? = nil,
         closeResult: Result<DirectCaptureReleaseEvidence, Error> = .success(.complete)) {
        self.openObservation = openObservation
        self.statusObservation = statusObservation ?? openObservation
        self.closeResult = closeResult
    }

    var releaseCount: Int { lock.withLock { closeCount } }

    func scalarStatus() throws -> DirectUVCOpenObservation {
        try lock.withLock { statusObservation }
    }

    func close() throws -> DirectCaptureReleaseEvidence {
        try lock.withLock {
            closeCount += 1
            return try closeResult.get()
        }
    }
}

private final class FakeNormalOpenBridge: @unchecked Sendable,
    DirectUVCNormalOpenBridge {
    private let lock = NSLock()
    private let handle: FakeNormalOpenHandle?
    private let failure: DirectUVCTransportError?
    private var opens = 0

    init(handle: FakeNormalOpenHandle? = nil,
         failure: DirectUVCTransportError? = nil) {
        self.handle = handle
        self.failure = failure
    }

    var openCount: Int { lock.withLock { opens } }

    func openVS(plan _: DirectUVCStreamPlan) throws
        -> any DirectUVCNormalOpenHandle {
        try lock.withLock {
            opens += 1
            if let failure { throw failure }
            guard let handle else {
                throw DirectUVCTransportError.openFailed(
                    code: "fake_missing_handle", ioReturn: nil)
            }
            return handle
        }
    }
}

private final class FakeNativeOpenHandle: @unchecked Sendable,
    DirectUVCNativeOpenHandle {
    let openObservation: DirectUVCOpenObservation
    private let lock = NSLock()
    private var controls: [UVCVideoStreamingRequest] = []
    private var reads = 0
    private var aborts = 0
    private var closes = 0

    init(observation: DirectUVCOpenObservation) {
        openObservation = observation
    }

    var controlRequests: [UVCVideoStreamingRequest] {
        lock.withLock { controls }
    }
    var readCount: Int { lock.withLock { reads } }
    var abortCount: Int { lock.withLock { aborts } }
    var closeCount: Int { lock.withLock { closes } }

    func scalarStatus() throws -> DirectUVCOpenObservation { openObservation }
    func controlTransfer(_ request: UVCVideoStreamingRequest,
                         payload _: Data?) throws -> Data? {
        lock.withLock { controls.append(request) }
        return request == .getMaxProbe || request == .getCurProbe
            ? Data(repeating: 0, count: 26) : nil
    }
    func readBulkIn(maximumBytes: Int) throws -> DirectUVCBulkTransfer {
        lock.withLock { reads += 1 }
        return DirectUVCBulkTransfer(
            requestedByteCount: maximumBytes,
            data: Data([2, 0x02, 0x65]), status: .complete)
    }
    func cancelBulkIn() throws { lock.withLock { aborts += 1 } }
    func close() throws -> DirectCaptureReleaseEvidence {
        lock.withLock { closes += 1 }
        return .complete
    }
}

private struct FakeNativeOpenBridge: DirectUVCNormalOpenBridge {
    let handle: FakeNativeOpenHandle
    func openVS(plan _: DirectUVCStreamPlan) throws
        -> any DirectUVCNormalOpenHandle { handle }
}

@Suite("Direct UVC normal-open transport")
struct DirectUVCTransportTests {
    private func plan() throws -> DirectUVCStreamPlan {
        let endpoint = UVCStreamingEndpoint(
            address: 0x82, transferType: 0x02, maximumPacketSize: 512)
        let inventory = UVCDescriptorInventory(interfaces: [
            UVCInterfaceInventory(
                number: 0, alternateSetting: 0, interfaceClass: 14,
                interfaceSubclass: 1, interfaceProtocol: 0,
                declaredEndpointCount: 0, endpoints: [], codecNames: []),
            UVCInterfaceInventory(
                number: 1, alternateSetting: 0, interfaceClass: 14,
                interfaceSubclass: 2, interfaceProtocol: 0,
                declaredEndpointCount: 1, endpoints: [endpoint],
                codecNames: ["H264"])
        ])
        return try DirectUVCStreamPlanner.pocket3H264(
            inventory: inventory, mode: Pocket3H264ModeCatalog.frame2,
            interval100ns: 333_333)
    }

    private func openedObservation(
        result: String = "opened", opened: Bool = true,
        ownedOpen: Bool = true
    ) -> DirectUVCOpenObservation {
        DirectUVCOpenObservation(
            location: 0x0110_0000, interfaceNumber: 1,
            alternateSetting: 0, endpointAddress: 0x82,
            endpointCount: 1,
            endpoints: [DirectUVCEndpointObservation(
                pipe: 1, address: 0x82, direction: 0x80,
                transferType: 0x02, maximumPacketSize: 512, interval: 0)],
            opened: opened, ownedOpen: ownedOpen, result: result,
            openIOReturn: 0, access: "normal_open_no_seize_no_pipe")
    }

    @Test func legacyPipeDirectionOneStillDescribesDescriptorINAddress() {
        let endpoint = DirectUVCEndpointObservation(
            pipe: 1, address: 0x82, direction: 1, transferType: 0x02,
            maximumPacketSize: 512, interval: 0)
        #expect(endpoint.isIN)
        #expect(endpoint.isBulk)
        #expect(endpoint.address == 0x82)
    }

    @Test func systemOwnerBusyEvidenceNeverClaimsAReleasePath() {
        let observation = openedObservation(
            result: "busy", opened: false, ownedOpen: false)
        let evidence = DirectUVCSystemOwnerBusyEvidence(
            interfaceNumber: observation.interfaceNumber,
            openIOReturn: 0xE000_02C7)
        #expect(evidence.ownerIdentity == "unknown")
        #expect(!evidence.publicReleasePathAvailable)
        #expect(evidence.nextSafeAction ==
                "stop_and_drain_own_avfoundation_graph")
    }

    @Test func normalOpenIsSingleOwnedLifecycleAndControlStaysUnavailable()
        async throws {
        let bridgeHandle = FakeNormalOpenHandle(
            openObservation: openedObservation())
        let bridge = FakeNormalOpenBridge(handle: bridgeHandle)
        let transport = DirectUVCNormalOpenTransport(bridge: bridge)

        let handle = try await transport.acquire(plan: try plan())
        let snapshot = await transport.snapshot()
        #expect(snapshot.active)
        #expect(snapshot.observation == openedObservation())
        #expect(bridge.openCount == 1)
        #expect(handle is any DirectUVCScalarDiagnosticsHandle)

        let scalar = try await (handle as! any DirectUVCScalarDiagnosticsHandle)
            .scalarStatus()
        #expect(scalar == openedObservation())
        await #expect(throws: DirectUVCTransportError.controlUnavailable) {
            try await handle.control(.getMaxProbe, payload: nil)
        }
        await #expect(throws: DirectUVCTransportError.busy) {
            try await transport.acquire(plan: try plan())
        }

        let evidence = try await handle.release()
        #expect(evidence == .complete)
        #expect(bridgeHandle.releaseCount == 1)
        #expect(!(await transport.snapshot()).active)
        await #expect(throws: DirectUVCTransportError.alreadyReleased) {
            try await handle.release()
        }
    }

    @Test func nativeNormalOpenForwardsReviewedControlsAndOneBoundedBulkRead()
        async throws {
        let bridgeHandle = FakeNativeOpenHandle(
            observation: openedObservation())
        let transport = DirectUVCNormalOpenTransport(
            bridge: FakeNativeOpenBridge(handle: bridgeHandle))
        let handle = try await transport.acquire(plan: try plan())
        let get = try await handle.control(.getMaxProbe, payload: nil)
        #expect(get?.count == 26)
        let set = try await handle.control(
            .setCurProbe, payload: Data(repeating: 0, count: 26))
        #expect(set == nil)
        let native = try #require(handle as? any DirectUVCNativeStreamHandle)
        let transfer = try await native.readBulkIn(maximumBytes: 4096)
        #expect(transfer.requestedByteCount == 4096)
        #expect(transfer.data == Data([2, 0x02, 0x65]))
        await native.cancelBulkIn()
        #expect(bridgeHandle.controlRequests == [.getMaxProbe, .setCurProbe])
        #expect(bridgeHandle.readCount == 1)
        #expect(bridgeHandle.abortCount == 1)
        _ = try await handle.release()
        #expect(bridgeHandle.closeCount == 1)
    }

    @Test func nonOwnedObservationIsRejectedAndReleasedOnce() async throws {
        let bridgeHandle = FakeNormalOpenHandle(
            openObservation: openedObservation(
                result: "busy", opened: false, ownedOpen: false))
        let bridge = FakeNormalOpenBridge(handle: bridgeHandle)
        let transport = DirectUVCNormalOpenTransport(bridge: bridge)

        await #expect(throws: DirectUVCTransportError.systemOwnerBusy(
            .init(interfaceNumber: 1, openIOReturn: 0))) {
            try await transport.acquire(plan: try plan())
        }
        #expect(bridge.openCount == 1)
        #expect(bridgeHandle.releaseCount == 1)
        #expect(!(await transport.snapshot()).active)
    }

    @Test func bridgeBusyDetachedAndTimeoutRemainTyped() async throws {
        let streamPlan = try plan()
        for error in [
            DirectUVCTransportError.busy,
            DirectUVCTransportError.detached,
            DirectUVCTransportError.timeout
        ] {
            let transport = DirectUVCNormalOpenTransport(
                bridge: FakeNormalOpenBridge(failure: error))
            await #expect(throws: error) {
                try await transport.acquire(plan: streamPlan)
            }
        }
    }

    @Test func closeFailureIsTypedAndDoesNotPermitSecondClose() async throws {
        let bridgeHandle = FakeNormalOpenHandle(
            openObservation: openedObservation(),
            closeResult: .failure(DirectUVCTransportError.closeFailed(
                code: "fake_close_timeout", ioReturn: 0xE000_02ED)))
        let bridge = FakeNormalOpenBridge(handle: bridgeHandle)
        let transport = DirectUVCNormalOpenTransport(bridge: bridge)
        let handle = try await transport.acquire(plan: try plan())

        await #expect(throws: DirectUVCTransportError.closeFailed(
            code: "fake_close_timeout", ioReturn: 0xE000_02ED)) {
            try await handle.release()
        }
        #expect(bridgeHandle.releaseCount == 1)
        #expect(!(await transport.snapshot()).active)
        await #expect(throws: DirectUVCTransportError.alreadyReleased) {
            try await handle.release()
        }
    }

    @Test func incompleteStopNeverCallsNormalOpenBridge() async throws {
        let bridge = FakeNormalOpenBridge(
            handle: FakeNormalOpenHandle(openObservation: openedObservation()))
        let transport = DirectUVCNormalOpenTransport(bridge: bridge)
        let coordinator = DirectUVCSessionCoordinator(
            plan: try plan(), transport: transport,
            ownership: CaptureOwnershipCoordinator(
                initialState: .avfoundationRunning))

        let result = await coordinator.start(after: AVFoundationStopEvidence(
            avfoundationStopped: true, frameQueueDrained: false))
        #expect(result.phase == .failed)
        #expect(bridge.openCount == 0)
    }

    @Test func coordinatorProjectsSystemOwnerBusyWithoutClaimingReadiness()
        async throws {
        let bridgeHandle = FakeNormalOpenHandle(
            openObservation: openedObservation(
                result: "busy", opened: false, ownedOpen: false))
        let bridge = FakeNormalOpenBridge(handle: bridgeHandle)
        let transport = DirectUVCNormalOpenTransport(bridge: bridge)
        let coordinator = DirectUVCSessionCoordinator(
            plan: try plan(), transport: transport,
            ownership: CaptureOwnershipCoordinator(
                initialState: .avfoundationRunning))

        let result = await coordinator.start(after: .complete)
        #expect(result.phase == .failed)
        #expect(result.failureCode == "direct_uvc_system_owner_busy")
        #expect(!result.negotiated && !result.ready)
        #expect(bridgeHandle.releaseCount == 1)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
