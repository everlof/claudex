import Foundation
import Observation

/// Owns the usage-history state for the chart: fetches per granularity (cached), and holds
/// the user's chart selections (metric / breakdown) which need no refetch to change.
@MainActor
@Observable
final class HistoryStore {
    /// The current snapshot for the selected granularity (empty until first load).
    private(set) var history: UsageHistory = .empty
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// True when ccusage isn't installed — the view shows a hint instead of an empty chart.
    private(set) var ccusageMissing = false

    // User selections. Granularity triggers a fetch; the others are pure view state.
    var granularity: HistoryGranularity = .daily {
        didSet { if granularity != oldValue { Task { await load(force: false) } } }
    }
    var metric: HistoryMetric = .cost
    var breakdown: HistoryBreakdown = .provider

    private let service = UsageHistoryService()
    private let accountsProvider: @MainActor () -> [AccountRef]
    /// Cache per granularity so flipping day/week/month is instant after first fetch.
    private var cache: [HistoryGranularity: UsageHistory] = [:]
    private var inFlight: Task<Void, Never>?

    init(accounts: @escaping @MainActor () -> [AccountRef]) {
        self.accountsProvider = accounts
    }

    /// The daily snapshot, for the compact panel chart (which always shows daily buckets over
    /// a short span, independent of the full view's granularity). Falls back to `history`.
    var dailyHistory: UsageHistory {
        cache[.daily] ?? (granularity == .daily ? history : .empty)
    }

    /// The daily data filtered to the last 7 days, always by model — the compact panel chart.
    func compactData(metric: HistoryMetric) -> [UsageHistory.Datum] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        return dailyHistory.data(breakdown: .model, metric: metric).filter { $0.date >= cutoff }
    }
    func compactSeries(metric: HistoryMetric) -> [UsageHistory.Series] {
        let names = Set(compactData(metric: metric).map(\.series))
        return dailyHistory.series(breakdown: .model, metric: metric).filter { names.contains($0.name) }
    }
    func compactTotal(metric: HistoryMetric) -> Double {
        compactData(metric: metric).reduce(0) { $0 + $1.value }
    }

    /// Load the current granularity, using the cache unless `force`.
    func load(force: Bool) async {
        if !force, let cached = cache[granularity] {
            history = cached
            return
        }
        inFlight?.cancel()
        let accounts = accountsProvider()
        guard !accounts.isEmpty else { history = .empty; return }

        isLoading = true
        loadError = nil
        let gran = granularity
        let task = Task { [service] in
            do {
                let result = try await service.fetch(granularity: gran, accounts: accounts)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.cache[gran] = result
                    if self.granularity == gran { self.history = result }
                    self.ccusageMissing = false
                    self.isLoading = false
                }
            } catch UsageHistoryService.HistoryError.ccusageNotFound {
                await MainActor.run {
                    self.ccusageMissing = true
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.loadError = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
        inFlight = Task { await task.value }
        await inFlight?.value
    }

    /// Invalidate the cache and reload the current granularity (used by the refresh button).
    func reload() async {
        cache.removeAll()
        await load(force: true)
    }
}
