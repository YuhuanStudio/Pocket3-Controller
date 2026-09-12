import AppKit
import Foundation
import SwiftUI
import Testing
import Pocket3Core
@testable import Pocket3BridgeApp

@Suite("Exposure capability presentation")
struct ExposurePresentationTests {
    private func readback(
        mode: UInt8 = Pocket3ExposureMode.manual.rawValue,
        ev: UInt8 = 0x11,
        selectedISO: UInt8 = Pocket3ExposureISOIndex.iso100.rawValue,
        effectiveISO: UInt32 = 100,
        shutter: [UInt8] = [0x32, 0x80, 0x00]
    ) throws -> Pocket3ExposureReadback {
        var raw = Data(repeating: 0, count: 20)
        raw[1] = shutter[0]
        raw[2] = shutter[1]
        raw[3] = shutter[2]
        raw[5] = selectedISO
        raw[6] = ev
        raw[7] = mode
        raw[16] = UInt8(effectiveISO & 0xFF)
        raw[17] = UInt8((effectiveISO >> 8) & 0xFF)
        raw[18] = UInt8((effectiveISO >> 16) & 0xFF)
        raw[19] = UInt8((effectiveISO >> 24) & 0xFF)
        return try Pocket3ExposureReadback(raw: raw)
    }

    @Test func readbackPresentationKeepsUnknownSelectorsVisible() throws {
        let manual = try readback()
        #expect(ExposurePresentation.mode(manual) == "Manual exposure")
        #expect(ExposurePresentation.selectedISO(manual) == "ISO 100")
        #expect(ExposurePresentation.effectiveISO(manual) == "ISO 100")
        #expect(ExposurePresentation.shutter(manual) == "1/50")

        let unknown = try readback(mode: 0xFE, selectedISO: 0xFD,
                                   effectiveISO: 0, shutter: [0xFE, 0xAA, 0x55])
        #expect(ExposurePresentation.mode(unknown).contains("0xFE"))
        #expect(ExposurePresentation.selectedISO(unknown).contains("0xFD"))
        #expect(ExposurePresentation.effectiveISO(unknown).contains("0x00000000"))
        #expect(ExposurePresentation.shutter(unknown).contains("0xFEAA55"))
    }

    @Test func isoLimitPresentationDistinguishesUnknownRawFromMissingReadback() throws {
        let sessionID = UUID()
        let unknown = try #require(Pocket3AdvancedSettingObservation(
            sessionID: sessionID, generation: 1, receivedUptime: 10,
            setting: .isoLimit,
            payload: Data([0x00, 0x00, 0x01, 0x0F, 0x00, 0x01, 0xFE]),
            expectedValueLength: 1))
        #expect(ExposurePresentation.isoLimitValue(unknown).contains("0xFE"))
        #expect(ExposurePresentation.isoLimitValue(nil) == "No current ISO limit readback")
        #expect(ExposurePresentation.isoLimitAvailability(nil).read == false)
    }

    @MainActor @Test func expandedExposureDisclosureRendersReadOnlyWithoutBluetoothIO() async throws {
        let model = AppModel()
        model.status = await model.service.status()
        let renderer = ImageRenderer(content: BodyCapabilitySection(
            model: model, exposureExpanded: true).frame(width: 560))
        renderer.proposedSize = ProposedViewSize(width: 560, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width <= 560)
        #expect(image.size.height > 350 && image.size.height < 1_500)
        #expect(!model.wireless.bluetooth.isBluetoothInitialized)
        if ProcessInfo.processInfo.environment["POCKET3_RENDER_ARTIFACT"] == "1",
           let data = image.tiffRepresentation {
            try data.write(to: URL(fileURLWithPath: "/tmp/Pocket3ExposureDisclosure.tiff"), options: .atomic)
        }
    }
}
