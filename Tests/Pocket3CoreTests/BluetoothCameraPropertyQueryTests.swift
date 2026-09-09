import Foundation
import Testing
@testable import Pocket3Core

@Suite struct BluetoothCameraPropertyQueryTests {
    private let binding = ContinuousGimbalBinding(sessionID: "ble-property-session", generation: 9)
    private func query(_ property: CameraSettingsProperty = .lensState) throws -> BluetoothCameraPropertyQuery {
        try BluetoothCameraPropertyQuery(property: property, binding: binding, sequence: 0x9123,
            transactionID: 0x11223344, startedUptime: 0)
    }
    private func bytes(_ hex: String) -> Data {
        let values = Array(hex)
        return Data(stride(from: 0, to: values.count, by: 2).map { UInt8(String(values[$0...($0 + 1)]), radix: 16)! })
    }
    private func propertyPayload(name: String, transaction: UInt32 = 77, value: Data) -> Data {
        var bytes: [UInt8] = [2,6,0,0]
        bytes += [UInt8(truncatingIfNeeded: transaction), UInt8(truncatingIfNeeded: transaction >> 8),
                  UInt8(truncatingIfNeeded: transaction >> 16), UInt8(truncatingIfNeeded: transaction >> 24)]
        bytes += [0,0,0]
        func append16(_ count: Int) { bytes += [UInt8(count & 255), UInt8((count >> 8) & 255)] }
        append16(name.utf8.count + value.count + 10); append16(name.utf8.count)
        bytes += name.utf8; bytes += [0,0,0,0,0,0]; append16(value.count); bytes += value
        return Data(bytes)
    }
    private func packet(source: UInt8 = 0x28, destination: UInt8 = 2, sequence: UInt16 = 0x9123,
                        flags: UInt8 = 0, set: UInt8 = 0, command: UInt8 = 0x99, payload: Data = Data()) throws -> Data {
        try DUMLCodec.encode(DUMLFrame(source: source, destination: destination, sequence: sequence,
            flags: flags, commandSet: set, commandID: command, payload: payload))
    }

    @Test func threeKnownPropertiesProduceOnlyOneSubscriptionToObservedAddress() throws {
        for property in [CameraSettingsProperty.lensState, .imageEffect, .exposure] {
            var state = try query(property)
            let request = state.request
            #expect(request.source == 2 && request.destination == 0x28 && request.flags == 0x40)
            #expect(request.commandSet == 0 && request.commandID == 0x99 && request.sequence == 0x9123)
            #expect(Array(request.payload.prefix(8)) == [2,2,0,0,0x44,0x33,0x22,0x11])
            #expect(String(decoding: request.payload.dropFirst(15).dropLast(4), as: UTF8.self) == property.rawValue)
            #expect(try DUMLCodec.decode(DUMLCodec.encode(request)) == request)
            try state.submitted(at: 0.01)
            #expect(throws: BridgeFailure.self) { try state.submitted(at: 0.02) }
            #expect(state.result.localSubmitted && !state.result.ackReceived && !state.result.propertyReceived)
        }
    }

    @Test func correlatedAckNeverCountsAsActualPropertyEvenWithNamedLookingBody() throws {
        var state = try query()
        try state.submitted(at: 0.01)
        let named = propertyPayload(name: "cam_lens_state", value: Data([0xb2]))
        for data in try [packet(source: 0x48, flags: 0xc0), packet(destination: 0x22, flags: 0xc0),
                         packet(sequence: 1, flags: 0xc0), packet(flags: 0xff)] {
            state.receive(data, characteristic: "FFF4", binding: binding, at: 0.1)
        }
        #expect(!state.result.ackReceived)
        state.receive(try packet(flags: 0xc0, payload: named), characteristic: "FFF4", binding: binding, at: 0.2)
        let result = state.finish(at: 2.1)
        #expect(result.ackReceived && result.ackHeader?.source == 0x28 && result.ackHeader?.sequence == 0x9123)
        #expect(!result.propertyReceived && result.observed == nil && result.valueHex == nil)
        #expect(result.timedOut && !result.ackTimedOut)
        #expect(result.evidence.contains("not_setting_confirmation"))
    }

