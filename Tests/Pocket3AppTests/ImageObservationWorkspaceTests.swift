import AppKit
import Foundation
import SwiftUI
import Testing
import Vision
@testable import Pocket3Core
@testable import Pocket3Intelligence
@testable import Pocket3BridgeApp

@MainActor private func importedTestImage(_ name: String) throws -> ImportedObservationImage {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 100,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 640, bitsPerPixel: 32))
    let bytes = try #require(bitmap.bitmapData)
    for offset in stride(from: 0, to: 64_000, by: 4) {
        bytes[offset] = 255; bytes[offset + 1] = 0; bytes[offset + 2] = 255; bytes[offset + 3] = 255
    }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    return .init(frame: try FramePacket.fixture(data: data), previewData: data, displayName: name)
}

private actor WorkspaceFixture {
    let a: ImportedObservationImage
    let b: ImportedObservationImage
    var delayLoad: Bool
    var delayAnalysis: Bool
    private var loadGate: CheckedContinuation<Void, Never>?
    private var analysisGate: CheckedContinuation<Void, Never>?
    private(set) var calls: [(String, ImageObservationAction, String)] = []
    var loading: Bool { loadGate != nil }
    var analysing: Bool { analysisGate != nil }
    init(a: ImportedObservationImage, b: ImportedObservationImage, delayLoad: Bool = false, delayAnalysis: Bool = false) {
        self.a = a; self.b = b; self.delayLoad = delayLoad; self.delayAnalysis = delayAnalysis
    }
    func load(_ url: URL) async -> ImportedObservationImage {
        if url.lastPathComponent == "a", delayLoad { await withCheckedContinuation { loadGate = $0 } }
        return url.lastPathComponent == "a" ? a : b
    }
    func analyze(_ frame: FramePacket, _ question: String, _ action: ImageObservationAction, _ engine: String) async throws -> ImageObservationResponse {
        calls.append((frame.info.id, action, engine))
        if delayAnalysis && calls.count == 1 { await withCheckedContinuation { analysisGate = $0 } }
        // Intentionally returns after cancellation; the workspace must fence it.
        let text = "{\"answer\":\"PRIVATEANSWER\",\"evidence\":[\"PRIVATEEVIDENCE\"],\"uncertainties\":[\"PRIVATEUNCERTAINTY\"]}"
        return .answer(try JSONDecoder().decode(ObservationAnswer.self, from: Data(text.utf8)))
    }
    func releaseLoad() { let gate = loadGate; loadGate = nil; gate?.resume() }
    func releaseAnalysis() { let gate = analysisGate; analysisGate = nil; gate?.resume() }
}

@MainActor private func workspace(_ fixture: WorkspaceFixture) -> ImageObservationWorkspace {
    .init(load: { await fixture.load($0) }, analyze: { try await fixture.analyze($0, $1, $2, $3) })
}
@MainActor private func eventuallyImage(_ condition: () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw BridgeFailure("test_timeout", "Image workspace did not reach the expected fixture state")
}

