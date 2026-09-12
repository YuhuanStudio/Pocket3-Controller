import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 native zoom and gimbal coordinators")
struct Pocket3NativeMotionCoordinatorTests {
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

    private func lens(_ status: NativeCameraSessionStatus, position: UInt16,
                      uptime: TimeInterval = 10, moving: Bool? = nil,
                      focus: UInt8 = 0xB2) -> Pocket3NativeLensStateObservation {
        Pocket3NativeLensStateObservation(sessionID: status.sessionID!,
            generation: status.generation, receivedUptime: uptime,
            raw: lensRaw(position, focus: focus), moving: moving)
    }

    private func gimbal(_ status: NativeCameraSessionStatus, mode: UInt8 = 0,
                        speed: UInt8 = 1, uptime: TimeInterval = 10)
        -> Pocket3NativeGimbalParameterObservation {
        Pocket3NativeGimbalParameterObservation(sessionID: status.sessionID!,
            generation: status.generation, receivedUptime: uptime,
            raw: Data([0, 1, 4, 1, mode, 5, 1, speed]))
    }

    private func transaction(for request: NativeCommandTransactionRequest,
                             submittedAt: TimeInterval = 11,
                             acknowledged: Bool = true)
        -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: request.generation,
            sessionID: request.sessionID, end: acknowledged ? .acknowledged : .rejected)
        result.sequence = 0x5501
        result.submitted = true
        result.submittedUptime = submittedAt
        result.responseReceived = acknowledged
        result.acknowledged = acknowledged
        result.acknowledgedUptime = submittedAt + 0.01
        return result
    }

    @Test func zoomFormatMapsKnownBodyResolutionsToRawBounds() {
        #expect(Pocket3NativeZoomFormat(resolution: .p4K).maximumMultiplier == 2)
        #expect(Pocket3NativeZoomFormat(resolution: .p2_7K).maximumMultiplier == 3)
        #expect(Pocket3NativeZoomFormat(resolution: .p1080).maximumMultiplier == 4)
        #expect(Pocket3NativeZoomFormat(resolution: .portrait3K).maximumRawPosition == 300)
        #expect(Pocket3NativeZoomFormat(resolution: .square1080).maximumRawPosition == 400)
        #expect(Pocket3NativeZoomFormat.fourK.acceptsAbsolute(200))
        #expect(!Pocket3NativeZoomFormat.fourK.acceptsAbsolute(201))
        #expect(Pocket3NativeZoomFormat.twoPointSevenK.acceptsAbsolute(300))
        #expect(!Pocket3NativeZoomFormat.twoPointSevenK.acceptsAbsolute(301))
        #expect(Pocket3NativeZoomFormat.fullHD.acceptsAbsolute(400))
        #expect(!Pocket3NativeZoomFormat.fullHD.acceptsAbsolute(401))
    }

    @Test func zoomAbsoluteNeedsFreshLensReadbackAfterACK() throws {
        let status = readySession()
        var coordinator = try Pocket3NativeZoomCoordinator(session: status)
        let request = try coordinator.prepare(.absoluteLens(position: 150),
            format: .fullHD, baseline: lens(status, position: 100), nowUptime: 10)
        #expect(request.command == .zoom)
        #expect(request.frame.commandSet == 2 && request.frame.commandID == 0xB8)
        #expect(request.frame.payload == Data([0x0A, 0x4E, 0x96, 0]))

        let ackOnly = coordinator.apply(transaction(for: request), nowUptime: 11.1)
        #expect(!ackOnly && coordinator.phase == .awaitingReadback)
        let readback = lens(status, position: 150, uptime: 12)
        let observed = coordinator.observe(readback, nowUptime: 12)
        #expect(observed && coordinator.result?.completed == true)
        #expect(coordinator.result?.readback?.zoomPositionRaw == 150)
    }

    @Test func zoomRelativeAndMovingStopRemainBoundedAndRequireFreshReadback() throws {
        let status = readySession()
        var relative = try Pocket3NativeZoomCoordinator(session: status)
        let relativeRequest = try relative.prepare(.relativeSlew(value: 300),
            format: .fourK, baseline: lens(status, position: 100), nowUptime: 10)
        #expect(relativeRequest.frame.payload == Data([3, 0, 0x2C, 1]))
        _ = relative.apply(transaction(for: relativeRequest), nowUptime: 11)
        let relativeReadback = lens(status, position: 120, uptime: 12)
        let relativeObserved = relative.observe(relativeReadback, nowUptime: 12)
        #expect(relativeObserved && relative.result?.completed == true)

        var movingStop = try Pocket3NativeZoomCoordinator(session: status)
        let stopBaseline = lens(status, position: 217, uptime: 20, moving: true)
        let stopRequest = try movingStop.prepare(Pocket3NativeZoomPayload.stop, format: .fullHD,
            baseline: stopBaseline, nowUptime: 20)
        #expect(stopRequest.frame.payload == Data([0xFF, 0, 0, 0]))
        #expect(movingStop.result?.stopRequestedWhileMoving == true)
        _ = movingStop.apply(transaction(for: stopRequest), nowUptime: 21)
        let stopped = lens(status, position: 217, uptime: 22, moving: false)
        let stopObserved = movingStop.observe(stopped, nowUptime: 22)
        #expect(stopObserved && movingStop.result?.completed == true)
    }

    @Test func zoomNoOpAndUnsafeFormatDoNotProduceRequests() throws {
        let status = readySession()
        var noOp = try Pocket3NativeZoomCoordinator(session: status)
        #expect(throws: Pocket3NativeZoomCoordinatorError.alreadyAtTarget) {
            try noOp.prepare(.absoluteLens(position: 200), format: .fourK,
                baseline: lens(status, position: 200), nowUptime: 10)
        }
        #expect(noOp.phase == .noOp && noOp.request == nil)
        #expect(noOp.result?.noOp == true && noOp.result?.submitted == false)

        var zeroSlew = try Pocket3NativeZoomCoordinator(session: status)
        #expect(throws: Pocket3NativeZoomCoordinatorError.alreadyAtTarget) {
            try zeroSlew.prepare(.relativeSlew(value: 0), format: .fullHD,
                baseline: lens(status, position: 100), nowUptime: 10)
        }
        var tooFar = try Pocket3NativeZoomCoordinator(session: status)
        #expect(throws: Pocket3NativeZoomCoordinatorError.invalidFormat) {
            try tooFar.prepare(.absoluteLens(position: 201), format: .fourK,
                baseline: lens(status, position: 100), nowUptime: 10)
        }
        var unknown = try Pocket3NativeZoomCoordinator(session: status)
        #expect(throws: Pocket3NativeZoomCoordinatorError.invalidAction) {
            try unknown.prepare(.unknown(Data([1, 2, 3])), format: .fullHD,
                baseline: lens(status, position: 100), nowUptime: 10)
        }
    }

    @Test func zoomForeignAndStaleReadbacksCannotCompleteTheTransaction() throws {
        let status = readySession()
        var coordinator = try Pocket3NativeZoomCoordinator(session: status)
        let request = try coordinator.prepare(.absoluteLens(position: 150),
            format: .fullHD, baseline: lens(status, position: 100), nowUptime: 10)
        _ = coordinator.apply(transaction(for: request), nowUptime: 11)
        let foreign = Pocket3NativeLensStateObservation(sessionID: UUID(),
            generation: status.generation, receivedUptime: 12,
            raw: lensRaw(150))
        let foreignObserved = coordinator.observe(foreign, nowUptime: 12)
        #expect(!foreignObserved && coordinator.phase == .awaitingReadback)
        let stale = lens(status, position: 150, uptime: 10)
        let staleObserved = coordinator.observe(stale, nowUptime: 12)
        #expect(!staleObserved && coordinator.result?.completed == false)
    }

    @Test func gimbalModeAndSpeedNeedFreshMatching040x50Readback() throws {
        let status = readySession()
        var mode = try Pocket3NativeGimbalCoordinator(session: status)
        let modeRequest = try mode.prepare(.mode(.tiltLocked),
            baseline: gimbal(status), nowUptime: 10)
        #expect(modeRequest.command == .gimbal)
        #expect(modeRequest.frame.commandSet == 4 && modeRequest.frame.commandID == 0x50)
        #expect(modeRequest.frame.payload == Data([0, 4, 1, 1]))
        _ = mode.apply(transaction(for: modeRequest), nowUptime: 11)
        let modeReadback = gimbal(status, mode: 1, uptime: 12)
        let modeObserved = mode.observe(modeReadback, nowUptime: 12)
        #expect(modeObserved && mode.result?.completed == true)

        var speed = try Pocket3NativeGimbalCoordinator(session: status)
        let speedRequest = try speed.prepare(.speed(.slow),
            baseline: gimbal(status), nowUptime: 10)
        #expect(speedRequest.frame.payload == Data([0, 5, 1, 2]))
        _ = speed.apply(transaction(for: speedRequest), nowUptime: 11)
        let speedReadback = gimbal(status, speed: 2, uptime: 12)
        let speedObserved = speed.observe(speedReadback, nowUptime: 12)
        #expect(speedObserved && speed.result?.completed == true)
    }

    @Test func gimbalNoOpUnknownRawAndGenerationGatesAreExplicit() throws {
        let status = readySession()
        var noOp = try Pocket3NativeGimbalCoordinator(session: status)
        #expect(throws: Pocket3NativeGimbalCoordinatorError.alreadyAtTarget) {
            try noOp.prepare(.mode(.follow), baseline: gimbal(status), nowUptime: 10)
        }
        #expect(noOp.phase == .noOp && noOp.request == nil)

        let unknownRaw = Data([0, 1, 4, 1, 0xFE, 5, 1, 0xFD])
        let unknownBaseline = Pocket3NativeGimbalParameterObservation(
            sessionID: status.sessionID!, generation: status.generation,
            receivedUptime: 10, raw: unknownRaw)
        #expect(unknownBaseline.readback?.mode == nil && unknownBaseline.readback?.speed == nil)
        var coordinator = try Pocket3NativeGimbalCoordinator(session: status)
        let request = try coordinator.prepare(.speed(.slow), baseline: unknownBaseline,
                                              nowUptime: 10)
        _ = coordinator.apply(transaction(for: request), nowUptime: 11)
        let unknownReadback = Pocket3NativeGimbalParameterObservation(
            sessionID: status.sessionID!, generation: status.generation,
            receivedUptime: 12, raw: unknownRaw)
        let unknownObserved = coordinator.observe(unknownReadback, nowUptime: 12)
        #expect(!unknownObserved && coordinator.readback?.raw == unknownRaw)
        #expect(coordinator.phase == .awaitingReadback)
        let matching = gimbal(status, speed: 2, uptime: 13)
        let matchingObserved = coordinator.observe(matching, nowUptime: 13)
        #expect(matchingObserved && coordinator.result?.completed == true)

        var stale = try Pocket3NativeGimbalCoordinator(session: status)
        let foreign = Pocket3NativeGimbalParameterObservation(sessionID: UUID(),
            generation: status.generation, receivedUptime: 10,
            raw: Data([0, 1, 4, 1, 0, 5, 1, 1]))
        #expect(throws: Pocket3NativeGimbalCoordinatorError.invalidBaseline) {
            try stale.prepare(.speed(.slow), baseline: foreign, nowUptime: 10)
        }
    }

    @Test func motionAdaptersCarryMatchingReadbackObservationHandlers() throws {
        let status = readySession()
        let zoom = try Pocket3NativeCommandAdapter.nativeZoom(
            .absoluteLens(position: 150), generation: status.generation,
            sessionID: status.sessionID)
        #expect(zoom.command == .zoom && zoom.frame.commandID == 0xB8)
        #expect(zoom.observationHandler() != nil)

        let gimbal = try Pocket3NativeCommandAdapter.gimbalSpeed(
            .slow, generation: status.generation, sessionID: status.sessionID)
        #expect(gimbal.command == .gimbal && gimbal.frame.payload == Data([0, 5, 1, 2]))
        #expect(gimbal.observationHandler() != nil)
        let get = try Pocket3NativeCommandAdapter.gimbalParameters(
            .get, generation: status.generation, sessionID: status.sessionID)
        #expect(get.command == .gimbal && get.frame.payload == Data([1, 4, 5]))
    }
}
