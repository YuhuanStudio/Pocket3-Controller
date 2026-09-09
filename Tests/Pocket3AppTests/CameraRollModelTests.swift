import Foundation
import Testing
@testable import Pocket3Core
@testable import Pocket3BridgeApp

private func rollCaps(current: Int = 0, minimum: Int = -30, maximum: Int = 30,
                      step: Int? = 1, defaultValue: Int? = 0, writable: Bool = true) -> USBRollCapabilities {
    .init(current: current, minimum: minimum, maximum: maximum, step: step,
          defaultValue: defaultValue, writable: writable)
}

@MainActor private final class RollModelFixture {
    enum Delay: Equatable { case beforeWrite, afterWrite }
    struct Write: Equatable { let value: Int; let session: String }
    var session = "roll-A"
    var capabilities = rollCaps()
    var delayNextWrite: Delay?
    var delayNextRead = false
    var delayNextPrepare = false
    var unverified = false
    var readFailure: BridgeFailure?
    private(set) var writes: [Write] = []
    private(set) var reads: [String] = []
    private(set) var prepares = 0
    private(set) var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var writeGate: CheckedContinuation<Void, Never>?
    private(set) var readGate: CheckedContinuation<Void, Never>?
    private(set) var prepareGate: CheckedContinuation<Void, Never>?
    var errors: [String] = []

    func read(_ expected: String) async throws -> USBRollCapabilities {
        reads.append(expected)
        if let readFailure { throw readFailure }
        guard expected == session else { throw BridgeFailure("session_changed", "Fixture read changed session") }
        let response = capabilities
        if delayNextRead {
            delayNextRead = false
            await withCheckedContinuation { readGate = $0 }
        }
        return response // Deliberately deliver an old read after a reconnect.
    }
    func prepare() async {
        prepares += 1
        if delayNextPrepare {
            delayNextPrepare = false
            await withCheckedContinuation { prepareGate = $0 }
        }
    }
    func apply(_ value: Int, session expected: String) async throws -> USBRollResult {
        inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        let delay = delayNextWrite; delayNextWrite = nil
        if delay == .beforeWrite { await withCheckedContinuation { writeGate = $0 } }
        try Task.checkCancellation()
        guard expected == session else { throw BridgeFailure("session_changed", "Fixture write changed session") }
        writes.append(.init(value: value, session: expected))
        capabilities.current = value
        let response = capabilities, verified = !unverified
        if delay == .afterWrite { await withCheckedContinuation { writeGate = $0 } }
        // Do not check cancellation here: the model must independently reject
        // a result returned after the operator cancelled or switched cameras.
        return USBRollResult(target: value, observed: value, accepted: true,
            completed: verified, verified: verified, verification: "fixture_raw_roll_readback",
            capabilities: response, message: "Fixture result")
    }
    func releaseWrite() { let gate = writeGate; writeGate = nil; gate?.resume() }
    func releaseRead() { let gate = readGate; readGate = nil; gate?.resume() }
    func releasePrepare() { let gate = prepareGate; prepareGate = nil; gate?.resume() }
    func releaseAll() { releaseWrite(); releaseRead(); releasePrepare() }
}

@MainActor private func rollModel(_ io: RollModelFixture) -> CameraRollModel {
    .init(readCapabilities: { try await io.read($0) },
          applyRoll: { try await io.apply($0, session: $1) },
          prepare: { await io.prepare() }, reportError: { io.errors.append($0) })
}

@MainActor private func eventuallyRoll(_ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw BridgeFailure("fixture_timeout", "Roll model did not reach the expected continuation")
}

@MainActor @Test func rollRangeSupportsNegativeValuesAndBothGridEndsWithoutUnsignedConversion() throws {
    let range = try #require(CameraRollRange(rollCaps(current: -2, minimum: -10, maximum: 9, step: 4, defaultValue: 2)))
    #expect(range.rawValue(fraction: 0) == -10)
    #expect(range.rawValue(fraction: 1) == 6) // Declared max 9 is off the min-based grid.
    #expect(range.rawValue(fraction: 0.5) == -2)
    for fraction in [-1.0, 0, 0.1, 0.5, 0.9, 1, 2] {
        let value = range.rawValue(fraction: fraction)
        #expect((-10...9).contains(value) && (value + 10).isMultiple(of: 4))
    }
    let fullSigned = try #require(CameraRollRange(rollCaps(current: -32768, minimum: -32768,
        maximum: 32767, step: 32767, defaultValue: -32768)))
    #expect(fullSigned.rawValue(fraction: 0) == -32768)
    #expect(fullSigned.rawValue(fraction: 1) == 32766)
}

