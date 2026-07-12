import Foundation

/// Reads historical token/cost usage by shelling out to `ccusage`, one run per account so
/// every datum carries its account, provider, and model. Claude and Codex use slightly
/// different ccusage schemas; both are normalised into `UsagePoint`s here.
///
/// Why per-account runs: the aggregated `ccusage daily` auto-discovers *all* homes and
/// folds Codex into every run, so it can't attribute usage to one login. The
/// provider-specific subcommands (`ccusage claude …` / `ccusage codex …`) stay isolated
/// and honour `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, giving us a clean account dimension.
struct UsageHistoryService: Sendable {

    enum HistoryError: Error, Sendable {
        case ccusageNotFound
        case launchFailed(String)
    }

    /// Fetch a full history snapshot at `granularity` across every discovered account.
    /// Runs the per-account ccusage invocations concurrently.
    func fetch(granularity: HistoryGranularity, accounts: [AccountRef]) async throws -> UsageHistory {
        guard let ccusage = Self.locateCcusage() else { throw HistoryError.ccusageNotFound }

        let since = Self.sinceStamp(daysBack: granularity.defaultLookbackDays)
        let cmd = granularity.ccusageCommand

        // One task per account; failures degrade to an empty slice rather than sinking all.
        let points = try await withThrowingTaskGroup(of: [UsagePoint].self) { group in
            for account in accounts {
                group.addTask {
                    (try? await Self.runOne(
                        ccusage: ccusage, account: account, command: cmd,
                        granularity: granularity, since: since
                    )) ?? []
                }
            }
            var all: [UsagePoint] = []
            for try await slice in group { all.append(contentsOf: slice) }
            return all
        }

        return UsageHistory(granularity: granularity, points: points, fetchedAt: Date())
    }

    // MARK: One account run

    private static func runOne(
        ccusage: CcusageInvocation, account: AccountRef, command: String,
        granularity: HistoryGranularity, since: String
    ) async throws -> [UsagePoint] {
        // Subcommand + isolating env differ by provider.
        // Subcommand + isolating env differ by provider. Codex has no `weekly` subcommand,
        // so for weekly we fetch its `daily` rows and re-bucket into weeks in Swift.
        var env = ProcessInfo.processInfo.environment
        let sub: String
        let fetchCommand: String
        let rebucketToWeekly: Bool
        switch account.source {
        case let .claudeConfigDir(configDir):
            sub = "claude"
            fetchCommand = command
            rebucketToWeekly = false
            env["CLAUDE_CONFIG_DIR"] = configDir
            env.removeValue(forKey: "CODEX_HOME")
        case let .codexAuthFile(path):
            sub = "codex"
            rebucketToWeekly = command == "weekly"
            fetchCommand = rebucketToWeekly ? "daily" : command
            // auth.json lives inside the codex home; its parent is CODEX_HOME.
            env["CODEX_HOME"] = (path as NSString).deletingLastPathComponent
            env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        }

        let args = ccusage.baseArgs + [sub, fetchCommand, "--json", "--since", since]
        let data = try await Self.launch(executable: ccusage.executable, args: args, env: env)
        let fetchGranularity: HistoryGranularity = rebucketToWeekly ? .daily : granularity
        let rows = try Self.decodeRows(data, command: fetchCommand)
        let points = rows.flatMap { $0.toPoint(account: account, granularity: fetchGranularity) ?? [] }
        return rebucketToWeekly ? Self.rebucketToWeekStart(points) : points
    }

