import Foundation
import CryptoKit
import Testing
@testable import Pocket3Core
@testable import Pocket3Intelligence

/// Explicit opt-in only. These tests use real local models with a simulated
/// camera; they never construct CameraService, discover USB, or open a camera.
@Suite(.serialized)
struct RealModelZoomIntegrationTests {
    @Test(.enabled(if: ModelZoomCheck.requested("apple")), .timeLimit(.minutes(3)))
    func appleAnswerWithMLXControlUsesSimulationOnly() async throws {
        try await ModelZoomCheck.run(engine: "apple")
    }

    @Test(.enabled(if: ModelZoomCheck.requested("mlx")), .timeLimit(.minutes(3)))
    func cachedMLXModelUsesZoomToolsWithSimulationOnly() async throws {
        try await ModelZoomCheck.run(engine: "mlx")
    }
}

private enum ModelZoomCheck {
    static func requested(_ engine: String) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let enabled = environment["POCKET3_ZOOM_MODEL_CHECK"]?.lowercased()
        let selected = environment["POCKET3_ZOOM_MODEL_ENGINE"]?.lowercased()
        return enabled == engine || (enabled == "1" && (selected == nil || selected == "all" || selected == engine))
    }

    private static var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private static func path(_ environmentKey: String, fallback: URL) throws -> URL {
        guard let value = ProcessInfo.processInfo.environment[environmentKey] else { return fallback }
        guard !value.isEmpty, !value.contains("://") else {
            throw BridgeFailure("model_check_local_path", "\(environmentKey) must be a local filesystem path")
        }
        return URL(fileURLWithPath: value, relativeTo: project).standardizedFileURL
    }
    private static func write(_ report: [String: JSONValue], at directory: URL) throws {
        let data = try JSONEncoder().encode(JSONValue.object(report))
        try data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func run(engine: String) async throws {
        let directory = try path("POCKET3_ZOOM_MODEL_OUTPUT", fallback: project.appendingPathComponent("artifacts/model-zoom-check"))
            .appendingPathComponent("\(engine)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report: [String: JSONValue] = [
            "status": .string("started"), "passed": .bool(false), "simulation": .bool(true),
            "physicalCameraAccess": .bool(false), "engine": .string(engine),
            "modelDownloadRequested": .bool(false), "modelSource": .string("existing on-device model or local pinned MLX snapshot only"),
            "maximumObservations": .number(1), "maximumToolCalls": .number(6), "maximumZoomToolCalls": .number(3),
            "observationBudgetSeconds": .number(90), "testTimeLimitSeconds": .number(180),
            "expectedZoomRaw": .number(200), "outputDirectory": .string(directory.path)
        ]
        try write(report, at: directory)
        print("MODEL_ZOOM_CHECK_START \(engine) \(directory.path)")

        #if DEBUG
        do {
            // Both cases use MLX for this control-enabled simulation.
            // This must precede IntelligenceEngine, fixture CIContext creation,
            // model status/loading and every GPU/MLX call. Missing resources
            // become a durable unavailable report instead of a native abort.
            do {
                report["metalLibrary"] = try ModelZoomMetalResource.prepare(project: project)
                try write(report, at: directory)
            } catch {
                let failure = error as? BridgeFailure ?? BridgeFailure("model_check_unavailable", error.localizedDescription)
                report["status"] = .string("unavailable")
                report["error"] = try .encode(failure)
                try write(report, at: directory)
                print("MODEL_ZOOM_CHECK_UNAVAILABLE \(engine) \(directory.path)")
                throw failure
            }
        }
        let intelligence = IntelligenceEngine()
        var camera: SimulatedObservationCamera?
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let beforeURL = try path("POCKET3_ZOOM_BEFORE_IMAGE", fallback: project.appendingPathComponent("artifacts/evaluation/fixtures/colours.png"))
            let afterURL = try path("POCKET3_ZOOM_AFTER_IMAGE", fallback: project.appendingPathComponent("artifacts/evaluation/fixtures/heldout-colours.png"))
            let before = try FramePacket.fixture(at: beforeURL)
            let after = try FramePacket.fixture(at: afterURL)
            let beforeHash = digest(try Data(contentsOf: beforeURL)), afterHash = digest(try Data(contentsOf: afterURL))
            guard beforeHash != afterHash else { throw BridgeFailure("model_check_distinct_images", "Use distinct local before/after images so a stale frame cannot pass") }
            report["beforeImage"] = .object(["path": .string(beforeURL.path), "sha256": .string(beforeHash)])
            report["afterImage"] = .object(["path": .string(afterURL.path), "sha256": .string(afterHash)])

            if engine == "apple" {
                let availability = await intelligence.status()
                report["modelAvailability"] = try .encode(availability)
                guard availability.available else {
                    throw BridgeFailure("model_check_unavailable", "Apple on-device model is unavailable: \(availability.detail)")
                }
            }
            do {
                let availability = await intelligence.localModel.status()
                report["controllerModelAvailability"] = try .encode(availability)
                guard availability.available else {
                    throw BridgeFailure("model_check_unavailable", "Pinned MLX weights are not already cached; this test will not download them")
                }
                let snapshot = try await intelligence.localModel.modelDirectory()
                let required = ["model.safetensors", "config.json", "tokenizer.json", "tokenizer_config.json"]
                for name in required {
                    let file = snapshot.appendingPathComponent(name)
                    guard FileManager.default.isReadableFile(atPath: file.path),
                          (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
                        throw BridgeFailure("model_check_unavailable", "Local MLX cache is incomplete: \(name); no download attempted")
                    }
                }
                guard ["processor_config.json", "preprocessor_config.json"].contains(where: {
                    FileManager.default.isReadableFile(atPath: snapshot.appendingPathComponent($0).path)
                }) else { throw BridgeFailure("model_check_unavailable", "Local MLX image processor configuration is missing; no download attempted") }
                report["localModelSnapshot"] = .string(snapshot.path)
                report["modelRevision"] = .string(LocalModelManager.revision)
                // Audited pinned dependency path: ModelFactory.resolve(.directory)
                // never calls Downloader; AutoTokenizer.from(modelFolder:) reads
                // local JSON and documents hubApi as unused for local loading.
                // load() also checks the existing weights' SHA-256. No download()
                // or repository-id model configuration is used by this test.
            }

            let simulation = SimulatedObservationCamera(before: before, after: after, access: .control,
                moveValidated: false, zoomCapabilities: .init(current: 100, minimum: 100, maximum: 400, step: 1, writable: true))
            camera = simulation
            let gate = try await simulation.beginObservation(origin: .manual)
            report["initialPermissions"] = .object(["canMove": .bool(gate.canMove), "canZoom": .bool(gate.canZoom)])
            guard !gate.canMove, gate.canZoom else { throw BridgeFailure("model_check_gate", "Expected zoom control without validated gimbal movement") }
            let question = """
                這是使用本地測試圖片的離線模擬驗收，沒有連接實體相機。
                請先呼叫 camera_zoom_status，再且只呼叫一次 camera_set_zoom，rawValue 必須為整數 200。
                縮放工具成功後，再呼叫 capture_frame 取得模擬相機的新影格，然後根據新圖用一句繁體中文描述看到的主要顏色或物件。
                回答中明確說明這是模擬，不要宣稱實體相機動過；200 是原始刻度，不是 2 倍。
                不要呼叫 move_gimbal、OCR 或條碼工具，不要重試任何縮放。
                """
            report["prompt"] = .string(question)
            report["observationsAttempted"] = .number(1)
            try write(report, at: directory)
            // Exactly one real-model observe call, through the same production
            // Apple/MLX tool factory and tool/response deadlines as the App.
            let result = try await intelligence.observe(service: simulation, question: question, engine: engine, origin: .manual)
            report["result"] = try result.metadata()
            let simulationReport = await simulation.report()
            report["simulationReport"] = simulationReport
            try result.imageJPEG.write(to: directory.appendingPathComponent("post-zoom.jpg"), options: .atomic)
            let expectedJPEGHash = digest(try after.jpeg(maxDimension: 1280))
            report["postZoomJPEGHash"] = .string(digest(result.imageJPEG))
            report["expectedAfterJPEGHash"] = .string(expectedJPEGHash)
            let actions = result.actions
            let sets = actions.enumerated().filter { $0.element.tool == "camera_set_zoom" }
            let set = sets.first
            let zoomFrame = set?.element.postActionFrame
            let statusIndex = actions.firstIndex { $0.tool == "camera_zoom_status" }
            let captureIndex = actions.lastIndex { $0.tool == "capture_frame" }
            let checks: [String: Bool] = [
                "independentZoomGate": !gate.canMove && gate.canZoom,
                "truthfulExecutionRoles": result.executionRoles == .init(controllerEngine: "mlx", answerEngine: engine, finalFrameRefresh: engine == "apple" ? "app" : nil),
                "singleZoomRaw200": sets.count == 1 && set?.element.zoom?.target == 200 && set?.element.zoom?.observed == 200,
                "statusBeforeSet": statusIndex != nil && set != nil && statusIndex! < set!.offset,
                "explicitFreshCaptureAfterSet": captureIndex != nil && set != nil && captureIndex! > set!.offset,
                "verifiedSimulationReadback": set?.element.zoom?.completed == true && set?.element.zoom?.verified == true && set?.element.zoom?.verification == "simulation_only",
                "postZoomFramePresent": zoomFrame != nil && zoomFrame?.id == set?.element.frameID && zoomFrame?.timestampSource == "simulated_frame",
                "sameSessionAfterZoom": zoomFrame?.sessionID == result.frame.sessionID && result.frame.sessionID == gate.stamp.sessionID,
                "latestFrameAfterZoomEvidence": zoomFrame != nil && result.frame.receivedUptime >= zoomFrame!.receivedUptime,
                "afterImageDelivered": digest(result.imageJPEG) == expectedJPEGHash,
                "noGimbalCalls": !actions.contains { $0.tool == "move_gimbal" } && simulationReport["directions"] == .array([]),
                "oneSimulatedWrite": simulationReport["zoomRequests"] == .array([.number(200)]) && simulationReport["appliedZooms"] == .array([.number(200)]),
                "boundedToolsWithoutFailures": actions.count <= 6 && actions.allSatisfy { $0.failureCode == nil },
                "answerNamesSimulation": result.answer.answer.localizedCaseInsensitiveContains("simulation") || result.answer.answer.contains("模擬") || result.answer.answer.contains("模拟")
            ]
            report["checks"] = .object(checks.mapValues(JSONValue.bool))
            let failed = checks.filter { !$0.value }.keys.sorted()
            guard failed.isEmpty else { throw BridgeFailure("model_zoom_acceptance_failed", "Failed checks: \(failed.joined(separator: ", "))") }
            await intelligence.cancelObservation()
            await intelligence.localModel.unload()
            report["status"] = .string("passed"); report["passed"] = .bool(true)
            report["elapsedSeconds"] = .number(ProcessInfo.processInfo.systemUptime - started)
            try write(report, at: directory)
            print("MODEL_ZOOM_CHECK_PASSED \(engine) \(directory.path)")
        } catch {
            await intelligence.cancelObservation()
            await intelligence.localModel.unload()
            let failure = error as? BridgeFailure ?? BridgeFailure("model_zoom_check_failed", error.localizedDescription)
            report["status"] = .string(failure.code == "model_check_unavailable" ? "unavailable" : "failed")
            report["error"] = try .encode(failure)
            if let camera { report["simulationReport"] = await camera.report() }
            report["elapsedSeconds"] = .number(ProcessInfo.processInfo.systemUptime - started)
            try write(report, at: directory)
            print("MODEL_ZOOM_CHECK_FAILED \(engine) \(directory.path)")
            throw error
        }
        #else
        let failure = BridgeFailure("model_check_requires_debug", "Use swift test -c debug: the simulated camera is deliberately excluded from release builds")
        report["status"] = .string("unavailable"); report["error"] = try .encode(failure)
        try write(report, at: directory)
        throw failure
        #endif
    }
}
