import CoreVideo
import Foundation
import Testing
@testable import Pocket3Core
@testable import Pocket3Intelligence

private func groundingFrame(imported: Bool = true) throws -> FramePacket {
    var pixels: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 100, 80, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess,
          let pixels else { throw BridgeFailure("fixture", "Cannot allocate synthetic pixels") }
    let info = FrameInfo(id: "grounding-frame", sessionID: "fixture-grounding", deviceID: imported ? "local-evaluation" : "camera-fixture",
        receivedAt: Date(), receivedUptime: ProcessInfo.processInfo.systemUptime, presentationTime: 0,
        width: 100, height: 80, timestampSource: imported ? "local_image_import" : "camera")
    return FramePacket(pixelBuffer: pixels, info: info)
}

@Test func groundingRejectsPixelScaleNonfiniteAndOutOfRangeCoordinatesWithoutRepair() throws {
    for point in [GroundedImagePoint(x: 200, y: 200), .init(x: 0.442, y: 650),
                  .init(x: -0.01, y: 0.5), .init(x: 0.5, y: 1.01),
                  .init(x: .nan, y: 0.5), .init(x: 0.5, y: .infinity)] {
        #expect(throws: BridgeFailure.self) {
            try GroundedImageValue.point(.init(point: point, uncertain: false)).validate(kind: .point)
        }
        #expect(throws: BridgeFailure.self) {
            try GroundedImageValue.absent(.init(found: true, point: point)).validate(kind: .absent)
        }
    }
    for point in [GroundedImagePoint(x: 0, y: 1), .init(x: 1, y: 0), .init(x: 0.442, y: 0.65)] {
        let value = GroundedImageValue.point(.init(point: point, uncertain: false))
        try value.validate(kind: .point)
        #expect(try value.json()["point"]["x"] == .number(point.x))
        #expect(try value.json()["point"]["y"] == .number(point.y))
    }
}

