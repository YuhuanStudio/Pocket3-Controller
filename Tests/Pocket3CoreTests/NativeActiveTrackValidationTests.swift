import Foundation
import Testing
@testable import Pocket3Core

@Suite("Native ActiveTrack A6 validation")
struct NativeActiveTrackValidationTests {
    private actor CallCounter {
        var count = 0
        func increment() { count += 1 }
        func value() -> Int { count }
    }

    private let sessionID = UUID()
    private let peripheralID = UUID()

    private func readySession() -> NativeCameraSessionStatus {
        var session = NativeCameraSession()
        let generation = session.begin(sessionID: sessionID, peerID: peripheralID)
        _ = session.markPaired(generation: generation)
        _ = session.markCredentialsAvailable(generation: generation)
        _ = session.observeDatalink(.connecting, generation: generation)
        _ = session.observeDatalink(.ready, generation: generation)
        return session.status
    }

    private func box() throws -> Pocket3TrackingBox {
        try Pocket3TrackingBox(centerX: 0.5, centerY: 0.5, width: 0.25, height: 0.3)
    }

    private func floatLE(_ value: Double) -> [UInt8] {
        var bits = Float(value).bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Array($0) }
    }

    private func boxPayload(_ box: Pocket3TrackingBox) -> Data {
        Data(floatLE(box.centerX) + floatLE(box.centerY) +
             floatLE(box.width) + floatLE(box.height))
    }

    private func observation(commandID: UInt8, payload: Data,
                             uptime: TimeInterval, sequence: UInt16 = 1) throws
        -> Pocket3ActiveTrackObservation {
        let frame = DUMLFrame(source: 0x01, destination: 0x02, sequence: sequence,
                              flags: 0, commandSet: 0x02, commandID: commandID,
                              payload: payload)
        return try #require(Pocket3ActiveTrackObservation(
            frame: frame, sessionID: sessionID, peripheralID: peripheralID,
            binding: Pocket3ActiveTrackObservation.bluetoothBinding(sessionID: sessionID),
            receivedAt: Date(timeIntervalSince1970: uptime + 100),
            receivedUptime: uptime))
    }

    private func a5(_ status: UInt8, box: Pocket3TrackingBox? = nil,
                    uptime: TimeInterval, sequence: UInt16 = 1) throws
        -> Pocket3ActiveTrackObservation {
        var payload = Data([0, status, 0, 0])
        if status == 1, let box { payload.append(boxPayload(box)) }
        return try observation(commandID: 0xA5, payload: payload,
                               uptime: uptime, sequence: sequence)
    }

    private func a89(_ box: Pocket3TrackingBox, uptime: TimeInterval,
                     sequence: UInt16 = 1) throws -> Pocket3ActiveTrackObservation {
        let payload = Data([0, 0, 0, 0, 0, 0x19, 0x01]) + boxPayload(box)
        return try observation(commandID: 0x89, payload: payload,
                               uptime: uptime, sequence: sequence)
    }

    private func request(_ action: NativeActiveTrackValidationOperation,
                         session: NativeCameraSessionStatus,
                         execute: Bool = false,
                         box: Pocket3TrackingBox? = nil) throws
        -> NativeActiveTrackValidationRequest {
        try NativeActiveTrackValidationRequest(
            action: action, expectedSessionID: session.sessionID!,
            peripheralID: session.peerID!, generation: session.generation,
            trackingID: action == .set ? 7 : nil, box: box,
            execute: execute, timeout: 1)
    }

    private func baseline(_ session: NativeCameraSessionStatus,
                          box: Pocket3TrackingBox) throws
        -> [Pocket3ActiveTrackObservation] {
        _ = session
        return [try a5(0, uptime: 10), try a89(box, uptime: 10.1, sequence: 2)]
    }

    private func acknowledged(_ request: NativeCommandTransactionRequest)
        -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(
            id: request.id, command: .tracking,
            generation: request.generation, sessionID: request.sessionID,
            end: .acknowledged)
        result.submitted = true
        result.submittedUptime = 11
        result.responseReceived = true
        result.responseStatus = 0
        result.acknowledged = true
        result.acknowledgedUptime = 11.1
        result.finishedUptime = 11.2
        return result
    }

    @Test func strictBoxValidationRejectsOutOfBoundsAndFloatOverflow() throws {
        #expect(Pocket3TrackingBox.isValid(centerX: 0.5, centerY: 0.5,
                                           width: 0.25, height: 0.3))
        #expect(!Pocket3TrackingBox.isValid(centerX: 0.1, centerY: 0.5,
                                            width: 0.3, height: 0.2))
        #expect(!Pocket3TrackingBox.isValid(centerX: 0.5, centerY: 0.1,
                                            width: 0.2, height: 0.3))
        #expect(throws: Pocket3NativeProtocolError.invalidTrackingBox) {
            try Pocket3TrackingBox(centerX: 0.1, centerY: 0.5,
                                   width: 0.3, height: 0.2)
        }
        #expect(throws: Pocket3NativeProtocolError.invalidTrackingBox) {
            try Pocket3TrackingBox(centerX: Double.greatestFiniteMagnitude,
                                   centerY: 0.5, width: 0.2, height: 0.2)
        }
    }

    @Test func requestSchemaAndCLIParserRequireExactSetOrClearShape() throws {
        let session = readySession()
        let parsed = try NativeActiveTrackValidationRequest(cliArguments: [
            "--action", "set", "--session", session.sessionID!.uuidString,
            "--peripheral", session.peerID!.uuidString,
            "--generation", String(session.generation), "--id", "7",
            "--x", "0.5", "--y", "0.5", "--width", "0.25", "--height", "0.3",
            "--timeout", "1", "--execute"])
        #expect(parsed.action == .set && parsed.execute && parsed.trackingID == 7)
        #expect(parsed.box?.minX == 0.375)
        #expect(abs((parsed.box?.maxY ?? 0) - 0.65) < 0.000001)
        #expect(NativeActiveTrackValidationRequest.schema["additionalProperties"] == .bool(false))

        let clear = try NativeActiveTrackValidationRequest(cliArguments: [
            "--action", "clear", "--session", session.sessionID!.uuidString,
            "--peripheral", session.peerID!.uuidString,
            "--generation", String(session.generation)])
        #expect(clear.action == .clear && clear.trackingID == nil && clear.box == nil)
        #expect(throws: BridgeFailure.self) {
            try NativeActiveTrackValidationRequest(cliArguments: [
                "--action", "clear", "--session", session.sessionID!.uuidString,
                "--peripheral", session.peerID!.uuidString,
                "--generation", String(session.generation), "--x", "0.5"])
        }
    }

    @Test func dryRunBuildsOneA6SetOrClearButNeverSubmits() async throws {
        let session = readySession()
        let target = try box()
        let base = try baseline(session, box: target)
        let service = NativeActiveTrackValidationService()
        let setResult = try await service.run(
            request(.set, session: session, box: target),
            snapshot: .init(session: session, baseline: base, nowUptime: 11))
        #expect(setResult.dryRun && setResult.requested)
        #expect(!setResult.submitted && !setResult.acknowledged && !setResult.completed)
        #expect(setResult.request.command == .tracking)
        #expect(setResult.request.frame.commandID == 0xA6)
        #expect(Pocket3TrackingBoxCommandPayload.decode(setResult.request.frame.payload)
                == .setBox(id: 7, box: target))

        let clearResult = try await service.run(
            request(.clear, session: session),
            snapshot: .init(session: session, baseline: base, nowUptime: 11))
        #expect(clearResult.request.frame.payload == Data(repeating: 0, count: 21))
        #expect(Pocket3TrackingBoxCommandPayload.decode(clearResult.request.frame.payload)
                == .clearBox)
    }

    @Test func exactIdentityAndFreshA5A89BaselineAreRequired() throws {
        let session = readySession()
        let target = try box()
        var coordinator = try NativeActiveTrackValidationCoordinator(session: session)
        let wrongGeneration = try NativeActiveTrackValidationRequest(
            action: .set, expectedSessionID: session.sessionID!,
            peripheralID: session.peerID!, generation: session.generation + 1,
            trackingID: 7, box: target)
        #expect(throws: NativeActiveTrackValidationError.invalidRequestIdentity) {
            try coordinator.prepare(wrongGeneration, baseline: try baseline(session, box: target), nowUptime: 11)
        }
        #expect(throws: NativeActiveTrackValidationError.baselineRequired) {
            try coordinator.prepare(request(.set, session: session, box: target),
                                    baseline: [try a5(0, uptime: 10)], nowUptime: 11)
        }
        #expect(throws: NativeActiveTrackValidationError.baselineRequired) {
            try coordinator.prepare(request(.set, session: session, box: target),
                                    baseline: [try a5(0, uptime: 10), try a89(target, uptime: 1)],
                                    nowUptime: 11)
        }
    }

    @Test func uncalibratedExecuteReturnsGateWithoutCallingExecutor() async throws {
        let session = readySession()
        let target = try box()
        let counter = CallCounter()
        let adapter = NativeActiveTrackValidationExecutorAdapter { _, _ in
            await counter.increment()
            fatalError("uncalibrated ActiveTrack execution must not call the executor")
        }
        let result = try await NativeActiveTrackValidationService(adapter: adapter).run(
            request(.set, session: session, execute: true, box: target),
            snapshot: .init(session: session, baseline: try baseline(session, box: target),
                            coordinateCalibration: .unverified, nowUptime: 11))
        #expect(result.requested && result.executeRequested)
        #expect(!result.submitted && !result.completed)
        #expect(result.failureCode == "active_track_coordinate_uncalibrated")
        #expect(await counter.value() == 0)
    }

    @Test func completionRequiresAckThenMatchingA5AndA89Readbacks() async throws {
        let session = readySession()
        let target = try box()
        let counter = CallCounter()
        let adapter = NativeActiveTrackValidationExecutorAdapter { request, _ in
            await counter.increment()
            return NativeActiveTrackExecutionResult(
                transaction: acknowledged(request),
                observations: [try a5(1, box: target, uptime: 11.3, sequence: 2),
                                try a89(target, uptime: 11.4, sequence: 3)])
        }
        let result = try await NativeActiveTrackValidationService(adapter: adapter).run(
            request(.set, session: session, execute: true, box: target),
            snapshot: .init(session: session, baseline: try baseline(session, box: target),
                            coordinateCalibration: .cameraNativeCoordinates, nowUptime: 11.5))
        #expect(await counter.value() == 1)
        #expect(result.requested && result.submitted && result.acknowledged)
        #expect(result.observed && result.completed)
        #expect(result.phase == .completed && result.failureCode == nil)
        #expect(result.a5Readback?.state.isLocked == true)
        #expect(result.a89Readback?.state.isSubjectBox == true)
    }

    @Test func missingPostAckReadbackCannotCompleteClear() async throws {
        let session = readySession()
        let target = try box()
        let adapter = NativeActiveTrackValidationExecutorAdapter { request, _ in
            NativeActiveTrackExecutionResult(
                transaction: acknowledged(request),
                observations: [try self.a5(0, uptime: 11.3, sequence: 2)])
        }
        let result = try await NativeActiveTrackValidationService(adapter: adapter).run(
            request(.clear, session: session, execute: true),
            snapshot: .init(session: session, baseline: try baseline(session, box: target),
                            coordinateCalibration: .cameraNativeCoordinates, nowUptime: 11.5))
        #expect(result.submitted && result.acknowledged)
        #expect(!result.observed && !result.completed)
        #expect(result.phase == .awaitingReadback)
    }
}
