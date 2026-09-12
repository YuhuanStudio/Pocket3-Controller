import Foundation
import Testing
@testable import Pocket3Core

@Suite("Native audio DSP validation")
struct NativeAudioDSPValidationTests {
    private actor CallCounter {
        var count = 0
        func next() -> Int {
            let value = count
            count += 1
            return value
        }
        func value() -> Int { count }
    }

    private let sessionID = UUID()
    private let peripheralID = UUID()

    private var binding: ContinuousGimbalBinding {
        ContinuousGimbalBinding(sessionID: "ble:\(sessionID.uuidString)", generation: 0)
    }

    private func readySession() -> NativeCameraSessionStatus {
        var session = NativeCameraSession()
        let generation = session.begin(sessionID: sessionID, peerID: peripheralID)
        _ = session.markPaired(generation: generation)
        _ = session.markCredentialsAvailable(generation: generation)
        _ = session.observeDatalink(.connecting, generation: generation)
        _ = session.observeDatalink(.ready, generation: generation)
        return session.status
    }

    private func blob(byte2: UInt8 = Pocket3WindNoiseReduction.on.rawValue,
                     count: Int = 31) -> Data {
        var value = Data((0..<count).map { UInt8(($0 * 13) & 0xff) })
        value[2] = byte2
        return value
    }