@Test func groundingRejectsContradictoryLocationPresenceAndWrongKind() throws {
    let center = GroundedImagePoint(x: 0.5, y: 0.5)
    let invalid: [(GroundedImageKind, GroundedImageValue)] = [
        (.count, .count(.init(count: -1, uncertain: false))),
        (.point, .point(.init(point: nil, uncertain: false))),
        (.point, .point(.init(point: center, uncertain: true))),
        (.absent, .absent(.init(found: false, point: center))),
        (.point, .count(.init(count: 1, uncertain: false)))
    ]
    for (kind, value) in invalid {
        do { try value.validate(kind: kind); Issue.record("Invalid grounding output accepted") }
        catch let failure as BridgeFailure { #expect(failure.code == "grounding_output_invalid") }
    }
    try GroundedImageValue.count(.init(count: 0, uncertain: true)).validate(kind: .count)
    try GroundedImageValue.absent(.init(found: true, point: nil)).validate(kind: .absent)
}

@Test func groundingAbstentionEncodesExplicitNullInsteadOfFakePoint() throws {
    let location = GroundedImageValue.point(.init(point: nil, uncertain: true))
    try location.validate(kind: .point)
    #expect(try location.json() == .object(["point": .null, "uncertain": .bool(true)]))
    let presence = GroundedImageValue.absent(.init(found: false, point: nil))
    try presence.validate(kind: .absent)
    #expect(try presence.json() == .object(["found": .bool(false), "point": .null]))
}

private actor GroundingResponder {
    let blocks: Bool
    private(set) var stages: [GroundedImageStage] = []
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    init(blocks: Bool = false) { self.blocks = blocks }
    func answer(_ stage: GroundedImageStage) async -> GroundedImageValue {
        stages.append(stage)
        if blocks && stages.count == 1 { await withCheckedContinuation { continuation = $0 } }
        switch stage.kind {
        case .count: return .count(.init(count: 2, uncertain: false))
        case .point: return .point(.init(point: .init(x: 0.2, y: 0.8), uncertain: false))
        case .absent: return .absent(.init(found: false, point: nil))
        }
    }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
}

@Test func groundingUsesOnlySelectedEngineAndHostImportedFrameMetadata() async throws {
    let frame = try groundingFrame(), responder = GroundingResponder()
    let engine = IntelligenceEngine(groundingStage: { await responder.answer($0) })
    for selected in ["apple", "mlx"] {
        let result = try await engine.grounded(frame: frame, question: "How many objects?", kind: .count, engine: selected)
        let json = try result.metadata()
        #expect(json["schemaVersion"] == .number(1))
        #expect(json["result"] == .object(["count": .number(2), "uncertain": .bool(false)]))
        #expect(json["engine"] == .string(selected) && json["kind"] == .string("count"))
        #expect(json["origin"] == .string("local_image_import"))
        #expect(json["frame"]["id"] == .string(frame.info.id))
        #expect(json["frame"]["timestampSource"] == .string("local_image_import"))
        #expect(json["coordinateSpace"] == .string("normalized_top_left_0_1"))
        #expect(json["actions"] == .null)
    }
    #expect(await responder.stages.map(\.engine) == ["apple", "mlx"])
}

@Test func groundingRejectsNonimportedFramesBeforeAnyModelCall() async throws {
    let responder = GroundingResponder()
    let engine = IntelligenceEngine(groundingStage: { await responder.answer($0) })
    do {
        _ = try await engine.grounded(frame: groundingFrame(imported: false), question: "Where?", kind: .point)
        Issue.record("Non-imported frame accepted")
    } catch let failure as BridgeFailure { #expect(failure.code == "grounding_input_invalid") }
    #expect(await responder.stages.isEmpty)
}

@Test func groundingHostValidationRejectsInvalidTypedModelResult() async throws {
    let engine = IntelligenceEngine(groundingStage: { _ in .point(.init(point: .init(x: 442, y: 650), uncertain: false)) })
    do {
        _ = try await engine.grounded(frame: groundingFrame(), question: "Where?", kind: .point)
        Issue.record("Model pixel-scale coordinates accepted")
    } catch let failure as BridgeFailure { #expect(failure.code == "grounding_output_invalid") }
    #expect(await engine.status().isBusy == false)
}

@Test func groundingCancellationKeepsSharedBusyGateUntilLateResponderFinishes() async throws {
    let frame = try groundingFrame(), responder = GroundingResponder(blocks: true)
    let engine = IntelligenceEngine(groundingStage: { await responder.answer($0) })
    let task = Task { try await engine.grounded(frame: frame, question: "Count", kind: .count) }
    for _ in 0..<1000 {
        if await responder.waiting { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await responder.waiting)
    await engine.cancelObservation()
    for operation in ["grounding", "analyze", "unload", "delete"] {
        do {
            switch operation {
            case "grounding": _ = try await engine.grounded(frame: frame, question: "Other", kind: .point)
            case "analyze": _ = try await engine.analyze(frame: frame, question: "Describe")
            case "unload": try await engine.unloadModel()
            default: try await engine.deleteModel()
            }
            Issue.record("Busy gate admitted \(operation)")
        } catch let failure as BridgeFailure { #expect(failure.code == "ai_busy") }
    }
    await responder.release()
    do { _ = try await task.value; Issue.record("Cancelled responder produced a late result") }
    catch is CancellationError {}
    #expect(await engine.status().isBusy == false)
    let next = try await engine.grounded(frame: frame, question: "Where?", kind: .point, engine: "mlx")
    #expect(next.engine == "mlx")
}

@Test func groundingParentTaskCancellationDiscardsLateResult() async throws {
    let frame = try groundingFrame(), responder = GroundingResponder(blocks: true)
    let engine = IntelligenceEngine(groundingStage: { await responder.answer($0) })
    let task = Task { try await engine.grounded(frame: frame, question: "Count", kind: .count) }
    for _ in 0..<1000 {
        if await responder.waiting { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await responder.waiting)
    task.cancel(); await responder.release()
    do { _ = try await task.value; Issue.record("Cancelled parent received a result") }
    catch is CancellationError {}
    #expect(await engine.status().isBusy == false)
}
