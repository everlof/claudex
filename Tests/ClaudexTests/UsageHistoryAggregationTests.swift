import Foundation
import Testing
@testable import Claudex

@Suite struct UsageHistoryAggregationTests {
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func dataAggregatesByProviderAndMetric() {
        let history = UsageHistory(
            granularity: .daily,
            points: [
                UsagePoint(date: day, series: "Opus", provider: .claude, accountLabel: "default", tokens: 100, cost: 1.5),
                UsagePoint(date: day, series: "Sonnet", provider: .claude, accountLabel: "work", tokens: 200, cost: 2.0),
                UsagePoint(date: day, series: "gpt-5", provider: .codex, accountLabel: "default", tokens: 50, cost: 0.5),
            ],
            fetchedAt: day
        )

        let rows = history.data(breakdown: .provider, metric: .tokens)
        #expect(rows.count == 2)
        #expect(rows.first(where: { $0.series == "Claude" })?.value == 300)
        #expect(rows.first(where: { $0.series == "Codex" })?.value == 50)
        #expect(history.grandTotal(metric: .cost) == 4.0)
    }

    @Test func seriesAreGroupedByProviderThenTotal() {
        let history = UsageHistory(
            granularity: .daily,
            points: [
                UsagePoint(date: day, series: "gpt-5", provider: .codex, accountLabel: nil, tokens: 1_000, cost: 0),
                UsagePoint(date: day, series: "Opus", provider: .claude, accountLabel: nil, tokens: 100, cost: 0),
                UsagePoint(date: day, series: "Sonnet", provider: .claude, accountLabel: nil, tokens: 200, cost: 0),
            ],
            fetchedAt: day
        )

        let series = history.series(breakdown: .model, metric: .tokens)
        #expect(series.map(\.name) == ["Sonnet", "Opus", "gpt-5"])
    }
}
