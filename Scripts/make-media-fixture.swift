import AppKit
@preconcurrency import AVFoundation
import CoreImage
import Foundation

// Synthetic pixels only: no capture device, audio input, or private photograph.
@MainActor private func scene(_ second: Bool) throws -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 360, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 2560, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    (second ? NSColor(calibratedRed: 0.75, green: 1, blue: 0.75, alpha: 1) : .white).setFill()
    NSRect(x: 0, y: 0, width: 640, height: 360).fill()
    NSColor.systemRed.setFill(); NSRect(x: 80, y: 120, width: 120, height: 120).fill()
    NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: NSRect(x: 420, y: 120, width: 120, height: 120)).fill()
    ((second ? "FRAME B" : "FRAME A") as NSString).draw(at: NSPoint(x: 48, y: 280),
        withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 44, weight: .bold), .foregroundColor: NSColor.black])
    return bitmap
}

private func finish(_ writer: AVAssetWriter) async throws {
    try await withCheckedThrowingContinuation { continuation in
        writer.finishWriting {
            if writer.status == .completed { continuation.resume() }
            else { continuation.resume(throwing: writer.error ?? NSError(domain: "MediaFixture", code: 3)) }
        }
    }
}

private func makeFixtures(at directory: URL) async throws {
    let a = try await scene(false), b = try await scene(true)
    try a.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("media-shapes.png"))
    let writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("media-two-scenes.mp4"), fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264.rawValue,
        AVVideoWidthKey: 640, AVVideoHeightKey: 360, AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 30]])
    // macOS 26+ receiver ownership replaces the deprecated adaptor/input state
    // machine. The fixture remains entirely local synthetic media.
    let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
    try writer.start(); writer.startSession(atSourceTime: .zero)
    let context = CIContext(options: [.cacheIntermediates: false])
    for index in 0..<60 {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw NSError(domain: "MediaFixture", code: 1) }
        context.render(CIImage(cgImage: (index < 30 ? a : b).cgImage!), to: buffer)
        try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer: buffer), with: CMTime(value: Int64(index), timescale: 30))
    }
    receiver.finish()
    try await finish(writer)
    let metadata: [String: Any] = ["synthetic": true, "cameraUsed": false, "audioInputUsed": false,
        "width": 640, "height": 360, "fps": 30, "frames": 60, "expectedDurationSeconds": 2,
        "image": "media-shapes.png", "video": "media-two-scenes.mp4", "blueCircleCenter": ["x": 0.75, "y": 0.5],
        "scenes": [["start": 0, "end": 1, "label": "FRAME A"], ["start": 1, "end": 2, "label": "FRAME B"]]]
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("fixtures.json"))
}

guard CommandLine.arguments.count == 2 else { fatalError("Pass a new fixture directory") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard !FileManager.default.fileExists(atPath: directory.path) else { fatalError("Fixture directory already exists") }
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
Task {
    do {
        try await makeFixtures(at: directory)
        print("Synthetic image and two-second video prepared.")
        exit(0)
    } catch {
        fputs("Media fixture failed: \(error)\n", stderr)
        exit(1)
    }
}
dispatchMain()
