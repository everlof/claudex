import Foundation

/// A normalized, account-level view of the user's available capacity. Percentages from
/// different plans are deliberately not treated as absolute quota: aggregate fractions are
/// equal-weight pressure signals, while actionable recommendations stay within one provider.
struct AccountPortfolio: Sendable {
    struct Account: Identifiable, Sendable {
        let ref: AccountRef
        let usage: AccountUsage

        var id: String { ref.id }
        var pressure: Double { usage.headlineFraction }
    }

    struct ProviderPool: Identifiable, Sendable {
        let provider: Provider
        let accounts: [Account]

        var id: Provider { provider }
        var best: Account? { accounts.min { $0.pressure < $1.pressure } }
    }

    struct HandoffRecommendation: Sendable {
        let source: AccountRef
        let target: Account
        /// Normalized improvement in consumed capacity, when the source has a snapshot.
        let improvement: Double?
    }

    let accounts: [Account]
    private let entries: [AccountEntry]

    init(entries: [AccountEntry]) {
        self.entries = entries
        accounts = entries.compactMap { entry in
            entry.state.value.map { Account(ref: entry.ref, usage: $0) }
        }
    }

    var providerPools: [ProviderPool] {
        Provider.allCases.compactMap { provider in
            let matches = accounts.filter { $0.ref.provider == provider }
            return matches.isEmpty ? nil : ProviderPool(provider: provider, accounts: matches)
        }
    }

    /// Accounts below the critical threshold can still accept work. Warning accounts remain
    /// "ready" because the handoff threshold intentionally fires before they are exhausted.
    var readyCount: Int { accounts.count { $0.usage.severity != .critical } }

    /// Critical snapshots plus rate-limited accounts without a usable cached snapshot.
    var constrainedCount: Int {
        let critical = accounts.count { $0.usage.severity == .critical }
        let rateLimitedWithoutSnapshot = entries.count { entry in
            guard entry.state.value == nil else { return false }
            if case .rateLimited = entry.state.error { return true }
            return false
        }
        return critical + rateLimitedWithoutSnapshot
    }

    /// Equal-weight normalized pressure. This is suitable for an ambient menu-bar signal,
    /// not an assertion that differently sized plan quotas can be literally pooled.
    var averageHeadlineFraction: Double? { average(accounts.map(\.pressure)) }
    var averageShortFraction: Double? { average(accounts.compactMap { $0.usage.shortWindow?.fraction }) }
    var averageLongFraction: Double? { average(accounts.compactMap { $0.usage.longWindow?.fraction }) }

    var severity: Severity {
        Severity.from(fraction: averageHeadlineFraction ?? 0)
    }

    /// The soonest reset on a window already under pressure. Low-usage resets are omitted:
    /// they do not materially restore the portfolio and would make the headline noisy.
    func nextUsefulReset(after now: Date) -> Date? {
        accounts
            .flatMap { $0.usage.windows }
            .filter { $0.fraction >= 0.75 }
            .compactMap(\.resetsAt)
            .filter { $0 > now }
            .min()
    }

    /// Recommend a same-provider target only once the source reaches warning pressure (75%)
    /// or has actually been rate limited. A small minimum improvement prevents noisy offers.
    func handoffRecommendation(for sourceID: String) -> HandoffRecommendation? {
        guard let sourceEntry = entries.first(where: { $0.ref.id == sourceID }) else { return nil }

        let sourcePressure: Double?
        let needsHandoff: Bool
        if let usage = sourceEntry.state.value {
            sourcePressure = usage.headlineFraction
            needsHandoff = usage.severity >= .warning
        } else if case .rateLimited = sourceEntry.state.error {
            sourcePressure = nil
            needsHandoff = true
        } else {
            return nil
        }
        guard needsHandoff else { return nil }

        let candidates = accounts.filter {
                $0.ref.provider == sourceEntry.ref.provider
                    && $0.ref.id != sourceEntry.ref.id
                    && $0.usage.severity != .critical
            }
        guard let target = candidates.min(by: { $0.pressure < $1.pressure }) else { return nil }

        let improvement = sourcePressure.map { $0 - target.pressure }
        if let improvement, improvement < 0.08 { return nil }

        return HandoffRecommendation(
            source: sourceEntry.ref,
            target: target,
            improvement: improvement
        )
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
