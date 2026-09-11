import Foundation
import Testing
@testable import Pocket3Core

private func cameraStatusFrame(payload: Data, flags: UInt8 = 0, source: UInt8 = 1,
                               destination: UInt8 = 2, command: UInt8 = 0x80) -> DUMLFrame {
    DUMLFrame(source: source, destination: destination, sequence: 10, flags: flags,
              commandSet: 0x02, commandID: command, payload: payload)
}

@Suite struct Pocket3CameraStatusReadbackTests {
    @Test func shortStatusDecodesOnlyRecordBits() throws {
        let session = UUID(), peer = UUID(), date = Date()
        let result = try #require(Pocket3CameraStatusParser.parse(cameraStatusFrame(payload: Data([0xC1])),
            sessionID: session, peripheralID: peer, receivedAt: date, receivedUptime: 10))
        #expect(result.statusByte == 0xC1 && result.recording && result.transitioning)
        #expect(result.sessionID == session && result.peripheralID == peer && result.receivedAt == date)
        #expect(result.shootingMode == nil && result.storageTotalMiB == nil && result.remainingRecordSeconds == nil)
    }

    @Test func extendedStatusUsesCaptureConfirmedOffsetsAndKnownMode() throws {
        var payload = Data(repeating: 0, count: 58)
        payload[0] = 0x81; payload[4] = 1
        payload.replaceSubrange(5...8, with: [0x00, 0x00, 0x02, 0x00])
        payload.replaceSubrange(9...12, with: [0x00, 0x00, 0x01, 0x00])
        payload.replaceSubrange(17...18, with: [0x1A, 0x04])
        payload.replaceSubrange(29...30, with: [0x2A, 0x00])
        payload[57] = Pocket3ShootingMode.video.rawValue
        let result = try #require(Pocket3CameraStatusParser.parse(cameraStatusFrame(payload: payload),
            sessionID: UUID(), peripheralID: UUID(), receivedAt: Date(), receivedUptime: 2))
        #expect(result.recording && !result.transitioning && result.videoLike == true)
        #expect(result.storageTotalMiB == 131_072 && result.storageFreeMiB == 65_536)
        #expect(result.remainingRecordSeconds == 1_050 && result.elapsedRecordSeconds == 42)
        #expect(result.shootingModeRaw == 1 && result.shootingMode == .video)
    }

    @Test func unknownModeAndPhotoPreserveRawWithoutInventingRemainingTime() throws {
        var payload = Data(repeating: 0, count: 58)
        payload[0] = 1; payload[57] = 0xFE
        payload[17] = 0xFF; payload[18] = 0xFF
        let result = try #require(Pocket3CameraStatusParser.parse(cameraStatusFrame(payload: payload),
            sessionID: UUID(), peripheralID: UUID(), receivedAt: Date(), receivedUptime: 2))
        #expect(result.shootingModeRaw == 0xFE && result.shootingMode == nil)
        #expect(result.videoLike == false && result.remainingRecordSeconds == nil)
    }

    @Test func independentStorageUsesConfirmedOffsetsAndStrictRoute() throws {
        var payload = Data(repeating: 0, count: 22)
        payload[2] = 1
        payload.replaceSubrange(6...9, with: [0x00, 0x00, 0x02, 0x00])
        payload.replaceSubrange(10...13, with: [0x00, 0x00, 0x01, 0x00])
        let session = UUID(), peer = UUID()
        let frame = cameraStatusFrame(payload: payload, command: 0xDC)
        let result = try #require(Pocket3CameraStatusParser.parseStorage(frame, sessionID: session,
            peripheralID: peer, receivedAt: Date(), receivedUptime: 10))
        #expect(result.storeCount == 1 && result.totalMiB == 131_072 && result.freeMiB == 65_536)
        #expect(result.isFresh(nowUptime: 15) && !result.isFresh(nowUptime: 15.01))
        #expect(Pocket3CameraStatusParser.parseStorage(cameraStatusFrame(payload: payload, flags: 0x80, command: 0xDC),
            sessionID: session, peripheralID: peer, receivedAt: Date(), receivedUptime: 10) == nil)
        #expect(Pocket3CameraStatusParser.parseStorage(cameraStatusFrame(payload: payload.dropLast(), command: 0xDC),
            sessionID: session, peripheralID: peer, receivedAt: Date(), receivedUptime: 10) == nil)
    }

    @Test func wrongRouteRepliesAndInvalidTimesAreIgnored() {
        let payload = Data([1]), session = UUID(), peer = UUID(), date = Date()
        for frame in [cameraStatusFrame(payload: payload, flags: 0x80),
                      cameraStatusFrame(payload: payload, source: 2),
                      cameraStatusFrame(payload: payload, destination: 1),
                      cameraStatusFrame(payload: payload, command: 0x81),
                      cameraStatusFrame(payload: Data())] {
            #expect(Pocket3CameraStatusParser.parse(frame, sessionID: session, peripheralID: peer,
                receivedAt: date, receivedUptime: 1) == nil)
        }
        #expect(Pocket3CameraStatusParser.parse(cameraStatusFrame(payload: payload), sessionID: session,
            peripheralID: peer, receivedAt: date, receivedUptime: .nan) == nil)
    }

    @Test func freshnessRejectsFutureStaleAndInvalidClocks() throws {
        let result = try #require(Pocket3CameraStatusParser.parse(cameraStatusFrame(payload: Data([1])),
            sessionID: UUID(), peripheralID: UUID(), receivedAt: Date(), receivedUptime: 10))
        #expect(result.isFresh(nowUptime: 10) && result.isFresh(nowUptime: 15))
        #expect(!result.isFresh(nowUptime: 15.001) && !result.isFresh(nowUptime: 9.9))
        #expect(!result.isFresh(nowUptime: .nan) && !result.isFresh(nowUptime: 10, maximumAge: -1))
    }

    @Test func legacyBluetoothStatusJSONDefaultsCameraStatusToNil() throws {
        let original = BluetoothDiscoveryStatus(phase: .idle, sessionID: UUID(), candidates: [],
            selectedPeripheralID: nil, issueCode: nil, identityVerification: "fixture",
            authentication: "not_performed", fff4NotificationEnabled: false,
            fff5NotificationEnabled: false, fff4Properties: nil, fff5Properties: nil,
            receivedFrames: 0, fragments: [:])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        object.removeValue(forKey: "cameraStatus")
        let decoded = try JSONDecoder().decode(BluetoothDiscoveryStatus.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.cameraStatus == nil)
    }
}
