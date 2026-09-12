import Foundation
import Testing
@testable import Pocket3Core

private final class NativeCommandFakeWire: Pocket3DatalinkIO, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1000
    private var opened = false
    private var session: UInt16?
    private var receiveSequence: UInt16 = 0x4000
    private var lastTransmit: UInt16 = 0x3000
    private var incoming: [Data] = []
    private var commands: [DUMLFrame] = []
    private var telemetryEnabled = true

    let responseCommand: (set: UInt8, id: UInt8)?
    let responsePayload: Data
    let responseFlags: UInt8
    let responseSequenceOffset: UInt16
    let receiveDelay: TimeInterval
    let terminalRecordingStatus: UInt8?

    init(responseCommand: (set: UInt8, id: UInt8)? = nil,
         responsePayload: Data = Data([0]), responseFlags: UInt8 = 0x80,
         responseSequenceOffset: UInt16 = 0, receiveDelay: TimeInterval = 0,
         terminalRecordingStatus: UInt8? = nil) {
        self.responseCommand = responseCommand; self.responsePayload = responsePayload
        self.responseFlags = responseFlags; self.responseSequenceOffset = responseSequenceOffset
        self.receiveDelay = receiveDelay; self.terminalRecordingStatus = terminalRecordingStatus
    }

    var now: TimeInterval { lock.withLock { time } }
    var isOpen: Bool { lock.withLock { opened } }
    var sentCommands: [DUMLFrame] { lock.withLock { commands } }
    func commandCount(set: UInt8, id: UInt8) -> Int {
        lock.withLock { commands.count { $0.commandSet == set && $0.commandID == id } }
    }
    var responseCommandCount: Int {
        lock.withLock {
            commands.filter { command in
                guard let responseCommand else { return false }
                guard command.commandSet == responseCommand.set && command.commandID == responseCommand.id else { return false }
                // `04/50` is also the heartbeat command used by connect and
                // maintenance; count only the explicit gimbal GET here.
                if responseCommand.set == 4 && responseCommand.id == 0x50 {
                    return command.payload != Pocket3DatalinkProtocol.heartbeat
                }
                return true
            }.count
        }
    }

    func tcpPoke(_ frame: Data, permit: OperationPermit) throws {
        try permit.perform { _ = try DUMLCodec.decode(frame) }
        lock.withLock { time += 0.4 }
    }

    func openUDP() throws {
        lock.withLock {
            opened = true; session = nil; incoming = []
            receiveSequence = 0x4000; lastTransmit = 0x3000
        }
    }

    func send(_ packet: Data) throws {
        try lock.withLock {
            guard opened else { throw BridgeFailure("fake_closed", "Fake transport is closed") }
            let header = Array(packet.prefix(8))
            guard header.count == 8 else { throw DJIUDPFramingError.invalidSize }
            let sessionID = UInt16(header[2]) | UInt16(header[3]) << 8
            let datagram = try DJIUDPFraming.decode(packet, expectedSessionID: sessionID)
            if datagram.header.packetType == .handshake {
                session = sessionID
                incoming.append(try DJIUDPFraming.encode(packetType: .handshake,
                    payload: Data([0, 0x30]), sessionID: sessionID, sequence: 0))
            } else if datagram.header.packetType == .command {
                lastTransmit = datagram.header.sequence
                let command = try DJIUDPFraming.routedCommand(in: datagram).frame
                commands.append(command)
                if let responseCommand,
                   command.commandSet == responseCommand.set,
                   command.commandID == responseCommand.id {
                    let response = DUMLFrame(source: command.destination,
                        destination: command.source,
                        sequence: command.sequence &+ responseSequenceOffset,
                        flags: responseFlags, commandSet: command.commandSet,
                        commandID: command.commandID, payload: responsePayload)
                    incoming.append(try controlPacket(response, sessionID: sessionID))
                    if command.commandSet == 2, command.commandID == 2,
                       let terminalRecordingStatus {
                        let status = DUMLFrame(source: 1, destination: 2,
                            sequence: command.sequence &+ 1, flags: 0,
                            commandSet: 2, commandID: 0x80,
                            payload: Data([terminalRecordingStatus]))
                        incoming.append(try controlPacket(status, sessionID: sessionID))
                    }
                } else if command.commandSet == 4 && command.commandID == 0x50,
                          command.payload == Pocket3DatalinkProtocol.heartbeat {
                    let response = DUMLFrame(source: 4, destination: 2,
                        sequence: command.sequence, flags: 0x80, commandSet: 4,
                        commandID: 0x50, payload: Data([0]))
                    incoming.append(try controlPacket(response, sessionID: sessionID))
                } else if command.commandSet == 4 && command.commandID == 0x4c {
                    let response = DUMLFrame(source: 4, destination: 2,
                        sequence: command.sequence, flags: 0x80, commandSet: 4,
                        commandID: 0x4c, payload: Data([0, 0]))
                    incoming.append(try controlPacket(response, sessionID: sessionID))
                }
            }
        }
    }

    private func controlPacket(_ frame: DUMLFrame, sessionID: UInt16) throws -> Data {
        receiveSequence &+= 8
        var payload = DJIUDPFraming.routingHeader(peerAcknowledgment: 0x3000,
            sequence: receiveSequence, commandCounter: 0)
        payload.append(try DUMLCodec.encode(frame))
        return try DJIUDPFraming.encode(packetType: .channel3, payload: payload,
            sessionID: sessionID, sequence: receiveSequence)
    }

    func receive(timeoutMS: Int) throws -> [Data] {
        if receiveDelay > 0 { Thread.sleep(forTimeInterval: receiveDelay) }
        return try lock.withLock {
            guard opened else { return [] }
            time += max(0.001, Double(timeoutMS) / 1000) + max(0, receiveDelay)
            guard let session else { return [] }
            var status = [UInt8](repeating: 0, count: 26)
            status[1] = 0x30
            status[16] = UInt8(lastTransmit & 0xff); status[17] = UInt8(lastTransmit >> 8)
            incoming.append(try DJIUDPFraming.encode(packetType: .status,
                payload: Data(status), sessionID: session, sequence: 0))
            if telemetryEnabled {
                incoming.append(try controlPacket(DUMLFrame(source: 4, destination: 2,
                    sequence: receiveSequence, flags: 0, commandSet: 4, commandID: 5,
                    payload: Data([8, 7, 0, 0, 0, 0])), sessionID: session))
            }
            let values = incoming; incoming = []; return values
        }
    }

    func close() { lock.withLock { opened = false; incoming = [] } }
}

