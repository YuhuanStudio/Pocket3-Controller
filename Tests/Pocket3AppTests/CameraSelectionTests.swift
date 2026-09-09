import Foundation
import Testing
@testable import Pocket3BridgeApp

@Suite("Camera selection preferences") struct CameraSelectionTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "Pocket3CameraSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @Test func explicitChoicePersistsAndRestoresOnlyTheSameDevice() {
        withDefaults { defaults in
            var selection = CameraSelection(defaults: defaults)
            selection.select("camera-a", availableIDs: ["camera-a", "camera-b"])
            #expect(defaults.string(forKey: CameraSelection.preferenceKey) == "camera-a")

            var reopened = CameraSelection(defaults: defaults)
            reopened.refresh(availableIDs: ["camera-a"])
            #expect(reopened.selectedID == "camera-a")
            reopened.refresh(availableIDs: ["camera-b"])
            #expect(reopened.selectedID.isEmpty)
            #expect(reopened.preferredID == "camera-a")
            reopened.refresh(availableIDs: [])
            reopened.refresh(availableIDs: ["camera-b"])
            #expect(reopened.selectedID.isEmpty)
        }
    }

    @Test func multipleCamerasRequireAnExplicitChoice() {
        withDefaults { defaults in
            defaults.set("camera-a", forKey: CameraSelection.preferenceKey)
            var selection = CameraSelection(defaults: defaults)
            selection.refresh(availableIDs: ["camera-a", "camera-b"])
            #expect(selection.selectedID.isEmpty)
            selection.select("camera-b", availableIDs: ["camera-a", "camera-b"])
            selection.refresh(availableIDs: ["camera-b", "camera-a"])
            #expect(selection.selectedID == "camera-b")
            #expect(selection.preferredID == "camera-b")
            selection.refresh(availableIDs: ["camera-a"])
            #expect(selection.selectedID.isEmpty)
        }
    }

    @Test func singleCameraSuggestionDoesNotReplaceAnOperatorChoice() {
        withDefaults { defaults in
            var selection = CameraSelection(defaults: defaults)
            selection.refresh(availableIDs: [])
            #expect(selection.selectedID.isEmpty)
            selection.refresh(availableIDs: ["camera-a"])
            #expect(selection.selectedID == "camera-a")
            #expect(defaults.string(forKey: CameraSelection.preferenceKey) == nil)
            selection.refresh(availableIDs: ["camera-a", "camera-b"])
            #expect(selection.selectedID.isEmpty)
            selection.select("camera-a", availableIDs: ["camera-a", "camera-b"])
            selection.select("missing-camera", availableIDs: ["camera-a", "camera-b"])
            selection.select("", availableIDs: ["camera-a", "camera-b"])
            #expect(selection.selectedID == "camera-a")
            #expect(defaults.string(forKey: CameraSelection.preferenceKey) == "camera-a")
        }
    }
}
