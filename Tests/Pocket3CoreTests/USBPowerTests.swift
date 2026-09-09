import Foundation
import Testing
@testable import Pocket3Core

private let powerTestLocation: UInt32 = 0x01100000
private func cameraPowerProperties(_ values: [String: Any] = [:]) -> [String: Any] {
    var properties: [String: Any] = ["idVendor": 0x2ca3, "idProduct": 0x0023, "locationID": powerTestLocation]
    properties.merge(values) { _, replacement in replacement }
    return properties
}

@Test func usbAllocationIsNotBatteryChargingTelemetry() throws {
    let status = try #require(USBPowerMonitor.classify(location: powerTestLocation, properties: cameraPowerProperties([
        "UsbPowerSinkAllocation": 500, "UsbLinkSpeed": 480_000_000, "CurrentPowerState": 2,
    ])))
    #expect(status.present)
    #expect(status.configuredMilliamps == 500)
    #expect(status.rawPowerSinkAllocation == 500)
    #expect(status.linkBitsPerSecond == 480_000_000)
    #expect(status.chargingState == .unknown)
    #expect(status.source == "mac_usb_allocation")
    #expect(status.allocationUnitVerified)
    #expect(status.isPowerAllocationFailed == nil)
    #expect(status.propertyStability == "apple_internal_registry_property_optional")
    let encoded = try JSONEncoder().encode(status)
    let decoded = try JSONDecoder().decode(USBPowerStatus.self, from: encoded)
    #expect(decoded.chargingState == .unknown && decoded.configuredMilliamps == 500)
}

@Test func usbPowerReaderMatchesExactDJICameraAndLocation() {
    #expect(USBPowerMonitor.classify(location: powerTestLocation, properties: cameraPowerProperties()) != nil)
    let replacements: [[String: Any]] = [
        ["idVendor": 0x05ac], ["idProduct": 0x0024], ["locationID": powerTestLocation + 1],
        ["idVendor": "0x2ca3"], ["idProduct": true], ["locationID": -1],
    ]
    for replacement in replacements {
        #expect(USBPowerMonitor.classify(location: powerTestLocation, properties: cameraPowerProperties(replacement)) == nil)
    }
    #expect(USBPowerMonitor.classify(location: powerTestLocation, properties: [:]) == nil)
}

@Test func usbAllocationValuesMustBeFiniteWholeAndBounded() throws {
    for value in [0, 500, 3000, Int(UInt32.max)] {
        let status = try #require(USBPowerMonitor.classify(location: powerTestLocation,
            properties: cameraPowerProperties(["UsbPowerSinkAllocation": value])))
        #expect(status.configuredMilliamps == value)
        #expect(status.chargingState == .unknown)
    }
    let invalid: [Any] = [-1, 500.5, Double.nan, Double.infinity, Double(UInt32.max) + 1, true, "500", NSNull()]
    for value in invalid {
        let status = try #require(USBPowerMonitor.classify(location: powerTestLocation,
            properties: cameraPowerProperties(["UsbPowerSinkAllocation": value])))
        #expect(status.configuredMilliamps == nil)
        #expect(status.chargingState == .unknown)
    }
}

@Test func absentPowerPropertiesAndPowerFailureRemainBatteryUnknown() throws {
    let absent = try #require(USBPowerMonitor.classify(location: powerTestLocation, properties: cameraPowerProperties()))
    #expect(absent.configuredMilliamps == nil && absent.linkBitsPerSecond == nil)
    for value in [true, false] {
        let status = try #require(USBPowerMonitor.classify(location: powerTestLocation,
            properties: cameraPowerProperties(["kUSBFailedRequestedPower": value, "UsbPowerSinkAllocation": 0])))
        #expect(status.isPowerAllocationFailed == value)
        #expect(status.chargingState == .unknown)
    }
    let invalid: [Any] = [1, 0, "true", NSNull()]
    for value in invalid {
        let status = try #require(USBPowerMonitor.classify(location: powerTestLocation,
            properties: cameraPowerProperties(["kUSBFailedRequestedPower": value])))
        #expect(status.isPowerAllocationFailed == nil)
    }
}

@Test func usbLinkSpeedRejectsMalformedAndZeroValues() throws {
    let invalid: [Any] = [0, -1, 480_000_000.5, Double.nan, Double.infinity, 1_000_000_000_001, true, "480000000"]
    for value in invalid {
        let status = try #require(USBPowerMonitor.classify(location: powerTestLocation,
            properties: cameraPowerProperties(["UsbLinkSpeed": value])))
        #expect(status.linkBitsPerSecond == nil)
    }
}
