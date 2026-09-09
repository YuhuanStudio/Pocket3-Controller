import Foundation
import Pocket3Core
import YunDesign

/// Keep the result, not a sentence translated at the time the test ran.
/// Both diagnostics surfaces must follow a later language change.
enum AppAudioMessage {
    case idle
    case testing
    case completed(AudioStats)
    case failed(AppErrorMessageKey)

    func formatted(localize: (String) -> String = loc) -> String {
        switch self {
        case .idle: return localize("Microphone off by default")
        case .testing: return localize("Testing audio for 3 seconds…")
        case .failed(let key): return localize(key.rawValue)
        case .completed(let stats):
            guard stats.sampleRate.isFinite, (0...Double(Int32.max)).contains(stats.sampleRate) else {
                return localize(AppErrorMessageKey.audio.rawValue)
            }
            return String(format: localize("%d channels · %d Hz · %d samples; no audio saved"),
                          stats.channels, Int(stats.sampleRate), stats.sampleFrames)
        }
    }
}
