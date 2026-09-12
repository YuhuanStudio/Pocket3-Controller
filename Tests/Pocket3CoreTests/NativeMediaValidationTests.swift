import Foundation
import Testing
@testable import Pocket3Core

private final class NativeMediaCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("Native media validation service")
struct NativeMediaValidationTests {
    private let sessionID = UUID()
    private let peerID = UUID()

    private func readySession() -> NativeCameraSessionStatus {
        var session = NativeCameraSession()
        let generation = session.begin(sessionID: sessionID, peerID: peerID)
        _ = session.markPaired(generation: generation)
        _ = session.markCredentialsAvailable(generation: generation)
        _ = session.observeDatalink(.connecting, generation: generation)
        _ = session.observeDatalink(.ready, generation: generation)
        return session.status
    }

    private func snapshot(_ session: NativeCameraSessionStatus,
                          route: Pocket3DatalinkRouteStatus = .init(
                            state: .legacyUnbound,
                            evidence: "test_legacy_route"),
                          now: TimeInterval = 10)
        -> NativeMediaValidationSnapshot {
        NativeMediaValidationSnapshot(session: session, routeStatus: route,
                                      nowUptime: now)
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
        result.sequence = 0x5001
        result.submitted = true
        result.submittedUptime = 11
        result.responseReceived = true
        result.acknowledged = true
        result.acknowledgedUptime = 11.01
        result.observedPayload = observedPayload
        result.observed = observedPayload != nil
        result.observedUptime = 11.02
        result.finishedUptime = 11.03
        return result
    }

    private func chunk(subtype: UInt8, counter: UInt8 = 1,
                       body: Data = Data()) -> DUMLFrame {
        var payload = Data([0x4A, subtype, 0, 0, counter,
                            0, 0, 0, 0, 0])
        payload.append(body)
        return DUMLFrame(source: 0x01, destination: 0x02,
                         sequence: 1, flags: 0, commandSet: 0,
                         commandID: 0x27, payload: payload)
    }

    private func syntheticManifest() -> Data {
        let path = "DCIM/DJI_001/DJI_20260912123456_0001_D"
        let base = path.split(separator: "/").last!
        let fileName = "\(base).MP4"
        let thumb = "MISC/THM/DJI_001/DJI_20260912123456_0001_D"
        var raw = Data(repeating: 0, count: 40)
        raw[0] = 1
        raw[19] = 0xE8; raw[20] = 0x03; raw[21] = 0; raw[22] = 0
        raw[23] = 0x10; raw[24] = 0x00; raw[25] = 0x04; raw[26] = 0x00
        raw[27] = 12; raw[28] = 0
        raw[29] = 3; raw[30] = 0x0A
        raw[31] = 3; raw[33] = 0x19; raw[34] = 0x06
        raw.append(pathField(path, subtype: 1))
        raw.append(Data([0x0D, UInt8(fileName.utf8.count)]))
        raw.append(contentsOf: fileName.utf8)
        raw.append(pathField(thumb, subtype: 2))
        raw.append(contentsOf: [
            0x1B, 0x0A, 0, 0, 0, 0x02, 0x02, 0x01,
            0x14, 0x02, 0x15, 0x03, 0x01
        ])
        return raw
    }

    private func pathField(_ path: String, subtype: UInt8) -> Data {
        var field = Data([0x1A, UInt8(6 + path.utf8.count),
                          0, 0, 0, subtype])
        field.append(contentsOf: path.utf8)
        return field
    }