@Suite("Native command transactions") struct NativeCommandTransactionTests {
    private func readySession() -> NativeCameraSessionStatus {
        var session = NativeCameraSession()
        let generation = session.begin(sessionID: UUID(), peerID: UUID())
        _ = session.markPaired(generation: generation)
        _ = session.markCredentialsAvailable(generation: generation)
        _ = session.observeDatalink(.connecting, generation: generation)
        _ = session.observeDatalink(.ready, generation: generation)
        return session.status
    }

    private func make(_ wire: NativeCommandFakeWire) -> Pocket3Datalink {
        Pocket3Datalink(io: wire, clientIdentifier: "native-command-test",
            pairedDeviceID: "synthetic-paired-camera")
    }

    private func eventually(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func gimbalReadUsesOneOwnerSequenceAndReportsObservedEvidence() async throws {
        let payload = Data([0, 1, 4, 1, 0, 5, 1, 1])
        let wire = NativeCommandFakeWire(responseCommand: (4, 0x50), responsePayload: payload)
        let link = make(wire)
        _ = try await link.connect()
        let commandsBeforeTransaction = wire.sentCommands.count
        let gimbalCommandsBeforeTransaction = wire.commandCount(set: 4, id: 0x50)
        let readiness = readySession()
        let request = try Pocket3NativeCommandAdapter.readGimbalParameters(
            generation: readiness.generation)

        let result = try await link.transact(request, readiness: readiness)
        let matchingCommands = wire.sentCommands.dropFirst(commandsBeforeTransaction).filter {
            $0.commandSet == 4 && $0.commandID == 0x50 && $0.sequence == result.sequence
        }
        guard let command = matchingCommands.last else {
            Issue.record("The transaction did not emit one matching gimbal command")
            _ = await link.disconnect()
            return
        }
        #expect(result.requested && result.submitted && result.responseReceived)
        #expect(result.acknowledged && result.observed && result.end == .observed)
        #expect(result.observedPayload == payload)
        #expect(result.sequence == command.sequence)
        #expect(wire.commandCount(set: 4, id: 0x50) == gimbalCommandsBeforeTransaction + 1)
        #expect(await link.status().phase == .ready)
        _ = await link.disconnect()
    }

    @Test func bodyFormatCandidateSendsOnceButDoesNotClaimReadback() async throws {
        let wire = NativeCommandFakeWire(responseCommand: (2, 0x18), responsePayload: Data([0]))
        let link = make(wire)
        _ = try await link.connect()
        let matchingBeforeTransaction = wire.responseCommandCount
        let readiness = readySession()
        let command = CameraBodyRecordingFormatCommand(resolution: .p1080, frameRate: .fps30)
        let request = try Pocket3NativeCommandAdapter.bodyRecordingFormatCandidate(command,
            generation: readiness.generation)

        let result = try await link.transact(request, readiness: readiness)
        #expect(result.requested && result.submitted && result.acknowledged)
        #expect(!result.observed && result.end == .acknowledged)
        #expect(wire.responseCommandCount == matchingBeforeTransaction + 1)
        #expect(wire.sentCommands.last?.commandSet == 2 && wire.sentCommands.last?.commandID == 0x18)
        _ = await link.disconnect()
    }

    @Test func mismatchedAckTimesOutWithoutRetry() async throws {
        let wire = NativeCommandFakeWire(responseCommand: (2, 0x18),
            responsePayload: Data([0]), responseSequenceOffset: 1)
        let link = make(wire)
        _ = try await link.connect()
        let readiness = readySession()
        let bodyCommand = CameraBodyRecordingFormatCommand(resolution: .p1080, frameRate: .fps30)
        let request = try Pocket3NativeCommandAdapter.bodyRecordingFormatCandidate(
            bodyCommand, generation: readiness.generation, timeout: 0.05)

        let result = try await link.transact(request, readiness: readiness)
        #expect(result.requested && result.submitted)
        #expect(!result.responseReceived && !result.acknowledged && !result.observed)
        #expect(result.end == .timedOut && result.failureCode == "native_command_timeout")
        #expect(wire.responseCommandCount == 1)
        _ = await link.disconnect()
    }

    @Test func commandReadyAndGenerationGatesRejectBeforeAnyWireSend() async throws {
        let wire = NativeCommandFakeWire(responseCommand: (4, 0x50), responsePayload: Data([0]))
        let link = make(wire)
        let binding = try await link.connect()
        let matchingBeforeGates = wire.responseCommandCount
        var session = NativeCameraSession()
        let generation = session.begin()
        _ = session.markPaired(generation: generation)
        _ = session.markCredentialsAvailable(generation: generation)
        let notReady = session.status
        let request = try Pocket3NativeCommandAdapter.readGimbalParameters(generation: generation)

        await #expect(throws: NativeCommandTransactionError.commandNotReady) {
            try await link.transact(request, readiness: notReady)
        }
        #expect(wire.responseCommandCount == matchingBeforeGates)

        let newer = session.begin()
        let staleReadiness = session.status
        let staleRequest = try NativeCommandTransactionRequest(command: .gimbal,
            generation: generation, frame: request.frame, timeout: 0.1)
        #expect(staleReadiness.generation == newer)
        await #expect(throws: NativeCommandTransactionError.staleGeneration) {
            try await link.transact(staleRequest, readiness: staleReadiness)
        }
        #expect(wire.responseCommandCount == matchingBeforeGates)
        _ = await link.disconnect()
        _ = binding
    }

    @Test func cancellationAfterSubmissionReturnsCancelledEvidenceAndNoRetry() async throws {
        let wire = NativeCommandFakeWire(responseCommand: nil, receiveDelay: 0.01)
        let link = make(wire)
        _ = try await link.connect()
        let readiness = readySession()
        let bodyCommand = CameraBodyRecordingFormatCommand(resolution: .p1080, frameRate: .fps30)
        let request = try Pocket3NativeCommandAdapter.bodyRecordingFormatCandidate(
            bodyCommand, generation: readiness.generation, timeout: 2)
        let task = Task { try await link.transact(request, readiness: readiness) }
        try await eventually { wire.commandCount(set: 2, id: 0x18) == 1 }
        task.cancel()
        let result = try await task.value
        #expect(result.requested && result.submitted)
        #expect(!result.acknowledged && !result.observed && result.end == .cancelled)
        #expect(wire.commandCount(set: 2, id: 0x18) == 1)
        _ = await link.disconnect()
    }

    @Test func disconnectFencesAnInFlightTransactionAsGenerationChanged() async throws {
        let wire = NativeCommandFakeWire(responseCommand: nil, receiveDelay: 0.01)
        let link = make(wire)
        _ = try await link.connect()
        let readiness = readySession()
        let bodyCommand = CameraBodyRecordingFormatCommand(resolution: .p1080, frameRate: .fps30)
        let request = try Pocket3NativeCommandAdapter.bodyRecordingFormatCandidate(
            bodyCommand, generation: readiness.generation, timeout: 2)
        let task = Task { try await link.transact(request, readiness: readiness) }
        try await eventually { wire.commandCount(set: 2, id: 0x18) == 1 }
        _ = await link.disconnect()
        let result = try await task.value
        #expect(result.requested && result.submitted)
        #expect(result.end == .generationChanged)
        #expect(wire.commandCount(set: 2, id: 0x18) == 1)
    }

    @Test func continuousGimbalLeaseBlocksCandidateWithoutTakingOwnership() async throws {
        let wire = NativeCommandFakeWire(responseCommand: (4, 0x50), responsePayload: Data([0]))
        let link = make(wire)
        let binding = try await link.connect()
        let lease = ContinuousGimbalLease(id: UUID(), binding: binding)
        let joystick = try DUMLJoystickCommand.encode(x: 1, y: 0, speed: 0.2)
        try await link.send(joystick, lease: lease, permit: OperationPermit())
        let readiness = readySession()
        let request = try Pocket3NativeCommandAdapter.readGimbalParameters(
            generation: readiness.generation)
        let before = wire.responseCommandCount
        let result = try await link.transact(request, readiness: readiness)
        #expect(result.end == .failed && result.failureCode == "native_busy")
        #expect(wire.responseCommandCount == before)
        _ = await link.disconnect()
    }

    @Test func bodyRecordCoordinatorCompletesOnlyAfterMatchingTerminalStatus() async throws {
        let wire = NativeCommandFakeWire(responseCommand: (2, 2),
            responsePayload: Data([0]), terminalRecordingStatus: 0x81)
        let link = make(wire)
        _ = try await link.connect()
        let readiness = readySession()
        var coordinator = try NativeBodyRecordingCoordinator(session: readiness)
        let baseline = NativeBodyRecordingLifecycleSample(
            sessionID: readiness.sessionID!, generation: readiness.generation,
            receivedUptime: wire.now, statusByte: 0x01)
        let request = try coordinator.prepareRecord(.start, baseline: baseline,
            nowUptime: wire.now)

        let transaction = try await link.transact(request, readiness: readiness)
        let completed = coordinator.apply(transaction, nowUptime: wire.now)
        #expect(completed)
        #expect(transaction.submitted && transaction.acknowledged)
        #expect(transaction.observed && transaction.end == .observed)
        #expect(coordinator.result?.completed == true)
        #expect(coordinator.result?.lifecycle?.status.lifecycle == .recording)
        #expect(wire.commandCount(set: 2, id: 2) == 1)
        _ = await link.disconnect()
    }
}
