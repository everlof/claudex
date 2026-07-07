import Foundation
import SwiftUI

// MARK: - History domain

/// How the usage-history chart buckets time. Raw values are the ccusage subcommand names,
/// so the service can pass them straight through.
enum HistoryGranularity: String, CaseIterable, Identifiable, Sendable {
    case daily
    case weekly
    case monthly

    var id: String { rawValue }

    /// The ccusage subcommand for this bucket.
    var ccusageCommand: String { rawValue }

    var displayName: String {
        switch self {
        case .daily: return "Day"
        case .weekly: return "Week"
        case .monthly: return "Month"
        }
    }

    /// How far back to fetch by default, in days, for a readable span at this bucket size.
    var defaultLookbackDays: Int {
        switch self {
        case .daily: return 30
        case .weekly: return 12 * 7
        case .monthly: return 365
        }
    }
}

/// What the chart's y-axis measures. Tokens are reported for every provider; cost is a
/// ccusage price estimate (notional for flat-rate Max/Pro plans, and unpriced for some
/// Codex usage), so it's clearly an estimate.
enum HistoryMetric: String, CaseIterable, Identifiable, Sendable {
    case tokens
    case cost

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tokens: return "Tokens"
        case .cost: return "Cost"
        }
    }
}

/// How the stacked series are split.
enum HistoryBreakdown: String, CaseIterable, Identifiable, Sendable {
    case provider
    case account
    case model

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .provider: return "By provider"
        case .account: return "By account"
        case .model: return "By model"
        }
    }
}

/// One measured value in one time bucket, tagged with every dimension the chart can split
/// by — provider, account, and model. A single fetch produces these; the view aggregates
/// per the selected breakdown without refetching.
struct UsagePoint: Identifiable, Sendable, Hashable {
    /// The bucket's start date (midnight for daily; week/month start otherwise).
    let date: Date
    /// The model name (the finest-grain series); also the label for the by-model breakdown.
    let series: String
    /// The provider the point rolls up to — drives colour grouping and provider totals.
    let provider: Provider
    /// The login handle this point came from (for the by-account breakdown), e.g. "default".
    let accountLabel: String?
    let tokens: Double
    let cost: Double

    var id: String { "\(date.timeIntervalSince1970)-\(accountLabel ?? "")-\(series)" }

    func value(_ metric: HistoryMetric) -> Double {
        switch metric {
        case .tokens: return tokens
        case .cost: return cost
        }
    }
}

/// A full history snapshot the chart renders from. Immutable; the store swaps a new one
/// in when the granularity changes or a refresh completes.
struct UsageHistory: Sendable {
    let granularity: HistoryGranularity
    /// Every (bucket × series) datum, for every breakdown — the view filters/aggregates
    /// per the selected breakdown so switching breakdowns needs no refetch.
    let points: [UsagePoint]
    /// When this snapshot was produced.
    let fetchedAt: Date

    static let empty = UsageHistory(granularity: .daily, points: [], fetchedAt: .distantPast)
}
