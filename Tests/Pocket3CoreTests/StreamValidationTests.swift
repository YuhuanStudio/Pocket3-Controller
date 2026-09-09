import CoreVideo
import Foundation
import Testing
@testable import Pocket3Core

private func streamStats() throws -> CaptureStats {
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, let pixel else { throw BridgeFailure("fixture", "No buffer") }
    let store = FrameStore(); store.reset(deviceID: "simulation"); store.receive(pixel, pts: 0)
    var stats = store.stats(); stats.recentFPS = 30; stats.age = 0.01
    return stats
}
@Test func shortStreamsCannotClaimThirtyMinuteAcceptance() throws {
    var stats = try streamStats(), report = try StreamValidationReport(seconds: 5, audio: false, initial: stats)
    for second in 1...5 { stats.frames += 30; report.record(stats, elapsed: Double(second), residentBytes: 1000) }
    report.outcome = "completed"
    #expect(report.passed)
    #expect(!report.fullAcceptanceRun)
}
@Test func fullSyntheticTimelineExercisesBothVideoAndAudioRules() throws {
    var stats = try streamStats(), report = try StreamValidationReport(seconds: 1800, audio: true, initial: stats)
    stats.audio.channels = 2; stats.audio.sampleRate = 48_000
    for second in 1...1800 {
        stats.frames += 30; stats.audio.sampleFrames += 48_000
        report.record(stats, elapsed: Double(second), residentBytes: 1000 + UInt64(second))
    }
    report.outcome = "completed"
    #expect(report.passed && report.fullAcceptanceRun)
    #expect(report.residentGrowthAfterWarmup == 1740)
    let summary = try report.json(includeSamples: false)
    #expect(summary["samples"] == .array([]) && summary["sampleCount"] == .number(1800))
}
@Test func staleFramesChangedSessionsAndStoppedAudioRemainFailures() throws {
    var stats = try streamStats(), report = try StreamValidationReport(seconds: 10, audio: true, initial: stats)
    stats.audio.channels = 2; stats.audio.sampleRate = 48_000
    stats.frames += 30; stats.audio.sampleFrames = 48_000
    report.record(stats, elapsed: 3, residentBytes: 1000)
    stats.age = 2; stats.sessionID = "replacement"; stats.recentFPS = 0
    report.record(stats, elapsed: 10, residentBytes: 1000)
    report.outcome = "completed"
    #expect(!report.passed)
    #expect(report.failures.contains("capture_session_changed"))
    #expect(report.failures.contains("stale_video_frame"))
    #expect(report.failures.contains("audio_stopped_advancing"))
    #expect(report.failures.contains("video_stopped_advancing"))
}
@Test func cancelledStreamNeverPasses() throws {
    let stats = try streamStats()
    var report = try StreamValidationReport(seconds: 1800, audio: true, initial: stats)
    report.outcome = "cancelled"
    #expect(!report.passed && !report.fullAcceptanceRun)
}

@Test func streamRateChecksFollowTheRequestedMode() throws {
    var stats = try streamStats()
    stats.frames += 30
    var highRate = try StreamValidationReport(seconds: 5, audio: false, initial: stats, frameRate: 60)
    highRate.record(stats, elapsed: 5, residentBytes: 1000)
    highRate.outcome = "completed"
    #expect(!highRate.passed)
    #expect(highRate.failures.contains("video_rate_below_expected"))
    var cinema = try StreamValidationReport(seconds: 5, audio: false, initial: stats, frameRate: 24)
    stats.recentFPS = 23.98
    cinema.record(stats, elapsed: 5, residentBytes: 1000)
    cinema.outcome = "completed"
    #expect(cinema.passed)
}
