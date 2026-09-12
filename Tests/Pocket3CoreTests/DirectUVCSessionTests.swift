import Foundation
import Testing
@testable import Pocket3Core

private final class FakeDirectUVCHandle: @unchecked Sendable,
    DirectUVCStreamHandle {
    private let lock = NSLock()
    private let maximum: Data
    private let current: Data
    private var requests: [(UVCVideoStreamingRequest, Data?)] = []
    private var releases = 0

    init(maximum: Data, current: Data) {
        self.maximum = maximum
        self.current = current
    }

    var requestKinds: [UVCVideoStreamingRequest] {
        lock.withLock { requests.map(\.0) }
    }

    var requestPayloads: [Data?] {
        lock.withLock { requests.map(\.1) }
    }

    var releaseCount: Int { lock.withLock { releases } }

    func control(_ request: UVCVideoStreamingRequest,
                 payload: Data?) async throws -> Data? {
        lock.withLock { requests.append((request, payload)) }
        switch request {
        case .getMaxProbe: return maximum
        case .setCurProbe, .setCurCommit: return nil
        case .getCurProbe: return current
        }
    }

    func release() async throws -> DirectCaptureReleaseEvidence {
        lock.withLock { releases += 1 }
        return .complete
    }
}

private final class FakeDirectUVCTransport: @unchecked Sendable,
    DirectUVCStreamTransport {
    let handle: FakeDirectUVCHandle
    private let lock = NSLock()
    private var acquisitions = 0

    init(handle: FakeDirectUVCHandle) { self.handle = handle }
    var acquireCount: Int { lock.withLock { acquisitions } }

    func acquire(plan _: DirectUVCStreamPlan) async throws
        -> any DirectUVCStreamHandle {
        lock.withLock { acquisitions += 1 }
        return handle
    }
}

private final class WaitingDirectUVCTransport: @unchecked Sendable,
    DirectUVCStreamTransport {
    let entered = AsyncDirectUVCSemaphore()
    let release = AsyncDirectUVCSemaphore()
    let handle: FakeDirectUVCHandle

    init(handle: FakeDirectUVCHandle) { self.handle = handle }

    func acquire(plan _: DirectUVCStreamPlan) async throws
        -> any DirectUVCStreamHandle {
        entered.signal()
        await release.wait()
        return handle
    }
}

