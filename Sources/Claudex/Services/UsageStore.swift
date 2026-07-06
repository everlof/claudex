import Foundation
import Observation

/// The single source of truth for the UI. Owns the list of accounts and their load
/// states, drives the 5-minute auto-refresh, and exposes a throttled manual refresh.
@MainActor
@Observable
final class UsageStore {
    /// One entry per discovered account, order stable (Claude accounts first).
    private(set) var entries: [AccountEntry] = []
    /// When the last full refresh completed.
    private(set) var lastRefresh: Date?
    /// True while a refresh cycle is in flight (drives the spinner in the header).
    private(set) var isRefreshing = false

    /// The account currently running in the frontmost window, or nil when none is
    /// detected (menu bar then shows the global peak). Matches an `AccountRef.id`.
    private(set) var frontmostAccountID: String?

    private let service = UsageService()
    private let detector = FrontmostDetector()
    private var timerTask: Task<Void, Never>?
    private var frontmostTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private let refreshInterval: Duration = .seconds(300) // 5 minutes
    private let frontmostInterval: Duration = .seconds(2)  // frontmost poll cadence

    /// The minimum spacing between actual network refreshes. Opening the popover more
    /// often than this reuses the cached data instead of hammering the APIs (which is
    /// what tripped Claude's 429 rate limit during development).
    private let minRefreshSpacing: TimeInterval = 60

    init() {
        rediscover()
    }

    /// Re-scan the machine for accounts, preserving any already-loaded state for
    /// accounts that still exist.
    func rediscover() {
        let refs = CredentialStore.discoverAll()
        let previous = Dictionary(uniqueKeysWithValues: entries.map { ($0.ref.id, $0.state) })
        entries = refs.map { ref in
            AccountEntry(ref: ref, state: previous[ref.id] ?? .idle)
        }
    }

