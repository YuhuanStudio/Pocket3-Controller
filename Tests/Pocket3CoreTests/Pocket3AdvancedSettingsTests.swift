import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 advanced setting inventory")
struct Pocket3AdvancedSettingsTests {
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
        at uptime: TimeInterval = 10,
        expectedValueLength: Int? = 1
    ) throws -> Pocket3AdvancedSettingObservation {
        try #require(Pocket3AdvancedSettingObservation(
            sessionID: session.sessionID!, generation: session.generation,
            receivedUptime: uptime, setting: setting,
            payload: keyedReply(parameterID: parameterID(for: setting), value: value),
            expectedValueLength: expectedValueLength))
    }

    private func parameterID(for setting: Pocket3AdvancedSettingID) -> UInt16 {
        switch setting {
        case .isoLimit: 0x000F
        case .audioChannel: 0x0020
        case .vocalBoost: 0x004C
        case .selfieFlip: 0x0038
        default: 0
        }
    }

    private func transaction(
        for request: NativeCommandTransactionRequest,
        payload: Data? = nil,
        end: NativeCommandTransactionEnd = .observed,
        at uptime: TimeInterval = 11
    ) -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(
            id: request.id, command: request.command,
            generation: request.generation, sessionID: request.sessionID,
            end: end)
        result.submitted = true
        result.submittedUptime = uptime
        result.responseReceived = true
        result.acknowledged = end == .acknowledged || end == .observed
        result.acknowledgedUptime = result.acknowledged ? uptime + 0.01 : nil
        result.observedPayload = payload
        result.observed = payload != nil
        result.observedUptime = payload.map { _ in uptime + 0.02 }
        result.finishedUptime = uptime + 0.03
        return result
    }

    @Test func inventoryListsEveryRequestedSettingWithEvidenceAndNoFalseAvailability() throws {
        #expect(Pocket3AdvancedSettingInventory.all.map(\.id) == [
            .medTele, .breathingCompensation, .sharpness, .noiseReduction,
            .isoLimit, .audioChannel, .vocalBoost, .selfieFlip
        ])

        let officialOnly = Pocket3AdvancedSettingInventory.all.filter {
            $0.evidence == [.officialOnly]
        }
        #expect(officialOnly.map(\.id) == [.breathingCompensation, .sharpness, .noiseReduction])
        #expect(officialOnly.allSatisfy {
            !$0.availability.read && !$0.availability.write && !$0.availability.verified
        })
        #expect(Pocket3AdvancedSettingInventory.entry(for: .isoLimit)?.evidence.contains(.localParser) == true)
        #expect(Pocket3AdvancedSettingInventory.entry(for: .vocalBoost)?.evidence.contains(.publicReverseEngineering) == true)

        let iso = try #require(Pocket3AdvancedSettingInventory.entry(for: .isoLimit))
        #expect(iso.availability.read && iso.availability.write && !iso.availability.verified)
        if case let .keyedParameter(pid, getPayload, length, values) = iso.command {
            #expect(pid == 0x000F)
            #expect(getPayload == Data([0, 1, 0x0F, 0]))
            #expect(length == 1 && values == Array(UInt8(1)...UInt8(7)))
        } else {
            Issue.record("ISO limit must retain its exact keyed candidate")
        }

        let selfie = try #require(Pocket3AdvancedSettingInventory.entry(for: .selfieFlip))
        #expect(selfie.availability.read && !selfie.availability.write)
        if case let .selfieFlip(pid, readPayload, togglePayload) = selfie.command {
            #expect(pid == 0x0038)
            #expect(readPayload == Data([0, 1, 0x38, 0]))
            #expect(togglePayload == Data([0xFE, 0x09]))
        } else {
            Issue.record("Selfie Flip must retain GET and FE09 candidates")
        }
    }

    @Test func keyedCommandsAndReadbackEnforcePIDAndLengthWithoutDroppingBytes() throws {
        let audioGet = try Pocket3KeyedParameterCommand.audioChannelGet()
        #expect(audioGet.payload == Data([0, 1, 0x20, 0]))
        let vocalSet = try Pocket3KeyedParameterCommand.vocalBoostSet(.on)
        #expect(vocalSet.payload == Data([1, 1, 0x4C, 0, 1, 1]))
        let roundTrip = try JSONDecoder().decode(
            Pocket3KeyedParameterCommand.self,
            from: JSONEncoder().encode(vocalSet))
        #expect(roundTrip == vocalSet)
        #expect(throws: Pocket3KeyedParameterError.self) {
            try JSONDecoder().decode(Pocket3KeyedParameterCommand.self,
                from: Data("{\"operation\":\"set\",\"parameterID\":39321,\"value\":\"AQ==\",\"expectedValueLength\":1}".utf8))
        }
        #expect(throws: Pocket3KeyedParameterError.self) {
            try Pocket3KeyedParameterCommand(set: 0x0020, value: Data([1, 2]),
                                              expectedValueLength: 1)
        }

        let raw = keyedReply(parameterID: 0x0020, value: Data([1, 2, 0xFE]))
        let decoded = try Pocket3KeyedParameterReadback(
            payload: raw, parameterID: 0x0020)
        #expect(decoded.raw == raw && decoded.value == Data([1, 2, 0xFE]))
        let decodedRoundTrip = try JSONDecoder().decode(
            Pocket3KeyedParameterReadback.self,
            from: JSONEncoder().encode(decoded))
        #expect(decodedRoundTrip == decoded)
        #expect(Pocket3KeyedParameterReadback.decode(
            raw, parameterID: 0x000F) == nil)
        #expect(Pocket3KeyedParameterReadback.decode(
            raw, parameterID: 0x0020, expectedValueLength: 1) == nil)
        #expect(Pocket3KeyedParameterReadback.decode(
            Data([0, 0, 1, 0x20, 0, 4, 1, 2, 3]), parameterID: 0x0020) == nil)

        let unknown = try #require(Pocket3AdvancedSettingReadback.decode(
            keyedReply(parameterID: 0x0020, value: Data([0x03])),
            setting: .audioChannel, expectedValueLength: 1))
        #expect(unknown.typedValue == nil && unknown.value == Data([0x03]))
        #expect(Pocket3AudioChannel(rawValue: 0x03) == nil)
    }

    @Test func medTeleAndSelfieCommandsKeepTheirDifferentRoutes() throws {
        let enable = Pocket3MedTeleCommand(.enabled)
        let disable = Pocket3MedTeleCommand(.disabled)
        #expect(enable.payload == Data([0, 0x15, 0, 0x0D, 0, 0, 0]))
        #expect(disable.payload == Data([0, 0x15, 0, 1, 0, 0, 0]))
        #expect(enable.frame(sequence: 7).commandSet == 0x02)
        #expect(enable.frame(sequence: 7).commandID == 0xFF)

        let selfieGet = try Pocket3SelfieFlipCommand.get()
        #expect(selfieGet.payload == Data([0, 1, 0x38, 0]))
        let selfieToggle = Pocket3SelfieFlipCommand.toggleFrame(sequence: 9)
        #expect(selfieToggle.source == 0x02 && selfieToggle.destination == 0x04)
        #expect(selfieToggle.commandSet == 0x04 && selfieToggle.commandID == 0x4C)
        #expect(selfieToggle.payload == Data([0xFE, 0x09]))
    }

    @Test func coordinatorRequiresFreshTypedBaselineAndCompletesOnceAfterMatchingReadback() throws {
        let session = readySession()
        let baseline = try observation(session, setting: .audioChannel,
                                       value: Data([Pocket3AudioChannel.mono.rawValue]))
        var coordinator = try Pocket3AdvancedSettingCoordinator(session: session)
        let request = try coordinator.prepare(
            .audioChannel(.stereo), baseline: baseline, nowUptime: 10)
        #expect(coordinator.phase == .awaitingAcknowledgment)
        #expect(request.command == .advancedSetting)
        #expect(request.frame.payload == Data([1, 1, 0x20, 0, 1, 2]))

        let matchingPayload = keyedReply(parameterID: 0x0020,
                                         value: Data([Pocket3AudioChannel.stereo.rawValue]))
        let result = transaction(for: request, payload: matchingPayload)
        let applied = coordinator.apply(result, nowUptime: 11.1)
        #expect(applied)
        #expect(coordinator.phase == .completed)
        #expect(coordinator.result?.completed == true)
        #expect(coordinator.result?.readback?.typedValue == .audioChannel(.stereo))
        let reapplied = coordinator.apply(result, nowUptime: 11.2)
        #expect(!reapplied)
    }

    @Test func coordinatorNoOpAckOnlyAndSafetyGatesDoNotCreateAnotherSend() throws {
        let session = readySession()
        let stereo = try observation(session, setting: .audioChannel,
                                     value: Data([Pocket3AudioChannel.stereo.rawValue]))
        var noOp = try Pocket3AdvancedSettingCoordinator(session: session)
        #expect(throws: Pocket3AdvancedSettingCoordinatorError.alreadyAtTarget) {
            try noOp.prepare(.audioChannel(.stereo), baseline: stereo, nowUptime: 10)
        }
        #expect(noOp.phase == .noOp && noOp.request == nil && noOp.result?.noOp == true)

        var pending = try Pocket3AdvancedSettingCoordinator(session: session)
        let request = try pending.prepare(
            .vocalBoost(.on),
            baseline: try observation(session, setting: .vocalBoost, value: Data([0])),
            nowUptime: 10)
        let ackOnly = pending.apply(transaction(for: request, end: .acknowledged), nowUptime: 11)
        #expect(!ackOnly)
        #expect(pending.phase == .awaitingReadback)
        let readback = try observation(session, setting: .vocalBoost,
                                       value: Data([1]), at: 11.2)
        let observed = pending.observe(readback, nowUptime: 11.3)
        #expect(observed)
        #expect(pending.phase == .completed)
        let reobserved = pending.observe(readback, nowUptime: 11.4)
        #expect(!reobserved)

        var blocked = try Pocket3AdvancedSettingCoordinator(session: session)
        _ = try blocked.prepare(
            .isoLimit(.iso1600),
            baseline: try observation(session, setting: .isoLimit, value: Data([1])),
            nowUptime: 10)
        let blockedResult = blocked.blockExecution(reason: "dry_run")
        #expect(blockedResult)
        #expect(blocked.result?.phase == .failed && blocked.result?.submitted == false)
    }

    @Test func unknownAndStaleBaselinesCannotBecomeNoOpOrAuthorizeAWrite() throws {
        let session = readySession()
        var coordinator = try Pocket3AdvancedSettingCoordinator(session: session)
        let unknown = try observation(session, setting: .isoLimit,
                                     value: Data([0xFE]))
        #expect(throws: Pocket3AdvancedSettingCoordinatorError.invalidBaseline) {
            try coordinator.prepare(.isoLimit(.iso6400), baseline: unknown,
                                     nowUptime: 10)
        }

        var stale = NativeCameraSession()
        let generation = stale.begin(sessionID: sessionID, peerID: peerID)
        _ = stale.markPaired(generation: generation)
        _ = stale.markCredentialsAvailable(generation: generation)
        _ = stale.observeDatalink(.connecting, generation: generation)
        _ = stale.observeDatalink(.ready, generation: generation)
        let old = try observation(stale.status, setting: .audioChannel,
                                  value: Data([1]), at: 1)
        var freshCoordinator = try Pocket3AdvancedSettingCoordinator(session: stale.status)
        #expect(throws: Pocket3AdvancedSettingCoordinatorError.invalidBaseline) {
            try freshCoordinator.prepare(.audioChannel(.stereo), baseline: old,
                                         nowUptime: 10)
        }

        var paired = NativeCameraSession()
        let pairedGeneration = paired.begin(sessionID: sessionID, peerID: peerID)
        _ = paired.markPaired(generation: pairedGeneration)
        #expect(throws: Pocket3AdvancedSettingCoordinatorError.sessionNotReady) {
            _ = try Pocket3AdvancedSettingCoordinator(session: paired.status)
        }
    }
}
