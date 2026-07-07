import AppKit
import SwiftUI

/// Manages the standalone "Usage history" window opened from the panel's breakout button.
/// A single reused window, so repeated clicks focus it rather than spawning duplicates.
@MainActor
enum UsageHistoryWindow {
    private static var window: NSWindow?

    static func show(store: HistoryStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: UsageHistoryWindowContent(store: store))
        host.view.frame = NSRect(x: 0, y: 0, width: 560, height: 460)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.contentViewController = host
        win.title = "Usage History"
        win.contentMinSize = NSSize(width: 440, height: 360)
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        // Bring the (accessory) app forward so the window is interactive.
        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The full chart plus a surface background matching the app's aesthetic.
private struct UsageHistoryWindowContent: View {
    @Bindable var store: HistoryStore

    var body: some View {
        UsageChartView(store: store, mode: .full)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    LinearGradient(
                        colors: [
                            Provider.claude.accentColor.opacity(0.05),
                            .clear,
                            Provider.codex.accentColor.opacity(0.05),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
                .ignoresSafeArea()
            )
    }
}
