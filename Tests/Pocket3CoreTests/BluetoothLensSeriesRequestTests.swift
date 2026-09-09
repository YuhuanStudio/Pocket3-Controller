import Foundation
import Testing
@testable import Pocket3Core

@Suite struct BluetoothLensSeriesRequestTests {
    private let session = UUID(), peer = UUID()

    @Test func cliAndRPCShareExactExplicitUUIDContract() throws {
        let cli = try BluetoothLensSeriesRequest(cliArguments: ["--session", session.uuidString.lowercased(), "--peripheral", peer.uuidString])
        let reversed = try BluetoothLensSeriesRequest(cliArguments: ["--peripheral", peer.uuidString, "--session", session.uuidString])
        let rpc = try BluetoothLensSeriesRequest(arguments: cli.arguments)
        #expect(cli == reversed && cli == rpc && cli.expectedSessionID == session && cli.peripheralID == peer)
        #expect(BluetoothLensSeriesRequest.operation == "validation-wireless-lens-series")
        #expect(cli.arguments == .object(["expectedSessionID": .string(session.uuidString), "peripheralID": .string(peer.uuidString)]))
    }

    @Test func malformedOrMissingCLIOptionsCannotFallBackToCurrentPeer() {
        let invalid: [[String]] = [[], ["--session", session.uuidString],
            ["--session", session.uuidString, "--session", session.uuidString],
            ["--session", "ble:" + session.uuidString, "--peripheral", peer.uuidString],
            ["--session", "not-a-session", "--peripheral", peer.uuidString],
            ["--session", session.uuidString, "--peripheral", ""],
            ["--session", session.uuidString, "--seconds", "120"],
            ["--session", session.uuidString, "--peripheral", peer.uuidString, "--join-network"]]
        for options in invalid {
            #expect(throws: BridgeFailure.self) { try BluetoothLensSeriesRequest(cliArguments: options) }
        }
    }

    @Test func RPCRejectsAlternativePropertiesSettersAndWindowOverrides() {
        let valid: [String: JSONValue] = ["expectedSessionID": .string(session.uuidString), "peripheralID": .string(peer.uuidString)]
        for key in ["seconds", "property", "rawValue", "joinNetwork", "x", "y"] {
            var changed = valid; changed[key] = .number(1)
            #expect(throws: BridgeFailure.self) { try BluetoothLensSeriesRequest(arguments: .object(changed)) }
        }
        for input in [JSONValue.null, .array([]), .object([:]),
                      .object(["expectedSessionID": .number(1), "peripheralID": .string(peer.uuidString)]),
                      .object(["expectedSessionID": .string(session.uuidString), "peripheralID": .null])] {
            #expect(throws: BridgeFailure.self) { try BluetoothLensSeriesRequest(arguments: input) }
        }
    }

    @MainActor @Test func productionRecordingEntryDoesNotInitializeBluetooth() async {
        guard !CommandLine.arguments.contains("--hardware-validation") else { return }
        let discovery = Pocket3BluetoothDiscovery()
        do {
            _ = try await discovery.recordLensPoints(expectedSessionID: session, peripheralID: peer)
            Issue.record("Production launch admitted a development lens recording")
        } catch { #expect((error as? BridgeFailure)?.code == "validation_disabled") }
        discovery.cancelLensPointRecording()
        discovery.cancelNativeProbe()
        let stopped = await discovery.stopNativeProbe()
        #expect(stopped == nil && !discovery.isBluetoothInitialized)
    }

    @MainActor @Test func revokedPermitPreventsEntryBeforeAnyBluetoothInitialization() async {
        let discovery = Pocket3BluetoothDiscovery(), permit = OperationPermit()
        permit.invalidate()
        do {
            _ = try await discovery.recordLensPoints(expectedSessionID: session, peripheralID: peer, permit: permit)
            Issue.record("Revoked operation permit admitted recording")
        } catch { #expect((error as? BridgeFailure)?.code == "cancelled") }
        #expect(!discovery.isBluetoothInitialized)
    }
}
