import Foundation
import Testing
@testable import Pocket3Core

private final class NativeMotionCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("Native motion validation service")
struct NativeMotionValidationTests {
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

    private func lensRaw(_ position: UInt16, focus: UInt8 = 0xB2) -> Data {
        var value = Data(repeating: 0, count: 47)
        value[0] = focus
        value[14] = UInt8(position & 0xFF)
        value[15] = UInt8(position >> 8)
        return value
    }

    private func zoomBaseline(_ session: NativeCameraSessionStatus,
                              position: UInt16 = 100,
                              uptime: TimeInterval = 10)
        -> Pocket3NativeLensStateObservation {
        Pocket3NativeLensStateObservation(sessionID: session.sessionID!,
            generation: session.generation, receivedUptime: uptime,
            raw: lensRaw(position))
    }

    private func gimbalBaseline(_ session: NativeCameraSessionStatus,
                                mode: UInt8 = 0, speed: UInt8 = 1,
                                uptime: TimeInterval = 10)
        -> Pocket3NativeGimbalParameterObservation {
        Pocket3NativeGimbalParameterObservation(sessionID: session.sessionID!,
            generation: session.generation, receivedUptime: uptime,
            raw: Data([0, 1, 4, 1, mode, 5, 1, speed]))
    }

    private func snapshot(_ session: NativeCameraSessionStatus,
                          zoom: Pocket3NativeLensStateObservation? = nil,
                          gimbal: Pocket3NativeGimbalParameterObservation? = nil,
                          now: TimeInterval = 10) -> NativeMotionValidationSnapshot {
        NativeMotionValidationSnapshot(session: session, zoomBaseline: zoom,
            gimbalBaseline: gimbal, nowUptime: now)
    }

    private func ackTransaction(for request: NativeCommandTransactionRequest,
                                observedPayload: Data? = nil,
                                observedUptime: TimeInterval? = nil,
                                end: NativeCommandTransactionEnd = .acknowledged)
        -> NativeCommandTransactionResult {
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
        result.observedUptime = observedUptime
        return result
    }

