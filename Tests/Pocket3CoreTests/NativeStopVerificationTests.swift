import Foundation
import Testing
@testable import Pocket3Core

@Suite("Native stop telemetry reducer") struct NativeStopTelemetryVerifierTests {
    private func sample(_ time: Double, pitch: Double = 0, roll: Double = 0, yaw: Double = 0) -> Pocket3DatalinkTelemetry {
        .init(pitchDegrees: pitch, rollDegrees: roll, yawDegrees: yaw, receivedAt: Date(timeIntervalSince1970: time))
    }
    @Test func needsThreeDistinctPostNeutralSamplesAcrossTwoHundredMilliseconds() {
        var verifier = NativeStopTelemetryVerifier(neutralSentUptime: 1000)
        for (index, time) in [1000.01, 1000.11].enumerated() {
            verifier.receive(sample(time), receivedUptime: time, packetSequence: UInt16(index + 1), messageSequence: 1, now: time)
        }
        #expect(!verifier.isStable(now: 1000.11))
        verifier.receive(sample(1000.21), receivedUptime: 1000.21, packetSequence: 3, messageSequence: 1, now: 1000.21)
        #expect(verifier.isStable(now: 1000.21))
        #expect(verifier.sampleCount == 3 && verifier.stableDurationSeconds >= 0.199999)
        #expect(!verifier.isStable(now: 1001))
    }
    @Test func duplicatePacketsSnapshotReadsAndInvalidReceiveTimesCannotManufactureEvidence() {
        var verifier = NativeStopTelemetryVerifier(neutralSentUptime: 1000)
        verifier.receive(sample(1000.01), receivedUptime: 1000.01, packetSequence: 1, messageSequence: 1, now: 1000.01)
        verifier.receive(sample(1000.11), receivedUptime: 1000.11, packetSequence: 1, messageSequence: 1, now: 1000.11)
        verifier.receive(sample(1000.01), receivedUptime: 1000.21, packetSequence: 2, messageSequence: 2, now: 1000.21)
        verifier.receive(sample(1000.31), receivedUptime: 1000.01, packetSequence: 3, messageSequence: 3, now: 1000.31)
        for (timestamp, now) in [(1000.0, 1000.1), (999.9, 1000.1), (1000.1, 1000.9), (1000.5, 1000.4), (Double.nan, 1000.5)] {
            verifier.receive(sample(timestamp), receivedUptime: timestamp, packetSequence: 4, messageSequence: 4, now: now)
        }
        #expect(verifier.sampleCount == 1)
        #expect(!verifier.isStable(now: 1000.31))
    }
    @Test func explicitPreCommandPurposeAcceptsLaterBaselineButDefaultStopDoesNot() {
        var baseline = NativeStopTelemetryVerifier(referenceUptime: 1000, purpose: .preCommandBaseline)
        var stop = NativeStopTelemetryVerifier(neutralSentUptime: 1000)
        for (index, time) in [1001.4, 1001.65, 1001.9].enumerated() {
            let identity = NativeStopReceiveIdentity.bluetooth(source: 4, messageSequence: UInt16(index + 1))
            baseline.receive(sample(time), receivedUptime: time, identity: identity, now: time)
            stop.receive(sample(time), receivedUptime: time, identity: identity, now: time)
        }
        #expect(baseline.sampleCount == 3 && baseline.stableDurationSeconds >= 0.5)
        #expect(baseline.isStable(now: 1001.9))
        #expect(stop.sampleCount == 1 && !stop.isStable(now: 1001.9))
        #expect(NativeStopTelemetryVerifier.maximumDuration == 1.5)
    }
    @Test func preCommandPurposeStillRejectsSamplesAfterThreeSeconds() {
        var baseline = NativeStopTelemetryVerifier(referenceUptime: 1000, purpose: .preCommandBaseline)
        for (index, time) in [1002.5, 1002.75, 1003.001].enumerated() {
            baseline.receive(sample(time), receivedUptime: time,
                identity: .bluetooth(source: 4, messageSequence: UInt16(index + 1)), now: time)
        }
        #expect(baseline.sampleCount == 2 && baseline.finalTelemetry?.receivedAt == sample(1002.75).receivedAt)
        #expect(!baseline.isStable(now: 1003.001))
    }
    @Test func allAxisTotalSpanRejectsSmallCumulativeStepsThenAcceptsSettling() {
        for axis in 0..<3 {
            var verifier = NativeStopTelemetryVerifier(neutralSentUptime: 1000)
            for index in 0..<3 {
                let time = 1000.01 + Double(index) * 0.1, angle = Double(index) * 0.2
                verifier.receive(sample(time, pitch: axis == 0 ? angle : 0, roll: axis == 1 ? angle : 0, yaw: axis == 2 ? angle : 0),
                    receivedUptime: time, packetSequence: UInt16(index + 1), messageSequence: 1, now: time)
            }
            #expect(!verifier.isStable(now: 1000.21)) // Each step was <0.25°, cumulative span was 0.4°.
            for index in 3..<5 {
                let time = 1000.01 + Double(index) * 0.1
                verifier.receive(sample(time, pitch: axis == 0 ? 0.4 : 0, roll: axis == 1 ? 0.4 : 0, yaw: axis == 2 ? 0.4 : 0),
                    receivedUptime: time, packetSequence: UInt16(index + 1), messageSequence: 1, now: time)
            }
            #expect(verifier.isStable(now: 1000.41))
        }
    }
    @Test func wrapBoundaryAndLostSampleGapsAreHandled() {
        var wrap = NativeStopTelemetryVerifier(neutralSentUptime: 1000)
        for (index, yaw) in [179.9, -180, -179.9].enumerated() {
            let time = 1000.01 + Double(index) * 0.1
            wrap.receive(sample(time, yaw: yaw), receivedUptime: time, packetSequence: UInt16(index + 1), messageSequence: 1, now: time)
        }
        #expect(wrap.isStable(now: 1000.21))
        var gaps = NativeStopTelemetryVerifier(neutralSentUptime: 1000)
        for (index, time) in [1000.01, 1000.51, 1001.01].enumerated() {
            gaps.receive(sample(time), receivedUptime: time, packetSequence: UInt16(index + 1), messageSequence: 1, now: time)
        }
        #expect(!gaps.isStable(now: 1001.01))
    }
    @Test func packetSequenceAdmissionRejectsReplayAndReorderingAcrossWrap() {
        var admission = NativeTelemetrySequenceAdmission()
        func check(_ type: DJIUDPPacketType, _ sequence: UInt16, expected: Bool) {
            let accepted = admission.accept(type: type, sequence: sequence)
            #expect(accepted == expected)
        }
        check(.channel3, 0, expected: false)
        check(.channel3, 0xfff8, expected: true)
        check(.channel3, 0xfff8, expected: false)
        check(.channel3, 0, expected: true)
        check(.channel3, 0xfff0, expected: false)
        check(.channel3, 8, expected: true)
        check(.channel3, 0x8008, expected: false)
        check(.video, 16, expected: false)
        check(.command, 100, expected: true)
        check(.command, 92, expected: false)
    }
}

