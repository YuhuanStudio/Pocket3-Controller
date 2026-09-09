import Foundation
import Testing
@testable import Pocket3Core

@Suite struct BluetoothReadinessQueryTests {
    private func response(sequence: UInt16 = 0x9123, source: UInt8 = 4, destination: UInt8 = 2,
                          set: UInt8 = 4, command: UInt8 = 0x50, flags: UInt8 = 0xc0,
                          payload: Data = Data([2, 0, 0])) throws -> Data {
        try DUMLCodec.encode(DUMLFrame(source: source, destination: destination, sequence: sequence,
            flags: flags, commandSet: set, commandID: command, payload: payload))
    }

    @Test func requestIsOneExactReadinessPacketAndReplyDoesNotAuthorizeMotors() throws {
        var query = BluetoothReadinessQuery(sequence: 0x9123, startedUptime: 1)
        let packet = try DUMLCodec.encode(query.request)
        #expect(packet.count == 16)
        #expect(query.request.source == 2 && query.request.destination == 4 && query.request.flags == 0x40)
        #expect(query.request.commandSet == 4 && query.request.commandID == 0x50)
        #expect(query.request.payload == Data([1, 4, 5]))
        query.submitted(at: 1.01)
        let accepted = query.receive(try response(), characteristic: "FFF4", at: 1.2)
        #expect(accepted)
        let result = query.finish(at: 1.21, cancelled: false, connectionChanged: false)
        #expect(result.localSubmitted && result.responseReceived && !result.timedOut)
        #expect(result.payloadHex == "020000" && result.payloadByteCount == 3)
        #expect(result.replyHeader?.source == 4 && result.replyHeader?.destination == 2 && result.replyHeader?.sequence == 0x9123)
        #expect(!result.motorPermissionConfirmed && result.interpretation == "routing_readiness_reply_only")
    }

    @Test func unrelatedRoutesFlagsSequencesAndCredentialTrafficNeverExposePayload() throws {
        let inputs = try [response(sequence: 0x9124), response(source: 5), response(destination: 3),
                          response(set: 7, command: 0x0e, payload: Data("fixture-private-password".utf8)),
                          response(command: 1), response(flags: 0x40)]
        for input in inputs {
            var query = BluetoothReadinessQuery(sequence: 0x9123, startedUptime: 1)
            query.submitted(at: 1.01)
            let accepted = query.receive(input, characteristic: "FFF5", at: 1.1)
            #expect(!accepted && query.result.payloadHex == nil && query.result.replyHeader == nil)
        }
        var corrupt = try response(); corrupt[corrupt.count - 1] ^= 1
        var query = BluetoothReadinessQuery(sequence: 0x9123, startedUptime: 1)
        query.submitted(at: 1.01)
        let accepted = query.receive(corrupt, characteristic: "FFF4", at: 1.1)
        #expect(!accepted && !query.result.responseReceived)
    }

    @Test func timeoutIsOneSecondAndLateOrDuplicateRepliesCannotChangeTheResult() throws {
        let frame = try response()
        var query = BluetoothReadinessQuery(sequence: 0x9123, startedUptime: 1)
        let early = query.receive(frame, characteristic: "FFF4", at: 1.01)
        #expect(!early)
        query.submitted(at: 1.02)
        let late = query.receive(frame, characteristic: "FFF4", at: 2.021)
        #expect(!late)
        let result = query.finish(at: 2.03, cancelled: false, connectionChanged: false)
        #expect(result.timedOut && result.payloadHex == nil)
        let afterFinish = query.receive(frame, characteristic: "FFF4", at: 1.5)
        #expect(!afterFinish)

        var once = BluetoothReadinessQuery(sequence: 0x9123, startedUptime: 1)
        once.submitted(at: 1.01)
        _ = once.receive(frame, characteristic: "FFF4", at: 1.1)
        let duplicate = once.receive(try response(payload: Data([9])), characteristic: "FFF5", at: 1.2)
        #expect(!duplicate && once.result.payloadHex == "020000")
    }

    @Test func cancellationAndConnectionChangesAreNotReportedAsTimeoutOrMotorPermission() {
        for changed in [false, true] {
            var query = BluetoothReadinessQuery(sequence: 1, startedUptime: 1)
            query.submitted(at: 1.01)
            let result = query.finish(at: 2.1, cancelled: !changed, connectionChanged: changed)
            #expect(!result.timedOut && !result.motorPermissionConfirmed && result.payloadHex == nil)
        }
    }
}
