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
    private struct PreparedSeries: Sendable {
        let samples: [LimitUsageSample]
        let chartSamples: [LimitUsageSample]
        let resets: [LimitResetEvent]
        let totalCapacityRestored: Int
        let totalPaceBonus: Int
        let totalTimeGained: TimeInterval
    }

    private struct PreparedHistory: Sendable {
        let series: [LimitHistorySeries]
        let valuesBySeriesID: [String: PreparedSeries]
    }

    private struct SnapshotSignature: Equatable {
        let sampleCount: Int
        let firstSampleID: String?
        let lastSampleID: String?
        let resetCount: Int
        let firstResetID: String?
        let lastResetID: String?
    }

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
    private(set) var series: [LimitHistorySeries] = []
    private(set) var selectedSamples: [LimitUsageSample] = []
    private(set) var chartSamples: [LimitUsageSample] = []
    private(set) var selectedResets: [LimitResetEvent] = []
    private(set) var latestReset: LimitResetEvent?
    private(set) var totalCapacityRestored = 0
    private(set) var totalPaceBonus = 0
    private(set) var totalTimeGained: TimeInterval = 0
    var range: LimitHistoryRange = .thirtyDays {
        didSet { reload() }
    }

    var selectedSeriesID: String? {
        didSet { applySelectedSeries() }
    }

    @ObservationIgnored private let history: LimitHistoryStore
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var preparedBySeriesID: [String: PreparedSeries] = [:]
    @ObservationIgnored private var snapshotSignature: SnapshotSignature?
    @ObservationIgnored private var hasLoaded = false

    init(history: LimitHistoryStore) {
        self.history = history
    }

    var selectedSeries: LimitHistorySeries? {
        let id = selectedSeriesID ?? series.first?.id
        return series.first { $0.id == id }
    }

    func reload() {
        loadTask?.cancel()
        if !hasLoaded { isLoading = true }
        if errorMessage != nil { errorMessage = nil }
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
                let signature = Self.signature(of: value)
                guard !Task.isCancelled, let self else { return }
                if snapshotSignature == signature {
                    hasLoaded = true
                    isLoading = false
                    return
                }
                let prepared = await Task.detached(priority: .utility) {
                    Self.prepare(value)
                }.value
                guard !Task.isCancelled else { return }
                snapshot = value
                snapshotSignature = signature
                series = prepared.series
                preparedBySeriesID = prepared.valuesBySeriesID
                let selection: String
                if let selectedSeriesID,
                   prepared.valuesBySeriesID[selectedSeriesID] != nil
                {
                    selection = selectedSeriesID
                } else {
                    if let latest = value.resets.max(by: { $0.detectedAt < $1.detectedAt }) {
                        selection = "\(latest.provider.rawValue):\(latest.accountID):\(latest.windowID)"
                    } else {
                        selection = prepared.series.first?.id ?? ""
                    }
                }
                if selectedSeriesID == selection {
                    applySelectedSeries()
                } else {
                    selectedSeriesID = selection.isEmpty ? nil : selection
                }
                hasLoaded = true
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
                snapshotSignature = nil
                hasLoaded = true
                series = []
                preparedBySeriesID = [:]
                selectedSeriesID = nil
                applySelectedSeries()
                errorMessage = nil
                isLoading = false
            } catch {
                guard let self else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private nonisolated static func signature(of snapshot: LimitHistorySnapshot) -> SnapshotSignature {
        SnapshotSignature(
            sampleCount: snapshot.samples.count,
            firstSampleID: snapshot.samples.first?.id,
            lastSampleID: snapshot.samples.last?.id,
            resetCount: snapshot.resets.count,
            firstResetID: snapshot.resets.first?.id,
            lastResetID: snapshot.resets.last?.id
        )
    }

    private func applySelectedSeries() {
        guard let selectedSeriesID,
              let prepared = preparedBySeriesID[selectedSeriesID]
        else {
            selectedSamples = []
            chartSamples = []
            selectedResets = []
            latestReset = nil
            totalCapacityRestored = 0
            totalPaceBonus = 0
            totalTimeGained = 0
            return
        }
        selectedSamples = prepared.samples
        chartSamples = prepared.chartSamples
        selectedResets = prepared.resets
        latestReset = prepared.resets.last
        totalCapacityRestored = prepared.totalCapacityRestored
        totalPaceBonus = prepared.totalPaceBonus
        totalTimeGained = prepared.totalTimeGained
    }

    private nonisolated static func prepare(_ snapshot: LimitHistorySnapshot) -> PreparedHistory {
        let series = snapshot.series
        let samplesBySeries = Dictionary(grouping: snapshot.samples, by: \.seriesID)
        let resetsBySeries = Dictionary(grouping: snapshot.resets) {
            "\($0.provider.rawValue):\($0.accountID):\($0.windowID)"
        }
        let values = Dictionary(uniqueKeysWithValues: series.map { series in
            let samples = (samplesBySeries[series.id] ?? []).sorted { $0.observedAt < $1.observedAt }
            let resets = (resetsBySeries[series.id] ?? []).sorted { $0.detectedAt < $1.detectedAt }
            return (series.id, PreparedSeries(
                samples: samples,
                chartSamples: downsampleForChart(samples),
                resets: resets,
                totalCapacityRestored: Int(
                    (resets.reduce(0) { $0 + $1.capacityRestoredFraction } * 100).rounded()
                ),
                totalPaceBonus: Int(
                    (resets.reduce(0) { $0 + $1.paceBonusFraction } * 100).rounded()
                ),
                totalTimeGained: resets.reduce(0) { $0 + $1.secondsEarly }
            ))
        })
        return PreparedHistory(series: series, valuesBySeriesID: values)
    }

    /// Swift Charts performs layout on the main thread. Keep the visual shape while
    /// placing a hard bound on marks by retaining each bucket's endpoints and extrema.
    nonisolated static func downsampleForChart(
        _ samples: [LimitUsageSample],
        maximumCount: Int = 600
    ) -> [LimitUsageSample] {
        guard maximumCount >= 4, samples.count > maximumCount else { return samples }
        let interiorCount = samples.count - 2
        let bucketCount = max(1, (maximumCount - 2) / 4)
        let bucketSize = max(1, Int(ceil(Double(interiorCount) / Double(bucketCount))))
        var indices = [0]
        indices.reserveCapacity(maximumCount)
        var lower = 1
        while lower < samples.count - 1 {
            let upper = min(samples.count - 1, lower + bucketSize)
            let range = lower ..< upper
            let minimum = range.min { samples[$0].fraction < samples[$1].fraction } ?? lower
            let maximum = range.max { samples[$0].fraction < samples[$1].fraction } ?? lower
            for index in Set([lower, minimum, maximum, upper - 1]).sorted()
                where indices.count < maximumCount - 1
            {
                indices.append(index)
            }
            lower = upper
        }
        indices.append(samples.count - 1)
        return indices.map { samples[$0] }
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