private final class StopVerificationWire: Pocket3DatalinkIO, @unchecked Sendable {
    enum Mode { case stationary, moving, missing, replay, failNeutral }
    private let lock = NSLock()
    private var clock: TimeInterval = 1000
    private var opened = false
    private var session: UInt16?
    private var rx: UInt16 = 0x4000
    private var lastTransmit: UInt16 = 0x3000
    private var inbox: [Data] = []
    private var poseHistory: [Data] = []
    private var neutralCount = 0
    private var movingAngle: Int16 = 0
    private var acknowledgeCount = 0
    let mode: Mode
    let delayAfterNeutral: TimeInterval
    init(mode: Mode = .stationary, delayAfterNeutral: TimeInterval = 0) {
        self.mode = mode; self.delayAfterNeutral = delayAfterNeutral
    }
    var now: TimeInterval { lock.withLock { clock } }
    var isOpen: Bool { lock.withLock { opened } }
    var hasNeutral: Bool { lock.withLock { neutralCount > 0 } }
    var neutrals: Int { lock.withLock { neutralCount } }
    var acknowledgments: Int { lock.withLock { acknowledgeCount } }
    func tcpPoke(_ frame: Data, permit: OperationPermit) throws { try permit.perform {}; _ = try DUMLCodec.decode(frame) }
    func openUDP() throws { lock.withLock { opened = true; session = nil; poseHistory = []; inbox = [] } }
    func close() { lock.withLock { opened = false; inbox = [] } }
    private func control(_ frame: DUMLFrame, session: UInt16) throws -> Data {
        rx &+= 8
        var payload = DJIUDPFraming.routingHeader(peerAcknowledgment: 0x3000, sequence: rx, commandCounter: 0)
        payload.append(try DUMLCodec.encode(frame))
        return try DJIUDPFraming.encode(packetType: .channel3, payload: payload, sessionID: session, sequence: rx)
    }
    func send(_ packet: Data) throws {
        try lock.withLock {
            let b = Array(packet.prefix(8)); guard b.count == 8 else { throw DJIUDPFramingError.invalidSize }
            let id = UInt16(b[2]) | UInt16(b[3]) << 8
            let datagram = try DJIUDPFraming.decode(packet, expectedSessionID: id)
            if datagram.header.packetType == .handshake {
                session = id; inbox.append(try DJIUDPFraming.encode(packetType: .handshake, payload: Data([0, 0x30]), sessionID: id, sequence: 0))
            } else if datagram.header.packetType == .acknowledgment { acknowledgeCount += 1 }
            else if datagram.header.packetType == .command {
                let command = try DJIUDPFraming.routedCommand(in: datagram).frame
                if command.commandSet == 4 && command.commandID == 1 && command.payload == DUMLJoystickCommand.neutral.payload {
                    if mode == .failNeutral { throw BridgeFailure("fake_neutral_send_failed", "Synthetic neutral failure") }
                    neutralCount += 1
                }
                lastTransmit = datagram.header.sequence
                if command.commandSet == 4 && command.commandID == 0x50 {
                    inbox.append(try control(DUMLFrame(source: 4, destination: 2, sequence: command.sequence, flags: 0x80,
                        commandSet: 4, commandID: 0x50, payload: Data([0])), session: id))
                }
            }
        }
    }
    func receive(timeoutMS: Int) throws -> [Data] {
        if hasNeutral && delayAfterNeutral > 0 { Thread.sleep(forTimeInterval: delayAfterNeutral) }
        return try lock.withLock {
            clock += max(0.001, Double(timeoutMS) / 1000)
            guard opened, let session else { return [] }
            var status = [UInt8](repeating: 0, count: 26); status[1] = 0x30
            status[16] = UInt8(lastTransmit & 0xff); status[17] = UInt8(lastTransmit >> 8)
            inbox.append(try DJIUDPFraming.encode(packetType: .status, payload: Data(status), sessionID: session, sequence: 0))
            if neutralCount > 0 && mode == .replay {
                inbox.append(contentsOf: poseHistory.reversed()) // Old valid CRC packets, including duplicates and older sequences.
            } else if neutralCount == 0 || mode != .missing {
                if neutralCount > 0 && mode == .moving { movingAngle &+= 4 }
                let yaw = UInt16(bitPattern: movingAngle)
                let pose = try control(DUMLFrame(source: 4, destination: 2, sequence: rx, flags: 0, commandSet: 4, commandID: 5,
                    payload: Data([8, 7, 0, 0, UInt8(yaw & 0xff), UInt8(yaw >> 8)])), session: session)
                inbox.append(pose); poseHistory.append(pose)
                if poseHistory.count > 3 { poseHistory.removeFirst() }
            }
            let values = inbox; inbox = []; return values
        }
    }
}

