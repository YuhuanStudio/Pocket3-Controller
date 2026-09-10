import Foundation
import Pocket3Core

enum AnalysisExportFormat: String, Sendable, CaseIterable, Equatable {
    case json, markdown
}

enum AnalysisExportSourceKind: String, Codable, Sendable, Equatable {
    case image, video

    var analysisScope: String {
        self == .image ? "single_image" : "single_video_frame"
    }

    var scopeDescription: String {
        self == .image
            ? "This report describes one imported still image."
            : "This report describes one selected video frame, not a video event or continuous video analysis."
    }
}

enum AnalysisExportAction: String, Codable, Sendable, Equatable {
    case question, count, point, ocr
}

/// Captured when a result is accepted, never reconstructed from current UI state.
/// Every field is a value type. FrameInfo includes imported-region provenance;
/// there is deliberately no image Data, CVPixelBuffer, source URL or file path.
struct AnalysisExportSnapshot: Codable, Sendable, Equatable {
    let sourceName: String?
    let sourceKind: AnalysisExportSourceKind
    let frame: FrameInfo
    let engine: String
    let action: AnalysisExportAction
    let question: String
    let answer: String
    let evidence: [String]
    let uncertainties: [String]
    let grounding: JSONValue?
    let createdAt: Date

    init(sourceName: String? = nil, sourceKind: AnalysisExportSourceKind,
         frame: FrameInfo, engine: String, action: AnalysisExportAction,
         question: String, answer: String, evidence: [String] = [],
         uncertainties: [String] = [], grounding: JSONValue? = nil,
         createdAt: Date = Date()) throws {
        try Self.validateSourceName(sourceName)
        self.sourceName = sourceName
        self.sourceKind = sourceKind
        self.frame = frame
        self.engine = engine
        self.action = action
        self.question = question
        self.answer = answer
        self.evidence = evidence
        self.uncertainties = uncertainties
        self.grounding = grounding
        self.createdAt = createdAt
    }

    /// Backslash is a valid macOS filename character. Do not mistake it for a
    /// directory separator or modify a legitimate basename supplied by the UI.
    fileprivate static func validateSourceName(_ value: String?) throws {
        guard let value else { return }
        guard !value.isEmpty, value != ".", value != "..",
              !value.contains("/"), !value.contains("\0") else {
            throw BridgeFailure("analysis_export_source", "Analysis exports accept an optional source basename, not a file path")
        }
    }
}

/// Pure UTF-8 document generation. The caller owns file selection and writing.
enum AnalysisExport {
    static func data(for snapshot: AnalysisExportSnapshot, format: AnalysisExportFormat) throws -> Data {
        // Codable snapshots may also come from a decoder; apply the basename
        // boundary again instead of trusting that the public initializer ran.
        try AnalysisExportSnapshot.validateSourceName(snapshot.sourceName)
        switch format {
        case .json:
            guard case .object(var fields) = try JSONValue.encode(snapshot) else {
                throw BridgeFailure("analysis_export_encoding", "Could not encode the analysis snapshot")
            }
            fields["schemaVersion"] = .number(1)
            fields["analysisScope"] = .string(snapshot.sourceKind.analysisScope)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var result = try encoder.encode(JSONValue.object(fields))
            result.append(0x0A)
            return result
        case .markdown:
            return Data(try markdown(snapshot).utf8)
        }
    }

    /// Code fences keep user/model text literal, including Markdown images,
    /// autolinks, HTML and embedded fences. The delimiter exceeds every run of
    /// backticks in the content, so a line inside the value cannot close it.
    private static func literal(_ value: String, language: String = "text") -> String {
        var longest = 0, current = 0
        for character in value {
            if character == "`" { current += 1; longest = max(longest, current) }
            else { current = 0 }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language)\n\(value)\n\(fence)"
    }

    private static func jsonLiteral<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return literal(String(decoding: try encoder.encode(value), as: UTF8.self), language: "json")
    }

    private static func markdown(_ snapshot: AnalysisExportSnapshot) throws -> String {
        var sections = [
            "# Pocket 3 Controller analysis",
            snapshot.sourceKind.scopeDescription,
            "The answer, evidence and uncertainties below are recorded analysis output. They do not establish that a camera action occurred. No image bytes or source file URL are embedded.",
            "## Source",
            snapshot.sourceName.map { literal($0) } ?? "Source basename omitted.",
            "## Analysis details",
            try jsonLiteral(JSONValue.object([
                "schemaVersion": .number(1),
                "analysisScope": .string(snapshot.sourceKind.analysisScope),
                "sourceKind": .string(snapshot.sourceKind.rawValue),
                "engine": .string(snapshot.engine),
                "action": .string(snapshot.action.rawValue),
                "createdAt": try JSONValue.encode(snapshot.createdAt)
            ])),
            "## Question", literal(snapshot.question),
            "## Answer", literal(snapshot.answer),
            "## Evidence"
        ]
        sections += snapshot.evidence.isEmpty ? ["No evidence entries were recorded."] : snapshot.evidence.map { literal($0) }
        sections += ["## Uncertainties"]
        sections += snapshot.uncertainties.isEmpty ? ["No uncertainty entries were recorded; this does not guarantee correctness."] : snapshot.uncertainties.map { literal($0) }
        sections += ["## Frame metadata", try jsonLiteral(snapshot.frame)]
        if let grounding = snapshot.grounding {
            sections += ["## Grounding output", try jsonLiteral(grounding)]
        }
        return sections.joined(separator: "\n\n") + "\n"
    }
}
