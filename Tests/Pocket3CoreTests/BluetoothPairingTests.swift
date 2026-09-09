import Foundation
import Testing
@testable import Pocket3Core

@Suite struct BluetoothPairingTests {
    private let identifier = "0123456789abcdef0123456789abcdef"
    private func started() throws -> (BluetoothPairingSession, DUMLFrame) {
        var session = try BluetoothPairingSession(clientIdentifier: identifier, initialSequence: 0x802b)
        _ = session.armSucceeded()
        let request = try session.pairingRequest()
        return (session, try #require(request))
    }
    private func reply(_ request: DUMLFrame, payload: Data, sequence: UInt16? = nil) -> DUMLFrame {
        DUMLFrame(source: request.destination, destination: request.source, sequence: sequence ?? request.sequence,
            flags: 0xc0, commandSet: request.commandSet, commandID: request.commandID, payload: payload)
    }
    private func packed(_ value: String) -> Data { Data([0, UInt8(value.utf8.count)]) + Data(value.utf8) }

    @Test func wakeMatchesFrozenProtocolVectorAndPairingUsesTheSuppliedIdentifier() throws {
        var session = try BluetoothPairingSession(clientIdentifier: identifier, initialSequence: 0x802b)
        let wake = session.armSucceeded()
        let actual = try DUMLCodec.encode(try #require(wake))
        // Existing Kaze DUML fixture, revision 341a35de18493ff61f97c93b8b10161a7512aa36.
        let frozen = Data([0x55, 0x0f, 0x04, 0xa2, 0x02, 0xf0, 0x2b, 0x80, 0x40, 0x00, 0x2b, 0x04, 0x00, 0x24, 0x40])
        #expect(actual == frozen)
        let requestValue = try session.pairingRequest()
        let request = try #require(requestValue)
        #expect(request.source == 2 && request.destination == 7 && request.flags == 0x40)
        #expect(request.commandSet == 7 && request.commandID == 0x45 && request.sequence == 0x802c)
        #expect(request.payload == Data([32]) + Data(identifier.utf8) + Data([4]) + Data("osmo".utf8))
        #expect(try DUMLCodec.encode(request).prefix(4) == Data([0x55, 0x33, 0x04, 0xc2]))
        for invalid in ["", "short", String(repeating: "z", count: 32)] {
            #expect(throws: BridgeFailure.self) {
                try BluetoothPairingSession(clientIdentifier: invalid, initialSequence: 1)
            }
        }
    }

    @Test func cameraApprovalIsExplicitAndCredentialsAreNotRequestedEarly() throws {
        var (session, request) = try started()
        let early = session.credentialRequests()
        #expect(early.isEmpty)
        let pending = session.receive(reply(request, payload: Data([0, 2])))
        #expect(!pending.confirmedPairing && session.phase == .awaitingApproval && !session.paired)
        let approval = DUMLFrame(source: 7, destination: 2, sequence: 0x1234, flags: 0x40,
            commandSet: 7, commandID: 0x46)
        let confirmed = session.receive(approval)
        #expect(confirmed.confirmedPairing && session.paired)
        #expect(confirmed.acknowledgment?.sequence == approval.sequence)
        #expect(confirmed.acknowledgment?.flags == 0xc0)
        let commands = session.credentialRequests()
        #expect(commands.map { $0.delay } == [0.1, 0.9, 1.4])
        #expect(commands.map { $0.frame.commandID } == [0x10, 7, 0x0e])
        #expect(commands[0].frame.commandSet == 0x53 && commands[0].frame.destination == 0x1c)
        let duplicated = session.credentialRequests()
        #expect(duplicated.isEmpty)
    }

    @Test func pairOnlyKeepsBluetoothWithoutWakingWiFiOrRequestingCredentials() throws {
        var session = try BluetoothPairingSession(clientIdentifier: identifier, initialSequence: 0x8010, pairOnly: true)
        _ = session.armSucceeded()
        let requestValue = try session.pairingRequest()
        let request = try #require(requestValue)
        _ = session.receive(reply(request, payload: Data([0, 1])))
        #expect(session.phase == .paired && session.paired && session.status.peerReportedPaired)
        let credentialWrites = session.credentialRequests()
        #expect(credentialWrites.isEmpty && !session.credentialsAvailable)
        let heartbeat = session.keepalive()
        #expect(heartbeat?.commandSet == 0 && heartbeat?.commandID == 0x2b)
        let sequences = session.reserveProbeSequences()
        #expect(sequences == [0x8013, 0x8014, 0x8015, 0x8016, 0x8017])
        let nextHeartbeat = session.keepalive()
        #expect(nextHeartbeat?.sequence == 0x8018)
    }

    @Test func wrongSequencesRoutingAndUnconfirmedCredentialRepliesAreIgnored() throws {
        var (session, request) = try started()
        let wrong = session.receive(reply(request, payload: Data([0, 1]), sequence: request.sequence &+ 1))
        #expect(!wrong.confirmedPairing && !session.paired)
        let wrongTarget = DUMLFrame(source: 7, destination: 3, sequence: request.sequence, flags: 0xc0,
            commandSet: 7, commandID: 0x45, payload: Data([0, 1]))
        _ = session.receive(wrongTarget)
        #expect(!session.paired)
        let unsolicited = DUMLFrame(source: 7, destination: 2, sequence: 1, flags: 0xc0,
            commandSet: 7, commandID: 0x0e, payload: packed("fixture-only-password"))
        let ignored = session.receive(unsolicited)
        #expect(ignored.credentials == nil && !session.credentialsAvailable)
    }

    @Test func correlatedCredentialsAreDeliveredOnceAndNeverAppearInStatusOrDebugText() throws {
        var (session, request) = try started()
        _ = session.receive(reply(request, payload: Data([0, 1])))
        let commands = session.credentialRequests()
        let ssidRequest = commands[1].frame, passwordRequest = commands[2].frame
        let password = "fixture-only-password", ssid = "fixture-camera"
        let old = session.receive(reply(passwordRequest, payload: packed(password), sequence: passwordRequest.sequence &+ 1))
        #expect(old.credentials == nil)
        let first = session.receive(reply(passwordRequest, payload: packed(password)))
        #expect(first.credentials == nil)
        let last = session.receive(reply(ssidRequest, payload: packed(ssid)))
        #expect(last.credentials?.ssid == ssid && last.credentials?.password == password)
        #expect(session.phase == .credentialsReady && session.credentialsAvailable)
        let duplicate = session.receive(reply(ssidRequest, payload: packed(ssid)))
        #expect(duplicate.credentials == nil)
        let statusJSON = try #require(String(data: JSONEncoder().encode(session.status), encoding: .utf8))
        #expect(!statusJSON.contains(password) && !statusJSON.contains(ssid))
        let value = BluetoothWiFiCredentials(ssid: ssid, password: password, sessionID: UUID(), peripheralID: UUID())
        #expect(!String(describing: value).contains(password))
        #expect(!String(reflecting: value).contains(ssid))
        let serializable = (value as Any) is any Encodable
        #expect(!serializable)
    }

    @Test func acknowledgmentsHaveRestrictedRoutingAndNeverBecomeMotorRequests() {
        let request = DUMLFrame(source: 0xf0, destination: 2, sequence: 10, flags: 0x40,
            commandSet: 0, commandID: 0x81, payload: Data([9]))
        let ack = BluetoothPairingCommands.acknowledgment(request)
        #expect(ack?.source == 2 && ack?.destination == 0xf0 && ack?.flags == 0xc0)
        #expect(ack?.payload.count == 62 && ack?.payload.prefix(4) == Data([0, 0x41, 0x50, 0x50]))
        for frame in [DUMLFrame(source: 7, destination: 3, sequence: 1, flags: 0x40, commandSet: 7, commandID: 0x46),
                      DUMLFrame(source: 7, destination: 2, sequence: 1, flags: 0xc0, commandSet: 7, commandID: 0x46),
                      DUMLFrame(source: 7, destination: 2, sequence: 1, flags: 0x40, commandSet: 4, commandID: 0x4c)] {
            #expect(BluetoothPairingCommands.acknowledgment(frame) == nil)
        }
    }

    @Test func observedCameraRegistrationEndpointReceivesOnlyTheRequiredAppReply() throws {
        // Header fields observed on firmware 01.06.10.04. The test payload is
        // synthetic; 00/81 replies carry the fixed APP record instead of echoing it.
        let input = DUMLFrame(source: 0x48, destination: 2, sequence: 35243, flags: 0x40,
            commandSet: 0, commandID: 0x81, payload: Data([0xaa]))
        let verified = try DUMLCodec.decode(DUMLCodec.encode(input))
        let value = BluetoothPairingCommands.acknowledgment(verified)
        let reply = try #require(value)
        #expect(reply.source == 2 && reply.destination == 0x48)
        #expect(reply.sequence == 35243 && reply.flags == 0xc0 && reply.commandSet == 0 && reply.commandID == 0x81)
        #expect(reply.payload == BluetoothPairingCommands.applicationInfo && reply.payload.count == 62)
        #expect(try DUMLCodec.decode(DUMLCodec.encode(reply)) == reply)
        for command in [UInt8(0x2b), 0x80, 0x82] {
            let other = DUMLFrame(source: 0x48, destination: 2, sequence: 1, flags: 0x40,
                commandSet: 0, commandID: command)
            #expect(BluetoothPairingCommands.acknowledgment(other) == nil)
        }
        let unknownSource = DUMLFrame(source: 0x49, destination: 2, sequence: 1, flags: 0x40,
            commandSet: 0, commandID: 0x81)
        #expect(BluetoothPairingCommands.acknowledgment(unknownSource) == nil)
    }

    @Test func credentialFailureDiagnosticsDistinguishStatusFromTruncationWithoutValues() throws {
        let samples: [(Data, BluetoothCredentialReplyClassification)] = [
            (Data(), .missingStatus), (Data([0]), .missingLength), (Data([1]), .statusFailure),
            (Data([0, 0]), .emptyValue), (Data([0, 5, 65]), .truncated),
            (Data([0, 33]) + Data(repeating: 65, count: 33), .lengthExceedsMaximum),
            (Data([0, 1, 0xff]), .invalidUTF8), (Data([0, 1, 0]), .controlCharacters)
        ]
        for (payload, expected) in samples {
            let result = BluetoothPairingCommands.inspectPackedString(payload, maximumBytes: 32)
            #expect(result.value == nil && result.diagnostic.classification == expected)
            #expect(result.diagnostic.payloadByteCount == payload.count)
        }
        let failed = BluetoothPairingCommands.inspectPackedString(Data([1]), maximumBytes: 32).diagnostic
        #expect(failed.statusSucceeded == false && !failed.hasLengthField && failed.declaredLengthFits == nil)
        let truncated = BluetoothPairingCommands.inspectPackedString(Data([0, 5, 65]), maximumBytes: 32).diagnostic
        #expect(truncated.statusSucceeded == true && truncated.hasLengthField)
        #expect(truncated.declaredLengthFits == false && truncated.declaredLengthAllowed == true)
        let secret = "fixture-private-value"
        let success = BluetoothPairingCommands.inspectPackedString(packed(secret), maximumBytes: 32)
        #expect(success.value == secret && success.diagnostic.classification == .accepted)
        let encoded = try JSONEncoder().encode(success.diagnostic)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains(secret) && !text.contains("payloadBytes") && !text.contains("declaredLength\":"))
    }

