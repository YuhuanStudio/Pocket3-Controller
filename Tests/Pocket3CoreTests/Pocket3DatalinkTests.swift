import Foundation
import Testing
@testable import Pocket3Core

private final class FakePocket3Wire: Pocket3DatalinkIO, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1000
    private var opened = false
    private var session: UInt16?
    private var receiveSequence: UInt16 = 0x4000
    private var lastTransmit: UInt16 = 0x3000
    private var incoming: [Data] = []
    private var commands: [DUMLFrame] = []
    private var traffic: [Data] = []
    private var tcpStarted = false
    private var telemetryEnabled = true
    let stallTCP: Bool
    let correlateHeartbeat: Bool
    init(stallTCP: Bool = false, correlateHeartbeat: Bool = true) {
        self.stallTCP = stallTCP; self.correlateHeartbeat = correlateHeartbeat
    }
    var now: TimeInterval { lock.withLock { time } }
    var isOpen: Bool { lock.withLock { opened } }
    var beganTCP: Bool { lock.withLock { tcpStarted } }
    var sentCommands: [DUMLFrame] { lock.withLock { commands } }
    var sentPackets: [Data] { lock.withLock { traffic } }
    func advance(_ duration: TimeInterval) { lock.withLock { time += duration } }
    func stopTelemetry() { lock.withLock { telemetryEnabled = false } }
    func tcpPoke(_ frame: Data, permit: OperationPermit) throws {
        try permit.perform { lock.withLock { tcpStarted = true } }
        _ = try DUMLCodec.decode(frame)
        while stallTCP { try permit.perform {}; Thread.sleep(forTimeInterval: 0.001) }
        lock.withLock { time += 0.4 }
    }
    func openUDP() throws { lock.withLock { opened = true; session = nil; incoming = []; receiveSequence = 0x4000; lastTransmit = 0x3000 } }
    func send(_ packet: Data) throws {
        try lock.withLock {
            guard opened else { throw BridgeFailure("fake_closed", "Fake transport is closed") }
            let b = Array(packet.prefix(8))
            guard b.count == 8 else { throw DJIUDPFramingError.invalidSize }
            let id = UInt16(b[2]) | UInt16(b[3]) << 8
            let datagram = try DJIUDPFraming.decode(packet, expectedSessionID: id)
            traffic.append(packet)
            if datagram.header.packetType == .handshake {
                session = id
                incoming.append(try DJIUDPFraming.encode(packetType: .handshake, payload: Data([0, 0x30]), sessionID: id, sequence: 0))
            } else if datagram.header.packetType == .command {
                lastTransmit = datagram.header.sequence
                let command = try DJIUDPFraming.routedCommand(in: datagram).frame
                commands.append(command)
                if command.commandSet == 4 && command.commandID == 0x50 {
                    let response = DUMLFrame(source: 4, destination: 2, sequence: correlateHeartbeat ? command.sequence : command.sequence &+ 1,
                        flags: 0x80, commandSet: 4, commandID: 0x50, payload: Data([0]))
                    incoming.append(try controlPacket(response, sessionID: id))
                } else if command.commandSet == 4 && command.commandID == 0x4c {
                    incoming.append(try controlPacket(DUMLFrame(source: 4, destination: 2, sequence: command.sequence,
                        flags: 0x80, commandSet: 4, commandID: 0x4c, payload: Data([0, 0])), sessionID: id))
                }
            }
        }
    }
    private func controlPacket(_ frame: DUMLFrame, sessionID: UInt16) throws -> Data {
        receiveSequence &+= 8
        var payload = DJIUDPFraming.routingHeader(peerAcknowledgment: 0x3000, sequence: receiveSequence, commandCounter: 0)
        payload.append(try DUMLCodec.encode(frame))
        return try DJIUDPFraming.encode(packetType: .channel3, payload: payload, sessionID: sessionID, sequence: receiveSequence)
    }
    func receive(timeoutMS: Int) throws -> [Data] {
        try lock.withLock {
            guard opened else { return [] }
            time += max(0.001, Double(timeoutMS) / 1000)
            guard let session else { return [] }
            var status = [UInt8](repeating: 0, count: 26)
            status[1] = 0x30
            status[16] = UInt8(lastTransmit & 0xff); status[17] = UInt8(lastTransmit >> 8)
            incoming.append(try DJIUDPFraming.encode(packetType: .status, payload: Data(status), sessionID: session, sequence: 0))
            if telemetryEnabled {
                incoming.append(try controlPacket(DUMLFrame(source: 4, destination: 2, sequence: receiveSequence,
                    flags: 0, commandSet: 4, commandID: 5, payload: Data([8, 7, 0, 0, 0, 0])), sessionID: session))
            }
            let values = incoming; incoming = []; return values
        }
    }
    func close() { lock.withLock { opened = false; incoming = [] } }
}