    private func lensReadbackFrame(_ raw: Data) -> DUMLFrame {
        // The transaction matcher only needs a valid named property push;
        // this fixture mirrors the existing 00/99 value envelope.
        var bytes: [UInt8] = [2, 6, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        func append16(_ value: Int) {
            bytes += [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
        }
        let name = Array("cam_lens_state".utf8)
        append16(name.count + raw.count + 10)
        append16(name.count)
        bytes += name
        bytes += [0, 0, 0, 0, 0, 0]
        append16(raw.count)
        bytes += raw
        return DUMLFrame(source: 0x28, destination: 2, sequence: 9,
            flags: 0, commandSet: 0, commandID: 0x99, payload: Data(bytes))
    }

    @Test func requestParsesStrictCLIAndDefaultsToDryRun() throws {
        let request = try NativeMotionValidationRequest(cliArguments: [
            "--action", "zoom-absolute", "--session", sessionID.uuidString,
            "--peripheral", peerID.uuidString, "--generation", "3",
            "--format", "1080p", "--raw", "150"])
        #expect(request.action == .zoomAbsolute && !request.execute)
        #expect(request.format == .fullHD && request.rawValue == 150)
        let decoded = try JSONDecoder().decode(NativeMotionValidationRequest.self,
            from: JSONEncoder().encode(request))
        #expect(decoded == request)

        let gimbal = try NativeMotionValidationRequest(arguments: .object([
            "action": .string("gimbal-speed"),
            "expectedSessionID": .string(sessionID.uuidString),
            "peripheralID": .string(peerID.uuidString),
            "generation": .number(3), "speed": .string("slow")]))
        #expect(gimbal.action == .gimbalSpeed && gimbal.speed == .slow)
        #expect(throws: NativeMotionValidationError.invalidArguments) {
            try NativeMotionValidationRequest(arguments: .object([
                "action": .string("zoom-stop"),
                "expectedSessionID": .string(sessionID.uuidString),
                "peripheralID": .string(peerID.uuidString),
                "generation": .number(3), "rawValue": .number(150)]))
        }
    }

    @Test func dryRunPreparesOneRequestWithoutCallingExecutor() async throws {
        let session = readySession()
        let request = try NativeMotionValidationRequest(
            action: .zoomAbsolute, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            format: .fullHD, rawValue: 150)
        let counter = NativeMotionCallCounter()
        let adapter = NativeMotionValidationExecutorAdapter { _, _ in
            counter.increment()
            return NativeCommandTransactionResult(id: UUID(), command: .zoom,
                generation: 1, end: .failed)
        }
        let result = try await NativeMotionValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session, zoom: zoomBaseline(session)))
        #expect(result.dryRun && !result.executeRequested)
        #expect(result.request?.frame.commandID == 0xB8)
        #expect(!result.submitted && !result.completed && counter.count == 0)
    }

    @Test func executeCallsTheExistingExecutorOnceAndRequiresMatchingLensReadback() async throws {
        let session = readySession()
        let request = try NativeMotionValidationRequest(
            action: .zoomAbsolute, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            format: .fullHD, rawValue: 150, execute: true)
        let counter = NativeMotionCallCounter()
        let adapter = NativeMotionValidationExecutorAdapter { request, _ in
            counter.increment()
            let frame = self.lensReadbackFrame(self.lensRaw(150))
            let observed = request.observationHandler()!(frame)
            return self.ackTransaction(for: request, observedPayload: observed,
                observedUptime: 12, end: .observed)
        }
        let result = try await NativeMotionValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session, zoom: zoomBaseline(session)))
        #expect(counter.count == 1)
        #expect(result.executeRequested && result.submitted && result.acknowledged)
        #expect(result.observed && result.completed && result.phase == "completed")
        #expect(result.zoom?.readback?.zoomPositionRaw == 150)
    }

    @Test func ACKOnlyAndCancellationPreservePartialEvidenceWithoutRetry() async throws {
        let session = readySession()
        let ackRequest = try NativeMotionValidationRequest(
            action: .gimbalMode, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            mode: .tiltLocked, execute: true)
        let ackCounter = NativeMotionCallCounter()
        let ackAdapter = NativeMotionValidationExecutorAdapter { request, _ in
            ackCounter.increment()
            return self.ackTransaction(for: request)
        }
        let ackResult = try await NativeMotionValidationService(adapter: ackAdapter).run(
            ackRequest, snapshot: snapshot(session, gimbal: gimbalBaseline(session)))
        #expect(ackCounter.count == 1 && ackResult.acknowledged)
        #expect(ackResult.observed == false && ackResult.completed == false)
        #expect(ackResult.phase == "awaitingReadback")

        let cancelCounter = NativeMotionCallCounter()
        let cancelAdapter = NativeMotionValidationExecutorAdapter { _, _ in
            cancelCounter.increment()
            throw CancellationError()
        }
        let cancelResult = try await NativeMotionValidationService(adapter: cancelAdapter).run(
            ackRequest, snapshot: snapshot(session, gimbal: gimbalBaseline(session)))
        #expect(cancelCounter.count == 1 && cancelResult.phase == "cancelled")
        #expect(!cancelResult.completed)
    }

    @Test func gimbalUnknownReadbackRemainsRawAndDoesNotComplete() async throws {
        let session = readySession()
        let request = try NativeMotionValidationRequest(
            action: .gimbalSpeed, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation,
            speed: .slow, execute: true)
        let unknownRaw = Data([0, 1, 4, 1, 0xFE, 5, 1, 0xFD])
        let adapter = NativeMotionValidationExecutorAdapter { request, _ in
            let frame = DUMLFrame(source: 4, destination: 2, sequence: 1,
                flags: 0x80, commandSet: 4, commandID: 0x50,
                payload: unknownRaw)
            let observed = request.observationHandler()!(frame)
            return self.ackTransaction(for: request, observedPayload: observed,
                observedUptime: 12, end: .observed)
        }
        let result = try await NativeMotionValidationService(adapter: adapter).run(
            request, snapshot: snapshot(session, gimbal: gimbalBaseline(session)))
        #expect(result.observed && !result.completed && result.phase == "awaitingReadback")
        #expect(result.gimbal?.readback?.raw == unknownRaw)
        #expect(result.gimbal?.readback?.readback?.speed == nil)
    }

    @Test func serviceRejectsForeignGenerationAndMissingBaselinesBeforeExecutor() async throws {
        let session = readySession()
        let request = try NativeMotionValidationRequest(
            action: .zoomStop, expectedSessionID: sessionID,
            peripheralID: peerID, generation: session.generation, execute: true)
        let counter = NativeMotionCallCounter()
        let adapter = NativeMotionValidationExecutorAdapter { _, _ in
            counter.increment()
            throw CancellationError()
        }
        let foreign = NativeMotionValidationSnapshot(
            session: NativeCameraSessionStatus(state: .commandReady,
                generation: session.generation + 1, sessionID: sessionID,
                peerID: peerID), zoomBaseline: nil, nowUptime: 10)
        var foreignError: NativeMotionValidationError?
        do {
            _ = try await NativeMotionValidationService(adapter: adapter).run(
                request, snapshot: foreign)
        } catch let error as NativeMotionValidationError {
            foreignError = error
        }
        #expect(foreignError == .invalidRequestIdentity)
        #expect(counter.count == 0)
        var baselineError: NativeMotionValidationError?
        do {
            _ = try await NativeMotionValidationService(adapter: adapter).run(
                request, snapshot: snapshot(session))
        } catch let error as NativeMotionValidationError {
            baselineError = error
        }
        #expect(baselineError == .zoomBaselineRequired)
    }
}
