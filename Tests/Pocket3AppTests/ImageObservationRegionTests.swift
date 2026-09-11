import AppKit
@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import Pocket3Core
@testable import Pocket3Intelligence
@testable import Pocket3BridgeApp

@MainActor private func regionWorkspaceAsset(_ name: String) throws -> ImportedObservationImage {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 100,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 640, bitsPerPixel: 32))
    let bytes = try #require(bitmap.bitmapData)
    for y in 0..<100 { for x in 0..<160 {
        let offset = y * 640 + x * 4
        // Upper-left red; upper-right green; lower-left blue; lower-right yellow.
        bytes[offset] = (x < 80 && y < 50) || (x >= 80 && y >= 50) ? 255 : 0
        bytes[offset + 1] = x >= 80 ? 255 : 0
        bytes[offset + 2] = x < 80 && y >= 50 ? 255 : 0
        bytes[offset + 3] = 255
    } }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    return .init(frame: try FramePacket.fixture(data: png), previewData: png, displayName: name)
}

private actor RegionWorkspaceAnalyzer {
    struct Call: Sendable {
        let frame: FramePacket
        let question: String
        let action: ImageObservationAction
        let engine: String
    }
    private(set) var calls: [Call] = []
    private var pauseNext = false
    private var gate: CheckedContinuation<Void, Never>?
    var waiting: Bool { gate != nil }
    func pauseNextCall() { pauseNext = true }
    func release() { let pending = gate; gate = nil; pending?.resume() }
    func analyze(_ frame: FramePacket, _ question: String, _ action: ImageObservationAction, _ engine: String) async throws -> ImageObservationResponse {
        calls.append(.init(frame: frame, question: question, action: action, engine: engine))
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { gate = $0 }
        }
        // Return even after cancellation to exercise the actual workspace fence.
        if action == .locate {
            let location = try JSONDecoder().decode(GroundedImageLocation.self,
                from: Data(#"{"point":{"x":0.25,"y":0.75},"uncertain":false}"#.utf8))
            return .grounding(.init(kind: .point, value: .point(location), frame: frame.info, engine: engine, elapsedSeconds: 0.1))
        }
        return .answer(try JSONDecoder().decode(ObservationAnswer.self,
            from: Data(#"{"answer":"RESULT","evidence":["VISIBLE"],"uncertainties":[]}"#.utf8)))
    }
}

@MainActor private func regionEventually(_ predicate: () async -> Bool) async throws {
    for _ in 0..<1500 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw BridgeFailure("fixture_timeout", "ROI workspace did not reach the expected state")
}

private func regionPixel(_ frame: FramePacket, x: Int, y: Int) throws -> [UInt8] {
    CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly) }
    let bytes = try #require(CVPixelBufferGetBaseAddress(frame.pixelBuffer)?.assumingMemoryBound(to: UInt8.self))
    let offset = y * CVPixelBufferGetBytesPerRow(frame.pixelBuffer) + x * 4
    return (0..<4).map { bytes[offset + $0] }
}

@Suite("Imported region workspace", .serialized) struct ImageObservationRegionTests {
    @MainActor @Test func analysisReceivesRealCroppedPixelsAndMapsResultBackToOriginal() async throws {
        let source = try regionWorkspaceAsset("quadrants.png")
        let analyzer = RegionWorkspaceAnalyzer()
        let model = ImageObservationWorkspace(load: { _ in source }, analyze: { try await analyzer.analyze($0, $1, $2, $3) })
        model.importImage(at: URL(fileURLWithPath: "/fixture/quadrants.png"))
        try await regionEventually { model.ready }
        let selection = try NormalizedImageRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        model.setRegion(selection); model.question = "Find the yellow object"
        model.begin(engine: "mlx", action: .locate)
        try await regionEventually { !model.isAnalyzing }
        let call = try #require(await analyzer.calls.first)
        #expect(call.frame.info.width == 80 && call.frame.info.height == 50)
        #expect(CVPixelBufferGetWidth(call.frame.pixelBuffer) == 80 && CVPixelBufferGetHeight(call.frame.pixelBuffer) == 50)
        #expect(try regionPixel(call.frame, x: 0, y: 0) == [0, 255, 255, 255])
        #expect(try regionPixel(call.frame, x: 79, y: 49) == [0, 255, 255, 255])
        #expect(call.frame.info.id != source.frame.info.id)
        #expect(call.frame.info.importedRegion?.sourceFrameID == source.frame.info.id)
        #expect(model.responseFrameID == call.frame.info.id)
        #expect(model.responseSourceFrameID == source.frame.info.id)
        #expect(model.asset?.frame.info.id == source.frame.info.id) // Preview still shows the complete source.
        #expect(model.marker == CGPoint(x: 0.625, y: 0.875))
        let snapshot = try #require(model.resultSnapshot)
        #expect(snapshot.frame == call.frame.info && snapshot.frame.importedRegion?.region == selection)
        #expect(snapshot.question == "Find the yellow object" && snapshot.engine == "mlx")
        #expect(snapshot.action == .point && snapshot.sourceKind == .image)
        let json = try JSONDecoder().decode(JSONValue.self, from: AnalysisExport.data(for: snapshot, format: .json))
        #expect(json["frame"]["importedRegion"]["sourceFrameID"].string == source.frame.info.id)
        #expect(json["frame"]["width"].number == 80)
    }

    @MainActor @Test func snapshotKeepsSubmittedQuestionAndEngineDespiteLaterUIEdits() async throws {
        let source = try regionWorkspaceAsset("unchanged.png")
        let analyzer = RegionWorkspaceAnalyzer()
        let file = ImageObservationWorkspace(load: { _ in source }, analyze: { try await analyzer.analyze($0, $1, $2, $3) })
        let app = AppModel(imageWorkspace: file)
        app.observationSource = .image; app.selectedEngine = "apple"
        file.importImage(at: URL(fileURLWithPath: "/fixture/unchanged.png"))
        try await regionEventually { file.ready }
        file.setRegion(try .init(x: 0, y: 0, width: 0.5, height: 0.5))
        file.question = "Original question"
        await analyzer.pauseNextCall()
        file.begin(engine: app.selectedEngine)
        try await regionEventually { await analyzer.waiting }
        file.question = "Edited while running"; app.selectedEngine = "mlx"
        await analyzer.release()
        try await regionEventually { !file.isAnalyzing }
        let snapshot = try #require(file.resultSnapshot)
        #expect(snapshot.question == "Original question" && snapshot.engine == "apple")
        let bytes = try AnalysisExport.data(for: snapshot, format: .json)
        file.question = "Edited after result"; app.selectedEngine = "apple"
        #expect(file.resultSnapshot == snapshot)
        let unchanged = try #require(file.resultSnapshot)
        #expect(try AnalysisExport.data(for: unchanged, format: .json) == bytes)
    }

    @MainActor @Test func regionChangeClearsResultAndWaitsForItsCancelledAnalyzerBeforeAnotherRun() async throws {
        let source = try regionWorkspaceAsset("regions.png")
        let analyzer = RegionWorkspaceAnalyzer()
        let file = ImageObservationWorkspace(load: { _ in source }, analyze: { try await analyzer.analyze($0, $1, $2, $3) })
        file.importImage(at: URL(fileURLWithPath: "/fixture/regions.png"))
        try await regionEventually { file.ready }
        file.question = "Locate"; file.begin(engine: "apple", action: .locate)
        try await regionEventually { !file.isAnalyzing }
        #expect(file.resultSnapshot != nil && file.marker != nil)
        file.setRegion(try .init(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(file.resultSnapshot == nil && file.responseFrameID == nil && file.responseSourceFrameID == nil && file.marker == nil)
        await analyzer.pauseNextCall()
        file.begin(engine: "apple", action: .locate)
        try await regionEventually { await analyzer.waiting }
        file.setRegion(try .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        file.begin(engine: "mlx", action: .locate)
        #expect(await analyzer.calls.count == 2) // New work is barred until the owned old job exits.
        #expect(file.isAnalyzing && file.isCancelling && file.marker == nil)
        await analyzer.release()
        try await regionEventually { !file.isAnalyzing }
        #expect(file.resultSnapshot == nil && file.response == nil && file.error == nil)
        file.begin(engine: "mlx", action: .locate)
        try await regionEventually { !file.isAnalyzing }
        #expect(await analyzer.calls.count == 3)
        #expect(file.marker == CGPoint(x: 0.625, y: 0.875))
    }

    @MainActor @Test func importingAnotherImageClearsRegionAndFencesOldCroppedAnswer() async throws {
        let a = try regionWorkspaceAsset("a.png"), b = try regionWorkspaceAsset("b.png")
        let analyzer = RegionWorkspaceAnalyzer()
        let file = ImageObservationWorkspace(load: { $0.lastPathComponent == "a.png" ? a : b },
            analyze: { try await analyzer.analyze($0, $1, $2, $3) })
        file.importImage(at: URL(fileURLWithPath: "/fixture/a.png"))
        try await regionEventually { file.ready }
        file.setRegion(try .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        file.question = "Locate"; await analyzer.pauseNextCall(); file.begin(engine: "apple", action: .locate)
        try await regionEventually { await analyzer.waiting }
        file.importImage(at: URL(fileURLWithPath: "/fixture/b.png"))
        try await regionEventually { file.ready }
        #expect(file.region == nil && file.resultSnapshot == nil && file.marker == nil)
        #expect(file.asset?.frame.info.id == b.frame.info.id)
        file.begin(engine: "mlx", action: .locate)
        #expect(await analyzer.calls.count == 1)
        await analyzer.release()
        try await regionEventually { !file.isAnalyzing }
        #expect(file.response == nil && file.responseSourceFrameID == nil && file.resultSnapshot == nil)
        file.begin(engine: "mlx", action: .locate)
        try await regionEventually { !file.isAnalyzing }
        #expect(file.responseSourceFrameID == b.frame.info.id)
        #expect(file.resultSnapshot?.frame.importedRegion == nil)
        #expect(file.marker == CGPoint(x: 0.25, y: 0.75))
    }

    @Test func regionDraggingRejectsLetterboxStartsAndSupportsReverseEdges() throws {
        let image = CGSize(width: 800, height: 400), container = CGSize(width: 400, height: 400)
        #expect(ImportedImageGeometry.selection(from: .init(x: 10, y: 50), to: .init(x: 390, y: 290), imageSize: image, containerSize: container) == nil)
        #expect(ImportedImageGeometry.selection(from: .init(x: -1, y: 150), to: .init(x: 200, y: 200), imageSize: image, containerSize: container) == nil)
        let reverse = ImportedImageGeometry.selection(from: .init(x: 400, y: 300), to: .init(x: 100, y: 150), imageSize: image, containerSize: container)
        #expect(reverse == (try .init(x: 0.25, y: 0.25, width: 0.75, height: 0.75)))
        let full = ImportedImageGeometry.selection(from: .init(x: 0, y: 100), to: .init(x: 500, y: 450), imageSize: image, containerSize: container)
        #expect(full == (try .init(x: 0, y: 0, width: 1, height: 1)))
        #expect(ImportedImageGeometry.selection(from: .init(x: 100, y: 150), to: .init(x: 105, y: 155), imageSize: image, containerSize: container) == nil)
        #expect(ImportedImageGeometry.selection(from: .init(x: 100, y: 150), to: .init(x: CGFloat.nan, y: 200), imageSize: image, containerSize: container) == nil)
        let portrait = ImportedImageGeometry.selection(from: .init(x: 100, y: 300), to: .init(x: 200, y: 100), imageSize: .init(width: 400, height: 800), containerSize: container)
        #expect(portrait == (try .init(x: 0, y: 0.25, width: 0.5, height: 0.5)))
    }
}

private func regionWorkspaceMovie(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264.rawValue, AVVideoWidthKey: 64, AVVideoHeightKey: 32,
        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1]])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    guard writer.canAdd(input) else { throw BridgeFailure("video_fixture", "Cannot add synthetic movie input") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? BridgeFailure("video_fixture", "Cannot start synthetic movie") }
    writer.startSession(atSourceTime: .zero)
    do {
        for index in 0..<2 {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw BridgeFailure("video_fixture", "Synthetic encoder readiness timed out") }
                try await Task.sleep(for: .milliseconds(1))
            }
            var output: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &output) == kCVReturnSuccess,
                  let output else { throw BridgeFailure("video_fixture", "Cannot allocate synthetic movie pixels") }
            CVPixelBufferLockBaseAddress(output, [])
            let pixels = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(output)
            for y in 0..<32 { for x in 0..<64 {
                let offset = y * stride + x * 4
                pixels[offset] = index == 0 ? 0 : 255
                pixels[offset + 1] = 0; pixels[offset + 2] = index == 0 ? 255 : 0; pixels[offset + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(output, [])
            guard adapter.append(output, withPresentationTime: CMTime(value: Int64(index), timescale: 2)) else {
                throw writer.error ?? BridgeFailure("video_fixture", "Cannot append synthetic movie pixels")
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1)); input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? BridgeFailure("video_fixture", "Synthetic movie did not complete") }
    } catch { writer.cancelWriting(); throw error }
}

extension ImageObservationRegionTests {
    @MainActor @Test func remoteCameraTaskBlocksSourceReplacementUntilItFinishes() async throws {
        let image = try regionWorkspaceAsset("fixture.png")
        let analyzer = RegionWorkspaceAnalyzer()
        let workspace = ImageObservationWorkspace(load: { _ in image },
            analyze: { try await analyzer.analyze($0, $1, $2, $3) })
        let app = AppModel(imageWorkspace: workspace)
        app.remoteTaskCount = 1
        #expect(!app.canChangeObservationSource)
        await app.changeObservationSource(.image)
        #expect(app.observationSource == .camera)
        app.remoteTaskCount = 0
        #expect(app.canChangeObservationSource)
        await app.changeObservationSource(.image)
        #expect(app.observationSource == .image)
    }

    @MainActor @Test func seekingVideoClearsPreviousSnapshotAndFencesItsOwnPendingCroppedResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-roi-video-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.mp4")
        try await regionWorkspaceMovie(at: url)
        let video = try await ImportedVideoSource.open(url)
        defer { Task { await video.close() } }
        let initial = try await video.frame(at: 0)
        let source = ImportedObservationImage(frame: initial, previewData: try initial.jpeg(maxDimension: 1920),
            displayName: "synthetic.mp4", videoSource: video)
        let analyzer = RegionWorkspaceAnalyzer()
        let file = ImageObservationWorkspace(load: { _ in source }, analyze: { try await analyzer.analyze($0, $1, $2, $3) })
        file.importImage(at: url)
        try await regionEventually { file.ready }
        file.setRegion(try .init(x: 0.5, y: 0, width: 0.5, height: 1))
        file.question = "Locate"; file.begin(engine: "apple", action: .locate)
        try await regionEventually { !file.isAnalyzing }
        #expect(file.resultSnapshot?.sourceKind == .video)
        #expect(file.resultSnapshot?.frame.importedRegion?.sourceFrameID == initial.info.id)
        file.seek(to: 0.5)
        #expect(file.resultSnapshot == nil && file.marker == nil && file.responseSourceFrameID == nil)
        try await regionEventually { file.ready && file.asset?.frame.info.id != initial.info.id }
        let middle = try #require(file.asset?.frame.info)
        #expect(middle.sessionID == initial.info.sessionID && abs(middle.presentationTime - 0.5) < 0.01)
        let middleFrame = try #require(file.asset?.frame)
        let blue = try regionPixel(middleFrame, x: 32, y: 16)
        #expect(blue[0] > 180 && blue[2] < 70)
        await analyzer.pauseNextCall(); file.begin(engine: "mlx", action: .locate)
        try await regionEventually { await analyzer.waiting }
        file.seek(to: 0)
        try await regionEventually { file.ready && file.asset?.frame.info.id != middle.id }
        #expect(file.isAnalyzing && file.isCancelling && file.resultSnapshot == nil)
        file.begin(engine: "apple", action: .locate)
        #expect(await analyzer.calls.count == 2)
        await analyzer.release()
        try await regionEventually { !file.isAnalyzing }
        #expect(file.response == nil && file.resultSnapshot == nil && file.error == nil)
        let current = try #require(file.asset?.frame.info)
        file.begin(engine: "apple", action: .locate)
        try await regionEventually { !file.isAnalyzing }
        #expect(file.responseSourceFrameID == current.id)
        #expect(file.resultSnapshot?.frame.importedRegion?.sourceFrameID == current.id)
        #expect(file.resultSnapshot?.frame.sessionID == initial.info.sessionID)
        #expect(file.resultSnapshot?.frame.presentationTime == current.presentationTime)
        #expect(file.resultSnapshot?.sourceKind == .video)
        await video.close(); file.clear()
    }
}
