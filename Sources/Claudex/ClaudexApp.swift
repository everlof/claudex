import SwiftUI
import AppKit

@main
struct ClaudexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // All UI is driven by the AppDelegate's NSStatusItem + popover; no SwiftUI
        // scene is needed. Settings{} keeps SwiftUI happy with an (empty) scene.
        Settings { EmptyView() }
    }
}

/// Owns the menu-bar status item and the popover that hosts the SwiftUI panel.
///
/// We manage `NSStatusItem` directly rather than using SwiftUI's `MenuBarExtra` because
/// only the AppKit button reliably shows *both* a glyph and live text ("91%") in the
/// menu bar. The status item's appearance is derived purely from the typed `UsageStore`
/// state, and refreshed via an observation tracking loop.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: MenuContent(store: store)
        )

        store.start()
        store.startFrontmostTracking()      // track which account is frontmost
        observeStore()      // keep the status button in sync with store changes
        updateStatusButton() // initial render

        // CLAUDEX_CAPTURE=1 shows the panel in a standalone floating window (instead of
        // the click-to-open, dismiss-on-outside-click popover) so screenshots can be
        // captured deterministically. Pair with CLAUDEX_DEMO=1 for anonymised names.
        if ProcessInfo.processInfo.environment["CLAUDEX_CAPTURE"] == "1" {
            showCaptureWindow()
        }
    }

    /// A borderless window hosting the panel, for reproducible doc/social screenshots.
    private var captureWindow: NSWindow?
    private func showCaptureWindow() {
        // CLAUDEX_CAPTURE_HEIGHT overrides the panel height so every account fits in one
        // shot (the live popover scrolls). The panel's own maxHeight is lifted to match.
        let heightOverride = ProcessInfo.processInfo.environment["CLAUDEX_CAPTURE_HEIGHT"]
            .flatMap { Double($0) }
        let height: CGFloat = heightOverride.map { CGFloat($0) } ?? 560
        let host = NSHostingController(
            rootView: MenuContent(store: store, maxContentHeight: height)
        )
        host.view.frame = NSRect(x: 0, y: 0, width: 340, height: height)
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        captureWindow = window
    }

    // MARK: Status button rendering

    /// Re-render the menu-bar button from the current store state whenever the store
    /// changes. Uses `withObservationTracking` to re-subscribe after each change.
    private func observeStore() {
        withObservationTracking {
            // Touch the derived summary and the style so every input to the rendering is
            // tracked (severity, peak, loaded count, featured account, and settings).
            _ = store.menuBar
            _ = store.menuBarStyle
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateStatusButton()
                self?.observeStore() // re-arm for the next change
            }
        }
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let summary = store.menuBar
        let output = MenuBarRenderer.render(summary, style: store.menuBarStyle)
        button.image = output.image
        button.attributedTitle = output.title

        // Tooltip explains what the number refers to.
        if summary.isFeatured, let entry = store.featuredEntry {
            let role = store.menuBarSubject == .frontmost ? "frontmost" : "highest usage"
            button.toolTip = "Claudex — \(entry.ref.provider.displayName) · \(entry.ref.handle) (\(role)) · 5h / weekly"
        } else if store.hasAnyError {
            button.toolTip = "Claudex — some accounts need attention"
        } else {
            button.toolTip = "Claudex — peak usage across all accounts"
        }
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        // Refresh on open only if the data is stale — avoids hammering the APIs when
        // the panel is opened repeatedly in quick succession.
        store.refreshIfStale()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        // Dismiss when clicking outside.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
