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
    }

    // MARK: Status button rendering

    /// Re-render the menu-bar button from the current store state whenever the store
    /// changes. Uses `withObservationTracking` to re-subscribe after each change.
    private func observeStore() {
        withObservationTracking {
            // Touch the derived summary so every input to it is tracked (severity, peak,
            // loaded count, and the frontmost account).
            _ = store.menuBar
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

        // Glyph: provider-tinted when a frontmost account is known, otherwise a
        // system-tinted template gauge.
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let base = NSImage(systemSymbolName: glyphName(summary), accessibilityDescription: "usage")?
            .withSymbolConfiguration(config)
        if let provider = summary.provider, let base {
            let tinted = base.tinted(with: NSColor(provider.accentColor))
            tinted.isTemplate = false
            button.image = tinted
        } else {
            base?.isTemplate = true
            button.image = base
        }

        // Title: "5h / 7d" for a frontmost account, or a single peak % on fallback.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let title: String
        if summary.isFrontmost {
            let p = summary.primaryPercent.map { "\($0)%" } ?? "–"
            if let s = summary.secondaryPercent {
                title = " \(p) / \(s)%"
            } else {
                title = " \(p)"
            }
        } else if let p = summary.primaryPercent {
            title = " \(p)%"
        } else {
            title = ""
        }
        button.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])

        // Tooltip explains what the number refers to.
        if summary.isFrontmost, let entry = store.frontmostEntry {
            button.toolTip = "Claudex — \(entry.ref.provider.displayName) · \(entry.ref.handle) (frontmost) · 5h / weekly"
        } else if store.hasAnyError {
            button.toolTip = "Claudex — some accounts need attention"
        } else {
            button.toolTip = "Claudex — peak usage across all accounts"
        }
    }

    private func glyphName(_ summary: MenuBarSummary) -> String {
        if store.loadedCount == 0 { return "gauge.with.dots.needle.bottom.0percent" }
        switch summary.severity {
        case .normal: return "gauge.with.dots.needle.33percent"
        case .warning: return "gauge.with.dots.needle.67percent"
        case .critical: return "gauge.with.dots.needle.100percent"
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
