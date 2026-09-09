import Testing
@testable import Pocket3Intelligence

@Test func duplicateDetectionsPreserveDifferentClassesAndSeparateObjects() {
    let items = [
        DetectedItem(id: 1, label: "remote", confidence: 0.99, x: 0.1, y: 0.1, width: 0.2, height: 0.2),
        DetectedItem(id: 2, label: "remote", confidence: 0.9, x: 0.105, y: 0.105, width: 0.2, height: 0.2),
        DetectedItem(id: 3, label: "cat", confidence: 0.85, x: 0.1, y: 0.1, width: 0.2, height: 0.2),
        DetectedItem(id: 4, label: "remote", confidence: 0.8, x: 0.6, y: 0.1, width: 0.2, height: 0.2)
    ]
    #expect(DetectionCleanup.apply(items).map(\.id) == [1,3,4])
}
@Test func invalidBoxesAreRejectedAndEdgesAreClipped() {
    let items = [
        DetectedItem(id: 1, label: "cat", confidence: 0.9, x: -0.1, y: 0.8, width: 0.3, height: 0.4),
        DetectedItem(id: 2, label: "cat", confidence: .nan, x: 0, y: 0, width: 1, height: 1),
        DetectedItem(id: 3, label: "cat", confidence: 0.8, x: 2, y: 2, width: 1, height: 1)
    ]
    let result = DetectionCleanup.apply(items)
    #expect(result.count == 1)
    #expect(result[0].x == 0 && result[0].y + result[0].height == 1)
}