    @Test func credentialFailurePreservesPairConfirmationButRevokesLiveAccess() throws {
        var (session, request) = try started()
        _ = session.receive(reply(request, payload: Data([0, 1])))
        let commands = session.credentialRequests()
        _ = session.receive(reply(commands[1].frame, payload: Data([1])))
        #expect(session.phase == .failed && !session.paired && !session.credentialsAvailable)
        #expect(session.status.peerReportedPaired && session.status.credentialAccessFailed)
        #expect(session.status.ssidReply?.classification == .statusFailure)
        #expect(session.status.ssidReply?.payloadByteCount == 1)
        session.fail("bluetooth_ssid_reply_invalid") // Connection cleanup must preserve the evidence.
        #expect(session.status.peerReportedPaired && session.status.credentialAccessFailed)
        let noKeepalive = session.keepalive()
        #expect(noKeepalive == nil)
        let newAttempt = try BluetoothPairingSession(clientIdentifier: identifier, initialSequence: 2)
        #expect(!newAttempt.status.peerReportedPaired && !newAttempt.status.credentialAccessFailed)
    }

    @Test func bluetoothBatteryUsesTheObservedSource05Header() {
        // Header is from the live BLE trace; payload values are synthetic and
        // do not assert the actual camera's battery percentage.
        var payload = Data(repeating: 0, count: 33)
        payload[20] = 42; payload[32] = 1
        let observedHeader = DUMLFrame(source: 5, destination: 2, sequence: 1, flags: 0,
            commandSet: 0x0d, commandID: 2, payload: payload)
        let parsed = BluetoothBatteryTelemetryParser.parse(observedHeader, receivedAt: Date())
        #expect(parsed?.percent == 42 && parsed?.chargingState == .charging && parsed?.source == .bluetooth)
        let guessedSource = DUMLFrame(source: 0x0d, destination: 2, sequence: 1, flags: 0,
            commandSet: 0x0d, commandID: 2, payload: payload)
        #expect(BluetoothBatteryTelemetryParser.parse(guessedSource, receivedAt: Date()) == nil)
        let short = DUMLFrame(source: 5, destination: 2, sequence: 1, flags: 0,
            commandSet: 0x0d, commandID: 2, payload: Data([42]))
        #expect(BluetoothBatteryTelemetryParser.parse(short, receivedAt: Date()) == nil)
    }

