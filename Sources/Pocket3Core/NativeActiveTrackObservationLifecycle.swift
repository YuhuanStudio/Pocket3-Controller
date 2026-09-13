import Foundation

public enum NativeActiveTrackObservationWindowLifecycleAction: String,
    Codable, Sendable, Equatable, CaseIterable {
    case start
    case marker
    case status
    case finish
    case cancel
}

public enum NativeActiveTrackObservationWindowLifecycleError: Error,
    LocalizedError, Codable, Sendable, Equatable {
    case invalidArguments
    case invalidAction
    case invalidIdentity
    case invalidWindow
    case markerRequired
    case markerNotAllowed
    case markerOutsideWindow
    case markerSequence
    case windowAlreadyActive
    case windowNotActive
    case staleSession
    case stalePeer

    public var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "ActiveTrack observation lifecycle arguments are invalid"
        case .invalidAction:
            "Use start, marker, status, finish or cancel"
        case .invalidIdentity:
            "ActiveTrack observation requires an exact BLE session and peer"
        case .invalidWindow:
            "ActiveTrack observation window must be between 0 and 20 seconds"
        case .markerRequired:
            "marker requires state and an absolute monotonic timestamp"
        case .markerNotAllowed:
            "state and timestamp are valid only for marker"
        case .markerOutsideWindow:
            "ActiveTrack marker is outside the armed observation window"
        case .markerSequence:
            "ActiveTrack lifecycle markers must be off, on, off in order"
        case .windowAlreadyActive:
            "An ActiveTrack observation window is already active"
        case .windowNotActive:
            "No ActiveTrack observation window is active"
        case .staleSession:
            "ActiveTrack lifecycle session identity changed"
        case .stalePeer:
            "ActiveTrack lifecycle peer identity changed"
        }
    }
}

/// IPC contract for the interactive lifecycle. Start arms the existing
/// passive recorder; marker calls only record an operator timestamp; status,
/// finish and cancel never submit a camera command.
public struct NativeActiveTrackObservationWindowLifecycleRequest: Codable,
    Sendable, Equatable {
    public static let operation = "validation-wireless-tracking-window-lifecycle"

    public let action: NativeActiveTrackObservationWindowLifecycleAction
    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let windowSeconds: TimeInterval?
    public let markerState: NativeActiveTrackOperatorMarkerState?
    /// Absolute host monotonic uptime, as returned by start status.
    public let markerUptime: TimeInterval?

    public init(
        action: NativeActiveTrackObservationWindowLifecycleAction,
        expectedSessionID: UUID,
        peripheralID: UUID,
        windowSeconds: TimeInterval? = nil,
        markerState: NativeActiveTrackOperatorMarkerState? = nil,
        markerUptime: TimeInterval? = nil
    ) throws {
        switch action {
        case .start:
            guard markerState == nil, markerUptime == nil else {
                throw NativeActiveTrackObservationWindowLifecycleError.markerNotAllowed
            }
            if let windowSeconds {
                guard windowSeconds.isFinite, windowSeconds > 0,
                      windowSeconds <= NativeActiveTrackObservationWindowRequest.maximumWindowSeconds else {
                    throw NativeActiveTrackObservationWindowLifecycleError.invalidWindow
                }
            }
        case .marker:
            guard windowSeconds == nil,
                  let markerState, let markerUptime,
                  markerUptime.isFinite else {
                throw NativeActiveTrackObservationWindowLifecycleError.markerRequired
            }
            _ = markerState
        case .status, .finish, .cancel:
            guard windowSeconds == nil, markerState == nil, markerUptime == nil else {
                throw NativeActiveTrackObservationWindowLifecycleError.markerNotAllowed
            }
        }
        self.action = action
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.windowSeconds = windowSeconds
        self.markerState = markerState
        self.markerUptime = markerUptime
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                  "action", "expectedSessionID", "peripheralID",
                  "windowSeconds", "markerState", "markerUptime"
              ]),
              let actionText = fields["action"]?.string,
              let action = NativeActiveTrackObservationWindowLifecycleAction(rawValue: actionText),
              let sessionText = fields["expectedSessionID"]?.string,
              let expectedSessionID = UUID(uuidString: sessionText),
              let peerText = fields["peripheralID"]?.string,
              let peripheralID = UUID(uuidString: peerText) else {
            throw NativeActiveTrackObservationWindowLifecycleError.invalidArguments
        }
        let windowSeconds = fields["windowSeconds"]?.number
        let markerState = fields["markerState"]?.string.flatMap(
            NativeActiveTrackOperatorMarkerState.init(rawValue:))
        let markerUptime = fields["markerUptime"]?.number
        guard fields["markerState"]?.string == nil || markerState != nil else {
            throw NativeActiveTrackObservationWindowLifecycleError.invalidArguments
        }
        try self.init(action: action, expectedSessionID: expectedSessionID,
                      peripheralID: peripheralID, windowSeconds: windowSeconds,
                      markerState: markerState, markerUptime: markerUptime)
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        while index < cliArguments.count {
            guard index + 1 < cliArguments.count else {
                throw BridgeFailure("usage", "Missing ActiveTrack lifecycle option value")
            }
            let key: String
            switch cliArguments[index] {
            case "--action": key = "action"
            case "--session": key = "expectedSessionID"
            case "--peripheral": key = "peripheralID"
            case "--window": key = "windowSeconds"
            case "--state": key = "markerState"
            case "--at": key = "markerUptime"
            default:
                throw BridgeFailure("usage", "Unknown ActiveTrack lifecycle option")
            }
            guard fields[key] == nil else {
                throw BridgeFailure("usage", "Duplicate ActiveTrack lifecycle option")
            }
            let value = cliArguments[index + 1]
            if key == "windowSeconds" || key == "markerUptime" {
                guard let number = Double(value), number.isFinite else {
                    throw BridgeFailure("usage", "ActiveTrack lifecycle timestamp must be finite")
                }
                fields[key] = .number(number)
            } else {
                fields[key] = .string(value)
            }
            index += 2
        }
        do {
            try self.init(arguments: .object(fields))
        } catch let error as NativeActiveTrackObservationWindowLifecycleError {
            throw BridgeFailure("invalid_active_track_observation_lifecycle",
                                error.localizedDescription)
        }
    }

    public var arguments: JSONValue {
        var fields: [String: JSONValue] = [
            "action": .string(action.rawValue),
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString)
        ]
        if let windowSeconds { fields["windowSeconds"] = .number(windowSeconds) }
        if let markerState { fields["markerState"] = .string(markerState.rawValue) }
        if let markerUptime { fields["markerUptime"] = .number(markerUptime) }
        return .object(fields)
    }

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }
}

