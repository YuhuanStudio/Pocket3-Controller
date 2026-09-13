import Foundation

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
