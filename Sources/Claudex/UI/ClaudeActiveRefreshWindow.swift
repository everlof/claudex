import AppKit
import SwiftUI

/// Standalone review surface for the experimental credential-backed Claude refresh.
/// Keychain access can begin only from the clearly labeled button in this window.
@MainActor
enum ClaudeActiveRefreshWindow {
    private static var window: NSWindow?

    static func show(store: UsageStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: ClaudeActiveRefreshContent(store: store))
        host.view.frame = NSRect(x: 0, y: 0, width: 700, height: 700)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.title = "Active Claude Refresh (Experimental)"
        window.contentMinSize = NSSize(width: 620, height: 620)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        writeCaptureIfRequested(view: host.view)
    }

    static func close() {
        window?.close()
    }

    private static func writeCaptureIfRequested(view: NSView) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CLAUDEX_ACTIVE_REFRESH_CAPTURE_PATH"], !path.isEmpty else {
            return
        }
        let delay = environment["CLAUDEX_ACTIVE_REFRESH_CAPTURE_DELAY_MS"].flatMap(Int.init) ?? 750
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            view.layoutSubtreeIfNeeded()
            defer {
                if environment["CLAUDEX_ACTIVE_REFRESH_CAPTURE_EXIT"] == "1" {
                    NSApplication.shared.terminate(nil)
                }
            }
            guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

private struct ClaudeActiveRefreshContent: View {
    @Bindable var store: UsageStore
    @State private var selectedAccountID: String?

    init(store: UsageStore) {
        self.store = store
        _selectedAccountID = State(initialValue: store.claudeAccounts.first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    introduction
                    disclosure
                    controls
                }
                .frame(maxWidth: 610, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(windowBackground)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Provider.claude.accentColor)
                .frame(width: 40, height: 40)
                .background(
                    Provider.claude.accentColor.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("Active Claude Refresh")
                        .font(.title3.weight(.semibold))
                    Pill(text: "Experimental", tint: Severity.warning.color, filled: true)
                }
                Text("Optional fresher usage when the passive Claude Code feed is idle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(
                store.claudeDirectRefreshEnabled ? "Enabled" : "Off",
                systemImage: store.claudeDirectRefreshEnabled ? "checkmark.circle.fill" : "circle"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(store.claudeDirectRefreshEnabled ? Severity.normal.color : .secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Review before authorizing")
                .font(.title2.weight(.semibold))
            Text("The passive local feed remains the default. This optional mode can fetch current quota windows directly when Claude Code has not produced a recent status-line event.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 15) {
            disclosureRow(
                symbol: "key",
                title: "Only after your click",
                detail: "Claude’s Keychain item is ambient, not labeled with a Claudex config slot. Select which local slot it belongs to; after your click, Claudex chooses the newest item from non-secret metadata and asks macOS for that exact item. Timers, startup, and menu opening never request its secret data."
            )
            disclosureRow(
                symbol: "arrow.up.right",
                title: "Sent directly to Anthropic",
                detail: "The current access token authenticates one GET request to Claude Code’s read-only OAuth usage endpoint. Claudex retains only normalized percentages, reset times, and the local source label."
            )
            disclosureRow(
                symbol: "memorychip",
                title: "Memory only",
                detail: "The access token can be reused for background usage refreshes until this app quits or the token expires. It is never written to disk, logs, diagnostics, history, or UI state."
            )
            disclosureRow(
                symbol: "eye.slash",
                title: "Ignored and excluded",
                detail: "The raw item may also contain a refresh token. Claudex must receive the Keychain item to parse it, but does not extract, retain, or use that field. Prompts, responses, transcripts, and Claude account content are never requested."
            )
        }
    }

    private func disclosureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Provider.claude.accentColor)
                .frame(width: 28, height: 28)
                .background(Provider.claude.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 13) {
            Toggle("Enable active Claude refresh", isOn: Binding(
                get: { store.claudeDirectRefreshEnabled },
                set: { store.setClaudeDirectRefreshEnabled($0) }
            ))
            .toggleStyle(.switch)

            if store.claudeDirectRefreshEnabled {
                if store.claudeAccounts.isEmpty {
                    Label("No Claude accounts are currently discovered.", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose the local slot for the current Claude Keychain login, then authorize once for this app run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker("Associate Keychain login with", selection: $selectedAccountID) {
                        ForEach(store.claudeAccounts) { account in
                            Text("Claude · \(account.handle)").tag(Optional(account.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 340, alignment: .leading)

                    Button("Authorize Keychain & Refresh") {
                        guard let selectedAccountID else { return }
                        store.authorizeClaudeKeychainRefresh(accountID: selectedAccountID)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Provider.claude.accentColor)
                    .disabled(selectedAccountID == nil)
                }
            }

            if let status = store.claudeDirectRefreshStatus {
                Label(status, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            Text("Disabling clears every in-memory Claude access token immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { ClaudeActiveRefreshWindow.close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var windowBackground: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            LinearGradient(
                colors: [Provider.claude.accentColor.opacity(0.045), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}