@Suite("Offline image workspace", .serialized) struct ImageObservationWorkspaceTests {
    @MainActor @Test func cancelledImportCannotOverwriteAReplacementImage() async throws {
        let a = try importedTestImage("PRIVATE-A"), b = try importedTestImage("PRIVATE-B")
        let fixture = WorkspaceFixture(a: a, b: b, delayLoad: true), model = workspace(fixture)
        model.importImage(at: URL(fileURLWithPath: "/fixture/a"))
        try await eventuallyImage { await fixture.loading }
        model.cancel()
        #expect(!model.isImporting && model.asset == nil)
        model.importImage(at: URL(fileURLWithPath: "/fixture/b"))
        try await eventuallyImage { model.ready }
        await fixture.releaseLoad()
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.asset?.frame.info.id == b.frame.info.id)
        #expect(model.error == nil && !model.isImporting)
    }

    @MainActor @Test func replacingImageDiscardsLateAnswerAndKeepsOwnedModelBusyUntilDrained() async throws {
        let a = try importedTestImage("A"), b = try importedTestImage("B")
        let fixture = WorkspaceFixture(a: a, b: b, delayAnalysis: true), model = workspace(fixture)
        model.importImage(at: URL(fileURLWithPath: "/fixture/a"))
        try await eventuallyImage { model.ready }
        model.question = "Count"; model.begin(engine: "mlx", action: .count)
        try await eventuallyImage { await fixture.analysing }
        model.importImage(at: URL(fileURLWithPath: "/fixture/b"))
        try await eventuallyImage { model.ready }
        model.begin(engine: "apple")
        #expect(await fixture.calls.count == 1)
        #expect(model.isAnalyzing && model.answer.isEmpty && model.marker == nil)
        await fixture.releaseAnalysis()
        try await eventuallyImage { !model.isAnalyzing }
        #expect(model.response == nil && model.error == nil)
        model.begin(engine: "apple", action: .ocr)
        try await eventuallyImage { !model.isAnalyzing }
        #expect(await fixture.calls.last?.0 == b.frame.info.id)
        #expect(await fixture.calls.last?.1 == .ocr)
        #expect(await fixture.calls.last?.2 == "apple")
        #expect(model.responseFrameID == b.frame.info.id)
    }

    @MainActor @Test func returningToCameraWaitsForOwnedFileTaskWithoutChangingCameraAccess() async throws {
        let image = try importedTestImage("PRIVATEFILE")
        let fixture = WorkspaceFixture(a: image, b: image, delayAnalysis: true), file = workspace(fixture)
        let app = AppModel(imageWorkspace: file)
        app.observationSource = .image; app.access = .control
        file.importImage(at: URL(fileURLWithPath: "/fixture/a"))
        try await eventuallyImage { file.ready }
        file.question = "Where?"; file.begin(engine: "apple")
        try await eventuallyImage { await fixture.analysing }
        let returning = Task { await app.changeObservationSource(.camera) }
        try await eventuallyImage { app.switchingObservationSource }
        #expect(app.observationSource == .image && app.access == .control)
        await fixture.releaseAnalysis(); await returning.value
        #expect(app.observationSource == .camera && app.access == .control)
        #expect(file.asset == nil && file.response == nil && !file.isWorking)
    }

    @Test func pointMappingUsesTopLeftAndAspectFitWithoutClamping() {
        let container = CGSize(width: 400, height: 400)
        #expect(ImportedImageGeometry.imageRect(imageSize: .init(width: 800, height: 400), containerSize: container) == CGRect(x: 0, y: 100, width: 400, height: 200))
        #expect(ImportedImageGeometry.markerPoint(normalized: .init(x: 0.25, y: 0.75), imageSize: .init(width: 800, height: 400), containerSize: container) == CGPoint(x: 100, y: 250))
        #expect(ImportedImageGeometry.markerPoint(normalized: .init(x: 0.25, y: 0.75), imageSize: .init(width: 400, height: 800), containerSize: container) == CGPoint(x: 150, y: 300))
        #expect(ImportedImageGeometry.markerPoint(normalized: .init(x: 200, y: 200), imageSize: .init(width: 800, height: 400), containerSize: container) == nil)
        #expect(ImportedImageGeometry.markerPoint(normalized: .init(x: 0.5, y: .nan), imageSize: .init(width: 800, height: 400), containerSize: container) == nil)
        #expect(ImportedImageGeometry.imageRect(imageSize: .zero, containerSize: container) == nil)
    }

    @MainActor @Test func publicWorkspaceRenderHidesImportedPhotoQuestionAnswerAndFilename() async throws {
        _ = NSApplication.shared
        let image = try importedTestImage("PRIVATEFILE.png")
        let fixture = WorkspaceFixture(a: image, b: image), file = workspace(fixture)
        let app = AppModel(imageWorkspace: file); app.observationSource = .image
        file.importImage(at: URL(fileURLWithPath: "/fixture/a"))
        try await eventuallyImage { file.ready }
        file.question = "PRIVATEQUESTION"; file.begin(engine: "apple")
        try await eventuallyImage { !file.isAnalyzing }
        let normal = try await renderWorkspace(app)
        let normalMetrics = try await Task.detached { try snapshotMetrics(normal) }.value
        #expect(normalMetrics.magenta > 5000)
        #expect(normalMetrics.text.contains("PRIVATEANSWER"))
        app.capturingUI = true
        let redacted = try await renderWorkspace(app)
        let publicMetrics = try await Task.detached { try snapshotMetrics(redacted) }.value
        #expect(publicMetrics.magenta == 0)
        for secret in ["PRIVATEFILE", "PRIVATEQUESTION", "PRIVATEANSWER", "PRIVATEEVIDENCE", "PRIVATEUNCERTAINTY"] {
            #expect(!publicMetrics.text.contains(secret))
        }
        #expect(file.question == "PRIVATEQUESTION" && file.answer == "PRIVATEANSWER")
        #expect(file.asset?.displayName == "PRIVATEFILE.png")
    }

    @MainActor @Test func markerIsRenderedAtMappedPointAndNeverInPublicPreview() async throws {
        _ = NSApplication.shared
        let asset = try importedTestImage("SYNTHETIC")
        let image = try #require(NSImage(data: asset.previewData))
        let withMarker = try await renderPreview(image, point: .init(x: 0.8, y: 0.3), redacted: false)
        let withoutMarker = try await renderPreview(image, point: nil, redacted: false)
        let point = try #require(ImportedImageGeometry.markerPoint(normalized: .init(x: 0.8, y: 0.3),
            imageSize: .init(width: 160, height: 100), containerSize: .init(width: 400, height: 300)))
        let shownDifference = try await Task.detached {
            try changedPixels(withMarker, withoutMarker, region: CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36))
        }.value
        #expect(shownDifference > 20)
        let hiddenMarker = try await renderPreview(image, point: .init(x: 0.8, y: 0.3), redacted: true)
        let hiddenNoMarker = try await renderPreview(image, point: nil, redacted: true)
        let hiddenDifference = try await Task.detached {
            try changedPixels(hiddenMarker, hiddenNoMarker, region: CGRect(x: 0, y: 0, width: 400, height: 300))
        }.value
        #expect(hiddenDifference == 0)
    }
}

