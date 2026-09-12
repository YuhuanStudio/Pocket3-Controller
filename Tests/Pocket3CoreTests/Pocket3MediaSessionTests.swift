import Foundation
import Testing
@testable import Pocket3Core

private final class Pocket3MediaSessionCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("Pocket 3 media session readback")
struct Pocket3MediaSessionTests {
    private let sessionID = UUID()
    private let peerID = UUID()

    private func readySession(generation: UInt64 = 3)
        -> NativeCameraSessionStatus {
        NativeCameraSessionStatus(state: .commandReady, generation: generation,
                                  sessionID: sessionID, peerID: peerID)
    }

    private func statusFrame(_ payload: Data) -> DUMLFrame {
        DUMLFrame(source: 0x01, destination: 0x02, sequence: 0x2201,
                  flags: 0, commandSet: 0x02, commandID: 0x80,
                  payload: payload)
    }

    private func playbackPayload(_ playback: Bool,
                                 statusByte: UInt8 = 0x01) -> Data {
        var payload = Data(repeating: 0, count: 13)
        payload[0] = statusByte
        if playback { payload[3] = 0x40 }
        put(2048, into: &payload, at: 5)
        put(1024, into: &payload, at: 9)
        return payload
    }

    private func put(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private func transaction(
        for request: NativeCommandTransactionRequest,
        observedPayload: Data? = nil,
        end: NativeCommandTransactionEnd = .acknowledged
    ) -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(
            id: request.id, command: request.command,
            generation: request.generation, sessionID: request.sessionID,
            end: end)
        result.sequence = 0x2201
        result.submitted = true
        result.submittedUptime = 11
        result.responseReceived = true
        result.acknowledged = true
        result.acknowledgedUptime = 11.01
        result.observedPayload = observedPayload
        result.observed = observedPayload != nil
        result.observedUptime = observedPayload == nil ? nil : 11.02
        result.finishedUptime = 11.03
        return result
    }

    private func snapshot(
        _ session: NativeCameraSessionStatus,
        mediaSession: Pocket3MediaSessionObservation? = nil,
        nowUptime: TimeInterval = 12
    ) -> NativeMediaValidationSnapshot {
        NativeMediaValidationSnapshot(session: session, nowUptime: nowUptime,
                                      mediaSession: mediaSession)
    }

    @Test func decodesPlaybackFlagAndActiveStoreWithoutDroppingRawBytes()
        throws {
        let payload = playbackPayload(true)
        let readback = try Pocket3MediaSessionReadback(raw: payload)

        #expect(readback.raw == payload)
        #expect(readback.flagsRaw == 0x4000_0001)
        #expect(readback.playbackBitRaw == 1)
        #expect(readback.playback == true)
        #expect(readback.activeStoreTotalMiB == 2048)
        #expect(readback.activeStoreFreeMiB == 1024)
        #expect(readback.state == .playback)

        let unknown = try Pocket3MediaSessionReadback(raw: Data([0x22, 0, 0, 0]))
        #expect(unknown.state == .unknown(raw: 0x22))
        #expect(unknown.flagsRaw == 0x22)
        #expect(unknown.raw == Data([0x22, 0, 0, 0]))
    }

