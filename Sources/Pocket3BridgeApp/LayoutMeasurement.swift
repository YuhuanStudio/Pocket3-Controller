import SwiftUI

/// Records the actual live layout used by the interface check, including the
/// ScrollView branch that offscreen rendering cannot measure.
struct LayoutBoundsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
extension View {
    func measuredForLayout(_ name: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: LayoutBoundsKey.self, value: [name: geometry.frame(in: .named("Pocket3MainLayout"))])
            }
        }
    }
}
