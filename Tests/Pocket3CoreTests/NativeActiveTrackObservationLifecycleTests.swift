import Foundation
import Testing
@testable import Pocket3Core

@Suite("Native ActiveTrack interactive observation lifecycle")
struct NativeActiveTrackObservationLifecycleTests {
    private let session = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let peer = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    private func startRequest(window: TimeInterval = 4) throws
        -> NativeActiveTrackObservationWindowLifecycleRequest {
        try .init(action: .start, expectedSessionID: session,
                  peripheralID: peer, windowSeconds: window)
    }

    private func markerRequest(
        _ state: NativeActiveTrackOperatorMarkerState,
        at uptime: TimeInterval
    ) throws -> NativeActiveTrackObservationWindowLifecycleRequest {
        try .init(action: .marker, expectedSessionID: session,
                  peripheralID: peer, markerState: state,
                  markerUptime: uptime)
    }

    private func baseline() throws -> NativeActiveTrackObservationBaseline {
        let frame = DUMLFrame(
            source: 1, destination: 2, sequence: 1, flags: 0,
            commandSet: 2, commandID: 0xA5,
            payload: Data([0, 0, 0, 0]))
        let observation = try #require(Pocket3ActiveTrackObservation(
            frame: frame,
            sessionID: session,
            peripheralID: peer,
            binding: Pocket3ActiveTrackObservation.bluetoothBinding(
                sessionID: session),
            receivedAt: Date(timeIntervalSince1970: 100),
            receivedUptime: 9))
        return NativeActiveTrackObservationBaseline(
            sessionID: session, peripheralID: peer, capturedUptime: 9.5,
            activeTrackObservations: [observation])
    }

    private func recording(end: BluetoothCameraEventRecordingEnd? = .windowElapsed)
        -> BluetoothCameraEventRecording {
        BluetoothCameraEventRecording(
            sessionID: session, peripheralID: peer,
            startedUptime: 10, finishedUptime: 14, end: end,
            failureCode: nil, acceptedSampleCount: 0,
            rejectedFrameCount: 0, unchangedFrameCount: 0, events: [])
    }

    @Test func requestAndCLIExposeSeparateLifecycleActions() throws {
        let start = try NativeActiveTrackObservationWindowLifecycleRequest(
            cliArguments: [
                "--action", "start", "--session", session.uuidString,
                "--peripheral", peer.uuidString, "--window", "4"
            ])
        #expect(start.action == .start && start.windowSeconds == 4)
        let marker = try NativeActiveTrackObservationWindowLifecycleRequest(
            cliArguments: [
                "--action", "marker", "--session", session.uuidString,
                "--peripheral", peer.uuidString, "--state", "off", "--at", "11"
            ])
        #expect(marker.action == .marker)
        #expect(marker.markerState == .off && marker.markerUptime == 11)
        #expect(try NativeActiveTrackObservationWindowLifecycleRequest(
            arguments: marker.arguments) == marker)
        let receiptStamped = try NativeActiveTrackObservationWindowLifecycleRequest(
            cliArguments: [
                "--action", "marker", "--session", session.uuidString,
                "--peripheral", peer.uuidString, "--state", "on"
            ])
        #expect(receiptStamped.markerState == .on &&
            receiptStamped.markerUptime == nil)
        #expect(IPCClient.timeoutSeconds(
            for: NativeActiveTrackObservationWindowLifecycleRequest.operation) == 120)
        let envelope = ServiceRequest(
            token: "test-token",
            operation: NativeActiveTrackObservationWindowLifecycleRequest.operation,
            arguments: start.arguments)
        let decodedEnvelope = try JSONValue.encode(envelope)
        #expect(decodedEnvelope["operation"].string ==
            NativeActiveTrackObservationWindowLifecycleRequest.operation)
        #expect(try NativeActiveTrackObservationWindowLifecycleRequest(
            arguments: decodedEnvelope["arguments"]) == start)
        #expect(throws: BridgeFailure.self) {
            try NativeActiveTrackObservationWindowLifecycleRequest(
                cliArguments: [
                    "--action", "status", "--session", session.uuidString,
                    "--peripheral", peer.uuidString, "--state", "off", "--at", "11"
                ])
        }
        #expect(throws: NativeActiveTrackObservationWindowLifecycleError.invalidArguments) {
            try NativeActiveTrackObservationWindowLifecycleRequest(
                arguments: .object([
                    "action": .string("status"),
                    "expectedSessionID": .string(session.uuidString),
                    "peripheralID": .string(peer.uuidString),
                    "unexpected": .bool(true)
                ]))
        }
    }

    @Test func markersAreAcceptedAsSeparateCallsAndFencedByOrderAndIdentity()
        throws {
        var coordinator = try NativeActiveTrackObservationWindowLifecycleCoordinator(
            start: try startRequest(), route: .available,
            baseline: try baseline(), startedUptime: 10)
        try coordinator.mark(try markerRequest(.off, at: 11))
        #expect(coordinator.markers.count == 1)
        let active = coordinator.update(
            recording: recording(end: nil), action: .status)
        #expect(active.projection.recordingActive)
        #expect(active.projection.nextMarkerState == .on)
        #expect(throws: NativeActiveTrackObservationWindowLifecycleError.markerSequence) {
            try coordinator.mark(try markerRequest(.off, at: 11.5))
        }
        #expect(throws: NativeActiveTrackObservationWindowLifecycleError.staleSession) {
            try coordinator.mark(.init(
                action: .marker,
                expectedSessionID: UUID(),
                peripheralID: peer,
                markerState: .on,
                markerUptime: 12))
        }
        try coordinator.mark(try markerRequest(.on, at: 12))
        try coordinator.mark(try markerRequest(.off, at: 13))
        #expect(coordinator.markers.map(\.state) == [.off, .on, .off])
        #expect(coordinator.markers.map(\.offsetSeconds) == [1, 2, 3])
    }

    @Test func finishProjectsTerminalNoEventsAfterAllMarkers() throws {
        var coordinator = try NativeActiveTrackObservationWindowLifecycleCoordinator(
            start: try startRequest(), route: .available,
            baseline: try baseline(), startedUptime: 10)
        try coordinator.mark(try markerRequest(.off, at: 11))
        try coordinator.mark(try markerRequest(.on, at: 12))
        try coordinator.mark(try markerRequest(.off, at: 13))
        let status = coordinator.finish(recording: recording())
        #expect(status.action == .finish)
        #expect(status.phase == .completed)
        #expect(status.completed)
        #expect(status.markerCount == 3)
        #expect(status.observation?.outcome == .noEvents)
        #expect(status.observation?.completed == true)
        #expect(status.recordingActive == false)
        #expect(status.projection.baselineCaptured)
        #expect(status.projection.markerCount == 3)
        #expect(status.projection.nextMarkerState == nil)
        #expect(status.projection.observationOutcome == .noEvents)
        #expect(status.projection.observationCompleted)
        let encoded = try JSONValue.encode(status)
        #expect(encoded["projection"]["nextMarkerState"].string == nil)
        #expect(encoded["projection"]["observationOutcome"].string == "noEvents")
    }

    @Test func cancelKeepsPartialMarkersAndDoesNotInventCompletion() throws {
        var coordinator = try NativeActiveTrackObservationWindowLifecycleCoordinator(
            start: try startRequest(), route: .available,
            baseline: try baseline(), startedUptime: 10)
        try coordinator.mark(try markerRequest(.off, at: 11))
        let status = coordinator.cancel(recording: recording(end: .cancelled))
        #expect(status.phase == .cancelled)
        #expect(status.markerCount == 1)
        #expect(!status.completed)
        #expect(status.failureCode == "cancelled")
        #expect(status.recording?.end == .cancelled)
    }
}
