import Foundation
import SwiftUI

// MARK: - Provider

/// The two tools we track. Exhaustive by construction — adding a case forces every
/// switch in the app to handle it, which is the whole point of the type-driven design.
enum Provider: String, CaseIterable, Sendable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var accentColor: Color {
        switch self {
        case .claude: return Color(hue: 0.07, saturation: 0.72, brightness: 0.95) // warm terracotta
        case .codex: return Color(hue: 0.44, saturation: 0.55, brightness: 0.78)  // teal/green
        }
    }

    var symbolName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - Account identity

/// Uniquely identifies a login. For Claude the source is a config directory + keychain
/// service; for Codex it's a CODEX_HOME. The identity is stable across refreshes so
/// SwiftUI can diff cleanly.
struct AccountRef: Hashable, Sendable, Identifiable {
    let provider: Provider
    /// Short human handle, e.g. "default", "claudedb", "claudevl".
    let handle: String
    /// Where the credential physically lives (keychain service or auth.json path).
    let source: CredentialSource

    var id: String { "\(provider.rawValue):\(handle)" }
}

/// Where a credential is read from. Kept separate from the token itself so tokens
/// never travel further than the fetch layer.
enum CredentialSource: Hashable, Sendable {
    case claudeKeychain(service: String, configDir: String)
    case codexAuthFile(path: String)
}

// MARK: - Usage windows

/// A single rate-limit window normalised across both providers.
struct UsageWindow: Sendable, Hashable, Identifiable {
    let id: String
    let label: String
    /// 0...1 fraction consumed.
    let fraction: Double
    /// When the window rolls over. Nil if unknown.
    let resetsAt: Date?
    /// Length of the window in seconds (e.g. 18000 for 5h, 604800 for weekly). Lets us
    /// place a "time elapsed" marker on the bar. Nil if unknown.
    let windowLength: TimeInterval?
    /// Optional scope, e.g. a specific model ("Fable", "Opus").
    let scope: String?
    let severity: Severity

    var percent: Int { Int((fraction * 100).rounded()) }

    /// How far through the window we are *in time*, 0...1, evaluated at `now`.
    /// This is the pace reference: compare it against `fraction` to see whether usage is
    /// ahead of or behind a steady burn rate. Nil when we can't place it.
    func timeElapsedFraction(now: Date) -> Double? {
        guard let resetsAt, let windowLength, windowLength > 0 else { return nil }
        let start = resetsAt.addingTimeInterval(-windowLength)
        let elapsed = now.timeIntervalSince(start) / windowLength
        return min(1, max(0, elapsed))
    }
}

/// Traffic-light state driven by how full a window is.
enum Severity: Int, Comparable, Sendable {
    case normal = 0
    case warning = 1
    case critical = 2

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Derive from a fill fraction using shared thresholds.
    static func from(fraction: Double) -> Severity {
        switch fraction {
        case ..<0.75: return .normal
        case ..<0.92: return .warning
        default: return .critical
        }
    }

    var color: Color {
        switch self {
        case .normal: return Color(hue: 0.38, saturation: 0.62, brightness: 0.82)
        case .warning: return Color(hue: 0.11, saturation: 0.85, brightness: 0.98)
        case .critical: return Color(hue: 0.99, saturation: 0.75, brightness: 0.97)
        }
    }
}

// MARK: - Reset credits (Codex only)

/// A Codex one-shot rate-limit reset credit with its expiry.
struct ResetCredit: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let grantedAt: Date?
    let expiresAt: Date?
    let status: String

    var isAvailable: Bool { status.lowercased() == "available" }
}

// MARK: - Per-account usage snapshot

/// Everything we know about one account after a successful fetch. Purely presentational
/// data — no tokens, no wire types.
struct AccountUsage: Sendable, Hashable {
    let planLabel: String?
    let displayName: String?
    /// Stable account identity used to match a frontmost desktop-app session (Codex.app /
    /// Claude.app) back to this account. Claude: the profile `account.uuid`; Codex: the
    /// `account_id`. Nil when the fetch couldn't determine it (e.g. profile call failed).
    let accountUUID: String?
    /// Primary windows to surface prominently (e.g. Claude 5h + 7d, Codex 5h + weekly).
    let windows: [UsageWindow]
    /// Extra per-model / additional windows shown in a secondary list.
    let extraWindows: [UsageWindow]
    /// Codex reset credits; empty for Claude.
    let resetCredits: [ResetCredit]
    /// Codex reset-credit count reported by the usage endpoint (may exceed detailed list).
    let resetCreditCount: Int?

