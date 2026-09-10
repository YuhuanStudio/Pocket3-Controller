import AppKit
import Foundation
import Observation
import Pocket3Core
import Pocket3Intelligence
import UniformTypeIdentifiers
import YunDesign

enum ObservationSourceMode: String, CaseIterable { case camera, image }
enum ImageObservationAction: String, CaseIterable { case ask, count, locate, ocr }

struct ImportedObservationImage: Sendable {
    let frame: FramePacket
    let previewData: Data
    let displayName: String
    var videoSource: ImportedVideoSource? = nil

    static func load(_ url: URL) async throws -> Self {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if try url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .movie) == true {
            let video = try await ImportedVideoSource.open(url)
            do {
                let frame = try await video.frame(at: video.metadata.startSeconds)
                try Task.checkCancellation()
                return Self(frame: frame, previewData: try frame.jpeg(maxDimension: 1920), displayName: url.lastPathComponent, videoSource: video)
            } catch { await video.close(); throw error }
        }
        return try await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try Task.checkCancellation()
            let frame = try FramePacket.fixture(at: url)
            let preview = try frame.jpeg(maxDimension: 1920)
            try Task.checkCancellation()
            return Self(frame: frame, previewData: preview, displayName: url.lastPathComponent)
        }.value
    }
}

enum ImageObservationResponse: Sendable {
    case answer(ObservationAnswer)
    case grounding(GroundedImageResult)
    case text([String])
}

/// A file-only workspace. Its injected functions have no camera service,
/// control permission or hardware methods, including during cancellation.
@MainActor @Observable final class ImageObservationWorkspace {
    typealias Analyze = @Sendable (FramePacket, String, ImageObservationAction, String) async throws -> ImageObservationResponse
    private let load: @Sendable (URL) async throws -> ImportedObservationImage
    private let analyze: Analyze
    private(set) var asset: ImportedObservationImage?
    private(set) var preview: NSImage?
    private(set) var response: ImageObservationResponse?
    private(set) var responseFrameID: String?
    private(set) var responseSourceFrameID: String?
    private(set) var resultSnapshot: AnalysisExportSnapshot?
    private(set) var region: NormalizedImageRegion?
    var selectingRegion = false
    var videoSeekTime: Double = 0
    var videoScrubbing = false
    private(set) var isImporting = false
    private(set) var isAnalyzing = false
    private(set) var isCancelling = false
    private(set) var error: String?
    var question = ""
    var action: ImageObservationAction = .ask
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    private var importID = UUID()
    private var revision = 0
    var isWorking: Bool { isImporting || isAnalyzing }
    var ready: Bool { asset != nil && !isImporting && !videoScrubbing }

    init(load: @escaping @Sendable (URL) async throws -> ImportedObservationImage = ImportedObservationImage.load,
         analyze: @escaping Analyze) {
        self.load = load; self.analyze = analyze
    }
    convenience init(intelligence: IntelligenceEngine) {
        self.init { frame, question, action, engine in
            switch action {
            case .ask: return .answer(try await intelligence.analyze(frame: frame, question: question, engine: engine))
            case .count, .locate:
                return .grounding(try await intelligence.grounded(frame: frame, question: question,
                    kind: action == .count ? .count : .point, engine: engine))
            case .ocr: return .text(try await intelligence.recognizeText(frame: frame))
            }
        }
    }

    func importImage(at url: URL) {
        cancel(clearResult: true)
        importTask?.cancel()
        importID = UUID(); let id = importID
        let oldVideo = asset?.videoSource
        asset = nil; preview = nil; error = nil; isImporting = true
        region = nil; selectingRegion = false; videoSeekTime = 0
        importTask = Task { [self] in
            defer { if importID == id { isImporting = false; importTask = nil } }
            var importedVideo: ImportedVideoSource?
            do {
                await oldVideo?.close()
                let loaded = try await load(url)
                importedVideo = loaded.videoSource
                try Task.checkCancellation()
                guard importID == id else { await importedVideo?.close(); return }
                guard ["local_image_import", "local_video_import"].contains(loaded.frame.info.timestampSource),
                      loaded.frame.info.deviceID == "local-evaluation",
                      let image = NSImage(data: loaded.previewData) else {
                    throw BridgeFailure("fixture_image", "Imported image could not be prepared")
                }
                asset = loaded; preview = image; videoSeekTime = loaded.frame.info.presentationTime
            } catch is CancellationError { await importedVideo?.close() }
            catch {
                await importedVideo?.close()
                if importID == id { self.error = AppErrorPresentation.message(error, fallback: .mediaFile) }
            }
        }
    }

