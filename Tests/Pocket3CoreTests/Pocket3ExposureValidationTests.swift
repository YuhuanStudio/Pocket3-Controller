import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 exposure validation") struct Pocket3ExposureValidationTests {
    private let sessionID = UUID(), peerID = UUID()

    private func session() -> NativeCameraSessionStatus {
        var value = NativeCameraSession()
        let generation = value.begin(sessionID: sessionID, peerID: peerID)
        _ = value.markPaired(generation: generation)
        _ = value.markCredentialsAvailable(generation: generation)
        _ = value.observeDatalink(.connecting, generation: generation)
        _ = value.observeDatalink(.ready, generation: generation)
        return value.status
    }

    private func raw(mode: Pocket3ExposureMode, ev: UInt8 = 0x10,
                     iso: UInt8, denominator: UInt16, effectiveISO: UInt32) -> Data {
        var value = Data(repeating: 0, count: 20)
        let encoded = denominator | 0x8000
        value[1] = UInt8(encoded & 0xff); value[2] = UInt8(encoded >> 8)
        value[5] = iso; value[6] = ev; value[7] = mode.rawValue
        value[16] = UInt8(effectiveISO & 0xff)
        value[17] = UInt8((effectiveISO >> 8) & 0xff)
        value[18] = UInt8((effectiveISO >> 16) & 0xff)
        value[19] = UInt8((effectiveISO >> 24) & 0xff)
        return value
    }

    private func observation(_ session: NativeCameraSessionStatus,
        mode: Pocket3ExposureMode, ev: UInt8 = 0x10, iso: UInt8,
        denominator: UInt16, effectiveISO: UInt32, uptime: TimeInterval = 10) throws
        -> Pocket3ExposureObservation {
        try #require(Pocket3ExposureObservation(
            sessionID: session.sessionID!, generation: session.generation,
            receivedUptime: uptime, raw: raw(mode: mode, ev: ev, iso: iso,
                denominator: denominator, effectiveISO: effectiveISO)))
    }

    private func snapshot(_ session: NativeCameraSessionStatus,
        exposure: Pocket3ExposureObservation?, now: TimeInterval = 10)
        -> Pocket3ExposureValidationSnapshot {
        .init(session: session, exposure: exposure,
            modeContext: .init(shootingModeRaw: Pocket3ShootingMode.video.rawValue,
                frameRateRaw: CameraFrameRate.fps30.rawValue), nowUptime: now)
    }

    private func transaction(_ request: NativeCommandTransactionRequest,
        end: NativeCommandTransactionEnd = .acknowledged) -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: request.generation,
            sessionID: request.sessionID, end: end)
        result.submitted = true; result.submittedUptime = 11
        result.responseReceived = true; result.acknowledged = true
        result.acknowledgedUptime = 11.01; result.finishedUptime = 11.02
        return result
    }

    @Test func encodersCoverModeEVISOShutterAndISOLimit() throws {
        #expect(Pocket3ExposureCommand.mode(.manual).frame.payload == Data([4, 0]))
        #expect(try Pocket3ExposureCommand.autoEV(thirdStops: 3).frame.payload == Data([0x13]))
        #expect(Pocket3ExposureCommand.iso(.iso50).frame.payload == Data([2]))
        let shutter = try Pocket3ExposureShutterSelection(denominator: 50)
        #expect(try Pocket3ExposureCommand(.shutter(shutter)).frame.commandID == 0x28)
        let limit = try Pocket3ExposureCommand(.isoLimit(.iso6400))
        #expect(limit.frame.payload == Data([1, 1, 0x0f, 0, 1, 7]))
    }

    @Test func readbackAndVideoShutterBoundsRemainTyped() throws {
        let session = session()
        let value = try observation(session, mode: .manual,
            iso: Pocket3ExposureISOIndex.iso50.rawValue,
            denominator: 50, effectiveISO: 50)
        let shutter = try Pocket3ExposureShutterSelection(denominator: 50)
        #expect(value.selectedISO == .iso50 && value.shutter == shutter)
        let context = Pocket3ExposureModeContext(
            shootingModeRaw: Pocket3ShootingMode.video.rawValue,
            frameRateRaw: CameraFrameRate.fps30.rawValue)
        #expect(context.allows(shutter))
        #expect(!context.allows(try .init(denominator: 25)))
    }

    @Test func ackAloneWaitsForFreshMatchingEVReadback() throws {
        let session = session()
        let baseline = try observation(session, mode: .automatic,
            iso: Pocket3ExposureISOIndex.automatic.rawValue,
            denominator: 30, effectiveISO: 100)
        let ev = try Pocket3ExposureEV(thirdStops: 3)
        var coordinator = try Pocket3ExposureCoordinator(session: session)
        let request = try coordinator.prepare(.ev(ev),
            snapshot: snapshot(session, exposure: baseline))
        let applied = coordinator.apply(transaction(request), nowUptime: 11.1)
        #expect(!applied && coordinator.phase == .awaitingReadback)
        let matching = try observation(session, mode: .automatic, ev: ev.rawValue,
            iso: Pocket3ExposureISOIndex.automatic.rawValue,
            denominator: 30, effectiveISO: 100, uptime: 12)
        let observed = coordinator.observe(matching, nowUptime: 12)
        #expect(observed)
        #expect(coordinator.phase == .completed)
    }

    @Test func unknownSelectedISOCannotComplete() throws {
        let session = session()
        let baseline = try observation(session, mode: .manual,
            iso: Pocket3ExposureISOIndex.iso100.rawValue,
            denominator: 50, effectiveISO: 100)
        var coordinator = try Pocket3ExposureCoordinator(session: session)
        let request = try coordinator.prepare(.iso(.iso50),
            snapshot: snapshot(session, exposure: baseline))
        let unknown = try observation(session, mode: .manual, iso: 1,
            denominator: 50, effectiveISO: 50, uptime: 12)
        let applied = coordinator.apply(transaction(request), readback: unknown,
            nowUptime: 12)
        #expect(!applied && coordinator.phase == .awaitingReadback)
    }

    @Test func manualPresetPlansModeThenISOThenShutterWithoutSending() throws {
        let session = session()
        let baseline = try observation(session, mode: .automatic,
            iso: Pocket3ExposureISOIndex.automatic.rawValue,
            denominator: 30, effectiveISO: 100)
        let shutter = try Pocket3ExposureShutterSelection(denominator: 50)
        let preset = Pocket3ManualExposurePreset(iso: .iso100, shutter: shutter)
        var coordinator = try Pocket3ExposureCoordinator(session: session)
        let first = try coordinator.prepare(.manualPreset(preset),
            snapshot: snapshot(session, exposure: baseline))
        #expect(first.frame.commandID == 0x1e)
        #expect(coordinator.plannedTargets == [
            .mode(.manual), .iso(.iso100), .shutter(shutter)
        ])
        #expect(coordinator.steps.isEmpty)
    }

    @Test func staleBaselineIsRejectedBeforeRequestCreation() throws {
        let session = session()
        let stale = try observation(session, mode: .automatic,
            iso: Pocket3ExposureISOIndex.automatic.rawValue,
            denominator: 30, effectiveISO: 100, uptime: 1)
        let ev = try Pocket3ExposureEV(thirdStops: 1)
        var coordinator = try Pocket3ExposureCoordinator(session: session)
        #expect(throws: Pocket3ExposureCoordinatorError.invalidBaseline) {
            try coordinator.prepare(.ev(ev),
                snapshot: snapshot(session, exposure: stale, now: 10))
        }
        #expect(coordinator.nextRequest == nil)
    }
}
