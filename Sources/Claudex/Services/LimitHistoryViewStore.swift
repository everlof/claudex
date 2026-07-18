import Foundation
import Observation

enum LimitHistoryRange: Int, CaseIterable, Identifiable, Sendable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }
    var label: String { "\(rawValue)d" }
}

@MainActor
@Observable
final class LimitHistoryViewStore {
    private struct DemoSeriesSpec: Sendable {
        let provider: Provider
        let accountID: String
        let accountLabel: String
        let windowID: String
        let windowLabel: String
        let length: TimeInterval
        let interval: TimeInterval
        let source: LimitSampleSource
    }

    private(set) var snapshot = LimitHistorySnapshot.empty
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var range: LimitHistoryRange = .thirtyDays {
        didSet { reload() }
    }

    var selectedSeriesID: String?

    @ObservationIgnored private let history: LimitHistoryStore
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(history: LimitHistoryStore) {
        self.history = history
    }

    var series: [LimitHistorySeries] { snapshot.series }

    var selectedSeries: LimitHistorySeries? {
        let id = selectedSeriesID ?? series.first?.id
        return series.first { $0.id == id }
    }

    var selectedSamples: [LimitUsageSample] {
        guard let id = selectedSeries?.id else { return [] }
        return snapshot.samples.filter { $0.seriesID == id }.sorted { $0.observedAt < $1.observedAt }
    }

    var selectedResets: [LimitResetEvent] {
        guard let selectedSeries else { return [] }
        return snapshot.resets.filter {
            $0.provider == selectedSeries.provider
                && $0.accountID == selectedSeries.accountID
                && $0.windowID == selectedSeries.windowID
        }.sorted { $0.detectedAt < $1.detectedAt }
    }

    var latestReset: LimitResetEvent? { selectedResets.last }
    var totalCapacityRestored: Int {
        Int((selectedResets.reduce(0) { $0 + $1.capacityRestoredFraction } * 100).rounded())
    }

    var totalPaceBonus: Int {
        Int((selectedResets.reduce(0) { $0 + $1.paceBonusFraction } * 100).rounded())
    }

    var totalTimeGained: TimeInterval {
        selectedResets.reduce(0) { $0 + $1.secondsEarly }
    }

    func reload() {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        let since = Calendar.current.date(
            byAdding: .day,
            value: -range.rawValue,
            to: Date()
        ) ?? .distantPast
        let history = history
        loadTask = Task { [weak self] in
            do {
                let isDemo = ProcessInfo.processInfo.environment["CLAUDEX_LIMIT_HISTORY_DEMO"] == "1"
                let value: LimitHistorySnapshot = if isDemo {
                    Self.demoSnapshot(since: since)
                } else {
                    try await history.snapshot(since: since)
                }
                guard !Task.isCancelled, let self else { return }
                snapshot = value
                if selectedSeriesID == nil || !series.contains(where: { $0.id == selectedSeriesID }) {
                    if let latest = value.resets.max(by: { $0.detectedAt < $1.detectedAt }) {
                        selectedSeriesID = "\(latest.provider.rawValue):\(latest.accountID):\(latest.windowID)"
                    } else {
                        selectedSeriesID = series.first?.id
                    }
                }
                isLoading = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func deleteHistory() {
        let history = history
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                try await history.deleteHistory()
                guard let self else { return }
                snapshot = .empty
                selectedSeriesID = nil
                errorMessage = nil
                isLoading = false
            } catch {
                guard let self else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private nonisolated static func demoSnapshot(since: Date, now: Date = Date()) -> LimitHistorySnapshot {
        let codex = demoSeries(
            spec: DemoSeriesSpec(
                provider: .codex,
                accountID: "codex:personal",
                accountLabel: "personal",
                windowID: "week",
                windowLabel: "Weekly",
                length: 7 * 24 * 60 * 60,
                interval: 6 * 60 * 60,
                source: .codexAPI
            ),
            since: since,
            now: now
        )
        let claude = demoSeries(
            spec: DemoSeriesSpec(
                provider: .claude,
                accountID: "claude:work",
                accountLabel: "work",
                windowID: "5h",
                windowLabel: "5-hour",
                length: 5 * 60 * 60,
                interval: 20 * 60,
                source: .claudeStatusLine
            ),
            since: max(since, now.addingTimeInterval(-7 * 24 * 60 * 60)),
            now: now
        )
        let eventDetectedAt = now.addingTimeInterval(-5.1 * 24 * 60 * 60)
        let event = LimitResetEvent(
            schemaVersion: 1,
            id: "demo-early-reset",
            provider: .codex,
            accountID: "codex:personal",
            accountLabel: "personal",
            windowID: "week",
            windowLabel: "Weekly",
            previousObservedAt: eventDetectedAt.addingTimeInterval(-15 * 60),
            detectedAt: eventDetectedAt,
            scheduledResetAt: eventDetectedAt.addingTimeInterval(46 * 60 * 60),
            newScheduledResetAt: eventDetectedAt.addingTimeInterval(7 * 24 * 60 * 60),
            windowLength: 7 * 24 * 60 * 60,
            capacityRestoredFraction: 0.72,
            elapsedFraction: 0.61,
            paceBonusFraction: 0.11,
            secondsEarly: 46 * 60 * 60
        )
        return LimitHistorySnapshot(
            samples: codex + claude,
            resets: event.detectedAt >= since ? [event] : [],
            loadedAt: now
        )
    }

    private nonisolated static func demoSeries(
        spec: DemoSeriesSpec,
        since: Date,
        now: Date
    ) -> [LimitUsageSample] {
        let anchor = now.addingTimeInterval(-spec.length * 0.22)
        var date = since
        var output: [LimitUsageSample] = []
        while date <= now {
            let cycles = floor(date.timeIntervalSince(anchor) / spec.length)
            let cycleStart = anchor.addingTimeInterval(cycles * spec.length)
            let phase = min(1, max(0, date.timeIntervalSince(cycleStart) / spec.length))
            let wave = sin(date.timeIntervalSince1970 / 12000) * 0.025
            let fraction = min(0.97, max(0.01, phase * 1.08 + wave))
            output.append(LimitUsageSample(
                schemaVersion: 1,
                observedAt: date,
                provider: spec.provider,
                accountID: spec.accountID,
                accountLabel: spec.accountLabel,
                windowID: spec.windowID,
                windowLabel: spec.windowLabel,
                fraction: fraction,
                resetsAt: cycleStart.addingTimeInterval(spec.length),
                windowLength: spec.length,
                source: spec.source
            ))
            date = date.addingTimeInterval(spec.interval)
        }
        return output
    }
}
