import Foundation
import Testing
@testable import Pocket3Core

@Suite("Bluetooth single lens/exposure readback")
struct BluetoothSinglePropertyReadbackTests {
    private let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let peripheralID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private var binding: ContinuousGimbalBinding {
        ContinuousGimbalBinding(
            sessionID: "ble:\(sessionID.uuidString)", generation: 17)
    }

    private func request(
        _ property: BluetoothSinglePropertyReadbackProperty = .lensState
    ) throws -> BluetoothSinglePropertyReadbackRequest {
        try BluetoothSinglePropertyReadbackRequest(cliArguments: [
            "--property", property.rawValue,
            "--session", sessionID.uuidString,
            "--peripheral", peripheralID.uuidString
        ])
    }

    private func query(
        _ property: BluetoothSinglePropertyReadbackProperty = .lensState
    ) throws -> BluetoothCameraPropertyQuery {
        try BluetoothCameraPropertyQuery(
            property: property.cameraProperty,
            binding: binding,
            sequence: 0x9123,
            transactionID: 0x11223344,
            startedUptime: 0)
    }

    private func packet(
        sequence: UInt16 = 0x9123,
        flags: UInt8 = 0,
        payload: Data = Data()
    ) throws -> Data {
        try DUMLCodec.encode(DUMLFrame(
            source: 0x28,
            destination: 0x02,
            sequence: sequence,
            flags: flags,
            commandSet: 0x00,
            commandID: 0x99,
            payload: payload))
    }

