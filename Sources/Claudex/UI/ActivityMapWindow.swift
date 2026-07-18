import AppKit
import SwiftUI

/// A single reusable standalone window for the opt-in Activity Map beta.
@MainActor
enum ActivityMapWindow {
    private static var window: NSWindow?
    private static var store: ActivityStore?

    static func show(accounts: [AccountRef]) {
        if let store { store.update(accounts: accounts) }
        let activityStore = store ?? ActivityStore(accounts: accounts)
        store = activityStore

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: ActivityMapWindowContent(store: activityStore))
        host.view.frame = NSRect(x: 0, y: 0, width: 940, height: 650)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.title = "Activity Map (Beta)"
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        writeCaptureIfRequested(view: host.view)
    }

    private static func writeCaptureIfRequested(view: NSView) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CLAUDEX_ACTIVITY_CAPTURE_PATH"], !path.isEmpty else { return }
        let delay = environment["CLAUDEX_ACTIVITY_CAPTURE_DELAY_MS"].flatMap(Int.init) ?? 1_200
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            view.layoutSubtreeIfNeeded()
            defer {
                if environment["CLAUDEX_ACTIVITY_CAPTURE_EXIT"] == "1" {
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

private struct ActivityMapWindowContent: View {
    @Bindable var store: ActivityStore
    @State private var selection: ActivityGraphSelection?
    @State private var now = Date()
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !store.collectionEnabled && store.conversations.isEmpty {
                disclosure
            } else if store.conversations.isEmpty {
                waitingState
            } else {
                activityContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(windowBackground)
        .onReceive(refresh) {
            now = $0
            store.refresh(now: $0)
        }
        .onChange(of: store.selectedConversationID) {
            selection = .conversation
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Provider.claude.accentColor, Provider.codex.accentColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("Activity Map")
                        .font(.title3.weight(.semibold))
                    Pill(text: "Beta", tint: Provider.codex.accentColor, filled: true)
                }
                Text("Observed conversations, tools, permissions, and repository-relative files")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.collectionEnabled {
                Label(
                    store.conversations.isEmpty ? "Waiting for first event" : "Observing locally",
                    systemImage: store.conversations.isEmpty ? "clock.badge.exclamationmark" : "record.circle"
                )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(store.conversations.isEmpty ? Severity.warning.color : Severity.normal.color)
                Menu {
                    Button("Pause collection") { store.pauseCollection() }
                    Divider()
                    Button("Delete local history", role: .destructive) { store.deleteHistory() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Activity Map options")
            } else if !store.conversations.isEmpty {
                Label("Paused", systemImage: "pause.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Button("Resume") { store.enableCollection() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var disclosure: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Review before enabling")
                        .font(.title2.weight(.semibold))
                    Text("Claudex adds a small reversible hook to each discovered Claude and Codex account. The hook creates a local metadata map; it never changes or controls an agent action.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 28) {
                    disclosureColumn(
                        title: "Kept for 7 days",
                        symbol: "externaldrive.badge.checkmark",
                        rows: [
                            "Provider, tool name, time, and success or failure",
                            "Project folder name and repository-relative file paths",
                            "Permission requests and subagent lifecycle",
                            "Hashed session, turn, agent, project, and account identifiers",
                        ]
                    )
                    disclosureColumn(
                        title: "Never retained",
                        symbol: "eye.slash",
                        rows: [
                            "Prompts, responses, reasoning, or file contents",
                            "Shell commands, tool inputs, or tool outputs",
                            "Credentials, full working-directory paths, or transcript paths",
                            "External uploads, analytics, or telemetry",
                        ]
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("What changes", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Text("Existing hooks are preserved. Pausing removes only Claudex’s exact hook entries and leaves the local history available until you delete it. Codex requires a review in /hooks before new command hooks run; the command stays stable across upgrades.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let message = store.statusMessage {
                    statusBanner(message)
                }

                HStack {
                    Text("\(store.accounts.count) account\(store.accounts.count == 1 ? "" : "s") discovered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Enable Activity Map") { store.enableCollection() }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.accounts.isEmpty)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(36)
            .frame(maxWidth: .infinity)
        }
    }

    private func disclosureColumn(title: String, symbol: String, rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: symbol)
                .font(.headline)
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Severity.normal.color)
                        .font(.caption)
                        .padding(.top, 2)
                    Text(row)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var waitingState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Provider.codex.accentColor)
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.connectedCodexAccounts.isEmpty ? "Start a fresh session" : "Finish setup")
                            .font(.title2.weight(.semibold))
                        Text("The local hooks are installed. New sessions load them automatically; this window updates after the first supported event.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let codex = store.connectedCodexAccounts.first {
                    setupStep(
                        number: 1,
                        title: "Review the Codex hook",
                        detail: codexReviewDetail
                    ) {
                        HStack(spacing: 10) {
                            Button("Copy /hooks & Open Codex") {
                                store.beginCodexHookReview(account: codex)
                            }
                            .buttonStyle(.borderedProminent)

                            if store.connectedCodexAccounts.count > 1 {
                                Menu("Other Codex accounts") {
                                    ForEach(store.connectedCodexAccounts.dropFirst()) { account in
                                        Button(account.handle) {
                                            store.beginCodexHookReview(account: account)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if let claude = store.connectedClaudeAccounts.first {
                    setupStep(
                        number: store.connectedCodexAccounts.isEmpty ? 1 : 2,
                        title: "Claude only needs a fresh session",
                        detail: claudeSessionDetail
                    ) {
                        HStack(spacing: 10) {
                            Button("Open Claude Code") {
                                store.openFreshSession(account: claude)
                            }
                            if store.connectedClaudeAccounts.count > 1 {
                                Menu("Other Claude accounts") {
                                    ForEach(store.connectedClaudeAccounts.dropFirst()) { account in
                                        Button(account.handle) {
                                            store.openFreshSession(account: account)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                setupStep(
                    number: (store.connectedCodexAccounts.isEmpty ? 0 : 1)
                        + (store.connectedClaudeAccounts.isEmpty ? 0 : 1) + 1,
                    title: "Use one tool",
                    detail: "Ask the new session to read a file, edit something, or run a command. Its conversation will then appear here automatically."
                )

                if let message = store.statusMessage {
                    statusBanner(message)
                }

                Text("You can leave this window open. Claudex checks for new local activity every 2 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 650, alignment: .leading)
            .padding(36)
            .frame(maxWidth: .infinity)
        }
    }

    private var codexReviewDetail: String {
        let count = store.connectedCodexAccounts.count
        let scope = count == 1
            ? "this Codex account"
            : "each of the \(count) Codex accounts you use"
        return "The button copies /hooks and opens a new Codex session. Paste it, press Return, and approve the Claudex command hook for \(scope)."
    }

    private var claudeSessionDetail: String {
        let count = store.connectedClaudeAccounts.count
        return count == 1
            ? "Open a new Claude Code session so it loads the installed hook. No separate review is required."
            : "Open a new Claude Code session for any of the \(count) accounts you use. No separate review is required."
    }

    private func setupStep<Actions: View>(
        number: Int,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text("\(number)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Provider.codex.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
    }

    private func setupStep(number: Int, title: String, detail: String) -> some View {
        setupStep(number: number, title: title, detail: detail) { EmptyView() }
    }

    private var activityContent: some View {
        VStack(spacing: 0) {
            if let message = store.statusMessage {
                statusBanner(message)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                Divider()
            }
            HStack(spacing: 0) {
                conversationSidebar
                Divider()
                if let conversation = store.selectedConversation {
                    VStack(spacing: 0) {
                        ActivityGraphView(conversation: conversation, selection: $selection)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        ActivitySelectionDetail(
                            conversation: conversation,
                            accountLabel: store.accountLabel(for: conversation.accountKey),
                            selection: selection ?? .conversation,
                            now: now
                        )
                        .frame(height: 64)
                    }
                }
            }
        }
    }

    private var conversationSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(.headline)
                Spacer()
                Text("\(store.conversations.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.conversations) { conversation in
                        Button {
                            store.selectedConversationID = conversation.id
                        } label: {
                            ActivityConversationRow(
                                conversation: conversation,
                                accountLabel: store.accountLabel(for: conversation.accountKey),
                                selected: store.selectedConversationID == conversation.id,
                                now: now
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(7)
            }

            Divider()
            Text("Local metadata · 7-day retention")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: 235)
    }

    private func statusBanner(_ message: String) -> some View {
        Label(message, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }

    private var windowBackground: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            LinearGradient(
                colors: [
                    Provider.claude.accentColor.opacity(0.035),
                    .clear,
                    Provider.codex.accentColor.opacity(0.035),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct ActivityConversationRow: View {
    let conversation: ActivityConversation
    let accountLabel: String?
    let selected: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: conversation.provider.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(conversation.provider.accentColor)
                .frame(width: 19, height: 19)
                .background(conversation.provider.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.projectLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(accountLabel ?? conversation.provider.displayName)
                    Text("·")
                    Text(Fmt.relativePast(conversation.updatedAt, now: now))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text("\(conversation.toolCallCount) tools · \(conversation.resourceCount) files")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? conversation.provider.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .accessibilityLabel("\(conversation.provider.displayName) conversation in \(conversation.projectLabel)")
        .accessibilityValue("\(conversation.toolCallCount) tools, \(conversation.resourceCount) files")
    }
}

private enum ActivityGraphSelection: Hashable {
    case conversation
    case tool(ActivityToolCategory)
    case resource(String)
}

private struct ActivityGraphView: View {
    let conversation: ActivityConversation
    @Binding var selection: ActivityGraphSelection?

    var body: some View {
        GeometryReader { geometry in
            let layout = ActivityGraphLayout(conversation: conversation, size: geometry.size)
            ZStack {
                Canvas { context, _ in
                    for edge in layout.sessionEdges {
                        stroke(edge: edge, color: conversation.provider.accentColor, context: &context)
                    }
                    for edge in layout.resourceEdges {
                        stroke(edge: edge, color: edge.action == .write ? Provider.claude.accentColor : Provider.codex.accentColor, context: &context)
                    }
                }

                graphColumnLabels(layout)

                ActivityGraphNode(
                    symbol: conversation.provider.symbolName,
                    title: conversation.projectLabel,
                    subtitle: "\(conversation.toolCallCount) observed tools",
                    tint: conversation.provider.accentColor,
                    selected: selection == .conversation,
                    width: 148
                ) { selection = .conversation }
                .position(layout.sessionPoint)

                ForEach(layout.tools, id: \.category) { tool in
                    ActivityGraphNode(
                        symbol: tool.category.symbolName,
                        title: tool.category.displayName,
                        subtitle: "\(tool.count) event\(tool.count == 1 ? "" : "s")",
                        tint: activityColor(tool.category),
                        selected: selection == .tool(tool.category),
                        width: 116
                    ) { selection = .tool(tool.category) }
                    .position(tool.point)
                }

                ForEach(layout.resources, id: \.path) { resource in
                    ActivityGraphNode(
                        symbol: resource.stats.writes > 0 ? "doc.badge.plus" : "doc.text",
                        title: URL(fileURLWithPath: resource.path).lastPathComponent,
                        subtitle: resource.parent,
                        tint: resource.stats.writes > 0 ? Provider.claude.accentColor : Provider.codex.accentColor,
                        selected: selection == .resource(resource.path),
                        width: 166
                    ) { selection = .resource(resource.path) }
                    .position(resource.point)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Activity graph for \(conversation.projectLabel)")
        }
        .padding(6)
    }

    private func graphColumnLabels(_ layout: ActivityGraphLayout) -> some View {
        ZStack {
            Text("CONVERSATION").position(x: layout.sessionPoint.x, y: 20)
            Text("TOOLS").position(x: layout.toolX, y: 20)
            if !layout.resources.isEmpty {
                Text("FILES").position(x: layout.resourceX, y: 20)
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .kerning(0.7)
    }

    private func stroke(edge: ActivityGraphLayout.Edge, color: Color, context: inout GraphicsContext) {
        var path = Path()
        path.move(to: edge.start)
        let distance = max(28, (edge.end.x - edge.start.x) * 0.5)
        path.addCurve(
            to: edge.end,
            control1: CGPoint(x: edge.start.x + distance, y: edge.start.y),
            control2: CGPoint(x: edge.end.x - distance, y: edge.end.y)
        )
        context.stroke(
            path,
            with: .color(color.opacity(edge.action == nil ? 0.32 : 0.42)),
            style: StrokeStyle(lineWidth: min(4, 1 + sqrt(CGFloat(edge.count))), lineCap: .round)
        )
    }

    private func activityColor(_ category: ActivityToolCategory) -> Color {
        switch category {
        case .edit: return Provider.claude.accentColor
        case .read, .search: return Provider.codex.accentColor
        case .shell: return .secondary
        case .web: return .blue
        case .mcp: return .indigo
        case .agent: return .purple
        case .interaction: return .yellow
        case .other: return .secondary
        }
    }
}

private struct ActivityGraphNode: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color
    let selected: Bool
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(width: width)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.9) : Color.primary.opacity(0.11), lineWidth: selected ? 2 : 1)
            )
            .shadow(color: selected ? tint.opacity(0.16) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
    }
}

private struct ActivityGraphLayout {
    struct ToolNode {
        let category: ActivityToolCategory
        let count: Int
        let point: CGPoint
    }

    struct ResourceNode {
        let path: String
        let parent: String
        let stats: ActivityResourceStats
        let point: CGPoint
    }

    struct Edge {
        let start: CGPoint
        let end: CGPoint
        let count: Int
        let action: ActivityResourceAction?
    }

    let sessionPoint: CGPoint
    let toolX: CGFloat
    let resourceX: CGFloat
    let tools: [ToolNode]
    let resources: [ResourceNode]
    let sessionEdges: [Edge]
    let resourceEdges: [Edge]

    init(conversation: ActivityConversation, size: CGSize) {
        let localSessionPoint = CGPoint(x: 88, y: max(90, size.height * 0.52))
        let localToolX = max(235, size.width * 0.45)
        let localResourceX = max(localToolX + 165, size.width - 92)

        let toolValues = conversation.toolCounts
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key.rawValue < rhs.key.rawValue : lhs.value > rhs.value }
            .prefix(7)
        let toolPoints = Self.verticalPoints(count: toolValues.count, height: size.height)
        let localTools = zip(toolValues, toolPoints).map { value, y in
            ToolNode(category: value.key, count: value.value, point: CGPoint(x: localToolX, y: y))
        }

        let resourceValues = conversation.resourceStats
            .sorted { lhs, rhs in lhs.value.total == rhs.value.total ? lhs.key < rhs.key : lhs.value.total > rhs.value.total }
            .prefix(9)
        let resourcePoints = Self.verticalPoints(count: resourceValues.count, height: size.height)
        let localResources = zip(resourceValues, resourcePoints).map { value, y in
            let parent = (value.key as NSString).deletingLastPathComponent
            return ResourceNode(
                path: value.key,
                parent: parent == "." || parent == "/" ? "Project root" : parent,
                stats: value.value,
                point: CGPoint(x: localResourceX, y: y)
            )
        }

        let localSessionEdges = localTools.map {
            Edge(start: localSessionPoint, end: $0.point, count: $0.count, action: nil)
        }

        let toolByCategory = Dictionary(uniqueKeysWithValues: localTools.map { ($0.category, $0) })
        let resourceByPath = Dictionary(uniqueKeysWithValues: localResources.map { ($0.path, $0) })
        var counts: [String: (category: ActivityToolCategory, path: String, action: ActivityResourceAction, count: Int)] = [:]
        for event in conversation.events {
            guard let category = event.toolCategory, toolByCategory[category] != nil else { continue }
            for resource in event.resources where resourceByPath[resource.path] != nil {
                let key = "\(category.rawValue):\(resource.action.rawValue):\(resource.path)"
                var value = counts[key] ?? (category, resource.path, resource.action, 0)
                value.count += 1
                counts[key] = value
            }
        }
        let localResourceEdges: [Edge] = counts.values.compactMap { value -> Edge? in
            guard let tool = toolByCategory[value.category], let resource = resourceByPath[value.path]
            else { return nil }
            return Edge(start: tool.point, end: resource.point, count: value.count, action: value.action)
        }
        sessionPoint = localSessionPoint
        toolX = localToolX
        resourceX = localResourceX
        tools = localTools
        resources = localResources
        sessionEdges = localSessionEdges
        resourceEdges = localResourceEdges
    }

    private static func verticalPoints(count: Int, height: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let top: CGFloat = 58
        let bottom = max(top + 1, height - 54)
        if count == 1 { return [(top + bottom) * 0.5] }
        return (0..<count).map { index in
            top + (bottom - top) * CGFloat(index) / CGFloat(count - 1)
        }
    }
}

private struct ActivitySelectionDetail: View {
    let conversation: ActivityConversation
    let accountLabel: String?
    let selection: ActivityGraphSelection
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if conversation.permissionCount > 0 {
                Label("\(conversation.permissionCount) permission request\(conversation.permissionCount == 1 ? "" : "s")", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch selection {
        case .conversation: return conversation.provider.symbolName
        case let .tool(category): return category.symbolName
        case .resource: return "doc.text"
        }
    }

    private var tint: Color {
        switch selection {
        case .conversation: return conversation.provider.accentColor
        case .tool(.edit): return Provider.claude.accentColor
        case .tool: return Provider.codex.accentColor
        case let .resource(path):
            return (conversation.resourceStats[path]?.writes ?? 0) > 0
                ? Provider.claude.accentColor : Provider.codex.accentColor
        }
    }

    private var title: String {
        switch selection {
        case .conversation: return conversation.projectLabel
        case let .tool(category): return category.displayName
        case let .resource(path): return path
        }
    }

    private var detail: String {
        switch selection {
        case .conversation:
            let account = accountLabel.map { " · \($0)" } ?? ""
            return "\(conversation.provider.displayName)\(account) · \(conversation.toolCallCount) tools · \(conversation.resourceCount) files · updated \(Fmt.relativePast(conversation.updatedAt, now: now))"
        case let .tool(category):
            let events = conversation.events.filter { $0.toolCategory == category }
            let names = Dictionary(grouping: events.compactMap(\.toolName), by: { $0 })
                .map { "\($0.key) ×\($0.value.count)" }
                .sorted()
                .prefix(4)
            let permissions = events.filter { $0.kind == .permissionRequested }.count
            return names.joined(separator: " · ") + (permissions > 0 ? " · \(permissions) requested permission" : "")
        case let .resource(path):
            guard let stats = conversation.resourceStats[path] else { return "Observed file activity" }
            var parts: [String] = []
            if stats.reads > 0 { parts.append("\(stats.reads) read\(stats.reads == 1 ? "" : "s")") }
            if stats.writes > 0 { parts.append("\(stats.writes) edit\(stats.writes == 1 ? "" : "s")") }
            if stats.searches > 0 { parts.append("\(stats.searches) search\(stats.searches == 1 ? "" : "es")") }
            return parts.joined(separator: " · ")
        }
    }
}
