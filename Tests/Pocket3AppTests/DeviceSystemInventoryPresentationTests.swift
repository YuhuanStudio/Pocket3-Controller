import AppKit
import Foundation
import SwiftUI
import Testing
import Pocket3Core
@testable import Pocket3BridgeApp

@Suite("Device system inventory presentation")
struct DeviceSystemInventoryPresentationTests {
    @Test func unknownEvidenceAndReadbackReasonsStayDistinct() {
        let inventory = Pocket3DeviceSystemInventory()
        #expect(DeviceSystemInventoryPresentation.summary(inventory)
            .contains("0 of 5 preferences readable"))
        #expect(DeviceSystemInventoryPresentation.firmwareTitle(.camera) == "Camera firmware")
        #expect(DeviceSystemInventoryPresentation.preferenceTitle(.rotateAndCapture) == "Rotate & Capture")
        #expect(DeviceSystemInventoryPresentation.accessoryTitle(.batteryHandle) == "Battery Handle")
        #expect(DeviceSystemInventoryPresentation.storageValue(inventory.storage) == "Unknown")
        #expect(DeviceSystemInventoryPresentation.evidence([.officialOnly]) == "Official only")
    }

    @Test func knownOrientationAndCapacityFormattingPreservesRawFacts() throws {
        let preference = Pocket3DevicePreferenceInventory(
            id: .screenOrientation,
            readback: .screenOrientation(.portrait), raw: Data([1]),
            availability: .readOnly, evidence: [.localObservation])
        #expect(DeviceSystemInventoryPresentation.preferenceValue(preference) == "Portrait")

        let storage = Pocket3SDStorageInventory(
            present: true, storeCountRaw: 1, totalMiB: 488_015,
            freeMiB: 176_047, availability: .readOnly,
            evidence: [.localObservation])
        #expect(DeviceSystemInventoryPresentation.storageValue(storage)
            == "Present · 171.9 / 476.6 GB")

        let unknown = Pocket3DevicePreferenceInventory(
            id: .screenOrientation, raw: Data([0xFE]),
            availability: .init(read: true,
                                reason: "Screen orientation raw selector is unknown"),
            evidence: [.localObservation])
        #expect(DeviceSystemInventoryPresentation.preferenceValue(unknown)
            .contains("0xFE"))
    }

    @MainActor @Test func expandedInventoryDisclosureRendersWithoutHardwareOrFooterChanges() async throws {
        let model = AppModel()
        model.status = await model.service.status()
        let renderer = ImageRenderer(content: BodyCapabilitySection(
            model: model, deviceInventoryExpanded: true).frame(width: 560))
        renderer.proposedSize = ProposedViewSize(width: 560, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width <= 560)
        #expect(image.size.height > 650 && image.size.height < 1_800)
        #expect(!model.wireless.bluetooth.isBluetoothInitialized)
        if ProcessInfo.processInfo.environment["POCKET3_RENDER_ARTIFACT"] == "1",
           let data = image.tiffRepresentation {
            try data.write(to: URL(fileURLWithPath: "/tmp/Pocket3DeviceSystemInventory.tiff"), options: .atomic)
        }
    }
}
