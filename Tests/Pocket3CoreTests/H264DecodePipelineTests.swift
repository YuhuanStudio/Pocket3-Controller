import Foundation
import Testing
@testable import Pocket3Core

@Suite("Bounded H.264 decode pipeline", .serialized)
struct H264DecodePipelineTests {
    @Test func admissionIsBoundedAndCompletionStaysOrdered() {
        var state = H264DecodePipelineState(maximumPending: 2)
        state.begin(generation: 11)
        let first = state.admit(generation: 11)
        let second = state.admit(generation: 11)
        let third = state.admit(generation: 11)

        #expect(first != nil && second != nil && third == nil)
        #expect(state.pendingCount == 2)
        #expect(state.submittedCount == 2 && state.droppedCount == 1)
        #expect(state.complete(first!) == .committed)
        #expect(state.complete(second!) == .committed)
        #expect(state.pendingCount == 0)

        // A worker is serial, so an out-of-order completion is treated as a
        // dropped result instead of silently publishing a reordered frame.
        state.begin(generation: 12)
        let orderedA = state.admit(generation: 12)!
        let orderedB = state.admit(generation: 12)!
        #expect(state.complete(orderedB) == .outOfOrder)
        #expect(state.complete(orderedA) == .committed)
        #expect(state.droppedCount == 1)
    }

    @Test func cancellationRejectsQueuedGenerationAndAllowsNextSession() {
        var state = H264DecodePipelineState(maximumPending: 4)
        state.begin(generation: 20)
        let old = state.admit(generation: 20)!
        state.cancel()

        #expect(state.pendingCount == 0)
        #expect(state.complete(old) == .stale)
        #expect(state.admit(generation: 20) == nil)

        state.begin(generation: 21)
        let current = state.admit(generation: 21)
        #expect(current != nil)
        #expect(state.complete(current!) == .committed)
    }

    @Test func sustainedSyntheticLoadNeverExceedsConfiguredPendingBound() {
        let maximum = 8
        var state = H264DecodePipelineState(maximumPending: maximum)
        state.begin(generation: 30)
        var accepted = 0
        var dropped = 0

        // Each completion represents one real sample finishing on the serial
        // worker. The loop models a bursty callback producer without creating
        // or storing image data.
        for _ in 0..<10_000 {
            if let admission = state.admit(generation: 30) {
                accepted += 1
                #expect(state.pendingCount <= maximum)
                #expect(state.complete(admission) == .committed)
            } else {
                dropped += 1
            }
        }
        #expect(accepted == 10_000)
        #expect(dropped == 0)
        #expect(state.pendingCount == 0)
    }

    @Test func frameStorePublishesSubmissionDropAndQueueLatencyMetrics() throws {
        let store = FrameStore()
        store.recordH264DecodeSubmission(accepted: true)
        store.recordH264DecodeSubmission(accepted: false)
        store.recordH264DecodeQueueLatency(seconds: 0.012)
        store.recordH264DecodeQueueLatency(seconds: 0.004)
        store.recordH264DecodeDrop()

        let diagnostics = store.sampleDiagnostics()
        #expect(diagnostics.h264DecodeSubmittedCount == 1)
        #expect(diagnostics.h264DecodeDroppedFrameCount == 2)
        #expect(diagnostics.h264DecodeQueueLatencyTotalMilliseconds == 16)
        #expect(diagnostics.h264DecodeQueueLatencyMaximumMilliseconds == 12)
        let roundTrip = try JSONDecoder().decode(CaptureSampleDiagnostics.self,
            from: JSONEncoder().encode(diagnostics))
        #expect(roundTrip == diagnostics)
    }
}
