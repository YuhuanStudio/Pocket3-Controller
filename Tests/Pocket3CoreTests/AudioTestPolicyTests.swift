import Foundation
import Testing
@testable import Pocket3Core

@Test func audioTestDurationIsFiniteAndBounded() throws {
    try AudioTestPolicy.validateDuration(1)
    try AudioTestPolicy.validateDuration(10)
    for value in [0,11,Double.nan,Double.infinity] {
        #expect(throws: BridgeFailure.self) { try AudioTestPolicy.validateDuration(value) }
    }
}
@Test func malformedPCMByteCountsCannotOverrunTheSampleBuffer() {
    #expect(AudioTestPolicy.acceptsPCM16(byteCount: 12, frames: 3, channels: 2))
    for bytes in [0,1,11,13,262_145] {
        #expect(!AudioTestPolicy.acceptsPCM16(byteCount: bytes, frames: 3, channels: 2))
    }
    #expect(!AudioTestPolicy.acceptsPCM16(byteCount: 12, frames: .max, channels: .max))
    #expect(!AudioTestPolicy.acceptsPCM16(byteCount: 12, frames: 3, channels: 0))
}
@Test func eachAudioTestStartsWithFreshCounters() {
    let store = FrameStore()
    store.receiveAudio(frames: 128, rate: 48_000, channels: 2, rms: 0.2, peak: 0.4)
    #expect(store.stats().audio.sampleFrames == 128)
    store.resetAudio()
    #expect(store.stats().audio.sampleFrames == 0 && store.stats().audio.buffers == 0)
}
