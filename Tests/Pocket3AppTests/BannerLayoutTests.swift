import AppKit
import SwiftUI
import Testing
import YunDesign
@testable import Pocket3BridgeApp

@MainActor @Test func bannerKeepsTheOriginalSingleLineHeight() throws {
    // Neither a short cancellation nor a paragraph may increase the original
    // single-line height and push the camera controls away.
    for message in ["動作已取消", String(repeating: "A long device error that needs its full-text popover. ", count: 8)] {
        let renderer = ImageRenderer(content: AppMessageBanner(message: message))
        renderer.proposedSize = ProposedViewSize(width: 600, height: nil)
        let size = try #require(renderer.nsImage).size
        #expect(size.height >= 27 && size.height <= 32)
        #expect(size.width <= 600)
    }
}