@MainActor @Test func rollMissingZeroNegativeOrOversizedStepsAndUnsupportedReadsNeverWrite() async {
    let invalidSteps: [Int?] = [nil, 0, -1, 32768]
    for step in invalidSteps {
        let io = RollModelFixture(); io.capabilities = rollCaps(step: step)
        let model = rollModel(io)
        await model.refresh(sessionID: io.session, phase: "ready")
        model.request(fraction: 0.8); model.adjust(-1); model.restoreDefault()
        #expect(!model.canInteract && !model.isWorking && io.prepares == 0 && io.writes.isEmpty)
    }
    let io = RollModelFixture(), model = rollModel(io)
    io.readFailure = BridgeFailure("uvc_roll_not_readable", "Fixture unsupported read")
    await model.refresh(sessionID: io.session, phase: "ready")
    await model.refresh(sessionID: io.session, phase: "ready")
    model.request(fraction: 1)
    #expect(io.reads.count == 1 && io.writes.isEmpty && !model.canInteract)
}

@MainActor @Test func rollRestoreUsesNonzeroDeviceDefaultAndButtonsMoveOneSignedStep() async throws {
    let io = RollModelFixture(); io.capabilities = rollCaps(current: -2, minimum: -10, maximum: 10, step: 4, defaultValue: 2)
    let model = rollModel(io)
    await model.refresh(sessionID: io.session, phase: "ready")
    #expect(model.currentRawValue == -2 && model.defaultRawValue == 2 && model.canRestoreDefault)
    model.restoreDefault()
    try await eventuallyRoll { !model.isWorking }
    #expect(io.writes.map(\.value) == [2] && !model.canRestoreDefault)
    model.adjust(-1)
    try await eventuallyRoll { !model.isWorking }
    #expect(io.writes.map(\.value) == [2, -2])
    #expect(!io.writes.contains { $0.value == 0 })
}

@MainActor @Test func rollAbsentOffGridOrOutOfRangeDefaultIsNotGuessedOrSubmitted() async {
    let unavailableDefaults: [Int?] = [nil, 0, 11]
    for value in unavailableDefaults {
        let io = RollModelFixture()
        io.capabilities = rollCaps(current: -2, minimum: -10, maximum: 10, step: 4, defaultValue: value)
        let model = rollModel(io)
        await model.refresh(sessionID: io.session, phase: "ready")
        #expect(model.defaultRawValue == nil && !model.canRestoreDefault)
        model.restoreDefault()
        #expect(!model.isWorking && io.prepares == 0 && io.writes.isEmpty)
    }
}

@MainActor @Test func rollCoalescesLatestSignedDragAndWithdrawsPendingAtInFlightValue() async throws {
    let io = RollModelFixture(), model = rollModel(io)
    defer { io.releaseAll() }
    await model.refresh(sessionID: io.session, phase: "ready")
    io.delayNextWrite = .afterWrite
    model.request(fraction: 0.25) // -15
    try await eventuallyRoll { io.writeGate != nil }
    model.request(fraction: 0.75); model.request(fraction: 0.95) // +15 is replaced by +27.
    await model.refresh(sessionID: io.session, phase: "moving")
    #expect(model.canInteract && io.reads.count == 1)
    io.releaseWrite()
    try await eventuallyRoll { !model.isWorking }
    #expect(io.writes.map(\.value) == [-15, 27] && io.maximumInFlight == 1)

    io.delayNextWrite = .afterWrite
    model.request(fraction: 0.25)
    try await eventuallyRoll { io.writeGate != nil }
    model.request(fraction: 0.9); model.request(fraction: 0.25)
    io.releaseWrite()
    try await eventuallyRoll { !model.isWorking }
    #expect(io.writes.map(\.value) == [-15, 27, -15] && io.errors.isEmpty)
}

