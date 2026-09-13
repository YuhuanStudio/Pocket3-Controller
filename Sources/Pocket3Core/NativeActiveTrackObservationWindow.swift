import Foundation

/// Operator-only marker for a passive ActiveTrack observation window. The
/// marker describes what the operator did outside the transport; it never
/// causes an A6 command or becomes a camera-state claim.
public enum NativeActiveTrackOperatorMarkerState: String, Codable, Sendable,
    Equatable, CaseIterable {
    case off
    case on
}

public struct NativeActiveTrackOperatorMarker: Codable, Sendable, Equatable {
    public let state: NativeActiveTrackOperatorMarkerState
    /// Monotonic seconds after the observation window is armed.
    public let offsetSeconds: TimeInterval

    public init(state: NativeActiveTrackOperatorMarkerState,
                offsetSeconds: TimeInterval) throws {
        guard offsetSeconds.isFinite, offsetSeconds >= 0 else {
            throw NativeActiveTrackObservationWindowError.invalidMarker
        }
        self.state = state
        self.offsetSeconds = offsetSeconds
    }

    public init(from decoder: Decoder) throws {
        guard case .object(let fields) = try JSONValue(from: decoder),
              let stateValue = fields["state"]?.string,
              let state = NativeActiveTrackOperatorMarkerState(rawValue: stateValue),
              let offsetSeconds = fields["offsetSeconds"]?.number else {
            throw NativeActiveTrackObservationWindowError.invalidMarker
        }
        try self.init(state: state, offsetSeconds: offsetSeconds)
    }
}

public enum NativeActiveTrackObservationWindowError: Error, LocalizedError,
    Codable, Sendable, Equatable {
    case invalidArguments
    case invalidIdentity
    case invalidWindow
    case invalidMarker
    case invalidMarkerSequence

    public var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "ActiveTrack observation arguments are invalid"
        case .invalidIdentity:
            "ActiveTrack observation requires an exact BLE session and peer"
        case .invalidWindow:
            "ActiveTrack observation window must be between 0 and 20 seconds"
        case .invalidMarker:
            "ActiveTrack marker timestamp must be a finite non-negative number"
        case .invalidMarkerSequence:
            "ActiveTrack markers must be off, on, off in increasing time order"
        }
    }
}

