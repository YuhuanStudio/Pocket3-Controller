import Foundation
import Testing
@testable import Pocket3Core

@Suite struct CaptureModeTests {
    @Test func hostSubtypeLabelsDoNotPretendToBeUSBWireFormats() {
        #expect(CapturePixelFormat.nv12.title == "420v host path (MJPEG UVC)")
        #expect(CapturePixelFormat.uyvy.title == "2vuy host path (H.264 UVC)")
        #expect(CapturePixelFormat.nv12.fourCC == "420v" && CapturePixelFormat.uyvy.fourCC == "2vuy")
    }
    @Test func timingNoiseDoesNotCreateDuplicateOrFractionalIntegerModes() {
        let exact = CaptureMode.default1080p30
        let advertised = CaptureMode(width: 1920, height: 1080, frameRate: 30.000030)
        #expect(exact == advertised)
        #expect(advertised.id == "1920x1080@30")
        #expect(CaptureMode.normalizedFrameRate(24.000038) == 24)
        #expect(CaptureMode.normalizedFrameRate(48.000076) == 48)
        #expect(CaptureMode.normalizedFrameRate(60.000240000960005) == 60)
        #expect(CaptureMode.normalizedFrameRate(29.97002997) == 29.97)
        #expect(CaptureMode.normalizedFrameRate(59.94) == 59.94)
        #expect(CaptureMode(width: 1920, height: 1080, frameRate: 29.97) != exact)
    }

    @Test func portraitAndFractionalRateRemainDistinctAndReadable() {
        let portrait = CaptureMode(width: 1080, height: 1920, frameRate: 29.97)
        #expect(portrait.isPortrait)
        #expect(portrait.id == "1080x1920@29.97")
        #expect(portrait.title == "1080 × 1920 · 29.97 fps")
        #expect(!CaptureMode.default1080p30.isPortrait)
    }

    @Test func formatMatchingToleratesRationalNoiseWithoutAcceptingAnotherRate() {
        let mode = CaptureMode.default1080p30
        #expect(mode.supports(minFrameRate: 30.000030, maxFrameRate: 30.000030))
        #expect(mode.supports(minFrameRate: 24, maxFrameRate: 60))
        #expect(!mode.supports(minFrameRate: 29.97, maxFrameRate: 29.97))
        #expect(!mode.supports(minFrameRate: 60, maxFrameRate: 30))
        #expect(!mode.supports(minFrameRate: .nan, maxFrameRate: 30))
    }

    @Test func fixedAndContinuousAdvertisedRangesProduceOnlySupportedRates() {
        #expect(CaptureMode.advertisedRates(minimum: 30.000030, maximum: 30.000030) == [30])
        #expect(CaptureMode.advertisedRates(minimum: 24, maximum: 30) == [24, 25, 29.97, 30])
        #expect(CaptureMode.advertisedRates(minimum: 29.97, maximum: 29.97) == [29.97])
        #expect(CaptureMode.advertisedRates(minimum: .infinity, maximum: .infinity).isEmpty)
    }

    @Test func catalogDeduplicatesPixelFormatsAndGroupsOrientations() {
        let landscape = CaptureMode.default1080p30
        let portrait = CaptureMode(width: 1080, height: 1920, frameRate: 30)
        let smaller = CaptureMode(width: 1280, height: 720, frameRate: 25)
        let noisyDuplicate = CaptureMode(width: 1920, height: 1080, frameRate: 30.000030)
        #expect(CaptureMode.uniqueSorted([portrait, landscape, noisyDuplicate, smaller]) == [smaller, landscape, portrait])
    }

    @Test func decodingCanonicalizesModesAndRejectsInvalidDimensions() throws {
        let noisy = Data(#"{"width":1920,"height":1080,"frameRate":30.000030}"#.utf8)
        #expect(try JSONDecoder().decode(CaptureMode.self, from: noisy) == .default1080p30)
        let mode = CaptureMode(width: 720, height: 1280, frameRate: 25)
        #expect(try JSONDecoder().decode(CaptureMode.self, from: JSONEncoder().encode(mode)) == mode)
        for invalid in [#"{"width":0,"height":1080,"frameRate":30}"#,
                        #"{"width":1920,"height":1080,"frameRate":0}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(CaptureMode.self, from: Data(invalid.utf8))
            }
        }
    }
}
