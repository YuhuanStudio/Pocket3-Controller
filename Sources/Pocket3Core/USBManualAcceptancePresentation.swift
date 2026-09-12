import Foundation

/// Compact, path-free projection of the most recent USB manual acceptance.
/// The full report remains available in the CLI reply, while Diagnostics only
/// needs the verification counters and exact session-fence outcome.
public struct USBManualAcceptanceDiagnostics: Codable, Sendable, Equatable,
    Hashable {
    public let createdAt: Date
    public let metricsPassed: Bool
    public let failureCode: String?
    public let gimbalHoldCount: Int
    public let gimbalStopVerifiedCount: Int
    public let gimbalRestoreVerifiedCount: Int
    public let zoomStopVerified: Bool
    public let zoomRestoreVerified: Bool
    public let reconnectSessionChanged: Bool
    public let oldSessionSuppressed: Bool
    public let newSessionReady: Bool
    public let finalRestoreVerified: Bool
    public let initialDeviceID: String
    public let initialSessionID: String
    public let finalSessionID: String
    public let cameraImagesStored: Bool
    public let physicalMotionVerified: Bool

    public init(report: USBManualAcceptanceReport,
                evaluation: USBManualAcceptanceEvaluation) {
        createdAt = report.createdAt
        metricsPassed = evaluation.metricsPassed
        failureCode = evaluation.failureCode
        gimbalHoldCount = report.gimbalHolds.count
        gimbalStopVerifiedCount = report.gimbalHolds.filter { $0.stop.verified }.count
        gimbalRestoreVerifiedCount = report.gimbalHolds.filter { $0.restore.verified }.count
        zoomStopVerified = report.zoom.stop.verified
        zoomRestoreVerified = report.zoom.restore.verified
        reconnectSessionChanged = report.reconnect.oldBinding.captureSessionID !=
            report.reconnect.newBinding.captureSessionID
        oldSessionSuppressed = report.reconnect.oldOperationSuppressed
        newSessionReady = report.reconnect.newSessionReady
        finalRestoreVerified = evaluation.checks["restore"] == true
        initialDeviceID = report.initialBinding.deviceID
        initialSessionID = report.initialBinding.captureSessionID
        finalSessionID = report.finalBinding.captureSessionID
        cameraImagesStored = report.cameraImagesStored
        physicalMotionVerified = report.physicalMotionVerified
    }
}

/// Shared distance-to-speed mapping for the UVC continuous path.  The UI
/// supplies screen-space x/y; the trajectory uses this normalized magnitude
/// and applies the same dead zone and curve for every input source.
public enum USBManualGimbalControlMapping {
    public static let deadZone: Double = 0.06
    public static let nearInputMagnitude: Double = 0.25
    public static let farInputMagnitude: Double = 0.80

    public static func magnitude(x: Double, y: Double) -> Double? {
        guard x.isFinite, y.isFinite else { return nil }
        let scale = max(1, abs(x), abs(y))
        var horizontal = x / scale
        var vertical = y / scale
        let length = hypot(horizontal, vertical)
        if length > 1 {
            horizontal /= length
            vertical /= length
        }
        return min(1, hypot(horizontal, vertical))
    }

    /// Returns the normalized fraction of the maximum trajectory rate after
    /// the dead zone.  It is intentionally raw UVC motion, not a physical
    /// degrees-per-second claim.
    public static func rateFraction(inputMagnitude: Double,
                                    speed: Double) -> Double? {
        guard inputMagnitude.isFinite, speed.isFinite,
              (0...1).contains(inputMagnitude), (0...1).contains(speed) else {
            return nil
        }
        guard inputMagnitude > deadZone, speed > 0 else { return 0 }
        return (inputMagnitude - deadZone) / (1 - deadZone) * speed
    }
}

public typealias Pocket3USBManualAcceptanceDiagnostics = USBManualAcceptanceDiagnostics
public typealias Pocket3USBManualGimbalControlMapping = USBManualGimbalControlMapping
