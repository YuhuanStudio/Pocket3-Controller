import Foundation
import ImageIO
import Vision

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Cannot decode fixture") }
var trials: [[String: Any]] = []
for iteration in 0..<6 {
    let started = ProcessInfo.processInfo.systemUptime
    let request = VNRecognizeAnimalsRequest()
    try VNImageRequestHandler(cgImage: image).perform([request])
    let seconds = ProcessInfo.processInfo.systemUptime - started
    let objects = (request.results ?? []).map { observation in
        ["label": observation.labels.first?.identifier ?? "unknown", "confidence": observation.labels.first?.confidence ?? 0] as [String: Any]
    }
    trials.append(["iteration": iteration, "seconds": seconds, "objects": objects])
}
let times = trials.dropFirst().map { $0["seconds"] as! Double }.sorted()
let result: [String: Any] = ["backend":"Vision VNRecognizeAnimalsRequest", "scope":"Cats and dogs only; not equivalent to general COCO detection", "imageWidth":image.width, "imageHeight":image.height, "cameraUsed":false, "trials":trials, "warmMedianSeconds":times[times.count/2]]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
print("Vision warm median: \(times[times.count/2]) seconds")
