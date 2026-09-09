import Foundation
import Testing
import Pocket3Core
@testable import Pocket3Intelligence

@Suite struct AppleObservationPlanTests {
    private let zoom = USBZoomCapabilities(current: 100, minimum: 100, maximum: 400, step: 5, writable: true)
    private func plan(_ steps: [AppleObservationStep], requested: Bool = true, clarification: String? = nil) -> AppleObservationPlan {
        .init(adjustmentRequested: requested, steps: steps, clarification: clarification)
    }
    private func move(_ direction: StepDirection = .right) -> AppleObservationStep {
        .init(kind: .move, direction: direction, rawValue: nil)
    }
    private func set(_ raw: Int = 200) -> AppleObservationStep {
        .init(kind: .zoom, direction: nil, rawValue: raw)
    }
    private func failure(_ plan: AppleObservationPlan, canMove: Bool = true, canZoom: Bool = true,
                         capabilities: USBZoomCapabilities? = nil) -> String? {
        do {
            try plan.validate(canMove: canMove, canZoom: canZoom, zoomCapabilities: capabilities ?? zoom)
            return nil
        } catch { return (error as? BridgeFailure)?.code }
    }

    @Test func observationWithoutMutationNeedsNoControlCapabilities() throws {
        try plan([], requested: false).validate(canMove: false, canZoom: false, zoomCapabilities: nil)
        #expect(failure(plan([set()], requested: false)) == "invalid_observation_plan")
    }

    @Test func requestedAdjustmentCannotSilentlySucceedWithoutExecutableSteps() {
        #expect(failure(plan([])) == "request_not_fulfilled")
        #expect(failure(plan([], clarification: "請提供原始縮放刻度")) == "request_not_fulfilled")
        #expect(failure(plan([set()], clarification: "目前倍率未校準")) == "request_not_fulfilled")
        #expect(failure(plan([], requested: false, clarification: "請釐清需求")) == "request_not_fulfilled")
        #expect(failure(plan([set()], clarification: " \n ")) == nil)
    }

    @Test func stepKindsRequireExactlyTheirOwnParameters() {
        let malformed: [AppleObservationStep] = [
            .init(kind: .move, direction: nil, rawValue: nil),
            .init(kind: .move, direction: .left, rawValue: 200),
            .init(kind: .zoom, direction: .right, rawValue: 200),
            .init(kind: .zoom, direction: nil, rawValue: nil)
        ]
        for step in malformed { #expect(failure(plan([step])) == "invalid_observation_plan") }
    }

    @Test func movementAndZoomPermissionsRemainIndependent() throws {
        try plan([set()]).validate(canMove: false, canZoom: true, zoomCapabilities: zoom)
        try plan([move()]).validate(canMove: true, canZoom: false, zoomCapabilities: nil)
        #expect(failure(plan([move()]), canMove: false) == "movement_denied")
        #expect(failure(plan([set()]), canZoom: false) == "zoom_denied")
        #expect(throws: BridgeFailure.self) {
            try plan([set()]).validate(canMove: false, canZoom: true, zoomCapabilities: nil)
        }
        let readOnly = USBZoomCapabilities(current: 100, minimum: 100, maximum: 400, step: 5, writable: false)
        #expect(failure(plan([set()]), capabilities: readOnly) == "zoom_unavailable")
        let badCurrent = USBZoomCapabilities(current: 0, minimum: 100, maximum: 400, step: 5, writable: true)
        #expect(failure(plan([set()]), capabilities: badCurrent) == "zoom_unavailable")
    }

    @Test func rawZoomIsValidatedWithoutClampingOrConvertingRatios() {
        for raw in [100,150,200,400] { #expect(failure(plan([set(raw)])) == nil) }
        for raw in [-1,2,99,401,Int.max] { #expect(failure(plan([set(raw)])) == "uvc_zoom_out_of_range") }
        #expect(failure(plan([set(151)])) == "uvc_zoom_step_mismatch")
    }

    @Test func fullPlanFitsThreeStepsAndTheSharedSixToolBudget() {
        #expect(failure(plan([move(.left),move(.up),move(.home)])) == nil)
        #expect(failure(plan([set(150),set(200)])) == nil)
        #expect(failure(plan([move(.front),set(150),move(.back)])) == nil)
        #expect(failure(plan([set(150),move(),set(200)])) == "tool_budget")
        #expect(failure(plan([set(),set(),set()])) == "tool_budget")
        #expect(failure(plan([move(),move(),move(),move()])) == "invalid_observation_plan")
        // A valid earlier step does not let an invalid later target pass preflight.
        #expect(failure(plan([move(),set(401)])) == "uvc_zoom_out_of_range")
    }

    @Test func codableRequiresRealBooleansKnownKindsDirectionsAndIntegerTargets() throws {
        let original = plan([set(200),move(.left)])
        let decoded = try JSONDecoder().decode(AppleObservationPlan.self, from: JSONEncoder().encode(original))
        #expect(decoded.adjustmentRequested && decoded.steps.count == 2)
        #expect(decoded.steps[0].kind == .zoom && decoded.steps[0].rawValue == 200)
        #expect(decoded.steps[1].kind == .move && decoded.steps[1].direction == .left)
        try decoded.validate(canMove: true, canZoom: true, zoomCapabilities: zoom)
        let malformed = [
            #"{"adjustmentRequested":"true","steps":[]}"#,
            #"{"adjustmentRequested":true,"steps":[{"kind":"focus"}]}"#,
            #"{"adjustmentRequested":true,"steps":[{"kind":"move","direction":"diagonal"}]}"#,
            #"{"adjustmentRequested":true,"steps":[{"kind":"zoom","rawValue":"200"}]}"#,
            #"{"adjustmentRequested":true,"steps":[{"kind":"zoom","rawValue":true}]}"#,
            #"{"adjustmentRequested":true,"steps":[{"kind":"zoom","rawValue":200.5}]}"#
        ]
        for json in malformed {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(AppleObservationPlan.self, from: Data(json.utf8))
            }
        }
    }
}