/// Developer-only request for one bounded passive ActiveTrack window.
///
/// The three markers are supplied by the operator as monotonic offsets. The
/// request contains no execute bit because this operation has no writer.
public struct NativeActiveTrackObservationWindowRequest: Codable, Sendable,
    Equatable {
    public static let operation = "validation-wireless-tracking-window"
    public static let maximumWindowSeconds: TimeInterval = 20
    public static let requiredMarkerStates: [NativeActiveTrackOperatorMarkerState] = [
        .off, .on, .off
    ]

    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let windowSeconds: TimeInterval
    public let markers: [NativeActiveTrackOperatorMarker]

    public init(
        expectedSessionID: UUID,
        peripheralID: UUID,
        windowSeconds: TimeInterval = Self.maximumWindowSeconds,
        markers: [NativeActiveTrackOperatorMarker]
    ) throws {
        guard windowSeconds.isFinite, windowSeconds > 0,
              windowSeconds <= Self.maximumWindowSeconds else {
            throw NativeActiveTrackObservationWindowError.invalidWindow
        }
        guard markers.count == Self.requiredMarkerStates.count,
              markers.map(\.state) == Self.requiredMarkerStates,
              markers.allSatisfy({ $0.offsetSeconds.isFinite && $0.offsetSeconds >= 0 }),
              markers.allSatisfy({ $0.offsetSeconds <= windowSeconds }),
              zip(markers, markers.dropFirst()).allSatisfy({
                  $0.offsetSeconds < $1.offsetSeconds
              }) else {
            throw NativeActiveTrackObservationWindowError.invalidMarkerSequence
        }
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.windowSeconds = windowSeconds
        self.markers = markers
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys) == [
                  "expectedSessionID", "peripheralID", "windowSeconds", "markers"
              ],
              let sessionText = fields["expectedSessionID"]?.string,
              let expectedSessionID = UUID(uuidString: sessionText),
              let peripheralText = fields["peripheralID"]?.string,
              let peripheralID = UUID(uuidString: peripheralText),
              let windowSeconds = fields["windowSeconds"]?.number,
              case .array(let markerValues) = fields["markers"] else {
            throw NativeActiveTrackObservationWindowError.invalidArguments
        }
        let markers: [NativeActiveTrackOperatorMarker] = try markerValues.map {
            try $0.decode(NativeActiveTrackOperatorMarker.self)
        }
        try self.init(expectedSessionID: expectedSessionID,
                      peripheralID: peripheralID,
                      windowSeconds: windowSeconds,
                      markers: markers)
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var markerValues: [JSONValue] = []
        var index = 0
        while index < cliArguments.count {
            switch cliArguments[index] {
            case "--session", "--peripheral", "--window":
                guard index + 1 < cliArguments.count else {
                    throw BridgeFailure("usage", "Missing ActiveTrack observation option value")
                }
                let key: String
                switch cliArguments[index] {
                case "--session": key = "expectedSessionID"
                case "--peripheral": key = "peripheralID"
                default: key = "windowSeconds"
                }
                guard fields[key] == nil else {
                    throw BridgeFailure("usage", "Duplicate ActiveTrack observation option")
                }
                if key == "windowSeconds" {
                    guard let value = Double(cliArguments[index + 1]), value.isFinite else {
                        throw BridgeFailure("usage", "ActiveTrack window must be a finite number")
                    }
                    fields[key] = .number(value)
                } else {
                    fields[key] = .string(cliArguments[index + 1])
                }
                index += 2
            case "--marker":
                guard index + 1 < cliArguments.count else {
                    throw BridgeFailure("usage", "Missing ActiveTrack marker")
                }
                let value = cliArguments[index + 1]
                let pieces = value.split(maxSplits: 1,
                                         whereSeparator: { $0 == ":" || $0 == "@" })
                    .map(String.init)
                guard pieces.count == 2,
                      let state = NativeActiveTrackOperatorMarkerState(rawValue: pieces[0]),
                      let offset = Double(pieces[1]), offset.isFinite else {
                    throw BridgeFailure("usage", "Markers use off:SECONDS, on:SECONDS, off:SECONDS")
                }
                markerValues.append(.object([
                    "state": .string(state.rawValue),
                    "offsetSeconds": .number(offset)
                ]))
                index += 2
            default:
                throw BridgeFailure("usage", "Unknown ActiveTrack observation option")
            }
        }
        guard fields["expectedSessionID"] != nil,
              fields["peripheralID"] != nil,
              !markerValues.isEmpty else {
            throw BridgeFailure("usage",
                "Use --session UUID --peripheral UUID --marker off:SECONDS --marker on:SECONDS --marker off:SECONDS")
        }
        fields["windowSeconds"] = fields["windowSeconds"] ??
            .number(Self.maximumWindowSeconds)
        fields["markers"] = .array(markerValues)
        do {
            try self.init(arguments: .object(fields))
        } catch let error as NativeActiveTrackObservationWindowError {
            throw BridgeFailure("invalid_active_track_observation", error.localizedDescription)
        }
    }

    public var arguments: JSONValue {
        .object([
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString),
            "windowSeconds": .number(windowSeconds),
            "markers": .array(markers.map {
                .object([
                    "state": .string($0.state.rawValue),
                    "offsetSeconds": .number($0.offsetSeconds)
                ])
            })
        ])
    }

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }
}