public enum NativeActiveTrackObservationWindowLifecyclePhase: String,
    Codable, Sendable, Equatable {
    case armed
    case observing
    case completed
    case cancelled
    case unavailableRoute
    case failed
}

/// Snapshot returned by each lifecycle call. The recording is the existing
/// bounded passive recorder snapshot; it contains no credentials, images or
/// replayable command payload.
public struct NativeActiveTrackObservationWindowLifecycleStatus: Codable,
    Sendable, Equatable {
    public static let operation =
        NativeActiveTrackObservationWindowLifecycleRequest.operation

    public let action: NativeActiveTrackObservationWindowLifecycleAction
    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let phase: NativeActiveTrackObservationWindowLifecyclePhase
    public let route: NativeActiveTrackObservationWindowRoute
    public let baseline: NativeActiveTrackObservationBaseline?
    public let startedUptime: TimeInterval?
    public let markers: [NativeActiveTrackOperatorMarker]
    public let recording: BluetoothCameraEventRecording?
    public let observation: NativeActiveTrackObservationWindowResult?
    public let failureCode: String?

    public var markerCount: Int { markers.count }
    public var routeAvailable: Bool { route.isAvailable }
    public var recordingActive: Bool {
        recording?.end == nil &&
            (phase == .armed || phase == .observing)
    }
    public var completed: Bool { phase == .completed }

    fileprivate init(
        action: NativeActiveTrackObservationWindowLifecycleAction,
        expectedSessionID: UUID,
        peripheralID: UUID,
        phase: NativeActiveTrackObservationWindowLifecyclePhase,
        route: NativeActiveTrackObservationWindowRoute,
        baseline: NativeActiveTrackObservationBaseline?,
        startedUptime: TimeInterval?,
        markers: [NativeActiveTrackOperatorMarker],
        recording: BluetoothCameraEventRecording?,
        observation: NativeActiveTrackObservationWindowResult?,
        failureCode: String?
    ) {
        self.action = action
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.phase = phase
        self.route = route
        self.baseline = baseline
        self.startedUptime = startedUptime
        self.markers = Array(markers.prefix(3))
        self.recording = recording
        self.observation = observation
        self.failureCode = failureCode
    }
}

/// Main-actor-friendly value coordinator for one interactive window. It owns
/// only marker/baseline state; the BLE discovery owner continues to own the
/// single passive recorder and its cancellation.
public struct NativeActiveTrackObservationWindowLifecycleCoordinator: Sendable {
    public static let maximumWindowSeconds =
        NativeActiveTrackObservationWindowRequest.maximumWindowSeconds

    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let windowSeconds: TimeInterval
    public private(set) var phase: NativeActiveTrackObservationWindowLifecyclePhase
    public private(set) var route: NativeActiveTrackObservationWindowRoute
    public private(set) var baseline: NativeActiveTrackObservationBaseline?
    public private(set) var startedUptime: TimeInterval?
    public private(set) var markers: [NativeActiveTrackOperatorMarker] = []
    public private(set) var failureCode: String?

