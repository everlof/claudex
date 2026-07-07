import Foundation

extension UsageHistory {

    /// A series ready to plot: its display name, the provider it rolls up to (for colour),
    /// and its total across the whole span (for legend ordering + direct labels).
    struct Series: Identifiable, Sendable {
        let name: String
        let provider: Provider
        let total: Double
        var id: String { name }
    }

    /// One stacked datum: bucket date, series name, value. The tidy row Swift Charts wants.
    struct Datum: Identifiable, Sendable {
        let date: Date
        let series: String
        let provider: Provider
        let value: Double
        var id: String { "\(date.timeIntervalSince1970)-\(series)" }
    }

    /// Collapse the raw points to (bucket × series) values for the chosen breakdown + metric.
    /// Switching breakdown or metric re-aggregates the same points — no refetch.
    func data(breakdown: HistoryBreakdown, metric: HistoryMetric) -> [Datum] {
        var acc: [String: Datum] = [:]
        for p in points {
            let name = seriesName(for: p, breakdown: breakdown)
            let key = "\(p.date.timeIntervalSince1970)-\(name)"
            let v = p.value(metric)
            if let prev = acc[key] {
                acc[key] = Datum(date: p.date, series: name, provider: prev.provider,
                                 value: prev.value + v)
            } else {
                acc[key] = Datum(date: p.date, series: name, provider: p.provider, value: v)
            }
        }
        return acc.values.sorted { $0.date < $1.date }
    }

    /// Distinct series for the breakdown, ordered by total descending (largest stacks first,
    /// and the legend reads top-to-bottom by size). Colour still follows the entity.
    func series(breakdown: HistoryBreakdown, metric: HistoryMetric) -> [Series] {
        var totals: [String: (provider: Provider, total: Double)] = [:]
        for p in points {
            let name = seriesName(for: p, breakdown: breakdown)
            let v = p.value(metric)
            if let prev = totals[name] {
                totals[name] = (prev.provider, prev.total + v)
            } else {
                totals[name] = (p.provider, v)
            }
        }
        return totals
            .map { Series(name: $0.key, provider: $0.value.provider, total: $0.value.total) }
            .filter { $0.total > 0 }
            .sorted {
                // Provider grouping first (Claude before Codex), then total desc within.
                if $0.provider != $1.provider { return $0.provider == .claude }
                return $0.total > $1.total
            }
    }

    /// The aggregated grand total across all series (for the hero figure).
    func grandTotal(metric: HistoryMetric) -> Double {
        points.reduce(0) { $0 + $1.value(metric) }
    }

    /// Per-bucket totals across every series — drives the hero sparkline / axis domain.
    func bucketTotals(metric: HistoryMetric) -> [(date: Date, value: Double)] {
        var acc: [Date: Double] = [:]
        for p in points { acc[p.date, default: 0] += p.value(metric) }
        return acc.map { (date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
    }

    private func seriesName(for p: UsagePoint, breakdown: HistoryBreakdown) -> String {
        switch breakdown {
        case .provider: return p.provider.displayName
        case .model: return p.series
        case .account: return p.accountLabel ?? p.provider.displayName
        }
    }
}
