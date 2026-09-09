import AppKit
import CoreGraphics
import Observation
import SwiftUI
import YunDesign
import Pocket3Core

/// YunAudio's transient-popover ownership and left/right-click interaction.
@MainActor final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var host: NSViewController?
    private var mark = ""
    private var fullyShown = false
    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient; popover.delegate = self
        if let button = item.button {
            button.imagePosition = .imageOnly; button.target = self; button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        observeStatus(); refreshImage()
    }
    private func observeStatus() {
        withObservationTracking { _ = model.status?.phase; _ = model.aiWorking; _ = YunTheme.shared.language } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeStatus(); self?.refreshImage() }
        }
    }
    private func refreshImage() {
        let next = "\(model.status?.phase ?? "idle"):\(model.aiWorking):\(YunTheme.shared.language.rawValue)"
        guard mark != next else { return }; mark = next
        let running = model.ready, paused = model.status?.phase == "paused"
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            YunAppIcon.draw(inkFitting: YunAppIcon.inkBox(height: 17, centredAt: NSPoint(x: 9, y: 11)), fraction: running ? 1 : 0.55)
            NSColor.black.setFill(); NSColor.black.setStroke()
            if running { NSBezierPath(ovalIn: NSRect(x: 17, y: 2, width: 3, height: 3)).fill() }
            if paused { let line = NSBezierPath(); line.move(to: NSPoint(x: 4, y: 3)); line.line(to: NSPoint(x: 18, y: 19)); line.lineWidth = 1.5; line.stroke() }
            return true
        }
        image.isTemplate = true; item.button?.image = image; item.button?.toolTip = "\(Pocket3Product.displayName) — \(loc(model.phaseTitle))"
    }
    @objc private func handleClick() {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true { showMenu(); return }
        if popover.isShown { closePopover(); return }
        showPanel(relativeTo: button)
    }
    private func showPanel(relativeTo button: NSStatusBarButton) {
        fullyShown = false
        let controller = NSHostingController(rootView:
            ScrollView {
                PanelView(model: model, openMain: { [weak self] in self?.openMain() }, openSettings: { [weak self] in self?.openSettings() })
            }
            .scrollIndicators(.never)
            .frame(width: 340)
            .frame(maxHeight: 680)
        )
        controller.sizingOptions = [.preferredContentSize]
        host = controller; popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func showMenu() {
        closePopover()
        let menu = NSMenu()
        for (title, action, key) in [("Stop operation", #selector(stopOperation), ""), ("Privacy pause", #selector(pause), ""), ("Open Pocket 3 Controller", #selector(openMain), ""), ("Settings", #selector(openSettings), ","), ("Check for Updates…", #selector(checkUpdates), ""), ("Quit", #selector(quit), "q")] {
            if title == "Open Pocket 3 Controller" || title == "Quit" { menu.addItem(.separator()) }
            menu.addItem(withTitle: loc(title), action: action, keyEquivalent: key).target = self
        }
        item.menu = menu; item.button?.performClick(nil); item.menu = nil
    }
    private func closePopover() {
        popover.performClose(nil)
    }
    func popoverDidShow(_ notification: Notification) {
        fullyShown = true
    }
    func popoverDidClose(_ notification: Notification) {
        fullyShown = false
        popover.contentViewController = nil; host = nil
    }
    @objc private func openMain() { closePopover(); model.openMainWindow?() }
    @objc private func openSettings() { closePopover(); SettingsWindow.open(model: model) }
    @objc private func checkUpdates() { SettingsWindow.open(model: model, initialSection: .about); AppUpdateController.shared.checkForUpdates() }
    @objc private func stopOperation() { Task { await model.stop() } }
    @objc private func pause() { Task { await model.pause() } }
    @objc private func quit() { NSApp.terminate(nil) }
    func close() { closePopover(); NSStatusBar.system.removeStatusItem(item) }
    private(set) var presentationCheck: [String: JSONValue] = [:]
    func checkPopoverLifetime() async -> Bool {
        let screenLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        let screenUnavailable = screenLocked || CGDisplayIsAsleep(CGMainDisplayID()) != 0
        let previousAnimations = popover.animates
        if screenUnavailable { popover.animates = false }
        defer { popover.animates = previousAnimations }
        presentationCheck = ["itemVisible": .bool(item.isVisible), "initiallyShown": .bool(popover.isShown), "screenUnavailable": .bool(screenUnavailable), "animationVerified": .bool(!screenUnavailable)]
        guard let button = item.button else { presentationCheck["failure"] = .string("missing button"); return false }
        presentationCheck["buttonHasWindow"] = .bool(button.window != nil)
        if popover.isShown { closePopover() }
        for _ in 0..<20 {
            if !popover.isShown && host == nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        for iteration in 0..<5 {
            showPanel(relativeTo: button)
            for _ in 0..<30 {
                if fullyShown { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard popover.isShown, fullyShown, host != nil else {
                presentationCheck["failure"] = .string("show failed at iteration \(iteration)")
                presentationCheck["contentHeight"] = .number(popover.contentSize.height)
                return false
            }
            closePopover()
            // AppKit releases the presentation after its close animation.
            for _ in 0..<20 {
                if host == nil && popover.contentViewController == nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if host != nil || popover.contentViewController != nil {
                presentationCheck["failure"] = .string("host retained at iteration \(iteration)")
                presentationCheck["stillShown"] = .bool(popover.isShown)
                return false
            }
        }
        return true
    }
    var retainedPanelCount: Int { host == nil ? 0 : 1 }
}

struct PanelView: View {
    @Bindable var model: AppModel
    var openMain: () -> Void
    var openSettings: () -> Void
    var body: some View {
        let _ = YunTheme.shared.language
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            HStack(spacing: Yun.Space.sm) {
                Image(nsImage: YunAppIcon.trimmed).resizable().scaledToFit().frame(height: 20)
                Text(Pocket3Product.displayName).font(Yun.Text.title)
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }.buttonStyle(YunButtonStyle(.ghost, small: true))
            }
            CompactCameraStatus(model: model)
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    Text(model.status?.selected?.name ?? loc("No camera")).font(Yun.Text.body)
                    Text(loc(model.phaseTitle)).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textSecondary)
                    YunSelect(selection: Binding(get: { model.access }, set: { value in Task { await model.setAccess(value) } }), options: AccessMode.allCases.map { .init(value: $0, title: loc($0.title)) })
                        .disabled(!model.isCameraSource)
                }
            }
            HStack(spacing: Yun.Space.sm) {
                Button(loc("Capture image")) { Task { await model.snapshot() } }.buttonStyle(YunButtonStyle(.secondary, small: true)).disabled(!model.cameraActionReady)
                Button(loc("Privacy pause")) { Task { await model.pause() } }.buttonStyle(YunButtonStyle(.primary, small: true))
            }
            YunDivider()
            HStack { Button(loc("Open Pocket 3 Controller"), action: openMain).buttonStyle(YunButtonStyle(.ghost, small: true)); Spacer(); Button(loc("Quit")) { NSApp.terminate(nil) }.buttonStyle(YunButtonStyle(.ghost, small: true)) }
        }.padding(Yun.Space.lg).frame(width: 340).yunPanelShell().foregroundStyle(Yun.Palette.textPrimary)
    }
}
