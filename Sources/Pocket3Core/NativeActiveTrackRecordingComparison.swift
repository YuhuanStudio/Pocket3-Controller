import CryptoKit
import Foundation

/// Label supplied by the operator for an offline recording. It is a test
/// condition only; it never claims that ActiveTrack was enabled by a command.
public enum NativeActiveTrackRecordingLabel: String, Codable, Sendable,
    Equatable, CaseIterable {
    case on
    case off
}

public struct NativeActiveTrackRecordingRoute: Codable, Sendable, Equatable,
    Hashable, Comparable {
    public let source: UInt8
    public let commandSet: UInt8
    public let commandID: UInt8

    public init(source: UInt8, commandSet: UInt8, commandID: UInt8) {
        self.source = source
        self.commandSet = commandSet
        self.commandID = commandID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.commandSet != rhs.commandSet {
            return lhs.commandSet < rhs.commandSet
        }
        return lhs.commandID < rhs.commandID
    }
}

/// Scalar payload evidence for one command route. Individual payloads are
/// represented by first/last and aggregate SHA-256 signatures so a 300-event
/// recording stays bounded while changes remain comparable.
public struct NativeActiveTrackPayloadSignature: Codable, Sendable, Equatable {
    public let route: NativeActiveTrackRecordingRoute
    public let eventCount: Int
    public let distinctPayloadCount: Int
    public let minimumPayloadLength: Int?
    public let maximumPayloadLength: Int?
    public let firstReceivedUptime: TimeInterval?
    public let lastReceivedUptime: TimeInterval?
    public let activeSpanSeconds: TimeInterval?
    public let activeRatePerSecond: Double?
    public let firstPayloadSHA256: String?
    public let lastPayloadSHA256: String?
    public let distinctPayloadDigestSHA256: String?

    fileprivate init(route: NativeActiveTrackRecordingRoute,
                     events: [BluetoothCameraEvent]) {
        self.route = route
        self.eventCount = events.count
        let payloads = events.map { event -> (length: Int, hash: String) in
            let data = Self.decodeHex(event.payloadHex) ?? Data(event.payloadHex.utf8)
            return (event.payloadLength, Self.sha256(data))
        }
        let unique = Set(payloads.map(\.hash)).sorted()
        self.distinctPayloadCount = unique.count
        self.minimumPayloadLength = payloads.map(\.length).min()
        self.maximumPayloadLength = payloads.map(\.length).max()
        let times = events.map(\.receivedUptime).filter(\.isFinite)
        self.firstReceivedUptime = times.min()
        self.lastReceivedUptime = times.max()
        if let firstReceivedUptime, let lastReceivedUptime,
           lastReceivedUptime >= firstReceivedUptime {
            let span = lastReceivedUptime - firstReceivedUptime
            self.activeSpanSeconds = span
            self.activeRatePerSecond = span > 0 ? Double(events.count) / span : nil
        } else {
            self.activeSpanSeconds = nil
            self.activeRatePerSecond = nil
        }
        self.firstPayloadSHA256 = payloads.first?.hash
        self.lastPayloadSHA256 = payloads.last?.hash
        self.distinctPayloadDigestSHA256 = unique.isEmpty
            ? nil : Self.sha256(Data(unique.joined(separator: ",").utf8))
    }

    fileprivate static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func decodeHex(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard bytes.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        result.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]),
                  let low = nibble(bytes[index + 1]) else { return nil }
            result.append((high << 4) | low)
            index += 2
        }
        return result
    }

    fileprivate static func nibble(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: return value - 48
        case 65...70: return value - 55
        case 97...102: return value - 87
        default: return nil
        }
    }
}

