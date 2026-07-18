import Foundation

enum LimitSampleSource: String, Codable, Sendable {
    case claudeStatusLine = "claude_status_line"
    case claudeOAuthFile = "claude_oauth_file"
    case codexAPI = "codex_api"
}

/// One observed rate-limit value. This contains no provider credential, account UUID,
/// config path, prompt, response, or token/cost content.
struct LimitUsageSample: Codable, Sendable, Hashable, Identifiable {
    let schemaVersion: Int
    let observedAt: Date
    let provider: Provider
    let accountID: String
    let accountLabel: String
    let windowID: String
    let windowLabel: String
    let fraction: Double
    let resetsAt: Date?
    let windowLength: TimeInterval?
    let source: LimitSampleSource

    var id: String {
        "\(provider.rawValue):\(accountID):\(windowID):\(observedAt.timeIntervalSince1970)"
    }

    var seriesID: String { "\(provider.rawValue):\(accountID):\(windowID)" }

    var percent: Double { fraction * 100 }

    func elapsedFraction(at date: Date? = nil) -> Double? {
        guard let resetsAt, let windowLength, windowLength > 0 else { return nil }
        let start = resetsAt.addingTimeInterval(-windowLength)
        let elapsed = (date ?? observedAt).timeIntervalSince(start) / windowLength
        guard elapsed.isFinite else { return nil }
        return min(1, max(0, elapsed))
    }
}

/// A reset inferred from two consecutive provider observations. `detectedAt` is the
/// first post-reset observation, so the exact reset happened between it and `previousObservedAt`.
struct LimitResetEvent: Codable, Sendable, Hashable, Identifiable {
    let schemaVersion: Int
    let id: String
    let provider: Provider
    let accountID: String
    let accountLabel: String
    let windowID: String
    let windowLabel: String
    let previousObservedAt: Date
    let detectedAt: Date
    let scheduledResetAt: Date
    let newScheduledResetAt: Date
    let windowLength: TimeInterval?
    let capacityRestoredFraction: Double
    let elapsedFraction: Double
    let paceBonusFraction: Double
    let secondsEarly: TimeInterval

    var isEarly: Bool { secondsEarly >= 15 * 60 }
    var capacityRestoredPercent: Int { Int((capacityRestoredFraction * 100).rounded()) }
    var paceBonusPercent: Int { Int((paceBonusFraction * 100).rounded()) }
}

struct LimitHistorySeries: Sendable, Hashable, Identifiable {
    let id: String
    let provider: Provider
    let accountID: String
    let accountLabel: String
    let windowID: String
    let windowLabel: String
}

struct LimitHistorySnapshot: Sendable, Equatable {
    let samples: [LimitUsageSample]
    let resets: [LimitResetEvent]
    let loadedAt: Date

    static let empty = LimitHistorySnapshot(samples: [], resets: [], loadedAt: .distantPast)

    var series: [LimitHistorySeries] {
        Dictionary(grouping: samples, by: \.seriesID)
            .compactMap { id, values in
                guard let latest = values.max(by: { $0.observedAt < $1.observedAt }) else {
                    return nil
                }
                return LimitHistorySeries(
                    id: id,
                    provider: latest.provider,
                    accountID: latest.accountID,
                    accountLabel: latest.accountLabel,
                    windowID: latest.windowID,
                    windowLabel: latest.windowLabel
                )
            }
            .sorted { lhs, rhs in
                if lhs.provider != rhs.provider {
                    return lhs.provider.rawValue < rhs.provider.rawValue
                }
                if lhs.accountLabel != rhs.accountLabel {
                    return lhs.accountLabel.localizedCaseInsensitiveCompare(rhs.accountLabel) == .orderedAscending
                }
                return lhs.windowLabel.localizedCaseInsensitiveCompare(rhs.windowLabel) == .orderedAscending
            }
    }
}
