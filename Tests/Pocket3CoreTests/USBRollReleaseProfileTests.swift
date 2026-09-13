import Foundation
import Testing
@testable import Pocket3Core

@Suite("USB Roll release capability profile")
struct USBRollReleaseProfileTests {
    private let profile = USBRollReleaseCapabilityProfile.pocket3Verified

    @Test func exactPocket3IdentityAndRollShapeMatchOnlyReviewedProfile() {
        let exact = USBRollCapabilities(current: 0, minimum: -30,
            maximum: 30, step: 1, defaultValue: 0, writable: true)
        #expect(profile.matches(deviceID: "0x11000002ca30023",
                                uvcVersion: 256, capabilities: exact))
        #expect(profile.matchesIdentity(deviceID: "0x11000002ca30023",
                                       uvcVersion: 256))
        #expect(profile.rawUnitsDescription.contains("physical Roll angle"))

        let identities = [
            "0x11000002ca30024", // product mismatch
            "0x11000002ca20023", // vendor mismatch
            "not-a-usb-device"
        ]
        for deviceID in identities {
            #expect(!profile.matches(deviceID: deviceID, uvcVersion: 256,
                                     capabilities: exact))
        }
        #expect(!profile.matches(deviceID: "0x11000002ca30023",
                                 uvcVersion: 255, capabilities: exact))
        #expect(!profile.matchesIdentity(deviceID: "0x11000002ca30023",
                                         uvcVersion: 255))
    }

    @Test func everyRollShapeMismatchStaysBlocked() {
        let exactID = "0x11000002ca30023"
        let mismatches = [
            USBRollCapabilities(current: 0, minimum: -31, maximum: 30,
                step: 1, defaultValue: 0, writable: true),
            USBRollCapabilities(current: 0, minimum: -30, maximum: 31,
                step: 1, defaultValue: 0, writable: true),
            USBRollCapabilities(current: 0, minimum: -30, maximum: 30,
                step: 2, defaultValue: 0, writable: true),
            USBRollCapabilities(current: 0, minimum: -30, maximum: 30,
                step: 1, defaultValue: 1, writable: true),
            USBRollCapabilities(current: 0, minimum: -30, maximum: 30,
                step: 1, defaultValue: 0, writable: false),
            USBRollCapabilities(current: 31, minimum: -30, maximum: 30,
                step: 1, defaultValue: 0, writable: true)
        ]
        for capabilities in mismatches {
            #expect(!profile.matches(deviceID: exactID, uvcVersion: 256,
                                     capabilities: capabilities))
        }
    }

    @Test func deviceIDParserPreservesOnlyVIDAndPID() {
        #expect(USBRollReleaseCapabilityProfile.vendorProduct(
            from: "0x11000002ca30023")?.vendorID == 0x2CA3)
        #expect(USBRollReleaseCapabilityProfile.vendorProduct(
            from: "0x11000002ca30023")?.productID == 0x0023)
        #expect(USBRollReleaseCapabilityProfile.vendorProduct(
            from: "invalid") == nil)
    }
}
