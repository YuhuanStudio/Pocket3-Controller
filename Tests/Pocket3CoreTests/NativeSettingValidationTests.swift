import Foundation
import Testing
@testable import Pocket3Core

private final class NativeSettingCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("Native setting validation service")
struct NativeSettingValidationTests {
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

    private func imageEffectBaseline(
        _ session: NativeCameraSessionStatus,
        raw: Data = Data([0, 0, 0, 0, 0, 0]),
        uptime: TimeInterval = 10
    ) -> Pocket3NativeSettingObservation {
        Pocket3NativeSettingObservation(sessionID: session.sessionID!,
            generation: session.generation, receivedUptime: uptime,
            property: .imageEffect, raw: raw)
    }

    private func lensBaseline(
        _ session: NativeCameraSessionStatus,
        raw: Data = Data([0xB1]),
        uptime: TimeInterval = 10
    ) -> Pocket3NativeSettingObservation {
        Pocket3NativeSettingObservation(sessionID: session.sessionID!,
            generation: session.generation, receivedUptime: uptime,
            property: .lensState, raw: raw)
    }

    private func showcaseBaseline(
        _ session: NativeCameraSessionStatus,
        mode: UInt8 = 0,
        uptime: TimeInterval = 10
    ) -> Pocket3NativeSettingObservation {
        let raw = Data([0, 0, 1, 0x3B, 0, 2, 1, mode])
        return Pocket3NativeSettingObservation(sessionID: session.sessionID!,
            generation: session.generation, receivedUptime: uptime,
            readback: .productShowcase(Pocket3ProductShowcaseReadback(
                raw: raw, modeRaw: mode)))
    }

    private func snapshot(
        _ session: NativeCameraSessionStatus,
        baseline: Pocket3NativeSettingObservation?,
        now: TimeInterval = 10
    ) -> NativeSettingValidationSnapshot {
        NativeSettingValidationSnapshot(session: session, baseline: baseline,
                                        nowUptime: now)
    }