/// Bounded scalar projection of one passive recording. Raw recorder envelopes
/// are retained up to the existing 512-event bound; typed A5/A6/A89/status
/// fields are strict projections and remain candidate/readback evidence only.
public struct NativeActiveTrackRecordingProjection: Codable, Sendable,
    Equatable {
    public static let maximumRawEvents = BluetoothCameraEventRecorder.maximumSamples
    public static let maximumTypedObservations = 64

    public let label: NativeActiveTrackRecordingLabel
    public let sessionID: UUID
    public let peripheralID: UUID
    public let startedUptime: TimeInterval
    public let finishedUptime: TimeInterval?
    public let durationSeconds: TimeInterval?
    public let acceptedSampleCount: Int
    public let rejectedFrameCount: Int
    public let unchangedFrameCount: Int
    public let rawEvents: [BluetoothCameraEvent]
    public let eventRatePerSecond: Double?
    public let routes: [NativeActiveTrackPayloadSignature]
    public let a5Observations: [Pocket3ActiveTrackObservation]
    public let a6Candidates: [Pocket3TrackingCandidateFrame]
    public let a89Observations: [Pocket3ActiveTrackObservation]
    public let cameraStatusChanges: [Pocket3CameraStatusObservation]
    public let a89Boxes: [Pocket3TrackingBox]
    public let a89TagRaw: [UInt8]

    public init(recording: BluetoothCameraEventRecording,
                label: NativeActiveTrackRecordingLabel) {
        let end = recording.finishedUptime ?? recording.events.last?.receivedUptime
        let duration: TimeInterval?
        if let end, end.isFinite, recording.startedUptime.isFinite,
           end >= recording.startedUptime {
            duration = end - recording.startedUptime
        } else {
            duration = nil
        }
        self.init(
            label: label,
            sessionID: recording.sessionID,
            peripheralID: recording.peripheralID,
            startedUptime: recording.startedUptime,
            finishedUptime: recording.finishedUptime,
            durationSeconds: duration,
            acceptedSampleCount: recording.acceptedSampleCount,
            rejectedFrameCount: recording.rejectedFrameCount,
            unchangedFrameCount: recording.unchangedFrameCount,
            events: recording.events)
    }

    /// Builds a projection for one marker segment. `durationSeconds` may be
    /// supplied when the segment is assembled from disjoint off intervals.
    public init(
        label: NativeActiveTrackRecordingLabel,
        sessionID: UUID,
        peripheralID: UUID,
        startedUptime: TimeInterval,
        finishedUptime: TimeInterval?,
        durationSeconds: TimeInterval?,
        acceptedSampleCount: Int,
        rejectedFrameCount: Int = 0,
        unchangedFrameCount: Int = 0,
        events: [BluetoothCameraEvent]
    ) {
        self.label = label
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.startedUptime = startedUptime
        self.finishedUptime = finishedUptime
        self.durationSeconds = durationSeconds
        self.acceptedSampleCount = max(0, acceptedSampleCount)
        self.rejectedFrameCount = max(0, rejectedFrameCount)
        self.unchangedFrameCount = max(0, unchangedFrameCount)
        let bounded = Array(events.prefix(Self.maximumRawEvents))
        self.rawEvents = bounded
        self.eventRatePerSecond = durationSeconds.flatMap {
            $0.isFinite && $0 > 0 ? Double(bounded.count) / $0 : nil
        }
        let grouped = Dictionary(grouping: bounded) {
            NativeActiveTrackRecordingRoute(
                source: $0.source, commandSet: $0.commandSet,
                commandID: $0.commandID)
        }
        self.routes = grouped.keys.sorted().map {
            NativeActiveTrackPayloadSignature(route: $0, events: grouped[$0] ?? [])
        }

        let binding = Pocket3ActiveTrackObservation.bluetoothBinding(
            sessionID: sessionID)
        let active = bounded.compactMap {
            $0.activeTrackObservation(binding: binding)
        }
        self.a5Observations = Array(active.filter { $0.commandID == 0xA5 }
            .suffix(Self.maximumTypedObservations))
        self.a89Observations = Array(active.filter { $0.commandID == 0x89 }
            .suffix(Self.maximumTypedObservations))
        self.a89Boxes = Array(self.a89Observations.compactMap(\.box)
            .suffix(Self.maximumTypedObservations))
        self.a89TagRaw = Array(self.a89Observations.compactMap(\.tagRaw)
            .suffix(Self.maximumTypedObservations))

        self.a6Candidates = Array(bounded.compactMap { event in
            guard event.commandSet == 0x02, event.commandID == 0xA6,
                  let frame = Self.frame(from: event) else { return nil }
            return Pocket3TrackingCandidateParser.parse(
                frame, sessionID: event.sessionID,
                peripheralID: event.peripheralID,
                receivedAt: event.receivedAt,
                receivedUptime: event.receivedUptime)
        }.suffix(Self.maximumTypedObservations))
        self.cameraStatusChanges = Array(bounded.compactMap { event in
            guard event.commandSet == 0x02, event.commandID == 0x80,
                  let frame = Self.frame(from: event) else { return nil }
            return Pocket3CameraStatusParser.parse(
                frame, sessionID: event.sessionID,
                peripheralID: event.peripheralID,
                receivedAt: event.receivedAt,
                receivedUptime: event.receivedUptime)
        }.suffix(Self.maximumTypedObservations))
    }

    public var eventCount: Int { rawEvents.count }
    public var routeCount: Int { routes.count }

    private static func frame(from event: BluetoothCameraEvent) -> DUMLFrame? {
        guard event.payloadLength >= 0,
              event.payloadLength <= BluetoothCameraEventParser.maximumPayloadBytes,
              event.payloadHex.utf8.count == event.payloadLength * 2,
              let payload = NativeActiveTrackPayloadSignature.decodeHex(
                event.payloadHex) else { return nil }
        return DUMLFrame(
            source: event.source, destination: 0x02, sequence: event.sequence,
            flags: 0, commandSet: event.commandSet, commandID: event.commandID,
            payload: payload)
    }
}

