import Foundation
import ServiceManagement
import os

/// Thin wrapper over `SMAppService.mainApp` — registers/unregisters the app as a login item
/// so it can start automatically at login. macOS 13+.
///
/// Registration is a system operation that can fail (e.g. the user disabled the item in
/// System Settings > General > Login Items, or the app isn't in a launchable location); we
/// surface the resulting `status` so the UI can reflect the *actual* state rather than what
/// we last asked for.
enum LoginItem {
    private static let log = Logger(subsystem: "dev.everlof.claudex", category: "LoginItem")

    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the user has actively disabled the item in System Settings — we can't flip
    /// it back programmatically, so the UI should point them there instead.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Register or unregister the login item. Returns whether the end state matches `enabled`.
    /// A thrown error is logged and treated as failure (the caller re-reads `isEnabled`).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                // `register` is idempotent; calling it while already enabled is harmless.
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
            return isEnabled == enabled
        } catch {
            log.error("Failed to \(enabled ? "register" : "unregister", privacy: .public) login item: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