    private func propertyPayload(
        name: String,
        transaction: UInt32,
        value: Data
    ) -> Data {
        var bytes: [UInt8] = [2, 6, 0, 0]
        bytes += [
            UInt8(truncatingIfNeeded: transaction),
            UInt8(truncatingIfNeeded: transaction >> 8),
            UInt8(truncatingIfNeeded: transaction >> 16),
            UInt8(truncatingIfNeeded: transaction >> 24)
        ]
        bytes += [0, 0, 0]
        func append16(_ value: Int) {
            bytes += [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
        }
        append16(name.utf8.count + value.count + 10)
        append16(name.utf8.count)
        bytes += name.utf8
        bytes += [0, 0, 0, 0, 0, 0]
        append16(value.count)
        bytes += value
        return Data(bytes)
    }

    private func hex(_ value: String) -> Data {
        let characters = Array(value)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        })
    }

    @Test func requestIsClosedToLensAndExposureAndBindsBothIdentifiers() throws {
        let lens = try request(.lensState)
        #expect(lens.property.cameraProperty == .lensState)
        #expect(lens.arguments["property"] == .string("cam_lens_state"))
        #expect(lens.arguments["expectedSessionID"] ==
                .string(sessionID.uuidString))
        #expect(lens.arguments["peripheralID"] ==
                .string(peripheralID.uuidString))
        #expect(BluetoothSinglePropertyReadbackProbe.properties ==
                [.lensState, .exposure])
        #expect(BluetoothSinglePropertyReadbackRequest.schema[
            "additionalProperties"] == .bool(false))

        #expect(throws: BluetoothSinglePropertyReadbackRequestError.invalidArguments) {
            try BluetoothSinglePropertyReadbackRequest(arguments: .object([
                "property": .string("cam_video_param_v2"),
                "expectedSessionID": .string(sessionID.uuidString),
                "peripheralID": .string(peripheralID.uuidString)
            ]))
        }
        #expect(throws: BluetoothSinglePropertyReadbackRequestError.invalidArguments) {
            try BluetoothSinglePropertyReadbackRequest(arguments: .object([
                "property": .string("cam_lens_state"),
                "expectedSessionID": .string(sessionID.uuidString),
                "peripheralID": .string(peripheralID.uuidString),
                "setter": .bool(true)
            ]))
        }
        #expect(throws: BluetoothSinglePropertyReadbackRequestError.invalidArguments) {
            try BluetoothSinglePropertyReadbackRequest(cliArguments: [
                "--property", "cam_lens_state",
                "--property", "cam_expo_param",
                "--session", sessionID.uuidString,
                "--peripheral", peripheralID.uuidString
            ])
        }
    }

    @Test func eachPropertyUsesOneSubscriptionAndReturnsRawAndTypedReadback() throws {
        let fixtures: [(
            BluetoothSinglePropertyReadbackProperty, Data, CameraSettingValue
        )] = [
            (
                .lensState,
                hex("b200ffff3e00ffff3e00d900b201d9000000061207121c026e067f0401000000000000000000006701000067010000"),
                .focus(.continuous)
            ),
            (
                .exposure,
                hex("00003c80000013010000000702c80010400600003c8000000000000064000000016501086400000001010000"),
                .autoEV(thirdStops: 3)
            )
        ]

        for (property, raw, expectedSetting) in fixtures {
            var state = try query(property)
            try state.submitted(at: 0.01)
            state.receive(
                try packet(flags: 0xc0),
                characteristic: "FFF4",
                binding: binding,
                at: 0.05)
            state.receive(
                try packet(
                    sequence: 9,
                    payload: propertyPayload(
                        name: property.rawValue,
                        transaction: 0x10203040,
                        value: raw)),
                characteristic: "FFF5",
                binding: binding,
                at: 0.10)

            let report = BluetoothSinglePropertyReadbackProbe.report(
                request: try request(property),
                query: state.finish(at: 2.1))
            #expect(report.property == property.cameraProperty)
            #expect(report.propertyName == property.rawValue)
            #expect(report.observedBinding == binding)
            #expect(report.submitted)
            #expect(report.subscriptionCount == 1)
            #expect(report.acknowledgmentReceived)
            #expect(report.notificationReceived)
            #expect(report.notificationSequence == 9)
            #expect(report.notificationTransactionID == 0x10203040)
            #expect(report.rawValue == raw)
            #expect(report.rawValueLength == raw.count)
            #expect(!report.rawValueTruncated)
            #expect(report.settingValue == expectedSetting)
            #expect(report.terminalStep == .complete)
            #expect(report.outcome == .readback)
            #expect(!report.setterIssued && !report.followUpGetIssued)
            #expect(report.readbackSource == .namedPropertyNotification)
            #expect(report.evidence.contains(
                "Kaze@341a35de18493ff61f97c93b8b10161a7512aa36"))
            #expect(report.evidence.contains("one 00/99 subscription"))
            #expect(report.evidence.contains("no setter or follow-up GET"))
            #expect(report.typedValue?.property == property.cameraProperty)
            #expect(try JSONEncoder().encode(report).isEmpty == false)
        }
    }

    @Test func unknownEnumStillReturnsTypedSchemaAndRetainsRawCode() throws {
        var state = try query(.lensState)
        try state.submitted(at: 0.01)
        let raw = Data([0x7f])
        state.receive(
            try packet(payload: propertyPayload(
                name: "cam_lens_state", transaction: 99, value: raw)),
            characteristic: "FFF4",
            binding: binding,
            at: 0.10)

        let report = BluetoothSinglePropertyReadbackProbe.report(
            request: try request(.lensState),
            query: state.finish(at: 2.1))
        guard case .lensState(let value) = report.typedValue else {
            Issue.record("lens readback schema missing")
            return
        }
        #expect(value.raw == raw)
        #expect(value.focusModeRaw == 0x7f)
        #expect(value.focusMode == nil)
        #expect(report.settingValue == nil)
        #expect(report.outcome == .readback)
    }

    @Test func ackOnlyOrShortValueStopsWithoutGuessingGet() throws {
        var ackOnly = try query(.exposure)
        try ackOnly.submitted(at: 0.01)
        ackOnly.receive(
            try packet(flags: 0xc0),
            characteristic: "FFF4",
            binding: binding,
            at: 0.10)
        let noReply = BluetoothSinglePropertyReadbackProbe.report(
            request: try request(.exposure),
            query: ackOnly.finish(at: 2.1))
        #expect(noReply.outcome == .noReply)
        #expect(noReply.reason == "ack_without_named_property_notification")
        #expect(noReply.terminalStep == .stopWithoutGet)
        #expect(noReply.rawValue == nil)
        #expect(!noReply.followUpGetIssued && !noReply.setterIssued)

        var short = try query(.exposure)
        try short.submitted(at: 0.01)
        let raw = Data([0x01, 0x02, 0x03])
        short.receive(
            try packet(payload: propertyPayload(
                name: "cam_expo_param", transaction: 5, value: raw)),
            characteristic: "FFF4",
            binding: binding,
            at: 0.10)
        let malformed = BluetoothSinglePropertyReadbackProbe.report(
            request: try request(.exposure),
            query: short.finish(at: 2.1))
        #expect(malformed.notificationReceived)
        #expect(malformed.rawValue == raw)
        #expect(malformed.rawValueLength == raw.count)
        #expect(malformed.outcome == .wrongEnvelope)
        #expect(malformed.reason == "named_property_value_short_or_unparseable")
        #expect(malformed.terminalStep == .stopWithoutGet)
        #expect(!malformed.followUpGetIssued)
    }

    @Test func wrongPropertyOrSessionCannotBecomeAReadback() throws {
        var wrongProperty = try query(.lensState)
        try wrongProperty.submitted(at: 0.01)
        wrongProperty.receive(
            try packet(payload: propertyPayload(
                name: "cam_expo_param", transaction: 6,
                value: Data(repeating: 0, count: 20))),
            characteristic: "FFF4",
            binding: binding,
            at: 0.10)
        let wrong = BluetoothSinglePropertyReadbackProbe.report(
            request: try request(.lensState),
            query: wrongProperty.finish(at: 2.1))
        #expect(wrong.outcome == .wrongEnvelope)
        #expect(wrong.reason == "rejected_named_property_notification")
        #expect(wrong.rawValue == nil)

        let otherBinding = ContinuousGimbalBinding(
            sessionID: "ble:33333333-3333-3333-3333-333333333333", generation: 17)
        var mismatched = try BluetoothCameraPropertyQuery(
            property: .lensState,
            binding: otherBinding,
            sequence: 0x9123,
            transactionID: 7,
            startedUptime: 0)
        try mismatched.submitted(at: 0.01)
        mismatched.receive(
            try packet(payload: propertyPayload(
                name: "cam_lens_state", transaction: 8, value: Data([0xb2]))),
            characteristic: "FFF4",
            binding: otherBinding,
            at: 0.10)
        let sessionMismatch = BluetoothSinglePropertyReadbackProbe.report(
            request: try request(.lensState),
            query: mismatched.finish(at: 2.1))
        #expect(sessionMismatch.outcome == .wrongEnvelope)
        #expect(sessionMismatch.reason == "query_session_mismatch")
        #expect(sessionMismatch.observedBinding == otherBinding)
    }
}