    @Test func requestParsesListAndRangeWithoutAllowingDeleteActions() throws {
        let list = try NativeMediaValidationRequest(cliArguments: [
            "--action", "list", "--session", sessionID.uuidString,
            "--peripheral", peerID.uuidString, "--generation", "3",
            "--counter", "2", "--cursor", "0x40000001",
            "--max-bytes", "4096", "--max-chunks", "4"
        ])
        #expect(list.action == .list && list.counter == 2)
        #expect(list.cursor == 0x40000001 && !list.execute)
        let encoded = try JSONEncoder().encode(list)
        #expect(try JSONDecoder().decode(
            NativeMediaValidationRequest.self, from: encoded) == list)

        let range = try NativeMediaValidationRequest(arguments: .object([
            "action": .string("range"),
            "expectedSessionID": .string(sessionID.uuidString),
            "peripheralID": .string(peerID.uuidString),
            "generation": .number(3),
            "storage": .number(0),
            "path": .string("DCIM/DJI_001/clip.MP4"),
            "start": .number(0), "end": .number(127)
        ]))
        #expect(range.rangeRequest?.range.length == 128)
        #expect(throws: NativeMediaValidationError.invalidArguments) {
            try NativeMediaValidationRequest(arguments: .object([
                "action": .string("delete"),
                "expectedSessionID": .string(sessionID.uuidString),
                "peripheralID": .string(peerID.uuidString),
                "generation": .number(3)
            ]))
        }
    }

    @Test func typedIndexReadsBoundedCompositePackFieldsAndUnknownType() throws {
        let identity = try Pocket3MediaSessionIdentity(
            sessionID: sessionID, generation: 3, peripheralID: peerID)
        let pack = try Pocket3MediaListPack(identity: identity, counter: 1,
            cursor: Pocket3MediaListRequest.newestSD,
            raw: syntheticManifest(), chunkCount: 2)
        let index = try Pocket3MediaIndex(pack: pack)
        #expect(index.entries.count == 1)
        let entry = try #require(index.entries.first)
        #expect(entry.fileName?.hasSuffix(".MP4") == true)
        #expect(entry.path.hasSuffix(".MP4"))
        #expect(entry.fileType == .mp4)
        #expect(entry.handle == 0x0004_0010)
        #expect(entry.sizeBytes == 1000 && entry.durationSeconds == 12)
        #expect(entry.frameRateRaw == 3 && entry.resolutionRaw == 0x0A)
        #expect(entry.starred == true)
        #expect(index.countMatchesDeclared == true)

        var unknown = syntheticManifest()
        unknown[31] = 0xFE
        let unknownPack = try Pocket3MediaListPack(identity: identity,
            counter: 1, cursor: 1, raw: unknown, chunkCount: 2)
        let unknownIndex = try Pocket3MediaIndex(pack: unknownPack)
        #expect(unknownIndex.entries.first?.fileType ==
            Pocket3MediaFileType.unknown(raw: 0xFE))
        #expect(unknownIndex.entries.first?.durationSeconds == nil)
    }

    @Test func dryRunBuildsOneListRequestWithoutCallingOwner() async throws {
        let session = readySession()
        let request = try NativeMediaValidationRequest(
            action: .list, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation)
        let counter = NativeMediaCallCounter()
        let adapter = NativeMediaValidationExecutorAdapter { _, _ in
            counter.increment()
            throw CancellationError()
        }
        let result = try await NativeMediaValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session))
        #expect(result.dryRun && result.phase == .dryRun)
        #expect(result.request?.command == .mediaList)
        #expect(result.request?.frame.commandSet == 0)
        #expect(result.request?.frame.commandID == 0x26)
        #expect(!result.submitted && counter.count == 0)
        #expect(result.list?.phase == .collecting)
    }

    @Test func listOwnerIsCalledOnceAndCompletesOnlyAfterEndChunkAndTypedIndex() async throws {
        let session = readySession()
        let request = try NativeMediaValidationRequest(
            action: .list, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            maximumBytes: 4096, maximumChunkCount: 8, execute: true)
        let counter = NativeMediaCallCounter()
        let adapter = NativeMediaValidationExecutorAdapter { request, _ in
            counter.increment()
            let observe = try #require(request.observationHandler())
            #expect(observe(self.chunk(subtype: 0x04)) == nil)
            #expect(observe(self.chunk(subtype: 0x01,
                                      body: self.syntheticManifest())) == nil)
            let marker = observe(self.chunk(subtype: 0x03))
            #expect(marker == Data([
                NativeMediaListObservationCollector.terminalMarker,
                NativeMediaListObservationCollector.successMarker
            ]))
            return self.transaction(for: request,
                observedPayload: marker, end: .observed)
        }
        let result = try await NativeMediaValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session))
        #expect(counter.count == 1)
        #expect(result.submitted && result.acknowledged && result.observed)
        #expect(result.completed && result.phase == .completed)
        #expect(result.list?.phase == .completed)
        #expect(result.list?.acceptedChunkCount == 3)
        #expect(result.mediaIndex?.entries.count == 1)
    }

    @Test func ackOnlyCancellationAndUnsafeRoutePreservePartialEvidenceWithoutRetry() async throws {
        let session = readySession()
        let request = try NativeMediaValidationRequest(
            action: .list, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation, execute: true)

        let ackCounter = NativeMediaCallCounter()
        let ackAdapter = NativeMediaValidationExecutorAdapter { request, _ in
            ackCounter.increment()
            return self.transaction(for: request)
        }
        let ackResult = try await NativeMediaValidationService(adapter: ackAdapter).run(
            request, snapshot: snapshot(session))
        #expect(ackCounter.count == 1 && ackResult.submitted)
        #expect(!ackResult.completed && ackResult.phase == .awaitingReadback)
        #expect(ackResult.list?.phase == .collecting)

        let cancelCounter = NativeMediaCallCounter()
        let cancelAdapter = NativeMediaValidationExecutorAdapter { _, _ in
            cancelCounter.increment()
            throw CancellationError()
        }
        let cancelResult = try await NativeMediaValidationService(adapter: cancelAdapter).run(
            request, snapshot: snapshot(session))
        #expect(cancelCounter.count == 1)
        #expect(cancelResult.phase == .cancelled)
        #expect(cancelResult.list?.phase == .cancelled)
        #expect(!cancelResult.completed)

        let blockedCounter = NativeMediaCallCounter()
        let blockedAdapter = NativeMediaValidationExecutorAdapter { _, _ in
            blockedCounter.increment()
            throw CancellationError()
        }
        let unknownRoute = Pocket3DatalinkRouteStatus(
            state: .unknown, evidence: "test_unknown")
        let blocked = try await NativeMediaValidationService(
            adapter: blockedAdapter).run(request,
                snapshot: snapshot(session, route: unknownRoute))
        #expect(blocked.phase == .routeRejected && !blocked.submitted)
        #expect(blocked.failureCode == "native_media_route_invalid")
        #expect(blockedCounter.count == 0)
    }

    @Test func playbackUsesExactCommandAndRangeRejectsUnboundRouteWithoutFetcher() async throws {
        let session = readySession()
        let request = try NativeMediaValidationRequest(
            action: .playbackEnter, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation, execute: true)
        let counter = NativeMediaCallCounter()
        let adapter = NativeMediaValidationExecutorAdapter { request, _ in
            counter.increment()
            #expect(request.frame.commandSet == 0x02)
            #expect(request.frame.commandID == 0x0C)
            #expect(request.frame.payload == Data([0x01, 0x01, 0x00, 0x01]))
            return self.transaction(for: request)
        }
        let playback = try await NativeMediaValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session))
        #expect(counter.count == 1 && !playback.completed)
        #expect(playback.phase == .awaitingReadback)
        #expect(playback.failureCode == "native_media_playback_readback_missing")
        #expect(playback.observed == false)

        let range = try NativeMediaValidationRequest(
            action: .range, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            storage: 0, path: "DCIM/DJI_001/clip.MP4",
            rangeStart: 0, rangeEnd: 31, execute: true)
        let rangeResult = try await NativeMediaValidationService().run(
            range, snapshot: snapshot(session))
        #expect(rangeResult.phase == .routeRejected)
        #expect(rangeResult.failureCode == "native_media_http_route_invalid")
        #expect(!rangeResult.submitted && !rangeResult.completed)
    }
}
