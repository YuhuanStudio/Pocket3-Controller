import Foundation
import Testing
@testable import Pocket3BridgeApp

@Suite("Product setting controls")
struct ProductSettingControlsTests {
    @MainActor @Test
    func controlsRequireCommandReadyAndVerifiedWriterAdmission() {
        let model = AppModel()
        #expect(!model.nativeSettingProductControlsVisible)
        #expect(model.nativeSettingProductOptions.isEmpty)
        #expect(model.legalBodyRecordingProductFormats.isEmpty)
        #expect(!model.bodyRecordingProductWriterUnlocked)
        #expect(model.nativeSettingProductWriterEntries.count == 4)
    }
}
