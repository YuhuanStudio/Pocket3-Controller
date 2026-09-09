import Foundation

/// The task requested for this answer, independent of the camera's standing
/// permissions. Selecting assistance never grants a missing hardware capability.
public enum ObservationIntent: String, Codable, Sendable, CaseIterable {
    case observe
    case assistFraming

    var permitsCameraAdjustment: Bool { self == .assistFraming }
}

/// Identifies the actual model responsibilities. A controller role does not
/// itself prove a camera action; only the action ledger can establish that.
public struct ObservationExecutionRoles: Codable, Sendable, Equatable {
    public let controllerEngine: String?
    public let answerEngine: String
    public let finalFrameRefresh: String?

    public init(controllerEngine: String? = nil, answerEngine: String, finalFrameRefresh: String? = nil) {
        self.controllerEngine = controllerEngine
        self.answerEngine = answerEngine
        self.finalFrameRefresh = finalFrameRefresh
    }

    static func route(selectedEngine: String, intent: ObservationIntent = .observe, canMove: Bool, canZoom: Bool) -> Self {
        let canAdjust = intent.permitsCameraAdjustment && (canMove || canZoom)
        if selectedEngine == "apple", canAdjust {
            return .init(controllerEngine: "mlx", answerEngine: "apple", finalFrameRefresh: "app")
        }
        return .init(controllerEngine: canAdjust ? selectedEngine : nil, answerEngine: selectedEngine)
    }
}
