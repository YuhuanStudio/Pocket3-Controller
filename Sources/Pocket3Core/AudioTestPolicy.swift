import Foundation

public enum AudioTestPolicy {
    public static func validateDuration(_ seconds: Double) throws {
        guard seconds.isFinite && (1...10).contains(seconds) else { throw BridgeFailure("invalid_duration", "音訊測試時間須為 1–10 秒") }
    }
    public static func acceptsPCM16(byteCount: Int, frames: Int, channels: UInt32) -> Bool {
        guard byteCount > 0 && byteCount <= 262_144, frames > 0 && frames <= 131_072,
              channels > 0 && channels <= 8 else { return false }
        return byteCount == frames * Int(channels) * MemoryLayout<Int16>.size
    }
}
