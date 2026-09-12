import Foundation
import Testing
@testable import Pocket3Core

@Suite("Native tap-AF validation")
struct NativeTapFocusValidationTests {
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

    private var binding: ContinuousGimbalBinding {
        ContinuousGimbalBinding(sessionID: "ble:\(sessionID.uuidString)", generation: 0)
    }

    private func baseline(_ session: NativeCameraSessionStatus,
                          lens: CameraFocusMode = .continuous,
                          exposureMode: CameraExposureMode = .automatic,
                          at uptime: TimeInterval = 10) -> [CameraSettingsObservation] {
        _ = session
        return [
            CameraSettingsObservation(property: .lensState, value: .focus(lens),
                exposureMode: nil, transactionID: 1, binding: binding,
                receivedUptime: uptime),
            CameraSettingsObservation(property: .exposure,
                value: .autoEV(thirdStops: 0), exposureMode: exposureMode,
                transactionID: 2, binding: binding,
                receivedUptime: uptime + 0.1)
        ]
    }

    private func request(_ session: NativeCameraSessionStatus,
                         execute: Bool = false) throws
        -> NativeTapFocusValidationRequest {
        try NativeTapFocusValidationRequest(
            expectedSessionID: session.sessionID!, peripheralID: session.peerID!,
            generation: session.generation, x: 0.3, y: 0.7,
            execute: execute, timeout: 0.8)
    }

