import Foundation
import Testing
@testable import Pocket3Core

private final class NativeAdvancedSettingCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("Native advanced setting validation service")
struct NativeAdvancedSettingValidationTests {
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

    private func keyedReply(parameterID: UInt16, value: Data) -> Data {
        Data([0x00, 0x00, 0x01, UInt8(parameterID & 0xFF),
              UInt8(parameterID >> 8), UInt8(value.count)]) + value
    }

    private func observation(
        _ session: NativeCameraSessionStatus,
        setting: Pocket3AdvancedSettingID,
        value: Data,
        uptime: TimeInterval = 10
    ) throws -> Pocket3AdvancedSettingObservation {
        let parameterID: UInt16
        switch setting {
        case .isoLimit: parameterID = 0x000F
        case .audioChannel: parameterID = 0x0020
        case .vocalBoost: parameterID = 0x004C
        case .selfieFlip: parameterID = 0x0038
        default: throw NativeAdvancedSettingValidationError.invalidValue
        }
        guard let result = Pocket3AdvancedSettingObservation(
            sessionID: session.sessionID!, generation: session.generation,
            receivedUptime: uptime, setting: setting,
            payload: keyedReply(parameterID: parameterID, value: value)) else {
            throw NativeAdvancedSettingValidationError.invalidValue
        }
        return result
    }

    private func snapshot(
        _ session: NativeCameraSessionStatus,
        baseline: Pocket3AdvancedSettingObservation? = nil,
        now: TimeInterval = 10
    ) -> NativeAdvancedSettingValidationSnapshot {
        NativeAdvancedSettingValidationSnapshot(session: session,
            baseline: baseline, nowUptime: now)
    }