    /// Collapse daily points into week buckets, summing tokens and cost per (week, series).
    /// Used for Codex weekly, which ccusage can't group itself. Weeks start on **Sunday** to
    /// line up with Claude's own weekly buckets (ccusage reports those Sunday-based).
    private static func rebucketToWeekStart(_ points: [UsagePoint]) -> [UsagePoint] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        cal.firstWeekday = 1 // Sunday, to match ccusage's Claude weekly buckets
        var acc: [String: UsagePoint] = [:]
        for p in points {
            let weekStart = cal.dateInterval(of: .weekOfYear, for: p.date)?.start ?? p.date
            let key = "\(weekStart.timeIntervalSince1970)-\(p.accountLabel ?? "")-\(p.series)"
            if let prev = acc[key] {
                acc[key] = UsagePoint(date: weekStart, series: p.series, provider: p.provider,
                                      accountLabel: p.accountLabel,
                                      tokens: prev.tokens + p.tokens, cost: prev.cost + p.cost)
            } else {
                acc[key] = UsagePoint(date: weekStart, series: p.series, provider: p.provider,
                                      accountLabel: p.accountLabel,
                                      tokens: p.tokens, cost: p.cost)
            }
        }
        return Array(acc.values)
    }

    // MARK: JSON decoding — one flexible row for both providers' schemas

    /// A ccusage row from any subcommand/granularity. All date and cost fields are optional
    /// because Claude uses `date`/`week`/`month` + `totalCost`, Codex uses those + `costUSD`.
    fileprivate struct Row: Decodable {
        let date: String?
        let week: String?
        let month: String?
        let totalTokens: Double?
        let totalCost: Double?
        let costUSD: Double?
        let modelBreakdowns: [ModelBreakdown]?
        let models: [String: ModelStat]?

        struct ModelBreakdown: Decodable {
            let modelName: String
            let cost: Double?
            let inputTokens: Double?
            let outputTokens: Double?
            let cacheReadTokens: Double?
            let cacheCreationTokens: Double?
        }
        struct ModelStat: Decodable {
            let totalTokens: Double?
        }

        /// The bucket key string for this granularity, whichever field carries it.
        func periodString(_ g: HistoryGranularity) -> String? {
            switch g {
            case .daily: return date
            case .weekly: return week ?? date
            case .monthly: return month ?? date
            }
        }
    }

    private struct Envelope: Decodable {
        let daily: [Row]?
        let weekly: [Row]?
        let monthly: [Row]?
        func rows(_ command: String) -> [Row] {
            switch command {
            case "weekly": return weekly ?? daily ?? []
            case "monthly": return monthly ?? daily ?? []
            default: return daily ?? []
            }
        }
    }

    private static func decodeRows(_ data: Data, command: String) throws -> [Row] {
        try JSONDecoder().decode(Envelope.self, from: data).rows(command)
    }

    // MARK: Launch

    private static func launch(executable: String, args: [String], env: [String: String]) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.environment = env
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            // Read fully before waiting so a large payload can't deadlock the pipe.
            process.terminationHandler = { _ in }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: HistoryError.launchFailed(error.localizedDescription))
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            cont.resume(returning: data)
        }
    }

    // MARK: ccusage discovery

    /// How to invoke an already-installed ccusage binary. Claudex deliberately never falls
    /// back to npx: opening a chart must not download or execute an unreviewed package.
    struct CcusageInvocation: Sendable {
        let executable: String
        let baseArgs: [String]
    }

    private static func locateCcusage() -> CcusageInvocation? {
        let fm = FileManager.default
        // GUI apps get a minimal PATH; probe the common install locations directly.
        let home = fm.homeDirectoryForCurrentUser.path
        let binCandidates = [
            "\(home)/.bun/bin/ccusage",
            "\(home)/.npm-global/bin/ccusage",
            "/opt/homebrew/bin/ccusage",
            "/usr/local/bin/ccusage",
        ]
        for path in binCandidates where fm.isExecutableFile(atPath: path) {
            return CcusageInvocation(executable: path, baseArgs: [])
        }
        return nil
    }

    // MARK: Dates

    /// `YYYYMMDD` stamp `daysBack` days before today, in the local calendar.
    private static func sinceStamp(daysBack: Int) -> String {
        let day = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: day)
    }

    /// Parse a ccusage period string (`2026-07-05`, week start `2026-06-14`, or month
    /// `2026-06`) into a Date at the bucket's start.
    static func parsePeriod(_ s: String, granularity: HistoryGranularity) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = (granularity == .monthly && s.count == 7) ? "yyyy-MM" : "yyyy-MM-dd"
        return f.date(from: s)
    }
}

// MARK: - Row → points

private extension UsageHistoryService.Row {
    /// Turn one ccusage row into per-model points (each tagged with account/provider), so a
    /// single fetch feeds the provider, account, and model breakdowns without refetching.
    func toPoint(account: AccountRef, granularity: HistoryGranularity) -> [UsagePoint]? {
        guard let periodStr = periodString(granularity),
              let date = UsageHistoryService.parsePeriod(periodStr, granularity: granularity)
        else { return nil }

        // Claude rows carry a costed `modelBreakdowns`; Codex rows carry a `models` dict
        // (tokens only) plus a row-level `costUSD`.
        if let breakdowns = modelBreakdowns, !breakdowns.isEmpty {
            return breakdowns.map { mb in
                let tokens = (mb.inputTokens ?? 0) + (mb.outputTokens ?? 0)
                    + (mb.cacheReadTokens ?? 0) + (mb.cacheCreationTokens ?? 0)
                return UsagePoint(
                    date: date,
                    series: mb.modelName,
                    provider: Self.provider(forModel: mb.modelName, fallback: account.provider),
                    accountLabel: account.handle,
                    tokens: tokens,
                    cost: mb.cost ?? 0
                )
            }
        }

        if let models, !models.isEmpty {
            // Codex: split tokens by model, and apportion the row's cost by token share.
            let rowTokens = models.values.reduce(0) { $0 + ($1.totalTokens ?? 0) }
            let rowCost = costUSD ?? totalCost ?? 0
            return models.map { name, stat in
                let t = stat.totalTokens ?? 0
                let share = rowTokens > 0 ? t / rowTokens : 0
                return UsagePoint(
                    date: date, series: name,
                    provider: Self.provider(forModel: name, fallback: account.provider),
                    accountLabel: account.handle,
                    tokens: t, cost: rowCost * share
                )
            }
        }

        // No per-model detail — emit a single provider-level point.
        let tokens = totalTokens ?? 0
        let cost = totalCost ?? costUSD ?? 0
        guard tokens > 0 || cost > 0 else { return nil }
        return [UsagePoint(date: date, series: account.provider.displayName,
                           provider: account.provider, accountLabel: account.handle,
                           tokens: tokens, cost: cost)]
    }

    /// Classify a model name to a provider. Claude models are `claude-*`; Codex/OpenAI are
    /// `gpt-*` / `*codex*` / `o*`. Falls back to the account's own provider.
    static func provider(forModel model: String, fallback: Provider) -> Provider {
        let m = model.lowercased()
        if m.hasPrefix("claude") || m.contains("opus") || m.contains("sonnet")
            || m.contains("haiku") || m.contains("fable") { return .claude }
        if m.hasPrefix("gpt") || m.contains("codex") || m.hasPrefix("o1") || m.hasPrefix("o3") {
            return .codex
        }
        return fallback
    }
}