private struct RenderedImage: @unchecked Sendable { let image: CGImage }

@MainActor private func renderPreview(_ image: NSImage, point: CGPoint?, redacted: Bool) async throws -> RenderedImage {
    let view = NSHostingView(rootView: ImportedImagePreview(image: image, imageSize: .init(width: 160, height: 100), point: point, redacted: redacted))
    return try await renderView(view, size: CGSize(width: 400, height: 300))
}
private func changedPixels(_ a: RenderedImage, _ b: RenderedImage, region: CGRect) throws -> Int {
    let first = try rgbaPixels(a.image), second = try rgbaPixels(b.image)
    var count = 0
    let scale = Double(a.image.width) / 400
    for y in max(0, Int(region.minY * scale))..<min(a.image.height, Int(region.maxY * scale)) {
        for x in max(0, Int(region.minX * scale))..<min(a.image.width, Int(region.maxX * scale)) {
            let offset = (y * a.image.width + x) * 4
            let delta = (0..<3).reduce(0) { $0 + abs(Int(first[offset + $1]) - Int(second[offset + $1])) }
            if delta > 12 { count += 1 }
        }
    }
    return count
}

@MainActor private func renderWorkspace(_ model: AppModel) async throws -> RenderedImage {
    let view = NSHostingView(rootView: RootView(model: model))
    return try await renderView(view, size: CGSize(width: 1440, height: 900))
}
@MainActor private func renderView(_ view: NSView, size: CGSize) async throws -> RenderedImage {
    view.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(80))
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return RenderedImage(image: try #require(bitmap.cgImage))
}
private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
}
private func snapshotMetrics(_ snapshot: RenderedImage) throws -> (magenta: Int, text: String) {
    let pixels = try rgbaPixels(snapshot.image)
    var count = 0
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        if pixels[offset] > 216 && pixels[offset + 2] > 216 && pixels[offset + 1] < 38 { count += 1 }
    }
    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: snapshot.image).perform([request])
    return (count, (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased())
}