    @Test func cancellationAndRejectedStatusesCannotResumePairing() throws {
        var (cancelled, request) = try started()
        cancelled.cancel()
        let late = cancelled.receive(reply(request, payload: Data([0, 1])))
        #expect(!late.confirmedPairing && late.acknowledgment == nil && !cancelled.paired)
        let keepalive = cancelled.keepalive()
        #expect(keepalive == nil)
        var (rejected, secondRequest) = try started()
        _ = rejected.receive(reply(secondRequest, payload: Data([1, 1])))
        #expect(rejected.phase == .failed && !rejected.paired)
        #expect(BluetoothPairingCommands.packedString(Data([0, 5, 65]), maximumBytes: 32) == nil)
        #expect(BluetoothPairingCommands.packedString(Data([1, 1, 65]), maximumBytes: 32) == nil)
        #expect(BluetoothPairingCommands.packedString(Data([0, 1, 0]), maximumBytes: 32) == nil)
    }
}

@Suite struct BluetoothWriteQueueTests {
    private func packet(_ sequence: UInt16, bytes: Int = 35) throws -> Data {
        try DUMLCodec.encode(DUMLFrame(source: 2, destination: 7, sequence: sequence, flags: 0x40,
            commandSet: 0, commandID: 0x2b, payload: Data(repeating: 0x11, count: bytes)))
    }
    @Test func mtuFragmentsStayOrderedAndAcceptNonzeroDataSliceIndices() throws {
        let first = try packet(1), second = try packet(2)
        let wrapped = Data([0, 0]) + first
        var queue = BluetoothWriteQueue()
        try queue.enqueue(wrapped.dropFirst(2), at: 1)
        try queue.enqueue(second, at: 1)
        var received = Data()
        while let fragment = try queue.nextFragment(maximumBytes: 20, at: 1.1) {
            #expect(fragment.count <= 20)
            received.append(fragment)
        }
        #expect(received == first + second && queue.byteCount == 0)
    }
    @Test func overflowCancellationAndDeadlineBoundOutstandingWrites() throws {
        var queue = BluetoothWriteQueue()
        let large = try packet(1, bytes: 1010)
        for _ in 0..<8 { try queue.enqueue(large, at: 1) }
        #expect(throws: BluetoothWriteQueueError.overflow) { try queue.enqueue(large, at: 1) }
        #expect(queue.byteCount <= BluetoothWriteQueue.maximumBytes)
        _ = try queue.nextFragment(maximumBytes: 20, at: 1.1)
        #expect(throws: BluetoothWriteQueueError.expired) { try queue.nextFragment(maximumBytes: 20, at: 6) }
        queue.reset()
        #expect(queue.isEmpty && queue.byteCount == 0)
        #expect(throws: BluetoothWriteQueueError.invalidMTU) { try queue.nextFragment(maximumBytes: 0, at: 1) }
        var corrupt = try packet(2); corrupt[3] ^= 1
        #expect(throws: DUMLCodecError.self) { try queue.enqueue(corrupt, at: 1) }
        #expect(queue.isEmpty)
    }

    @Test func registrationReplyIsNotMarkedCompleteUntilItsLastFragment() throws {
        let registration = DUMLFrame(source: 2, destination: 0x48, sequence: 35243, flags: 0xc0,
            commandSet: 0, commandID: 0x81, payload: BluetoothPairingCommands.applicationInfo)
        var queue = BluetoothWriteQueue()
        try queue.enqueue(DUMLCodec.encode(registration), at: 1)
        #expect(queue.completedFrame == nil)
        for _ in 0..<3 {
            _ = try queue.nextFragment(maximumBytes: 20, at: 1.1)
            #expect(queue.completedFrame == nil)
        }
        _ = try queue.nextFragment(maximumBytes: 20, at: 1.1)
        #expect(queue.completedFrame == registration && queue.isEmpty)
        _ = try queue.nextFragment(maximumBytes: 20, at: 1.2)
        #expect(queue.completedFrame == nil)
    }
}
