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
}