private final class RecordingPocket3LiveViewSink: @unchecked Sendable,
    Pocket3DatalinkLiveViewSink {
    private let lock = NSLock()
    private var attached: [UInt64] = []
    private var received: [UInt64] = []
    private var flushed: [UInt64] = []

    var attachGenerations: [UInt64] { lock.withLock { attached } }
    var receivedGenerations: [UInt64] { lock.withLock { received } }
    var flushGenerations: [UInt64] { lock.withLock { flushed } }

    func attach(generation: UInt64) {
        lock.withLock { attached.append(generation) }
    }

    func receive(_: DJIUDPDatagram, generation: UInt64) {
        lock.withLock { received.append(generation) }
    }

    func flush(generation: UInt64) {
        lock.withLock { flushed.append(generation) }
    }
}

@Suite("Explicit Pocket 3 native datalink with fake I/O") struct Pocket3DatalinkTests {
    private func hex(_ string: String) -> Data {
        let c = Array(string)
        return Data(stride(from: 0, to: c.count, by: 2).map { UInt8(String(c[$0...($0 + 1)]), radix: 16)! })
    }
    private func make(_ wire: FakePocket3Wire) -> Pocket3Datalink { Pocket3Datalink(io: wire, clientIdentifier: "pocket3-test-client", pairedDeviceID: "synthetic-paired-camera") }

    @Test func frozenConstantsMatchPinnedBytesAndNoConstructionOpensIO() async throws {
        #expect(Pocket3DatalinkProtocol.appPresence == hex("170046237c415050000000000002"))
        #expect(Pocket3DatalinkProtocol.appPresence.count == 14)
        #expect(Pocket3DatalinkProtocol.heartbeat == hex("010405"))
        #expect(Pocket3DatalinkProtocol.initialization == hex("05ffffffff"))
        #expect(Pocket3DatalinkProtocol.handshake(baseSequence: 0x1234) == hex("341264006400c005140000640000019001c005140000640014006400c00514000064000101040102"))
        #expect(Pocket3DatalinkProtocol.appDeviceInfo == hex("0041505000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000020800000000000000000000"))
        #expect(Pocket3DatalinkProtocol.appDeviceInfo.count == 62)
        let pairing = try DUMLCodec.decode(Pocket3DatalinkProtocol.pairingFrame(clientIdentifier: "test"))
        #expect(pairing.source == 2 && pairing.destination == 7 && pairing.sequence == 0x8092 && pairing.flags == 0x40)
        #expect(pairing.commandSet == 7 && pairing.commandID == 0x45 && pairing.payload == hex("0474657374046f736d6f"))
        let wire = FakePocket3Wire(), link = make(wire)
        #expect(await link.status().phase == .idle)
        #expect(!wire.isOpen && !wire.beganTCP && wire.sentPackets.isEmpty)
    }

    @Test func explicitConnectRequiresRepliesAndRegistersInOrderWithoutStartingMotion() async throws {
        let wire = FakePocket3Wire(), link = make(wire)
        let binding = try await link.connect()
        let status = await link.status()
        #expect(status.phase == .ready && status.binding == binding)
        #expect(status.lastHeartbeatAge != nil && status.lastTelemetryAge != nil)
        #expect(status.telemetry?.pitchDegrees == 180)
        let commands = wire.sentCommands
        #expect(commands.prefix(4).map { [Int($0.commandSet), Int($0.commandID)] } == [[0, 0x81], [0, 0x88], [3, 0xda], [4, 0x50]])
        #expect(commands[0].destination == 0x48 && commands[0].flags == 0x80)
        #expect(commands[1].destination == 0x28 && commands[1].payload == Pocket3DatalinkProtocol.appPresence)
        #expect(!commands.contains { $0.commandSet == 4 && $0.commandID == 1 })
        let closed = await link.disconnect()
        #expect(closed.neutralSent && !wire.isOpen)
        #expect(wire.sentCommands.last?.payload == DUMLJoystickCommand.neutral.payload)
        #expect(await link.status().binding == nil)
    }

