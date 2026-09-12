import Foundation
import Pocket3Core
import YunDesign

enum DeviceSystemInventoryPresentation {
    static func summary(_ inventory: Pocket3DeviceSystemInventory?) -> String {
        guard let inventory else { return loc("No device inventory") }
        let readable = inventory.preferences.filter { $0.availability.read }.count
        let storage = storageValue(inventory.storage)
        return "\(storage) · " + String(format: loc("%d of %d preferences readable"),
                                         readable, inventory.preferences.count)
    }

    static func firmwareTitle(_ id: Pocket3FirmwareComponentID) -> String {
        switch id {
        case .device: loc("Device firmware")
        case .camera: loc("Camera firmware")
        case .gimbal: loc("Gimbal firmware")
        }
    }

    static func preferenceTitle(_ id: Pocket3DevicePreferenceID) -> String {
        switch id {
        case .screenOrientation: loc("Screen orientation")
        case .autoPowerOff: loc("Auto Power Off")
        case .wearable: loc("Wearable")
        case .rotateAndCapture: loc("Rotate & Capture")
        case .selfieFlip: loc("Selfie Flip")
        }
    }

    static func accessoryTitle(_ id: Pocket3AccessoryID) -> String {
        switch id {
        case .djiMic2: loc("DJI Mic 2")
        case .djiMicMini: loc("DJI Mic Mini")
        case .batteryHandle: loc("Battery Handle")
        }
    }

    static func firmwareValue(_ entry: Pocket3FirmwareComponentInventory) -> String {
        entry.currentVersion ?? entry.rawVersion ?? loc("Unknown")
    }

    static func preferenceValue(_ entry: Pocket3DevicePreferenceInventory) -> String {
        guard let readback = entry.readback else {
            if let raw = entry.raw { return unknownRaw(raw) }
            return loc("Unknown")
        }
        switch readback {
        case .screenOrientation(.landscape): return loc("Landscape")
        case .screenOrientation(.portrait): return loc("Portrait")
        case .boolean(true): return loc("On")
        case .boolean(false): return loc("Off")
        }
    }

    static func storageValue(_ storage: Pocket3SDStorageInventory) -> String {
        let presence: String
        switch storage.present {
        case true: presence = loc("Present")
        case false: presence = loc("Absent")
        case nil: presence = loc("Unknown")
        }
        guard let free = storage.freeMiB, let total = storage.totalMiB else {
            return presence
        }
        let capacity = String(format: "%.1f / %.1f GB",
                              Double(free) / 1024,
                              Double(total) / 1024)
        return "\(presence) · \(capacity)"
    }

    static func accessoryValue(_ entry: Pocket3AccessoryInventory) -> String {
        entry.identity ?? loc("Unknown")
    }

    static func evidence(_ values: [Pocket3DeviceInventoryEvidence]) -> String {
        let labels = values.map { value -> String in
            switch value {
            case .officialOnly: loc("Official only")
            case .publicReverseEngineering: loc("Public reverse engineering")
            case .localParser: loc("Local parser")
            case .localObservation: loc("Local read-only observation")
            case .operatorReport: loc("Operator reported")
            case .unknown: loc("Unknown")
            }
        }
        return labels.joined(separator: " · ")
    }

    private static func unknownRaw(_ raw: Data) -> String {
        let value = raw.map { String(format: "%02X", $0) }.joined()
        return "\(loc("Unknown")) (0x\(value))"
    }
}
