import Foundation
import CoreGraphics

/// A focus point in the capture device's unrotated, top-left-origin image.
/// Preview-layer conversion must happen before creating this value.
public struct CameraFocusPoint: Sendable, Equatable, Codable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw BridgeFailure("invalid_focus_point", "對焦點須位於影像範圍內")
        }
        self.x = x; self.y = y
    }
    public init(_ point: CGPoint) throws { try self.init(x: Double(point.x), y: Double(point.y)) }
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    private enum CodingKeys: String, CodingKey { case x, y }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: values.decode(Double.self, forKey: .x), y: values.decode(Double.self, forKey: .y))
    }
}

/// Identifies the exact capture lifecycle and video input, not an authorization
/// token. The caller still owns the manual action/interaction permission.
public struct CaptureLifecycleToken: Sendable, Equatable, Codable {
    public let generation: UInt64
    public let sessionID: String
    public let deviceID: String
    public init(generation: UInt64, sessionID: String, deviceID: String) {
        self.generation = generation; self.sessionID = sessionID; self.deviceID = deviceID
    }
    func validate(generation: UInt64, sessionID: String, deviceID: String) throws {
        guard self.generation == generation, !self.sessionID.isEmpty, self.sessionID == sessionID,
              !self.deviceID.isEmpty, self.deviceID == deviceID else {
            throw BridgeFailure("session_changed", "相機連線已改變，請重新選擇對焦點")
        }
    }
}

public enum CaptureFocusMode: String, Codable, Sendable {
    case locked, autoFocus, continuousAutoFocus
}

public struct FocusCapabilities: Codable, Sendable, Equatable {
    public let supportsPoint: Bool
    public let supportsAuto: Bool
    public let supportsContinuous: Bool
    public let currentMode: CaptureFocusMode?
    public let sessionID: String?
    public let sessionToken: CaptureLifecycleToken?
    public var canFocus: Bool { supportsPoint && (supportsAuto || supportsContinuous) && sessionToken != nil }
    public init(supportsPoint: Bool, supportsAuto: Bool, supportsContinuous: Bool,
                currentMode: CaptureFocusMode?, sessionToken: CaptureLifecycleToken?) {
        self.supportsPoint = supportsPoint; self.supportsAuto = supportsAuto; self.supportsContinuous = supportsContinuous
        self.currentMode = currentMode; self.sessionToken = sessionToken; sessionID = sessionToken?.sessionID
    }
    public static let unavailable = Self(supportsPoint: false, supportsAuto: false,
        supportsContinuous: false, currentMode: nil, sessionToken: nil)
}

public struct FocusResult: Codable, Sendable, Equatable {
    public let sessionID: String
    public let requestedPoint: CameraFocusPoint
    public let observedPoint: CameraFocusPoint?
    public let requestedMode: CaptureFocusMode
    public let observedMode: CaptureFocusMode?
    public let pointAndModeConfirmed: Bool
    public let adjustingFocus: Bool
    /// Selecting a point and observing the mode does not prove optical focus.
    public let opticalFocusConfirmed: Bool
    public let verification: String
    public let submittedUptime: TimeInterval
    public let readbackUptime: TimeInterval

    init(sessionID: String, requestedPoint: CameraFocusPoint, observedPoint: CameraFocusPoint?,
         requestedMode: CaptureFocusMode, observedMode: CaptureFocusMode?, adjustingFocus: Bool,
         submittedUptime: TimeInterval, readbackUptime: TimeInterval) {
        self.sessionID = sessionID; self.requestedPoint = requestedPoint; self.observedPoint = observedPoint
        self.requestedMode = requestedMode; self.observedMode = observedMode; self.adjustingFocus = adjustingFocus
        pointAndModeConfirmed = FocusPointPolicy.confirms(point: requestedPoint, mode: requestedMode,
            observedPoint: observedPoint, observedMode: observedMode)
        opticalFocusConfirmed = false
        verification = "avfoundation_point_and_mode_readback_not_optical_focus"
        self.submittedUptime = submittedUptime; self.readbackUptime = readbackUptime
    }
}

enum FocusPointPolicy {
    static func mode(supportsPoint: Bool, supportsAuto: Bool, supportsContinuous: Bool) throws -> CaptureFocusMode {
        guard supportsPoint else { throw BridgeFailure("focus_point_unsupported", "此相機連線未提供點選對焦") }
        if supportsAuto { return .autoFocus }
        if supportsContinuous { return .continuousAutoFocus }
        throw BridgeFailure("focus_mode_unsupported", "此相機連線未提供可套用對焦點的自動對焦模式")
    }
    static func confirms(point: CameraFocusPoint, mode: CaptureFocusMode,
                         observedPoint: CameraFocusPoint?, observedMode: CaptureFocusMode?) -> Bool {
        guard let observedPoint, observedMode == mode else { return false }
        return abs(point.x - observedPoint.x) <= 0.0001 && abs(point.y - observedPoint.y) <= 0.0001
    }
}