    @Test func unrelatedHeartbeatCannotMarkTheConnectionReady() async throws {
        let wire = FakePocket3Wire(correlateHeartbeat: false), link = make(wire)
        do { _ = try await link.connect(); Issue.record("Uncorrelated reply admitted native movement") } catch {}
        let status = await link.status()
        #expect(status.phase == .error && status.binding == nil && status.unmatchedHeartbeatReplies > 0)
        #expect(!wire.isOpen)
    }

    @Test func invalidPermitAndOldBindingsNeverReachTheWire() async throws {
        let wire = FakePocket3Wire(), link = make(wire), command = try DUMLJoystickCommand.encode(x: 1, y: 0, speed: 0.2)
        let binding = try await link.connect(), lease = ContinuousGimbalLease(id: UUID(), binding: binding)
        let invalid = OperationPermit(); invalid.invalidate()
        let before = wire.sentCommands.count
        do { try await link.send(command, lease: lease, permit: invalid); Issue.record("Invalid permit reached sender") } catch {}
        #expect(wire.sentCommands.count == before)
        _ = await link.disconnect()
        let next = try await link.connect()
        #expect(next != binding)
        let beforeStale = wire.sentCommands.count
        do { try await link.send(command, lease: lease, permit: OperationPermit()); Issue.record("Old lease redirected to new socket") } catch {}
        #expect(wire.sentCommands.count == beforeStale)
        _ = await link.disconnect()
    }