    private func readback(byte2: UInt8 = Pocket3WindNoiseReduction.on.rawValue,
                          at uptime: TimeInterval = 10) throws -> Pocket3AudioDSPReadback {
        try #require(Pocket3AudioDSPReadback.decode(
            Data([0]) + blob(byte2: byte2), receivedUptime: uptime))
    }

    private func baseline(byte2: UInt8 = Pocket3WindNoiseReduction.on.rawValue,
                          at uptime: TimeInterval = 10) throws -> Pocket3AudioDSPBaseline {
        try Pocket3AudioDSPBaseline(readback: readback(byte2: byte2, at: uptime),
                                    binding: binding)
    }

    private func request(_ session: NativeCameraSessionStatus,
                         wind: Pocket3WindNoiseReduction? = .off,
                         directional: Pocket3DirectionalAudio? = nil,
                         execute: Bool = false) throws -> NativeAudioDSPValidationRequest {
        try NativeAudioDSPValidationRequest(
            expectedSessionID: session.sessionID!, peripheralID: session.peerID!,
            generation: session.generation, wind: wind,
            directional: directional, execute: execute, timeout: 1)
    }

    private func transaction(for request: NativeCommandTransactionRequest,
                             payload: Data? = nil,
                             end: NativeCommandTransactionEnd = .acknowledged,
                             at uptime: TimeInterval = 11)
        -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(
            id: request.id, command: .audioDSP,
            generation: request.generation, sessionID: request.sessionID,
            end: end)
        result.submitted = true
        result.submittedUptime = uptime
        result.responseReceived = end != .timedOut && end != .cancelled
        result.responseStatus = end == .acknowledged || end == .observed ? 0 : 1
        result.acknowledged = end == .acknowledged || end == .observed
        result.acknowledgedUptime = result.acknowledged ? uptime + 0.01 : nil
        result.observedPayload = payload
        result.observed = payload != nil
        result.observedUptime = payload.map { _ in uptime + 0.02 }
        result.end = payload == nil ? end : .observed
        result.finishedUptime = uptime + 0.03
        return result
    }

    @Test func requestSchemaAndCLIParserKeepOnlyConfirmedAudioFields() throws {
        let session = readySession()
        let parsed = try NativeAudioDSPValidationRequest(cliArguments: [
            "--session", session.sessionID!.uuidString,
            "--peripheral", session.peerID!.uuidString,
            "--generation", String(session.generation),
            "--wind", "off", "--direction", "frontAndBack",
            "--timeout", "1", "--execute"])
        #expect(parsed.execute && parsed.wind == .off)
        #expect(parsed.directional == .frontAndBack)
        #expect(NativeAudioDSPValidationRequest.schema["additionalProperties"] == .bool(false))
        let decoded = try JSONDecoder().decode(
            NativeAudioDSPValidationRequest.self,
            from: JSONEncoder().encode(parsed))
        #expect(decoded == parsed)

        #expect(throws: BridgeFailure.self) {
            try NativeAudioDSPValidationRequest(cliArguments: [
                "--session", session.sessionID!.uuidString,
                "--peripheral", session.peerID!.uuidString,
                "--generation", String(session.generation)])
        }
        #expect(throws: BridgeFailure.self) {
            try NativeAudioDSPValidationRequest(arguments: .object([
                "expectedSessionID": .string(session.sessionID!.uuidString),
                "peripheralID": .string(session.peerID!.uuidString),
                "generation": .number(Double(session.generation)),
                "wind": .string("invalid")]))
        }
    }

    @Test func dryRunPlansInitialA0AndOptionalSafe9FPatchWithoutExecutor() async throws {
        let session = readySession()
        let input = try request(session)
        let noBaseline = try await NativeAudioDSPValidationService().run(
            input, snapshot: .init(session: session, binding: binding, nowUptime: 11))
        #expect(noBaseline.dryRun && noBaseline.steps.count == 1)
        #expect(noBaseline.steps[0].step == .initialGet)
        #expect(noBaseline.steps[0].request.frame.commandID == 0xA0)
        #expect(noBaseline.submittedCount == 0)

        let withBaseline = try await NativeAudioDSPValidationService().run(
            input, snapshot: .init(session: session, binding: binding,
                                   baseline: try baseline(), nowUptime: 11))
        #expect(withBaseline.steps.map(\.step) == [.initialGet, .set, .verificationGet])
        #expect(withBaseline.steps[1].request.frame.commandID == 0x9F)
        #expect(withBaseline.steps[1].request.frame.payload[2] == Pocket3WindNoiseReduction.off.rawValue)
        #expect(withBaseline.steps[1].request.frame.payload.count == 31)
        #expect(!withBaseline.completed && withBaseline.submittedCount == 0)
    }

    @Test func executeRunsA0SetAndMatchingA0ExactlyOncePreservingUnknownBytes() async throws {
        let session = readySession()
        let original = blob(byte2: Pocket3DirectionalAudio.front.rawValue)
        let patched = original.enumerated().map { index, value in
            index == 2 ? Pocket3WindNoiseReduction.off.rawValue : value
        }
        let counter = CallCounter()
        let adapter = NativeAudioDSPValidationExecutorAdapter { request, _ in
            let index = await counter.next()
            switch index {
            case 0:
                return transaction(for: request, payload: Data([0]) + original, at: 11)
            case 1:
                return transaction(for: request, at: 11.1)
            default:
                return transaction(for: request, payload: Data([0]) + Data(patched),
                                   end: .observed, at: 11.2)
            }
        }
        let result = try await NativeAudioDSPValidationService(adapter: adapter).run(
            try request(session, execute: true),
            snapshot: .init(session: session, binding: binding, nowUptime: 11))
        #expect(await counter.value() == 3)
        #expect(result.completed && result.phase == .completed)
        #expect(result.submittedCount == 3 && result.acknowledgedCount == 3)
        #expect(result.observedCount == 2)
        #expect(result.steps.map(\.request.frame.commandID) == [0xA0, 0x9F, 0xA0])
        #expect(result.steps[1].request.frame.payload == Data(patched))
        #expect(result.steps[2].readback?.blob == Data(patched))
    }

    @Test func unknownByteTwoStopsBefore9FAndNeverInventsASetting() async throws {
        let session = readySession()
        let counter = CallCounter()
        let adapter = NativeAudioDSPValidationExecutorAdapter { request, _ in
            _ = await counter.next()
            return transaction(for: request,
                               payload: Data([0]) + blob(byte2: 0xFE), at: 11)
        }
        let result = try await NativeAudioDSPValidationService(adapter: adapter).run(
            try request(session, execute: true),
            snapshot: .init(session: session, binding: binding, nowUptime: 11))
        #expect(await counter.value() == 1)
        #expect(result.phase == .failed && result.failureCode == "native_audio_dsp_unknown_byte2")
        #expect(result.steps.count == 1 && result.submittedCount == 1)
    }

    @Test func setNackStopsBeforeVerificationAndCancellationKeepsPartialEvidence() async throws {
        let session = readySession()
        let nackCounter = CallCounter()
        let nackAdapter = NativeAudioDSPValidationExecutorAdapter { request, _ in
            let index = await nackCounter.next()
            return index == 0
                ? transaction(for: request, payload: Data([0]) + self.blob(), at: 11)
                : transaction(for: request, end: .rejected, at: 11.1)
        }
        let nacked = try await NativeAudioDSPValidationService(adapter: nackAdapter).run(
            try request(session, execute: true),
            snapshot: .init(session: session, binding: binding, nowUptime: 11))
        #expect(await nackCounter.value() == 2)
        #expect(nacked.phase == .failed && !nacked.completed)
        #expect(nacked.steps.count == 3 && nacked.submittedCount == 2)

        let cancelCounter = CallCounter()
        let cancelAdapter = NativeAudioDSPValidationExecutorAdapter { request, _ in
            let index = await cancelCounter.next()
            if index == 1 { throw CancellationError() }
            return transaction(for: request,
                               payload: Data([0]) + self.blob(), at: 11)
        }
        let cancelled = try await NativeAudioDSPValidationService(adapter: cancelAdapter).run(
            try request(session, execute: true),
            snapshot: .init(session: session, binding: binding, nowUptime: 11))
        #expect(await cancelCounter.value() == 2)
        #expect(cancelled.phase == .cancelled && cancelled.partial)
        #expect(cancelled.submittedCount == 1 && cancelled.steps.count == 3)
    }

    @Test func commandReadyExactIdentityAndFreshBaselineAreRequired() throws {
        var paired = NativeCameraSession()
        let pairedGeneration = paired.begin(sessionID: sessionID, peerID: peripheralID)
        _ = paired.markPaired(generation: pairedGeneration)
        let pairedRequest = try NativeAudioDSPValidationRequest(
            expectedSessionID: sessionID, peripheralID: peripheralID,
            generation: pairedGeneration, wind: .off)
        #expect(throws: NativeAudioDSPValidationError.sessionNotReady) {
            _ = try NativeAudioDSPValidationCoordinator(session: paired.status,
                                                         binding: binding)
        }

        let session = readySession()
        let mismatched = try NativeAudioDSPValidationRequest(
            expectedSessionID: session.sessionID!, peripheralID: session.peerID!,
            generation: session.generation + 1, wind: .off)
        var coordinator = try NativeAudioDSPValidationCoordinator(
            session: session, binding: binding)
        #expect(throws: NativeAudioDSPValidationError.invalidRequestIdentity) {
            try coordinator.prepare(mismatched, baseline: nil, nowUptime: 11)
        }
        #expect(pairedRequest.generation == pairedGeneration)
        try coordinator.prepare(try request(session), baseline: nil, nowUptime: 11)
        #expect(coordinator.phase == .awaitingInitialReadback)
        var staleCoordinator = try NativeAudioDSPValidationCoordinator(
            session: session, binding: binding)
        #expect(throws: NativeAudioDSPValidationError.baselineRequired) {
            try staleCoordinator.prepare(try request(session), baseline: try baseline(at: 1), nowUptime: 11)
        }
        let foreign = ContinuousGimbalBinding(sessionID: binding.sessionID, generation: 8)
        #expect(throws: NativeAudioDSPValidationError.invalidBinding) {
            _ = try NativeAudioDSPValidationCoordinator(session: session, binding: foreign)
        }
    }
}