    public init(
        start: NativeActiveTrackObservationWindowLifecycleRequest,
        route: NativeActiveTrackObservationWindowRoute,
        baseline: NativeActiveTrackObservationBaseline?,
        startedUptime: TimeInterval
    ) throws {
        guard start.action == .start else {
            throw NativeActiveTrackObservationWindowLifecycleError.invalidAction
        }
        let windowSeconds = start.windowSeconds ?? Self.maximumWindowSeconds
        guard windowSeconds.isFinite, windowSeconds > 0,
              windowSeconds <= Self.maximumWindowSeconds,
              startedUptime.isFinite, startedUptime >= 0 else {
            throw NativeActiveTrackObservationWindowLifecycleError.invalidWindow
        }
        self.expectedSessionID = start.expectedSessionID
        self.peripheralID = start.peripheralID
        self.windowSeconds = windowSeconds
        self.route = route
        self.baseline = baseline
        self.startedUptime = startedUptime
        self.phase = route.isAvailable ? .armed : .unavailableRoute
    }

    public mutating func mark(
        _ request: NativeActiveTrackObservationWindowLifecycleRequest
    ) throws {
        guard request.action == .marker else {
            throw NativeActiveTrackObservationWindowLifecycleError.invalidAction
        }
        try validateIdentity(request.expectedSessionID, request.peripheralID)
        guard phase == .armed || phase == .observing else {
            throw NativeActiveTrackObservationWindowLifecycleError.windowNotActive
        }
        guard let state = request.markerState,
              let timestamp = request.markerUptime,
              let startedUptime else {
            throw NativeActiveTrackObservationWindowLifecycleError.markerRequired
        }
        let offset = timestamp - startedUptime
        guard offset.isFinite, offset >= 0, offset <= windowSeconds else {
            throw NativeActiveTrackObservationWindowLifecycleError.markerOutsideWindow
        }
        let expectedStates = NativeActiveTrackObservationWindowRequest.requiredMarkerStates
        guard markers.count < expectedStates.count,
              state == expectedStates[markers.count] else {
            throw NativeActiveTrackObservationWindowLifecycleError.markerSequence
        }
        if let previous = markers.last, offset <= previous.offsetSeconds {
            throw NativeActiveTrackObservationWindowLifecycleError.markerSequence
        }
        markers.append(try NativeActiveTrackOperatorMarker(
            state: state, offsetSeconds: offset))
        phase = .observing
    }

    public func update(
        recording: BluetoothCameraEventRecording?,
        action: NativeActiveTrackObservationWindowLifecycleAction = .status
    ) -> NativeActiveTrackObservationWindowLifecycleStatus {
        let observation = partialObservation(recording: recording)
        return status(action: action, recording: recording, observation: observation)
    }

    public mutating func finish(
        recording: BluetoothCameraEventRecording?
    ) -> NativeActiveTrackObservationWindowLifecycleStatus {
        let observation = partialObservation(recording: recording)
        guard markers.count == 3 else {
            phase = .failed
            failureCode = "active_track_observation_markers_incomplete"
            return status(action: .finish, recording: recording,
                          observation: observation)
        }
        if let observation {
            switch observation.outcome {
            case .eventsObserved, .noEvents:
                phase = .completed
            case .connectionChanged:
                phase = .failed
                failureCode = observation.failureCode
            case .cancelled:
                phase = .cancelled
                failureCode = observation.failureCode
            case .unavailableRoute, .baselineUnavailable, .failed:
                phase = .failed
                failureCode = observation.failureCode
            }
        } else {
            phase = .failed
            failureCode = "active_track_observation_recording_unavailable"
        }
        return status(action: .finish, recording: recording,
                      observation: observation)
    }

    public mutating func cancel(
        recording: BluetoothCameraEventRecording?
    ) -> NativeActiveTrackObservationWindowLifecycleStatus {
        phase = .cancelled
        failureCode = "cancelled"
        return status(action: .cancel, recording: recording,
                      observation: partialObservation(recording: recording))
    }

    public func status(
        action: NativeActiveTrackObservationWindowLifecycleAction = .status,
        recording: BluetoothCameraEventRecording? = nil,
        observation: NativeActiveTrackObservationWindowResult? = nil
    ) -> NativeActiveTrackObservationWindowLifecycleStatus {
        NativeActiveTrackObservationWindowLifecycleStatus(
            action: action,
            expectedSessionID: expectedSessionID,
            peripheralID: peripheralID,
            phase: phase,
            route: route,
            baseline: baseline,
            startedUptime: startedUptime,
            markers: markers,
            recording: recording,
            observation: observation,
            failureCode: failureCode)
    }

    private func partialObservation(
        recording: BluetoothCameraEventRecording?
    ) -> NativeActiveTrackObservationWindowResult? {
        guard markers.count == 3 else { return nil }
        guard let markersRequest = try? NativeActiveTrackObservationWindowRequest(
            expectedSessionID: expectedSessionID,
            peripheralID: peripheralID,
            windowSeconds: windowSeconds,
            markers: markers) else { return nil }
        return NativeActiveTrackObservationWindowService().run(
            markersRequest, route: route, baseline: baseline,
            recording: recording)
    }

    private func validateIdentity(_ sessionID: UUID, _ peripheralID: UUID)
        throws {
        guard sessionID == expectedSessionID else {
            throw NativeActiveTrackObservationWindowLifecycleError.staleSession
        }
        guard peripheralID == self.peripheralID else {
            throw NativeActiveTrackObservationWindowLifecycleError.stalePeer
        }
    }
}
