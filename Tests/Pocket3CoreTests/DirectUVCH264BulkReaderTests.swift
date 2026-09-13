import Foundation
import Testing
@testable import Pocket3Core

private enum FakeDirectUVCBulkError: Error {
    case failed
}

private final class FakeDirectUVCBulkIO: @unchecked Sendable,
    DirectUVCBulkReaderIO {
    enum Outcome {
        case transfer(DirectUVCBulkTransfer)
        case failure
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var sizes: [Int] = []
    private var cancellations = 0
    private let blockFirstRead: Bool
    let entered = DirectUVCBulkSignal()
    let allow = DirectUVCBulkSignal()

    init(outcomes: [Outcome], blockFirstRead: Bool = false) {
        self.outcomes = outcomes
        self.blockFirstRead = blockFirstRead
    }

    var readSizes: [Int] { lock.withLock { sizes } }
    var cancelCount: Int { lock.withLock { cancellations } }

    func readBulkIn(maximumBytes: Int) async throws -> DirectUVCBulkTransfer {
        let outcome = lock.withLock { () -> Outcome in
            sizes.append(maximumBytes)
            return outcomes.isEmpty ? .failure : outcomes.removeFirst()
        }
        if blockFirstRead {
            entered.signal()
            await allow.wait()
        }
        switch outcome {
        case .transfer(let transfer): return transfer
        case .failure: throw FakeDirectUVCBulkError.failed
        }
    }

    func cancelBulkIn() async {
        lock.withLock { cancellations += 1 }
    }
}

private final class DirectUVCBulkSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    func signal() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            signaled = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if signaled { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

@Suite("Direct UVC bounded bulk reader")
struct DirectUVCH264BulkReaderTests {
    private let ownerID = UUID(uuidString: "B6A3D2E4-8D76-4D50-9B1D-8A58E4D9A901")!
    private let generation: UInt64 = 41

    private func binding() throws -> DirectUVCBulkReaderBinding {
        let negotiation = DirectUVCNegotiationResult(
            phase: "committed", requested: true, submittedCount: 4,
            committed: true,
            steps: DirectUVCNegotiator.requiredSequence.map {
                DirectUVCNegotiationStep(
                    request: $0, submitted: true, validated: true)
            })
        return try negotiation.bulkReaderBinding(
            ownerID: ownerID, generation: generation)
    }

    private func accessUnitBytes() -> Data {
        let nals = [
            Data([0x67, 0x42]),
            Data([0x68, 0xce]),
            Data([0x65, 0x88, 0x84]),
        ]
        var result = Data()
        for nal in nals {
            let length = UInt32(nal.count)
            result.append(UInt8((length >> 24) & 0xff))
            result.append(UInt8((length >> 16) & 0xff))
            result.append(UInt8((length >> 8) & 0xff))
            result.append(UInt8(length & 0xff))
            result.append(nal)
        }
        return result
    }

    private func transfer(
        flags: UInt8,
        payload: Data,
        requestedBytes: Int = 256,
        status: DirectUVCBulkTransferStatus = .complete
    ) -> DirectUVCBulkTransfer {
        DirectUVCBulkTransfer(
            requestedByteCount: requestedBytes,
            data: Data([2, flags]) + payload,
            status: status)
    }

    @Test func committedNegotiationCreatesTheOnlyBulkReaderAdmission() throws {
        let admitted = try binding()
        #expect(admitted.admission.admitted)
        #expect(admitted.admission.interfaceNumber == 1)
        #expect(admitted.admission.endpointAddress == 0x82)
        #expect(!admitted.admission.streamReady)

        let failed = DirectUVCNegotiationResult(
            phase: "failed", requested: true, submittedCount: 2,
            committed: false, failureCode: "probe_failed")
        #expect(throws: DirectUVCH264BulkReaderError.invalidAdmission) {
            try failed.bulkReaderBinding(
                ownerID: ownerID, generation: generation)
        }
    }

    @Test func readerAssemblesFragmentsAndNormalizesReadyH264() async throws {
        let bytes = accessUnitBytes()
        let split = bytes.count / 2
        let io = FakeDirectUVCBulkIO(outcomes: [
            .transfer(transfer(flags: 0, payload: Data(bytes.prefix(split)))),
            .transfer(transfer(flags: 0x02, payload: Data(bytes.dropFirst(split)))),
        ])
        let reader = try DirectUVCH264BulkReader(
            binding: try binding(), io: io, maximumTransferBytes: 256,
            maximumTransferCount: 8, maximumAccumulatorBytes: 1024)

        let first = await reader.readNext(
            ownerID: ownerID, generation: generation)
        #expect(first.state == .waitingForPayload)
        #expect(first.accessUnit == nil)
        #expect(first.payload?.fid == false)
        #expect(first.transferCount == 1)

        let second = await reader.readNext(
            ownerID: ownerID, generation: generation)
        #expect(second.state == .accessUnitReady)
        #expect(second.transferCount == 2)
        #expect(second.totalBytes == first.totalBytes +
                (2 + bytes.count - split))
        let accessUnit = try #require(second.accessUnit)
        #expect(accessUnit.data == bytes)
        #expect(accessUnit.endedByEOF)
        #expect(accessUnit.normalizedData != nil)
        #expect(accessUnit.readiness == .ready)
        #expect(accessUnit.containsIDR)
        #expect(second.decodeReady)
        #expect(io.readSizes == [256, 256])
    }

    @Test func shortTransferIsTerminalAndNeverRetried() async throws {
        let io = FakeDirectUVCBulkIO(outcomes: [
            .transfer(transfer(flags: 0x02, payload: accessUnitBytes(),
                               status: .short)),
            .transfer(transfer(flags: 0x02, payload: accessUnitBytes())),
        ])
        let reader = try DirectUVCH264BulkReader(
            binding: try binding(), io: io, maximumTransferBytes: 256,
            maximumTransferCount: 8, maximumAccumulatorBytes: 1024)

        let failed = await reader.readNext(
            ownerID: ownerID, generation: generation)
        #expect(failed.state == .failed)
        #expect(failed.failureCode == "direct_uvc_bulk_short_transfer")
        let again = await reader.readNext(
            ownerID: ownerID, generation: generation)
        #expect(again.state == .failed)
        #expect(io.readSizes == [256])
    }

    @Test func payloadErrorAndIOErrorAreTerminal() async throws {
        let payloadErrorIO = FakeDirectUVCBulkIO(outcomes: [
            .transfer(transfer(flags: 0x42, payload: accessUnitBytes())),
            .transfer(transfer(flags: 0x02, payload: accessUnitBytes())),
        ])
        let payloadReader = try DirectUVCH264BulkReader(
            binding: try binding(), io: payloadErrorIO,
            maximumTransferBytes: 256, maximumTransferCount: 8,
            maximumAccumulatorBytes: 1024)
        let payloadFailure = await payloadReader.readNext(
            ownerID: ownerID, generation: generation)
        #expect(payloadFailure.state == .failed)
        #expect(payloadFailure.failureCode == "direct_uvc_bulk_payload_error_flag")
        _ = await payloadReader.readNext(ownerID: ownerID, generation: generation)
        #expect(payloadErrorIO.readSizes == [256])

        let ioFailure = FakeDirectUVCBulkIO(outcomes: [.failure, .failure])
        let failedReader = try DirectUVCH264BulkReader(
            binding: try binding(), io: ioFailure,
            maximumTransferBytes: 256, maximumTransferCount: 8,
            maximumAccumulatorBytes: 1024)
        let first = await failedReader.readNext(
            ownerID: ownerID, generation: generation)
        #expect(first.state == .failed)
        #expect(first.failureCode == "direct_uvc_bulk_io_failed")
        _ = await failedReader.readNext(ownerID: ownerID, generation: generation)
        #expect(ioFailure.readSizes == [256])
    }

    @Test func ownerOrGenerationMismatchFencesReaderBeforeIO() async throws {
        let io = FakeDirectUVCBulkIO(outcomes: [
            .transfer(transfer(flags: 0x02, payload: accessUnitBytes()))
        ])
        let reader = try DirectUVCH264BulkReader(
            binding: try binding(), io: io, maximumTransferBytes: 256,
            maximumTransferCount: 8, maximumAccumulatorBytes: 1024)

        let failed = await reader.readNext(
            ownerID: UUID(), generation: generation)
        #expect(failed.state == .generationChanged)
        #expect(failed.failureCode == "direct_uvc_bulk_owner_mismatch")
        let again = await reader.readNext(
            ownerID: ownerID, generation: generation)
        #expect(again.state == .generationChanged)
        #expect(io.readSizes.isEmpty)
    }

    @Test func cancellationFencesAnInFlightReadAndFlushesAssembler() async throws {
        let io = FakeDirectUVCBulkIO(
            outcomes: [.transfer(transfer(flags: 0x02, payload: accessUnitBytes()))],
            blockFirstRead: true)
        let reader = try DirectUVCH264BulkReader(
            binding: try binding(), io: io, maximumTransferBytes: 256,
            maximumTransferCount: 8, maximumAccumulatorBytes: 1024)
        let task = Task {
            await reader.readNext(ownerID: ownerID, generation: generation)
        }
        await io.entered.wait()
        let cancelled = await reader.cancel()
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.failureCode == "direct_uvc_bulk_cancelled")
        io.allow.signal()
        let late = await task.value
        #expect(late.state == .cancelled)
        #expect(io.readSizes == [256])
        #expect(io.cancelCount == 1)
        #expect((await reader.status()).state == .cancelled)
    }
}
