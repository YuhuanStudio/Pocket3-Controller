import Foundation

/// A saved USB choice is a preference, not permission to substitute a camera.
struct CameraSelection {
    static let preferenceKey = "Pocket3PreferredDeviceID"
    private let defaults: UserDefaults
    private var explicitID: String?
    private(set) var preferredID: String?
    private(set) var selectedID = ""

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferredID = defaults.string(forKey: Self.preferenceKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    mutating func refresh(availableIDs: [String]) {
        let available = Set(availableIDs)
        if let explicitID, available.contains(explicitID) {
            selectedID = explicitID
            return
        }
        explicitID = nil
        // With multiple identical cameras, require a choice this launch even
        // when an old USB location happens to match the saved preference.
        guard available.count == 1, let candidate = available.first,
              preferredID == nil || preferredID == candidate else {
            selectedID = ""
            return
        }
        selectedID = candidate
    }

    mutating func select(_ id: String, availableIDs: [String]) {
        guard !id.isEmpty, availableIDs.contains(id) else { return }
        explicitID = id
        selectedID = id
        preferredID = id
        defaults.set(id, forKey: Self.preferenceKey)
    }
}
