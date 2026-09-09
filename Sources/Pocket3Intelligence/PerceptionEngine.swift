import Foundation
import CoreAI
import CoreAIObjectDetector
import CoreImage
import Pocket3Core

public struct DetectedItem: Codable, Sendable, Identifiable {
    public var id: Int
    public var label: String
    public var confidence: Float
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}
public struct PerceptionResult: Codable, Sendable {
    public var model = "YOLOS tiny · Core AI"
    public var frameID: String
    public var loadingSeconds: Double
    public var inferenceSeconds: Double
    public var executionDevice = "Core AI 自動選擇；未由此結果證明使用 ANE"
    public var postprocessing = "same-class duplicate suppression; IoU 0.7"
    public var requestedComputeMode = "automatic"
    public var availableComputeUnits: [String] = []
    public var architecture = ""
    public var objects: [DetectedItem]
}
public actor PerceptionEngine {
    private var detectors: [PerceptionComputeMode: ObjectDetector] = [:]
    private let path: String
    private var running = false
    public init(path: String) { self.path = path }
    public func detect(frame: FramePacket, mode: PerceptionComputeMode = .automatic) async throws -> PerceptionResult {
        guard !running else { throw BridgeFailure("perception_busy", "物件偵測正在執行") }
        running = true; defer { running = false }
        let start = ProcessInfo.processInfo.systemUptime
        if detectors[mode] == nil { detectors[mode] = try await ObjectDetector(resourcesAt: path, options: mode.options) }
        let loaded = ProcessInfo.processInfo.systemUptime
        let ci = CIImage(cvPixelBuffer: frame.pixelBuffer)
        guard let image = CIContext().createCGImage(ci, from: ci.extent), let detector = detectors[mode] else { throw BridgeFailure("perception_image", "無法建立感知圖片") }
        var parameters = DetectionParameters.default; parameters.threshold = 0.55; parameters.maxDetections = 12
        let result = try await detector.detect(images: [image], parameters: parameters)
        return PerceptionResult(frameID: frame.info.id, loadingSeconds: loaded-start, inferenceSeconds: ProcessInfo.processInfo.systemUptime-loaded, executionDevice: mode.report, requestedComputeMode: mode.rawValue, availableComputeUnits: ComputeUnitKind.availableKinds.map(String.init(describing:)).sorted(), architecture: AIModel.deviceArchitectureName, objects: DetectionCleanup.apply((result.first ?? []).enumerated().map { index, item in
            DetectedItem(id: index, label: item.label, confidence: item.confidence, x: item.boundingBox.minX/Double(image.width), y: item.boundingBox.minY/Double(image.height), width: item.boundingBox.width/Double(image.width), height: item.boundingBox.height/Double(image.height))
        }))
    }
    public func unload() throws {
        guard !running else { throw BridgeFailure("perception_busy", "請等待物件偵測結束") }
        detectors.removeAll()
    }
    #if DEBUG
    public func probe(frame: FramePacket, mode: PerceptionComputeMode = .automatic) async throws -> DetectionProbe {
        guard !running else { throw BridgeFailure("perception_busy", "物件偵測正在執行") }
        running = true; defer { running = false }
        if detectors[mode] == nil { detectors[mode] = try await ObjectDetector(resourcesAt: path, options: mode.options) }
        let ci = CIImage(cvPixelBuffer: frame.pixelBuffer)
        guard let image = CIContext().createCGImage(ci, from: ci.extent), let detector = detectors[mode] else { throw BridgeFailure("perception_image", "無法建立圖片") }
        return try await detector.evaluationProbe(image: image)
    }
    #endif
}

public enum PerceptionComputeMode: String, Codable, CaseIterable, Sendable {
    case automatic, cpu, gpu, neuralEngine
    var options: SpecializationOptions {
        switch self {
        case .automatic: .init(preferredComputeUnitKind: .gpu)
        case .cpu: .cpuOnly
        case .gpu: .init(preferredComputeUnitKind: .gpu)
        case .neuralEngine: .init(preferredComputeUnitKind: .neuralEngine)
        }
    }
    var report: String {
        self == .cpu ? "CPU only (Core AI specialization constraint)" : "Requested \(self == .automatic ? "automatic (GPU preferred)" : rawValue); actual device requires Instruments evidence, fallback is allowed"
    }
}
