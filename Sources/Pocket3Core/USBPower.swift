import Foundation
import IOKit

public enum USBChargingState: String, Codable, Sendable {
    /// macOS USB allocation properties contain no camera battery telemetry.
    case unknown
}

public struct USBPowerStatus: Codable, Sendable {
    public let present: Bool
    /// The host's expected sink-current allocation, not measured current draw.
    public let configuredMilliamps: Int?
    public let rawPowerSinkAllocation: Int?
    public let linkBitsPerSecond: Int64?
    public let isPowerAllocationFailed: Bool?
    public let chargingState: USBChargingState
    public let source: String
    public let allocationProperty: String
    public let allocationUnitVerified: Bool
    public let propertyStability: String
    /// Present only when registry enumeration failed; absence is not a battery diagnosis.
    public let readError: String?

    init(present: Bool, configuredMilliamps: Int? = nil, linkBitsPerSecond: Int64? = nil,
         isPowerAllocationFailed: Bool? = nil, readError: String? = nil) {
        self.present = present
        self.configuredMilliamps = configuredMilliamps
        rawPowerSinkAllocation = configuredMilliamps
        self.linkBitsPerSecond = linkBitsPerSecond
        self.isPowerAllocationFailed = isPowerAllocationFailed
        chargingState = .unknown
        source = "mac_usb_allocation"
        allocationProperty = "UsbPowerSinkAllocation"
        allocationUnitVerified = true
        propertyStability = "apple_internal_registry_property_optional"
        self.readError = readError
    }
}

/// Reads registry properties only. Never opens a USB user client, selects a
/// configuration, sends a control request, or infers the camera battery state.
public enum USBPowerMonitor {
    // macOS 27 SDK, IOKit/usb/IOUSBHostFamilyDefinitions.h:
    // kUSBHostDevicePropertyPowerSinkAllocation (line 258) documents OSNumber mA
    // of current the device is expected to sink. This section is explicitly for
    // Apple internal use and its properties may change, so all values stay optional.
    // kUSBHostDevicePropertyFailedRequestedPower defines kUSBFailedRequestedPower.
    // AppleUSBDefinitions.h's kIOUSBLinkSpeed* constants express the link bitrate.
    private static let identityKeys = ["idVendor", "idProduct", "locationID"]
    private static let powerKeys = ["UsbPowerSinkAllocation", "UsbLinkSpeed", "kUSBFailedRequestedPower"]

    public static func read(location: UInt32) -> USBPowerStatus {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else {
            return USBPowerStatus(present: false, readError: "usb_registry_matching_unavailable")
        }
        var iterator: io_iterator_t = IO_OBJECT_NULL
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            if iterator != IO_OBJECT_NULL { IOObjectRelease(iterator) }
            return USBPowerStatus(present: false, readError: "usb_registry_enumeration_failed:\(result)")
        }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }
            var properties: [String: Any] = [:]
            for key in identityKeys {
                if let value = property(service, key) { properties[key] = value }
            }
            guard matches(location: location, properties: properties) else { continue }
            for key in powerKeys {
                if let value = property(service, key) { properties[key] = value }
            }
            // A disconnect or missing optional property never becomes "not charging".
            return classify(location: location, properties: properties)
                ?? USBPowerStatus(present: false, readError: "usb_registry_identity_changed")
        }
        return USBPowerStatus(present: false)
    }

    private static func property(_ service: io_service_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func matches(location: UInt32, properties: [String: Any]) -> Bool {
        integer(properties["idVendor"], maximum: UInt64(UInt16.max)) == 0x2ca3
            && integer(properties["idProduct"], maximum: UInt64(UInt16.max)) == 0x0023
            && integer(properties["locationID"], maximum: UInt64(UInt32.max)) == UInt64(location)
    }

    /// Pure interpretation for regression tests; no registry or device access.
    static func classify(location: UInt32, properties: [String: Any]) -> USBPowerStatus? {
        guard matches(location: location, properties: properties) else { return nil }
        // These are representational/parser bounds, not Pocket 3 electrical or
        // supported-link limits. Reject malformed values rather than clamp them.
        let allocation = integer(properties["UsbPowerSinkAllocation"], maximum: UInt64(UInt32.max))
        let speed = integer(properties["UsbLinkSpeed"], maximum: 1_000_000_000_000)
        return USBPowerStatus(present: true, configuredMilliamps: allocation.map(Int.init),
                              linkBitsPerSecond: speed.flatMap { $0 > 0 ? Int64($0) : nil },
                              isPowerAllocationFailed: boolean(properties["kUSBFailedRequestedPower"]))
    }

    static func integer(_ value: Any?, maximum: UInt64) -> UInt64? {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw >= 0, raw.rounded(.towardZero) == raw,
              raw <= Double(maximum), raw < Double(UInt64.max) else { return nil }
        return UInt64(raw)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
