import AppKit
import SwiftUI
import Pocket3Core
import YunDesign

/// Contents for the existing YunCard; no new card/footer aesthetics or absolute
/// one-degree repetitions. The handle displays user input, not measured pose.
@MainActor struct ContinuousGimbalControls: View {
    @Bindable var controller: ContinuousGimbalGestureController
    @State private var surfaceID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            VStack(spacing: Yun.Space.sm) {
                direction(x: 0, y: -1, symbol: "arrow.up", title: loc("Hold to move up"))
                HStack(spacing: Yun.Space.sm) {
                    direction(x: -1, y: 0, symbol: "arrow.left", title: loc("Hold to move left"))
                    joystick
                    direction(x: 1, y: 0, symbol: "arrow.right", title: loc("Hold to move right"))
                }
                direction(x: 0, y: 1, symbol: "arrow.down", title: loc("Hold to move down"))
            }
            .frame(maxWidth: .infinity)
            .opacity(controller.canInteract ? 1 : 0.5)

            Button {
                Task { await controller.stop(reason: .cancelled) }
            } label: {
                Label(loc("Stop operation"), systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(YunButtonStyle(.secondary, small: true))
            .disabled(!controller.canStop)

            if let message = controller.availability.message {
                caption(message)
            } else if controller.isStopping {
                caption(loc("Stopping control…"))
            } else if controller.isStarting {
                caption(loc("Preparing control…"))
            } else {
                caption(loc("Near the center is slow; farther out is fast. Release to stop."))
            }
            if let error = controller.lastError {
                Text(error).font(Yun.Text.caption).foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { controller.endSurface(surfaceID) }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func direction(x: Double, y: Double, symbol: String, title: String) -> some View {
        let input = ContinuousGimbalInput(x: x, y: y)
        let active = controller.gestureID != nil && controller.input == input
        return Button {} label: {
            Image(systemName: symbol).frame(width: 14, height: 18)
        }
        .buttonStyle(YunButtonStyle(active ? .primary : .secondary, small: true))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .overlay {
            ContinuousGimbalInputSurface(controller: controller, surfaceID: surfaceID,
                fixedInput: input, label: title, enabled: controller.canInteract)
        }
        .help(title)
    }

    private var joystick: some View {
        ZStack {
            Circle().fill(Yun.Palette.elevated)
            Circle().strokeBorder(Yun.Palette.border, lineWidth: 1)
            Rectangle().fill(Yun.Palette.borderHairline).frame(width: 72, height: 1)
            Rectangle().fill(Yun.Palette.borderHairline).frame(width: 1, height: 72)
            Circle().fill(Yun.Palette.accentSubtle)
                .overlay { Circle().strokeBorder(Yun.Palette.textTertiary, lineWidth: 1) }
                .frame(width: 22, height: 22)
                .offset(x: controller.input.x * 41, y: controller.input.y * 41)
        }
        .frame(width: 104, height: 104)
        .transaction { $0.animation = nil }
        .overlay {
            ContinuousGimbalInputSurface(controller: controller, surfaceID: surfaceID,
                fixedInput: nil, label: loc("Drag to move the camera"), enabled: controller.canInteract)
        }
        .help(loc("Drag to move. Arrow keys also work while focused."))
    }
}

/// AppKit owns each mouse-down/drag/up sequence, so leaving the SwiftUI button
/// bounds does not create new presses or lose its matching release token.
private struct ContinuousGimbalInputSurface: NSViewRepresentable {
    let controller: ContinuousGimbalGestureController
    let surfaceID: UUID
    let fixedInput: ContinuousGimbalInput?
    let label: String
    let enabled: Bool
    func makeNSView(context: Context) -> TrackingView { TrackingView(frame: .zero) }
    func updateNSView(_ view: TrackingView, context: Context) {
        view.controller = controller; view.surfaceID = surfaceID
        view.fixedInput = fixedInput; view.enabled = enabled
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(fixedInput == nil ? .group : .button)
        view.setAccessibilityLabel(label)
        view.setAccessibilityEnabled(enabled)
        view.setAccessibilityHelp(fixedInput == nil
            ? loc("Focus this control and hold an arrow key to move.")
            : loc("Press and hold to move. Accessibility activation toggles movement; activate again to stop."))
    }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { view.finish(reason: .focusLost) }

    @MainActor final class TrackingView: NSView {
        weak var controller: ContinuousGimbalGestureController?
        var surfaceID = UUID()
        var fixedInput: ContinuousGimbalInput?
        var enabled = false {
            didSet { if !enabled { finish(reason: .cancelled) }; window?.invalidateCursorRects(for: self) }
        }
        private var trackingID: UUID?
        private var keys: Set<UInt16> = []
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { enabled }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: enabled ? (fixedInput == nil ? .crosshair : .pointingHand) : .operationNotAllowed)
        }
        override func mouseDown(with event: NSEvent) {
            guard enabled else { return }
            window?.makeFirstResponder(self)
            finish(reason: .cancelled)
            begin(input: input(for: event))
        }
        override func mouseDragged(with event: NSEvent) {
            guard let trackingID else { return }
            controller?.updateGesture(id: trackingID, input: input(for: event))
        }
        override func mouseUp(with event: NSEvent) { finish(reason: .released) }
        override func resignFirstResponder() -> Bool { finish(reason: .focusLost); return true }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { finish(reason: .focusLost) }
            super.viewWillMove(toWindow: newWindow)
        }
        override func keyDown(with event: NSEvent) {
            guard enabled else { return }
            if event.keyCode == 53 { finish(reason: .cancelled); return }
            let supported = fixedInput == nil ? (123...126).contains(event.keyCode) : [UInt16(36),49].contains(event.keyCode)
            guard supported else { super.keyDown(with: event); return }
            if let trackingID, controller?.gestureID != trackingID { self.trackingID = nil; keys.removeAll() }
            // Stop/focus loss latches the held key off until a fresh key-down.
            // An OS autorepeat from the cancelled press must not restart motion.
            if event.isARepeat && trackingID == nil { return }
            keys.insert(event.keyCode)
            let input = keyboardInput
            if let trackingID { controller?.updateGesture(id: trackingID, input: input) }
            else { begin(input: input) }
        }
        override func keyUp(with event: NSEvent) {
            guard keys.remove(event.keyCode) != nil else { super.keyUp(with: event); return }
            if keys.isEmpty { finish(reason: .released) }
            else if let trackingID { controller?.updateGesture(id: trackingID, input: keyboardInput) }
        }
        override func accessibilityPerformPress() -> Bool {
            guard enabled, let fixedInput else { return false }
            if let trackingID, controller?.gestureID == trackingID { finish(reason: .released) }
            else { window?.makeFirstResponder(self); begin(input: fixedInput) }
            return true
        }
        private func begin(input: ContinuousGimbalInput) {
            let id = UUID()
            if controller?.beginGesture(id: id, input: input, window: window, surfaceID: surfaceID) == true { trackingID = id }
        }
        func finish(reason: ContinuousGimbalStopReason) {
            if let trackingID { controller?.endGesture(id: trackingID, reason: reason) }
            trackingID = nil; keys.removeAll()
        }
        private var keyboardInput: ContinuousGimbalInput {
            fixedInput ?? .init(x: (keys.contains(124) ? 1 : 0) - (keys.contains(123) ? 1 : 0),
                                y: (keys.contains(125) ? 1 : 0) - (keys.contains(126) ? 1 : 0))
        }
        private func input(for event: NSEvent) -> ContinuousGimbalInput {
            if let fixedInput { return fixedInput }
            let point = convert(event.locationInWindow, from: nil)
            let radius = max(1, (min(bounds.width, bounds.height) - 22) / 2)
            return .init(x: (point.x - bounds.midX) / radius, y: (point.y - bounds.midY) / radius)
        }
    }
}