private final class AsyncDirectUVCSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    func signal() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            signaled = true
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if signaled { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

@Suite("Direct UVC public planner and ownership coordinator")
struct DirectUVCSessionTests {
    private func inventory(endpoint: UVCStreamingEndpoint = .init(
        address: 0x82, transferType: 0x02, maximumPacketSize: 512),
                            codecNames: [String] = ["H264"])
        -> UVCDescriptorInventory {
        UVCDescriptorInventory(interfaces: [
            UVCInterfaceInventory(
                number: 0, alternateSetting: 0, interfaceClass: 14,
                interfaceSubclass: 1, interfaceProtocol: 0,
                declaredEndpointCount: 0, endpoints: [], codecNames: []),
            UVCInterfaceInventory(
                number: 1, alternateSetting: 0, interfaceClass: 14,
                interfaceSubclass: 2, interfaceProtocol: 0,
                declaredEndpointCount: 1, endpoints: [endpoint],
                codecNames: codecNames)
        ])
    }

    private func plan() throws -> DirectUVCStreamPlan {
        try DirectUVCStreamPlanner.pocket3H264(
            inventory: inventory(), mode: Pocket3H264ModeCatalog.frame2,
            interval100ns: 333_333)
    }

    private func controlBlock(maxVideoFrameSize: UInt32,
                              maxPayloadTransferSize: UInt32)
        -> Data {
        UVCVideoStreamingControlBlock(
            formatIndex: 2, frameIndex: 2, frameInterval: 333_333,
            maxVideoFrameSize: maxVideoFrameSize,
            maxPayloadTransferSize: maxPayloadTransferSize).encodedData
    }

    @Test func plannerSelectsOnlyDescriptorBackedBulkINH264() throws {
        let selected = try plan()
        #expect(selected.selection.controlInterface.number == 0)
        #expect(selected.selection.streamingInterface.number == 1)
        #expect(selected.selection.streamingInterface.alternateSetting == 0)
        #expect(selected.selection.endpoint.address == 0x82)
        #expect(selected.selection.endpoint.isIN && selected.selection.endpoint.isBulk)
        #expect(selected.negotiationRequests == [
            .getMaxProbe, .setCurProbe, .getCurProbe, .setCurCommit
        ])

        #expect(throws: DirectUVCError.invalidConfiguration) {
            try DirectUVCStreamPlanner.pocket3H264(
                inventory: inventory(endpoint: .init(
                    address: 0x02, transferType: 0x02,
                    maximumPacketSize: 512)), endpointAddress: 0x02)
        }
        #expect(throws: DirectUVCError.codecUnavailable(.hevc)) {
            let configuration = try DirectUVCStreamConfiguration(
                codec: .hevc, formatIndex: 1, frameIndex: 1,
                width: 1920, height: 1080,
                supportedIntervals100ns: [333_333],
                frameInterval100ns: 333_333)
            try DirectUVCStreamPlanner.plan(
                inventory: inventory(), configuration: configuration)
        }
    }

    @Test func negotiatorUsesOneExactFourStepProbeCommitSequence() async throws {
        let maximum = controlBlock(
            maxVideoFrameSize: 2_000_000,
            maxPayloadTransferSize: 512)
        let current = controlBlock(
            maxVideoFrameSize: 1_500_000,
            maxPayloadTransferSize: 512)
        let handle = FakeDirectUVCHandle(maximum: maximum, current: current)
        let result = await DirectUVCNegotiator.run(
            plan: try plan(), handle: handle)

        #expect(result.completed)
        #expect(result.committed)
        #expect(result.submittedCount == 4)
        #expect(result.steps.map(\.request) == [
            .getMaxProbe, .setCurProbe, .getCurProbe, .setCurCommit
        ])
        #expect(handle.requestKinds == result.steps.map(\.request))
        #expect(handle.requestPayloads[0] == nil)
        #expect(handle.requestPayloads[1]?.count == 26)
        #expect(handle.requestPayloads[2] == nil)
        #expect(handle.requestPayloads[3] == current)
        #expect(result.probeMaximum?.maxVideoFrameSize == 2_000_000)
        #expect(result.probeAccepted?.maxVideoFrameSize == 1_500_000)
    }

    @Test func ownershipRequiresCompleteAVFStopAndSupportsFencedRestart() async throws {
        let handle = FakeDirectUVCHandle(
            maximum: controlBlock(maxVideoFrameSize: 2_000_000,
                                  maxPayloadTransferSize: 512),
            current: controlBlock(maxVideoFrameSize: 1_500_000,
                                  maxPayloadTransferSize: 512))
        let transport = FakeDirectUVCTransport(handle: handle)
        let ownership = CaptureOwnershipCoordinator(
            initialState: .avfoundationRunning)
        let coordinator = DirectUVCSessionCoordinator(
            plan: try plan(), transport: transport, ownership: ownership)

        let result = await coordinator.start(after: .complete)
        #expect(result.phase == .directNegotiated)
        #expect(result.negotiated && !result.bulkReadReady)
        #expect(transport.acquireCount == 1)
        #expect(await ownership.state() == .directRunning)

        let stopped = await coordinator.stop()
        #expect(stopped.phase == .awaitingAVFoundationRestart)
        #expect(stopped.releaseEvidence == .complete)
        #expect(handle.releaseCount == 1)
        let restarted = await coordinator.avfoundationRestarted()
        #expect(restarted.phase == .idle)
        #expect(await ownership.state() == .avfoundationRunning)
    }

    @Test func incompleteAVFStopDoesNotAcquireVSInterface() async throws {
        let handle = FakeDirectUVCHandle(maximum: Data(), current: Data())
        let transport = FakeDirectUVCTransport(handle: handle)
        let coordinator = DirectUVCSessionCoordinator(
            plan: try plan(), transport: transport,
            ownership: CaptureOwnershipCoordinator(
                initialState: .avfoundationRunning))
        let result = await coordinator.start(after: AVFoundationStopEvidence(
            avfoundationStopped: true, frameQueueDrained: false))
        #expect(result.phase == .failed)
        #expect(transport.acquireCount == 0)
        #expect(result.failureCode?.contains("ownership") == true)
    }

    @Test func cancellationDuringAcquireReleasesLateHandleAndDoesNotNegotiate() async throws {
        let handle = FakeDirectUVCHandle(maximum: Data(), current: Data())
        let transport = WaitingDirectUVCTransport(handle: handle)
        let coordinator = DirectUVCSessionCoordinator(
            plan: try plan(), transport: transport,
            ownership: CaptureOwnershipCoordinator(
                initialState: .avfoundationRunning))
        let task = Task { await coordinator.start(after: .complete) }
        await transport.entered.wait()
        let cancelled = await coordinator.cancel()
        #expect(cancelled.phase == .cancelled)
        transport.release.signal()
        let late = await task.value
        #expect(late.phase == .cancelled)
        #expect(handle.requestKinds.isEmpty)
        #expect(handle.releaseCount == 1)
    }

    @Test func cancellationAfterNegotiationFencesDirectOwnershipBeforeRestart() async throws {
        let handle = FakeDirectUVCHandle(
            maximum: controlBlock(maxVideoFrameSize: 2_000_000,
                                  maxPayloadTransferSize: 512),
            current: controlBlock(maxVideoFrameSize: 1_500_000,
                                  maxPayloadTransferSize: 512))
        let ownership = CaptureOwnershipCoordinator(
            initialState: .avfoundationRunning)
        let coordinator = DirectUVCSessionCoordinator(
            plan: try plan(),
            transport: FakeDirectUVCTransport(handle: handle),
            ownership: ownership)

        _ = await coordinator.start(after: .complete)
        let cancelled = await coordinator.cancel()

        #expect(cancelled.phase == .cancelled)
        #expect(cancelled.releaseEvidence == .complete)
        #expect(handle.releaseCount == 1)
        #expect(await ownership.state() == .restartingAVF)

        let restarted = await coordinator.avfoundationRestarted()
        #expect(restarted.phase == .idle)
        #expect(await ownership.state() == .avfoundationRunning)
    }
}
