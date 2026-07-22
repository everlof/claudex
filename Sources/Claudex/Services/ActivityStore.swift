import AppKit
import Foundation
import Observation

struct ActivityEventSnapshot: Sendable {
    let signature: String
    let events: [ActivityEvent]?
}

/// Loads the sanitized Activity Map event spool and reconstructs provider conversations.
/// Collection itself happens in the tiny signed helper, so opening this window is read-only.
@MainActor
@Observable
final class ActivityStore {
    private(set) var conversations: [ActivityConversation] = []
    private(set) var collectionEnabled = false
    private(set) var statusMessage: String?
    private(set) var lastRefresh: Date?
    var selectedConversationID: String?

    private(set) var accounts: [AccountRef]
    private let installer: ActivityHookInstaller
    private let deployment: ClaudeStatusBridgeDeployment
    private let demoMode: Bool
    private var cachedEvents: [ActivityEvent] = []
    private var eventFilesSignature: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefreshNow: Date?
    @ObservationIgnored private var refreshGeneration = 0

    init(
        accounts: [AccountRef],
        installer: ActivityHookInstaller? = nil,
        deployment: ClaudeStatusBridgeDeployment? = nil,
        fileManager: FileManager = .default,
        demoMode: Bool = ProcessInfo.processInfo.environment["CLAUDEX_ACTIVITY_DEMO"] == "1"
    ) {
        self.accounts = accounts
        self.installer = installer ?? ActivityHookInstaller(fileManager: fileManager)
        self.deployment = deployment ?? ClaudeStatusBridgeDeployment(fileManager: fileManager)
        self.demoMode = demoMode
        refresh()
        if collectionEnabled, !demoMode {
            do {
                try self.deployment.deploy(from: ClaudeStatusBridgeDeployment.bundledExecutableURL)
            } catch {
                statusMessage = "The local Activity Map helper needs repair: \(error.localizedDescription)"
            }
        }
    }

    var selectedConversation: ActivityConversation? {
        guard let selectedConversationID else { return conversations.first }
        return conversations.first { $0.id == selectedConversationID } ?? conversations.first
    }

    var connectedAccountCount: Int { installer.installations().count }

    var connectedCodexAccounts: [AccountRef] { connectedAccounts(for: .codex) }

    var connectedClaudeAccounts: [AccountRef] { connectedAccounts(for: .claude) }

    func accountLabel(for key: String) -> String? {
        installer.installations().first { $0.accountKey == key }?.handle
    }

    func update(accounts: [AccountRef]) {
        self.accounts = accounts
        collectionEnabled = !installer.installations().isEmpty
    }

    func enableCollection() {
        statusMessage = nil
        do {
            try deployment.deploy(from: ClaudeStatusBridgeDeployment.bundledExecutableURL)
            let report = installer.install(accounts: accounts)
            collectionEnabled = !installer.installations().isEmpty
            if report.issues.isEmpty {
                statusMessage = nil
            } else {
                let prefix = report.connected > 0
                    ? "Connected \(report.connected) account\(report.connected == 1 ? "" : "s"); some configurations were left unchanged:\n"
                    : "No configurations were changed:\n"
                statusMessage = prefix + report.issues.joined(separator: "\n")
            }
        } catch {
            collectionEnabled = false
            statusMessage = error.localizedDescription
        }
        refresh()
    }

