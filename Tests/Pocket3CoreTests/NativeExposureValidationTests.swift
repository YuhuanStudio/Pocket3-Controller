import Foundation
import Testing
@testable import Pocket3Core

private final class NativeExposureTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() { lock.withLock { storage += 1 } }
    var count: Int { lock.withLock { storage } }
}

@Suite("Native exposure validation")
struct NativeExposureValidationTests {
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

    private func raw(mode: Pocket3ExposureMode,
                     ev: UInt8 = 0x10,
                     iso: UInt8 = Pocket3ExposureISOIndex.automatic.rawValue,
                     denominator: UInt16 = 30,
                     effectiveISO: UInt32 = 100,
                     trailer: UInt8 = 0) -> Data {
        var value = Data(repeating: 0, count: 20)
        let encoded = denominator | 0x8000
        value[1] = UInt8(encoded & 0xff)
        value[2] = UInt8(encoded >> 8)
        value[3] = trailer
        value[5] = iso
        value[6] = ev
        value[7] = mode.rawValue
        value[16] = UInt8(effectiveISO & 0xff)
        value[17] = UInt8((effectiveISO >> 8) & 0xff)
        value[18] = UInt8((effectiveISO >> 16) & 0xff)
        value[19] = UInt8((effectiveISO >> 24) & 0xff)
        return value
    }