/// Route evidence is evaluated from the currently selected BLE owner. An
/// unavailable route is returned as data so callers can distinguish it from
/// an available route that simply produced no telemetry events.
public enum NativeActiveTrackObservationWindowRoute: Codable, Sendable,
    Equatable {
    case available
    case unavailable(code: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var code: String? {
        if case .unavailable(let code) = self { return code }
        return nil
    }

    public static func evaluate(
        status: BluetoothDiscoveryStatus,
        expectedSessionID: UUID,
        peripheralID: UUID
    ) -> Self {
        guard status.sessionID == expectedSessionID else {
            return .unavailable(code: "active_track_observation_session_changed")
        }
        guard status.selectedPeripheralID == peripheralID else {
            return .unavailable(code: "active_track_observation_peer_changed")
        }
        guard status.phase == .gattPaired else {
            return .unavailable(code: "active_track_observation_not_gatt_paired")
        }
        let pairing = status.pairing
        guard pairing?.peerReportedPaired == true ||
                [.paired, .credentialsReady].contains(pairing?.phase ?? .idle) else {
            return .unavailable(code: "active_track_observation_pairing_unavailable")
        }
        guard status.registrationAcknowledgmentSubmitted else {
            return .unavailable(code: "active_track_observation_registration_unavailable")
        }
        guard status.fff4NotificationEnabled && status.fff5NotificationEnabled else {
            return .unavailable(code: "active_track_observation_notifications_unavailable")
        }
        return .available
    }
}

/// The baseline is captured by the existing BLE owner before a passive window
/// starts. It contains only typed status/candidate evidence and no credentials.
public struct NativeActiveTrackObservationBaseline: Codable, Sendable, Equatable {
    public static let maximumActiveTrackObservations = 64
    public static let maximumTrackingCandidates = 32

    public let sessionID: UUID
    public let peripheralID: UUID
    public let capturedUptime: TimeInterval
    public let activeTrackObservations: [Pocket3ActiveTrackObservation]
    public let trackingCandidates: [Pocket3TrackingCandidateFrame]
    public let cameraStatus: Pocket3CameraStatusObservation?

    public init(
        sessionID: UUID,
        peripheralID: UUID,
        capturedUptime: TimeInterval,
        activeTrackObservations: [Pocket3ActiveTrackObservation] = [],
        trackingCandidates: [Pocket3TrackingCandidateFrame] = [],
        cameraStatus: Pocket3CameraStatusObservation? = nil
    ) {
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.capturedUptime = capturedUptime
        self.activeTrackObservations = Array(
            activeTrackObservations.suffix(Self.maximumActiveTrackObservations))
        self.trackingCandidates = Array(
            trackingCandidates.suffix(Self.maximumTrackingCandidates))
        self.cameraStatus = cameraStatus
    }
}

public enum NativeActiveTrackObservationEventKind: String, Codable, Sendable,
    Equatable {
    case a5
    case a6Candidate
    case a89
    case cameraStatus
    case other
}

/// One bounded raw recorder envelope with optional typed projections. The raw
/// event remains authoritative; projections do not upgrade candidate evidence
/// into a tracking support claim.
public struct NativeActiveTrackObservationEvent: Codable, Sendable, Equatable {
    public let rawEnvelope: BluetoothCameraEvent
    public let kind: NativeActiveTrackObservationEventKind
    public let activeTrackObservation: Pocket3ActiveTrackObservation?
    public let trackingCandidate: Pocket3TrackingCandidateFrame?
    public let cameraStatus: Pocket3CameraStatusObservation?

    fileprivate init(rawEnvelope: BluetoothCameraEvent,
                     kind: NativeActiveTrackObservationEventKind,
                     activeTrackObservation: Pocket3ActiveTrackObservation?,
                     trackingCandidate: Pocket3TrackingCandidateFrame?,
                     cameraStatus: Pocket3CameraStatusObservation?) {
        self.rawEnvelope = rawEnvelope
        self.kind = kind
        self.activeTrackObservation = activeTrackObservation
        self.trackingCandidate = trackingCandidate
        self.cameraStatus = cameraStatus
    }

    public var raw: BluetoothCameraEvent { rawEnvelope }
}

public enum NativeActiveTrackObservationWindowSegmentLabel: String, Codable,
    Sendable, Equatable {
    case beforeFirstOff
    case afterOff
    case afterOn
    case afterFinalOff
}

/// Marker-bounded event indexes. Indexing the result's event array keeps the
/// complete raw envelopes bounded without duplicating payloads in each segment.
public struct NativeActiveTrackObservationWindowSegment: Codable, Sendable,
    Equatable {
    public let label: NativeActiveTrackObservationWindowSegmentLabel
    public let startOffsetSeconds: TimeInterval
    public let endOffsetSeconds: TimeInterval
    public let markerState: NativeActiveTrackOperatorMarkerState?
    public let eventIndices: [Int]

    fileprivate init(label: NativeActiveTrackObservationWindowSegmentLabel,
                     startOffsetSeconds: TimeInterval,
                     endOffsetSeconds: TimeInterval,
                     markerState: NativeActiveTrackOperatorMarkerState?,
                     eventIndices: [Int]) {
        self.label = label
        self.startOffsetSeconds = startOffsetSeconds
        self.endOffsetSeconds = endOffsetSeconds
        self.markerState = markerState
        self.eventIndices = eventIndices
    }
}

public enum NativeActiveTrackObservationWindowOutcome: String, Codable,
    Sendable, Equatable {
    case eventsObserved
    case noEvents
    case unavailableRoute
    case baselineUnavailable
    case connectionChanged
    case cancelled
    case failed
}

public struct NativeActiveTrackObservationWindowResult: Codable, Sendable,
    Equatable {
    public static let operation = NativeActiveTrackObservationWindowRequest.operation

    public let request: NativeActiveTrackObservationWindowRequest
    public let route: NativeActiveTrackObservationWindowRoute
    public let outcome: NativeActiveTrackObservationWindowOutcome
    public let baseline: NativeActiveTrackObservationBaseline?
    public let recordingStartedUptime: TimeInterval?
    public let recordingFinishedUptime: TimeInterval?
    public let recordingEnd: BluetoothCameraEventRecordingEnd?
    public let acceptedSampleCount: Int
    public let rejectedFrameCount: Int
    public let unchangedFrameCount: Int
    public let events: [NativeActiveTrackObservationEvent]
    public let segments: [NativeActiveTrackObservationWindowSegment]
    public let failureCode: String?

    public var routeAvailable: Bool { route.isAvailable }
    public var eventsObserved: Bool { outcome == .eventsObserved }
    public var noEvents: Bool { outcome == .noEvents }
    /// A live recorder snapshot may have no events yet, but it is not a
    /// completed window until the owner has produced a terminal recording.
    public var completed: Bool {
        (eventsObserved || noEvents) && recordingEnd != nil
    }
    public var rawEvents: [BluetoothCameraEvent] {
        events.map(\.rawEnvelope)
    }
    public var a5Observations: [Pocket3ActiveTrackObservation] {
        events.compactMap { $0.activeTrackObservation }.filter { $0.commandID == 0xA5 }
    }
    public var a89Observations: [Pocket3ActiveTrackObservation] {
        events.compactMap { $0.activeTrackObservation }.filter { $0.commandID == 0x89 }
    }
    public var a6Candidates: [Pocket3TrackingCandidateFrame] {
        events.compactMap(\.trackingCandidate)
    }
    public var cameraStatusChanges: [Pocket3CameraStatusObservation] {
        events.compactMap(\.cameraStatus)
    }

    /// Resolves one marker segment without exposing a second unbounded store.
    public func events(
        in segment: NativeActiveTrackObservationWindowSegment
    ) -> [NativeActiveTrackObservationEvent] {
        segment.eventIndices.compactMap { index in
            guard events.indices.contains(index) else { return nil }
            return events[index]
        }
    }

    fileprivate init(
        request: NativeActiveTrackObservationWindowRequest,
        route: NativeActiveTrackObservationWindowRoute,
        outcome: NativeActiveTrackObservationWindowOutcome,
        baseline: NativeActiveTrackObservationBaseline?,
        recording: BluetoothCameraEventRecording?,
        events: [NativeActiveTrackObservationEvent] = [],
        segments: [NativeActiveTrackObservationWindowSegment] = [],
        failureCode: String? = nil
    ) {
        self.request = request
        self.route = route
        self.outcome = outcome
        self.baseline = baseline
        self.recordingStartedUptime = recording?.startedUptime
        self.recordingFinishedUptime = recording?.finishedUptime
        self.recordingEnd = recording?.end
        self.acceptedSampleCount = recording?.acceptedSampleCount ?? 0
        self.rejectedFrameCount = recording?.rejectedFrameCount ?? 0
        self.unchangedFrameCount = recording?.unchangedFrameCount ?? 0
        self.events = Array(events.prefix(BluetoothCameraEventRecorder.maximumSamples))
        self.segments = segments
        self.failureCode = failureCode
    }
}

/// Pure coordinator for a finished passive recorder result. The real BLE
/// owner is responsible for arming/cancelling `BluetoothCameraEventRecorder`;
/// this service performs no subscription, pairing, write, Wi-Fi or image work.
public struct NativeActiveTrackObservationWindowService: Sendable {
    public static let maximumCorrelatedEvents = 128
    public static let maximumBaselineAge: TimeInterval = 5

    public init() {}

    public func run(
        _ request: NativeActiveTrackObservationWindowRequest,
        route: NativeActiveTrackObservationWindowRoute,
        baseline: NativeActiveTrackObservationBaseline?,
        recording: BluetoothCameraEventRecording?
    ) -> NativeActiveTrackObservationWindowResult {
        guard route.isAvailable else {
            return .init(request: request, route: route, outcome: .unavailableRoute,
                         baseline: nil, recording: nil,
                         failureCode: route.code ?? "active_track_observation_route_unavailable")
        }
        guard let baseline,
              validBaseline(baseline, request: request) else {
            return .init(request: request, route: route, outcome: .baselineUnavailable,
                         baseline: baseline, recording: nil,
                         failureCode: "active_track_observation_baseline_missing")
        }
        guard let recording else {
            return .init(request: request, route: route, outcome: .failed,
                         baseline: baseline, recording: nil,
                         failureCode: "active_track_observation_recording_unavailable")
        }
        guard recording.sessionID == request.expectedSessionID,
              recording.peripheralID == request.peripheralID else {
            return .init(request: request, route: route, outcome: .connectionChanged,
                         baseline: baseline, recording: recording,
                         failureCode: "active_track_observation_connection_changed")
        }
        guard recording.startedUptime.isFinite,
              recording.startedUptime >= baseline.capturedUptime,
              (recording.startedUptime + request.windowSeconds).isFinite else {
            return .init(request: request, route: route, outcome: .failed,
                         baseline: baseline, recording: recording,
                         failureCode: "active_track_observation_invalid_clock")
        }

        let end = recording.startedUptime + request.windowSeconds
        let matchingEvents = recording.events.filter {
            $0.sessionID == request.expectedSessionID &&
                $0.peripheralID == request.peripheralID &&
                $0.receivedUptime.isFinite &&
                $0.receivedUptime >= recording.startedUptime &&
                $0.receivedUptime <= end
        }.sorted { lhs, rhs in
            if lhs.receivedUptime == rhs.receivedUptime {
                return lhs.sequence < rhs.sequence
            }
            return lhs.receivedUptime < rhs.receivedUptime
        }
        let foreignEvent = recording.events.contains {
            $0.receivedUptime.isFinite &&
                $0.receivedUptime >= recording.startedUptime &&
                $0.receivedUptime <= end &&
                ($0.sessionID != request.expectedSessionID ||
                 $0.peripheralID != request.peripheralID)
        }
        let binding = Pocket3ActiveTrackObservation.bluetoothBinding(
            sessionID: request.expectedSessionID)
        let projected = matchingEvents.prefix(Self.maximumCorrelatedEvents).map {
            project($0, binding: binding)
        }
        let segments = makeSegments(
            projected, request: request, startedUptime: recording.startedUptime)
        let outcome: NativeActiveTrackObservationWindowOutcome
        let failureCode: String?
        switch recording.end {
        case .connectionChanged:
            outcome = .connectionChanged
            failureCode = recording.failureCode ?? "active_track_observation_connection_changed"
        case _ where foreignEvent:
            outcome = .connectionChanged
            failureCode = "active_track_observation_connection_changed"
        case .cancelled:
            outcome = .cancelled
            failureCode = recording.failureCode ?? "cancelled"
        case .invalidClock:
            outcome = .failed
            failureCode = recording.failureCode ?? "active_track_observation_invalid_clock"
        case .failed:
            outcome = .failed
            failureCode = recording.failureCode ?? "active_track_observation_failed"
        default:
            outcome = projected.isEmpty ? .noEvents : .eventsObserved
            failureCode = recording.failureCode
        }
        return .init(request: request, route: route, outcome: outcome,
                     baseline: baseline, recording: recording,
                     events: Array(projected), segments: segments,
                     failureCode: failureCode)
    }

    private func validBaseline(
        _ baseline: NativeActiveTrackObservationBaseline,
        request: NativeActiveTrackObservationWindowRequest
    ) -> Bool {
        guard baseline.sessionID == request.expectedSessionID,
              baseline.peripheralID == request.peripheralID,
              baseline.capturedUptime.isFinite,
              baseline.capturedUptime >= 0 else { return false }
        let binding = Pocket3ActiveTrackObservation.bluetoothBinding(
            sessionID: request.expectedSessionID)
        let fresh = baseline.activeTrackObservations.filter {
            $0.sessionID == request.expectedSessionID &&
                $0.peripheralID == request.peripheralID &&
                $0.binding == binding &&
                $0.receivedUptime <= baseline.capturedUptime &&
                $0.isFresh(nowUptime: baseline.capturedUptime,
                           maximumAge: Self.maximumBaselineAge)
        }
        guard !fresh.isEmpty else { return false }
        if let cameraStatus = baseline.cameraStatus {
            guard cameraStatus.sessionID == request.expectedSessionID,
                  cameraStatus.peripheralID == request.peripheralID,
                  cameraStatus.receivedUptime <= baseline.capturedUptime,
                  cameraStatus.isFresh(nowUptime: baseline.capturedUptime,
                                       maximumAge: Self.maximumBaselineAge) else {
                return false
            }
        }
        return true
    }

    private func makeSegments(
        _ events: [NativeActiveTrackObservationEvent],
        request: NativeActiveTrackObservationWindowRequest,
        startedUptime: TimeInterval
    ) -> [NativeActiveTrackObservationWindowSegment] {
        let markers = request.markers
        let boundaries = [0] + markers.map(\.offsetSeconds) + [request.windowSeconds]
        let labels: [NativeActiveTrackObservationWindowSegmentLabel] = [
            .beforeFirstOff, .afterOff, .afterOn, .afterFinalOff
        ]
        let states: [NativeActiveTrackOperatorMarkerState?] = [
            nil, .off, .on, .off
        ]
        return (0..<4).map { index in
            let start = boundaries[index]
            let end = boundaries[index + 1]
            let indices = events.indices.filter { eventIndex in
                let offset = events[eventIndex].rawEnvelope.receivedUptime - startedUptime
                if index == 3 {
                    return offset >= start && offset <= end
                }
                return offset >= start && offset < end
            }
            return NativeActiveTrackObservationWindowSegment(
                label: labels[index], startOffsetSeconds: start,
                endOffsetSeconds: end, markerState: states[index],
                eventIndices: Array(indices.prefix(Self.maximumCorrelatedEvents)))
        }
    }

    private func project(
        _ event: BluetoothCameraEvent,
        binding: ContinuousGimbalBinding
    ) -> NativeActiveTrackObservationEvent {
        let active = event.activeTrackObservation(binding: binding)
        let frame = frame(from: event)
        let candidate: Pocket3TrackingCandidateFrame?
        if event.commandID == 0xA6, let frame {
            candidate = Pocket3TrackingCandidateParser.parse(
                frame, sessionID: event.sessionID, peripheralID: event.peripheralID,
                receivedAt: event.receivedAt, receivedUptime: event.receivedUptime)
        } else {
            candidate = nil
        }
        let status: Pocket3CameraStatusObservation?
        if event.commandSet == 0x02, event.commandID == 0x80, let frame {
            status = Pocket3CameraStatusParser.parse(
                frame, sessionID: event.sessionID, peripheralID: event.peripheralID,
                receivedAt: event.receivedAt, receivedUptime: event.receivedUptime)
        } else {
            status = nil
        }
        let kind: NativeActiveTrackObservationEventKind
        switch event.commandID {
        case 0xA5: kind = .a5
        case 0xA6: kind = .a6Candidate
        case 0x89: kind = .a89
        case 0x80 where event.commandSet == 0x02: kind = .cameraStatus
        default: kind = .other
        }
        return NativeActiveTrackObservationEvent(
            rawEnvelope: event, kind: kind,
            activeTrackObservation: active,
            trackingCandidate: candidate, cameraStatus: status)
    }

    private func frame(from event: BluetoothCameraEvent) -> DUMLFrame? {
        guard event.payloadLength >= 0,
              event.payloadLength <= BluetoothCameraEventParser.maximumPayloadBytes,
              event.payloadHex.utf8.count == event.payloadLength * 2,
              let payload = decodeHex(event.payloadHex) else { return nil }
        return DUMLFrame(source: event.source, destination: 0x02,
                         sequence: event.sequence, flags: 0,
                         commandSet: event.commandSet, commandID: event.commandID,
                         payload: payload)
    }

    private func decodeHex(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard bytes.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        result.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else {
                return nil
            }
            result.append((high << 4) | low)
            index += 2
        }
        return result
    }

    private func nibble(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: return value - 48
        case 65...70: return value - 55
        case 97...102: return value - 87
        default: return nil
        }
    }
}
