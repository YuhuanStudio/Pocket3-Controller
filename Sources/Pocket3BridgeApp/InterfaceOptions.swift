import AppKit
import ServiceManagement
import YunDesign

@MainActor
enum InterfaceOptions {
    private static let dockKey = "studio.yuhuan.Pocket3Bridge.showsDockIcon"

    /// `LSUIElement` makes this an accessory by default: menu bar only, no Dock
    /// icon and no application menu. That is right for a router that is mostly
    /// left alone, and wrong for somebody who works in the window and wants to
    /// reach it with ⌘-tab like anything else.
    static var showsDockIcon: Bool {
        get { UserDefaults.standard.bool(forKey: dockKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: dockKey)
            apply()
        }
    }

    /// Puts the policy on the running application.
    ///
    /// Returns whether it took: `setActivationPolicy` reports failure, and a
    /// toggle that silently did nothing is the kind of defect this project
    /// keeps finding.
    @discardableResult
    static func apply() -> Bool {
        NSApp?.setActivationPolicy(showsDockIcon ? .regular : .accessory) ?? false
    }
}

/// Login item registration.
///
/// `SMAppService.mainApp` replaces the old login-item and helper-bundle dances;
/// the system owns the state, so it is read back rather than mirrored locally.
@MainActor
enum LoginItem {
    enum State: Equatable, Sendable {
        case enabled
        case requiresApproval
        case notRegistered
        case unavailable
    }

    static var state: State {
        readState()
    }

    /// Reads ServiceManagement without making MainActor wait for its daemon.
    nonisolated static func readState() -> State {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    static var isEnabled: Bool {
        state == .enabled
    }

    /// Returns nil on success, or a message explaining why it did not take.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return AppErrorPresentation.message(error, fallback: .loginItem)
        }
    }
}