    func seek(to seconds: Double) {
        guard let current = asset, let video = current.videoSource,
              seconds.isFinite, (video.metadata.startSeconds...video.metadata.lastSeekSeconds).contains(seconds) else { return }
        cancel(clearResult: true)
        let id = UUID(); importID = id; isImporting = true; videoSeekTime = seconds
        importTask = Task { [self] in
            defer { if importID == id { isImporting = false; importTask = nil } }
            do {
                let frame = try await video.frame(at: seconds)
                let bytes = try await Task.detached { try frame.jpeg(maxDimension: 1920) }.value
                try Task.checkCancellation()
                guard importID == id, asset?.videoSource === video else { return }
                asset = ImportedObservationImage(frame: frame, previewData: bytes, displayName: current.displayName, videoSource: video)
                preview = NSImage(data: bytes); videoSeekTime = frame.info.presentationTime
            } catch is CancellationError {}
            catch {
                if importID == id {
                    videoSeekTime = asset?.frame.info.presentationTime ?? 0
                    self.error = AppErrorPresentation.message(error, fallback: .videoTime)
                }
            }
        }
    }

    func setRegion(_ value: NormalizedImageRegion?) {
        guard region != value else { selectingRegion = false; return }
        cancel(clearResult: true); region = value; selectingRegion = false
    }

    func begin(engine: String, action override: ImageObservationAction? = nil) {
        guard ready, !isAnalyzing, let asset else { return }
        let requestedAction = override ?? action
        let requestedQuestion = question, selectedRegion = region
        guard requestedAction == .ocr || !requestedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        revision += 1; let requestedRevision = revision, frameID = asset.frame.info.id
        response = nil; responseFrameID = nil; responseSourceFrameID = nil; resultSnapshot = nil; error = nil
        isAnalyzing = true; isCancelling = false
        analysisTask = Task { [self] in
            defer { isAnalyzing = false; isCancelling = false; analysisTask = nil }
            do {
                let analysisFrame = try await Task.detached {
                    try Task.checkCancellation()
                    return try selectedRegion.map { try asset.frame.cropImported(to: $0).frame } ?? asset.frame
                }.value
                try Task.checkCancellation()
                let result = try await analyze(analysisFrame, requestedQuestion, requestedAction, engine)
                try Task.checkCancellation()
                guard revision == requestedRevision, self.asset?.frame.info.id == frameID else { return }
                if case .grounding(let grounded) = result {
                    guard grounded.frame.id == analysisFrame.info.id, grounded.frame.timestampSource == analysisFrame.info.timestampSource else {
                        throw BridgeFailure("grounding_input_invalid", "Result belongs to another image")
                    }
                }
                response = result; responseFrameID = analysisFrame.info.id; responseSourceFrameID = frameID
                let exportedAction: AnalysisExportAction = switch requestedAction {
                case .ask: .question
                case .count: .count
                case .locate: .point
                case .ocr: .ocr
                }
                let grounding: JSONValue?
                if case .grounding(let value) = result { grounding = try value.metadata() } else { grounding = nil }
                resultSnapshot = try AnalysisExportSnapshot(sourceName: asset.displayName,
                    sourceKind: asset.videoSource == nil ? .image : .video, frame: analysisFrame.info,
                    engine: requestedAction == .ocr ? "vision" : engine, action: exportedAction,
                    question: requestedAction == .ocr ? "" : requestedQuestion,
                    answer: answer, evidence: evidence, uncertainties: uncertainties, grounding: grounding, createdAt: Date())
            } catch is CancellationError {}
            catch {
                if revision == requestedRevision, self.asset?.frame.info.id == frameID {
                    self.error = AppErrorPresentation.message(error, fallback: .imageAnalysis)
                }
            }
        }
    }

    func cancel(clearResult: Bool = true) {
        revision += 1
        importID = UUID(); importTask?.cancel(); importTask = nil; isImporting = false
        videoScrubbing = false
        if asset?.videoSource != nil { videoSeekTime = asset?.frame.info.presentationTime ?? 0 }
        analysisTask?.cancel()
        isCancelling = isAnalyzing
        if clearResult { response = nil; responseFrameID = nil; responseSourceFrameID = nil; resultSnapshot = nil; error = nil }
    }
    func clear() {
        cancel()
        importID = UUID(); importTask?.cancel(); importTask = nil; isImporting = false
        if let video = asset?.videoSource { Task { await video.close() } }
        asset = nil; preview = nil; question = ""; region = nil; selectingRegion = false; videoSeekTime = 0
    }
    func clearResult() { cancel(clearResult: true) }
    func cancelAndWait() async {
        let ownedAnalysis = analysisTask
        cancel()
        await ownedAnalysis?.value
    }