    private func observation(_ session: NativeCameraSessionStatus,
                             raw: Data, uptime: TimeInterval = 10)
        throws -> Pocket3ExposureObservation {
        try #require(Pocket3ExposureObservation(
            sessionID: session.sessionID!, generation: session.generation,
            receivedUptime: uptime, raw: raw))
    }

    private func snapshot(_ session: NativeCameraSessionStatus,
                          exposure: Pocket3ExposureObservation? = nil,
                          isoLimit: Pocket3AdvancedSettingObservation? = nil,
                          now: TimeInterval = 10)
        -> Pocket3ExposureValidationSnapshot {
        Pocket3ExposureValidationSnapshot(session: session, exposure: exposure,
            isoLimit: isoLimit,
            modeContext: .init(shootingModeRaw: Pocket3ShootingMode.video.rawValue,
                               frameRateRaw: CameraFrameRate.fps30.rawValue),
            nowUptime: now)
    }

    private func transaction(_ request: NativeCommandTransactionRequest,
                             end: NativeCommandTransactionEnd = .acknowledged)
        -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: request.generation,
            sessionID: request.sessionID, end: end)
        result.submitted = true
        result.submittedUptime = 11
        result.responseReceived = true
        result.acknowledged = end == .acknowledged || end == .observed
        result.acknowledgedUptime = result.acknowledged ? 11.01 : nil
        result.finishedUptime = 11.02
        return result
    }

    @Test func requestRoundTripsJSONAndCLIWithDryRunDefault() throws {
        let request = try NativeExposureValidationRequest(cliArguments: [
            "--action", "ev", "--session", sessionID.uuidString,
            "--peripheral", peerID.uuidString, "--generation", "3",
            "--value", "+1.0"])
        #expect(request.action == .ev && !request.execute)
        #expect(request.operation == .ev(try Pocket3ExposureEV(thirdStops: 3)))
        #expect(NativeExposureValidationRequest.schema["additionalProperties"] == .bool(false))
        let decoded = try JSONDecoder().decode(
            NativeExposureValidationRequest.self,
            from: JSONEncoder().encode(request))
        #expect(decoded == request)

        let preset = try NativeExposureValidationRequest(
            action: .manualPreset, expectedSessionID: sessionID,
            peripheralID: peerID, generation: 3, iso: "100", shutter: "1/50")
        #expect(preset.operation == .manualPreset(.init(
            iso: .iso100, shutter: try .init(denominator: 50))))
    }

    @Test func dryRunPreparesExposureWithoutCallingExecutor() async throws {
        let session = readySession()
        let baseline = try observation(session,
            raw: raw(mode: .automatic, ev: 0x10))
        let request = try NativeExposureValidationRequest(
            action: .ev, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            value: "+1.0")
        let counter = NativeExposureTestCounter()
        let adapter = NativeExposureValidationExecutorAdapter { _, _ in
            counter.increment()
            throw CancellationError()
        }
        let result = try await NativeExposureValidationService(adapter: adapter)
            .run(request, snapshot: snapshot(session, exposure: baseline))
        #expect(result.dryRun && result.phase == .dryRun)
        #expect(result.request?.frame.commandID == 0x2E)
        #expect(!result.submitted && !result.completed && counter.count == 0)
    }

    @Test func executeNeedsMatchingFreshReadbackAfterACK() async throws {
        let session = readySession()
        let baseline = try observation(session,
            raw: raw(mode: .automatic, ev: 0x10))
        let request = try NativeExposureValidationRequest(
            action: .ev, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            value: "+1.0", execute: true)

        let ackAdapter = NativeExposureValidationExecutorAdapter { request, _ in
            Pocket3ExposureExecutionResult(transaction: transaction(request))
        }
        let ack = try await NativeExposureValidationService(adapter: ackAdapter)
            .run(request, snapshot: snapshot(session, exposure: baseline))
        #expect(ack.acknowledged && !ack.observed && !ack.completed)
        #expect(ack.phase == .awaitingReadback)

        let matching = try observation(session,
            raw: raw(mode: .automatic, ev: 0x13), uptime: 12)
        let completeAdapter = NativeExposureValidationExecutorAdapter { request, _ in
            Pocket3ExposureExecutionResult(transaction: transaction(request),
                                           exposureReadback: matching)
        }
        let complete = try await NativeExposureValidationService(adapter: completeAdapter)
            .run(request, snapshot: snapshot(session, exposure: baseline))
        #expect(complete.observed && complete.completed)
        #expect(complete.phase == .completed && complete.steps.count == 1)
    }

    @Test func manualPresetSendsExactlyModeISOThenShutter() async throws {
        let session = readySession()
        let baseline = try observation(session,
            raw: raw(mode: .automatic,
                     iso: Pocket3ExposureISOIndex.automatic.rawValue))
        let shutter = try Pocket3ExposureShutterSelection(denominator: 50)
        let request = try NativeExposureValidationRequest(
            action: .manualPreset, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            iso: "100", shutter: "1/50", execute: true)
        let counter = NativeExposureTestCounter()
        let adapter = NativeExposureValidationExecutorAdapter { request, _ in
            counter.increment()
            let value: Data
            switch request.frame.commandID {
            case 0x1E:
                value = self.raw(mode: .manual,
                                 iso: Pocket3ExposureISOIndex.automatic.rawValue)
            case 0x2A:
                value = self.raw(mode: .manual,
                                 iso: Pocket3ExposureISOIndex.iso100.rawValue,
                                 effectiveISO: 100)
            default:
                value = self.raw(mode: .manual,
                                 iso: Pocket3ExposureISOIndex.iso100.rawValue,
                                 denominator: 50, effectiveISO: 100)
            }
            let readback = try self.observation(session, raw: value,
                                                 uptime: 12 + Double(counter.count))
            return Pocket3ExposureExecutionResult(transaction: self.transaction(request),
                                                   exposureReadback: readback)
        }
        let result = try await NativeExposureValidationService(adapter: adapter)
            .run(request, snapshot: snapshot(session, exposure: baseline))
        let allCompleted = result.steps.allSatisfy { $0.completed }
        let commandIDs = result.steps.map { $0.request.frame.commandID }
        let targets = result.steps.map { $0.target }
        #expect(counter.count == 3 && result.completed)
        #expect(result.steps.count == 3 && allCompleted)
        #expect(commandIDs == [0x1E, 0x2A, 0x28])
        #expect(targets == [
            .mode(.manual), .iso(.iso100), .shutter(shutter)])
    }

    @Test func unknownSelectedISOStaysPartialAndDoesNotRetry() async throws {
        let session = readySession()
        let baseline = try observation(session,
            raw: raw(mode: .manual,
                     iso: Pocket3ExposureISOIndex.iso100.rawValue, effectiveISO: 100))
        let request = try NativeExposureValidationRequest(
            action: .iso, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            value: "50", execute: true)
        let counter = NativeExposureTestCounter()
        let unknown = try observation(session,
            raw: raw(mode: .manual, iso: 0x01, effectiveISO: 50), uptime: 12)
        let adapter = NativeExposureValidationExecutorAdapter { request, _ in
            counter.increment()
            return Pocket3ExposureExecutionResult(transaction: transaction(request),
                                                   exposureReadback: unknown)
        }
        let result = try await NativeExposureValidationService(adapter: adapter)
            .run(request, snapshot: snapshot(session, exposure: baseline))
        let phase = result.phase
        #expect(counter.count == 1 && result.observed)
        #expect(!result.completed && phase == NativeExposureValidationPhase.awaitingReadback)
    }

    @Test func isoLimitExecuteRequiresFreshKeyedBaseline() async throws {
        let session = readySession()
        let request = try NativeExposureValidationRequest(
            action: .isoLimit, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            value: "1600", execute: true)
        let counter = NativeExposureTestCounter()
        let adapter = NativeExposureValidationExecutorAdapter { _, _ in
            counter.increment()
            throw CancellationError()
        }
        await #expect(throws: Pocket3ExposureValidationError.baselineRequired) {
            _ = try await NativeExposureValidationService(adapter: adapter)
                .run(request, snapshot: snapshot(session))
        }
        #expect(counter.count == 0)
    }
}
