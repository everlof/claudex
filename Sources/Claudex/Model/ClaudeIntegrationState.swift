import Foundation

/// Connection state for Claude's passive local feed. This is intentionally separate from
/// `LoadState`: disconnected/waiting/repair are configuration states, not HTTP failures.
enum ClaudeIntegrationState: Sendable, Equatable {
    case disconnected
    case waiting(lastReceivedAt: Date?, claudeVersion: String?, rateLimitsPresent: Bool?)
    case connected(
        valuesChangedAt: Date,
        lastLimitsSeenAt: Date,
        claudeVersion: String?,
        stale: Bool
    )
    case needsRepair(message: String, observedAt: Date?)
    case modified(message: String, observedAt: Date?)
    case failed(message: String)

    var isConfigured: Bool {
        switch self {
        case .disconnected, .failed: return false
        case .waiting, .connected, .needsRepair, .modified: return true
        }
    }

    var observedAt: Date? {
        switch self {
        case let .connected(valuesChangedAt, _, _, _): return valuesChangedAt
        case let .needsRepair(_, observedAt), let .modified(_, observedAt): return observedAt
        case .disconnected, .waiting, .failed: return nil
        }
    }

    var isStale: Bool {
        if case let .connected(_, _, _, stale) = self { return stale }
        return false
    }
}
