import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 media protocol foundation")
struct Pocket3MediaProtocolTests {
    private let sessionID = UUID()
    private let peerID = UUID()

    private func identity(generation: UInt64 = 3)
        -> Pocket3MediaSessionIdentity {
        try! Pocket3MediaSessionIdentity(sessionID: sessionID,
            generation: generation, peripheralID: peerID)
    }

    private func chunk(subtype: UInt8, counter: UInt8 = 1,
                       body: Data = Data()) -> Pocket3MediaListChunk {
        var payload = Data([0x4A, subtype, 0, 0, counter, 0, 0, 0, 0, 0])
        payload.append(body)
        return try! Pocket3MediaListChunk(payload: payload)
    }

    @Test func playbackAndPresenceUseExactPayloadsAndIdentity() throws {
        let identity = identity()
        let enter = Pocket3MediaPlaybackCommand(identity: identity,
            operation: .enter)
        #expect(enter.command == .mediaPlayback)
        #expect(enter.frame(sequence: 9).payload ==
            Data([0x01, 0x01, 0x00, 0x01]))
        #expect(enter.frame(sequence: 9).commandSet == 0x02 &&
            enter.frame(sequence: 9).commandID == 0x0C)

        let exit = Pocket3MediaPlaybackCommand(identity: identity,
            operation: .exit)
        #expect(exit.payload == Data([0x01, 0x01, 0x00, 0x00]))

        let hold = try Pocket3MediaPresenceHold(identity: identity)
        #expect(hold.command == .mediaPresence)
        #expect(hold.interval == 1)
        #expect(hold.frame(sequence: 4).payload == Pocket3MediaPresenceHold.payload)
        #expect(hold.frame(sequence: 4).commandSet == 0 &&
            hold.frame(sequence: 4).commandID == 0x88)
        #expect(hold.isCurrent(for: NativeCameraSessionStatus(
            state: .commandReady, generation: 3, sessionID: sessionID,
            peerID: peerID)))
        #expect(throws: Pocket3MediaProtocolError.invalidClock) {
            try Pocket3MediaPresenceHold(identity: identity, interval: 0.1)
        }
    }

    @Test func listRequestTriggerAndCursorPreserveCounterAndLittleEndianCursor() throws {
        let list = try Pocket3MediaListRequest(identity: identity(),
            counter: 2, cursor: 0x4010_4480)
        #expect(list.command == .mediaList)
        #expect(list.payload.count == 41)
        #expect(list.payload == Pocket3MediaListRequest.listPayload(
            counter: 2, cursor: 0x4010_4480))
        #expect(Array(list.payload[4...4]) == [2])
        #expect(Array(list.payload[10...13]) == [0x80, 0x44, 0x10, 0x40])
        #expect(list.payload[14] == 0x2D)

        let trigger = Pocket3MediaListTrigger(identity: identity())
        #expect(trigger.payload == Pocket3MediaListRequest.triggerPayload)
        #expect(trigger.frame(sequence: 5).commandSet == 0 &&
            trigger.frame(sequence: 5).commandID == 0x26)
        #expect(throws: Pocket3MediaProtocolError.invalidCounter) {
            try Pocket3MediaListRequest(identity: self.identity(), counter: 0,
                                         cursor: 1)
        }

        let handles: [UInt32] = [0x4010_0880, 0x4010_0840, 0x02]
        #expect(Pocket3MediaListCursor.oldestVideoHandle(handles) == 0x4010_0840)
        #expect(Pocket3MediaListCursor.nextCursor(handles: handles,
            current: 0x4010_0880) == 0x4010_0840)
        #expect(!Pocket3MediaListCursor.hasOlderPage(recordCount: 44,
            cursor: 0x4010_0840))
        #expect(Pocket3MediaListCursor.hasOlderPage(recordCount: 45,
            cursor: 0x4010_0840))
    }

    @Test func chunkDecoderRetainsUnknownHeaderAndAssemblerConcatenatesDataInArrivalOrder() throws {
        let identity = identity()
        var assembler = try Pocket3MediaListReassembler(identity: identity,
            counter: 1, cursor: Pocket3MediaListRequest.newestSD)
        #expect(try assembler.ingest(chunk(subtype: 0x01, body: Data([2, 0, 0, 0])),
            sessionID: sessionID, generation: 3, peripheralID: peerID,
            receivedUptime: 10))

        let unknown = chunk(subtype: 0xFE, body: Data([0xAA, 0xBB]))
        #expect(try assembler.ingest(unknown, sessionID: sessionID,
            generation: 3, peripheralID: peerID, receivedUptime: 10.1))
        #expect(unknown.subtype == .unknown(raw: 0xFE))
        #expect(unknown.unknownRaw == unknown.raw)

        #expect(try assembler.ingest(chunk(subtype: 0x01, body: Data([1, 2])),
            sessionID: sessionID, generation: 3, peripheralID: peerID,
            receivedUptime: 10.2))
        #expect(try assembler.ingest(chunk(subtype: 0x03),
            sessionID: sessionID, generation: 3, peripheralID: peerID,
            receivedUptime: 10.3))
        #expect(assembler.phase == .completed && assembler.isComplete)
        #expect(assembler.assembledData == Data([2, 0, 0, 0, 1, 2]))
        #expect(assembler.acceptedChunkCount == 4)
        #expect(assembler.unknownRaw == [unknown.raw])

        let pack = try assembler.makePack()
        #expect(pack.raw == assembler.assembledData)
        #expect(pack.declaredRecordCount == 2)
        #expect(pack.counter == 1 && pack.cursor == 1)
        #expect(pack.unknownRaw == [unknown.raw])
        #expect(throws: Pocket3MediaProtocolError.terminalState) {
            try assembler.ingest(chunk(subtype: 0x01, body: Data([9])),
                sessionID: sessionID, generation: 3, peripheralID: peerID,
                receivedUptime: 10.4)
        }
    }

    @Test func assemblerFencesIdentityBoundsCancellationAndTeardown() throws {
        let identity = identity()
        var assembler = try Pocket3MediaListReassembler(identity: identity,
            counter: 1, maximumBytes: 2, maximumChunkCount: 2)
        #expect(throws: Pocket3MediaProtocolError.generationMismatch) {
            try assembler.ingest(chunk(subtype: 0x01, body: Data([1])),
                sessionID: sessionID, generation: 4, peripheralID: peerID,
                receivedUptime: 10)
        }
        #expect(assembler.assembledData.isEmpty && assembler.rejectedChunkCount == 1)
        #expect(throws: Pocket3MediaProtocolError.responseTooLarge) {
            try assembler.ingest(chunk(subtype: 0x01, body: Data([1, 2, 3])),
                sessionID: sessionID, generation: 3, peripheralID: peerID,
                receivedUptime: 10)
        }
        #expect(assembler.phase == .failed && assembler.assembledData.isEmpty)

        var cancelled = try Pocket3MediaListReassembler(identity: identity,
            counter: 1)
        #expect(try cancelled.ingest(chunk(subtype: 0x01, body: Data([4, 5])),
            sessionID: sessionID, generation: 3, peripheralID: peerID,
            receivedUptime: 11))
        cancelled.cancel()
        #expect(cancelled.phase == .cancelled &&
            cancelled.assembledData == Data([4, 5]))
        #expect(throws: Pocket3MediaProtocolError.terminalState) {
            try cancelled.ingest(chunk(subtype: 0x03),
                sessionID: sessionID, generation: 3, peripheralID: peerID,
                receivedUptime: 11.1)
        }
        cancelled.teardown()
        #expect(cancelled.phase == .tornDown && cancelled.assembledData.isEmpty)
        #expect(cancelled.discardedByteCount == 2)
    }

    @Test func boundedHTTPRangeRequestEncodesV2PathWithoutNetworkIO() throws {
        let byteRange = try Pocket3MediaByteRange(start: 1024,
            endInclusive: 2047)
        #expect(byteRange.length == 1024)
        #expect(byteRange.headerValue == "bytes=1024-2047")
        let request = try Pocket3MediaHTTPRangeRequest(identity: identity(),
            storage: 0, path: "DCIM/DJI_001/clip 01.MP4", range: byteRange)
        #expect(request.method == "GET")
        #expect(request.rangeHeader == "bytes=1024-2047")
        #expect(request.headers["Range"] == "bytes=1024-2047")
        #expect(request.url?.scheme == "http" && request.url?.host == "192.168.2.1")
        #expect(request.url?.path == "/v2")
        #expect(request.url?.query?.contains("storage=0") == true)
        #expect(request.url?.query?.contains("DCIM") == true)
        #expect(request.isCurrent(for: NativeCameraSessionStatus(
            state: .commandReady, generation: 3, sessionID: sessionID,
            peerID: peerID)))

        #expect(throws: Pocket3MediaProtocolError.invalidRange) {
            try Pocket3MediaByteRange(start: 0, endInclusive: UInt64.max)
        }
        #expect(throws: Pocket3MediaProtocolError.invalidPath) {
            try Pocket3MediaHTTPRangeRequest(identity: self.identity(),
                storage: 0, path: "../secret", range: byteRange)
        }
        #expect(throws: Pocket3MediaProtocolError.invalidStorage) {
            try Pocket3MediaHTTPRangeRequest(identity: self.identity(),
                storage: 2, path: "DCIM/clip.MP4", range: byteRange)
        }
    }

    @Test func favoriteAndDeleteCandidatesEncodeExactBytesButExposeNoExecutor() throws {
        let favorite = try Pocket3MediaFavoriteCommand(identity: identity(),
            handle: 0x4010_4040, on: true, counter: 1)
        #expect(favorite.command == .mediaFavorite)
        #expect(favorite.frame(sequence: 1).commandSet == 0x02 &&
            favorite.frame(sequence: 1).commandID == 0xBF)
        #expect(favorite.payload == Data([
            0x01, 0x01, 0x40, 0x40, 0x10, 0x40,
            0x01, 0x00, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00
        ]))

        let delete = try Pocket3MediaDeleteCommand(identity: identity(),
            handle: 0x4010_4480, counter: 1)
        #expect(delete.frame(sequence: 2).commandSet == 0x00 &&
            delete.frame(sequence: 2).commandID == 0x28)
        #expect(delete.payload == Data([
            0x01, 0x80, 0x44, 0x10, 0x40,
            0x01, 0x00, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00,
            0x01, 0x01, 0x00, 0x00
        ]))

        #expect(throws: Pocket3MediaProtocolError.invalidHandle) {
            try Pocket3MediaFavoriteCommand(identity: self.identity(),
                handle: 0, on: true, counter: 1)
        }
        #expect(throws: Pocket3MediaProtocolError.invalidCounter) {
            try Pocket3MediaDeleteCommand(identity: self.identity(),
                handle: 1, counter: 0)
        }
    }
}
