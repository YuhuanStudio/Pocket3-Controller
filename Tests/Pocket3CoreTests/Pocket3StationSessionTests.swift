import Foundation
import Testing
@testable import Pocket3Core

private actor StationTrace {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor FakeStationBLE: Pocket3StationBLEExecutor {
    let trace: StationTrace
    private var rejectLeave: Bool
    private var sent: [Pocket3StationBLECommand] = []

    init(trace: StationTrace, rejectLeave: Bool = false) {
        self.trace = trace
        self.rejectLeave = rejectLeave
    }

    func setRejectLeave(_ value: Bool) { rejectLeave = value }

    func send(_ command: Pocket3StationBLECommand,
              binding: Pocket3StationSessionBinding) async throws
        -> Pocket3StationBLEReply {
        sent.append(command)
        await trace.append(command.operation.rawValue)
        let payload: Data
        switch command.operation {
        case .networkModeProbe: payload = Data([0xE0])
        case .enterStationMode: payload = Data([0x00])
        case .joinNetwork: payload = Data([0x00, 0x00])
        case .leaveStationMode:
            payload = rejectLeave ? Data([0xE1]) : Data([0x00])
        }
        return Pocket3StationBLEReply(
            operation: command.operation, sequence: command.frame.sequence,
            payload: payload)
    }

    func revalidate(_ binding: Pocket3StationSessionBinding) async throws
        -> Pocket3StationSessionBinding {
        await trace.append("ble_revalidate")
        return binding
    }

    func commands() -> [Pocket3StationBLECommand] { sent }
}

private struct FakeStationClock: Pocket3StationClock {
    let trace: StationTrace
    func sleep(for duration: TimeInterval) async throws {
        await trace.append("sleep:\(Int(duration))")
    }
}

private actor FakeStationLAN: Pocket3StationLANExecutor {
    let trace: StationTrace
    let identity: Pocket3StationIdentity
    let identityValidated: Bool
    let retainOwner: Bool

    init(trace: StationTrace, identity: Pocket3StationIdentity,
         identityValidated: Bool = true, retainOwner: Bool = true) {
        self.trace = trace
        self.identity = identity
        self.identityValidated = identityValidated
        self.retainOwner = retainOwner
    }

    func discoverAndConnect(
        host: String?, binding: Pocket3StationSessionBinding,
        expectedIdentity: Pocket3StationIdentity
    ) async throws -> Pocket3StationLANEvidence {
        await trace.append("lan_discover")
        return try Pocket3StationLANEvidence(
            host: host ?? "192.168.50.44", tcp7001Connected: true,
            udp9004Connected: true, identity: identity,
            identityRaw: identity.raw,
            datalinkOwnerRetained: retainOwner,
            identityReplyValidated: identityValidated)
    }

    func close(_ evidence: Pocket3StationLANEvidence,
               binding: Pocket3StationSessionBinding) async {
        await trace.append("lan_close")
    }
}

@Suite("Pocket 3 station session")
struct Pocket3StationSessionTests {
    private func identity(_ byte: UInt8 = 0x31) throws
        -> Pocket3StationIdentity {
        try Pocket3StationIdentity(raw: Data([0, byte, 2, 3]), source: "07/07")
    }

    private func binding(identity: Pocket3StationIdentity) throws
        -> Pocket3StationSessionBinding {
        try Pocket3StationSessionBinding(
            bleSessionID: UUID(), peripheralID: UUID(), generation: 1,
            bleIdentity: identity)
    }

    @Test func protocolUsesCapturedPocket3PacketsAndCredentialBounds() throws {
        let credentials = try Pocket3StationCredentials(
            ssid: "Studio", password: "correct horse battery staple")
        let probe = Pocket3StationProtocol.networkModeProbe(sequence: 1)
        let enter = Pocket3StationProtocol.enterStationMode(sequence: 2)
        let join = Pocket3StationProtocol.joinNetwork(
            credentials: credentials, sequence: 3)
        let leave = Pocket3StationProtocol.leaveStationMode(sequence: 4)
        #expect(probe.frame.commandSet == 7 && probe.frame.commandID == 0x39)
        #expect(probe.frame.payload == Data([0]))
        #expect(enter.frame.commandID == 0x48 && enter.frame.payload == Data([1]))
        #expect(leave.frame.commandID == 0x48 && leave.frame.payload == Data([0]))
        #expect(join.frame.commandID == 0x47)
        #expect(join.frame.payload.first == 6)
        #expect(join.frame.payload.range(of: Data("Studio".utf8)) != nil)
        #expect(Pocket3StationProtocol.settleSeconds == 10)
        #expect(throws: Pocket3StationSessionError.invalidCredentials) {
            try Pocket3StationCredentials(
                ssid: String(repeating: "s", count: 33), password: "password")
        }
        #expect(throws: Pocket3StationSessionError.invalidCredentials) {
            try Pocket3StationCredentials(
                ssid: "Studio", password: String(repeating: "p", count: 64))
        }
    }

    @Test func stationIdentityUsesPackedCameraSSIDDigestWithoutLeakingSSID() throws {
        let payload = Data([0, 6]) + Data("Studio".utf8)
        let identity = try #require(
            Pocket3StationProtocol.cameraSSIDIdentity(from: payload))
        let expected = try Pocket3StationIdentity(cameraSSID: "Studio")
        #expect(identity == expected)
        #expect(identity.raw.count == 32)
        #expect(identity.raw != Data("Studio".utf8))
        #expect(Pocket3StationProtocol.cameraSSIDIdentity(
            from: Data([0, 6]) + Data("Stud".utf8)) == nil)
        #expect(Pocket3StationProtocol.cameraSSIDIdentity(
            from: Data([1, 6]) + Data("Studio".utf8)) == nil)
        #expect(Pocket3StationProtocol.cameraSSIDIdentity(
            from: Data([0, 6]) + Data("Studio".utf8) + Data([0])) == nil)
        #expect(Pocket3StationProtocol.cameraSSIDIdentity(
            from: Data([0, 2, 0x41, 0x0A])) == nil)
    }

    @Test func commandReadyRequiresCapturedOrderIdentityAndRetainedOwner() async throws {
        let trace = StationTrace()
        let expected = try identity()
        let binding = try binding(identity: expected)
        let ble = FakeStationBLE(trace: trace)
        let lan = FakeStationLAN(trace: trace, identity: expected)
        let coordinator = Pocket3StationSessionCoordinator(
            binding: binding, ble: ble, lan: lan,
            clock: FakeStationClock(trace: trace),
            debtStore: Pocket3StationInMemoryCleanupDebtStore())
        let result = await coordinator.start(
            credentials: try Pocket3StationCredentials(
                ssid: "Studio", password: "password"))
        #expect(result.phase == .commandReady)
        #expect(result.commandReady)
        #expect(result.automaticWiFiAssociation == false)
        #expect(result.credentialsPersisted == false)
        #expect(await trace.snapshot() == [
            "07/39_probe", "07/48_enter", "sleep:10", "07/47_join",
            "lan_discover"
        ])
        let commands = await ble.commands()
        #expect(commands.map(\.operation) == [
            .networkModeProbe, .enterStationMode, .joinNetwork
        ])
    }

    @Test func LANIdentityOrOwnerMismatchFailsAndRestoresAP() async throws {
        let trace = StationTrace()
        let expected = try identity()
        let coordinator = Pocket3StationSessionCoordinator(
            binding: try binding(identity: expected),
            ble: FakeStationBLE(trace: trace),
            lan: FakeStationLAN(trace: trace, identity: try identity(0x32)),
            clock: FakeStationClock(trace: trace),
            debtStore: Pocket3StationInMemoryCleanupDebtStore())
        let result = await coordinator.start(
            credentials: try Pocket3StationCredentials(
                ssid: "Studio", password: "password"))
        #expect(result.phase == .failed)
        #expect(!result.commandReady)
        #expect(result.cleanupDebt == nil)
        #expect(result.steps.last?.operation == .leaveStationMode)
        #expect(result.steps.last?.accepted == true)
        #expect(await trace.snapshot().suffix(3) == [
            "lan_close", "ble_revalidate", "07/48_leave"
        ])

        let trace2 = StationTrace()
        let ownerless = Pocket3StationSessionCoordinator(
            binding: try binding(identity: expected),
            ble: FakeStationBLE(trace: trace2),
            lan: FakeStationLAN(
                trace: trace2, identity: expected, retainOwner: false),
            clock: FakeStationClock(trace: trace2),
            debtStore: Pocket3StationInMemoryCleanupDebtStore())
        let ownerlessResult = await ownerless.start(
            credentials: try Pocket3StationCredentials(
                ssid: "Studio", password: "password"))
        #expect(!ownerlessResult.commandReady)
        #expect(ownerlessResult.phase == .failed)
    }

    @Test func failedAPRestorePersistsCredentialFreeDebtAndRetriesOnlyCleanup()
        async throws {
        let trace = StationTrace()
        let expected = try identity()
        let binding = try binding(identity: expected)
        let store = Pocket3StationInMemoryCleanupDebtStore()
        let ble = FakeStationBLE(trace: trace, rejectLeave: true)
        let coordinator = Pocket3StationSessionCoordinator(
            binding: binding, ble: ble,
            lan: FakeStationLAN(
                trace: trace, identity: expected, identityValidated: false),
            clock: FakeStationClock(trace: trace), debtStore: store)
        let failed = await coordinator.start(
            credentials: try Pocket3StationCredentials(
                ssid: "Studio", password: "never-persist-this"))
        #expect(failed.phase == .cleanupDebt)
        #expect(failed.cleanupDebt?.retryRequired == true)
        #expect(await store.load() != nil)

        await ble.setRejectLeave(false)
        let retry = await coordinator.retryCleanup()
        #expect(retry.phase == .idle)
        #expect(retry.cleanupDebt == nil)
        #expect(await store.load() == nil)
        let operations = (await ble.commands()).map(\.operation)
        #expect(operations.suffix(2) == [.leaveStationMode, .leaveStationMode])
        #expect(operations.filter { $0 == .joinNetwork }.count == 1)
    }

    @Test func validationContractCannotCarryNetworkCredentials() throws {
        let request = try Pocket3StationValidationRequest(
            expectedSessionID: UUID(), expectedPeripheralID: UUID(),
            generation: 1)
        let json = try JSONEncoder().encode(request)
        let text = String(decoding: json, as: UTF8.self)
        #expect(!text.localizedCaseInsensitiveContains("ssid"))
        #expect(!text.localizedCaseInsensitiveContains("password"))
        #expect(Pocket3StationValidationRequest.schema["properties"]["ssid"] == .null)
        #expect(Pocket3StationValidationRequest.schema["properties"]["password"] == .null)
        let plan = Pocket3StationValidationService.dryRun(request)
        #expect(plan.steps[3] == "bounded station settle")
        #expect(plan.steps[4].hasPrefix("07/47"))
        #expect(!plan.automaticWiFiAssociation && !plan.credentialsPersisted)
    }
}
