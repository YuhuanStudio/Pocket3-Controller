import Foundation

/// A bounded failure raised before a property query can submit its one
/// subscription. The per-property query result remains responsible for
/// ACK/notification/no-reply evidence; this type covers preflight failures
/// such as busy, not-ready, MTU and backpressure conditions.
public struct BluetoothCameraSettingsQueryFailure: Codable, Sendable,
    Equatable, Identifiable {
    public let id: String
    public let index: Int
    public let property: CameraSettingsProperty
    public let expectedSessionID: UUID
    public let expectedPeripheralID: UUID
    public let code: String
    public let stage: String

    public init(index: Int, property: CameraSettingsProperty,
                expectedSessionID: UUID, expectedPeripheralID: UUID,
                code: String, stage: String = "preflight") {
        self.id = "\(index):\(property.rawValue)"
        self.index = index
        self.property = property
        self.expectedSessionID = expectedSessionID
        self.expectedPeripheralID = expectedPeripheralID
        self.code = code
        self.stage = stage
    }
}

public struct BluetoothCameraPropertyReadinessSnapshot: Sendable,
    Equatable {
    public let sessionID: UUID
    public let peripheralID: UUID?
    public let phase: BluetoothDiscoveryPhase
    public let paired: Bool
    public let registrationAcknowledged: Bool
    public let centralPoweredOn: Bool
    public let peripheralConnected: Bool
    public let fff4NotificationsEnabled: Bool
    public let fff5NotificationsEnabled: Bool
    public let fff5CharacteristicNotifying: Bool
    public let writeWithoutResponse: Bool
    public let canSendWriteWithoutResponse: Bool
    public let writeQueueEmpty: Bool

    public init(sessionID: UUID, peripheralID: UUID?,
                phase: BluetoothDiscoveryPhase, paired: Bool,
                registrationAcknowledged: Bool,
                centralPoweredOn: Bool,
                peripheralConnected: Bool,
                fff4NotificationsEnabled: Bool,
                fff5NotificationsEnabled: Bool,
                fff5CharacteristicNotifying: Bool,
                writeWithoutResponse: Bool,
                canSendWriteWithoutResponse: Bool,
                writeQueueEmpty: Bool) {
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.phase = phase
        self.paired = paired
        self.registrationAcknowledged = registrationAcknowledged
        self.centralPoweredOn = centralPoweredOn
        self.peripheralConnected = peripheralConnected
        self.fff4NotificationsEnabled = fff4NotificationsEnabled
        self.fff5NotificationsEnabled = fff5NotificationsEnabled
        self.fff5CharacteristicNotifying = fff5CharacteristicNotifying
        self.writeWithoutResponse = writeWithoutResponse
        self.canSendWriteWithoutResponse = canSendWriteWithoutResponse
        self.writeQueueEmpty = writeQueueEmpty
    }
}

public enum BluetoothCameraPropertyReadinessDecision: String, Sendable,
    Equatable {
    case wait
    case ready
    case timeout
    case sessionChanged = "session_changed"
}

public enum BluetoothCameraSettingsReadbackState: String, Codable, Sendable,
    Equatable {
    case notStarted = "not_started"
    case partial
    case complete
}

/// Pure completion projection shared by the App response and offline tests.
/// An empty result is never complete, even if no error string was produced.
public struct BluetoothCameraSettingsReadSummary: Codable, Sendable,
    Equatable {
    public let completed: Bool
    public let partial: Bool
    public let state: BluetoothCameraSettingsReadbackState
    public let routeAvailable: Bool
    public let attemptedPropertyCount: Int
    public let expectedPropertyCount: Int

    public init(
        routeAvailable: Bool,
        issuePresent: Bool,
        results: [BluetoothCameraPropertyQueryResult],
        failures: [BluetoothCameraSettingsQueryFailure]
    ) {
        self.routeAvailable = routeAvailable
        expectedPropertyCount = BluetoothCameraSettingsReadPlan.orderedProperties.count
        attemptedPropertyCount = results.count + failures.count
        completed = routeAvailable && !issuePresent && failures.isEmpty &&
            results.count == expectedPropertyCount &&
            results.allSatisfy(BluetoothCameraSettingsReadPlan.hasTypedReadback)
        partial = attemptedPropertyCount > 0 && !completed
        state = completed ? .complete : partial ? .partial : .notStarted
    }
}

/// The bounded order for the explicit developer read-settings pass.
///
/// `cam_video_param_v2` is first because the pinned Kaze source documents its
/// named-property layout and the Pocket 3 campaign has already observed it.
/// The two `camcap_*` capability names remain in the allowlist, but a missing
/// capability notification must not prevent the known property or later
/// properties from being attempted.
public enum BluetoothCameraSettingsReadPlan {
    /// Keep this explicit so adding a future property cannot silently make
    /// the read pass unbounded. The current allowlist contains eleven names.
    public static let maximumPropertyCount = 11
    /// Readiness is allowed to settle briefly before each independent
    /// subscription, but it cannot extend the 24-second total plan window.
    public static let propertyReadinessTimeout: TimeInterval = 0.5
    /// Each query owns a two-second notification window. The extra two
    /// seconds cover scheduling between independent subscriptions while still
    /// bounding the total developer operation.
    public static let maximumDuration: TimeInterval =
        TimeInterval(maximumPropertyCount * 2 + 2)

    public static var orderedProperties: [CameraSettingsProperty] {
        let preferred: [CameraSettingsProperty] = [.videoParameters]
        let remainder = CameraSettingsProperty.allCases.filter {
            !preferred.contains($0)
        }
        return Array((preferred + remainder).prefix(maximumPropertyCount))
    }

    /// A timeout or missing named-property notification is local to that
    /// property. Only cancellation or an exact session/peer change fences the
    /// next independent subscription.
    public static func shouldContinue(
        after result: BluetoothCameraPropertyQueryResult
    ) -> Bool {
        !result.cancelled && !result.connectionChanged
    }

    public static func hasTypedReadback(
        _ result: BluetoothCameraPropertyQueryResult
    ) -> Bool {
        result.failure == nil && result.propertyReceived && result.observed != nil
    }

    public static func readinessDecision(
        expectedSessionID: UUID,
        expectedPeripheralID: UUID,
        snapshot: BluetoothCameraPropertyReadinessSnapshot,
        now: TimeInterval,
        deadline: TimeInterval
    ) -> BluetoothCameraPropertyReadinessDecision {
        guard snapshot.sessionID == expectedSessionID,
              snapshot.peripheralID == nil ||
                snapshot.peripheralID == expectedPeripheralID else {
            return .sessionChanged
        }
        guard now.isFinite, deadline.isFinite, now >= 0, deadline >= now else {
            return .timeout
        }
        let routeReady = snapshot.phase == .gattPaired && snapshot.paired &&
            snapshot.registrationAcknowledged && snapshot.centralPoweredOn &&
            snapshot.peripheralConnected &&
            snapshot.fff4NotificationsEnabled &&
            snapshot.fff5NotificationsEnabled && snapshot.fff5CharacteristicNotifying &&
            snapshot.writeWithoutResponse &&
            snapshot.canSendWriteWithoutResponse && snapshot.writeQueueEmpty
        if routeReady { return .ready }
        return now >= deadline ? .timeout : .wait
    }
}
