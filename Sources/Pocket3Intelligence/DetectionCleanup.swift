import Foundation

/// Set-prediction models can still produce duplicate boxes. Suppress only a
/// lower-confidence box of the same class, preserving overlapping objects of
/// different classes and returning normalised coordinates within the image.
public enum DetectionCleanup {
    public static func apply(_ input: [DetectedItem], overlapThreshold: Double = 0.7) -> [DetectedItem] {
        var selected: [DetectedItem] = []
        for item in input.filter({ $0.confidence.isFinite }).sorted(by: { $0.confidence > $1.confidence }) {
            guard item.confidence.isFinite, (0...1).contains(item.confidence),
                  [item.x,item.y,item.width,item.height].allSatisfy(\.isFinite), item.width > 0, item.height > 0 else { continue }
            var box = item
            let right = min(1, item.x + item.width), bottom = min(1, item.y + item.height)
            box.x = max(0, item.x); box.y = max(0, item.y)
            box.width = right - box.x; box.height = bottom - box.y
            guard box.width > 0, box.height > 0 else { continue }
            if selected.contains(where: { $0.label == box.label && overlap($0, box) > overlapThreshold }) { continue }
            selected.append(box)
        }
        return selected
    }
    private static func overlap(_ a: DetectedItem, _ b: DetectedItem) -> Double {
        let width = max(0, min(a.x+a.width,b.x+b.width)-max(a.x,b.x))
        let height = max(0, min(a.y+a.height,b.y+b.height)-max(a.y,b.y))
        let intersection = width*height
        return intersection / max(1e-12, a.width*a.height+b.width*b.height-intersection)
    }
}
