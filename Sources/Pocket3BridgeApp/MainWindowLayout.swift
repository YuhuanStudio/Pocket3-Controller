import AppKit
import SwiftUI
import YunDesign

/// The same column budget as YunAudio. The AppKit frame owns the minimum:
/// SwiftUI's content minimum adds the hidden 32-point title bar a second time.
enum MainWindowLayout {
    static let minimumSize = NSSize(width: 1180, height: 720)
    static let sourceWidth: CGFloat = 268
    static let inspectorWidth: CGFloat = 360
}
struct MainWindowMinimumSize: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Attachment() }
    func updateNSView(_ view: NSView, context: Context) { apply(view.window) }
    private func apply(_ window: NSWindow?) {
        window?.minSize = MainWindowLayout.minimumSize
    }
    private final class Attachment: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.minSize = MainWindowLayout.minimumSize
            DispatchQueue.main.async { [weak self] in self?.window?.minSize = MainWindowLayout.minimumSize }
        }
    }
}
