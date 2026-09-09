import Foundation
import Testing
@testable import Pocket3Core

private final class ZoomStopClock: ContinuousGimbalClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 10
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ time: TimeInterval) { lock.withLock { value += time } }
    func sleep(until deadline: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock { value = max(value, deadline) }
    }
}
private actor ZoomStopIO {
    let clock: ZoomStopClock
    let lifetime = OperationPermit()
    private var values: [Int]
    private let readDelay: TimeInterval
    private let readFailure: Bool
    private(set) var writes: [Int] = []
    private(set) var reads = 0
    init(clock: ZoomStopClock, values: [Int], readDelay: TimeInterval = 0, readFailure: Bool = false) {
        self.clock = clock; self.values = values; self.readDelay = readDelay; self.readFailure = readFailure
    }
    func read() throws -> USBZoomCapabilities {
        reads += 1
        if readFailure { throw BridgeFailure("zoom_read_failed", "Fake read failure") }
        clock.advance(readDelay)
        let current = values.first ?? 164
        if values.count > 1 { values.removeFirst() }
        return .init(current: current, minimum: 100, maximum: 400, step: 1, writable: true)
    }
    func write(_ value: Int, deadline: TimeInterval, permit: OperationPermit) throws {
        try lifetime.perform {
            try permit.perform {
                guard clock.now <= deadline else { throw BridgeFailure("zoom_timing", "Expired fake hold") }
                writes.append(value)
            }
        }
    }
    func invalidate() { lifetime.invalidate() }
}
private func runZoomStop(_ io: ZoomStopIO, clock: ZoomStopClock) async -> USBZoomStopResult {
    await USBZoomStopOperation.perform(read: { try await io.read() },
        write: { try await io.write($0, deadline: $1, permit: $2) }, clock: clock)
}
private func panStop(verified: Bool) -> MotionResult {
    .init(accepted: true, completed: verified, verified: verified, verification: "pan_hold",
          target: .init(pan: 6120, tilt: -29880), observed: .init(pan: 6120, tilt: -29880), message: "Pan result")
}

@Test func zoomStopHoldsFreshSlewPositionInsteadOfOriginalDestination() async {
    let clock = ZoomStopClock(), io = ZoomStopIO(clock: clock, values: [164,164,164,164])
    let result = await runZoomStop(io, clock: clock)
    #expect(result.submitted && result.verified && result.target == 164 && result.observed == 164)
    #expect(result.sampleCount >= 3)
    #expect(result.toleranceRaw == 1)
    #expect((result.stableDurationSeconds ?? 0) >= 0.8 - 1e-9)
    #expect(await io.writes == [164])
    #expect(await io.reads == result.sampleCount + 1)
}

@Test func zoomStopDoesNotClaimSuccessWhenDeviceContinuesTowardOldDestination() async {
    let clock = ZoomStopClock(), io = ZoomStopIO(clock: clock, values: [164,175,186,197,200])
    let result = await runZoomStop(io, clock: clock)
    #expect(result.submitted && !result.verified && result.target == 164 && result.observed == 200)
    #expect(result.failure == "zoom_stop_unverified")
    #expect(await io.writes == [164]) // Never repeat the SET inside verification.
}

@Test func zoomStopAcceptsRecordedOneStepQuantizationAndReportsTolerance() async {
    // Scalar replay of zoom-final: hold147, matching reads, later146. The
    // fake clock accelerates the sequence; this is not a new camera trial.
    let clock = ZoomStopClock(), io = ZoomStopIO(clock: clock, values: [147,147,147,147,146])
    let result = await runZoomStop(io, clock: clock)
    #expect(result.verified && result.target == 147 && result.observed == 146)
    #expect(result.toleranceRaw == 1)
    #expect((result.stableDurationSeconds ?? 0) >= 0.8 - 1e-9)
    #expect(await io.writes == [147])
}

@Test func zoomStopRejectsRampThatBeginsAfterThreeBrieflyMatchingSamples() async {
    let clock = ZoomStopClock(), io = ZoomStopIO(clock: clock, values: [147,147,147,147,148,148,149,150,151])
    let result = await runZoomStop(io, clock: clock)
    #expect(result.submitted && !result.verified && result.failure == "zoom_stop_unverified")
    #expect(result.toleranceRaw == 1)
    #expect(await io.writes == [147])
}

@Test func zoomStopReadFailurePreservesPanEvidenceAndMakesCombinedStopUnverified() async {
    let clock = ZoomStopClock(), io = ZoomStopIO(clock: clock, values: [], readFailure: true)
    let zoom = await runZoomStop(io, clock: clock)
    let pan = panStop(verified: true), combined = USBZoomStopResult.combining(panStop(verified: true), zoom: zoom)
    #expect(!zoom.submitted && !zoom.verified && zoom.failure == "zoom_read_failed")
    #expect(!combined.verified && !combined.completed && combined.accepted)
    #expect(combined.target == pan.target && combined.observed == pan.observed)
    #expect(combined.zoomStop == zoom)
    #expect(await io.writes.isEmpty)
}

@Test func zoomStopRejectsSlowFeedbackAndRevokedConnectionBeforeWriting() async {
    let slowClock = ZoomStopClock(), slow = ZoomStopIO(clock: slowClock, values: [164], readDelay: 0.11)
    let stale = await runZoomStop(slow, clock: slowClock)
    #expect(!stale.submitted && !stale.verified && stale.failure == "zoom_stop_feedback_stale")
    #expect(await slow.writes.isEmpty)
    let clock = ZoomStopClock(), closed = ZoomStopIO(clock: clock, values: [164])
    await closed.invalidate()
    let invalidated = await runZoomStop(closed, clock: clock)
    #expect(!invalidated.submitted && invalidated.failure == "cancelled")
    #expect(await closed.writes.isEmpty)
}

@Test func zoomStopOptionalResultPreservesNormalPanOnlyStopAndCodableCompatibility() throws {
    let pan = panStop(verified: true)
    let unchanged = USBZoomStopResult.combining(pan, zoom: nil)
    #expect(unchanged.verified && unchanged.zoomStop == nil && unchanged.id == pan.id)
    let json = try JSONEncoder().encode(pan)
    #expect(!String(decoding: json, as: UTF8.self).contains("zoomStop"))
    #expect(try JSONDecoder().decode(MotionResult.self, from: json).zoomStop == nil)
    let zoom = USBZoomStopResult(submitted: true, target: 164, observed: 164, verified: true, sampleCount: 3)
    #expect(USBZoomStopResult.combining(panStop(verified: false), zoom: zoom).verified == false)
    let complete = USBZoomStopResult.combining(pan, zoom: zoom)
    #expect(complete.verified && complete.completed)
    #expect(try JSONDecoder().decode(MotionResult.self, from: JSONEncoder().encode(complete)).zoomStop == zoom)
}
