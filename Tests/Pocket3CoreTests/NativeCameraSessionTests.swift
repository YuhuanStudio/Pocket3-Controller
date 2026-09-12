import Foundation
import Testing
@testable import Pocket3Core

@Suite("Native camera session readiness") struct NativeCameraSessionTests {
    @Test func readinessRequiresTheObservedLifecycleInOrder() throws {
        var session = NativeCameraSession()
        let generation = session.begin(sessionID: UUID(), peerID: UUID())

        #expect(session.state == .disconnected)
        let paired = session.markPaired(generation: generation)
        #expect(paired)
        #expect(session.state == .paired)
        #expect(session.isReady(for: .battery, generation: generation))
        #expect(!session.isReady(for: .whiteBalance, generation: generation))

        let credentials = session.markCredentialsAvailable(generation: generation)
        #expect(credentials)
        #expect(session.state == .credentialsAvailable)
        #expect(!session.isReady(for: .record, generation: generation))
        let handshaking = session.beginDatalinkHandshake(generation: generation)
        #expect(handshaking)
        #expect(session.state == .datalinkHandshaking)
        #expect(!session.isReady(for: .record, generation: generation))

        let commandReady = session.markCommandReady(generation: generation)
        #expect(commandReady)
        #expect(session.state == .commandReady)
        #expect(session.isReady(for: .whiteBalance, generation: generation))
        #expect(session.isReady(for: .record, generation: generation))
        #expect(!session.isReady(for: .livePreview, generation: generation))
        #expect(!session.status.liveReady)

        let liveReady = session.markLiveReady(generation: generation)
        #expect(liveReady)
        #expect(session.state == .liveReady)
        #expect(session.isReady(for: .livePreview, generation: generation))
    }

    @Test func minimumReadinessMappingKeepsReadOnlyAndLiveBoundariesExplicit() {
        #expect(NativeCameraSessionCommand.battery.minimumReadiness == .paired)
        #expect(NativeCameraSessionCommand.telemetry.minimumReadiness == .paired)
        #expect(NativeCameraSessionCommand.cameraSettingsRead.minimumReadiness == .paired)
        #expect(NativeCameraSessionCommand.credentials.minimumReadiness == .credentialsAvailable)
        #expect(NativeCameraSessionCommand.whiteBalance.minimumReadiness == .commandReady)
        #expect(NativeCameraSessionCommand.record.minimumReadiness == .commandReady)
        #expect(NativeCameraSessionCommand.tracking.minimumReadiness == .commandReady)
        #expect(NativeCameraSessionCommand.livePreview.minimumReadiness == .liveReady)
    }

    @Test func transportReadyCannotPromoteBlePairingWithoutHandshakeEvidence() {
        var session = NativeCameraSession()
        let generation = session.begin()
        let paired = session.markPaired(generation: generation)
        #expect(paired)
        let credentials = session.markCredentialsAvailable(generation: generation)
        #expect(credentials)

        let acceptedReady = session.observeDatalink(.ready, generation: generation)
        #expect(!acceptedReady)
        #expect(session.state == .credentialsAvailable)
        #expect(!session.isReady(for: .record, generation: generation))

        let acceptedConnecting = session.observeDatalink(.connecting, generation: generation)
        #expect(acceptedConnecting)
        let acceptedReadyAfterHandshake = session.observeDatalink(.ready, generation: generation)
        #expect(acceptedReadyAfterHandshake)
        #expect(session.state == .commandReady)
    }

    @Test func disarmedTransportRotatesGenerationBeforeAReconnect() {
        var session = NativeCameraSession()
        let generation = session.begin()
        _ = session.markPaired(generation: generation)
        _ = session.markCredentialsAvailable(generation: generation)
        _ = session.beginDatalinkHandshake(generation: generation)
        _ = session.markCommandReady(generation: generation)

        let disarmed = session.observeDatalink(.disarmed, generation: generation)
        #expect(disarmed)
        let reconnectGeneration = session.generation
        #expect(reconnectGeneration != generation)
        #expect(session.state == .credentialsAvailable)
        let staleReady = session.observeDatalink(.ready, generation: generation)
        #expect(!staleReady)

        let reconnecting = session.observeDatalink(.connecting, generation: reconnectGeneration)
        #expect(reconnecting)
        let reconnected = session.observeDatalink(.ready, generation: reconnectGeneration)
        #expect(reconnected)
        #expect(session.state == .commandReady)
    }

    @Test func staleGenerationCannotAdvanceOrAuthorizeACommand() throws {
        var session = NativeCameraSession()
        let oldGeneration = session.begin(sessionID: UUID(), peerID: UUID())
        let oldPaired = session.markPaired(generation: oldGeneration)
        #expect(oldPaired)
        let oldCredentials = session.markCredentialsAvailable(generation: oldGeneration)
        #expect(oldCredentials)

        let newGeneration = session.begin(sessionID: UUID(), peerID: UUID())
        #expect(newGeneration != oldGeneration)
        #expect(session.state == .disconnected)
        let stalePaired = session.markPaired(generation: oldGeneration)
        #expect(!stalePaired)
        let staleCommandReady = session.markCommandReady(generation: oldGeneration)
        #expect(!staleCommandReady)
        #expect(!session.isReady(for: .battery, generation: oldGeneration))
        #expect(throws: NativeCameraSessionTransitionError.self) {
            try session.require(.battery, generation: oldGeneration)
        }
    }

    @Test func invalidSkipsAndDisconnectKeepCommandReadinessHonest() throws {
        var session = NativeCameraSession()
        let generation = session.begin()
        let skippedCommandReady = session.markCommandReady(generation: generation)
        #expect(skippedCommandReady == false)
        let paired = session.markPaired(generation: generation)
        #expect(paired)
        let skippedCommandReadyAfterPair = session.markCommandReady(generation: generation)
        #expect(skippedCommandReadyAfterPair == false)
        let credentials = session.markCredentialsAvailable(generation: generation)
        #expect(credentials)
        let skippedLiveReady = session.markLiveReady(generation: generation)
        #expect(skippedLiveReady == false)

        #expect(throws: NativeCameraSessionTransitionError.self) {
            try session.require(.record, generation: generation)
        }
        let handshaking = session.beginDatalinkHandshake(generation: generation)
        #expect(handshaking)
        let commandReady = session.markCommandReady(generation: generation)
        #expect(commandReady)
        try session.require(.record, generation: generation)

        let disconnectedGeneration = session.invalidate()
        #expect(disconnectedGeneration != generation)
        #expect(session.state == .disconnected)
        #expect(!session.isReady(for: .battery))
        #expect(throws: NativeCameraSessionTransitionError.self) {
            try session.require(.battery)
        }
    }
}