    /// Start the background refresh loop. Fires immediately, then every 5 minutes.
    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshAll(force: true)
                try? await Task.sleep(for: self.refreshInterval)
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        frontmostTask?.cancel()
        frontmostTask = nil
    }

    /// Start polling which account is frontmost. The detector shells out to AppleScript
    /// and `ps`, so it runs off the main actor; results are hopped back on.
    func startFrontmostTracking() {
        guard frontmostTask == nil else { return }
        frontmostTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let refs = self.entries.map(\.ref)
                let detector = self.detector
                // Run the (blocking) detection off the main actor.
                let id = await Task.detached(priority: .utility) {
                    detector.detect(known: refs)
                }.value
                if self.frontmostAccountID != id {
                    self.frontmostAccountID = id
                }
                try? await Task.sleep(for: self.frontmostInterval)
            }
        }
    }

    /// Refresh every account concurrently. `force` bypasses the throttle (used by the
    /// timer and the explicit refresh button); non-forced calls are skipped if the last
    /// refresh was very recent.
    func refreshAll(force: Bool) async {
        rediscover()
        guard !entries.isEmpty else {
            isRefreshing = false
            return
        }

        // Throttle: reuse cached data if we refreshed very recently and this isn't forced.
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < minRefreshSpacing {
            return
        }
        // Coalesce concurrent refreshes into the one already running.
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Only show the spinner for accounts that have nothing to show yet; accounts
        // with a prior value keep displaying it until fresh data (or a real error) lands.
        for i in entries.indices {
            if entries[i].state.value == nil, entries[i].state.error == nil {
                entries[i].state = .loading
            }
        }

        let refs = entries.map(\.ref)
        // Stagger requests to the same host so three Claude accounts don't burst the
        // usage endpoint simultaneously.
        let staggered = refs.enumerated().map { (index, ref) in (ref, Double(index) * 0.25) }

        await withTaskGroup(of: (String, Result<AccountUsage, UsageError>).self) { group in
            for (ref, delay) in staggered {
                let service = self.service
                let hasPrior = entries.first(where: { $0.ref.id == ref.id })?.state.value != nil
                group.addTask {
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    // On a cold start (no prior value) a transient error like a 429 would
                    // otherwise show a hard error card, so retry a bounded number of times
                    // honouring Retry-After. When we already have data, don't retry — the
                    // stale value is shown and the next cycle refreshes.
                    let maxAttempts = hasPrior ? 1 : 3
                    var lastError: UsageError = .network("unknown")
                    for attempt in 0..<maxAttempts {
                        do {
                            return (ref.id, .success(try await service.fetch(ref)))
                        } catch let error as UsageError {
                            lastError = error
                            guard error.isTransient, attempt < maxAttempts - 1,
                                  let backoff = Self.retryDelay(for: error, attempt: attempt)
                            else { break }
                            try? await Task.sleep(for: .seconds(backoff))
                        } catch {
                            lastError = .network(error.localizedDescription)
                            break
                        }
                    }
                    return (ref.id, .failure(lastError))
                }
            }
            for await (id, result) in group {
                guard let idx = entries.firstIndex(where: { $0.ref.id == id }) else { continue }
                let now = Date()
                switch result {
                case let .success(usage):
                    entries[idx].state = .loaded(usage, fetchedAt: now)
                case let .failure(error):
                    // A transient error must not erase good data we already have — keep
                    // showing the last snapshot rather than flashing an error card.
                    if error.isTransient, let prev = entries[idx].state.value {
                        entries[idx].state = .loaded(prev, fetchedAt: entries[idx].state.stamp ?? now)
                    } else {
                        entries[idx].state = .failed(error, at: now)
                    }
                }
            }
        }

        lastRefresh = Date()
    }

    /// Backoff before a retry, or `nil` to give up (let the next 5-min tick heal it).
    /// Honours a 429's Retry-After; if that wait exceeds our cap we don't retry now, so
    /// a cold start never blocks the cycle for long.
    nonisolated private static func retryDelay(for error: UsageError, attempt: Int) -> Double? {
        let cap = 8.0
        if case let .rateLimited(retryAfter) = error, let s = retryAfter {
            return s <= cap ? max(1, s) : nil
        }
        return min(cap, pow(2, Double(attempt))) // 1s, 2s, 4s…
    }

    /// User-triggered refresh (menu button) — always forces.
    func refreshNow() {
        inFlight?.cancel()
        inFlight = Task { await refreshAll(force: true) }
    }

    /// Called when the popover opens. Refreshes only if data is stale, so rapidly
    /// reopening the panel doesn't spam the APIs.
    func refreshIfStale() {
        Task { await refreshAll(force: false) }
    }

    // MARK: Derived summaries for the menubar glyph & header

    /// The worst severity across all loaded accounts — drives the menubar icon tint.
    var overallSeverity: Severity {
        entries.compactMap { $0.state.value?.severity }.max() ?? .normal
    }

    /// Highest fill fraction across all accounts, for a compact headline number.
    var peakFraction: Double {
        entries.compactMap { $0.state.value?.headlineFraction }.max() ?? 0
    }

    /// True only when an account is showing a *hard* error with no data to fall back on.
    var hasAnyError: Bool {
        entries.contains { $0.state.value == nil && $0.state.error != nil }
    }

    var loadedCount: Int {
        entries.filter { $0.state.value != nil }.count
    }

    /// The frontmost account entry, if one is detected and loaded.
    var frontmostEntry: AccountEntry? {
        guard let id = frontmostAccountID else { return nil }
        return entries.first { $0.ref.id == id && $0.state.value != nil }
    }

    /// What the menu bar should display: either the frontmost account's two windows, or
    /// the global-peak fallback.
    var menuBar: MenuBarSummary {
        if let entry = frontmostEntry, let usage = entry.state.value {
            let short = usage.windows.first(where: { $0.id == "5h" }) ?? usage.windows.first
            let long = usage.windows.first(where: { $0.id == "7d" || $0.id == "week" })
                ?? usage.windows.dropFirst().first
            return MenuBarSummary(
                provider: entry.ref.provider,
                primaryPercent: short?.percent,
                secondaryPercent: long?.percent,
                severity: usage.severity,
                isFrontmost: true
            )
        }
        // Fallback: global peak across all accounts, no per-account tint.
        guard loadedCount > 0 else {
            return MenuBarSummary(provider: nil, primaryPercent: nil, secondaryPercent: nil,
                                  severity: .normal, isFrontmost: false)
        }
        return MenuBarSummary(
            provider: nil,
            primaryPercent: Int((peakFraction * 100).rounded()),
            secondaryPercent: nil,
            severity: overallSeverity,
            isFrontmost: false
        )
    }
}

/// A value type describing exactly what the menu-bar button should render, so the
/// AppKit status item stays a thin projection of typed store state.
struct MenuBarSummary: Equatable, Sendable {
    let provider: Provider?      // tints the glyph when a frontmost account is known
    let primaryPercent: Int?     // 5-hour % (frontmost) or global peak % (fallback)
    let secondaryPercent: Int?   // weekly % — only shown for a frontmost account
    let severity: Severity
    let isFrontmost: Bool
}
