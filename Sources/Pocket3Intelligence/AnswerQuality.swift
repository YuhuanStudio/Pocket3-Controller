import Foundation
import Pocket3Core

/// Reject structural degeneration instead of displaying it as a valid answer.
/// This does not claim to grade factual accuracy; the evaluation set does that.
public enum AnswerQuality {
    public static func validate(answer: String, evidence: [String], uncertainties: [String]) throws {
        let value = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 3000, evidence.count <= 4, uncertainties.count <= 4,
              (evidence + uncertainties).allSatisfy({ $0.count <= 700 }) else {
            throw BridgeFailure("invalid_model_output", "模型回答不完整或超過長度限制，請縮短問題後再試")
        }
        if value.count > 32 {
            let letters = value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
            guard Double(letters) / Double(value.unicodeScalars.count) >= 0.2 else {
                throw BridgeFailure("invalid_model_output", "模型回傳重複符號，未將其當作有效回答")
            }
        }
    }
    /// Reject the demonstrated false-completion failure against the action
    /// ledger. This is a conservative phrase guard, not a general fact checker.
    public static func validateExecution(answer: String, hasVerifiedMovement: Bool, hasVerifiedZoom: Bool = false) throws {
        if !hasVerifiedMovement {
            let patterns = [
                #"(?:^|[。！？!?\n，,])\s*(?:好的[，,]\s*)?(?:(?:我|相機|镜头|鏡頭|雲台)(?:已經|已经|已|成功)|已經|已经|已|成功)[^。！？!?\n]{0,16}(?:移動|移动|轉動|转动|轉向|转向|往左|往右|向左|向右|抬頭|低頭)"#,
                #"(?i)(?:^|[.!?\n])\s*(?:(?:I|the camera|the gimbal)\s+)?(?:(?:have|has)\s+)?(?:successfully\s+)?(?:moved|rotated|turned|panned|tilted|recentered)\b"#
            ]
            guard !patterns.contains(where: { answer.range(of: $0, options: .regularExpression) != nil }) else {
                throw BridgeFailure("unverified_action_claim", "本次未執行相機移動；模型的完成宣稱沒有工具證據，已丟棄此回答")
            }
        }
        if !hasVerifiedZoom {
            let patterns = [
                #"(?:^|[。！？!?\n，,])\s*(?:好的[，,]\s*)?(?:(?:我|相機|镜头|鏡頭)(?:已經|已经|已|成功)|已經|已经|已|成功)[^。！？!?\n]{0,20}(?:放大|縮小|缩小|縮放|變焦|变焦|拉近|拉遠|拉远)"#,
                #"(?i)(?:^|[.!?\n])\s*(?:(?:I|the camera)\s+)?(?:(?:have|has)\s+)?(?:successfully\s+)?(?:zoomed|set\s+(?:the\s+)?zoom|changed\s+(?:the\s+)?zoom)\b"#
            ]
            guard !patterns.contains(where: { answer.range(of: $0, options: .regularExpression) != nil }) else {
                throw BridgeFailure("unverified_zoom_claim", "本次沒有縮放回讀與後續新影格；模型的縮放完成宣稱缺乏工具證據")
            }
        }
    }

}
