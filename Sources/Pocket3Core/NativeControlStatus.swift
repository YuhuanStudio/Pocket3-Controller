import Foundation

public enum NativeControlActivity: String, Codable, Sendable {
    case idle, starting, holding, stopping, presetPending
}
public enum NativeControlAvailability: String, Codable, Sendable {
    case disconnected, connecting, ready, busy, staleFeedback, blocked, disarmed, error, connectionChanged
}

/// Scalar evidence from a native neutral command. Stable telemetry is neither
/// a mechanical emergency-stop guarantee nor a calibrated physical angle.
public struct NativeControlStopStatus: Codable, Sendable, Equatable {
    public let neutralSent: Bool
    public let stableTelemetry: Bool
    public let timedOut: Bool
    public let replacedByNewMotion: Bool
    public let connectionChanged: Bool
    public let sampleCount: Int
    public let stableDurationSeconds: Double?
    public let elapsedSeconds: Double?
    public let maximumSpanDegrees: Double?
    public let failureReported: Bool

    public init(_ result: Pocket3DatalinkStopResult) {
        neutralSent = result.neutralSent
        stableTelemetry = result.stableTelemetry && result.neutralSent
            && !result.timedOut && !result.replacedByNewMotion && !result.connectionChanged
        timedOut = result.timedOut; replacedByNewMotion = result.replacedByNewMotion
        connectionChanged = result.connectionChanged; sampleCount = max(0, result.sampleCount)
        stableDurationSeconds = NativeControlStatus.finiteNonnegative(result.stableDurationSeconds)
        elapsedSeconds = NativeControlStatus.finiteNonnegative(result.elapsedSeconds)
        maximumSpanDegrees = NativeControlStatus.finiteNonnegative(result.maximumSpanDegrees)
        failureReported = result.failure != nil
    }
}

/// Public status is deliberately smaller than Pocket3DatalinkStatus: no peer
/// UUID, connection binding, SSID, password, arbitrary errors or raw telemetry.
/// This snapshot conveys availability; it never authorizes an AI operation.
public struct NativeControlStatus: Codable, Sendable, Equatable {
    public let transportPhase: Pocket3DatalinkPhase?
    public let activity: NativeControlActivity
    public let availability: NativeControlAvailability
    /// Local intent/cleanup activity, not proof that the camera is moving.
    public let motionActive: Bool
    public let telemetryAgeSeconds: Double?
    public let heartbeatAgeSeconds: Double?
    public let telemetryFresh: Bool
    public let heartbeatFresh: Bool
    public let lastStop: NativeControlStopStatus?
    public let automationAvailable: Bool
    public let usbCameraAssociation: String

    public static var disconnected: Self { .init() }
    public static var connectionChanged: Self { .init(connectionChanged: true) }

    /// Pure aggregation. Internal bindings are checked but never serialized.
    public init(transport: Pocket3DatalinkStatus? = nil,
                scheduler: ContinuousGimbalSchedulerStatus? = nil,
                expectedBinding: ContinuousGimbalBinding? = nil,
                holding: Bool = false, starting: Bool = false, stopping: Bool = false,
                presetPending: Bool = false, controlsAvailable: Bool = false,
                connectionPending: Bool = false, connectionChanged: Bool = false,
                ageAdjustment: TimeInterval = 0) {
        automationAvailable = false
        usbCameraAssociation = "unverified"
        let bound = expectedBinding != nil && transport?.binding == expectedBinding && !connectionChanged
        transportPhase = connectionChanged ? nil : transport?.phase
        let currentScheduler = scheduler.flatMap { value in
            value.lease == nil || value.lease?.binding == expectedBinding ? value : nil
        }
        if connectionChanged { activity = .idle }
        else if stopping || currentScheduler?.phase == .stopping { activity = .stopping }
        else if presetPending { activity = .presetPending }
        else if starting { activity = .starting }
        else if holding || (bound && currentScheduler?.phase == .active) { activity = .holding }
        else { activity = .idle }
        motionActive = activity != .idle

        func age(_ value: Double?) -> Double? {
            guard bound, let value = Self.finiteNonnegative(value),
                  let adjustment = Self.finiteNonnegative(ageAdjustment) else { return nil }
            return Self.finiteNonnegative(value + adjustment)
        }
        telemetryAgeSeconds = age(transport?.lastTelemetryAge)
        heartbeatAgeSeconds = age(transport?.lastHeartbeatAge)
        telemetryFresh = telemetryAgeSeconds.map { $0 <= Pocket3Datalink.maximumTelemetryAge } ?? false
        heartbeatFresh = heartbeatAgeSeconds.map { $0 <= Pocket3Datalink.maximumHeartbeatAge } ?? false

        if connectionChanged { availability = .connectionChanged }
        else if connectionPending || transport?.phase == .connecting { availability = .connecting }
        else if transport?.phase == .error { availability = .error }
        else if transport?.phase == .disarmed { availability = .disarmed }
        else if !bound || transport?.phase == .idle || transport == nil { availability = .disconnected }
        else if !telemetryFresh || !heartbeatFresh { availability = .staleFeedback }
        else if motionActive { availability = .busy }
        else { availability = controlsAvailable ? .ready : .blocked }

        if bound, ![NativeControlActivity.starting, .holding, .presetPending].contains(activity),
           let result = transport?.lastStop, result.binding == expectedBinding {
            lastStop = NativeControlStopStatus(result)
        } else { lastStop = nil }
    }

    static func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