    @Test func cameraStatusParserCarriesTypedMediaFlags() throws {
        var payload = Data(repeating: 0, count: 58)
        payload[0] = 0x01
        payload[3] = 0x40
        payload[4] = 0x01
        put(4096, into: &payload, at: 5)
        put(3000, into: &payload, at: 9)
        payload[57] = Pocket3ShootingMode.video.rawValue
        let frame = statusFrame(payload)
        let observation = try #require(Pocket3CameraStatusParser.parse(
            frame, sessionID: sessionID, peripheralID: peerID,
            receivedAt: Date(timeIntervalSinceReferenceDate: 100),
            receivedUptime: 10))

        #expect(observation.statusFlagsRaw == 0x4000_0001)
        #expect(observation.playbackBit == true)
        #expect(observation.mediaSessionState == .playback)
        #expect(observation.storageTotalMiB == 4096)
        #expect(observation.storageFreeMiB == 3000)
        #expect(observation.recordingLifecycle == .idle)
    }

    @Test func mediaObservationFencesSessionGenerationAndFreshness() throws {
        let readback = try Pocket3MediaSessionReadback(
            raw: playbackPayload(true))
        let observation = try Pocket3MediaSessionObservation(
            sessionID: sessionID, peripheralID: peerID, generation: 3,
            receivedUptime: 10, readback: readback)
        let session = readySession()

        #expect(observation.isFresh(nowUptime: 12))
        #expect(observation.isFresh(session: session, nowUptime: 12))
        #expect(!observation.isFresh(session: readySession(generation: 4),
                                     nowUptime: 12))
        #expect(!observation.isFresh(session: NativeCameraSessionStatus(
            state: .disconnected, generation: 3,
            sessionID: sessionID, peerID: peerID), nowUptime: 12))
        #expect(!observation.isFresh(nowUptime: 16))
    }

    @Test func presenceHoldStateTracksLifecycleWithoutTransportSideEffects()
        throws {
        let identity = try Pocket3MediaSessionIdentity(
            sessionID: sessionID, generation: 3, peripheralID: peerID)
        var hold = try Pocket3MediaPresenceHoldState(identity: identity,
                                                       interval: 1)
        #expect(hold.lifecycle == .idle && !hold.isFresh(nowUptime: 1))
        let began = hold.begin(at: 10)
        #expect(began)
        #expect(hold.lifecycle == .holding && hold.isFresh(nowUptime: 11))
        let beat = hold.beat(at: 11)
        #expect(beat)
        let reversedBeat = hold.beat(at: 10)
        #expect(!reversedBeat)
        let expired = hold.expire(at: 13, maximumAge: 1.5)
        #expect(expired)
        #expect(hold.lifecycle == .expired &&
                !hold.isFresh(nowUptime: 13))

        var cancelled = try Pocket3MediaPresenceHoldState(identity: identity)
        let cancelBegan = cancelled.begin(at: 20)
        let didCancel = cancelled.cancel()
        #expect(cancelBegan && didCancel)
        #expect(cancelled.lifecycle == .cancelled)
        let cancelledAgain = cancelled.cancel()
        #expect(!cancelledAgain)
    }

    @Test func olderListPagesExplicitlyRequireFreshPlayback() throws {
        let identity = try Pocket3MediaSessionIdentity(
            sessionID: sessionID, generation: 3, peripheralID: peerID)
        let readback = try Pocket3MediaSessionReadback(
            raw: playbackPayload(true))
        let playback = try Pocket3MediaSessionObservation(
            sessionID: sessionID, peripheralID: peerID, generation: 3,
            receivedUptime: 10, readback: readback)
        let old = try Pocket3MediaListRequest(identity: identity, counter: 1,
                                               cursor: 0x4000_0002)
        let newest = try Pocket3MediaListRequest(
            identity: identity, counter: 1,
            cursor: Pocket3MediaListRequest.newestSD)

        #expect(old.requiresPlayback)
        #expect(!newest.requiresPlayback)
        #expect(!old.isAllowed(mediaSession: nil, nowUptime: 12))
        #expect(old.isAllowed(mediaSession: playback, nowUptime: 12))
        #expect(!old.isAllowed(mediaSession: playback, nowUptime: 16))
        #expect(newest.isAllowed(mediaSession: nil, nowUptime: 0))
        #expect(!Pocket3MediaListPlaybackPolicy.allows(
            cursor: old.cursor, session: nil))
    }

    @Test func playbackTerminalNeedsAckAndMatchingFreshStatus() async throws {
        let session = readySession()
        let enter = try NativeMediaValidationRequest(
            action: .playbackEnter, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation, execute: true)
        let counter = Pocket3MediaSessionCallCounter()
        let enterAdapter = NativeMediaValidationExecutorAdapter {
            request, _ in
            counter.increment()
            let observe = try #require(request.observationHandler())
            #expect(observe(self.statusFrame(Data([0, 0]))) == Data([0, 0]))
            let payload = self.playbackPayload(true)
            #expect(observe(self.statusFrame(payload)) == payload)
            return self.transaction(for: request, observedPayload: payload,
                                    end: .observed)
        }
        let entered = try await NativeMediaValidationService(
            adapter: enterAdapter).run(enter, snapshot: snapshot(session))
        #expect(counter.count == 1)
        #expect(entered.completed && entered.phase == .completed)
        #expect(entered.mediaSessionReadback?.state == .playback)
        #expect(entered.playbackObservation?.generation == session.generation)

        let ackOnlyAdapter = NativeMediaValidationExecutorAdapter {
            request, _ in
            self.transaction(for: request)
        }
        let ackOnly = try await NativeMediaValidationService(
            adapter: ackOnlyAdapter).run(enter, snapshot: snapshot(session))
        #expect(ackOnly.acknowledged && !ackOnly.observed)
        #expect(!ackOnly.completed && ackOnly.phase == .awaitingReadback)
        #expect(ackOnly.failureCode == "native_media_playback_readback_missing")

        let wrongStateAdapter = NativeMediaValidationExecutorAdapter {
            request, _ in
            let payload = Data([0x41, 0, 0, 0])
            return self.transaction(for: request, observedPayload: payload,
                                    end: .observed)
        }
        let wrongState = try await NativeMediaValidationService(
            adapter: wrongStateAdapter).run(enter, snapshot: snapshot(session))
        #expect(wrongState.observed && !wrongState.completed)
        #expect(wrongState.phase == .awaitingReadback)

        let exit = try NativeMediaValidationRequest(
            action: .playbackExit, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation, execute: true)
        let exitAdapter = NativeMediaValidationExecutorAdapter { request, _ in
            let payload = self.playbackPayload(false)
            return self.transaction(for: request, observedPayload: payload,
                                    end: .observed)
        }
        let exited = try await NativeMediaValidationService(
            adapter: exitAdapter).run(exit, snapshot: snapshot(session))
        #expect(exited.completed && exited.mediaSessionReadback?.state == .normal)
    }

    @Test func oldListExecutionIsBlockedUntilPlaybackEvidenceIsFresh()
        async throws {
        let session = readySession()
        let old = try NativeMediaValidationRequest(
            action: .list, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            cursor: 0x4000_0002, execute: true)
        let calls = Pocket3MediaSessionCallCounter()
        let adapter = NativeMediaValidationExecutorAdapter { request, _ in
            calls.increment()
            return self.transaction(for: request)
        }
        await #expect(throws: NativeMediaValidationError.playbackRequired) {
            try await NativeMediaValidationService(adapter: adapter).run(
                old, snapshot: self.snapshot(session))
        }
        #expect(calls.count == 0)

        let readback = try Pocket3MediaSessionReadback(
            raw: playbackPayload(true))
        let playback = try Pocket3MediaSessionObservation(
            sessionID: sessionID, peripheralID: peerID,
            generation: session.generation, receivedUptime: 10,
            readback: readback)
        let allowed = try await NativeMediaValidationService(adapter: adapter)
            .run(old, snapshot: snapshot(session, mediaSession: playback))
        #expect(calls.count == 1 && allowed.submitted)
        #expect(!allowed.completed && allowed.phase == .awaitingReadback)

        let newest = try NativeMediaValidationRequest(
            action: .list, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation, execute: true)
        let newestResult = try await NativeMediaValidationService(
            adapter: adapter).run(newest, snapshot: snapshot(session))
        #expect(calls.count == 2 && newestResult.submitted)
    }
}