    private func transaction(for request: NativeCommandTransactionRequest,
                             index: Int = 0,
                             end: NativeCommandTransactionEnd = .acknowledged)
        -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(
            id: request.id, command: .focusMode,
            generation: request.generation, sessionID: request.sessionID,
            end: end)
        result.sequence = UInt16(100 + index)
        result.submitted = true
        result.submittedUptime = 10.2 + Double(index) * 0.1
        result.responseReceived = end != .timedOut && end != .cancelled
        result.responseStatus = end == .acknowledged ? 0 : 1
        result.acknowledged = end == .acknowledged
        result.acknowledgedUptime = result.acknowledged ? 10.3 + Double(index) * 0.1 : nil
        result.finishedUptime = 10.35 + Double(index) * 0.1
        return result
    }

    @Test func typedCalibrationKeepsOrientationRotationAndMirrorExplicit() throws {
        let calibration = NativeTapFocusCoordinateCalibration(
            orientation: .portrait, rotation: .ninety, mirrored: true,
            verified: false)
        let decoded = try JSONDecoder().decode(
            NativeTapFocusCoordinateCalibration.self,
            from: JSONEncoder().encode(calibration))
        #expect(decoded == calibration)
        #expect(!calibration.verified)
        #expect(calibration.orientation == .portrait && calibration.rotation == .ninety)
        #expect(calibration.mirrored)
    }

    @Test func requestSchemaAndCLIParserValidateExactCoordinatesAndIdentity() throws {
        let session = readySession()
        let parsed = try NativeTapFocusValidationRequest(cliArguments: [
            "--session", session.sessionID!.uuidString,
            "--peripheral", session.peerID!.uuidString,
            "--generation", String(session.generation),
            "--x", "0.3", "--y", "0.7", "--timeout", "0.8", "--execute"])
        #expect(parsed.execute && parsed.x == 0.3 && parsed.y == 0.7)
        #expect(parsed.arguments["execute"] == .bool(true))
        #expect(NativeTapFocusValidationRequest.schema["additionalProperties"] == .bool(false))
        let roundTrip = try JSONDecoder().decode(
            NativeTapFocusValidationRequest.self,
            from: JSONEncoder().encode(parsed))
        #expect(roundTrip == parsed)

        #expect(throws: BridgeFailure.self) {
            try NativeTapFocusValidationRequest(cliArguments: [
                "--session", session.sessionID!.uuidString,
                "--peripheral", session.peerID!.uuidString,
                "--generation", String(session.generation),
                "--x", "0.05", "--y", "0.7"])
        }
        #expect(throws: BridgeFailure.self) {
            try NativeTapFocusValidationRequest(arguments: .object([
                "expectedSessionID": .string(session.sessionID!.uuidString),
                "peripheralID": .string(session.peerID!.uuidString),
                "generation": .number(Double(session.generation)),
                "x": .number(0.3), "y": .number(0.7),
                "timeout": .string("0.8")]))
        }
    }

    @Test func dryRunReusesFourOrderedNativeFramesWithoutSubmitting() async throws {
        let session = readySession()
        let input = try request(session)
        var coordinator = try NativeTapFocusValidationCoordinator(session: session)
        try coordinator.prepare(input, observations: baseline(session), nowUptime: 11)
        #expect(coordinator.stepRequests.map { $0.frame.commandID }
                == [0x22, 0x30, 0x68, 0x32])
        #expect(coordinator.stepRequests.map { $0.frame.payload.count }
                == [1, 21, 1, 20])
        #expect(coordinator.nextRequest?.frame.commandID == 0x22)

        let result = try await NativeTapFocusValidationService().run(
            input, snapshot: .init(session: session, observations: baseline(session),
                                   coordinateCalibration: .unverifiedLandscape,
                                   nowUptime: 11))
        #expect(result.requested && result.steps.count == 4)
        #expect(result.steps.map(\.commandID) == [0x22, 0x30, 0x68, 0x32])
        #expect(result.submittedCount == 0 && result.acknowledgedCount == 0)
        #expect(!result.completed && result.phase == .awaitingAcknowledgment)
    }

    @Test func uncalibratedExecuteDoesNotCallExecutor() async throws {
        let session = readySession()
        let counter = CallCounter()
        let adapter = NativeTapFocusValidationExecutorAdapter { _, _ in
            await counter.increment()
            fatalError("uncalibrated native tap-AF must not execute")
        }
        let result = try await NativeTapFocusValidationService(adapter: adapter).run(
            try request(session, execute: true),
            snapshot: .init(session: session, observations: baseline(session),
                            coordinateCalibration: .unverifiedPortrait,
                            nowUptime: 11))
        #expect(result.requested && !result.completed)
        #expect(result.submittedCount == 0 && result.failureCode == "native_tap_focus_coordinates_uncalibrated")
        #expect(await counter.value() == 0)
    }

    @Test func verifiedExecutionCallsEachStepOnceInOrderAndCompletesOnACKs() async throws {
        let session = readySession()
        let counter = CallCounter()
        let commands = NativeTapFocusValidationExecutorAdapter { request, _ in
            await counter.increment()
            return transaction(for: request, index: await counter.value() - 1)
        }
        let result = try await NativeTapFocusValidationService(adapter: commands).run(
            try request(session, execute: true),
            snapshot: .init(session: session, observations: baseline(session),
                            coordinateCalibration: .init(orientation: .landscape,
                                rotation: .zero, mirrored: false, verified: true),
                            nowUptime: 11))
        #expect(await counter.value() == 4)
        #expect(result.submittedCount == 4 && result.acknowledgedCount == 4)
        #expect(result.completed && result.phase == .completed)
        #expect(result.steps.map(\.commandID) == [0x22, 0x30, 0x68, 0x32])
        #expect(result.verification == "four_step_ack_only_no_optical_focus_readback")
    }

    @Test func cancellationPreservesEarlierPartialEvidenceWithoutRetry() async throws {
        let session = readySession()
        let counter = CallCounter()
        let adapter = NativeTapFocusValidationExecutorAdapter { request, _ in
            let index = await counter.value()
            await counter.increment()
            if index == 1 { throw CancellationError() }
            return transaction(for: request, index: index)
        }
        let result = try await NativeTapFocusValidationService(adapter: adapter).run(
            try request(session, execute: true),
            snapshot: .init(session: session, observations: baseline(session),
                            coordinateCalibration: .init(orientation: .landscape,
                                verified: true), nowUptime: 11))
        #expect(await counter.value() == 2)
        #expect(result.phase == .cancelled && result.failureCode == "cancelled")
        #expect(result.submittedCount == 1 && result.acknowledgedCount == 1)
        #expect(result.partialSequence && !result.completed)
    }

    @Test func commandReadyExactIdentityAndFreshBaselineAreRequired() throws {
        var paired = NativeCameraSession()
        let pairedGeneration = paired.begin(sessionID: sessionID, peerID: peripheralID)
        _ = paired.markPaired(generation: pairedGeneration)
        #expect(throws: NativeTapFocusValidationError.sessionNotReady) {
            _ = try NativeTapFocusValidationCoordinator(session: paired.status)
        }

        let session = readySession()
        let target = try request(session)
        var coordinator = try NativeTapFocusValidationCoordinator(session: session)
        let wrong = try NativeTapFocusValidationRequest(
            expectedSessionID: session.sessionID!, peripheralID: session.peerID!,
            generation: session.generation + 1, x: 0.3, y: 0.7)
        #expect(throws: NativeTapFocusValidationError.invalidRequestIdentity) {
            try coordinator.prepare(wrong, observations: baseline(session), nowUptime: 11)
        }
        #expect(throws: NativeTapFocusValidationError.baselineRequired) {
            try coordinator.prepare(target, observations: [], nowUptime: 11)
        }
        #expect(throws: NativeTapFocusValidationError.baselineRequired) {
            try coordinator.prepare(target, observations: baseline(session, at: 1), nowUptime: 11)
        }
        #expect(throws: NativeTapFocusValidationError.baselineRequired) {
            try coordinator.prepare(target,
                                    observations: baseline(session, exposureMode: .manual),
                                    nowUptime: 11)
        }
    }

    @Test func wrongStepACKIsCorrelatedAndCannotAdvanceSequence() throws {
        let session = readySession()
        let input = try request(session)
        var coordinator = try NativeTapFocusValidationCoordinator(session: session)
        try coordinator.prepare(input, observations: baseline(session), nowUptime: 11)
        let next = try #require(coordinator.nextRequest)
        var wrong = transaction(for: next)
        wrong.id = UUID()
        let applied = coordinator.apply(wrong, nowUptime: 11.5)
        #expect(!applied)
        #expect(coordinator.phase == .generationChanged)
        #expect(coordinator.nextStepIndex == 0)
    }
}
