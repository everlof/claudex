import SwiftUI

/// Portfolio overview of normalized capacity. It avoids pretending plan quotas are directly
/// additive: the bar is explicitly account-segmented and launch choices stay per provider.
struct PortfolioCard: View {
    let portfolio: AccountPortfolio
    let now: Date
    let activeAccountID: String?
    let activeSessionDetected: Bool
    let activeProvider: Provider?
    let onLaunch: (AccountRef) -> String?
    let onSelectAccount: (String) -> Void

    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            PortfolioSegmentBar(
                accounts: portfolio.accounts,
                onSelectAccount: onSelectAccount
            )
            providerRows
            footer
            if let launchError {
                Text(launchError)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Severity.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.thinMaterial)
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Provider.claude.accentColor.opacity(0.14),
                                Color.primary.opacity(0.025),
                                Provider.codex.accentColor.opacity(0.14),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Provider.claude.accentColor.opacity(0.55),
                            Color.primary.opacity(0.12),
                            Provider.codex.accentColor.opacity(0.55),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.25
                )
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Provider.claude.accentColor, Provider.codex.accentColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 2)
                .padding(.horizontal, 24)
                .opacity(0.8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Provider.claude.accentColor, Provider.codex.accentColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 26, height: 26)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("All Accounts")
                    .font(.system(size: 13, weight: .semibold))
                Text(activeDescription)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 3) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 8, weight: .semibold))
                Text("AVG \(averagePressure)%")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(portfolio.severity == .normal ? .secondary : portfolio.severity.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
    }

    private var activeDescription: String {
        if let activeAccountID,
           let active = portfolio.accounts.first(where: { $0.ref.id == activeAccountID }) {
            let handle = DemoMode.handle(active.ref.handle, id: active.ref.id)
            return "Current · \(active.ref.provider.displayName) \(handle)"
        }
        if activeSessionDetected {
            return "Active \(activeProvider?.displayName ?? "AI") account unknown"
        }
        return "Combined capacity · unmapped"
    }

    private var averagePressure: Int {
        Int(((portfolio.averageHeadlineFraction ?? 0) * 100).rounded())
    }

    private var providerRows: some View {
        VStack(spacing: 7) {
            ForEach(portfolio.providerPools) { pool in
                if let best = pool.best {
                    providerRow(pool: pool, best: best)
                }
            }
        }
    }

    private func providerRow(
        pool: AccountPortfolio.ProviderPool,
        best: AccountPortfolio.Account
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: pool.provider.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(pool.provider.accentColor)
                .frame(width: 14)

            Text(pool.provider.displayName)
                .font(.system(size: 10.5, weight: .medium))

            Text(DemoMode.handle(best.ref.handle, id: best.ref.id))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 3)

            Text(windowSummary(best.usage))
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(best.usage.severity == .normal ? .secondary : best.usage.severity.color)

            Button {
                launchError = onLaunch(best.ref)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(pool.provider.accentColor)
            .help("Start \(pool.provider.displayName) with \(best.ref.handle)")
        }
    }

    private func windowSummary(_ usage: AccountUsage) -> String {
        let short = usage.shortWindow.map { "\($0.percent)%" } ?? "–"
        let long = usage.longWindow.map { "\($0.percent)%" } ?? "–"
        return "\(short) / \(long)"
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Text("\(portfolio.readyCount) ready")
            if portfolio.constrainedCount > 0 {
                Text("· \(portfolio.constrainedCount) constrained")
                    .foregroundStyle(Severity.critical.color)
            }
            if let reset = portfolio.nextUsefulReset(after: now),
               let relative = Fmt.relativeFuture(reset, now: now) {
                Text("· capacity returns in \(relative)")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct PortfolioSegmentBar: View {
    let accounts: [AccountPortfolio.Account]
    let onSelectAccount: (String) -> Void

    @State private var hoveredAccountID: String?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(accounts) { account in
                Button {
                    onSelectAccount(account.id)
                } label: {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(hoveredAccountID == account.id ? 0.16 : 0.09))
                            Capsule()
                                .fill(account.usage.severity.color)
                                .frame(width: max(3, geometry.size.width * min(1, account.pressure)))
                        }
                        .frame(height: hoveredAccountID == account.id ? 7 : 5)
                        .frame(maxHeight: .infinity)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onHover { hovering in
                    hoveredAccountID = hovering ? account.id : nil
                }
                .help("Show \(account.ref.provider.displayName) \(account.ref.handle) — \(Int((account.pressure * 100).rounded()))%")
                .accessibilityLabel("Show \(account.ref.provider.displayName) \(account.ref.handle)")
            }
        }
        .frame(height: 15)
        .accessibilityLabel("Normalized usage across all accounts")
    }
}