    private func transaction(
        for request: NativeCommandTransactionRequest,
        payload: Data? = nil,
        end: NativeCommandTransactionEnd = .observed
    ) -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(
            id: request.id, command: request.command,
            generation: request.generation, sessionID: request.sessionID,
            end: end)
        result.submitted = true
        result.submittedUptime = 11
        result.responseReceived = true
        result.acknowledged = end == .acknowledged || end == .observed
        result.acknowledgedUptime = result.acknowledged ? 11.01 : nil
        result.observedPayload = payload
        result.observed = payload != nil
        result.observedUptime = payload == nil ? nil : 11.02
        result.finishedUptime = 11.03
        return result
    }

    private func assertThrows(
        _ expected: NativeAdvancedSettingValidationError,
        _ body: () async throws -> Void
    ) async {
        var caught: NativeAdvancedSettingValidationError?
        do {
            try await body()
        } catch let error as NativeAdvancedSettingValidationError {
            caught = error
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(caught == expected)
    }

    @Test func requestParsesTypedValuesAndDefaultsToDryRun() throws {
        let request = try NativeAdvancedSettingValidationRequest(cliArguments: [
            "--action", "iso-limit", "--session", sessionID.uuidString,
            "--peripheral", peerID.uuidString, "--generation", "3",
            "--value", "1600"
        ])
        #expect(request.action == .isoLimit)
        #expect(request.typedTarget == .isoLimit(.iso1600))
        #expect(!request.execute)

        let roundTrip = try JSONDecoder().decode(
            NativeAdvancedSettingValidationRequest.self,
            from: JSONEncoder().encode(request))
        #expect(roundTrip == request)

        let selfie = try NativeAdvancedSettingValidationRequest(arguments: .object([
            "action": .string("selfie-flip-get"),
            "expectedSessionID": .string(sessionID.uuidString),
            "peripheralID": .string(peerID.uuidString),
            "generation": .number(3)
        ]))
        #expect(selfie.action == .selfieFlipGet && selfie.value == nil)
        #expect(throws: NativeAdvancedSettingValidationError.invalidValue) {
            try NativeAdvancedSettingValidationRequest(arguments: .object([
                "action": .string("audio-channel"),
                "expectedSessionID": .string(sessionID.uuidString),
                "peripheralID": .string(peerID.uuidString),
                "generation": .number(3), "value": .string("surround")
            ]))
        }
    }

    @Test func dryRunPreparesTypedISOOnceWithoutCallingExecutor() async throws {
        let session = readySession()
        let request = try NativeAdvancedSettingValidationRequest(
            action: .isoLimit, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            value: "1600")
        let counter = NativeAdvancedSettingCallCounter()
        let adapter = NativeAdvancedSettingValidationExecutorAdapter { _, _ in
            counter.increment()
            throw CancellationError()
        }
        let result = try await NativeAdvancedSettingValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session,
                baseline: try observation(session, setting: .isoLimit,
                                          value: Data([Pocket3ISOLimit.iso100.rawValue]))))
        #expect(result.dryRun && result.phase == .dryRun)
        #expect(result.request?.frame.commandID == 0x8E)
        #expect(result.request?.frame.payload == Data([1, 1, 0x0F, 0, 1, 5]))
        #expect(result.setting?.phase == .awaitingAcknowledgment)
        #expect(!result.submitted && !result.completed && counter.count == 0)
    }

    @Test func executeAudioChannelCompletesAfterOneMatchingReadback() async throws {
        let session = readySession()
        let request = try NativeAdvancedSettingValidationRequest(
            action: .audioChannel, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            value: "stereo", execute: true)
        let counter = NativeAdvancedSettingCallCounter()
        let adapter = NativeAdvancedSettingValidationExecutorAdapter { request, _ in
            counter.increment()
            return self.transaction(for: request,
                payload: self.keyedReply(parameterID: 0x0020,
                    value: Data([Pocket3AudioChannel.stereo.rawValue])))
        }
        let result = try await NativeAdvancedSettingValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session,
                baseline: try observation(session, setting: .audioChannel,
                                          value: Data([Pocket3AudioChannel.mono.rawValue]))))
        #expect(counter.count == 1)
        #expect(result.submitted && result.acknowledged && result.observed)
        #expect(result.completed && result.phase == .completed)
        #expect(result.setting?.readback?.typedValue == .audioChannel(.stereo))
    }

    @Test func vocalBoostACKOnlyAndCancellationStayPartialWithoutRetry() async throws {
        let session = readySession()
        let request = try NativeAdvancedSettingValidationRequest(
            action: .vocalBoost, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            value: "on", execute: true)
        let ackCounter = NativeAdvancedSettingCallCounter()
        let ackAdapter = NativeAdvancedSettingValidationExecutorAdapter { request, _ in
            ackCounter.increment()
            return self.transaction(for: request, end: .acknowledged)
        }
        let baseline = try observation(session, setting: .vocalBoost, value: Data([0]))
        let ack = try await NativeAdvancedSettingValidationService(adapter: ackAdapter).run(
            request, snapshot: snapshot(session, baseline: baseline))
        #expect(ackCounter.count == 1 && ack.acknowledged)
        #expect(!ack.observed && !ack.completed && ack.phase == .awaitingReadback)

        let cancelCounter = NativeAdvancedSettingCallCounter()
        let cancelAdapter = NativeAdvancedSettingValidationExecutorAdapter { _, _ in
            cancelCounter.increment()
            throw CancellationError()
        }
        let cancelled = try await NativeAdvancedSettingValidationService(adapter: cancelAdapter).run(
            request, snapshot: snapshot(session, baseline: baseline))
        #expect(cancelCounter.count == 1 && cancelled.phase == .cancelled)
        #expect(cancelled.failureCode == "cancelled" && !cancelled.completed)
    }

    @Test func selfieFlipIsGETOnlyAndRetainsUnknownReadbackBytes() async throws {
        let session = readySession()
        let request = try NativeAdvancedSettingValidationRequest(
            action: .selfieFlipGet, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation, execute: true)
        let counter = NativeAdvancedSettingCallCounter()
        let adapter = NativeAdvancedSettingValidationExecutorAdapter { request, _ in
            counter.increment()
            return self.transaction(for: request,
                payload: self.keyedReply(parameterID: 0x0038,
                    value: Data([0x02, 0xFE])))
        }
        let result = try await NativeAdvancedSettingValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session))
        #expect(counter.count == 1 && result.completed)
        #expect(result.request?.frame.payload == Data([0, 1, 0x38, 0]))
        #expect(result.readback?.typedValue == nil)
        #expect(result.readback?.raw == self.keyedReply(parameterID: 0x0038,
                                                         value: Data([0x02, 0xFE])))
    }

    @Test func officialOnlyAndSelfieFlipSetReturnUnsupportedWithoutSending() async throws {
        let session = readySession()
        let counter = NativeAdvancedSettingCallCounter()
        let adapter = NativeAdvancedSettingValidationExecutorAdapter { _, _ in
            counter.increment()
            throw CancellationError()
        }
        for action in [NativeAdvancedSettingValidationOperation.breathingCompensation,
                       .sharpness, .noiseReduction, .selfieFlipSet] {
            let request = try NativeAdvancedSettingValidationRequest(
                action: action, expectedSessionID: sessionID,
                peripheralID: peerID, generation: session.generation, execute: true)
            await assertThrows(.unsupportedNoProtocol) {
                _ = try await NativeAdvancedSettingValidationService(adapter: adapter).run(
                    request, snapshot: snapshot(session))
            }
        }
        #expect(counter.count == 0)

        let medTele = try NativeAdvancedSettingValidationRequest(
            action: .medTele, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation, value: "enabled")
        let candidate = try await NativeAdvancedSettingValidationService(adapter: adapter).run(
            medTele, snapshot: snapshot(session))
        #expect(candidate.phase == .candidateOnly && !candidate.submitted)
        #expect(candidate.request?.frame.commandID == 0xFF && counter.count == 0)

        let executeMedTele = try NativeAdvancedSettingValidationRequest(
            action: .medTele, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            value: "enabled", execute: true)
        let unsupported = try await NativeAdvancedSettingValidationService(adapter: adapter).run(
            executeMedTele, snapshot: snapshot(session))
        #expect(unsupported.phase == .unsupported &&
            unsupported.failureCode == "unsupported_no_protocol" && counter.count == 0)
    }

    @Test func identityBaselineAndNoOpGatesPrecedeExecutor() async throws {
        let session = readySession()
        let request = try NativeAdvancedSettingValidationRequest(
            action: .isoLimit, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            value: "1600", execute: true)
        let counter = NativeAdvancedSettingCallCounter()
        let adapter = NativeAdvancedSettingValidationExecutorAdapter { _, _ in
            counter.increment()
            throw CancellationError()
        }
        let foreign = NativeAdvancedSettingValidationSnapshot(
            session: NativeCameraSessionStatus(state: .commandReady,
                generation: session.generation + 1, sessionID: sessionID,
                peerID: peerID), baseline: nil, nowUptime: 10)
        await assertThrows(.invalidRequestIdentity) {
            _ = try await NativeAdvancedSettingValidationService(adapter: adapter).run(
                request, snapshot: foreign)
        }
        await assertThrows(.baselineRequired) {
            _ = try await NativeAdvancedSettingValidationService(adapter: adapter).run(
                request, snapshot: snapshot(session))
        }
        await assertThrows(.invalidBaseline) {
            _ = try await NativeAdvancedSettingValidationService(adapter: adapter).run(
                request, snapshot: snapshot(session,
                    baseline: try observation(session, setting: .isoLimit,
                                              value: Data([1]), uptime: 1)))
        }
        #expect(counter.count == 0)

        let noOpRequest = try NativeAdvancedSettingValidationRequest(
            action: .isoLimit, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            value: "1600", execute: true)
        let noOp = try await NativeAdvancedSettingValidationService(adapter: adapter).run(
            noOpRequest, snapshot: snapshot(session,
                baseline: try observation(session, setting: .isoLimit,
                                          value: Data([Pocket3ISOLimit.iso1600.rawValue]))))
        #expect(noOp.noOp && noOp.phase == .noOp && !noOp.submitted)
        #expect(counter.count == 0)
    }
}
