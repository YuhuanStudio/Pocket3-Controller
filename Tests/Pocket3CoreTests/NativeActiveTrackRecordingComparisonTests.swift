import Foundation
import Testing
@testable import Pocket3Core

@Suite("ActiveTrack recording scalar comparison")
struct NativeActiveTrackRecordingComparisonTests {
    private let session = UUID(uuidString: "9386318D-B0DB-448C-8857-7CA83316208C")!
    private let peer = UUID(uuidString: "DCA2FB6B-AF9C-422F-6C78-2ED0AD01971E")!

    private let artifactA89Payload = Data(hex: "0000000000a0418299013fcaf4c93ea060263d9890993d")!

    private func event(
        source: UInt8 = 1,
        commandSet: UInt8 = 2,
        commandID: UInt8,
        payload: Data,
        uptime: TimeInterval,
        sequence: UInt16
    ) -> BluetoothCameraEvent {
        BluetoothCameraEvent(
            sessionID: session,
            peripheralID: peer,
            receivedAt: Date(timeIntervalSince1970: 1_000 + uptime),
            receivedUptime: uptime,
            sequence: sequence,
            source: source,
            commandSet: commandSet,
            commandID: commandID,
            payloadLength: payload.count,
            payloadHex: payload.map { String(format: "%02x", $0) }.joined())
    }

    private func recording(
        events: [BluetoothCameraEvent],
        sessionID: UUID = UUID(uuidString: "9386318D-B0DB-448C-8857-7CA83316208C")!,
        peerID: UUID = UUID(uuidString: "DCA2FB6B-AF9C-422F-6C78-2ED0AD01971E")!
    ) -> BluetoothCameraEventRecording {
        BluetoothCameraEventRecording(
            sessionID: sessionID,
            peripheralID: peerID,
            startedUptime: 100,
            finishedUptime: 120,
            end: .windowElapsed,
            failureCode: nil,
            acceptedSampleCount: events.count,
            rejectedFrameCount: 0,
            unchangedFrameCount: 0,
            events: events)
    }

