import Foundation
import Testing
@testable import Pocket3Core

@Suite("Bluetooth video-parameter readback")
struct BluetoothVideoParametersReadbackTests {
    private let sessionID = UUID()
    private let peripheralID = UUID()
    private var binding: ContinuousGimbalBinding {
        ContinuousGimbalBinding(sessionID: "ble:\(sessionID.uuidString)", generation: 0)
    }

    private func request() throws -> BluetoothVideoParametersReadbackRequest {
        try BluetoothVideoParametersReadbackRequest(cliArguments: [
            "--session", sessionID.uuidString,
            "--peripheral", peripheralID.uuidString
        ])
    }

    private func packet(source: UInt8 = 0x28, destination: UInt8 = 0x02,
                        sequence: UInt16 = 51779, flags: UInt8 = 0,
                        payload: Data = Data()) throws -> Data {
        try DUMLCodec.encode(DUMLFrame(
            source: source, destination: destination, sequence: sequence,
            flags: flags, commandSet: 0, commandID: 0x99, payload: payload))
    }

    private func propertyPayload(name: String, transaction: UInt32,
                                 value: Data) -> Data {
        var bytes: [UInt8] = [2, 6, 0, 0]
        bytes += [UInt8(truncatingIfNeeded: transaction),
                  UInt8(truncatingIfNeeded: transaction >> 8),
                  UInt8(truncatingIfNeeded: transaction >> 16),
                  UInt8(truncatingIfNeeded: transaction >> 24)]
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

    private func query() throws -> BluetoothCameraPropertyQuery {
        try BluetoothCameraPropertyQuery(
            property: .videoParameters, binding: binding,
            sequence: 51779, transactionID: 0xD6_4E_18_2A,
            startedUptime: 0)
    }

    @Test func requestIsFixedToOnePropertyAndRejectsExtraFields() throws {
        let value = try request()
        #expect(value.arguments["expectedSessionID"] ==
                .string(sessionID.uuidString))
        #expect(value.arguments["peripheralID"] ==
                .string(peripheralID.uuidString))
        #expect(BluetoothVideoParametersReadbackProbe.property ==
                .videoParameters)
        #expect(BluetoothVideoParametersReadbackRequest.schema[
            "additionalProperties"] == .bool(false))
        #expect(throws: BluetoothVideoParametersReadbackRequestError.invalidArguments) {
            try BluetoothVideoParametersReadbackRequest(arguments: .object([
                "expectedSessionID": .string(sessionID.uuidString),
                "peripheralID": .string(peripheralID.uuidString),
                "property": .string("cam_video_param_v2")
            ]))
        }
    }

    @Test func ackThenNotificationIsReadbackAndUsesNoGetFallback() throws {
        var query = try query()
        #expect(query.request.source == 0x02)
        #expect(query.request.destination == 0x28)
        #expect(query.request.flags == 0x40)
        #expect(query.request.commandSet == 0x00)
        #expect(query.request.commandID == 0x99)
        #expect(query.request.sequence == 51779)
        try query.submitted(at: 0.01)
        query.receive(try packet(flags: 0xc0), characteristic: "FFF4",
                      binding: binding, at: 0.10)

        // The last byte and the extra byte are deliberately unknown to the
        // typed decoder. They must survive the bounded reader unchanged.
        let raw = Data([0x6c, 0x03, 0x00, 0xaa, 0xbb, 0xcc, 0xdd, 0xee,
                        0xfe, 0x99])
        let push = propertyPayload(name: "cam_video_param_v2",
                                   transaction: 0x1020_3040, value: raw)
        query.receive(try packet(sequence: 41, payload: push),
                      characteristic: "FFF4", binding: binding, at: 0.20)

        let report = BluetoothVideoParametersReadbackProbe.report(
            request: try request(), query: query.finish(at: 2.1))
        #expect(report.outcome == .readback)
        #expect(report.acknowledgmentReceived)
        #expect(report.acknowledgmentSequence == 51779)
        #expect(report.notificationReceived)
        #expect(report.notificationSequence == 41)
        #expect(report.notificationTransactionID == 0x1020_3040)
        #expect(report.rawValue == raw)
        #expect(report.rawValueLength == raw.count)
        #expect(!report.rawValueTruncated)
        #expect(report.typedValue?.resolution == .portrait3K)
        #expect(report.typedValue?.frameRate == .fps30)
        #expect(report.typedValue?.compression == nil)
        #expect(report.terminalStep == .complete)
        #expect(!report.followUpGetIssued)
        #expect(report.evidence.contains("00/99/06 notification"))
        #expect(report.evidence.contains("00/01 GET"))
    }

    @Test func notificationMayPrecedeTransportAckWithoutSequenceEcho() throws {
        var query = try query()
        try query.submitted(at: 0.01)
        let raw = Data([0x10, 0x06, 0, 0, 0, 2, 1, 0, 1])
        query.receive(try packet(sequence: 7, payload: propertyPayload(
            name: "cam_video_param_v2", transaction: 77, value: raw)),
            characteristic: "FFF5", binding: binding, at: 0.10)
        query.receive(try packet(flags: 0x80), characteristic: "FFF4",
                      binding: binding, at: 0.20)

        let report = BluetoothVideoParametersReadbackProbe.report(
            request: try request(), query: query.finish(at: 2.1))
        #expect(report.outcome == .readback)
        #expect(report.acknowledgmentSequence == 51779)
        #expect(report.notificationSequence == 7)
        #expect(report.rawValue == raw)
    }

    @Test func ackWithoutNotificationStopsAndDoesNotGuessGet() throws {
        var query = try query()
        try query.submitted(at: 0.01)
        query.receive(try packet(flags: 0xc0), characteristic: "FFF4",
                      binding: binding, at: 0.10)
        let report = BluetoothVideoParametersReadbackProbe.report(
            request: try request(), query: query.finish(at: 2.1))
        #expect(report.outcome == .noReply)
        #expect(report.terminalStep == .stopWithoutGet)
        #expect(report.reason == "ack_without_named_property_notification")
        #expect(!report.notificationReceived)
        #expect(!report.followUpGetIssued)
        #expect(report.rawValue == nil)
    }

    @Test func wrongPropertyNotificationCannotBecomeVideoReadback() throws {
        var query = try query()
        try query.submitted(at: 0.01)
        let wrong = propertyPayload(name: "cam_lens_state", transaction: 4,
                                    value: Data([0xb2]))
        query.receive(try packet(sequence: 8, payload: wrong),
                      characteristic: "FFF4", binding: binding, at: 0.10)
        let report = BluetoothVideoParametersReadbackProbe.report(
            request: try request(), query: query.finish(at: 2.1))
        #expect(report.outcome == .wrongEnvelope)
        #expect(report.reason == "rejected_named_property_notification")
        #expect(report.rawValue == nil)
        #expect(!report.followUpGetIssued)
    }
}
