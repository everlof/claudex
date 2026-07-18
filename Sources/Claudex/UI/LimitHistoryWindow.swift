import AppKit
import Charts
import SwiftUI

/// A single reusable window for locally observed rate-limit history.
@MainActor
enum LimitHistoryWindow {
    private static var window: NSWindow?
    private static var viewStore: LimitHistoryViewStore?

    static func show(history: LimitHistoryStore) {
        if let window {
            viewStore?.reload()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let store = LimitHistoryViewStore(history: history)
        let host = NSHostingController(rootView: LimitHistoryWindowContent(store: store))
        host.view.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.title = "Limit History"
        window.contentMinSize = NSSize(width: 720, height: 500)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        viewStore = store
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        writeCaptureIfRequested(view: host.view)
    }

    private static func writeCaptureIfRequested(view: NSView) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CLAUDEX_LIMIT_HISTORY_CAPTURE_PATH"], !path.isEmpty else { return }
        let delay = environment["CLAUDEX_LIMIT_HISTORY_CAPTURE_DELAY_MS"].flatMap(Int.init) ?? 1200
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            view.layoutSubtreeIfNeeded()
            defer {
                if environment["CLAUDEX_LIMIT_HISTORY_CAPTURE_EXIT"] == "1" {
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

private struct LimitHistoryWindowContent: View {
    @Bindable var store: LimitHistoryViewStore
    @State private var hoveredAt: Date?
    private let refresh = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            Group {
                if store.isLoading, store.snapshot.samples.isEmpty {
                    ProgressView("Loading local observations…")
                } else if let error = store.errorMessage, store.snapshot.samples.isEmpty {
                    ContentUnavailableView(
                        "Limit history unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if store.selectedSamples.isEmpty {
                    emptyState
                } else {
                    historyContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(windowBackground)
        .task { store.reload() }
        .onReceive(refresh) { _ in store.reload() }
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
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Limit history")
                    .font(.title3.weight(.semibold))
                Text("Actual usage against linear pace, with early resets measured as gained capacity")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !store.series.isEmpty {
                Picker("Account and window", selection: Binding(
                    get: { store.selectedSeriesID ?? store.series[0].id },
                    set: { store.selectedSeriesID = $0 }
                )) {
                    ForEach(store.series) { series in
                        Text("\(series.provider.displayName) · \(series.accountLabel) — \(series.windowLabel)")
                            .tag(series.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            Picker("Range", selection: $store.range) {
                ForEach(LimitHistoryRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            Button { store.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload limit history")

            Menu {
                Button("Delete local limit history", role: .destructive) {
                    store.deleteHistory()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                summaryCard(
                    title: "Resets observed",
                    value: "\(store.selectedResets.count)",
                    detail: "in this range",
                    color: selectedColor
                )
                summaryCard(
                    title: "Capacity restored",
                    value: store.selectedResets.isEmpty ? "—" : "+\(store.totalCapacityRestored) pts",
                    detail: "usage at rollover",
                    color: Severity.normal.color
                )
                summaryCard(
                    title: "Above linear pace",
                    value: store.selectedResets.isEmpty ? "—" : "+\(store.totalPaceBonus) pts",
                    detail: "the profitable share",
                    color: Provider.codex.accentColor
                )
                summaryCard(
                    title: "Early time gained",
                    value: store.selectedResets.isEmpty ? "—" : formatDuration(store.totalTimeGained),
                    detail: "before scheduled reset",
                    color: Provider.claude.accentColor
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Usage through time")
                            .font(.headline)
                        Text("Dashed is elapsed time. Green fill is above pace; pale bands are time gained.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    chartLegend
                }
                chart
                    .frame(minHeight: 270)
            }
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08))
            )

            if let event = store.latestReset {
                latestResetRow(event)
            } else {
                Label(
                    "No early reset has been observed for this window yet. "
                        + "Detection begins with the first saved sample.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var chart: some View {
        Chart {
            ForEach(store.selectedResets.filter(\.isEarly)) { event in
                RectangleMark(
                    xStart: .value("Reset detected", event.detectedAt),
                    xEnd: .value("Original reset", event.scheduledResetAt),
                    yStart: .value("Minimum", 0),
                    yEnd: .value("Maximum", 100)
                )
                .foregroundStyle(Severity.normal.color.opacity(0.055))
            }

            ForEach(store.selectedSamples) { sample in
                if let pace = sample.elapsedFraction(), sample.percent > pace * 100 {
                    AreaMark(
                        x: .value("Observed", sample.observedAt),
                        yStart: .value("Linear pace", pace * 100),
                        yEnd: .value("Usage", sample.percent)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Severity.normal.color.opacity(0.28), Severity.normal.color.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }

            ForEach(store.selectedSamples) { sample in
                if let pace = sample.elapsedFraction() {
                    LineMark(
                        x: .value("Observed", sample.observedAt),
                        y: .value("Linear pace", pace * 100),
                        series: .value("Series", "Linear pace")
                    )
                    .foregroundStyle(Color.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.3, dash: [5, 4]))
                }
                LineMark(
                    x: .value("Observed", sample.observedAt),
                    y: .value("Usage", sample.percent),
                    series: .value("Series", "Actual usage")
                )
                .foregroundStyle(selectedColor)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }

            ForEach(store.selectedResets) { event in
                RuleMark(x: .value("Early reset", event.detectedAt))
                    .foregroundStyle(Severity.normal.color.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.3, dash: [3, 3]))
                PointMark(
                    x: .value("Early reset", event.detectedAt),
                    y: .value("Restored", event.capacityRestoredFraction * 100)
                )
                .foregroundStyle(Severity.normal.color)
                .symbolSize(60)
                if event.isEarly {
                    RuleMark(x: .value("Original reset", event.scheduledResetAt))
                        .foregroundStyle(Provider.claude.accentColor.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.1, dash: [2, 4]))
                }
            }

            if let hoveredAt, let sample = nearestSample(to: hoveredAt) {
                RuleMark(x: .value("Selection", sample.observedAt))
                    .foregroundStyle(Color.primary.opacity(0.18))
                    .annotation(
                        position: .top,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        hoverCard(sample)
                    }
            }
        }
        .chartYScale(domain: 0 ... 100)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text("\(percent)%").font(.system(size: 10))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 10))
            }
        }
        .chartXSelection(value: $hoveredAt)
    }

    private var chartLegend: some View {
        HStack(spacing: 14) {
            legendItem("Actual", color: selectedColor, dashed: false)
            legendItem("Linear pace", color: .secondary, dashed: true)
            legendItem("Ahead", color: Severity.normal.color, dashed: false)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ text: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
                .frame(width: 16, height: 3)
            Text(text)
        }
    }

    private func summaryCard(title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07))
        )
    }

    private func latestResetRow(_ event: LimitResetEvent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "gift.fill")
                .font(.system(size: 18))
                .foregroundStyle(Severity.normal.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.isEarly ? "Latest gain" : "Latest reset")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(latestResetDescription(event))
                    .font(.callout.weight(.medium))
            }
            Spacer()
            Text(event.detectedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func hoverCard(_ sample: LimitUsageSample) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sample.observedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Usage \(Int(sample.percent.rounded()))%")
                .font(.caption.weight(.semibold).monospacedDigit())
            if let pace = sample.elapsedFraction() {
                Text("Linear pace \(Int((pace * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func nearestSample(to date: Date) -> LimitUsageSample? {
        store.selectedSamples.min {
            abs($0.observedAt.timeIntervalSince(date)) < abs($1.observedAt.timeIntervalSince(date))
        }
    }

    private var selectedColor: Color {
        store.selectedSeries?.provider.accentColor ?? Provider.codex.accentColor
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "—" }
        let hours = Int(interval / 3600)
        let days = hours / 24
        let remainingHours = hours % 24
        if days > 0, remainingHours > 0 { return "\(days)d \(remainingHours)h" }
        if days > 0 { return "\(days)d" }
        if hours > 0 { return "\(hours)h" }
        return "\(max(1, Int(interval / 60)))m"
    }

    private func latestResetDescription(_ event: LimitResetEvent) -> String {
        let gain = event.paceBonusPercent > 0
            ? " · \(event.paceBonusPercent) points above linear pace"
            : ""
        if event.isEarly {
            return "Reset \(formatDuration(event.secondsEarly)) early at \(event.capacityRestoredPercent)% used\(gain)"
        }
        return "Reset observed at \(event.capacityRestoredPercent)% used\(gain)"
    }
}

private extension LimitHistoryWindowContent {
    var emptyState: some View {
        ContentUnavailableView {
            Label("History starts now", systemImage: "chart.line.uptrend.xyaxis")
        } description: {
            Text(
                "Claudex will save future Claude and Codex limit observations locally. "
                    + "Once a reset is seen, this view can measure restored capacity and how early it arrived."
            )
        }
    }

    var windowBackground: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            LinearGradient(
                colors: [
                    Provider.claude.accentColor.opacity(0.05),
                    .clear,
                    Provider.codex.accentColor.opacity(0.05),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}