    private func transaction(
        for request: NativeCommandTransactionRequest,
        observedPayload: Data? = nil,
        end: NativeCommandTransactionEnd = .acknowledged
    ) -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: request.generation,
            sessionID: request.sessionID, end: end)
        result.sequence = 0x6001
        result.submitted = true
        result.submittedUptime = 11
        result.responseReceived = true
        result.acknowledged = true
        result.acknowledgedUptime = 11.01
        result.observedPayload = observedPayload
        result.observed = observedPayload != nil
        result.observedUptime = observedPayload == nil ? nil : 12
        result.finishedUptime = 12
        return result
    }

    private func propertyFrame(
        _ property: CameraSettingsProperty,
        raw: Data
    ) -> DUMLFrame {
        var bytes: [UInt8] = [2, 6, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        func append16(_ value: Int) {
            bytes += [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
        }
        let name = Array(property.rawValue.utf8)
        append16(name.count + raw.count + 10)
        append16(name.count)
        bytes += name
        bytes += [0, 0, 0, 0, 0, 0]
        append16(raw.count)
        bytes += raw
        return DUMLFrame(source: 0x28, destination: 0x02, sequence: 9,
            flags: 0, commandSet: 0, commandID: 0x99, payload: Data(bytes))
    }

    private func showcaseFrame(mode: UInt8) -> DUMLFrame {
        DUMLFrame(source: 0x01, destination: 0x02, sequence: 9,
            flags: 0x80, commandSet: 0x02, commandID: 0x8E,
            payload: Data([0, 0, 1, 0x3B, 0, 2, 1, mode]))
    }

    @Test func requestIsStrictTypedAndDefaultsToDryRun() throws {
        let request = try NativeSettingValidationRequest(cliArguments: [
            "--action", "white-balance", "--session", sessionID.uuidString,
            "--peripheral", peerID.uuidString, "--generation", "3",
            "--value", "5600"
        ])
        #expect(request.action == .whiteBalance)
        #expect(request.whiteBalance == .customKelvin(5600))
        #expect(!request.execute)

        let decoded = try JSONDecoder().decode(NativeSettingValidationRequest.self,
            from: JSONEncoder().encode(request))
        #expect(decoded == request)
        #expect(throws: NativeSettingValidationError.invalidValue) {
            try NativeSettingValidationRequest(arguments: .object([
                "action": .string("color-profile"),
                "expectedSessionID": .string(sessionID.uuidString),
                "peripheralID": .string(peerID.uuidString),
                "generation": .number(3), "value": .string("future")
            ]))
        }
    }

    @Test func dryRunPreparesOneTypedRequestWithoutCallingExecutor() async throws {
        let session = readySession()
        let request = try NativeSettingValidationRequest(
            action: .whiteBalance, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            target: .whiteBalance(.customKelvin(5600)))
        let counter = NativeSettingCallCounter()
        let adapter = NativeSettingValidationExecutorAdapter { _, _ in
            counter.increment()
            return NativeCommandTransactionResult(id: UUID(), command: .whiteBalance,
                generation: 1, end: .failed)
        }
        let result = try await NativeSettingValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session, baseline: imageEffectBaseline(session)))
        #expect(result.dryRun && !result.executeRequested)
        #expect(result.request?.frame.commandID == 0x2C)
        #expect(result.setting?.phase == .awaitingAcknowledgment)
        #expect(!result.submitted && !result.completed && counter.count == 0)
    }

    @Test func executeCompletesColorAfterOneMatchingReadback() async throws {
        let session = readySession()
        let request = try NativeSettingValidationRequest(
            action: .colorProfile, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            target: .colorProfile(.dLogM), execute: true)
        let counter = NativeSettingCallCounter()
        let adapter = NativeSettingValidationExecutorAdapter { request, _ in
            counter.increment()
            let frame = self.propertyFrame(.imageEffect,
                raw: Data([0, 0, 0x3D, 0, 0, 0]))
            let observed = request.observationHandler()!(frame)
            return self.transaction(for: request, observedPayload: observed,
                                    end: .observed)
        }
        let result = try await NativeSettingValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session, baseline: imageEffectBaseline(session)))
        #expect(counter.count == 1)
        #expect(result.submitted && result.acknowledged && result.observed)
        #expect(result.completed && result.setting?.phase == .completed)
        #expect(result.setting?.readback?.readback.imageEffect?.colorProfile == .dLogM)
    }

    @Test func showcaseUsesKeyedReadbackAndNoOpAvoidsExecutor() async throws {
        let session = readySession()
        let request = try NativeSettingValidationRequest(
            action: .productShowcase, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            target: .productShowcase(.on), execute: true)
        let counter = NativeSettingCallCounter()
        let adapter = NativeSettingValidationExecutorAdapter { request, _ in
            counter.increment()
            let observed = request.observationHandler()!(self.showcaseFrame(mode: 1))
            return self.transaction(for: request, observedPayload: observed,
                                    end: .observed)
        }
        let result = try await NativeSettingValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session,
                baseline: showcaseBaseline(session)))
        #expect(counter.count == 1 && result.completed)
        #expect(result.setting?.readback?.readback.showcase?.mode == .on)

        let noOpRequest = try NativeSettingValidationRequest(
            action: .productShowcase, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            target: .productShowcase(.off), execute: true)
        let noOp = try await NativeSettingValidationService(adapter: adapter).run(
            noOpRequest, snapshot: snapshot(session,
                baseline: showcaseBaseline(session, mode: 0)))
        #expect(noOp.noOp && !noOp.submitted && counter.count == 1)
    }

    @Test func ackOnlyAndCancellationKeepPartialEvidenceWithoutRetry() async throws {
        let session = readySession()
        let request = try NativeSettingValidationRequest(
            action: .focusMode, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            target: .focusMode(.continuous), execute: true)
        let ackCounter = NativeSettingCallCounter()
        let ackAdapter = NativeSettingValidationExecutorAdapter { request, _ in
            ackCounter.increment()
            return self.transaction(for: request)
        }
        let ack = try await NativeSettingValidationService(adapter: ackAdapter).run(
            request, snapshot: snapshot(session, baseline: lensBaseline(session)))
        #expect(ackCounter.count == 1 && ack.acknowledged)
        #expect(!ack.observed && !ack.completed &&
            ack.setting?.phase == .awaitingReadback)

        let cancelCounter = NativeSettingCallCounter()
        let cancelAdapter = NativeSettingValidationExecutorAdapter { _, _ in
            cancelCounter.increment()
            throw CancellationError()
        }
        let cancelled = try await NativeSettingValidationService(adapter: cancelAdapter).run(
            request, snapshot: snapshot(session, baseline: lensBaseline(session)))
        #expect(cancelCounter.count == 1 && cancelled.setting?.phase == .cancelled)
        #expect(!cancelled.completed && cancelled.failureCode == "cancelled")
    }

    @Test func unknownReadbackIsRetainedAndIdentityOrBaselineGatesPrecedeExecutor() async throws {
        let session = readySession()
        let request = try NativeSettingValidationRequest(
            action: .whiteBalance, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            target: .whiteBalance(.automatic), execute: true)
        let adapter = NativeSettingValidationExecutorAdapter { request, _ in
            let frame = self.propertyFrame(.imageEffect,
                raw: Data([0, 0, 0, 0, 0xEE, 0x12]))
            let observed = request.observationHandler()!(frame)
            return self.transaction(for: request, observedPayload: observed,
                                    end: .observed)
        }
        let result = try await NativeSettingValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session,
                baseline: imageEffectBaseline(session,
                    raw: Data([0, 0, 0, 0, 0x06, 0x38]))))
        #expect(result.observed && !result.completed)
        #expect(result.setting?.readback?.isUnknown == true)
        #expect(result.setting?.readback?.raw == Data([0, 0, 0, 0, 0xEE, 0x12]))

        let count = NativeSettingCallCounter()
        let rejectingAdapter = NativeSettingValidationExecutorAdapter { _, _ in
            count.increment()
            throw CancellationError()
        }
        let foreign = NativeSettingValidationSnapshot(
            session: NativeCameraSessionStatus(state: .commandReady,
                generation: session.generation + 1, sessionID: sessionID,
                peerID: peerID), baseline: nil, nowUptime: 10)
        var identityError: NativeSettingValidationError?
        do {
            _ = try await NativeSettingValidationService(adapter: rejectingAdapter).run(
                request, snapshot: foreign)
        } catch let error as NativeSettingValidationError {
            identityError = error
        }
        #expect(identityError == .invalidRequestIdentity && count.count == 0)

        var baselineError: NativeSettingValidationError?
        do {
            _ = try await NativeSettingValidationService(adapter: rejectingAdapter).run(
                request, snapshot: snapshot(session, baseline: nil))
        } catch let error as NativeSettingValidationError {
            baselineError = error
        }
        #expect(baselineError == .baselineRequired && count.count == 0)
    }
}