    var marker: CGPoint? {
        guard responseSourceFrameID == asset?.frame.info.id, case .grounding(let result) = response,
              case .point(let location) = result.value, !location.uncertain, let point = location.point,
              point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        let local = CGPoint(x: point.x, y: point.y)
        if let region = result.frame.importedRegion?.region { return try? region.mapToOriginal(local) }
        return local
    }
    var answer: String {
        guard responseSourceFrameID == asset?.frame.info.id, let response else { return "" }
        switch response {
        case .answer(let answer): return answer.answer
        case .text(let lines): return lines.isEmpty ? loc("No clear text was recognised.") : lines.joined(separator: "\n")
        case .grounding(let result):
            switch result.value {
            case .count(let count): return String(format: loc("Model count: %lld"), Int64(count.count))
            case .point(let location): return loc(location.uncertain ? "The model could not locate one clear target." : "Model location shown on the image.")
            case .absent(let presence): return loc(presence.found ? "The model reports that the target is visible." : "The model did not find the target in this image.")
            }
        }
    }
    var evidence: [String] {
        guard case .answer(let answer) = response else { return [] }
        return answer.evidence
    }
    var uncertainties: [String] {
        switch response {
        case .answer(let answer): return answer.uncertainties
        case .grounding(let result):
            if case .count(let count) = result.value, count.uncertain { return [loc("The count is uncertain.")] }
            return [loc("Model estimates can be wrong. Check the image before using this result.")]
        default: return []
        }
    }
}

extension AppModel {
    nonisolated static func requestedObservationIntent(_ arguments: JSONValue) throws -> ObservationIntent {
        guard case .object(let fields) = arguments else { throw BridgeFailure("invalid_intent", "Observation arguments must be an object") }
        guard let supplied = fields["intent"] else { return .observe }
        guard let value = supplied.string, let intent = ObservationIntent(rawValue: value) else {
            throw BridgeFailure("invalid_intent", "Use observe or assistFraming as the task intent")
        }
        return intent
    }
    var isCameraSource: Bool { observationSource == .camera }
    var cameraActionReady: Bool { isCameraSource && ready }
    var observationReady: Bool { !switchingObservationSource && (isCameraSource ? ready : imageWorkspace.ready) }
    var observationBusy: Bool { isCameraSource ? busy : imageWorkspace.isWorking }
    var canChangeObservationSource: Bool {
        !switchingObservationSource && !isConnecting && !isManualPresetBusy && !continuousGimbal.canStop
            && status?.motionActive != true && !zoom.isWorking && !roll.isWorking
    }
    var observationQuestion: String {
        get { isCameraSource ? question : imageWorkspace.question }
        set { if isCameraSource { question = newValue } else { imageWorkspace.question = newValue } }
    }
    var observationAnswer: String { isCameraSource ? answer : imageWorkspace.answer }
    var observationEvidence: [String] { isCameraSource ? evidence : imageWorkspace.evidence }
    var observationUncertainties: [String] { isCameraSource ? uncertainties : imageWorkspace.uncertainties }

