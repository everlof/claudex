import SwiftUI

/// One card per account. Exhaustively renders every `LoadState`, so an account can never
/// be shown in an inconsistent state.
struct AccountCard: View {
    let entry: AccountEntry
    let now: Date
    /// True when this account is running in the frontmost window — gets a highlight so
    /// it's clear which account the menu-bar number refers to.
    var isFrontmost: Bool = false

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
                    Text(entry.ref.handle)
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
        entry.state.value?.displayName
    }

    // MARK: Content — one branch per state

    @ViewBuilder
    private var content: some View {
        switch entry.state {
        case .idle, .loading:
            loadingRow
        case let .failed(error, _):
            errorRow(error)
        case let .loaded(usage, _):
            loadedContent(usage)
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

    private func errorRow(_ error: UsageError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Severity.warning.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.headline)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                if let d = error.detail {
                    Text(d)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func loadedContent(_ usage: AccountUsage) -> some View {
        HStack(alignment: .center, spacing: 12) {
            UsageRing(
                fraction: usage.headlineFraction,
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
                    if let rel = Fmt.relativeFuture(exp, now: now) {
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