@MainActor @Test func rollReturningToCurrentDuringPreparationWithdrawsUnsentTarget() async throws {
    let io = RollModelFixture(), model = rollModel(io)
    defer { io.releaseAll() }
    await model.refresh(sessionID: io.session, phase: "ready")
    io.delayNextPrepare = true
    model.request(fraction: 1)
    try await eventuallyRoll { io.prepareGate != nil }
    model.request(fraction: 0.5) // Back to actual current 0 before any write starts.
    io.releasePrepare()
    try await eventuallyRoll { !model.isWorking }
    #expect(io.writes.isEmpty && model.currentRawValue == 0)
    model.request(fraction: 0.6)
    try await eventuallyRoll { !model.isWorking }
    #expect(io.writes.map(\.value) == [6])
}

@MainActor @Test func rollCancellationBeforeWriteDiscardsQueuedSignedTargets() async throws {
    let io = RollModelFixture(), model = rollModel(io)
    defer { io.releaseAll() }
    await model.refresh(sessionID: io.session, phase: "ready")
    io.delayNextWrite = .beforeWrite
    model.request(fraction: 0.2)
    try await eventuallyRoll { io.writeGate != nil }
    model.request(fraction: 0.8); model.cancel()
    #expect(model.isCancelling && !model.canInteract)
    io.releaseWrite()
    try await eventuallyRoll { !model.isWorking }
    #expect(io.writes.isEmpty && io.errors.isEmpty)
    await model.refresh(sessionID: io.session, phase: "ready")
    model.request(fraction: 0.4)
    try await eventuallyRoll { !model.isWorking }
    #expect(io.writes.map(\.value) == [-6] && io.maximumInFlight == 1)
}

@MainActor @Test func rollReconnectRejectsLateWriteAndCapabilityReadWithoutResurrectingDraft() async throws {
    let io = RollModelFixture(), model = rollModel(io)
    defer { io.releaseAll() }
    await model.refresh(sessionID: io.session, phase: "ready")
    io.delayNextWrite = .afterWrite
    model.request(fraction: 0.25)
    try await eventuallyRoll { io.writeGate != nil }
    model.request(fraction: 0.9)
    io.session = "roll-B"; io.capabilities.current = -20
    await model.refresh(sessionID: io.session, phase: "ready")
    model.request(fraction: 1)
    #expect(!model.canInteract && model.capabilities == nil)
    io.releaseWrite()
    try await eventuallyRoll { !model.isWorking }
    #expect(model.capabilities == nil)
    await model.refresh(sessionID: io.session, phase: "ready")
    #expect(model.currentRawValue == -20 && model.sessionID == "roll-B")

    io.delayNextRead = true
    let oldRead = Task { await model.refresh(sessionID: "roll-B", phase: "ready") }
    try await eventuallyRoll { io.readGate != nil }
    io.session = "roll-C"; io.capabilities.current = -5
    await model.refresh(sessionID: io.session, phase: "ready")
    io.releaseRead(); await oldRead.value
    #expect(model.capabilities == nil && model.sessionID == "roll-C")
    await model.refresh(sessionID: io.session, phase: "ready")
    #expect(model.currentRawValue == -5 && model.canInteract)
    #expect(io.writes == [.init(value: -15, session: "roll-A")] && io.maximumInFlight == 1)
}

@MainActor @Test func rollUnconfirmedReadbackDropsNewerDragWithoutAutomaticRetry() async throws {
    let io = RollModelFixture(), model = rollModel(io)
    defer { io.releaseAll() }
    await model.refresh(sessionID: io.session, phase: "ready")
    io.delayNextWrite = .afterWrite; io.unverified = true
    model.request(fraction: 0.2)
    try await eventuallyRoll { io.writeGate != nil }
    model.request(fraction: 0.8)
    io.releaseWrite()
    try await eventuallyRoll { !model.isWorking }
    await model.refresh(sessionID: io.session, phase: "ready")
    #expect(io.writes.map(\.value) == [-18])
    #expect(io.errors.count == 1 && io.maximumInFlight == 1)
}
