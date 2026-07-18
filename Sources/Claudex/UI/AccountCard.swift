import SwiftUI

/// One card per account. Exhaustively renders every `LoadState`, so an account can never
/// be shown in an inconsistent state.
struct AccountCard: View {
    let entry: AccountEntry
    let now: Date
    /// True when this account is running in the frontmost window — gets a highlight so
    /// it's clear which account the menu-bar number refers to.
    var isFrontmost: Bool = false
    /// Opens this account's correctly-routed CLI so an expired session can refresh or
    /// guide the user through login without making them reconstruct its config path.
    var onOpenCLI: ((AccountRef) -> String?)? = nil
    /// A healthier same-provider account, offered only when this account is under pressure.
    var handoff: AccountPortfolio.HandoffRecommendation? = nil
    /// Opens a fresh CLI session under the selected account. Returns nil on success.
    var onHandoff: ((AccountRef) -> String?)? = nil
    /// Passive Claude Code integration state. Nil for Codex and demo fixtures.
    var claudeIntegration: ClaudeIntegrationState? = nil
    /// Present after an opt-in OAuth refresh succeeds for this account.
    var claudeDirectRefreshAt: Date? = nil
    var claudeDirectRefreshSource: ClaudeDirectRefreshSource? = nil
    var claudeSettingsPath: String? = nil
    var onConnectClaude: (() -> String?)? = nil
    var onDisconnectClaude: (() -> String?)? = nil
    var onForgetClaudeMetadata: (() -> String?)? = nil

    @State private var handoffError: String?
    @State private var recoveryError: String?
    @State private var integrationError: String?
    @State private var showsConnectReview = false
    @State private var showsDisconnectReview = false
    @State private var showsForgetReview = false

