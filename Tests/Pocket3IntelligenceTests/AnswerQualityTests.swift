import Testing
import Pocket3Core
@testable import Pocket3Intelligence

@Test func observedModelDegenerationIsRejected() throws {
    #expect(throws: BridgeFailure.self) { try AnswerQuality.validate(answer: String(repeating: "}]", count: 60), evidence: [], uncertainties: []) }
    #expect(throws: BridgeFailure.self) { try AnswerQuality.validate(answer: "", evidence: [], uncertainties: []) }
    try AnswerQuality.validate(answer: "圖中可見紅色正方形。", evidence: ["紅色區塊的四邊等長。"], uncertainties: [])
}

@Test func aModelCannotClaimMovementWithoutTheActionRecord() throws {
    #expect(throws: BridgeFailure.self) { try AnswerQuality.validateExecution(answer: "已向左移動一小步。", hasVerifiedMovement: false) }
    #expect(throws: BridgeFailure.self) { try AnswerQuality.validateExecution(answer: "I have moved the camera left.", hasVerifiedMovement: false) }
    try AnswerQuality.validateExecution(answer: "無法確認相機是否已向左移動。", hasVerifiedMovement: false)
    try AnswerQuality.validateExecution(answer: "已向左移動一小步。", hasVerifiedMovement: true)
}

@Test func zoomClaimsRequireTheirOwnReadbackAndPostZoomFrameEvidence() throws {
    #expect(throws: BridgeFailure.self) {
        try AnswerQuality.validateExecution(answer: "已放大畫面。", hasVerifiedMovement: false)
    }
    #expect(throws: BridgeFailure.self) {
        try AnswerQuality.validateExecution(answer: "I have zoomed in.", hasVerifiedMovement: true, hasVerifiedZoom: false)
    }
    try AnswerQuality.validateExecution(answer: "無法確認縮放是否完成。", hasVerifiedMovement: false, hasVerifiedZoom: false)
    try AnswerQuality.validateExecution(answer: "已調整縮放至原始值147。", hasVerifiedMovement: false, hasVerifiedZoom: true)
}
