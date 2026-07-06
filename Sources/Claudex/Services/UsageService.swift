import Foundation

/// Fetches and normalises usage for any account. Stateless and `Sendable` so it can be
/// called freely from the store's concurrent refresh.
struct UsageService: Sendable {

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: config)
    }

    /// Fetch a normalised snapshot for one account. Throws a typed `UsageError`.
    func fetch(_ ref: AccountRef) async throws(UsageError) -> AccountUsage {
        let token = try CredentialStore.readToken(for: ref)
        switch token {
        case let .claude(accessToken, planLabel):
            return try await fetchClaude(accessToken: accessToken, planLabel: planLabel)
        case let .codex(accessToken, accountId, displayName):
            return try await fetchCodex(accessToken: accessToken, accountId: accountId, displayName: displayName)
        }
    }

    // MARK: Claude

    private func fetchClaude(accessToken: String, planLabel: String?) async throws(UsageError) -> AccountUsage {
        let headers = [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claudex/1.0",
        ]
        let usage: ClaudeWire.Usage = try await getJSON(
            "https://api.anthropic.com/api/oauth/usage", headers: headers
        )
        // Profile is best-effort — a failure here shouldn't sink the whole account.
        let profile: ClaudeWire.Profile? = try? await getJSON(
            "https://api.anthropic.com/api/oauth/profile", headers: headers
        )

        var windows: [UsageWindow] = []
        if let w = usage.fiveHour {
            windows.append(window(id: "5h", label: "5-hour", fractionPercent: w.utilization,
                                  resetsAtISO: w.resetsAt, windowLength: Self.fiveHourSeconds))
        }
        if let w = usage.sevenDay {
            windows.append(window(id: "7d", label: "Weekly", fractionPercent: w.utilization,
                                  resetsAtISO: w.resetsAt, windowLength: Self.weeklySeconds))
        }

        // Extra windows: scoped/model-specific limits that aren't the two headline ones.
        var extras: [UsageWindow] = []
        for (i, limit) in (usage.limits ?? []).enumerated() {
            let kind = limit.kind ?? ""
            // Skip the ones already represented as headline windows.
            if kind == "session" || kind == "weekly_all" { continue }
            let scopeName = limit.scope?.model?.displayName
            let label = scopeName ?? prettyKind(kind)
            // Scoped limits reset on the weekly cadence; others we leave unmarked.
            let len: TimeInterval? = kind.contains("weekly") ? Self.weeklySeconds : nil
            extras.append(
                window(
                    id: "x\(i)-\(kind)",
                    label: label,
                    fractionPercent: limit.percent,
                    resetsAtISO: limit.resetsAt,
                    windowLength: len,
                    scope: scopeName
                )
            )
        }

        let plan = profile?.account.flatMap(claudePlan(from:)) ?? planLabel
        let name = profile?.account?.fullName

        return AccountUsage(
            planLabel: plan,
            displayName: name,
            windows: windows,
            extraWindows: extras,
            resetCredits: [],
            resetCreditCount: nil
        )
    }

    private func claudePlan(from account: ClaudeWire.Profile.Account) -> String? {
        if account.hasClaudeMax == true { return "Max" }
        if account.hasClaudePro == true { return "Pro" }
        return nil
    }

    private func prettyKind(_ kind: String) -> String {
        kind
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: Codex

    private func fetchCodex(accessToken: String, accountId: String, displayName: String?) async throws(UsageError) -> AccountUsage {
        let headers = [
            "Authorization": "Bearer \(accessToken)",
            "ChatGPT-Account-ID": accountId,
            "originator": "Codex Desktop",
            "User-Agent": "claudex/1.0",
        ]
        let usage: CodexWire.Usage = try await getJSON(
            "https://chatgpt.com/backend-api/wham/usage", headers: headers
        )
        let resets: CodexWire.ResetCredits? = try? await getJSON(
            "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", headers: headers
        )

        var windows: [UsageWindow] = []
        if let w = usage.rateLimit?.primaryWindow {
            windows.append(codexWindow(id: "5h", label: "5-hour", w))
        }
        if let w = usage.rateLimit?.secondaryWindow {
            windows.append(codexWindow(id: "week", label: "Weekly", w))
        }

        var extras: [UsageWindow] = []
        for (i, add) in (usage.additionalRateLimits ?? []).enumerated() {
            let name = add.limitName ?? "Additional \(i + 1)"
            if let w = add.rateLimit?.primaryWindow {
                extras.append(codexWindow(id: "a\(i)-5h", label: "\(name) · 5h", w, scope: name))
            }
            if let w = add.rateLimit?.secondaryWindow {
                extras.append(codexWindow(id: "a\(i)-wk", label: "\(name) · wk", w, scope: name))
            }
        }

        let credits: [ResetCredit] = (resets?.credits ?? []).map {
            ResetCredit(
                id: $0.id ?? UUID().uuidString,
                title: $0.title ?? "Reset credit",
                grantedAt: Self.parseISO($0.grantedAt),
                expiresAt: Self.parseISO($0.expiresAt),
                status: $0.status ?? "unknown"
            )
        }

        let count = resets?.availableCount ?? usage.rateLimitResetCredits?.availableCount

        return AccountUsage(
            planLabel: usage.planType.map { $0.capitalized },
            displayName: displayName,
            windows: windows,
            extraWindows: extras,
            resetCredits: credits,
            resetCreditCount: count
        )
    }

    private func codexWindow(
        id: String, label: String, _ w: CodexWire.Usage.Window, scope: String? = nil
    ) -> UsageWindow {
        let fraction = max(0, min(1, (w.usedPercent ?? 0) / 100))
        let resetsAt: Date? = w.resetAt.map { Date(timeIntervalSince1970: $0) }
        return UsageWindow(
            id: id, label: label, fraction: fraction,
            resetsAt: resetsAt, windowLength: w.limitWindowSeconds, scope: scope,
            severity: .from(fraction: fraction)
        )
    }

    // MARK: Shared helpers

    /// Claude's usage API reports `resets_at` but not the window length; its windows are
    /// fixed, so we supply the length so the bar can show a time-elapsed marker.
    private static let fiveHourSeconds: TimeInterval = 5 * 3600
    private static let weeklySeconds: TimeInterval = 7 * 86400

    private func window(
        id: String, label: String, fractionPercent: Double?, resetsAtISO: String?,
        windowLength: TimeInterval? = nil, scope: String? = nil
    ) -> UsageWindow {
        let fraction = max(0, min(1, (fractionPercent ?? 0) / 100))
        return UsageWindow(
            id: id, label: label, fraction: fraction,
            resetsAt: Self.parseISO(resetsAtISO), windowLength: windowLength, scope: scope,
            severity: .from(fraction: fraction)
        )
    }

    /// GET a URL and decode JSON, translating every failure into a typed `UsageError`.
    private func getJSON<T: Decodable>(_ urlString: String, headers: [String: String]) async throws(UsageError) -> T {
        guard let url = URL(string: urlString) else {
            throw .network("Bad URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw .network(urlError.localizedDescription)
        } catch {
            throw .network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw .network("No HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw .tokenExpired
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw .rateLimited(retryAfter: retryAfter)
        default:
            throw .http(status: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .decoding("Could not read \(T.self).")
        }
    }

    // MARK: Date parsing

    /// Parse an ISO-8601 timestamp, tolerating fractional seconds (both providers emit them).
    static func parseISO(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return isoWithFraction.date(from: value) ?? isoPlain.date(from: value)
    }

    // These formatters are configured once and thereafter only read via `date(from:)`,
    // which is safe to call concurrently. `nonisolated(unsafe)` documents that we've
    // reasoned about the (absence of) shared mutation.
    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
