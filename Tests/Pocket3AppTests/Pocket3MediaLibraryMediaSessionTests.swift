import Foundation
import SwiftUI
import Testing
@testable import Pocket3BridgeApp
import Pocket3Core

@Suite("Pocket 3 media library session presentation")
struct Pocket3MediaLibraryMediaSessionTests {
    private func identity(_ sessionID: UUID = UUID(),
                          generation: UInt64 = 3,
                          peripheralID: UUID = UUID())
        throws -> Pocket3MediaSessionIdentity {
        try Pocket3MediaSessionIdentity(sessionID: sessionID,
                                         generation: generation,
                                         peripheralID: peripheralID)
    }

    private func route() -> Pocket3DatalinkRouteStatus {
        Pocket3DatalinkRouteStatus(state: .interfaceBound,
            interfaceName: "en0", interfaceIndex: 4,
            cameraRouteReachable: true, samePrimaryRoute: true,
            defaultRouteChanged: false, evidence: "media_session_fixture")
    }

    private func playbackObservation(
        identity: Pocket3MediaSessionIdentity,
        receivedUptime: TimeInterval
    ) throws -> Pocket3MediaSessionObservation {
        var payload = Data(repeating: 0, count: 13)
        payload[0] = 0x01
        payload[3] = 0x40
        put(8192, into: &payload, at: 5)
        put(4096, into: &payload, at: 9)
        let readback = try Pocket3MediaSessionReadback(raw: payload)
        return try Pocket3MediaSessionObservation(
            sessionID: identity.sessionID,
            peripheralID: identity.peripheralID,
            generation: identity.generation,
            receivedUptime: receivedUptime,
            readback: readback)
    }

    private func put(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    @Test func metadataModelCarriesFreshPlaybackAndActiveStoreEvidence()
        throws {
        let identity = try identity()
        let now = ProcessInfo.processInfo.systemUptime
        let observation = try playbackObservation(identity: identity,
                                                  receivedUptime: now)
        var model = Pocket3MediaLibraryModel()

        let applied = model.applyMediaSession(observation,
            expectedIdentity: identity, routeStatus: route(), nowUptime: now)
        #expect(applied)
        #expect(model.mediaSession == observation)
        #expect(model.mediaState == .playback)
        #expect(model.mediaStateIsFresh)
        #expect(model.activeStoreTotalMiB == 8192)
        #expect(model.activeStoreFreeMiB == 4096)
        #expect(model.rows.isEmpty)
    }

    @Test func changedMediaIdentityCannotReuseTypedState() throws {
        let currentIdentity = try identity()
        let now = ProcessInfo.processInfo.systemUptime
        let observation = try playbackObservation(identity: currentIdentity,
                                                  receivedUptime: now)
        var model = Pocket3MediaLibraryModel()
        let applied = model.applyMediaSession(observation,
            expectedIdentity: currentIdentity, routeStatus: route(), nowUptime: now)
        #expect(applied)

        let newer = try identity(generation: currentIdentity.generation + 1)
        let rejected = model.applyMediaSession(observation,
            expectedIdentity: newer, routeStatus: route(), nowUptime: now)
        #expect(!rejected)
        #expect(model.lastFailureCode == "media_library_media_session_mismatch")
        #expect(model.mediaSession == observation)
    }

    @Test func validationSnapshotRoundTripsTypedMediaSession() throws {
        let identity = try identity()
        let now = ProcessInfo.processInfo.systemUptime
        let observation = try playbackObservation(identity: identity,
                                                  receivedUptime: now)
        let session = NativeCameraSessionStatus(state: .commandReady,
            generation: identity.generation, sessionID: identity.sessionID,
            peerID: identity.peripheralID)
        let snapshot = NativeMediaValidationSnapshot(
            session: session, routeStatus: route(), nowUptime: now,
            mediaSession: observation)
        #expect(snapshot.currentMediaSession == observation)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(
            NativeMediaValidationSnapshot.self, from: data) == snapshot)
    }

    @Test @MainActor func disclosureBuildsWithTypedStateAndNoMediaBytes()
        throws {
        let identity = try identity()
        let now = ProcessInfo.processInfo.systemUptime
        let observation = try playbackObservation(identity: identity,
                                                  receivedUptime: now)
        var model = Pocket3MediaLibraryModel()
        _ = model.applyMediaSession(observation,
            expectedIdentity: identity, routeStatus: route(), nowUptime: now)
        let disclosure = Pocket3MediaLibraryDiagnostics(model: .constant(model))
        _ = disclosure.body
        #expect(model.mediaState == .playback)
        #expect(model.activeStoreTotalMiB == 8192)
        #expect(model.activeStoreFreeMiB == 4096)
    }
}
