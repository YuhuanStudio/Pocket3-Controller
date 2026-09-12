import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 device system inventory")
struct Pocket3DeviceSystemInventoryTests {
    private func status(
        sessionID: UUID = UUID(),
        peerID: UUID = UUID(),
        paired: Bool = true,
        orientation: CameraSensorAspectRatioReadback? = nil,
        orientationUptime: TimeInterval = 100,
        storage: Pocket3StorageObservation? = nil
    ) -> BluetoothDiscoveryStatus {
        let binding = ContinuousGimbalBinding(
            sessionID: "ble:\(sessionID.uuidString)", generation: 0)
        var result = BluetoothDiscoveryStatus(
            phase: .gattPaired, sessionID: sessionID, candidates: [],
            selectedPeripheralID: peerID, issueCode: nil,
            identityVerification: "fixture", authentication: "fixture",
            fff4NotificationEnabled: true, fff5NotificationEnabled: true,
            fff4Properties: nil, fff5Properties: nil, receivedFrames: 1,
            fragments: [:],
            pairing: BluetoothPairingStatus(phase: .paired,
                peerReportedPaired: paired, credentialsAvailable: false,
                issueCode: nil))
        if let orientation {
            result.cameraSettingsObservations = [CameraSettingsObservation(
                property: .sensorAspectRatio, value: nil,
                readOnlyValue: .sensorAspectRatio(orientation),
                exposureMode: nil, transactionID: 1, binding: binding,
                receivedUptime: orientationUptime)]
        }
        result.storageStatus = storage
        return result
    }

    @Test func unknownInventoryIsExplicitAndHasNoWriterClaims() throws {
        let inventory = Pocket3DeviceSystemInventory()
        #expect(inventory.firmware.count == 3)
        #expect(inventory.preferences.count == 5)
        #expect(inventory.accessories.count == 3)
        #expect(inventory.storage.availability.read == false)
        #expect(inventory.firmware.allSatisfy { !$0.availability.read && !$0.availability.write })
        #expect(inventory.preferences.allSatisfy { !$0.availability.read && !$0.availability.write })
        #expect(inventory.accessories.allSatisfy { !$0.availability.read && !$0.availability.write })
        #expect(inventory.preferences.first(where: { $0.id == .autoPowerOff })?.evidence == [.officialOnly])
    }

    @Test func currentOrientationAndSDFactsUseFreshExactBLEObservations() throws {
        let sessionID = UUID(), peerID = UUID()
        let receivedAt = Date(timeIntervalSinceReferenceDate: 100)
        let storage = Pocket3StorageObservation(
            sessionID: sessionID, peripheralID: peerID,
            receivedAt: receivedAt, receivedUptime: 100, storeCount: 1,
            totalMiB: 488_015, freeMiB: 176_047)
        let inventory = Pocket3DeviceSystemInventory.from(
            discovery: status(sessionID: sessionID, peerID: peerID,
                orientation: .init(raw: Data([1]), rawValue: 1,
                                   aspectRatio: .portrait), storage: storage),
            nowUptime: 105)
        let orientation = try #require(inventory.preferences.first {
            $0.id == .screenOrientation
        })
        #expect(orientation.readback == .screenOrientation(.portrait))
        #expect(orientation.raw == Data([1]))
        #expect(orientation.availability.read && !orientation.availability.write)
        #expect(orientation.evidenceLevel == .localReadOnly)
        #expect(inventory.storage.present == true)
        #expect(inventory.storage.storeCountRaw == 1)
        #expect(inventory.storage.totalMiB == 488_015)
        #expect(inventory.storage.freeMiB == 176_047)
        #expect(inventory.storage.evidenceLevel == .localReadOnly)
    }

    @Test func unknownOrientationRawAndStaleOrForeignFactsNeverBecomeKnownStates() throws {
        let sessionID = UUID(), peerID = UUID()
        let unknown = Pocket3DeviceSystemInventory.from(
            discovery: status(sessionID: sessionID, peerID: peerID,
                orientation: .init(raw: Data([0xFE]), rawValue: 0xFE,
                                   aspectRatio: nil)),
            nowUptime: 105)
        let orientation = try #require(unknown.preferences.first {
            $0.id == .screenOrientation
        })
        #expect(orientation.readback == nil && orientation.raw == Data([0xFE]))
        #expect(orientation.availability.read)
        #expect(orientation.availability.reason == "Screen orientation raw selector is unknown")

        let stale = Pocket3DeviceSystemInventory.from(
            discovery: status(sessionID: sessionID, peerID: peerID,
                orientation: .init(raw: Data([1]), rawValue: 1,
                                   aspectRatio: .portrait), orientationUptime: 90),
            nowUptime: 105)
        #expect(stale.preferences.first(where: { $0.id == .screenOrientation })?.availability.read == false)

        let foreignStorage = Pocket3StorageObservation(
            sessionID: UUID(), peripheralID: peerID,
            receivedAt: Date(timeIntervalSinceReferenceDate: 100),
            receivedUptime: 100, storeCount: 1, totalMiB: 10, freeMiB: 5)
        let foreign = Pocket3DeviceSystemInventory.from(
            discovery: status(sessionID: sessionID, peerID: peerID,
                storage: foreignStorage), nowUptime: 101)
        #expect(foreign.storage.availability.read == false)
        #expect(foreign.storage.present == nil)
    }

    @Test func inventoryAndCapabilityGraphRoundTripWithoutRawInference() throws {
        let inventory = Pocket3DeviceSystemInventory()
        let graph = Pocket3CapabilityGraph(deviceInventory: inventory)
        let decodedGraph = try JSONDecoder().decode(
            Pocket3CapabilityGraph.self,
            from: JSONEncoder().encode(graph))
        #expect(decodedGraph == graph)
        let added = Pocket3CapabilityGraph().adding(deviceInventory: inventory)
        #expect(added.deviceInventory == inventory)
        #expect(added.uvcCaptureFormats.isEmpty && added.nativeSession == .disconnected)
    }
}