@Suite("Native neutral and fresh telemetry verification with fake I/O") struct NativeStopDatalinkTests {
    private func link(_ wire: StopVerificationWire, queue: DispatchQueue? = nil) -> Pocket3Datalink {
        Pocket3Datalink(io: wire, clientIdentifier: "stop-verification-test", queue: queue)
    }
    @Test func stableResultUsesPostNeutralInboundTelemetry() async throws {
        let wire = StopVerificationWire(), link = link(wire)
        let binding = try await link.connect()
        let result = await link.neutralAndVerify(binding: binding)
        #expect(result.neutralSent && result.stableTelemetry && !result.timedOut)
        #expect(result.sampleCount >= 3 && result.stableDurationSeconds >= 0.199999)
        #expect(result.elapsedSeconds <= 1.55 && result.finalTelemetry?.pitchDegrees == 180)
        #expect(result.maximumSpanDegrees == 0)
        #expect(await link.status().lastStop?.stableTelemetry == true)
        _ = await link.disconnect()
    }
    @Test func replayedMovingOrMissingPosesNeverVerifyStopping() async throws {
        for mode in [StopVerificationWire.Mode.replay, .moving, .missing] {
            let wire = StopVerificationWire(mode: mode), link = link(wire)
            let binding = try await link.connect()
            let ackBefore = wire.acknowledgments
            let result = await link.neutralAndVerify(binding: binding)
            #expect(result.neutralSent && !result.stableTelemetry && result.timedOut)
            #expect(result.elapsedSeconds <= 1.55)
            if mode == .replay {
                #expect(result.sampleCount == 0)
                let status = await link.status()
                #expect(status.replayedOrReorderedControlDatagrams > 0)
                #expect((status.lastTelemetryAge ?? 0) >= 1.5)
                #expect(wire.acknowledgments > ackBefore)
            }
            _ = await link.disconnect()
        }
    }
    @Test func aFailedNeutralIsDifferentFromTelemetryTimeout() async throws {
        let wire = StopVerificationWire(mode: .failNeutral), link = link(wire)
        let binding = try await link.connect()
        let result = await link.neutralAndVerify(binding: binding)
        #expect(!result.neutralSent && !result.stableTelemetry && !result.timedOut)
        #expect(result.failure == "fake_neutral_send_failed")
        #expect(await link.status().phase == .disarmed)
        _ = await link.disconnect()
    }
    @Test func callerCancellationBeforeEntryCannotPreventSafetyNeutral() async throws {
        let queue = DispatchQueue(label: "NativeStopTests.before-entry")
        let wire = StopVerificationWire(), link = link(wire, queue: queue)
        let binding = try await link.connect()
        queue.suspend()
        var suspended = true
        defer { if suspended { queue.resume() } }
        let invalidPermit = OperationPermit(); invalidPermit.invalidate()
        let stop = Task { await link.neutralAndVerify(binding: binding, permit: invalidPermit) }
        stop.cancel()
        suspended = false; queue.resume()
        let result = await stop.value
        #expect(result.neutralSent && wire.hasNeutral)
        _ = await link.disconnect()
    }
    @Test func callerCancellationWhileWaitingCannotCancelNeutralCleanup() async throws {
        let wire = StopVerificationWire(delayAfterNeutral: 0.005), link = link(wire)
        let binding = try await link.connect()
        let stop = Task { await link.neutralAndVerify(binding: binding) }
        for _ in 0..<100 { if wire.hasNeutral { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(wire.hasNeutral)
        stop.cancel()
        let result = await stop.value
        #expect(result.neutralSent && result.elapsedSeconds <= 1.55)
        _ = await link.disconnect()
    }
    @Test func aNewGestureSupersedesVerificationBeforeItsWrite() async throws {
        let wire = StopVerificationWire(delayAfterNeutral: 0.01), link = link(wire)
        let binding = try await link.connect()
        let stop = Task { await link.neutralAndVerify(binding: binding) }
        for _ in 0..<100 { if wire.hasNeutral { break }; try await Task.sleep(for: .milliseconds(2)) }
        let lease = ContinuousGimbalLease(id: UUID(), binding: binding)
        let command = try DUMLJoystickCommand.encode(x: 1, y: 0, speed: 0.1)
        let movement = Task { try await link.send(command, lease: lease, permit: OperationPermit()) }
        let result = await stop.value
        #expect(result.neutralSent && !result.stableTelemetry && result.replacedByNewMotion)
        #expect(!result.timedOut && !result.connectionChanged)
        try await movement.value
        _ = await link.disconnect()
    }
    @Test func disconnectInvalidatesEvidenceForTheOldConnection() async throws {
        let wire = StopVerificationWire(delayAfterNeutral: 0.01), link = link(wire)
        let binding = try await link.connect()
        let stop = Task { await link.neutralAndVerify(binding: binding) }
        for _ in 0..<100 { if wire.hasNeutral { break }; try await Task.sleep(for: .milliseconds(2)) }
        let disconnect = Task { await link.disconnect() }
        let result = await stop.value
        #expect(!result.stableTelemetry && result.connectionChanged)
        _ = await disconnect.value
        #expect(await link.status().binding == nil)
    }
}