    func beginCodexHookReview(account: AccountRef) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString("/hooks", forType: .string) else {
            statusMessage = "Could not copy /hooks. Open Codex and type it manually."
            return
        }
        if let error = HandoffLauncher.launch(
            account: account,
            workingDirectory: nil,
            preferredTerminal: nil
        ) {
            statusMessage = "Copied /hooks, but Codex could not be opened: \(error)"
        } else {
            statusMessage = "Opened Codex · \(account.handle). Paste /hooks, press Return, then approve the Claudex command hook."
        }
    }

    func openFreshSession(account: AccountRef) {
        if let error = HandoffLauncher.launch(
            account: account,
            workingDirectory: nil,
            preferredTerminal: nil
        ) {
            statusMessage = "Could not open \(account.provider.displayName) · \(account.handle): \(error)"
        } else {
            statusMessage = "Opened a fresh \(account.provider.displayName) · \(account.handle) session. Use one tool and its activity will appear here."
        }
    }

    func pauseCollection() {
        let report = installer.removeAll()
        collectionEnabled = !installer.installations().isEmpty
        statusMessage = report.issues.isEmpty
            ? "Collection paused. Existing local activity remains visible."
            : report.issues.joined(separator: "\n")
        refresh()
    }

    func deleteHistory() {
        do {
            refreshGeneration += 1
            refreshTask?.cancel()
            pendingRefreshNow = nil
            try installer.deleteEventFiles()
            cachedEvents = []
            eventFilesSignature = nil
            conversations = []
            selectedConversationID = nil
            statusMessage = "Local activity history deleted."
        } catch {
            statusMessage = "Could not delete local activity history: \(error.localizedDescription)"
        }
    }

    func refresh(now: Date = Date()) {
        collectionEnabled = !installer.installations().isEmpty
        if demoMode {
            collectionEnabled = true
            apply(events: Self.demoEvents(now: now), now: now)
            return
        }

        // File metadata and JSON decoding must never block SwiftUI's main thread. A busy
        // hook spool can change continuously, so coalesce timer ticks while one snapshot
        // is being loaded instead of allowing overlapping full refreshes.
        installer.removeExpiredEventFiles(now: now)
        pendingRefreshNow = now
        startPendingRefreshIfNeeded()
    }

    private func startPendingRefreshIfNeeded() {
        guard refreshTask == nil, let now = pendingRefreshNow else { return }
        pendingRefreshNow = nil
        let directory = installer.eventDirectory
        let previousSignature = eventFilesSignature
        let generation = refreshGeneration

        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                Self.loadEventSnapshot(
                    eventDirectory: directory,
                    now: now,
                    previousSignature: previousSignature
                )
            }.value
            guard let self else { return }
            self.refreshTask = nil
            guard generation == self.refreshGeneration else {
                self.startPendingRefreshIfNeeded()
                return
            }
            if let events = snapshot.events {
                self.cachedEvents = events
                self.eventFilesSignature = snapshot.signature
                self.apply(events: events, now: now)
            } else {
                self.lastRefresh = now
            }
            self.startPendingRefreshIfNeeded()
        }
    }

    private func apply(events: [ActivityEvent], now: Date) {
        let updatedConversations = Self.conversations(from: events)
        if updatedConversations != conversations {
            conversations = updatedConversations
        }
        if selectedConversationID == nil
            || !conversations.contains(where: { $0.id == selectedConversationID }) {
            selectedConversationID = conversations.first?.id
        }
        lastRefresh = now
    }

    private func connectedAccounts(for provider: Provider) -> [AccountRef] {
        let installedHandles = Set(
            installer.installations()
                .filter { $0.provider == provider }
                .map(\.handle)
        )
        return accounts
            .filter { $0.provider == provider && installedHandles.contains($0.handle) }
            .sorted { lhs, rhs in
                if lhs.handle == "default" { return true }
                if rhs.handle == "default" { return false }
                return lhs.handle.localizedCaseInsensitiveCompare(rhs.handle) == .orderedAscending
            }
    }

    /// Loads at most the newest events needed by the UI. This is intentionally
    /// nonisolated so callers can run it on a utility task rather than the main actor.
    nonisolated static func loadEventSnapshot(
        eventDirectory: URL,
        now: Date,
        previousSignature: String?
    ) -> ActivityEventSnapshot {
        let fileManager = FileManager()
        guard let files = try? fileManager.contentsOfDirectory(
            at: eventDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        ) else {
            return ActivityEventSnapshot(
                signature: "missing",
                events: previousSignature == "missing" ? nil : []
            )
        }
        let eventFiles = files.compactMap { file -> (url: URL, size: Int, modifiedAt: Date?)? in
            guard file.lastPathComponent.hasPrefix("events-"), file.pathExtension == "jsonl",
                  let values = try? file.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size >= 0,
                  size <= 1_048_576
            else { return nil }
            return (file, size, values.contentModificationDate)
        }
        let signature = eventFiles.map { file in
            "\(file.url.lastPathComponent):\(file.size):\(file.modifiedAt?.timeIntervalSince1970 ?? -1)"
        }
        .sorted()
        .joined(separator: "|")
        guard signature != previousSignature else {
            return ActivityEventSnapshot(signature: signature, events: nil)
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? .distantPast
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let standard = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = (try? fractional.parse(value)) ?? (try? standard.parse(value)) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Activity Map timestamp"
            )
        }

        var events: [ActivityEvent] = []
        events.reserveCapacity(2_500)
        for file in eventFiles.sorted(by: { $0.url.lastPathComponent > $1.url.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file.url, options: [.mappedIfSafe]) else { continue }
            for line in data.split(separator: 0x0A).reversed() {
                guard let event = try? decoder.decode(ActivityEvent.self, from: Data(line)),
                      event.schemaVersion == 1,
                      event.observedAt >= cutoff,
                      event.observedAt <= now.addingTimeInterval(300)
                else { continue }
                events.append(event)
                if events.count == 2_500 { break }
            }
            if events.count == 2_500 { break }
        }
        return ActivityEventSnapshot(
            signature: signature,
            events: events.sorted { $0.observedAt < $1.observedAt }
        )
    }

    nonisolated static func conversations(from events: [ActivityEvent]) -> [ActivityConversation] {
        let grouped = Dictionary(grouping: events) {
            "\($0.provider.rawValue):\($0.accountKey):\($0.sessionKey)"
        }
        return grouped.compactMap { id, values in
            guard let first = values.min(by: { $0.observedAt < $1.observedAt }),
                  let last = values.max(by: { $0.observedAt < $1.observedAt })
            else { return nil }
            return ActivityConversation(
                id: id,
                provider: first.provider,
                accountKey: first.accountKey,
                projectKey: first.projectKey,
                projectLabel: first.projectLabel,
                startedAt: first.observedAt,
                updatedAt: last.observedAt,
                events: values.sorted { $0.observedAt < $1.observedAt }
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private nonisolated static func demoEvents(now: Date) -> [ActivityEvent] {
        func event(
            _ offset: TimeInterval,
            provider: Provider,
            session: String,
            project: String,
            kind: ActivityEventKind,
            tool: String? = nil,
            category: ActivityToolCategory? = nil,
            outcome: ActivityOutcome = .succeeded,
            resources: [ActivityResource] = []
        ) -> ActivityEvent {
            ActivityEvent(
                schemaVersion: 1,
                id: UUID().uuidString,
                observedAt: now.addingTimeInterval(offset),
                provider: provider,
                accountKey: "demo-\(provider.rawValue)",
                sessionKey: session,
                turnKey: "turn",
                agentKey: category == .agent ? "agent" : nil,
                projectKey: project.lowercased(),
                projectLabel: project,
                kind: kind,
                toolName: tool,
                toolCategory: category,
                outcome: outcome,
                resources: resources
            )
        }
        return [
            event(-1_800, provider: .codex, session: "release", project: "claudex", kind: .sessionStart, outcome: .started),
            event(-1_720, provider: .codex, session: "release", project: "claudex", kind: .toolCompleted, tool: "exec_command", category: .shell),
            event(-1_600, provider: .codex, session: "release", project: "claudex", kind: .toolCompleted, tool: "apply_patch", category: .edit, resources: [
                ActivityResource(path: "Sources/Claudex/Services/UsageStore.swift", action: .write),
                ActivityResource(path: "Sources/Claudex/UI/AccountCard.swift", action: .write),
            ]),
            event(-1_500, provider: .codex, session: "release", project: "claudex", kind: .permissionRequested, tool: "exec_command", category: .shell, outcome: .requested),
            event(-1_350, provider: .codex, session: "release", project: "claudex", kind: .subagentStart, tool: "Subagent", category: .agent, outcome: .started),
            event(-1_100, provider: .codex, session: "release", project: "claudex", kind: .toolCompleted, tool: "apply_patch", category: .edit, resources: [
                ActivityResource(path: "Tests/ClaudexTests/UsageServiceTests.swift", action: .write),
            ]),
            event(-900, provider: .codex, session: "release", project: "claudex", kind: .toolCompleted, tool: "exec_command", category: .shell),
            event(-700, provider: .codex, session: "release", project: "claudex", kind: .toolCompleted, tool: "web_search", category: .web),
            event(-300, provider: .codex, session: "release", project: "claudex", kind: .sessionEnd, outcome: .stopped),
            event(-7_200, provider: .claude, session: "docs", project: "mjukis.dev", kind: .sessionStart, outcome: .started),
            event(-7_100, provider: .claude, session: "docs", project: "mjukis.dev", kind: .toolCompleted, tool: "Read", category: .read, resources: [
                ActivityResource(path: "src/pages/claudex/index.njk", action: .read),
            ]),
            event(-6_900, provider: .claude, session: "docs", project: "mjukis.dev", kind: .toolCompleted, tool: "Edit", category: .edit, resources: [
                ActivityResource(path: "src/pages/claudex/index.njk", action: .write),
                ActivityResource(path: "CHANGELOG.md", action: .write),
            ]),
        ]
    }
}
