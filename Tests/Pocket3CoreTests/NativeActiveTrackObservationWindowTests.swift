import Foundation
import Testing
@testable import Pocket3Core

@Suite("Native ActiveTrack passive observation window")
struct NativeActiveTrackObservationWindowTests {
    private let session = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let peer = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    private func marker(
        _ state: NativeActiveTrackOperatorMarkerState,
        _ offset: TimeInterval
    ) throws -> NativeActiveTrackOperatorMarker {
        try NativeActiveTrackOperatorMarker(state: state,
                                             offsetSeconds: offset)
    }

    private func request(window: TimeInterval = 4) throws
        -> NativeActiveTrackObservationWindowRequest {
        try NativeActiveTrackObservationWindowRequest(
            expectedSessionID: session,
            peripheralID: peer,
            windowSeconds: window,
            markers: [try marker(.off, 1), try marker(.on, 2), try marker(.off, 3)])
    }

    private func floatLE(_ value: Float) -> [UInt8] {
        var bits = value.bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Array($0) }
    }

    private func observation(
        commandID: UInt8,
        payload: Data,
        uptime: TimeInterval,
        sequence: UInt16 = 1
    ) throws -> Pocket3ActiveTrackObservation {
        let frame = DUMLFrame(
            source: 0x01, destination: 0x02, sequence: sequence, flags: 0,
            commandSet: 0x02, commandID: commandID, payload: payload)
        let value = Pocket3ActiveTrackObservation(
            frame: frame,
            sessionID: session,
            peripheralID: peer,
            binding: Pocket3ActiveTrackObservation.bluetoothBinding(
                sessionID: session),
            receivedAt: Date(timeIntervalSince1970: 100 + uptime),
            receivedUptime: uptime)
        return try #require(value)
    }

    private func event(
        commandID: UInt8,
        payload: Data,
        uptime: TimeInterval,
        sequence: UInt16
    ) -> BluetoothCameraEvent {
        BluetoothCameraEvent(
            sessionID: session,
            peripheralID: peer,
            receivedAt: Date(timeIntervalSince1970: 100 + uptime),
            receivedUptime: uptime,
            sequence: sequence,
            source: 0x01,
            commandSet: 0x02,
            commandID: commandID,
            payloadLength: payload.count,
            payloadHex: payload.map { String(format: "%02x", $0) }.joined())
    }

    private func status(_ phase: BluetoothDiscoveryPhase = .gattPaired,
                        fff4: Bool = true,
                        fff5: Bool = true) -> BluetoothDiscoveryStatus {
        var value = BluetoothDiscoveryStatus(
            phase: phase,
            sessionID: session,
            candidates: [],
            selectedPeripheralID: peer,
            issueCode: nil,
            identityVerification: "unverified_candidate",
            authentication: "protocol_pair_confirmed",
            fff4NotificationEnabled: fff4,
            fff5NotificationEnabled: fff5,
            fff4Properties: nil,
            fff5Properties: nil,
            receivedFrames: 0,
            fragments: [:],
            pairing: BluetoothPairingStatus(
                phase: .paired,
                peerReportedPaired: true,
                credentialsAvailable: false,
                issueCode: nil))
        value.registrationAcknowledgmentSubmitted = true
        return value
    }

    private func baseline(capturedUptime: TimeInterval = 9.5)
        throws -> NativeActiveTrackObservationBaseline {
        NativeActiveTrackObservationBaseline(
            sessionID: session,
            peripheralID: peer,
            capturedUptime: capturedUptime,
            activeTrackObservations: [try observation(
                commandID: 0xA5,
                payload: Data([0, 0, 0, 0]),
                uptime: 9,
                sequence: 1)])
    }

    private func recording(events: [BluetoothCameraEvent],
                           end: BluetoothCameraEventRecordingEnd? = .windowElapsed)
        -> BluetoothCameraEventRecording {
        BluetoothCameraEventRecording(
            sessionID: session,
            peripheralID: peer,
            startedUptime: 10,
            finishedUptime: 14,
            end: end,
            failureCode: nil,
            acceptedSampleCount: events.count,
            rejectedFrameCount: 0,
            unchangedFrameCount: 0,
            events: events)
    }

    @Test func requestRequiresExplicitOffOnOffMarkersAndRoundTripsCLI()
        throws {
        let parsed = try NativeActiveTrackObservationWindowRequest(
            cliArguments: [
                "--session", session.uuidString,
                "--peripheral", peer.uuidString,
                "--window", "4",
                "--marker", "off:1",
                "--marker", "on:2",
                "--marker", "off:3"
            ])
        #expect(parsed.markers.map(\.state) == [.off, .on, .off])
        #expect(parsed.markers.map(\.offsetSeconds) == [1, 2, 3])
        let decoded = try NativeActiveTrackObservationWindowRequest(
            arguments: parsed.arguments)
        #expect(decoded == parsed)

        #expect(throws: NativeActiveTrackObservationWindowError.invalidMarkerSequence) {
            try NativeActiveTrackObservationWindowRequest(
                expectedSessionID: session,
                peripheralID: peer,
                windowSeconds: 4,
                markers: [try marker(.on, 1), try marker(.off, 2), try marker(.off, 3)])
        }
        #expect(throws: BridgeFailure.self) {
            try NativeActiveTrackObservationWindowRequest(cliArguments: [
                "--session", session.uuidString,
                "--peripheral", peer.uuidString,
                "--marker", "off:1",
                "--marker", "on:2"
            ])
        }
    }

    @Test func routeEvaluationDistinguishesUnavailableRoute() throws {
        let request = try request()
        #expect(
            NativeActiveTrackObservationWindowRoute.evaluate(
                status: status(),
                expectedSessionID: request.expectedSessionID,
                peripheralID: request.peripheralID) == .available)
        let unavailable = NativeActiveTrackObservationWindowRoute.evaluate(
            status: status(fff4: false),
            expectedSessionID: request.expectedSessionID,
            peripheralID: request.peripheralID)
        #expect(unavailable == .unavailable(
            code: "active_track_observation_notifications_unavailable"))
    }

    @Test func correlatesRawA5A6A89AndCameraStatusAcrossMarkers() throws {
        let a89Payload = Data([0, 0, 0, 0, 0, 0x19, 1]) +
            Data(floatLE(0.25) + floatLE(0.75) + floatLE(0.2) + floatLE(0.3))
        let events = [
            event(commandID: 0xA5, payload: Data([0, 0, 0, 0]), uptime: 10.5, sequence: 1),
            event(commandID: 0xA6, payload: Data([7, 1, 2]), uptime: 11.5, sequence: 2),
            event(commandID: 0x89, payload: a89Payload, uptime: 12.5, sequence: 3),
            event(commandID: 0x80, payload: Data([0x81]), uptime: 13.5, sequence: 4)
        ]
        let result = NativeActiveTrackObservationWindowService().run(
            try request(),
            route: .available,
            baseline: try baseline(),
            recording: recording(events: events))

        #expect(result.outcome == .eventsObserved)
        #expect(result.routeAvailable)
        #expect(result.eventsObserved && !result.noEvents)
        #expect(result.rawEvents.count == 4)
        #expect(result.a5Observations.count == 1)
        #expect(result.a89Observations.count == 1)
        #expect(result.a6Candidates.count == 1)
        #expect(result.a6Candidates[0].commandID == 0xA6)
        #expect(result.cameraStatusChanges.count == 1)
        #expect(result.cameraStatusChanges[0].recording)
        #expect(result.segments.count == 4)
        #expect(result.events(in: result.segments[0]).map(\.kind) == [.a5])
        #expect(result.events(in: result.segments[1]).map(\.kind) == [.a6Candidate])
        #expect(result.events(in: result.segments[2]).map(\.kind) == [.a89])
        #expect(result.events(in: result.segments[3]).map(\.kind) == [.cameraStatus])
        #expect(result.events[1].rawEnvelope.payloadHex == "070102")
    }

    @Test func availableRouteWithNoTelemetryIsNotUnavailableRoute() throws {
        let result = NativeActiveTrackObservationWindowService().run(
            try request(),
            route: .available,
            baseline: try baseline(),
            recording: recording(events: []))
        #expect(result.outcome == .noEvents)
        #expect(result.noEvents && result.completed)
        #expect(result.routeAvailable)
        #expect(result.events.isEmpty)

        let unavailable = NativeActiveTrackObservationWindowService().run(
            try request(),
            route: .unavailable(code: "active_track_observation_not_gatt_paired"),
            baseline: nil,
            recording: nil)
        #expect(unavailable.outcome == .unavailableRoute)
        #expect(!unavailable.noEvents && !unavailable.completed)
        #expect(!unavailable.routeAvailable)
        #expect(unavailable.failureCode == "active_track_observation_not_gatt_paired")
    }

    @Test func connectionChangeRemainsPartialEvidence() throws {
        let foreign = BluetoothCameraEvent(
            sessionID: UUID(),
            peripheralID: peer,
            receivedAt: Date(timeIntervalSince1970: 110),
            receivedUptime: 10.5,
            sequence: 1,
            source: 0x01,
            commandSet: 0x02,
            commandID: 0xA5,
            payloadLength: 4,
            payloadHex: "00000000")
        let result = NativeActiveTrackObservationWindowService().run(
            try request(),
            route: .available,
            baseline: try baseline(),
            recording: recording(events: [foreign], end: .connectionChanged))
        #expect(result.outcome == .connectionChanged)
        #expect(result.recordingEnd == .connectionChanged)
        #expect(result.events.isEmpty)
        #expect(!result.completed)
    }
}
