import AppKit
import SwiftUI

/// Presents the safe support report before any sharing action. The app never uploads or
/// copies diagnostics automatically; the pasteboard changes only when the user presses Copy.
@MainActor
enum DiagnosticsWindow {
    private static var window: NSWindow?

    static func show(report: String) {
        let view = DiagnosticsPreview(
            report: report,
            onClose: { close() }
        )
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = "Claudex Diagnostics"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 600, height: 470))
        window.minSize = NSSize(width: 460, height: 320)
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func close() {
        window?.close()
        window = nil
    }
}

private struct DiagnosticsPreview: View {
    let report: String
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview diagnostics")
                    .font(.title2.weight(.semibold))
                Text("Review the complete report below. Nothing is uploaded, and nothing is copied until you choose Copy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(report)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )

            HStack {
                Text("Excluded: credentials, identity, paths, sessions, Activity Map data, and content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(copied ? "Copied" : "Copy report") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(report, forType: .string)
                    copied = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 320)
    }
}
