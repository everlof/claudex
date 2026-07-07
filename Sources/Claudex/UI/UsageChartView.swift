import SwiftUI
import Charts

/// The usage-history chart. Two modes share one store:
/// - `.compact` (panel top): aggregated bars, all models, a simple span toggle, a breakout
///   button — minimal chrome.
/// - `.full` (breakout window): every control (Day/Week/Month, Tokens/Cost, breakdown menu).
/// Colours come from the validated `ChartPalette`.
struct UsageChartView: View {
    enum Mode { case compact, full }

    @Bindable var store: HistoryStore
    var mode: Mode = .full
    /// Called when the compact chart's breakout button is tapped.
    var onBreakout: (() -> Void)? = nil
    @State private var hoveredDate: Date?

    private var isCompact: Bool { mode == .compact }

    private var series: [UsageHistory.Series] {
        isCompact
            ? store.compactSeries(metric: store.metric)
            : store.history.series(breakdown: store.breakdown, metric: store.metric)
    }
    private var data: [UsageHistory.Datum] {
        isCompact
            ? store.compactData(metric: store.metric)
            : store.history.data(breakdown: store.breakdown, metric: store.metric)
    }
    private var colors: [String: Color] {
        ChartPalette.assign(series: series.map { ($0.name, $0.provider) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
            if isCompact { compactHeader } else { heroAndControls }
            if store.ccusageMissing {
                missingHint
            } else if data.isEmpty {
                emptyOrLoading
            } else {
                chart
                legend
            }
        }
        .padding(isCompact ? 0 : 16)
        .task { await store.load(force: false) }
    }

    // MARK: Compact header (panel top) — hero total, span toggle, breakout

    private var compactHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Usage · \(spanLabel)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(heroValue)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Picker("", selection: $store.compactSpan) {
                Text("24h").tag(HistoryStore.CompactSpan.day)
                Text("Week").tag(HistoryStore.CompactSpan.week)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            Button {
                onBreakout?()
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open usage history")
        }
    }

    private var spanLabel: String {
        store.compactSpan == .day ? "last 24h" : "last 7 days"
    }

    // MARK: Hero + controls

    private var heroAndControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Total usage")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(heroValue)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                }
                Spacer()
                metricToggle
            }

            HStack(spacing: 8) {
                granularityControl
                Spacer()
                breakdownMenu
            }
        }
    }

    private var heroValue: String {
        let total = isCompact
            ? store.compactTotal(metric: store.metric)
            : store.history.grandTotal(metric: store.metric)
        switch store.metric {
        case .cost: return Self.formatCost(total)
        case .tokens: return Self.formatTokens(total)
        }
    }

    private var metricToggle: some View {
        Picker("", selection: $store.metric) {
            ForEach(HistoryMetric.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .labelsHidden()
    }

    private var granularityControl: some View {
        Picker("", selection: $store.granularity) {
            ForEach(HistoryGranularity.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .labelsHidden()
    }

    private var breakdownMenu: some View {
        Menu {
            Picker("Breakdown", selection: $store.breakdown) {
                ForEach(HistoryBreakdown.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(store.breakdown.displayName)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            ForEach(data) { d in
                BarMark(
                    x: .value("Date", d.date, unit: barUnit),
                    y: .value(store.metric.displayName, d.value),
                    width: .automatic
                )
                .foregroundStyle(colors[d.series] ?? .gray)
                .foregroundStyle(by: .value("Series", d.series))
                .cornerRadius(2)
            }

            if let hoveredDate, let total = hoverTotal(hoveredDate) {
                RuleMark(x: .value("Date", hoveredDate, unit: barUnit))
                    .foregroundStyle(Color.primary.opacity(0.18))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        hoverTooltip(date: hoveredDate, total: total)
                    }
            }
        }
        .chartForegroundStyleScale(
            domain: series.map(\.name),
            range: series.map { colors[$0.name] ?? .gray }
        )
        .chartLegend(.hidden) // custom legend below, so we can order + direct-label it
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(axisLabel(d)).font(.system(size: 9))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: xAxisFormat).font(.system(size: 9))
            }
        }
        .chartXSelection(value: $hoveredDate)
        .frame(height: isCompact ? 92 : 150)
    }

    private var barUnit: Calendar.Component {
        switch store.granularity {
        case .daily: return .day
        case .weekly: return .weekOfYear
        case .monthly: return .month
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch store.granularity {
        case .daily, .weekly: return .dateTime.month(.abbreviated).day()
        case .monthly: return .dateTime.month(.abbreviated)
        }
    }

    private func hoverTotal(_ date: Date) -> Double? {
        let cal = Calendar.current
        let matching = data.filter { cal.isDate($0.date, equalTo: date, toGranularity: barUnit) }
        guard !matching.isEmpty else { return nil }
        return matching.reduce(0) { $0 + $1.value }
    }

    private func hoverTooltip(date: Date, total: Double) -> some View {
        let cal = Calendar.current
        let rows = data
            .filter { cal.isDate($0.date, equalTo: date, toGranularity: barUnit) && $0.value > 0 }
            .sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 3) {
            Text(date, format: xAxisFormat)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(rows) { r in
                HStack(spacing: 5) {
                    Circle().fill(colors[r.series] ?? .gray).frame(width: 6, height: 6)
                    Text(r.series).font(.system(size: 10))
                    Spacer(minLength: 8)
                    Text(formatValue(r.value)).font(.system(size: 10, weight: .medium).monospacedDigit())
                }
            }
            if rows.count > 1 {
                Divider()
                HStack {
                    Text("Total").font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(formatValue(total)).font(.system(size: 10, weight: .bold).monospacedDigit())
                }
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .frame(maxWidth: 200)
    }

    // MARK: Legend (identity is never colour-alone)

    private var legend: some View {
        FlowLayout(spacing: isCompact ? 8 : 10, lineSpacing: 4) {
            ForEach(series) { s in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colors[s.name] ?? .gray)
                        .frame(width: isCompact ? 7 : 9, height: isCompact ? 7 : 9)
                    Text(legendLabel(s.name))
                        .font(.system(size: isCompact ? 9 : 10))
                        .foregroundStyle(.secondary)
                    // Full view direct-labels each series' total (the required secondary
                    // encoding for the floor-band palette); compact omits it to save space.
                    if !isCompact {
                        Text(formatValue(s.total))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.primary.opacity(0.8))
                    }
                }
            }
        }
    }

    /// Trim noisy model ids for the legend ("claude-opus-4-8" → "opus-4-8").
    private func legendLabel(_ name: String) -> String {
        name.replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-20251001", with: "")
    }

    // MARK: States

    private var emptyOrLoading: some View {
        HStack {
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text("No usage in this period.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(height: 150)
    }

    private var missingHint: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("Install ccusage for usage history")
                .font(.system(size: 11, weight: .medium))
            Text("npm i -g ccusage")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
    }

    // MARK: Formatting

    private func formatValue(_ v: Double) -> String {
        store.metric == .cost ? Self.formatCost(v) : Self.formatTokens(v)
    }
    private func axisLabel(_ v: Double) -> String {
        store.metric == .cost ? Self.formatCost(v) : Self.formatTokens(v)
    }

    static func formatCost(_ v: Double) -> String {
        if v >= 1000 { return String(format: "$%.1fk", v / 1000) }
        return String(format: "$%.0f", v)
    }
    static func formatTokens(_ v: Double) -> String {
        switch v {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1e9)
        case 1_000_000...: return String(format: "%.0fM", v / 1e6)
        case 1_000...: return String(format: "%.0fK", v / 1e3)
        default: return String(format: "%.0f", v)
        }
    }
}