public struct NativeActiveTrackRecordingRouteDelta: Codable, Sendable,
    Equatable {
    public let route: NativeActiveTrackRecordingRoute
    public let onCount: Int
    public let offCount: Int
    public let countDelta: Int
    public let onRatePerSecond: Double?
    public let offRatePerSecond: Double?
    public let rateDeltaPerSecond: Double?
    public let onDistinctPayloadCount: Int
    public let offDistinctPayloadCount: Int
    public let payloadDigestChanged: Bool
    public let onActiveSpanSeconds: TimeInterval?
    public let offActiveSpanSeconds: TimeInterval?
    public let activeSpanDeltaSeconds: TimeInterval?
    public let onActiveRatePerSecond: Double?
    public let offActiveRatePerSecond: Double?
    public let activeRateDeltaPerSecond: Double?
    public let onFirstPayloadSHA256: String?
    public let offFirstPayloadSHA256: String?
    public let onLastPayloadSHA256: String?
    public let offLastPayloadSHA256: String?

    fileprivate init(route: NativeActiveTrackRecordingRoute,
                     on: NativeActiveTrackPayloadSignature?,
                     off: NativeActiveTrackPayloadSignature?,
                     onDuration: TimeInterval?,
                     offDuration: TimeInterval?) {
        self.route = route
        self.onCount = on?.eventCount ?? 0
        self.offCount = off?.eventCount ?? 0
        self.countDelta = self.onCount - self.offCount
        self.onRatePerSecond = Self.rate(on?.eventCount, duration: onDuration)
        self.offRatePerSecond = Self.rate(off?.eventCount, duration: offDuration)
        if let onRate = onRatePerSecond, let offRate = offRatePerSecond {
            self.rateDeltaPerSecond = onRate - offRate
        } else {
            self.rateDeltaPerSecond = nil
        }
        self.onDistinctPayloadCount = on?.distinctPayloadCount ?? 0
        self.offDistinctPayloadCount = off?.distinctPayloadCount ?? 0
        self.payloadDigestChanged = on?.distinctPayloadDigestSHA256 !=
            off?.distinctPayloadDigestSHA256
        self.onActiveSpanSeconds = on?.activeSpanSeconds
        self.offActiveSpanSeconds = off?.activeSpanSeconds
        if let onSpan = on?.activeSpanSeconds,
           let offSpan = off?.activeSpanSeconds {
            self.activeSpanDeltaSeconds = onSpan - offSpan
        } else {
            self.activeSpanDeltaSeconds = nil
        }
        self.onActiveRatePerSecond = on?.activeRatePerSecond
        self.offActiveRatePerSecond = off?.activeRatePerSecond
        if let onRate = on?.activeRatePerSecond,
           let offRate = off?.activeRatePerSecond {
            self.activeRateDeltaPerSecond = onRate - offRate
        } else {
            self.activeRateDeltaPerSecond = nil
        }
        self.onFirstPayloadSHA256 = on?.firstPayloadSHA256
        self.offFirstPayloadSHA256 = off?.firstPayloadSHA256
        self.onLastPayloadSHA256 = on?.lastPayloadSHA256
        self.offLastPayloadSHA256 = off?.lastPayloadSHA256
    }

    private static func rate(_ count: Int?, duration: TimeInterval?) -> Double? {
        guard let count, let duration, duration.isFinite, duration > 0 else {
            return nil
        }
        return Double(count) / duration
    }
}

