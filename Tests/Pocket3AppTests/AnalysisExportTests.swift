import Foundation
import Testing
@testable import Pocket3Core
@testable import Pocket3BridgeApp

private func exportFrame() -> FrameInfo {
    FrameInfo(id: "imported-frame-A", sessionID: "imported-session-A", deviceID: "local-evaluation",
              receivedAt: Date(timeIntervalSince1970: 1_800_000_000), receivedUptime: 12.345,
              presentationTime: 2.75, width: 160, height: 100, timestampSource: "local_image_import")
}

private func exportSnapshot(sourceName: String? = "fixture.jpg", kind: AnalysisExportSourceKind = .image,
                            question: String = "Count the blue circles", answer: String = "One") throws -> AnalysisExportSnapshot {
    var frame = exportFrame()
    if kind == .video { frame.timestampSource = "local_video_import" }
    return try .init(sourceName: sourceName, sourceKind: kind, frame: frame, engine: "mlx",
              action: .count, question: question, answer: answer,
              evidence: ["One visible blue circle"], uncertainties: [],
              grounding: .object(["count": .number(1), "uncertain": .bool(false)]),
              createdAt: Date(timeIntervalSince1970: 1_800_000_002))
}

@Suite("Offline analysis export") struct AnalysisExportTests {
    @Test func capturedSnapshotDoesNotFollowLaterQuestionModelOrFrameChanges() throws {
        var question = "Locate the blue circle", engine = "mlx", frame = exportFrame()
        var evidence = ["Original evidence"]
        var grounding: [String: JSONValue] = ["point": .object(["x": .number(0.75), "y": .number(0.5)])]
        let snapshot = try AnalysisExportSnapshot(sourceName: "original.jpg", sourceKind: .image,
            frame: frame, engine: engine, action: .point, question: question, answer: "Original result",
            evidence: evidence, grounding: .object(grounding), createdAt: Date(timeIntervalSince1970: 1_800_000_002))
        question = "A different question"; engine = "apple"; frame.id = "replacement-frame"
        evidence[0] = "Replacement evidence"; grounding["point"] = .null
        #expect(question != snapshot.question && engine != snapshot.engine && frame.id != snapshot.frame.id)
        #expect(snapshot.evidence == ["Original evidence"])
        #expect(snapshot.grounding?["point"]["x"] == .number(0.75))

        let data = try AnalysisExport.data(for: snapshot, format: .json)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try decoder.decode(AnalysisExportSnapshot.self, from: data)
        #expect(roundTrip == snapshot)
        let object = try decoder.decode(JSONValue.self, from: data)
        #expect(object["schemaVersion"] == .number(1) && object["analysisScope"] == .string("single_image"))
        #expect(object["question"] == .string("Locate the blue circle") && object["engine"] == .string("mlx"))
        #expect(object["frame"]["receivedUptime"] == .number(12.345))
    }

    @Test func sourceBasenameCanBeOmittedButDirectoryPathsAreRejected() throws {
        for name in ["/Users/private/image.jpg", "relative/image.jpg", "", ".", "..", "bad\0name.jpg"] {
            #expect(throws: BridgeFailure.self) { try exportSnapshot(sourceName: name) }
        }
        let omitted = try AnalysisExport.data(for: exportSnapshot(sourceName: nil), format: .json)
        let value = try JSONDecoder().decode(JSONValue.self, from: omitted)
        #expect(value["sourceName"] == .null)
        #expect(value["path"] == .null && value["url"] == .null && value["imageData"] == .null)
        let legitimate = try exportSnapshot(sourceName: "a\\b\"name.jpg")
        #expect(legitimate.sourceName == "a\\b\"name.jpg")

        // Decoding must not bypass the exporter boundary.
        var raw = try #require(JSONSerialization.jsonObject(with: omitted) as? [String: Any])
        raw["sourceName"] = "/Users/private/image.jpg"
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AnalysisExportSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(throws: BridgeFailure.self) { try AnalysisExport.data(for: decoded, format: .markdown) }
    }

    @Test func markdownKeepsUntrustedImagesLinksHTMLQuotesAndFencesLiteral() throws {
        let hostile = "\"quote\"\n```\n![remote](https://example.invalid/image.png)\n[link](https://example.invalid)\n<https://example.invalid>\n<img src=\"https://example.invalid/pixel\">\n``````\n# forged heading"
        let snapshot = try AnalysisExportSnapshot(sourceName: "![name](relative.png)\n````\n# filename",
            sourceKind: .image, frame: exportFrame(), engine: "[engine](https://example.invalid)", action: .question,
            question: hostile, answer: hostile, evidence: [hostile], uncertainties: [hostile],
            grounding: .object(["text": .string(hostile)]))
        let markdown = String(decoding: try AnalysisExport.data(for: snapshot, format: .markdown), as: UTF8.self)
        #expect(markdown.contains("```````text\n" + hostile + "\n```````"))
        #expect(markdown.contains("`````text\n![name](relative.png)\n````\n# filename\n`````"))
        let rendered = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full))
        #expect(!rendered.runs.contains { $0.link != nil })
        let json = try JSONDecoder().decode(JSONValue.self, from: AnalysisExport.data(for: snapshot, format: .json))
        #expect(json["question"] == .string(hostile) && json["answer"] == .string(hostile))
    }

    @Test func videoExportIdentifiesOnlyTheSelectedFrameWithoutInventingEventsOrActions() throws {
        let snapshot = try exportSnapshot(kind: .video)
        let json = try JSONDecoder().decode(JSONValue.self, from: AnalysisExport.data(for: snapshot, format: .json))
        #expect(json["analysisScope"] == .string("single_video_frame"))
        #expect(json["sourceKind"] == .string("video") && json["frame"]["presentationTime"] == .number(2.75))
        #expect(json["frame"]["timestampSource"] == .string("local_video_import"))
        for forbidden in ["events", "actions", "completed", "verified", "imageData", "videoData", "sourceURL", "path"] {
            #expect(json[forbidden] == .null)
        }
        let markdown = String(decoding: try AnalysisExport.data(for: snapshot, format: .markdown), as: UTF8.self)
        #expect(markdown.contains("one selected video frame, not a video event or continuous video analysis"))
        #expect(markdown.contains("do not establish that a camera action occurred"))
        #expect(markdown.contains("No uncertainty entries were recorded; this does not guarantee correctness."))
    }

    @Test func exportedFrameRetainsImportedRegionProvenanceWithoutRecomputingCoordinates() throws {
        var frame = exportFrame()
        let region = try NormalizedImageRegion(x: 0.2, y: 0.1, width: 0.5, height: 0.6)
        frame.importedRegion = ImportedRegionProvenance(sourceFrameID: "original-imported-frame",
            originalWidth: 640, originalHeight: 480, region: region)
        let snapshot = try AnalysisExportSnapshot(sourceKind: .image, frame: frame, engine: "vision", action: .ocr,
            question: "", answer: "SERIAL: ABC", createdAt: Date(timeIntervalSince1970: 1_800_000_002))
        frame.importedRegion = nil
        let data = try AnalysisExport.data(for: snapshot, format: .json)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try decoder.decode(AnalysisExportSnapshot.self, from: data)
        #expect(roundTrip.frame.importedRegion == snapshot.frame.importedRegion)
        let json = try decoder.decode(JSONValue.self, from: data)
        #expect(json["frame"]["importedRegion"]["sourceFrameID"] == .string("original-imported-frame"))
        #expect(json["frame"]["importedRegion"]["region"]["x"] == .number(0.2))
        #expect(json["frame"]["importedRegion"]["region"]["width"] == .number(0.5))
    }
}
