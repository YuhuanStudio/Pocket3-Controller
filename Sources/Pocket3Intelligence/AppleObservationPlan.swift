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

    @Guide(description: "Nil when the user gives a direction, asks to zoom in/out a little, or gives an explicit raw zoom value. Only explain missing target information or an exact optical ratio without a raw value. Never assess hardware support, access or numeric range: the App validates these, not the model.")
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
            case .zoomIn, .zoomOut:
                guard step.direction == nil, step.rawValue == nil else {
                    throw BridgeFailure("invalid_observation_plan", "相對縮放不能包含移動方向或原始目標值")
                }
                guard canZoom else { throw BridgeFailure("zoom_denied", "本次觀察未開放縮放") }
                guard let zoomCapabilities else { throw BridgeFailure("zoom_unavailable", "相機未提供縮放能力") }
                _ = try Self.relativeZoomBounds(zoomCapabilities)
                // Do not evaluate an end-stop using the initial current value:
                // an earlier step may change it. Resolve after fresh runtime GET.
                actionToolCalls += 2
            }
        }
        // The shared six-tool budget reserves one initial and one final capture.
        guard actionToolCalls <= 4 else {
            throw BridgeFailure("tool_budget", "調整計畫加上前後取像超過六次工具呼叫上限")
        }
    }

    /// App-defined relative travel in device raw units, not a magnification or
    /// optical distance. The executor supplies fresh capabilities for this step.
    static func relativeZoomTarget(increase: Bool, capabilities: USBZoomCapabilities) throws -> Int {
        let (minimum, maximum, step) = try relativeZoomBounds(capabilities)
        let distance = max(Double(step), Double(maximum - minimum) * 0.25)
        let desired = Double(capabilities.current) + (increase ? distance : -distance)
        let grid = (desired - Double(minimum)) / Double(step)
        // Round towards the requested direction on the min+n*step grid. The
        // maximum itself need not be an advertised grid point.
        let index = Int(increase ? ceil(grid) : floor(grid))
        let boundedIndex = min((maximum - minimum) / step, max(0, index))
        let target = minimum + boundedIndex * step
        guard increase ? target > capabilities.current : target < capabilities.current else {
            throw BridgeFailure("uvc_zoom_out_of_range", "已到此方向可用的縮放界限")
        }
        try ObservationZoomPolicy.validate(rawValue: target, capabilities: capabilities)
        return target
    }

    private static func relativeZoomBounds(_ capabilities: USBZoomCapabilities) throws -> (Int, Int, Int) {
        guard capabilities.writable, let minimum = capabilities.minimum, let maximum = capabilities.maximum,
              (0...65535).contains(minimum), (0...65535).contains(maximum), minimum <= maximum,
              (minimum...maximum).contains(capabilities.current) else {
            throw BridgeFailure("zoom_unavailable", "相機未提供有效的可寫入縮放範圍")
        }
        guard let step = capabilities.step, (1...65535).contains(step) else {
            throw BridgeFailure("uvc_zoom_step_unavailable", "相對縮放需要裝置提供有效的正值步進")
        }
        return (minimum, maximum, step)
    }
}

@Generable
struct AppleObservationStep: Codable, Sendable {
    @Generable
    enum Kind: String, Codable, Sendable { case move, zoom, zoomIn, zoomOut }

    @Guide(description: "move for an explicitly requested gimbal direction; zoom for an explicit integer raw target; zoomIn for natural requests to zoom in or get closer a little; zoomOut for zooming out or a wider view. The App computes relative raw travel. An exact optical ratio without a raw target needs clarification, not a guessed target.")
    var kind: Kind

    @Guide(description: "Required only for move; nil for zoom, zoomIn and zoomOut. Use only an explicitly requested direction or supported view preset.")
    var direction: StepDirection?

    @Guide(description: "Required only for zoom; nil for move, zoomIn and zoomOut. Copy the exact integer raw value requested by the user without changing it or judging its range. The App validates range and step. Raw values are NOT optical multipliers: 200 does not mean 2x.")
    var rawValue: Int?
}
