import AppKit
import SwiftUI
import Pocket3Core
import YunDesign

extension AppModel {
    /// The real AppKit window frame, including traffic lights and clipping.
    /// Camera IOSurfaces are represented by a fresh still from this session.
    func captureWindow(_ request: ServiceRequest) async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else { throw BridgeFailure("development_only", "Interface capture requires a development launch") }
        guard !capturingUI else { throw BridgeFailure("capture_busy", "Another interface capture is running") }
        guard let path = request.arguments["output"].string, path.hasPrefix("/"), path.hasSuffix(".png") else { throw BridgeFailure("capture_path", "UI capture requires an absolute PNG path") }
        capturingUI = true
        let oldPage = selectedPage, oldAppearance = NSApp.appearance, oldLanguage = YunStrings.language, oldMessage = message
        let oldThemeLanguage = YunTheme.shared.language
        let captureLanguage = YunLanguage(rawValue: request.arguments["language"].string ?? "zh-Hant") ?? .traditionalChinese
        // Update the lookup first: the theme setter then sees the same value
        // and does not persist it. Its observation invalidates every loc()
        // consumer, including footer pills that otherwise retained old text.
        YunStrings.useForThisLaunchOnly(captureLanguage)
        YunTheme.shared.language = captureLanguage
        defer {
            YunStrings.useForThisLaunchOnly(oldThemeLanguage)
            YunTheme.shared.language = oldThemeLanguage
            YunStrings.useForThisLaunchOnly(oldLanguage)
            capturingUI = false
        }
        let surface = request.arguments["surface"].string ?? "main"
        let settingsWasVisible = SettingsWindow.window?.isVisible == true
        let oldSection = SettingsWindow.selection
        let window: NSWindow
        var transient: NSWindow?
        if surface == "settings" {
            SettingsWindow.open(model: self, initialSection: PreferencesSection(rawValue: request.arguments["page"].string ?? "general") ?? .general)
            window = SettingsWindow.window!
        } else if surface == "updates" {
            window = UpdatePermissionWindow.make { _, _ in }
            transient = window; window.orderFront(nil)
        } else if surface == "panel" {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 355), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: PanelView(model: self, openMain: {}, openSettings: {}))
            transient = window; window.orderFront(nil)
        } else if surface == "settings-readback-fixture" {
            let host = NSHostingController(rootView: try CameraSettingsReadbackFixture.view(state: request.arguments["page"].string ?? "available"))
            window = NSWindow(contentViewController: host)
            window.styleMask = [.borderless]; window.isReleasedWhenClosed = false
            window.setContentSize(host.view.fittingSize)
            transient = window; window.orderFront(nil)
        } else if surface == "roll-fixture" {
            let host = NSHostingController(rootView: try await RollControlFixture.view(state: request.arguments["page"].string ?? "negative"))
            window = NSWindow(contentViewController: host)
            window.styleMask = [.borderless]; window.isReleasedWhenClosed = false
            window.setContentSize(host.view.fittingSize)
            transient = window; window.orderFront(nil)
        } else if surface == "telemetry-fixture" {
            let host = NSHostingController(rootView: try BluetoothTelemetryFixture.view(state: request.arguments["page"].string ?? "full"))
            window = NSWindow(contentViewController: host)
            window.styleMask = [.borderless]; window.isReleasedWhenClosed = false
            window.setContentSize(host.view.fittingSize)
            transient = window; window.orderFront(nil)
        } else if surface == "wireless" {
            let host = NSHostingController(rootView: WirelessGimbalConnectionView(model: wireless))
            window = NSWindow(contentViewController: host)
            window.styleMask = [.borderless]; window.isReleasedWhenClosed = false
            window.setContentSize(host.view.fittingSize)
            transient = window; window.orderFront(nil)
        } else {
            guard let main = NSApp.windows.first(where: { $0.title == Pocket3Product.displayName }) else { capturingUI = false; throw BridgeFailure("window_missing", "Open the main window before capturing") }
            window = main; selectedPage = request.arguments["page"].string ?? "camera"
        }
        if let fixtureMessage = request.arguments["message"].string { message = fixtureMessage }
        let oldFrame = window.frame
        defer {
            capturePreview = nil; selectedPage = oldPage; message = oldMessage; NSApp.appearance = oldAppearance
            window.setFrame(oldFrame, display: true)
            if surface == "settings" { SettingsWindow.selection = oldSection; if !settingsWasVisible { window.close() } }
            transient?.close(); capturingUI = false
        }
        NSApp.appearance = NSAppearance(named: request.arguments["appearance"].string == "light" ? .aqua : .darkAqua)
        if request.arguments["minimum"].bool != false && ["settings", "main"].contains(surface) {
            let size = surface == "settings" ? NSSize(width: 620, height: 440) : NSSize(width: 1180, height: 720)
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
        }
        if let frame = try? service.capture.store.latest(),
           let data = try? await Task.detached(operation: { try frame.jpeg(maxDimension: 1280) }).value,
           frame.info.sessionID == service.capture.store.stats().sessionID { capturePreview = NSImage(data: data) }
        // Reattach settings so a temporary language selection invalidates the
        // same hosting tree even when this pane contains no observed model data.
        if surface == "settings" { SettingsWindow.refreshContent(model: self) }
        try await Task.sleep(for: .milliseconds(350))
        guard let frame = window.contentView?.superview else { throw BridgeFailure("render_failed", "No theme frame") }
        frame.layoutSubtreeIfNeeded(); frame.displayIfNeeded()
        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { throw BridgeFailure("render_failed", "Unable to allocate the window bitmap") }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw BridgeFailure("render_failed", "Unable to encode the window") }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return ServiceReply(id: request.id, result: .object(["saved": .string(path), "width": .number(Double(bitmap.pixelsWide)), "height": .number(Double(bitmap.pixelsHigh)), "chromeIntegrated": .bool(WindowChrome.isIntegrated(window)), "surface": .string(surface), "simulation": .bool(["telemetry-fixture", "roll-fixture", "settings-readback-fixture"].contains(surface)), "layout": try .encode(layoutBounds), "method": .string("AppKit window rendering; camera layer represented by a fresh still")]))
    }

    func checkInterface(_ request: ServiceRequest) async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else { throw BridgeFailure("development_only", "Interface checks require a development launch") }
        var checks: [String: JSONValue] = [:]
        await testBridgeConnection()
        checks["localBridgeConnection"] = .bool(bridgeConnectionCheckedAt != nil && bridgeConnectionError == nil)
        let wasVisible = SettingsWindow.window?.isVisible == true, oldSelection = SettingsWindow.selection
        SettingsWindow.open(model: self, initialSection: .appearance)
        let window = SettingsWindow.window, host = SettingsWindow.hostIdentity
        checks["settingsVisible"] = .bool(window?.isVisible == true)
        window?.close()
        checks["settingsDetached"] = .bool(window?.contentViewController == nil)
        SettingsWindow.open(model: self)
        checks["settingsSingleWindow"] = .bool(SettingsWindow.window === window)
        checks["settingsRetainsState"] = .bool(SettingsWindow.hostIdentity == host && SettingsWindow.selection == .appearance)
        checks["settingsReattached"] = .bool(window?.contentViewController != nil)
        checks["settingsChrome"] = .bool(window.map { WindowChrome.isIntegrated($0) } == true)
        SettingsWindow.selection = oldSelection
        if !wasVisible { window?.close() }
        checks["statusPopoverReleased"] = .bool(await statusItem?.checkPopoverLifetime() == true)
        let updater = AppUpdateController.shared
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil {
            updater.checkForUpdates()
            checks["noInventedUpdateStatus"] = .bool(!updater.isAvailable && !updater.canCheckForUpdates && !updater.automaticallyChecksForUpdates)
        }
        let originalPage = selectedPage
        selectedPage = "camera"
        try await Task.sleep(for: .milliseconds(200))
        if let source = layoutBounds["source"], let preview = layoutBounds["previewColumn"],
           let inspector = layoutBounds["inspector"], let footer = layoutBounds["footer"],
           let question = layoutBounds["question"], let actions = layoutBounds["answerActions"] {
            checks["columnWidths"] = .bool(abs(source.width - 268) < 1 && abs(inspector.width - 360) < 1)
            checks["columnGaps"] = .bool(abs(preview.minX - source.maxX - 16) < 1 && abs(inspector.minX - preview.maxX - 16) < 1)
            checks["columnAlignment"] = .bool(abs(source.minY - preview.minY) < 1 && abs(preview.minY - inspector.minY) < 1)
            checks["controlsInsideInspector"] = .bool(question.minX >= inspector.minX && question.maxX <= inspector.maxX && actions.minX >= inspector.minX && actions.maxX <= inspector.maxX)
            checks["footerDoesNotOverlap"] = .bool(source.maxY <= footer.minY + 1 && inspector.maxY <= footer.minY + 1)
        } else { checks["layoutMeasurementsAvailable"] = .bool(false) }
        selectedPage = originalPage
        if let main = NSApp.windows.first(where: { $0.title == Pocket3Product.displayName }) {
            main.performClose(nil); openMainWindow?()
            try await Task.sleep(for: .milliseconds(250))
            checks["mainReopens"] = .bool(NSApp.windows.filter { $0.title == Pocket3Product.displayName && $0.isVisible }.count == 1)
            checks["pageRetained"] = .bool(selectedPage == originalPage)
        }
        checks["passed"] = .bool(checks.values.allSatisfy { $0.bool == true })
        checks["popoverDetails"] = .object(statusItem?.presentationCheck ?? [:])
        return ServiceReply(id: request.id, result: .object(checks))
    }
}
