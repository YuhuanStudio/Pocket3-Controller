import Foundation
import Testing
@testable import Pocket3Core

// Capture fixtures from Kaze 341a35de18493ff61f97c93b8b10161a7512aa36.
// Copyright (c) 2026 Brian Merchant, MIT; complete notice and source hashes:
// research/2026-09-08/camera-settings/PROVENANCE.md.
@Suite struct CameraSettingsTests {
    let binding = ContinuousGimbalBinding(sessionID: "settings-fixture", generation: 1)
    private func bytes(_ hex: String) -> Data {
        let chars = Array(hex)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0+1)]), radix: 16)! })
    }
    private func wb(_ kelvin: Int? = nil, transaction: UInt32 = 1) -> CameraPropertyPush {
        CameraPropertyPush(property: .imageEffect, transactionID: transaction,
            value: Data([0,0,0,0,kelvin == nil ? 0 : 6,UInt8((kelvin ?? 0) / 100)]))
    }
    private func focus(_ byte: UInt8, transaction: UInt32 = 1) -> CameraPropertyPush {
        CameraPropertyPush(property: .lensState, transactionID: transaction, value: Data([byte]))
    }
    private func exposure(_ thirds: Int, mode: UInt8 = 1, transaction: UInt32 = 1) -> CameraPropertyPush {
        var value = [UInt8](repeating: 0, count: 20); value[6] = UInt8(0x10+thirds); value[7] = mode
        return CameraPropertyPush(property: .exposure, transactionID: transaction, value: Data(value))
    }

    @Test func typedSettingCommandsMatchCapturedBytesAndRouting() throws {
        let commands: [(CameraSettingValue, UInt8, String)] = [
            (.whiteBalance(.automatic),0x2c,"0000000000"),
            (.whiteBalance(.customKelvin(5600)),0x2c,"0638000000"),
            (.focus(.single),0x24,"01"),(.focus(.continuous),0x24,"02"),
            (.autoEV(thirdStops:-9),0x2e,"07"),(.autoEV(thirdStops:0),0x2e,"10"),(.autoEV(thirdStops:9),0x2e,"19"),
        ]
        for (value, id, payload) in commands {
            let command = try CameraSettingCommand(value), frame = command.frame(sequence: 0x1234)
            #expect(command.payload == bytes(payload))
            #expect(frame.source == 2 && frame.destination == 1 && frame.flags == 0x40)
            #expect(frame.commandSet == 2 && frame.commandID == id && frame.sequence == 0x1234)
            #expect(try DUMLCodec.decode(command.encodedFrame(sequence: 0x1234)) == frame)
            #expect(try JSONDecoder().decode(CameraSettingCommand.self, from: JSONEncoder().encode(command)) == command)
        }
    }

    @Test func settingsRejectInvalidNumbersAndCodableCannotBypassBounds() throws {
        for invalid in [Double.nan,.infinity,-1,1999,5650,10001] {
            #expect(throws: CameraSettingsError.self) { try CameraSettingCommand.whiteBalance(kelvin: invalid) }
        }
        for invalid in [Double.nan,.infinity,-10,0.5,10] {
            #expect(throws: CameraSettingsError.self) { try CameraSettingCommand.autoEV(thirdStops: invalid) }
        }
        let invalid = try JSONEncoder().encode(CameraSettingValue.whiteBalance(.customKelvin(Int.max)))
        #expect(throws: CameraSettingsError.invalidWhiteBalance) { try JSONDecoder().decode(CameraSettingCommand.self, from: invalid) }
        #expect(try CameraSettingCommand.whiteBalance(kelvin: 2000).payload == bytes("0614000000"))
        #expect(try CameraSettingCommand.whiteBalance(kelvin: 10000).payload == bytes("0664000000"))
    }

    @Test func propertySubscriptionAndFrozenPushesUseNamedRecordLayout() throws {
        let subscription = CameraPropertyCodec.subscription(.imageEffect, transactionID: 0xc938, sequence: 9)
        #expect(subscription.source == 2 && subscription.destination == 0x28 && subscription.flags == 0x40)
        #expect(subscription.commandSet == 0 && subscription.commandID == 0x99)
        #expect(subscription.payload == bytes("0202000038c900000000001600100063616d5f696d6167655f65666665637400000000"))
        let captures = [
            "020600008e2a00000000002a00100063616d5f696d6167655f656666656374000000000000100000003d0006380005000638000000fefe",
            "02060000882a000000000044000e0063616d5f6578706f5f706172616d0000000000002c0000003c80000013010000000702c80010400600003c8000000000000064000000016501086400000001010000",
            "02060000902a000000000047000e0063616d5f6c656e735f73746174650000000000002f00b200ffff3e00ffff3e00d900b201d9000000061207121c026e067f0401000000000000000000006701000067010000",
        ]
        var state = try CameraSettingsState(binding: binding)
        for (index, hex) in captures.enumerated() {
            let wrapped = Data([0xff,0xee]) + bytes(hex)
            let decoded = try CameraPropertyCodec.decodePayload(wrapped.dropFirst(2))
            let push = try #require(decoded)
            let applied = state.apply(push,binding:binding,receivedUptime:Double(index),now:Double(index))
            #expect(applied)
        }
        #expect(state.currentValue(for:.imageEffect,now:2) == .whiteBalance(.customKelvin(5600)))
        #expect(state.currentValue(for:.exposure,now:2) == .autoEV(thirdStops:3))
        #expect(state.observation(for:.exposure)?.exposureMode == .automatic)
        #expect(state.currentValue(for:.lensState,now:2) == .focus(.continuous))
    }

    @Test func malformedPropertyLengthsNamesAndWrongCommandsDoNotDecode() throws {
        let valid = bytes("020600008e2a00000000002a00100063616d5f696d6167655f656666656374000000000000100000003d0006380005000638000000fefe")
        for count in 0..<valid.count {
            #expect(throws: CameraPropertyCodecError.self) { try CameraPropertyCodec.decodePayload(valid.prefix(count)) }
        }
        var badName = valid; badName[15] = 0xff
        #expect(throws: CameraPropertyCodecError.invalidName) { try CameraPropertyCodec.decodePayload(badName) }
        var hugeName = valid; hugeName[13] = 0xff; hugeName[14] = 0xff
        #expect(throws: CameraPropertyCodecError.malformedLayout) { try CameraPropertyCodec.decodePayload(hugeName) }
        #expect(throws: CameraPropertyCodecError.invalidSize) { try CameraPropertyCodec.decodePayload(Data(repeating:0,count:1011)) }
        let unrelated = DUMLFrame(source:2,destination:1,sequence:1,flags:0x40,commandSet:2,commandID:0x99,payload:valid)
        #expect(try CameraPropertyCodec.decodePush(from: unrelated) == nil)
        var corrupt = try DUMLCodec.encode(DUMLFrame(source:2,destination:1,sequence:1,flags:0x40,commandSet:0,commandID:0x99,payload:valid))
        corrupt[20] ^= 1
        #expect(throws: DUMLCodecError.invalidFrameChecksum) { try CameraPropertyCodec.decodeFrame(corrupt) }
    }

    @Test func preparedAndSubmittedRequestsNeverReplaceObservedState() throws {
        var state = try CameraSettingsState(binding: binding)
        let seeded = state.apply(wb(),binding:binding,receivedUptime:0,now:0)
        #expect(seeded)
        let request = try state.prepare(CameraSettingCommand.whiteBalance(kelvin:5600),sequence:7,now:1)
        #expect(state.operation?.phase == .prepared)
        #expect(state.currentValue(for:.imageEffect,now:1) == .whiteBalance(.automatic))
        try state.validateForSubmission(request,binding:binding,now:1.1)
        try state.markSubmitted(request,binding:binding,at:1.1)
        #expect(state.operation?.phase == .pending && state.operation?.confirmation == nil)
        #expect(state.currentValue(for:.imageEffect,now:1.1) == .whiteBalance(.automatic))
        let applied = state.apply(wb(5600,transaction:999),binding:binding,receivedUptime:1.2,now:1.2)
        #expect(applied)
        #expect(state.operation?.phase == .confirmed)
        #expect(state.operation?.confirmation?.transactionID == 999) // Does not pretend it echoes sequence 7.
        #expect(state.operation?.confirmation?.basis == "fresh_matching_property_after_submission")
    }

    @Test func wrongGenerationOldFutureAndPreSubmissionSamplesCannotConfirm() throws {
        var state = try CameraSettingsState(binding: binding)
        state.apply(focus(0xb2),binding:binding,receivedUptime:10,now:10)
        let request = try state.prepare(CameraSettingCommand(.focus(.single)),sequence:1,now:10.1)
        try state.markSubmitted(request,binding:binding,at:10.5)
        let wrong = ContinuousGimbalBinding(sessionID:binding.sessionID,generation:2)
        let wrongGeneration = state.apply(focus(0xb1),binding:wrong,receivedUptime:11,now:11)
        let oldSample = state.apply(focus(0xb1),binding:binding,receivedUptime:9,now:11)
        let futureSample = state.apply(focus(0xb1),binding:binding,receivedUptime:13,now:12)
        let preSubmission = state.apply(focus(0xb1),binding:binding,receivedUptime:10.25,now:10.75)
        #expect(!wrongGeneration && !oldSample && !futureSample)
        #expect(preSubmission)
        #expect(state.operation?.phase == .pending)
        let matching = state.apply(focus(0xb1),binding:binding,receivedUptime:11,now:11)
        #expect(matching)
        #expect(state.operation?.phase == .confirmed)
        let duplicate = state.apply(focus(0xb2),binding:binding,receivedUptime:11,now:11.1)
        #expect(!duplicate)
    }

    @Test func matchingSampleBeforeMarkSubmittedIsNotRetroConfirmed() throws {
        var state = try CameraSettingsState(binding: binding)
        state.apply(wb(),binding:binding,receivedUptime:0,now:0)
        let request = try state.prepare(CameraSettingCommand.whiteBalance(kelvin:5600),sequence:1,now:1)
        state.apply(wb(5600),binding:binding,receivedUptime:1.1,now:1.1)
        #expect(state.operation?.phase == .prepared)
        try state.markSubmitted(request,binding:binding,at:1.2)
        #expect(state.operation?.phase == .pending && state.operation?.confirmation == nil)
        state.apply(wb(5600),binding:binding,receivedUptime:1.3,now:1.3)
        #expect(state.operation?.phase == .confirmed)
    }

    @Test func autoEVRequiresAutoBaselineAndAutoReadbackAfterSubmission() throws {
        var state = try CameraSettingsState(binding: binding)
        state.apply(exposure(0,mode:4),binding:binding,receivedUptime:0,now:0)
        let command = try CameraSettingCommand.autoEV(thirdStops:1)
        #expect(throws: CameraSettingsError.exposureNotAutomatic) { try state.prepare(command,sequence:1,now:0.1) }
        state.apply(exposure(0),binding:binding,receivedUptime:0.2,now:0.2)
        let request = try state.prepare(command,sequence:1,now:0.3)
        try state.markSubmitted(request,binding:binding,at:0.4)
        state.apply(exposure(1,mode:4),binding:binding,receivedUptime:0.5,now:0.5)
        #expect(state.operation?.phase == .pending)
        state.apply(exposure(1),binding:binding,receivedUptime:0.6,now:0.6)
        #expect(state.operation?.phase == .confirmed)
    }

    @Test func unknownCodesClearValuesAndStalenessCannotUseLastSentFallback() throws {
        var state = try CameraSettingsState(binding: binding)
        state.apply(focus(0xb2),binding:binding,receivedUptime:0,now:0)
        state.apply(focus(0xee),binding:binding,receivedUptime:1,now:1) // Unknown firmware value must not reuse the prior mode.
        #expect(state.currentValue(for:.lensState,now:1) == nil)
        #expect(throws: CameraSettingsError.noFreshBaseline) { try state.prepare(CameraSettingCommand(.focus(.single)),sequence:1,now:1) }
        state.apply(wb(),binding:binding,receivedUptime:1,now:1)
        #expect(state.currentValue(for:.imageEffect,now:6.001) == nil)
        #expect(state.currentValue(for:.imageEffect,now:0) == nil)
        #expect(state.currentValue(for:.imageEffect,now:.nan) == nil)
        let stale = state.apply(wb(5600),binding:binding,receivedUptime:1,now:7)
        #expect(!stale)
    }

    @Test func finalWriteValidationRejectsChangedBaselineOrCancelledRequest() throws {
        var state = try CameraSettingsState(binding: binding)
        state.apply(focus(0xb2),binding:binding,receivedUptime:0,now:0)
        let request = try state.prepare(CameraSettingCommand(.focus(.single)),sequence:1,now:0.1)
        state.apply(focus(0xb1),binding:binding,receivedUptime:0.2,now:0.2)
        #expect(throws: CameraSettingsError.baselineChanged) { try state.validateForSubmission(request,binding:binding,now:0.3) }
        state.cancel(request)
        #expect(throws: CameraSettingsError.invalidTransition) { try state.validateForSubmission(request,binding:binding,now:0.3) }
        let next = try state.prepare(CameraSettingCommand(.focus(.continuous)),sequence:2,now:0.4)
        #expect(throws: CameraSettingsError.unknownRequest) { try state.validateForSubmission(request,binding:binding,now:0.5) }
        #expect(throws: CameraSettingsError.wrongSession) {
            try state.validateForSubmission(next,binding:ContinuousGimbalBinding(sessionID:"other",generation:1),now:0.5)
        }
    }

    @Test func lateMatchingReadbackDoesNotTurnTimeoutIntoSuccess() throws {
        var state = try CameraSettingsState(binding: binding)
        state.apply(wb(),binding:binding,receivedUptime:0,now:0)
        let request = try state.prepare(CameraSettingCommand.whiteBalance(kelvin:5600),sequence:1,now:0.1,timeout:0.5)
        try state.markSubmitted(request,binding:binding,at:0.2)
        state.expire(at:0.7)
        #expect(state.operation?.phase == .unconfirmed && state.operation?.failureCode == "readback_timeout")
        state.apply(wb(5600),binding:binding,receivedUptime:0.8,now:0.8)
        #expect(state.currentValue(for:.imageEffect,now:0.8) == .whiteBalance(.customKelvin(5600)))
        #expect(state.operation?.phase == .unconfirmed && state.operation?.confirmation == nil)
    }

    @Test func requestTimesAreFiniteAndBoundedAndPendingWritesDoNotOverlap() throws {
        var state = try CameraSettingsState(binding: binding)
        state.apply(wb(),binding:binding,receivedUptime:0,now:0)
        let command = try CameraSettingCommand.whiteBalance(kelvin:5600)
        for timeout in [Double.nan,.infinity,0,-1,5.01] {
            #expect(throws: CameraSettingsError.invalidTime) { try state.prepare(command,sequence:1,now:0.1,timeout:timeout) }
        }
        #expect(throws: CameraSettingsError.invalidTime) { try state.prepare(command,sequence:1,now:.nan) }
        _ = try state.prepare(command,sequence:1,now:0.1)
        #expect(throws: CameraSettingsError.busy) { try state.prepare(command,sequence:2,now:0.2) }
    }
}
