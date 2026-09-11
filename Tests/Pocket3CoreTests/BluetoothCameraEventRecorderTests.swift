import Foundation
import Testing
@testable import Pocket3Core

@Suite struct BluetoothCameraEventRecorderTests {
    private func packet(sequence: UInt16, source: UInt8 = 1, destination: UInt8 = 2,
                        flags: UInt8 = 0, commandSet: UInt8 = 2, commandID: UInt8 = 0x89,
                        payload: Data = Data([0x01, 0x02, 0xa0])) throws -> ValidatedDUMLPacket {
        let frame = DUMLFrame(source: source, destination: destination, sequence: sequence,
            flags: flags, commandSet: commandSet, commandID: commandID, payload: payload)
        let data = try DUMLCodec.encode(frame)
        return ValidatedDUMLPacket(frameData: data, frame: try DUMLCodec.decode(data))
    }

    @Test func parserKeepsOnlyValidatedCameraDomainFields() throws {
        let session = UUID(), peer = UUID(), date = Date(timeIntervalSince1970: 100)
        let valid = try packet(sequence: 7, commandID: 0xa6, payload: Data([0xab, 0x00, 0xff]))
        let event = try #require(BluetoothCameraEventParser.parse(valid, sessionID: session,
            peripheralID: peer, receivedAt: date, receivedUptime: 4))
        #expect(event.sessionID == session && event.peripheralID == peer)
        #expect(event.sequence == 7 && event.commandID == 0xa6)
        #expect(event.payloadLength == 3 && event.payloadHex == "ab00ff")

        for invalid in [
            try packet(sequence: 8, source: 2),
            try packet(sequence: 9, destination: 1),
            try packet(sequence: 10, flags: 0x80),
            try packet(sequence: 11, commandSet: 1),
            try packet(sequence: 12, payload: Data(repeating: 0, count: BluetoothCameraEventRecorder.maximumPayloadBytes + 1))
        ] {
            #expect(BluetoothCameraEventParser.parse(invalid, sessionID: session,
                peripheralID: peer, receivedAt: date, receivedUptime: 5) == nil)
        }
    }

    @Test func recorderBindsToPairedIdentityAndDeduplicatesSequenceAndFrame() throws {
        let session = UUID(), peer = UUID(), other = UUID()
        var recorder = try BluetoothCameraEventRecorder(sessionID: session,
            peripheralID: peer, startedUptime: 10, baselineSequence: 40)
        let first = try packet(sequence: 41, payload: Data([1, 2]))
        let accepted = recorder.receive(first, characteristic: "FFF4", sessionID: session,
            peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 10.1)
        let duplicate = recorder.receive(first, characteristic: "FFF4", sessionID: session,
            peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 10.2)
        let replay = recorder.receive(try packet(sequence: 40), characteristic: "FFF4",
            sessionID: session, peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 10.3)
        let wrongSession = recorder.receive(try packet(sequence: 42), characteristic: "FFF4",
            sessionID: other, peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 10.4)
        let unpaired = recorder.receive(try packet(sequence: 42), characteristic: "FFF4",
            sessionID: session, peripheralID: peer, paired: false, hostReceivedAt: Date(), uptime: 10.4)
        let wrongChannel = recorder.receive(try packet(sequence: 42), characteristic: "OTHER",
            sessionID: session, peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 10.4)
        #expect(accepted && !duplicate && !replay && !wrongSession && !unpaired && !wrongChannel)
        #expect(recorder.result.acceptedSampleCount == 1)
        #expect(recorder.result.events.first?.payloadHex == "0102")
    }

    @Test func sequenceAdmissionSupportsNormalWrapWithoutReplays() throws {
        let session = UUID(), peer = UUID()
        var recorder = try BluetoothCameraEventRecorder(sessionID: session,
            peripheralID: peer, startedUptime: 1, baselineSequence: 0xfffe)
        let beforeWrap = recorder.receive(try packet(sequence: 0xffff), sessionID: session,
            peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 1.1)
        let afterWrap = recorder.receive(try packet(sequence: 0), sessionID: session,
            peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 1.2)
        let duplicate = recorder.receive(try packet(sequence: 0), sessionID: session,
            peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 1.3)
        let replay = recorder.receive(try packet(sequence: 0xff00), sessionID: session,
            peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 1.4)
        #expect(beforeWrap && afterWrap && !duplicate && !replay)
        #expect(recorder.result.acceptedSampleCount == 2)
    }

    @Test func independentCommandStreamsCannotRejectEachOthersSequences() throws {
        let session = UUID(), peer = UUID()
        var recorder = try BluetoothCameraEventRecorder(sessionID: session,
            peripheralID: peer, startedUptime: 1)
        let status = recorder.receive(try packet(sequence: 900, commandID: 0x80),
            sessionID: session, peripheralID: peer, paired: true,
            hostReceivedAt: Date(), uptime: 1.1)
        let storage = recorder.receive(try packet(sequence: 40, commandID: 0xDC),
            sessionID: session, peripheralID: peer, paired: true,
            hostReceivedAt: Date(), uptime: 1.2)
        let nextStatus = recorder.receive(try packet(sequence: 901, commandID: 0x80),
            sessionID: session, peripheralID: peer, paired: true,
            hostReceivedAt: Date(), uptime: 1.3)
        #expect(status && storage && nextStatus)
        #expect(recorder.result.events.map(\.commandID) == [0x80, 0xDC, 0x80])
    }

    @Test func durationAndSampleBoundsCloseTheWindow() throws {
        let session = UUID(), peer = UUID()
        var timed = try BluetoothCameraEventRecorder(sessionID: session,
            peripheralID: peer, startedUptime: 2)
        let inWindow = timed.receive(try packet(sequence: 1), sessionID: session,
            peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 2.1)
        let afterWindow = timed.receive(try packet(sequence: 2), sessionID: session,
            peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 22.1)
        #expect(inWindow && !afterWindow)
        #expect(timed.result.end == .windowElapsed)
        #expect(timed.result.finishedUptime == 22)
        #expect(timed.result.events.count == 1)

        var capped = try BluetoothCameraEventRecorder(sessionID: session,
            peripheralID: peer, startedUptime: 0)
        for index in 0..<BluetoothCameraEventRecorder.maximumSamples {
            let accepted = capped.receive(try packet(sequence: UInt16(index + 1)), sessionID: session,
                peripheralID: peer, paired: true, hostReceivedAt: Date(),
                uptime: 0.001 + Double(index) * 0.001)
            #expect(accepted)
        }
        #expect(capped.result.end == .sampleLimit)
        #expect(capped.result.events.count == BluetoothCameraEventRecorder.maximumSamples)
        let beyondLimit = capped.receive(try packet(sequence: 513), sessionID: session,
            peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 1)
        #expect(!beyondLimit)
    }

    @Test func cancellationAndInvalidClockAreExplicitAndDoNotPersistPayloads() throws {
        let session = UUID(), peer = UUID()
        var recorder = try BluetoothCameraEventRecorder(sessionID: session,
            peripheralID: peer, startedUptime: 5)
        let result = recorder.finish(at: 6, reason: .cancelled, failureCode: String(repeating: "x", count: 300))
        #expect(result.end == .cancelled && result.failureCode?.count == 128)
        let afterCancel = recorder.receive(try packet(sequence: 1), sessionID: session,
            peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 7)
        #expect(!afterCancel)
        #expect(result.events.isEmpty)

        var invalid = try BluetoothCameraEventRecorder(sessionID: session,
            peripheralID: peer, startedUptime: 5)
        let backwards = invalid.receive(try packet(sequence: 1), sessionID: session,
            peripheralID: peer, paired: true, hostReceivedAt: Date(), uptime: 4)
        #expect(!backwards)
        #expect(invalid.result.end == .invalidClock)
    }

    @Test func requestRequiresExactlyTheCurrentSessionAndPeer() throws {
        let session = UUID(), peer = UUID()
        let request = try BluetoothCameraEventRecordingRequest(cliArguments: [
            "--session", session.uuidString.lowercased(), "--peripheral", peer.uuidString])
        #expect(request.expectedSessionID == session && request.peripheralID == peer)
        #expect(try BluetoothCameraEventRecordingRequest(arguments: request.arguments) == request)
        for options in [
            ["--session", session.uuidString],
            ["--session", session.uuidString, "--peripheral", peer.uuidString, "--seconds", "30"],
            ["--session", "not-a-uuid", "--peripheral", peer.uuidString],
            ["--session", session.uuidString, "--session", session.uuidString, "--peripheral", peer.uuidString]
        ] {
            #expect(throws: BridgeFailure.self) { try BluetoothCameraEventRecordingRequest(cliArguments: options) }
        }
        var extra = request.arguments
        if case .object(var fields) = extra {
            fields["payload"] = .string("should-not-be-accepted")
            extra = .object(fields)
        }
        #expect(throws: BridgeFailure.self) { try BluetoothCameraEventRecordingRequest(arguments: extra) }
        #expect(IPCClient.timeoutSeconds(for: BluetoothCameraEventRecordingRequest.operation) == 120)
        #expect(IPCClient.timeoutSeconds(for: "status") == 20)
        #expect(IPCClient.timeoutSeconds(for: "cancel-request") == 2)
    }
}
