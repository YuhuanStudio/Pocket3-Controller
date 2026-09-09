import Foundation
import Darwin

public struct StreamValidationSample: Codable, Sendable {
    public let elapsed: Double
    public let frames: Int
    public let recentFPS: Double
    public let frameAge: Double?
    public let width: Int?
    public let height: Int?
    public let audioFrames: Int
    public let audioChannels: Int
    public let audioSampleRate: Double
    public let residentBytes: UInt64
}
public struct StreamValidationReport: Codable, Sendable {
    public var version = 2
    public let id: String
    public let startedAt: Date
    public let requestedSeconds: Int
    public let includesAudio: Bool
    public let sessionID: String
    public let expectedWidth: Int
    public let expectedHeight: Int
    public let expectedFrameRate: Double
    public var outcome = "running"
    public var configurationSeconds: Double?
    public var samples: [StreamValidationSample] = []
    public var failures: [String] = []
    public var elapsedSeconds: Double { samples.last?.elapsed ?? 0 }
    public var fullAcceptanceRun: Bool { requestedSeconds >= 1800 && includesAudio && passed }
    public var passed: Bool { outcome == "completed" && elapsedSeconds >= Double(requestedSeconds) && failures.isEmpty }
    public var residentGrowthAfterWarmup: Int64? {
        guard let first = samples.first(where: { $0.elapsed >= 60 }), let last = samples.last else { return nil }
        return Int64(last.residentBytes) - Int64(first.residentBytes)
    }
    public init(seconds: Int, audio: Bool, initial: CaptureStats, frameRate: Double = 30) throws {
        guard frameRate.isFinite, frameRate > 0, (1...1800).contains(seconds), let frame = initial.frame, frame.sessionID == initial.sessionID, (initial.age ?? .infinity) <= 1 else { throw BridgeFailure("validation_input", "串流驗證需要新影格，時間須為 1–1800 秒") }
        id = UUID().uuidString; startedAt = Date()
        requestedSeconds = seconds; includesAudio = audio; sessionID = initial.sessionID
        expectedWidth = frame.width; expectedHeight = frame.height; expectedFrameRate = frameRate
    }
    public mutating func record(_ stats: CaptureStats, elapsed: Double, residentBytes: UInt64) {
        func add(_ message: String) { if !failures.contains(message) { failures.append(message) } }
        if residentBytes == 0 { add("memory_measurement_unavailable") }
        if stats.sessionID != sessionID { add("capture_session_changed") }
        if stats.frame?.width != expectedWidth || stats.frame?.height != expectedHeight { add("frame_format_changed") }
        if (stats.age ?? .infinity) > 1 { add("stale_video_frame") }
        if elapsed >= 5 && stats.recentFPS < expectedFrameRate * 0.8 { add("video_rate_below_expected") }
        if let previous = samples.last, stats.frames <= previous.frames { add("video_stopped_advancing") }
        if includesAudio && elapsed >= 3 {
            if stats.audio.channels != 2 || stats.audio.sampleRate != 48_000 { add("unexpected_audio_format") }
            if stats.audio.sampleFrames <= (samples.last?.audioFrames ?? 0) { add("audio_stopped_advancing") }
        }
        samples.append(.init(elapsed: elapsed, frames: stats.frames, recentFPS: stats.recentFPS, frameAge: stats.age, width: stats.frame?.width, height: stats.frame?.height, audioFrames: stats.audio.sampleFrames, audioChannels: stats.audio.channels, audioSampleRate: stats.audio.sampleRate, residentBytes: residentBytes))
    }
    public func json(includeSamples: Bool = true) throws -> JSONValue {
        var source = self
        if !includeSamples { source.samples = [] }
        guard case .object(var result) = try JSONValue.encode(source) else { throw BridgeFailure("validation_report", "無法建立驗證報告") }
        result["sampleCount"] = .number(Double(samples.count))
        result["latestSample"] = try samples.last.map(JSONValue.encode) ?? .null
        result["passed"] = .bool(passed); result["fullAcceptanceRun"] = .bool(fullAcceptanceRun)
        result["elapsedSeconds"] = .number(elapsedSeconds)
        result["residentGrowthAfterWarmup"] = residentGrowthAfterWarmup.map { .number(Double($0)) } ?? .null
        result["reviewRequired"] = .array([.string("memory growth and system interruptions")])
        result["memoryAssessment"] = .string("Resident growth is recorded for review; it is not by itself proof of a leak or its absence.")
        return .object(result)
    }
}
public enum ProcessMemory {
    public static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
