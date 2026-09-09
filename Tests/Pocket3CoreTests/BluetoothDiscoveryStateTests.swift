import Foundation
import Testing
@testable import Pocket3Core

@Suite struct BluetoothDiscoveryStateTests {
    @Test func discoveringACandidateNeverSelectsOrAuthenticatesIt() {
        var state = BluetoothDiscoveryState()
        let session = state.beginScan()
        let outcome1 = state.transition(from: .waitingForBluetooth, to: .scanning, session: session)
        #expect(outcome1)
        let candidate = BluetoothCandidate(id: UUID(), name: "Pocket 3", rssi: -50, connectable: true)
        let outcome2 = state.discover(candidate, session: session)
        #expect(outcome2)
        #expect(state.selected == nil && state.phase == .scanning)
        let outcome3 = state.select(UUID()) == nil
        #expect(outcome3)
        let selectedSession = state.select(candidate.id)
        #expect(selectedSession != nil && selectedSession != session)
        #expect(state.selected == candidate.id && state.phase == .connecting)
    }

    @Test func disconnectAndRescanRejectLateCallbacksEvenForTheSameUUID() throws {
        var state = BluetoothDiscoveryState()
        let scan = state.beginScan()
        _ = state.transition(from: .waitingForBluetooth, to: .scanning, session: scan)
        let candidate = BluetoothCandidate(id: UUID(), name: nil, rssi: nil, connectable: nil)
        _ = state.discover(candidate, session: scan)
        let oldConnectionValue = state.select(candidate.id)
        let oldConnection = try #require(oldConnectionValue)
        state.finish(.disconnected)
        #expect(!state.accepts(peripheral: candidate.id, session: oldConnection))
        let outcome4 = !state.transition(from: .disconnected, to: .gattConnectedUnauthenticated, session: oldConnection)
        #expect(outcome4)
        let newScan = state.beginScan()
        _ = state.transition(from: .waitingForBluetooth, to: .scanning, session: newScan)
        _ = state.discover(candidate, session: newScan)
        let newConnectionValue = state.select(candidate.id)
        let newConnection = try #require(newConnectionValue)
        #expect(newConnection != oldConnection)
        #expect(!state.accepts(peripheral: candidate.id, session: oldConnection))
        #expect(state.accepts(peripheral: candidate.id, session: newConnection))
        let outcome5 = !state.discover(candidate, session: newScan)
        #expect(outcome5)
    }

    @Test func candidatesAreBoundedAndNonconnectableCandidatesAreNotSelected() {
        var state = BluetoothDiscoveryState()
        let session = state.beginScan()
        _ = state.transition(from: .waitingForBluetooth, to: .scanning, session: session)
        let blocked = BluetoothCandidate(id: UUID(), name: nil, rssi: -70, connectable: false)
        let outcome6 = state.discover(blocked, session: session)
        #expect(outcome6)
        let outcome7 = state.select(blocked.id) == nil
        #expect(outcome7)
        for _ in 0..<100 {
            _ = state.discover(.init(id: UUID(), name: nil, rssi: -60, connectable: true), session: session)
        }
        #expect(state.candidates.count == BluetoothDiscoveryState.maximumCandidates)
        let outcome8 = !state.discover(.init(id: UUID(), name: nil, rssi: nil, connectable: nil), session: session)
        #expect(outcome8)
        let outcome9 = state.discover(.init(id: blocked.id, name: "Updated", rssi: -45, connectable: false), session: session)
        #expect(outcome9)
        #expect(state.candidates.count == BluetoothDiscoveryState.maximumCandidates)
    }

    @Test func staleDeadlinesCannotEndANewerScan() {
        var state = BluetoothDiscoveryState()
        let old = state.beginScan()
        let current = state.beginScan()
        _ = state.transition(from: .waitingForBluetooth, to: .scanning, session: current)
        let outcome10 = !state.transition(from: .scanning, to: .scanComplete, session: old)
        #expect(outcome10)
        #expect(state.phase == .scanning)
        let outcome11 = state.transition(from: .scanning, to: .scanComplete, session: current)
        #expect(outcome11)
    }

    @Test func authorizationWaitCannotExpireAnAlreadyStartedRadioScan() {
        var state = BluetoothDiscoveryState()
        let session = state.beginScan()
        #expect(state.phase == .waitingForBluetooth)
        let started = state.transition(from: .waitingForBluetooth, to: .scanning, session: session)
        #expect(started)
        let staleAuthorizationDeadline = state.transition(from: .waitingForBluetooth, to: .failed, session: session)
        #expect(!staleAuthorizationDeadline && state.phase == .scanning)
        let actualScanDeadline = state.transition(from: .scanning, to: .scanComplete, session: session)
        #expect(actualScanDeadline)
    }
}
