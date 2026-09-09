import Foundation
import Testing
@testable import Pocket3Core
@testable import Pocket3BridgeApp

@Test func audioStatusUsesTheRequestedLanguageAfterItsStateWasCreated() throws {
    var stats = AudioStats()
    stats.channels = 2; stats.sampleRate = 48_000; stats.sampleFrames = 144_000
    let states: [AppAudioMessage] = [.idle, .testing, .completed(stats), .failed(.microphonePermission)]
    var messages: [[String]] = []
    for language in ["en", "zh-Hant", "zh-Hans"] {
        let url = try #require(AppResources.bundle.url(forResource: language, withExtension: "lproj"))
        let bundle = try #require(Bundle(url: url))
        messages.append(states.map { $0.formatted { bundle.localizedString(forKey: $0, value: "__MISSING__", table: "Localizable") } })
    }
    for index in states.indices {
        #expect(Set(messages.map { $0[index] }).count == 3)
        #expect(!messages.contains { $0[index].contains("__MISSING__") })
    }
    for row in messages { #expect(row[2].contains("48000") && row[2].contains("144000")) }
}

@Test func invalidAudioRateCannotCrashTheStatusPresentation() {
    for rate in [Double.nan, .infinity, -1, Double(Int64.max)] {
        var stats = AudioStats(); stats.sampleRate = rate
        #expect(AppAudioMessage.completed(stats).formatted(localize: { $0 }) == AppErrorMessageKey.audio.rawValue)
    }
}
