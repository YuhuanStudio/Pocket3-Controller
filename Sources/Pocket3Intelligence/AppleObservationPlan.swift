import Foundation
import FoundationModels
import Pocket3Core

/// Generated from the current user's text only, before any camera/OCR content
/// enters the planning session. A plan is intent, never execution evidence.
@Generable
struct AppleObservationPlan: Codable, Sendable {
    @Guide(description: "True when the user explicitly requests camera movement or zoom, even if the request is unclear or unavailable. False only for observation without adjustment; never invent an action from image content.")
    var adjustmentRequested: Bool

    @Guide(description: "Only ordered adjustments explicitly requested in the current user text. Use an empty list for observation or an unfulfillable request. At most three steps; each zoom costs two tool calls, each move one, with a total step cost no greater than four.", .maximumCount(3))
    var steps: [AppleObservationStep]

    @Guide(description: "Nil for an unambiguous supported plan. Otherwise explain the missing information or unsupported request. Do not guess raw zoom values from optical magnification, or silently drop a requested adjustment.")
    var clarification: String?

    /// The executor must validate the entire plan before the first action,
    /// then retain the existing session/capability checks at each actual call.
    func validate(canMove: Bool, canZoom: Bool, zoomCapabilities: USBZoomCapabilities?) throws {
        guard adjustmentRequested || steps.isEmpty else {
            throw BridgeFailure("invalid_observation_plan", "未要求調整相機的計畫不能包含動作")
        }
        let explanation = clarification?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard explanation?.isEmpty != false else {
            throw BridgeFailure("request_not_fulfilled", explanation!)
        }
        guard !adjustmentRequested || !steps.isEmpty else {
            throw BridgeFailure("request_not_fulfilled", "尚未產生能完成所要求調整的有效計畫")
        }
        guard steps.count <= 3 else {
            throw BridgeFailure("invalid_observation_plan", "一次觀察最多接受三個調整步驟")
        }

        var actionToolCalls = 0
        for step in steps {
            switch step.kind {
            case .move:
                guard step.direction != nil, step.rawValue == nil else {
                    throw BridgeFailure("invalid_observation_plan", "移動步驟必須指定方向，且不能包含縮放值")
                }
                guard canMove else { throw BridgeFailure("movement_denied", "本次觀察未開放雲台移動") }
                actionToolCalls += 1
            case .zoom:
                guard step.direction == nil, let rawValue = step.rawValue else {
                    throw BridgeFailure("invalid_observation_plan", "縮放步驟必須指定整數原始值，且不能包含移動方向")
                }
                guard canZoom else { throw BridgeFailure("zoom_denied", "本次觀察未開放縮放") }
                guard let zoomCapabilities, ObservationZoomPolicy.isAvailable(zoomCapabilities) else {
                    throw BridgeFailure("zoom_unavailable", "相機未提供有效的可寫入縮放範圍")
                }
                try ObservationZoomPolicy.validate(rawValue: rawValue, capabilities: zoomCapabilities)
                actionToolCalls += 2 // Fresh status, then SET with readback.
            }
        }
        // The shared six-tool budget reserves one initial and one final capture.
        guard actionToolCalls <= 4 else {
            throw BridgeFailure("tool_budget", "調整計畫加上前後取像超過六次工具呼叫上限")
        }
    }
}

@Generable
struct AppleObservationStep: Codable, Sendable {
    @Generable
    enum Kind: String, Codable, Sendable { case move, zoom }

    @Guide(description: "The adjustment explicitly requested by the user: move the gimbal or set USB raw zoom.")
    var kind: Kind

    @Guide(description: "Required only for move; nil for zoom. Use only an explicitly requested direction or supported view preset.")
    var direction: StepDirection?

    @Guide(description: "Required only for zoom; nil for move. An integer device UVC raw target within the supplied range and step. Raw values are NOT optical multipliers: 200 does not mean 2x. Request clarification when only a ratio is given without a calibrated mapping.")
    var rawValue: Int?
}