    private var provider: Provider { entry.ref.provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(12)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    isFrontmost ? provider.accentColor.opacity(0.85) : Color.primary.opacity(0.06),
                    lineWidth: isFrontmost ? 1.5 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: isFrontmost ? provider.accentColor.opacity(0.25) : .clear,
                radius: isFrontmost ? 8 : 0)
        .alert(claudeReviewTitle, isPresented: $showsConnectReview) {
            Button(isClaudeRepairReview ? "Repair" : "Connect") {
                integrationError = onConnectClaude?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(connectReviewText)
        }
        .alert("Disconnect Claude Code usage?", isPresented: $showsDisconnectReview) {
            Button("Disconnect", role: .destructive) {
                integrationError = onDisconnectClaude?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Claudex will restore the exact status-line setting it found when you connected. If that setting has changed since then, Claudex will leave it untouched.")
        }
        .alert("Forget Claudex restore data?", isPresented: $showsForgetReview) {
            Button("Forget", role: .destructive) {
                integrationError = onForgetClaudeMetadata?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only Claudex’s owner-only restore metadata and usage cache. It never changes Claude settings. If settings still references the helper, Claudex will refuse and explain how to recover.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(provider.accentColor.opacity(0.16))
                    .frame(width: 26, height: 26)
                Image(systemName: provider.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(provider.accentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(DemoMode.handle(entry.ref.handle, id: entry.ref.id))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if isFrontmost {
                        Image(systemName: "arrow.up.forward.app.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(provider.accentColor)
                            .help("Running in the frontmost window")
                    }
                }
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let plan = entry.state.value?.planLabel {
                Pill(text: plan, tint: provider.accentColor)
            }
            if case .loaded = entry.state {
                StatusDot(severity: entry.state.value?.severity ?? .normal)
            }
        }
    }

    private var subtitle: String? {
        DemoMode.displayName(entry.state.value?.displayName, id: entry.ref.id)
    }

    // MARK: Content — one branch per state

    @ViewBuilder
    private var content: some View {
        if provider == .claude, let refreshedAt = claudeDirectRefreshAt {
            loadStateContent
            claudeDirectSourceRow(
                refreshedAt: refreshedAt,
                source: claudeDirectRefreshSource
            )
        } else if provider == .claude, let claudeIntegration {
            claudeContent(claudeIntegration)
        } else {
            loadStateContent
        }
    }

    @ViewBuilder
    private var loadStateContent: some View {
        switch entry.state {
        case .idle, .loading:
            loadingRow
        case let .failed(error, _):
            VStack(alignment: .leading, spacing: 8) {
                errorRow(error)
                if handoff != nil { handoffRow }
            }
        case let .loaded(usage, _):
            loadedContent(usage)
        }
    }

    @ViewBuilder
    private func claudeContent(_ integration: ClaudeIntegrationState) -> some View {
        switch integration {
        case .disconnected:
            claudeConnectRow

        case let .waiting(lastReceivedAt, version, rateLimitsPresent):
            claudeWaitingRow(
                lastReceivedAt: lastReceivedAt,
                version: version,
                rateLimitsPresent: rateLimitsPresent
            )

        case let .connected(valuesChangedAt, lastLimitsSeenAt, version, stale):
            loadStateContent
            claudeSourceRow(
                valuesChangedAt: valuesChangedAt,
                lastLimitsSeenAt: lastLimitsSeenAt,
                version: version,
                stale: stale
            )

        case let .needsRepair(message, observedAt):
            if entry.state.value != nil { loadStateContent }
            claudeIssueRow(
                title: "Local feed needs repair",
                message: message,
                observedAt: observedAt,
                allowsRepair: true,
                allowsDisconnect: true,
                allowsForget: false
            )

        case let .modified(message, observedAt):
            if entry.state.value != nil { loadStateContent }
            claudeIssueRow(
                title: "Claude settings changed",
                message: message,
                observedAt: observedAt,
                allowsRepair: false,
                allowsDisconnect: false,
                allowsForget: true
            )

        case let .failed(message):
            claudeIssueRow(
                title: "Local feed unavailable",
                message: message,
                observedAt: nil,
                allowsRepair: true,
                allowsDisconnect: true,
                allowsForget: false
            )
        }

        if let integrationError {
            Text(integrationError)
                .font(.system(size: 9.5))
                .foregroundStyle(Severity.warning.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading usage…")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(height: 40)
    }

    private var claudeConnectRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Connect Claude Code usage", systemImage: "bolt.horizontal.circle")
                .font(.system(size: 11.5, weight: .medium))
            Text("Use Claude Code’s local usage feed instead of reading its Keychain token or polling Anthropic.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Review & Connect…") {
                integrationError = nil
                showsConnectReview = true
            }
            .buttonStyle(.borderedProminent)
            .tint(provider.accentColor)
            .controlSize(.small)
            .disabled(onConnectClaude == nil)
        }
    }

    private func claudeWaitingRow(
        lastReceivedAt: Date?,
        version: String?,
        rateLimitsPresent: Bool?
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Waiting for Claude Code", systemImage: "ellipsis.circle")
                .font(.system(size: 11.5, weight: .medium))
            Text(waitingDetail(
                lastReceivedAt: lastReceivedAt,
                version: version,
                rateLimitsPresent: rateLimitsPresent
            ))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("If it keeps waiting, check workspace trust, `disableAllHooks`, and project/local status-line overrides.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                if let onOpenCLI {
                    Button("Open Claude CLI…") {
                        recoveryError = onOpenCLI(entry.ref)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(provider.accentColor)
                    .controlSize(.small)
                }
                Button("Disconnect…") { showsDisconnectReview = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if let recoveryError {
                Text(recoveryError)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Severity.warning.color)
            }
        }
    }

    private func waitingDetail(
        lastReceivedAt: Date?,
        version: String?,
        rateLimitsPresent: Bool?
    ) -> String {
        if let lastReceivedAt, rateLimitsPresent == false {
            let cli = version.map { " v\($0)" } ?? ""
            return "The helper ran \(Fmt.relativePast(lastReceivedAt, now: now)) with Claude Code\(cli), but Claude supplied no subscription limits. Confirm Claude Code 2.1.80+ and a supported Pro/Max login."
        }
        if let lastReceivedAt {
            return "The helper ran \(Fmt.relativePast(lastReceivedAt, now: now)), but a valid usage snapshot is not ready. Send another message in this account’s Claude CLI."
        }
        return "Start this account’s Claude CLI (2.1.80 or newer) and send one message. Usage arrives after its first response; Claudex makes no request itself."
    }

    private func claudeSourceRow(
        valuesChangedAt: Date,
        lastLimitsSeenAt: Date,
        version: String?,
        stale: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "bolt.horizontal.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(stale ? Severity.warning.color : provider.accentColor)
            Text(stale ? "Local feed stale" : "Local Claude Code feed")
                .font(.system(size: 9.5, weight: .medium))
            Text("· seen \(Fmt.relativePast(lastLimitsSeenAt, now: now)) · changed \(Fmt.relativePast(valuesChangedAt, now: now))")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 3)
            if let version {
                Text("v\(version)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Button {
                showsDisconnectReview = true
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.plain)
            .help("Disconnect local Claude Code feed")
        }
        .padding(.top, 1)
    }

    private func claudeDirectSourceRow(
        refreshedAt: Date,
        source: ClaudeDirectRefreshSource?
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: source == .keychain ? "key.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(provider.accentColor)
            Text("Active Claude refresh")
                .font(.system(size: 9.5, weight: .medium))
            Text("· updated \(Fmt.relativePast(refreshedAt, now: now))")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 3)
            Image(systemName: source == .keychain ? "memorychip" : "key.slash")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
                .help(
                    source == .keychain
                        ? "Keychain-authorized access token held only in memory for this app run"
                        : "Credential file only; no Keychain access"
                )
        }
        .padding(.top, 1)
    }

    private func claudeIssueRow(
        title: String,
        message: String,
        observedAt: Date?,
        allowsRepair: Bool,
        allowsDisconnect: Bool,
        allowsForget: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Severity.warning.color)
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let observedAt {
                Text("Last safe snapshot: \(Fmt.relativePast(observedAt, now: now))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 7) {
                if allowsRepair {
                    Button("Review & Repair…") { showsConnectReview = true }
                        .buttonStyle(.borderedProminent)
                        .tint(provider.accentColor)
                        .controlSize(.small)
                }
                if allowsDisconnect {
                    Button("Disconnect…") { showsDisconnectReview = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if allowsForget {
                    Button("Forget restore data…") { showsForgetReview = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var connectReviewText: String {
        let path = claudeSettingsPath ?? "this account’s Claude settings.json"
        return "Claudex will update \(path) to run a small local status-line helper copied to its stable owner-only Application Support folder. An existing status-line command is chained and restored on disconnect. The documented feed requires Claude Code 2.1.80+ and a Claude.ai Pro/Max login; other authentication modes may not provide these fields.\n\nUsage cache: five-hour and weekly percentages/reset times, last-changed time, and Claude Code version. Health heartbeat: received time, last-limits-seen time, version, and whether limits were present. The raw live payload—including credentials, prompts, responses, transcripts, working directory, and session ID—is discarded.\n\nRestore backup: owner-only metadata stores this config path and the exact original statusLine/command so it can be restored. It is never included in diagnostics or uploaded. Connecting this passive feed makes no Anthropic request from Claudex. Claude Code requires normal workspace trust before running status-line commands."
    }

    private var isClaudeRepairReview: Bool {
        switch claudeIntegration {
        case .needsRepair, .failed:
            true
        default:
            false
        }
    }

    private var claudeReviewTitle: String {
        isClaudeRepairReview ? "Repair Claude Code usage?" : "Connect Claude Code usage?"
    }

    private func errorRow(_ error: UsageError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Severity.warning.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.headline)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                if let d = errorDetail(error) {
                    Text(d)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if error == .tokenExpired, let onOpenCLI {
                    Button("Open \(provider.displayName) CLI…") {
                        recoveryError = onOpenCLI(entry.ref)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.top, 3)
                }
                if let recoveryError {
                    Text(recoveryError)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Severity.warning.color)
                }
            }
            Spacer()
        }
    }

    private func errorDetail(_ error: UsageError) -> String? {
        guard case let .rateLimited(retryAfter) = error,
              let retryAfter,
              let failedAt = entry.state.stamp
        else { return error.detail }

        let retryAt = failedAt.addingTimeInterval(retryAfter)
        guard retryAt > now else { return "Too many requests — retry available shortly." }
        return "Too many requests — paused for \(Fmt.relativeFuture(retryAt, now: now) ?? "a while")."
    }

    @ViewBuilder
    private func loadedContent(_ usage: AccountUsage) -> some View {
        HStack(alignment: .center, spacing: 12) {
            UsageRing(
                fraction: usage.currentHeadlineFraction,
                severity: usage.severity,
                size: 50,
                label: "\(provider.displayName) peak usage"
            )
            VStack(spacing: 9) {
                ForEach(usage.windows) { window in
                    WindowBar(window: window, now: now)
                }
            }
        }

        if !usage.extraWindows.isEmpty {
            ExtraWindowsView(windows: usage.extraWindows, now: now, accent: provider.accentColor)
        }

        if provider == .codex {
            ResetCreditsView(usage: usage, now: now)
        }

        if handoff != nil {
            handoffRow
        }
    }

    private var handoffRow: some View {
        Group {
            if let handoff {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(provider.accentColor)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("More capacity on \(DemoMode.handle(handoff.target.ref.handle, id: handoff.target.ref.id))")
                                .font(.system(size: 10.5, weight: .medium))
                            Text(handoffDetail(handoff))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 4)

                        Button("Handoff…") {
                            handoffError = onHandoff?(handoff.target.ref)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(provider.accentColor)
                        .controlSize(.small)
                        .font(.system(size: 9.5, weight: .semibold))
                        .disabled(onHandoff == nil)
                        .help("Start a fresh \(provider.displayName) session using \(handoff.target.ref.handle)")
                    }

                    if let handoffError {
                        Text(handoffError)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Severity.warning.color)
                    }
                }
                .padding(8)
                .background(provider.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func handoffDetail(_ handoff: AccountPortfolio.HandoffRecommendation) -> String {
        if let improvement = handoff.improvement {
            return "\(Int((improvement * 100).rounded())) points more headroom · fresh session"
        }
        return "Available now · fresh session"
    }

    private var cardBackground: some ShapeStyle {
        provider.accentColor.opacity(0.04)
    }
}

// MARK: - Extra / scoped windows (collapsible)

/// A compact expandable list of secondary windows (per-model / additional limits).
private struct ExtraWindowsView: View {
    let windows: [UsageWindow]
    let now: Date
    let accent: Color
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("\(windows.count) more limit\(windows.count == 1 ? "" : "s")")
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                    // Peek at the busiest hidden window when collapsed.
                    if !expanded, let peak = windows.max(by: { $0.fraction < $1.fraction }) {
                        Text("\(peak.label) \(peak.percent)%")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(peak.severity == .normal ? .secondary : peak.severity.color)
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 7) {
                    ForEach(windows) { w in
                        WindowBar(window: w, now: now)
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Reset credits (Codex)

/// Shows Codex reset-credit count plus the soonest expiry — the headline the user asked
/// for ("nbr reset and expirations for codex").
private struct ResetCreditsView: View {
    let usage: AccountUsage
    let now: Date
    private var optionDown: Bool { OptionKeyMonitor.shared.isOptionDown }

    private var count: Int {
        usage.resetCreditCount ?? usage.resetCredits.filter(\.isAvailable).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Provider.codex.accentColor)
                Text("Reset credits")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(count > 0 ? Provider.codex.accentColor : .secondary)
                Text(count == 1 ? "available" : "available")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if let next = usage.nextExpiringCredit, let exp = next.expiresAt {
                HStack(spacing: 5) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("Next expires")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let short = Fmt.shortDate(exp) {
                        Text(short)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                    // Countdown by default; the exact local clock time while ⌥ is held.
                    if optionDown, let at = Fmt.absoluteReset(exp, now: now) {
                        Text("· \(at)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else if let rel = Fmt.relativeFuture(exp, now: now) {
                        Text("· in \(rel)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if count > 0 {
                Text("No expiry details reported.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
