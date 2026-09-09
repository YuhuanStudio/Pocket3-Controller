import Foundation
import FoundationModels
import HuggingFace
import Tokenizers
import MLXVLM
import MLXLMCommon
import MLXHuggingFace
import MLXFoundationModels
import Pocket3Core
import CryptoKit
import MLX

public struct LocalModelStatus: Codable, Sendable {
    public var name = "Qwen 3.5 · 4B"
    public var repository = "mlx-community/Qwen3.5-4B-4bit"
    public var revision = "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c"
    public var phase = "notDownloaded"
    public var progress = 0.0
    public var expectedBytes: Int64 = 3_061_121_787
    public var message = "4-bit VLM · 約 3.1 GB · 本地 GPU 推論"
    public var available = false
    public var hasDownload = false
    public var activeMemoryBytes = 0
    public var cacheMemoryBytes = 0
    public var peakMemoryBytes = 0
}

public actor LocalModelManager {
    public static let repository = "mlx-community/Qwen3.5-4B-4bit"
    public static let revision = "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c"
    public static var root: URL { BridgePaths.directory.appendingPathComponent("Models", isDirectory: true) }
    typealias DownloadOverride = @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> Void
    private let cache: HubCache
    private let rootURL: URL
    private let downloadOverride: DownloadOverride?
    private var downloadID: UUID?
    private var deleting = false
    private var integrityRejected = false
    private var state = LocalModelStatus()
    private var downloadTask: Task<Void, Error>?
    private var model: MLXLanguageModel?
    private var loadTask: Task<MLXLanguageModel, Error>?
    private var lifecycle = 0
    private var unloading = false
    public init(rootURL: URL = LocalModelManager.root) {
        self.rootURL = rootURL; cache = HubCache(cacheDirectory: rootURL); downloadOverride = nil
    }
    init(rootURL: URL, download: @escaping DownloadOverride) {
        self.rootURL = rootURL; cache = HubCache(cacheDirectory: rootURL); downloadOverride = download
    }
    private var repo: Repo.ID { Repo.ID(rawValue: Self.repository)! }
    public func modelDirectory() throws -> URL { try cache.snapshotPath(repo: repo, kind: .model, commitHash: Self.revision) }
    private func exists() -> Bool {
        guard let directory = try? modelDirectory(),
              let size = try? directory.appendingPathComponent("model.safetensors").resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size == 3_034_300_695 && FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path)
    }
    public func status() -> LocalModelStatus {
        state.hasDownload = FileManager.default.fileExists(atPath: cache.repoDirectory(repo: repo, kind: .model).path)
        if downloadTask == nil && loadTask == nil && !unloading && model == nil && state.phase != "error" && state.phase != "cancelled" && !integrityRejected && exists() { state.phase = "downloaded"; state.available = true; state.progress = 1 }
        if model != nil || loadTask != nil {
            let memory = Memory.snapshot()
            state.activeMemoryBytes = memory.activeMemory; state.cacheMemoryBytes = memory.cacheMemory; state.peakMemoryBytes = memory.peakMemory
        }
        return state
    }
    public func download() async throws {
        if let task = downloadTask { return try await task.value }
        guard loadTask == nil && model == nil && !unloading && !deleting else { throw BridgeFailure("model_busy", "請先卸載模型再重新下載") }
        let id = UUID(); downloadID = id
        state.available = false
        state.phase = "downloading"; state.message = "正在下載固定版本權重…"; state.progress = 0
        let task = Task { [self] in
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let progress: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { await self?.updateProgress(fraction, id: id) }
            }
            if let downloadOverride {
                try await downloadOverride(modelDirectory(), progress)
            } else {
                let hub = HubClient(host: URL(string: "https://huggingface.co")!, tokenProvider: .none, cache: cache)
                _ = try await hub.downloadSnapshot(of: repo, revision: Self.revision,
                    matching: ["*.json", "*.safetensors", "*.jinja", "*.txt", "*.model"], maxConcurrentDownloads: 3,
                    progressHandler: { progress($0.fractionCompleted) })
            }
            try Task.checkCancellation()
            guard exists() else { throw BridgeFailure("model_incomplete", "模型權重下載不完整，請重試") }
            state.message = "正在驗證模型 SHA-256…"
            try await ModelIntegrity.verifyAsync(url: modelDirectory().appendingPathComponent("model.safetensors"), bytes: 3_034_300_695, sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db")
        }
        downloadTask = task
        do {
            try await task.value
            integrityRejected = false; downloadID = nil; downloadTask = nil
            state.phase = "downloaded"; state.progress = 1; state.available = true; state.message = "已下載，可離線使用"
        } catch {
            if (error as? BridgeFailure)?.code == "model_checksum" { integrityRejected = true }
            downloadTask = nil; downloadID = nil
            state.phase = error is CancellationError ? "cancelled" : "error"
            state.available = exists() && !integrityRejected
            state.message = error is CancellationError ? "下載已取消，可稍後繼續" : error.localizedDescription
            throw error
        }
    }
    private func updateProgress(_ fraction: Double, id: UUID) {
        if state.phase == "downloading" && downloadID == id { state.progress = min(1, max(0, fraction)) }
    }
    public func cancelDownload() { downloadTask?.cancel() }
    public func load() async throws -> MLXLanguageModel {
        guard !unloading && !deleting else { throw BridgeFailure("model_busy", "模型正在卸載") }
        if let model { return model }
        if let task = loadTask {
            let generation = lifecycle
            let candidate = try await task.value
            guard generation == lifecycle && !unloading else { throw CancellationError() }
            return candidate
        }
        guard downloadTask == nil else { throw BridgeFailure("model_busy", "請等待模型下載及校驗完成") }
        guard exists() else { throw BridgeFailure("model_not_downloaded", "請先在 AI 引擎頁下載 Qwen 3.5 模型") }
        lifecycle += 1; let generation = lifecycle
        state.phase = "loading"; state.message = "正在載入本地模型…"
        let directory = try modelDirectory()
        let task = Task { [directory] in
            let configuration = ModelConfiguration(directory: directory, extraEOSTokens: ["<|im_end|>"], toolCallFormat: .qwen35, reasoningConfig: .thinkTagsWithEnableThinking)
            let candidate = MLXLanguageModel(configuration: configuration, capabilities: [.vision, .guidedGeneration, .toolCalling], weightsLocation: { _ in directory }, load: { configuration, _ in
                let hub = HubClient(host: URL(string: "https://huggingface.co")!, tokenProvider: .none, cache: nil)
                return try await VLMModelFactory.shared.loadContainer(from: #hubDownloader(hub), using: #huggingFaceTokenizerLoader(), configuration: configuration)
            })
            do {
                try Task.checkCancellation()
                // The snapshot directory alone does not establish integrity.
                // Recheck before loading, including after a failed download.
                try await ModelIntegrity.verifyAsync(url: directory.appendingPathComponent("model.safetensors"), bytes: 3_034_300_695, sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db")
                try await candidate.preload()
                try Task.checkCancellation()
                return candidate
            } catch { await candidate.evict(); throw error }
        }
        loadTask = task
        do {
            let candidate = try await task.value
            guard generation == lifecycle else { await candidate.evict(); throw CancellationError() }
            integrityRejected = false; model = candidate; loadTask = nil
            state.phase = "loaded"; state.message = "已載入 · MLX／GPU"; state.available = true
            return candidate
        } catch {
            if generation == lifecycle {
                if (error as? BridgeFailure)?.code == "model_checksum" { integrityRejected = true }
                loadTask = nil; state.phase = "error"; state.available = false; state.message = error.localizedDescription
            }
            throw error
        }
    }
    public func unload() async {
        guard !unloading, downloadTask == nil, model != nil || loadTask != nil else { return }
        unloading = true; lifecycle += 1
        state.phase = "unloading"; state.message = "正在卸載推論權重…"
        let pending = loadTask; pending?.cancel()
        if let candidate = try? await pending?.value { await candidate.evict() }
        if let model { await model.evict() }
        model = nil; loadTask = nil; unloading = false
        Memory.clearCache()
        let memory = Memory.snapshot(); state.activeMemoryBytes = memory.activeMemory; state.cacheMemoryBytes = memory.cacheMemory; state.peakMemoryBytes = memory.peakMemory
        state.phase = integrityRejected ? "error" : (exists() ? "downloaded" : "notDownloaded"); state.available = exists() && !integrityRejected; state.message = "已卸載推論權重，下載檔案保留"
    }
    public func deleteDownload() async throws {
        guard downloadTask == nil && !unloading && !deleting else { throw BridgeFailure("model_busy", "請先取消下載或等待卸載完成") }
        deleting = true; defer { deleting = false }
        await unload()
        let directory = cache.repoDirectory(repo: repo, kind: .model)
        guard directory.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path + "/") else { throw BridgeFailure("invalid_path", "模型路徑不在 App 專用資料夾") }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        integrityRejected = false; state = LocalModelStatus()
    }
}