    func changeObservationSource(_ source: ObservationSourceMode) async {
        guard source != observationSource, canChangeObservationSource else { return }
        switchingObservationSource = true
        defer { switchingObservationSource = false }
        observationRevision += 1
        let oldTask = aiTask
        oldTask?.cancel(); imageWorkspace.cancel()
        clearObservationPresentation()
        // Wait only for this window's previous live operation. No service
        // permission, capture or external MCP state is changed by source choice.
        await oldTask?.value
        await imageWorkspace.cancelAndWait()
        observationSource = source
        if source == .camera { imageWorkspace.clear() }
    }
    func chooseObservationImage() {
        guard !switchingObservationSource else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.prompt = loc("Open media")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if isCameraSource { await changeObservationSource(.image) }
            guard !isCameraSource else { return }
            imageWorkspace.importImage(at: url)
        }
    }
    func cancelCurrentObservation() {
        if isCameraSource {
            observationRevision += 1; aiTask?.cancel(); clearObservationPresentation()
            message = loc("Observation cancelled")
        } else { imageWorkspace.cancel() }
    }
    func clearObservationPresentation() {
        answer = ""; evidence = []; uncertainties = []; observationActions = []; observationRoles = nil
        evidenceImage = nil; evidenceFrameID = ""; message = nil
    }

    func exportImageAnalysis(format: AnalysisExportFormat) {
        guard !isCameraSource, !capturingUI, let snapshot = imageWorkspace.resultSnapshot else { return }
        do {
            // Capture immutable bytes before presenting the panel. A later
            // source/question change cannot rewrite this already chosen report.
            let data = try AnalysisExport.data(for: snapshot, format: format)
            let panel = NSSavePanel()
            panel.allowedContentTypes = format == .json ? [.json] : [.plainText]
            panel.nameFieldStringValue = format == .json ? "Pocket3-analysis.json" : "Pocket3-analysis.md"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch { message = AppErrorPresentation.message(error, fallback: .imageAnalysis) }
    }

    /// Development-only driver of the same user workspace, for reproducible
    /// offline UI acceptance where native desktop automation is unavailable.
    func handleImageWorkspace(_ request: ServiceRequest) async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("development_only", "Image workspace validation requires a development launch")
        }
        guard !capturingUI, let action = request.arguments["action"].string else {
            throw BridgeFailure("image_workspace_busy", "Pass an action outside UI capture")
        }
        switch action {
        case "import":
            guard let path = request.arguments["imagePath"].string, path.hasPrefix("/") else {
                throw BridgeFailure("fixture_image", "Pass an absolute imagePath")
            }
            if isCameraSource { await changeObservationSource(.image) }
            guard !isCameraSource else { throw BridgeFailure("image_workspace_busy", "A camera operation must finish before switching source") }
            imageWorkspace.importImage(at: URL(fileURLWithPath: path))
        case "run", "ocr":
            guard !isCameraSource, observationReady, !aiWorking else { throw BridgeFailure("ai_busy", "Image workspace is not ready") }
            let engine = request.arguments["engine"].string ?? selectedEngine
            guard ["apple", "mlx"].contains(engine) else { throw BridgeFailure("invalid_engine", "Use apple or mlx") }
            let kind = action == "ocr" ? ImageObservationAction.ocr : ImageObservationAction(rawValue: request.arguments["kind"].string ?? "ask")
            guard let kind else { throw BridgeFailure("invalid_grounding_kind", "Use ask, count or locate") }
            selectedEngine = engine
            imageWorkspace.question = request.arguments["question"].string ?? imageWorkspace.question
            imageWorkspace.action = kind == .ocr ? .ask : kind
            imageWorkspace.begin(engine: engine, action: kind)
        case "cancel": imageWorkspace.cancel()
        case "seek":
            guard let time = request.arguments["seconds"].number, let video = imageWorkspace.asset?.videoSource,
                  time.isFinite, (video.metadata.startSeconds...video.metadata.lastSeekSeconds).contains(time) else { throw BridgeFailure("video_time_range", "Choose a time within this clip") }
            imageWorkspace.seek(to: time)
        case "region":
            if request.arguments["region"] == .null { imageWorkspace.setRegion(nil) }
            else {
                let region = try JSONDecoder().decode(NormalizedImageRegion.self, from: JSONEncoder().encode(request.arguments["region"]))
                imageWorkspace.setRegion(region)
            }
        case "export":
            guard let snapshot = imageWorkspace.resultSnapshot, let path = request.arguments["output"].string, path.hasPrefix("/"),
                  let format = AnalysisExportFormat(rawValue: request.arguments["format"].string ?? "json") else {
                throw BridgeFailure("export_unavailable", "Choose a completed result, format and absolute output file")
            }
            try AnalysisExport.data(for: snapshot, format: format).write(to: URL(fileURLWithPath: path), options: .atomic)
        case "clear": imageWorkspace.clear()
        case "camera": await changeObservationSource(.camera)
        case "status": break
        default: throw BridgeFailure("invalid_image_workspace_action", "Unknown image workspace action")
        }
        let file = imageWorkspace
        var result: [String: JSONValue] = ["source": .string(observationSource.rawValue),
            "ready": .bool(observationReady), "busy": .bool(file.isWorking), "importing": .bool(file.isImporting),
            "analysing": .bool(file.isAnalyzing), "cancelling": .bool(file.isCancelling),
            "answer": .string(file.answer), "evidence": .array(file.evidence.map(JSONValue.string)),
            "uncertainties": .array(file.uncertainties.map(JSONValue.string)), "error": file.error.map(JSONValue.string) ?? .null,
            "frame": try file.asset.map { try JSONValue.encode($0.frame.info) } ?? .null,
            "responseFrameID": file.responseFrameID.map(JSONValue.string) ?? .null,
            "responseSourceFrameID": file.responseSourceFrameID.map(JSONValue.string) ?? .null,
            "region": try file.region.map(JSONValue.encode) ?? .null,
            "video": try (file.asset?.videoSource?.metadata).map(JSONValue.encode) ?? .null,
            "videoSeekTime": .number(file.videoSeekTime),
            "exportAvailable": .bool(file.resultSnapshot != nil), "aiBusy": .bool(aiWorking),
            "marker": file.marker.map { .object(["x": .number($0.x), "y": .number($0.y)]) } ?? .null,
            "cameraActionReady": .bool(cameraActionReady), "cameraAccess": .string(access.rawValue)]
        if case .grounding(let grounding) = file.response { result["grounding"] = try grounding.metadata() }
        return ServiceReply(id: request.id, result: .object(result))
    }
}