public enum NativeActiveTrackRecordingComparisonAssessment: String,
    Codable, Sendable, Equatable {
    case insufficientEvidence
    case noObservedDifference
    case scalarDifferenceObserved
    case mixedDynamicTraffic
}

public struct NativeActiveTrackRecordingFieldDelta: Codable, Sendable,
    Equatable {
    public let field: String
    public let onValue: String?
    public let offValue: String?
    public let changed: Bool

    fileprivate init(field: String, onValue: String?, offValue: String?) {
        self.field = field
        self.onValue = onValue
        self.offValue = offValue
        self.changed = onValue != offValue
    }
}

/// Scalar comparison between an operator-labelled ON recording and an OFF
/// recording. A comparison is evidence about observed envelopes only; it does
/// not infer causality or establish that a tracking writer ran.
public struct NativeActiveTrackRecordingComparison: Codable, Sendable,
    Equatable {
    public let comparable: Bool
    public let identityMatch: Bool
    public let onSessionID: UUID
    public let offSessionID: UUID
    public let onPeripheralID: UUID
    public let offPeripheralID: UUID
    public let onEventCount: Int
    public let offEventCount: Int
    public let onEventRatePerSecond: Double?
    public let offEventRatePerSecond: Double?
    public let routeDeltas: [NativeActiveTrackRecordingRouteDelta]
    public let fieldDeltas: [NativeActiveTrackRecordingFieldDelta]
    public let onA89Boxes: [Pocket3TrackingBox]
    public let offA89Boxes: [Pocket3TrackingBox]
    public let onA89TagRaw: [UInt8]
    public let offA89TagRaw: [UInt8]
    public let onA6CandidateCount: Int
    public let offA6CandidateCount: Int
    /// A scalar classifier aid only. It does not infer that tracking caused
    /// any difference; for example, the artifact pair has both 02/89 and
    /// unrelated 04/05 traffic changes and is therefore mixed.
    public let assessment: NativeActiveTrackRecordingComparisonAssessment
    public let changedRouteCount: Int
    public let changedActiveTrackRouteCount: Int
    public let changedNonActiveRouteCount: Int
    public let confoundingRoutes: [NativeActiveTrackRecordingRoute]
    public let claimsTrackingCausality: Bool
    public let failureCode: String?

    fileprivate init(on: NativeActiveTrackRecordingProjection,
                     off: NativeActiveTrackRecordingProjection) {
        self.identityMatch = on.sessionID == off.sessionID &&
            on.peripheralID == off.peripheralID
        self.comparable = identityMatch && on.durationSeconds != nil &&
            off.durationSeconds != nil
        self.onSessionID = on.sessionID
        self.offSessionID = off.sessionID
        self.onPeripheralID = on.peripheralID
        self.offPeripheralID = off.peripheralID
        self.onEventCount = on.eventCount
        self.offEventCount = off.eventCount
        self.onEventRatePerSecond = on.eventRatePerSecond
        self.offEventRatePerSecond = off.eventRatePerSecond
        let onRoutes = Dictionary(uniqueKeysWithValues: on.routes.map { ($0.route, $0) })
        let offRoutes = Dictionary(uniqueKeysWithValues: off.routes.map { ($0.route, $0) })
        let allRoutes = Set(onRoutes.keys).union(offRoutes.keys).sorted()
        self.routeDeltas = allRoutes.map { route in
            NativeActiveTrackRecordingRouteDelta(
                route: route, on: onRoutes[route], off: offRoutes[route],
                onDuration: on.durationSeconds,
                offDuration: off.durationSeconds)
        }
        self.fieldDeltas = [
            Self.delta("a5State", on: Self.a5Value(on.a5Observations.last),
                       off: Self.a5Value(off.a5Observations.last)),
            Self.delta("a89Box", on: Self.boxValue(on.a89Boxes.last),
                       off: Self.boxValue(off.a89Boxes.last)),
            Self.delta("a89TagRaw", on: on.a89TagRaw.last.map(String.init),
                       off: off.a89TagRaw.last.map(String.init)),
            Self.delta("a6Payload", on: on.a6Candidates.last?.payloadHex,
                       off: off.a6Candidates.last?.payloadHex),
            Self.delta("cameraStatusByte",
                       on: on.cameraStatusChanges.last.map { String(format: "%02x", $0.statusByte) },
                       off: off.cameraStatusChanges.last.map { String(format: "%02x", $0.statusByte) })
        ].filter { $0.onValue != nil || $0.offValue != nil }
        self.onA89Boxes = on.a89Boxes
        self.offA89Boxes = off.a89Boxes
        self.onA89TagRaw = on.a89TagRaw
        self.offA89TagRaw = off.a89TagRaw
        self.onA6CandidateCount = on.a6Candidates.count
        self.offA6CandidateCount = off.a6Candidates.count
        let changed = routeDeltas.filter {
            $0.countDelta != 0 || $0.payloadDigestChanged
        }
        self.changedRouteCount = changed.count
        let activeChanged = changed.filter(Self.isActiveTrackRoute)
        let nonActiveChanged = changed.filter { !Self.isActiveTrackRoute($0) }
        self.changedActiveTrackRouteCount = activeChanged.count
        self.changedNonActiveRouteCount = nonActiveChanged.count
        self.confoundingRoutes = nonActiveChanged.map(\.route).prefix(8).map { $0 }
        if !identityMatch || !comparable {
            self.assessment = .insufficientEvidence
        } else if changed.isEmpty {
            self.assessment = .noObservedDifference
        } else if !nonActiveChanged.isEmpty {
            self.assessment = .mixedDynamicTraffic
        } else {
            self.assessment = .scalarDifferenceObserved
        }
        self.claimsTrackingCausality = false
        self.failureCode = !identityMatch
            ? "active_track_recording_identity_mismatch"
            : !comparable ? "active_track_recording_invalid_clock" : nil
    }

    private static func delta(_ field: String, on: String?, off: String?)
        -> NativeActiveTrackRecordingFieldDelta {
        NativeActiveTrackRecordingFieldDelta(field: field, onValue: on,
                                             offValue: off)
    }

    private static func isActiveTrackRoute(
        _ delta: NativeActiveTrackRecordingRouteDelta
    ) -> Bool {
        delta.route.commandSet == 0x02 &&
            [0x80, 0x89, 0xA5, 0xA6].contains(delta.route.commandID)
    }

    private static func a5Value(_ observation: Pocket3ActiveTrackObservation?)
        -> String? {
        guard let observation else { return nil }
        switch observation.state {
        case .idle: return "idle"
        case .locked(let box): return "locked:" + (boxValue(box) ?? "none")
        case .subjectBox(let box): return "subjectBox:" + (boxValue(box) ?? "none")
        case .unknown(_, let raw): return "unknown:" + raw.map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func boxValue(_ box: Pocket3TrackingBox?) -> String? {
        guard let box else { return nil }
        return String(format: "%.6f,%.6f,%.6f,%.6f",
                      box.centerX, box.centerY, box.width, box.height)
    }
}

public enum NativeActiveTrackRecordingComparator {
    public static func project(
        _ recording: BluetoothCameraEventRecording,
        label: NativeActiveTrackRecordingLabel
    ) -> NativeActiveTrackRecordingProjection {
        NativeActiveTrackRecordingProjection(recording: recording, label: label)
    }

    public static func compare(
        on: BluetoothCameraEventRecording,
        off: BluetoothCameraEventRecording
    ) -> NativeActiveTrackRecordingComparison {
        NativeActiveTrackRecordingComparison(
            on: project(on, label: .on), off: project(off, label: .off))
    }

    /// Compares marker subsets from one lifecycle window. Durations are
    /// explicit because the OFF condition may be split before/after ON.
    public static func compare(
        onEvents: [BluetoothCameraEvent],
        offEvents: [BluetoothCameraEvent],
        sessionID: UUID,
        peripheralID: UUID,
        onDurationSeconds: TimeInterval?,
        offDurationSeconds: TimeInterval?,
        startedUptime: TimeInterval = 0
    ) -> NativeActiveTrackRecordingComparison {
        let on = NativeActiveTrackRecordingProjection(
            label: .on, sessionID: sessionID, peripheralID: peripheralID,
            startedUptime: startedUptime, finishedUptime: nil,
            durationSeconds: onDurationSeconds,
            acceptedSampleCount: onEvents.count, events: onEvents)
        let off = NativeActiveTrackRecordingProjection(
            label: .off, sessionID: sessionID, peripheralID: peripheralID,
            startedUptime: startedUptime, finishedUptime: nil,
            durationSeconds: offDurationSeconds,
            acceptedSampleCount: offEvents.count, events: offEvents)
        return NativeActiveTrackRecordingComparison(on: on, off: off)
    }
}
