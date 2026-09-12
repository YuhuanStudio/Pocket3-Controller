import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 native setting coordinators")
struct Pocket3NativeSettingCoordinatorTests {
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

    private func transaction(for request: NativeCommandTransactionRequest,
                             submittedAt: TimeInterval = 11,
                             end: NativeCommandTransactionEnd = .acknowledged,
                             acknowledged: Bool = true) -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: request.generation,
            sessionID: request.sessionID, end: end)
        result.sequence = 0x5501
        result.submitted = true
        result.submittedUptime = submittedAt
        result.responseReceived = acknowledged
        result.acknowledged = acknowledged
        result.acknowledgedUptime = submittedAt + 0.01
        return result
    }

    private func imageEffectBaseline(_ status: NativeCameraSessionStatus,
                                     raw: Data = Data([0, 0, 0, 0, 0, 0]),
                                     uptime: TimeInterval = 10)
        -> Pocket3NativeSettingObservation {
        Pocket3NativeSettingObservation(sessionID: status.sessionID!,
            generation: status.generation, receivedUptime: uptime,
            property: .imageEffect, raw: raw)
    }

    private func lensBaseline(_ status: NativeCameraSessionStatus,
                              raw: Data = Data([0xB1]),
                              uptime: TimeInterval = 10)
        -> Pocket3NativeSettingObservation {
        Pocket3NativeSettingObservation(sessionID: status.sessionID!,
            generation: status.generation, receivedUptime: uptime,
            property: .lensState, raw: raw)
    }

    private func showcaseBaseline(_ status: NativeCameraSessionStatus,
                                  mode: UInt8 = 0,
                                  uptime: TimeInterval = 10)
        -> Pocket3NativeSettingObservation {
        let raw = Data([0, 0, 1, 0x3B, 0, 2, 1, mode])
        return Pocket3NativeSettingObservation(sessionID: status.sessionID!,
            generation: status.generation, receivedUptime: uptime,
            readback: .productShowcase(Pocket3ProductShowcaseReadback(
                raw: raw, modeRaw: mode)))
    }

    @Test func adaptersEncodeEachNativeCommandWithItsReadinessCommand() throws {
        let status = readySession()
        let whiteBalance = try Pocket3NativeCommandAdapter.whiteBalance(
            .customKelvin(5600), generation: status.generation,
            sessionID: status.sessionID)
        #expect(whiteBalance.command == .whiteBalance)
        #expect(whiteBalance.frame.commandSet == 2 && whiteBalance.frame.commandID == 0x2C)
        #expect(whiteBalance.frame.payload == Data([6, 0x38, 0, 0, 0]))

        let focus = try Pocket3NativeCommandAdapter.focusMode(
            .continuous, generation: status.generation, sessionID: status.sessionID)
        #expect(focus.command == .focusMode)
        #expect(focus.frame.commandSet == 2 && focus.frame.commandID == 0x24)
        #expect(focus.frame.payload == Data([0x02]))

        let color = try Pocket3NativeCommandAdapter.colorProfile(
            .dLogM, generation: status.generation, sessionID: status.sessionID)
        #expect(color.command == .colorProfile)
        #expect(color.frame.commandSet == 2 && color.frame.commandID == 0x42)
        #expect(color.frame.payload == Data([0x3D]))

        let showcase = try Pocket3NativeCommandAdapter.productShowcase(
            .set(.on), generation: status.generation, sessionID: status.sessionID)
        #expect(showcase.command == .productShowcase)
        #expect(showcase.frame.commandSet == 2 && showcase.frame.commandID == 0x8E)
        #expect(showcase.frame.payload == Data([1, 1, 0x3B, 0, 2, 1, 1]))

        let get = try Pocket3NativeCommandAdapter.showcase(.get,
            generation: status.generation, sessionID: status.sessionID)
        #expect(get.frame.payload == Data([0, 1, 0x3B, 0]))
    }

    @Test func whiteBalanceCompletesOnlyAfterFreshMatchingReadback() throws {
        let status = readySession()
        var coordinator = try Pocket3NativeSettingCoordinator(session: status)
        let baseline = imageEffectBaseline(status)
        let request = try coordinator.prepare(.whiteBalance(.customKelvin(5600)),
            baseline: baseline, nowUptime: 10)
        #expect(request.frame.payload == Data([6, 0x38, 0, 0, 0]))

        let ack = transaction(for: request)
        let ackOnly = coordinator.apply(ack, nowUptime: 11.1)
        #expect(!ackOnly && coordinator.phase == .awaitingReadback)

        let readback = Pocket3NativeSettingObservation(sessionID: sessionID,
            generation: status.generation, receivedUptime: 12,
            property: .imageEffect, raw: Data([0, 0, 0, 0, 0x06, 0x38]))
        let observed = coordinator.observe(readback, nowUptime: 12)
        #expect(observed)
        #expect(coordinator.result?.completed == true)
        #expect(coordinator.result?.acknowledged == true)
        #expect(coordinator.result?.readback?.raw == readback.raw)
    }

    @Test func focusAndColorUseIndependentExactProperties() throws {
        let status = readySession()

        var focusCoordinator = try Pocket3NativeSettingCoordinator(session: status)
        let focusRequest = try focusCoordinator.prepare(.focusMode(.continuous),
            baseline: lensBaseline(status), nowUptime: 10)
        #expect(focusRequest.frame.commandID == 0x24)
        let focusAck = transaction(for: focusRequest)
        _ = focusCoordinator.apply(focusAck, nowUptime: 11)
        let focusReadback = Pocket3NativeSettingObservation(sessionID: sessionID,
            generation: status.generation, receivedUptime: 12,
            property: .lensState, raw: Data([0xB2]))
        let focusObserved = focusCoordinator.observe(focusReadback, nowUptime: 12)
        #expect(focusObserved)

        var colorCoordinator = try Pocket3NativeSettingCoordinator(session: status)
        let colorRequest = try colorCoordinator.prepare(.colorProfile(.dLogM),
            baseline: imageEffectBaseline(status), nowUptime: 10)
        #expect(colorRequest.frame.commandID == 0x42)
        let colorAck = transaction(for: colorRequest)
        _ = colorCoordinator.apply(colorAck, nowUptime: 11)
        let colorReadback = Pocket3NativeSettingObservation(sessionID: sessionID,
            generation: status.generation, receivedUptime: 12,
            property: .imageEffect, raw: Data([0, 0, 0x3D, 0, 0, 0]))
        let colorObserved = colorCoordinator.observe(colorReadback, nowUptime: 12)
        #expect(colorObserved)
        #expect(focusCoordinator.result?.completed == true &&
            colorCoordinator.result?.completed == true)
    }

    @Test func showcaseRequiresKeyedReadbackAfterItsACK() throws {
        let status = readySession()
        var coordinator = try Pocket3NativeSettingCoordinator(session: status)
        let request = try coordinator.prepare(.productShowcase(.on),
            baseline: showcaseBaseline(status), nowUptime: 10)
        #expect(request.frame.commandID == 0x8E)
        _ = coordinator.apply(transaction(for: request), nowUptime: 11)
        #expect(coordinator.phase == .awaitingReadback)

        let readback = showcaseBaseline(status, mode: 1, uptime: 12)
        let observed = coordinator.observe(readback, nowUptime: 12)
        #expect(observed)
        #expect(coordinator.result?.completed == true &&
            coordinator.result?.readback?.readback.matches(.productShowcase(.on)) == true)
    }

    @Test func unknownEnumReadbackIsRetainedButCannotClaimCompletion() throws {
        let status = readySession()
        var coordinator = try Pocket3NativeSettingCoordinator(session: status)
        // The property layout is valid, but byte 4 is a future WB selector.
        let baseline = imageEffectBaseline(status, raw: Data([0, 0, 0, 0, 0xEE, 0x12]))
        let request = try coordinator.prepare(.whiteBalance(.automatic),
            baseline: baseline, nowUptime: 10)
        _ = coordinator.apply(transaction(for: request), nowUptime: 11)

        let unknown = imageEffectBaseline(status,
            raw: Data([0, 0, 0, 0, 0xEF, 0x13]), uptime: 12)
        let unknownObserved = coordinator.observe(unknown, nowUptime: 12)
        #expect(!unknownObserved)
        #expect(coordinator.readback?.isUnknown == true)
        #expect(coordinator.readback?.readback.property == .imageEffect)
        #expect(coordinator.readback?.raw == unknown.raw)
        #expect(coordinator.phase == .awaitingReadback)

        let matching = imageEffectBaseline(status,
            raw: Data([0, 0, 0, 0, 0, 0]), uptime: 13)
        let matchingObserved = coordinator.observe(matching, nowUptime: 13)
        #expect(matchingObserved)
    }

    @Test func noOpAndBaselineGatesPreventASecondRequest() throws {
        let status = readySession()
        var noOp = try Pocket3NativeSettingCoordinator(session: status)
        #expect(throws: Pocket3NativeSettingCoordinatorError.alreadyAtTarget) {
            try noOp.prepare(.whiteBalance(.automatic),
                baseline: imageEffectBaseline(status), nowUptime: 10)
        }
        #expect(noOp.phase == .noOp && noOp.request == nil)
        #expect(noOp.result?.noOp == true && noOp.result?.submitted == false)

        var stale = try Pocket3NativeSettingCoordinator(session: status)
        #expect(throws: Pocket3NativeSettingCoordinatorError.invalidBaseline) {
            try stale.prepare(.focusMode(.continuous),
                baseline: lensBaseline(status, uptime: 1), nowUptime: 10)
        }

        var wrongGeneration = try Pocket3NativeSettingCoordinator(session: status)
        let foreign = Pocket3NativeSettingObservation(sessionID: sessionID,
            generation: status.generation + 1, receivedUptime: 10,
            property: .lensState, raw: Data([0xB1]))
        #expect(throws: Pocket3NativeSettingCoordinatorError.invalidBaseline) {
            try wrongGeneration.prepare(.focusMode(.continuous), baseline: foreign,
                                        nowUptime: 10)
        }
    }

    @Test func wrongSessionGenerationAndACKWithoutReadbackStayUnconfirmed() throws {
        let status = readySession()
        var coordinator = try Pocket3NativeSettingCoordinator(session: status)
        let request = try coordinator.prepare(.focusMode(.continuous),
            baseline: lensBaseline(status), nowUptime: 10)
        var staleTransaction = transaction(for: request)
        staleTransaction.generation += 1
        let staleApplied = coordinator.apply(staleTransaction, nowUptime: 11)
        #expect(!staleApplied)
        #expect(coordinator.phase == .generationChanged)

        var pending = try Pocket3NativeSettingCoordinator(session: status)
        let pendingRequest = try pending.prepare(.focusMode(.continuous),
            baseline: lensBaseline(status), nowUptime: 10)
        var nack = transaction(for: pendingRequest, acknowledged: false)
        nack.end = .rejected
        let nackApplied = pending.apply(nack, nowUptime: 11)
        #expect(!nackApplied)
        #expect(pending.phase == .failed && pending.result?.completed == false)
    }
}
