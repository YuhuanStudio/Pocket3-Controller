import Foundation
import Testing
@testable import Pocket3Core

@Suite struct CaptureCallbackFenceTests {
    @Test func queuedOldVideoOutputCannotEnterOrCommitAfterStoreReset() throws {
        let fence = CaptureCallbackFence(), store = FrameStore(), oldOutput = NSObject()
        let generation = fence.advance()
        store.reset(deviceID: "old-fixture")
        _ = try #require(fence.activate(output: ObjectIdentifier(oldOutput), kind: .video, generation: generation))
        let callback = try #require(fence.begin(output: ObjectIdentifier(oldOutput)))
        let oldSession = store.stats().sessionID
        fence.invalidateAll { store.reset(deviceID: "new-fixture") }
        let accepted = fence.commit(callback) {
            store.recordVideoSample(hasImageBuffer: false, hasBlockBuffer: true, mediaSubType: nil, inputMediaSubType: nil)
        }
        #expect(!accepted)
        #expect(fence.begin(output: ObjectIdentifier(oldOutput)) == nil)
        #expect(store.stats().sessionID != oldSession)
        #expect(store.sampleDiagnostics().videoSampleCount == 0 && store.stats().frames == 0)
    }

    @Test func reconnectRequiresBothTheOutputIdentityAndNewGeneration() throws {
        let fence = CaptureCallbackFence(), first = NSObject(), second = NSObject()
        let oldGeneration = fence.advance()
        let old = try #require(fence.activate(output: ObjectIdentifier(first), kind: .video, generation: oldGeneration))
        let newGeneration = fence.advance()
        let current = try #require(fence.activate(output: ObjectIdentifier(second), kind: .video, generation: newGeneration))
        var commits = 0
        let oldAccepted = fence.commit(old) { commits += 1 }
        let currentAccepted = fence.commit(current) { commits += 1 }
        #expect(!oldAccepted && currentAccepted && commits == 1)
        #expect(fence.begin(output: ObjectIdentifier(first)) == nil)
        #expect(fence.begin(output: ObjectIdentifier(second)) == current)
        var prepared = false
        let staleActivation = fence.activate(output: ObjectIdentifier(first), kind: .video, generation: oldGeneration) { prepared = true }
        #expect(staleActivation == nil && !prepared)
        #expect(fence.begin(output: ObjectIdentifier(second)) == current)
    }

    @Test func oldAudioCannotContaminateCountersAfterAudioReenableInSameSession() throws {
        let fence = CaptureCallbackFence(), store = FrameStore()
        let video = NSObject(), oldAudio = NSObject(), newAudio = NSObject()
        let generation = fence.advance()
        let videoBinding = try #require(fence.activate(output: ObjectIdentifier(video), kind: .video, generation: generation))
        let old = try #require(fence.activate(output: ObjectIdentifier(oldAudio), kind: .audio, generation: generation))
        fence.commit(old) { store.receiveAudio(frames: 64, rate: 48000, channels: 2, rms: 0, peak: 0) }
        fence.invalidate(.audio)
        let current = try #require(fence.activate(output: ObjectIdentifier(newAudio), kind: .audio, generation: generation) { store.resetAudio() })
        let oldAccepted = fence.commit(old) { store.receiveAudio(frames: 64, rate: 48000, channels: 2, rms: 0, peak: 0) }
        let newAccepted = fence.commit(current) { store.receiveAudio(frames: 128, rate: 48000, channels: 2, rms: 0, peak: 0) }
        var videoCommits = 0
        let videoAccepted = fence.commit(videoBinding) { videoCommits += 1 }
        #expect(!oldAccepted && newAccepted && videoAccepted && videoCommits == 1)
        #expect(fence.begin(output: ObjectIdentifier(oldAudio)) == nil)
        #expect(store.stats().audio.sampleFrames == 128 && store.stats().audio.buffers == 1)
        #expect(fence.currentGeneration() == generation)
    }

    @Test func reactivatingAnIdentityStillInvalidatesAlreadyProcessingCallbackToken() throws {
        let fence = CaptureCallbackFence(), output = NSObject()
        let generation = fence.advance()
        let old = try #require(fence.activate(output: ObjectIdentifier(output), kind: .audio, generation: generation))
        fence.invalidate(.audio)
        let current = try #require(fence.activate(output: ObjectIdentifier(output), kind: .audio, generation: generation))
        var commits = 0
        let oldAccepted = fence.commit(old) { commits += 1 }
        let currentAccepted = fence.commit(current) { commits += 1 }
        #expect(old.activation != current.activation)
        #expect(!oldAccepted && currentAccepted && commits == 1)
    }

    @Test func lifecycleAdvanceRejectsTheFinalCommitAfterMetadataProcessing() throws {
        let fence = CaptureCallbackFence(), output = NSObject()
        let oldGeneration = fence.advance()
        let processing = try #require(fence.activate(output: ObjectIdentifier(output), kind: .video, generation: oldGeneration))
        _ = fence.advance() // Simulates Stop during AVF getter / PCM computation.
        var writes = 0
        let accepted = fence.commit(processing) { writes += 1 }
        let resetAccepted = fence.whileCurrent(oldGeneration) { writes += 1 }
        #expect(!accepted && !resetAccepted && writes == 0)
    }

    @Test func finalCommitAndResetAreSerializedByTheSameLifecycleLock() throws {
        let fence = CaptureCallbackFence(), output = NSObject(), events = FenceEvents()
        let generation = fence.advance()
        let callback = try #require(fence.activate(output: ObjectIdentifier(output), kind: .video, generation: generation))
        let entered = DispatchSemaphore(value: 0), allowCommit = DispatchSemaphore(value: 0)
        let commitFinished = DispatchSemaphore(value: 0), resetStarted = DispatchSemaphore(value: 0), resetFinished = DispatchSemaphore(value: 0)
        defer { allowCommit.signal() }
        DispatchQueue.global().async {
            fence.commit(callback) {
                events.append("commit-start")
                entered.signal()
                _ = allowCommit.wait(timeout: .now() + 2)
                events.append("commit-end")
            }
            commitFinished.signal()
        }
        guard entered.wait(timeout: .now() + 1) == .success else { throw FenceTestError.timeout }
        DispatchQueue.global().async {
            resetStarted.signal()
            fence.invalidateAll { events.append("reset") }
            resetFinished.signal()
        }
        guard resetStarted.wait(timeout: .now() + 1) == .success else { throw FenceTestError.timeout }
        // Reset must wait while the already-validated final store commit runs.
        let prematureReset = resetFinished.wait(timeout: .now() + 0.02)
        #expect(prematureReset == .timedOut)
        allowCommit.signal()
        guard commitFinished.wait(timeout: .now() + 1) == .success else { throw FenceTestError.timeout }
        if prematureReset == .timedOut {
            guard resetFinished.wait(timeout: .now() + 1) == .success else { throw FenceTestError.timeout }
        }
        #expect(events.snapshot() == ["commit-start", "commit-end", "reset"])
        var lateWrites = 0
        let lateAccepted = fence.commit(callback) { lateWrites += 1 }
        #expect(!lateAccepted && lateWrites == 0)
    }
}

private enum FenceTestError: Error { case timeout }
private final class FenceEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    func snapshot() -> [String] { lock.withLock { values } }
}