    /// The worst severity across the primary windows — drives the account's status dot.
    var severity: Severity {
        windows.map(\.severity).max() ?? .normal
    }

    /// Headline fill fraction (max of primary windows) for compact display.
    var headlineFraction: Double {
        windows.map(\.fraction).max() ?? 0
    }

    /// Soonest-expiring available reset credit, for the "expires in" glance.
    var nextExpiringCredit: ResetCredit? {
        resetCredits
            .filter { $0.isAvailable && $0.expiresAt != nil }
            .min { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// The two windows the menu bar and reset notifications surface — 5-hour and
    /// weekly — with positional fallbacks for accounts that don't report those ids.
    var shortWindow: UsageWindow? {
        windows.first(where: { $0.id == "5h" }) ?? windows.first
    }
    var longWindow: UsageWindow? {
        windows.first(where: { $0.id == "7d" || $0.id == "week" }) ?? windows.dropFirst().first
    }
}

// MARK: - Load state

/// The lifecycle of a single account's data. Making this an enum means the UI cannot
/// render "loaded" data that doesn't exist or forget the error case — it must switch.
enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value, fetchedAt: Date)
    case failed(UsageError, at: Date)

    var value: Value? {
        if case let .loaded(v, _) = self { return v }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var error: UsageError? {
        if case let .failed(e, _) = self { return e }
        return nil
    }

    /// Timestamp of the most recent terminal outcome, for "updated 2m ago".
    var stamp: Date? {
        switch self {
        case .idle, .loading: return nil
        case let .loaded(_, at): return at
        case let .failed(_, at): return at
        }
    }
}

/// One account paired with its current load state — the unit the UI iterates over.
struct AccountEntry: Identifiable, Sendable {
    let ref: AccountRef
    var state: LoadState<AccountUsage>

    var id: String { ref.id }
}

// MARK: - Errors

/// Typed failure modes. Every fetch path funnels into one of these so the UI can
/// present a precise, human message instead of a raw string.
enum UsageError: Error, Sendable, Hashable {
    case noCredential
    /// The keychain item exists but macOS refused the read (the user clicked "Deny" on
    /// the consent prompt). Automatic refreshes skip accounts in this state so the
    /// prompt only reappears when the user explicitly retries.
    case keychainDenied
    case credentialUnreadable(String)
    case tokenExpired
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case network(String)
    case decoding(String)

    var headline: String {
        switch self {
        case .noCredential: return "Not signed in"
        case .keychainDenied: return "Keychain access denied"
        case .credentialUnreadable: return "Credential unreadable"
        case .tokenExpired: return "Session expired"
        case .rateLimited: return "Rate limited"
        case let .http(status): return "Server error \(status)"
        case .network: return "Network error"
        case .decoding: return "Unexpected response"
        }
    }

    var detail: String? {
        switch self {
        case .noCredential:
            return "No stored login was found for this account."
        case .keychainDenied:
            return "macOS blocked reading this login. Retry and choose “Always Allow”."
        case let .credentialUnreadable(m):
            return m
        case .tokenExpired:
            return "Re-run the CLI to refresh this login."
        case let .rateLimited(retryAfter):
            if let s = retryAfter, s > 0 {
                return "Too many requests — retrying in \(Int(s.rounded()))s."
            }
            return "Too many requests — will retry shortly."
        case .http(let status):
            return status == 401 ? "Login rejected — try re-authenticating." : nil
        case let .network(m):
            return m
        case let .decoding(m):
            return m
        }
    }

    /// Transient errors shouldn't blow away previously-good data.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .network: return true
        case .http(let status): return status >= 500
        default: return false
        }
    }
}