    @Test func completeNamedValuesReuseOnlyExistingTypedDecoders() throws {
        // Fixed Kaze capture values, already used by CameraSettingsTests.
        // Copyright (c) 2026 Brian Merchant, MIT; source/license hashes are in
        // research/2026-09-08/camera-settings/PROVENANCE.md. Lens prefix also
        // matches the independently observed source28 BLE property channel.
        let fixtures: [(CameraSettingsProperty, String, CameraSettingValue)] = [
            (.imageEffect, "00003d0006380005000638000000fefe", .whiteBalance(.customKelvin(5600))),
            (.exposure, "00003c80000013010000000702c80010400600003c8000000000000064000000016501086400000001010000", .autoEV(thirdStops: 3)),
            (.lensState, "b200ffff3e00ffff3e00d900b201d9000000061207121c026e067f0401000000000000000000006701000067010000", .focus(.continuous))
        ]
        for (property, hex, expected) in fixtures {
            let value = bytes(hex)
            var state = try query(property); try state.submitted(at: 0.01)
            // The push transaction/sequence deliberately do not echo our request.
            let payload = propertyPayload(name: property.rawValue, transaction: 77, value: value)
            state.receive(try packet(sequence: 9, payload: payload), characteristic: "FFF5", binding: binding, at: 0.1)
            let result = state.finish(at: 2.1)
            #expect(result.propertyReceived && !result.ackReceived && result.ackTimedOut && !result.timedOut)
            #expect(result.property == property && result.binding == binding)
            #expect(result.propertyTransactionID == 77 && result.subscriptionTransactionID == 0x11223344)
            #expect(result.propertyHeader?.source == 0x28 && result.propertyHeader?.sequence == 9 && result.propertyHeader?.flags == 0)
            #expect(result.valueHex == hex && result.valueLength == value.count && !result.valueTruncated)
            #expect(result.observed?.value == expected && result.observed?.binding == binding)
            #expect(result.observed?.transactionID == 77 && result.observed?.receivedUptime == 0.1)
            if property == .exposure { #expect(result.observed?.exposureMode == .automatic) }
            _ = try JSONEncoder().encode(result)
        }
    }

    @Test func valueLimitPreservesLengthAndNeverDecodesTruncatedData() throws {
        for count in [64,65,200] {
            var state = try query(); try state.submitted(at: 0.01)
            let value = Data([0xb2]) + Data(repeating: 0x11, count: count - 1)
            state.receive(try packet(payload: propertyPayload(name: "cam_lens_state", value: value)),
                          characteristic: "FFF4", binding: binding, at: 0.1)
            #expect(state.result.propertyReceived && state.result.valueLength == count)
            #expect(state.result.valueHex?.count == min(count,64) * 2)
            #expect(state.result.valueTruncated == (count > 64))
            #expect((state.result.observed == nil) == (count > 64))
        }
    }

    @Test func otherPropertiesRoutesCredentialsAndMalformedFramesExposeNoValue() throws {
        var state = try query(); try state.submitted(at: 0.01)
        let secret = Data("fixture-password-never-export".utf8)
        let valid = propertyPayload(name: "cam_lens_state", value: Data([0xb2]))
        var malformed = valid; malformed[13] = 0xff; malformed[14] = 0xff
        var corrupt = try packet(payload: valid); corrupt[corrupt.count - 1] ^= 1
        let inputs = try [packet(source: 0x48, payload: valid), packet(destination: 0x22, payload: valid),
            packet(set: 7, command: 0x0e, payload: secret),
            packet(payload: propertyPayload(name: "cam_image_effect", value: secret)),
            packet(payload: propertyPayload(name: "cam_lens_state_extra", value: secret)),
            packet(payload: propertyPayload(name: "wifi_password", value: secret)),
            packet(payload: malformed), packet(payload: Data(valid.dropLast())), corrupt]
        for data in inputs { state.receive(data, characteristic: "FFF4", binding: binding, at: 0.1) }
        state.receive(try packet(payload: valid), characteristic: "FFF3", binding: binding, at: 0.1)
        #expect(!state.result.propertyReceived && state.result.valueHex == nil && state.result.observed == nil)
        let json = String(decoding: try JSONEncoder().encode(state.result), as: UTF8.self)
        #expect(!json.contains("fixture-password") && !json.contains("wifi_password") && !json.contains("cam_image_effect"))
    }

    @Test func unknownOrTooShortValuesRemainUnknownRatherThanRequestedSettings() throws {
        var unknown = try query(); try unknown.submitted(at: 0.01)
        unknown.receive(try packet(payload: propertyPayload(name: "cam_lens_state", value: Data([0]))),
                        characteristic: "FFF4", binding: binding, at: 0.1)
        #expect(unknown.result.propertyReceived && unknown.result.observed != nil && unknown.result.observed?.value == nil)
        var short = try query(.imageEffect); try short.submitted(at: 0.01)
        short.receive(try packet(payload: propertyPayload(name: "cam_image_effect", value: Data([0,0,0,0,6]))),
                      characteristic: "FFF4", binding: binding, at: 0.1)
        #expect(short.result.propertyReceived && short.result.observed == nil && short.result.valueLength == 5)
    }

    @Test func sessionWindowAndFirstObservationFenceLateOrRepeatedValues() throws {
        var state = try query()
        let continuous = try packet(payload: propertyPayload(name: "cam_lens_state", value: Data([0xb2])))
        let single = try packet(payload: propertyPayload(name: "cam_lens_state", value: Data([0xb1])))
        state.receive(continuous, characteristic: "FFF4", binding: binding, at: 0)
        try state.submitted(at: 0.01)
        let old = ContinuousGimbalBinding(sessionID: binding.sessionID, generation: binding.generation - 1)
        state.receive(continuous, characteristic: "FFF4", binding: old, at: 0.1)
        state.receive(continuous, characteristic: "FFF4", binding: binding, at: 2.02)
        #expect(!state.result.propertyReceived)
        state.receive(try packet(flags: 0x80), characteristic: "FFF4", binding: binding, at: 0.2)
        state.receive(continuous, characteristic: "FFF4", binding: binding, at: 0.1) // Backwards receive clock.
        #expect(!state.result.propertyReceived)
        state.receive(continuous, characteristic: "FFF4", binding: binding, at: 0.2) // Same callback time is valid for a distinct push.
        state.receive(single, characteristic: "FFF4", binding: binding, at: 0.3)
        #expect(state.result.observed?.value == .focus(.continuous))
        let done = state.finish(at: 2.1)
        state.receive(single, characteristic: "FFF4", binding: binding, at: 0.4)
        let repeated = state.finish(at: 4, cancelled: true, connectionChanged: true)
        #expect(done.observationWindowCompleted && done.ackReceived && done.propertyReceived)
        #expect(repeated.finishedUptime == done.finishedUptime && !repeated.cancelled && !repeated.connectionChanged)
        #expect(repeated.observed?.value == .focus(.continuous))
    }

    @Test func cancellationAndInvalidClockFinishCannotClaimTimeoutOrBreakJSON() throws {
        for changed in [false,true] {
            var state = try query(); try state.submitted(at: 0.01)
            let result = state.finish(at: 0.5, cancelled: !changed, connectionChanged: changed)
            #expect(!result.observationWindowCompleted && !result.timedOut && !result.ackTimedOut)
            #expect(result.cancelled == !changed && result.connectionChanged == changed)
        }
        var invalid = try query(); try invalid.submitted(at: 0.01)
        let result = invalid.finish(at: .nan)
        #expect(result.failure == "bluetooth_property_query_clock" && result.finishedUptime == 0.01)
        #expect(!result.observationWindowCompleted)
        _ = try JSONEncoder().encode(result)
        for uptime in [Double.nan, .infinity, -1, .greatestFiniteMagnitude] {
            #expect(throws: CameraSettingsError.self) {
                try BluetoothCameraPropertyQuery(property: .lensState, binding: binding, sequence: 1, transactionID: 1, startedUptime: uptime)
            }
        }
        var neverSubmitted = try query()
        let permit = OperationPermit(); permit.invalidate()
        var writes = 0
        #expect(throws: BridgeFailure.self) { try permit.perform { try neverSubmitted.submitted(at: 0.01); writes += 1 } }
        #expect(writes == 0 && !neverSubmitted.result.localSubmitted)
    }
}
