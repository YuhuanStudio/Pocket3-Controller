import Foundation
import Testing
@testable import Pocket3Core
@testable import Pocket3BridgeApp

private func cameraObservation(mode: Pocket3ShootingMode? = .video, raw: UInt8 = 1,
    recording: Bool = false, transitioning: Bool = false, videoLike: Bool? = true,
    total: UInt32? = 131_072, free: UInt32? = 65_536,
    remaining: UInt16? = 3_661, elapsed: UInt16? = 42) -> Pocket3CameraStatusObservation {
    .init(sessionID: UUID(), peripheralID: UUID(), receivedAt: Date(), receivedUptime: 1,
        statusByte: recording ? 0x81 : transitioning ? 0x41 : 0x01,
        recording: recording, transitioning: transitioning, videoLike: videoLike,
        shootingModeRaw: raw, shootingMode: mode, storageTotalMiB: total,
        storageFreeMiB: free, remainingRecordSeconds: remaining, elapsedRecordSeconds: elapsed)
}

@Suite struct BluetoothCameraStatusPresentationTests {
    @Test func knownAndUnknownModesRemainDistinct() {
        #expect(BluetoothCameraStatusPresentation.mode(cameraObservation()) != "0x01")
        #expect(BluetoothCameraStatusPresentation.mode(cameraObservation(mode: nil, raw: 0xFE)) == "0xFE")
    }
    @Test func recordTransitionsAreNotPresentedAsCompletedRecording() {
        let idle = BluetoothCameraStatusPresentation.recordState(cameraObservation())
        let recording = BluetoothCameraStatusPresentation.recordState(cameraObservation(recording: true))
        let changing = BluetoothCameraStatusPresentation.recordState(cameraObservation(recording: false, transitioning: true))
        #expect(!idle.isEmpty && !recording.isEmpty && !changing.isEmpty)
        #expect(idle != recording && recording != changing && idle != changing)
    }
    @Test func storageAndDurationsUseDeviceUnitsWithoutGuessing() {
        #expect(BluetoothCameraStatusPresentation.storage(cameraObservation()) == "64.0 / 128.0 GB")
        #expect(BluetoothCameraStatusPresentation.storage(cameraObservation(total: nil, free: nil)) == "—")
        #expect(BluetoothCameraStatusPresentation.duration(3_661) == "01:01:01")
        #expect(BluetoothCameraStatusPresentation.duration(nil) == "—")
        let independent = Pocket3StorageObservation(sessionID: UUID(), peripheralID: UUID(),
            receivedAt: Date(), receivedUptime: 1, storeCount: 1, totalMiB: 256_000, freeMiB: 128_000)
        #expect(BluetoothCameraStatusPresentation.storage(cameraObservation(), independent: independent) == "125.0 / 250.0 GB")
    }
}
