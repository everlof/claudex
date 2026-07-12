import Foundation

/// Screenshot support has two levels:
/// - `CLAUDEX_DEMO=1` anonymises labels on live data.
/// - `CLAUDEX_DEMO_SCENARIO=<name>` supplies a fully deterministic, credential-free fixture.
enum DemoMode {
    enum Scenario: String, CaseIterable {
        case overview
        case handoff
        case single
    }

    struct Fixture {
        let entries: [AccountEntry]
        let frontmostAccountID: String?
        let history: UsageHistory
    }

    static let scenario = ProcessInfo.processInfo.environment["CLAUDEX_DEMO_SCENARIO"]
        .flatMap(Scenario.init(rawValue:))
    static let isEnabled = ProcessInfo.processInfo.environment["CLAUDEX_DEMO"] == "1"
        || scenario != nil
    static let fixture: Fixture? = scenario.map(Self.makeFixture)

    private static let names = ["Ada", "Grace", "Alan", "Linus", "Margaret", "Dennis"]
    private static let handles = ["personal", "work", "team", "side-project", "oss", "client"]

    /// Assign a distinct placeholder per account, ordered by account id so the mapping is
    /// stable across launches and never collides.
    private static func slot(for id: String) -> Int {
        allIDs.firstIndex(of: id) ?? 0
    }

    /// The set of account ids seen this session, registered by the view as it renders.
    nonisolated(unsafe) private static var allIDs: [String] = []
    private static let lock = NSLock()

    static func register(_ id: String) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        if !allIDs.contains(id) { allIDs.append(id) }
    }

    /// A stable, collision-free placeholder display name for an account id.
    static func name(for id: String) -> String {
        register(id)
        return names[slot(for: id) % names.count]
    }

    /// A stable placeholder handle, keeping "default" as-is (it isn't personal).
    static func handle(_ original: String, id: String) -> String {
        guard isEnabled else { return original }
        // Named fixtures are authored with safe, meaningful labels already.
        if fixture != nil { return original }
        if original == "default" { return original }
        register(id)
        return handles[slot(for: id) % handles.count]
    }

    /// Anonymise a real display name if demo mode is on.
    static func displayName(_ original: String?, id: String) -> String? {
        guard isEnabled else { return original }
        if fixture != nil { return original }
        guard original != nil else { return nil }
        return name(for: id)
    }

    // MARK: Deterministic screenshot fixtures

    static func makeFixture(_ scenario: Scenario) -> Fixture {
        let now = Date()
        let entries: [AccountEntry]
        let frontmost: String?

        switch scenario {
        case .overview:
            entries = [
                entry(.claude, "work", "Ada", "Max", short: 0.34, long: 0.47, now: now,
                      extras: [("Fable", 0.18)]),
                entry(.claude, "personal", "Grace", "Max", short: 0.68, long: 0.61, now: now,
                      extras: [("Opus", 0.42)]),
                entry(.codex, "default", "Margaret", "Pro", short: 0.22, long: 0.38, now: now,
                      extras: [("GPT-5.3-Codex-Spark", 0.12)], credits: 3),
                entry(.codex, "team", "Alan", "Team", short: 0.54, long: 0.28, now: now,
                      extras: [("GPT-5.3-Codex", 0.08)], credits: 1),
            ]
            frontmost = "claude:work"

        case .handoff:
            entries = [
                entry(.claude, "work", "Ada", "Max", short: 0.96, long: 0.72, now: now,
                      extras: [("Fable", 0.88)]),
                entry(.claude, "personal", "Grace", "Max", short: 0.23, long: 0.31, now: now,
                      extras: [("Opus", 0.16)]),
            ]
            frontmost = "claude:work"

        case .single:
            entries = [
                entry(.codex, "personal", "Linus", "Pro", short: 0.41, long: 0.36, now: now,
                      extras: [("GPT-5.3-Codex", 0.14)], credits: 2),
            ]
            frontmost = "codex:personal"
        }

        return Fixture(
            entries: entries,
            frontmostAccountID: frontmost,
            history: history(now: now, scenario: scenario)
        )
    }

    private static func entry(
        _ provider: Provider,
        _ handle: String,
        _ displayName: String,
        _ plan: String,
        short: Double,
        long: Double,
        now: Date,
        extras: [(String, Double)] = [],
        credits: Int = 0
    ) -> AccountEntry {
        let ref: AccountRef
        switch provider {
        case .claude:
            ref = AccountRef(
                provider: provider,
                handle: handle,
                source: .claudeConfigDir(path: "/Users/demo/.claude-\(handle)")
            )
        case .codex:
            ref = AccountRef(
                provider: provider,
                handle: handle,
                source: .codexAuthFile(path: "/Users/demo/.codex-\(handle)/auth.json")
            )
        }

        let windows = [
            window(id: "5h", label: "5-hour", fraction: short,
                   resetsAt: now.addingTimeInterval(2.7 * 3_600), length: 5 * 3_600),
            window(id: provider == .claude ? "7d" : "week", label: "Weekly", fraction: long,
                   resetsAt: now.addingTimeInterval(3.4 * 86_400), length: 7 * 86_400),
        ]
        let extraWindows = (provider == .claude ? [] : extras).enumerated().map { index, extra in
            window(
                id: "demo-extra-\(index)",
                label: extra.0,
                fraction: extra.1,
                resetsAt: now.addingTimeInterval(4.2 * 86_400),
                length: 7 * 86_400,
                scope: extra.0
            )
        }
        let resetCredits = (0..<credits).map { index in
            ResetCredit(
                id: "demo-credit-\(handle)-\(index)",
                title: "Rate limit reset",
                grantedAt: now.addingTimeInterval(-86_400),
                expiresAt: now.addingTimeInterval(Double(index + 5) * 86_400),
                status: "available"
            )
        }
        let usage = AccountUsage(
            planLabel: provider == .claude ? nil : plan,
            displayName: provider == .claude ? nil : displayName,
            accountUUID: provider == .claude ? nil : "demo-\(provider.rawValue)-\(handle)",
            windows: windows,
            extraWindows: extraWindows,
            resetCredits: resetCredits,
            resetCreditCount: provider == .codex ? credits : nil
        )
        return AccountEntry(ref: ref, state: .loaded(usage, fetchedAt: now))
    }

    private static func window(
        id: String,
        label: String,
        fraction: Double,
        resetsAt: Date,
        length: TimeInterval,
        scope: String? = nil
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            label: label,
            fraction: fraction,
            resetsAt: resetsAt,
            windowLength: length,
            scope: scope,
            severity: .from(fraction: fraction)
        )
    }

    private static func history(now: Date, scenario: Scenario) -> UsageHistory {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let claude = [5.2, 8.1, 6.8, 12.4, 9.7, 15.1, 11.8]
        let codex = [3.1, 4.8, 7.2, 5.6, 8.9, 6.4, 10.2]
        var points: [UsagePoint] = []
        for index in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: index - 6, to: today) else { continue }
            if scenario != .single {
                points.append(UsagePoint(
                    date: date,
                    series: "claude-sonnet-4-5",
                    provider: .claude,
                    accountLabel: "work",
                    tokens: claude[index] * 1_000_000,
                    cost: claude[index] * 0.42
                ))
            }
            if scenario != .handoff {
                points.append(UsagePoint(
                    date: date,
                    series: "gpt-5.3-codex",
                    provider: .codex,
                    accountLabel: scenario == .single ? "personal" : "default",
                    tokens: codex[index] * 1_000_000,
                    cost: codex[index] * 0.31
                ))
            }
        }
        return UsageHistory(granularity: .daily, points: points, fetchedAt: now)
    }
}