    @Test func artifactShapedProjectionRetainsRawAndBoundedRouteScalars() {
        var events: [BluetoothCameraEvent] = []
        for index in 0..<224 {
            var payload = artifactA89Payload
            payload[0] = UInt8(index % 212)
            events.append(event(
                commandID: 0x89,
                payload: payload,
                uptime: 100.1 + Double(index) * 19.2 / 224,
                sequence: UInt16(index + 1)))
        }
        for index in 0..<78 {
            events.append(event(
                source: 4,
                commandSet: 4,
                commandID: 5,
                payload: Data([UInt8(index), 0x02]),
                uptime: 100.2 + Double(index) * 19.0 / 78,
                sequence: UInt16(500 + index)))
        }
        for (index, (source, commandSet, commandID, payload)) in [
            (0, (UInt8(1), UInt8(2), UInt8(0x80), Data([0x01]))),
            (1, (UInt8(1), UInt8(2), UInt8(0xDC), Data([0, 0, 1]))),
            (2, (UInt8(4), UInt8(4), UInt8(0x1C), Data([0x48]))),
            (3, (UInt8(4), UInt8(4), UInt8(0x27), Data([0, 0, 0, 0, 0]))),
            (4, (UInt8(4), UInt8(4), UInt8(0x38), Data([0, 0, 0, 0, 0])))
        ] {
            events.append(event(
                source: source,
                commandSet: commandSet,
                commandID: commandID,
                payload: payload,
                uptime: 100.3 + Double(index) * 0.01,
                sequence: UInt16(600 + index)))
        }
        let projection = NativeActiveTrackRecordingComparator.project(
            recording(events: events), label: .on)
        #expect(projection.rawEvents.count == 307)
        #expect(projection.routes.count == 7)
        #expect(projection.durationSeconds == 20)
        #expect(abs((projection.eventRatePerSecond ?? 0) - 15.35) < 0.000001)
        let a89 = projection.routes.first {
            $0.route.commandSet == 2 && $0.route.commandID == 0x89
        }
        #expect(a89?.eventCount == 224)
        #expect(a89?.distinctPayloadCount == 212)
        #expect(a89?.distinctPayloadDigestSHA256?.count == 64)
        #expect(projection.a89Observations.count <=
            NativeActiveTrackRecordingProjection.maximumTypedObservations)
        #expect(projection.rawEvents[0].payloadHex ==
            "0000000000a0418299013fcaf4c93ea060263d9890993d")
    }

    @Test func comparisonReportsPayloadRateAndStrictFieldDeltas() {
        let onEvents = [
            event(commandID: 0x89, payload: artifactA89Payload,
                  uptime: 100.5, sequence: 1),
            event(commandID: 0xA6, payload: Data([7, 1, 2]),
                  uptime: 101, sequence: 2),
            event(commandID: 0x80, payload: Data([0x81]),
                  uptime: 102, sequence: 3)
        ]
        var offPayload = artifactA89Payload
        offPayload[7] = 0x81
        let offEvents = [
            event(commandID: 0x89, payload: offPayload,
                  uptime: 110.5, sequence: 4),
            event(commandID: 0x80, payload: Data([0x01]),
                  uptime: 112, sequence: 5)
        ]
        let comparison = NativeActiveTrackRecordingComparator.compare(
            on: recording(events: onEvents), off: recording(events: offEvents))
        #expect(comparison.comparable)
        #expect(comparison.identityMatch)
        #expect(comparison.onEventCount == 3 && comparison.offEventCount == 2)
        #expect(comparison.routeDeltas.contains {
            $0.route.commandID == 0xA6 && $0.onCount == 1 && $0.offCount == 0
        })
        #expect(comparison.routeDeltas.contains {
            $0.route.commandID == 0x89 && $0.payloadDigestChanged
        })
        #expect(comparison.fieldDeltas.contains {
            $0.field == "cameraStatusByte" && $0.changed &&
                $0.onValue == "81" && $0.offValue == "01"
        })
        #expect(comparison.onA89Boxes.count == 1)
        #expect(comparison.offA89Boxes.count == 1)
        #expect(comparison.onA6CandidateCount == 1 &&
            comparison.offA6CandidateCount == 0)
    }

    @Test func mismatchedIdentityIsExplicitlyNotComparable() {
        let on = recording(events: [
            event(commandID: 0x80, payload: Data([0x81]), uptime: 101, sequence: 1)
        ])
        let off = recording(
            events: [],
            sessionID: UUID(),
            peerID: peer)
        let comparison = NativeActiveTrackRecordingComparator.compare(on: on, off: off)
        #expect(!comparison.identityMatch)
        #expect(!comparison.comparable)
        #expect(comparison.failureCode == "active_track_recording_identity_mismatch")
    }

    @Test func unrelatedDynamicTrafficRaisesConfoundingAssessment() {
        let on = recording(events: [
            event(commandID: 0x89, payload: artifactA89Payload,
                  uptime: 101, sequence: 1),
            event(source: 4, commandSet: 4, commandID: 5,
                  payload: Data([1]), uptime: 102, sequence: 2)
        ])
        let off = recording(events: [
            event(commandID: 0x89, payload: artifactA89Payload,
                  uptime: 111, sequence: 3),
            event(source: 4, commandSet: 4, commandID: 5,
                  payload: Data([2]), uptime: 112, sequence: 4),
            event(source: 4, commandSet: 4, commandID: 5,
                  payload: Data([3]), uptime: 113, sequence: 5)
        ])
        let comparison = NativeActiveTrackRecordingComparator.compare(
            on: on, off: off)
        #expect(comparison.assessment == .mixedDynamicTraffic)
        #expect(comparison.changedNonActiveRouteCount == 1)
        #expect(comparison.confoundingRoutes == [
            NativeActiveTrackRecordingRoute(source: 4, commandSet: 4,
                                            commandID: 5)
        ])
        #expect(!comparison.claimsTrackingCausality)
    }

    @Test func suppliedArtifactPairProducesBoundedMixedTrafficProjection()
        throws {
        let onURL = URL(fileURLWithPath: "/tmp/p3-active-track-on-events.json")
        let offURL = URL(fileURLWithPath: "/tmp/p3-active-track-off-events.json")
        guard FileManager.default.fileExists(atPath: onURL.path),
              FileManager.default.fileExists(atPath: offURL.path) else {
            // The checked-in synthetic tests above remain portable when the
            // operator's local artifacts are unavailable.
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let on = try decoder.decode(
            BluetoothCameraEventRecording.self,
            from: Data(contentsOf: onURL))
        let off = try decoder.decode(
            BluetoothCameraEventRecording.self,
            from: Data(contentsOf: offURL))
        let comparison = NativeActiveTrackRecordingComparator.compare(
            on: on, off: off)
        #expect(on.events.count == 307 && off.events.count == 182)
        #expect(comparison.comparable && comparison.identityMatch)
        #expect(comparison.assessment == .mixedDynamicTraffic)
        #expect(comparison.onA6CandidateCount == 0 &&
            comparison.offA6CandidateCount == 0)
        #expect(comparison.routeDeltas.contains {
            $0.route == NativeActiveTrackRecordingRoute(
                source: 1, commandSet: 2, commandID: 0x89) &&
                $0.onCount == 224 && $0.offCount == 70
        })
        #expect(comparison.routeDeltas.contains {
            $0.route == NativeActiveTrackRecordingRoute(
                source: 4, commandSet: 4, commandID: 5) &&
                $0.onCount == 78 && $0.offCount == 107
        })
        #expect(comparison.confoundingRoutes.contains {
            $0 == NativeActiveTrackRecordingRoute(
                source: 4, commandSet: 4, commandID: 5)
        })
        #expect(comparison.onA89Boxes.count == 64 &&
            comparison.offA89Boxes.count == 64)
        #expect(!comparison.claimsTrackingCausality)
    }
}

private extension Data {
    init?(hex: String) {
        let bytes = Array(hex.utf8)
        guard bytes.count.isMultiple(of: 2) else { return nil }
        var value = Data()
        value.reserveCapacity(bytes.count / 2)
        var index = 0
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        while index < bytes.count {
            guard let high = nibble(bytes[index]),
                  let low = nibble(bytes[index + 1]) else { return nil }
            value.append((high << 4) | low)
            index += 2
        }
        self = value
    }
}