    @Test func inputTransportPumps04Slash01AndReleasesWithCenterNeutral() async throws {
        let wire = FakePocket3Wire(), link = make(wire)
        let binding = try await link.connect()
        let lease = ContinuousGimbalLease(id: UUID(), binding: binding)
        let input = try ContinuousGimbalInput(x: 1, y: 0, speed: 1)
        try await link.send(input, lease: lease, permit: OperationPermit())
        let beforeStop = wire.sentCommands.count
        try await link.stop(lease: lease, permit: OperationPermit())
        let commands = wire.sentCommands
        #expect(commands.count == beforeStop + 1)
        #expect(commands[beforeStop].commandSet == 0x04 &&
                commands[beforeStop].commandID == 0x01)
        #expect(commands[beforeStop].flags == 0)
        #expect(commands[beforeStop].payload == DUMLJoystickCommand.neutral.payload)
        #expect(commands[beforeStop].payload.count == 10)
        #expect(!commands[beforeStop...].contains {
            $0.commandSet == 0x04 && $0.commandID == 0x14
        })
        _ = await link.disconnect()
    }

    @Test func globalNeutralRetiresOldLeaseAndStaleTelemetryDisarmsMotion() async throws {
        let wire = FakePocket3Wire(), link = make(wire), command = try DUMLJoystickCommand.encode(x: 1, y: 0, speed: 0.2)
        let binding = try await link.connect(), first = ContinuousGimbalLease(id: UUID(), binding: binding)
        try await link.send(command, lease: first, permit: OperationPermit())
        try await link.neutral(binding: binding, permit: OperationPermit())
        let count = wire.sentCommands.count
        do { try await link.send(command, lease: first, permit: OperationPermit()); Issue.record("Retired gesture resumed") } catch {}
        #expect(wire.sentCommands.count == count)
        let second = ContinuousGimbalLease(id: UUID(), binding: binding)
        try await link.send(command, lease: second, permit: OperationPermit())
        let beforeStaleDisarm = wire.sentCommands.count
        wire.stopTelemetry(); wire.advance(1)
        do { try await link.send(command, lease: second, permit: OperationPermit()); Issue.record("Stale telemetry drove motion") } catch {}
        #expect(await link.status().phase == .disarmed)
        #expect(wire.sentCommands.dropFirst(beforeStaleDisarm).contains {
            $0.commandSet == 4 && $0.commandID == 1 && $0.payload == DUMLJoystickCommand.neutral.payload
        })
        _ = await link.disconnect()
    }

    @Test func nativeActionsReportAcceptanceWithoutPhysicalCompletionClaims() async throws {
        let wire = FakePocket3Wire(), link = make(wire)
        let binding = try await link.connect()
        let recenter = try await link.recenter(binding: binding, permit: OperationPermit())
        let flip = try await link.flip(binding: binding, permit: OperationPermit())
        #expect(recenter.requestAccepted && !recenter.physicalCompletionVerified && recenter.command == "recenter")
        #expect(flip.requestAccepted && !flip.physicalCompletionVerified && flip.command == "flip")
        let actions = wire.sentCommands.filter { $0.commandSet == 4 && $0.commandID == 0x4c }
        #expect(actions.map(\.payload) == [Data([0xfe, 8]), Data([0xfe, 9])])
        _ = await link.disconnect()
    }

    @Test func cancellationDuringTCPBootstrapReleasesTheReservedBinding() async throws {
        let wire = FakePocket3Wire(stallTCP: true), link = make(wire)
        let connect = Task { try await link.connect() }
        for _ in 0..<100 { if wire.beganTCP { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(wire.beganTCP)
        connect.cancel()
        do { _ = try await connect.value; Issue.record("Cancelled connect completed") } catch {}
        #expect(await link.status().binding == nil)
        #expect(!wire.isOpen && wire.sentPackets.isEmpty)
        _ = await link.disconnect()
    }

    @Test func cancellationBeforeQueueEntryReleasesBindingWithoutOpeningIO() async throws {
        let queue = DispatchQueue(label: "Pocket3DatalinkTests.suspended-owner")
        queue.suspend()
        var suspended = true
        defer { if suspended { queue.resume() } }
        let wire = FakePocket3Wire()
        let link = Pocket3Datalink(io: wire, clientIdentifier: "test", queue: queue)
        let connect = Task { try await link.connect() }
        for _ in 0..<100 { if await link.status().phase == .connecting { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await link.status().binding != nil)
        connect.cancel()
        suspended = false; queue.resume()
        do { _ = try await connect.value; Issue.record("Early-cancelled connect completed") } catch {}
        #expect(await link.status().binding == nil)
        #expect(!wire.beganTCP && !wire.isOpen && wire.sentPackets.isEmpty)
    }

    @Test func rejectedQueueAdmissionReleasesBindingWithoutOpeningIO() async throws {
        let wire = FakePocket3Wire()
        let link = Pocket3Datalink(io: wire, clientIdentifier: "test", maximumQueuedOperations: 0)
        do { _ = try await link.connect(); Issue.record("Zero-capacity work queue accepted connect") } catch {}
        #expect(await link.status().binding == nil)
        #expect(!wire.beganTCP && !wire.isOpen && wire.sentPackets.isEmpty)
    }

    @Test func compatibilityExtractionNeverReadsVideoOrNestedPayloadAsControl() throws {
        let inner = DUMLFrame(source: 4, destination: 2, sequence: 1, flags: 0x80, commandSet: 4, commandID: 0x50, payload: Data([0]))
        let outer = DUMLFrame(source: 4, destination: 2, sequence: 2, flags: 0, commandSet: 0x7f, commandID: 0x7f, payload: try DUMLCodec.encode(inner))
        for type in [DJIUDPPacketType.video, .channel3] {
            let datagram = try DJIUDPFraming.decode(DJIUDPFraming.encode(packetType: type, payload: DUMLCodec.encode(outer), sessionID: 1, sequence: 8), expectedSessionID: 1)
            let frames = Pocket3DatalinkProtocol.controlFrames(in: datagram)
            #expect(frames == (type == .video ? [] : [outer]))
        }
    }

    @Test func optionalLiveViewSinkIsPassiveAndGenerationFenced() async throws {
        let wire = FakePocket3Wire(), link = make(wire)
        let binding = try await link.connect()
        let sink = RecordingPocket3LiveViewSink()
        let before = wire.sentCommands.count
        let token = link.attachLiveViewSink(sink, binding: binding)

        #expect(link.hasLiveViewSink)
        #expect(sink.attachGenerations == [binding.generation])
        #expect(wire.sentCommands.count == before)
        #expect(!wire.sentCommands.contains {
            $0.commandSet == 9 && $0.commandID == 0xa8
        })

        link.detachLiveViewSink(Pocket3DatalinkLiveViewSinkToken(
            generation: binding.generation + 1))
        #expect(sink.flushGenerations.isEmpty)
        #expect(link.hasLiveViewSink)
        link.detachLiveViewSink(token)
        #expect(sink.flushGenerations == [binding.generation])
        #expect(!link.hasLiveViewSink)

        _ = await link.disconnect()
        #expect(sink.flushGenerations == [binding.generation])
    }
}
