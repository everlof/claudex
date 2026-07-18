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

    /// Fetch a normalized Codex snapshot.
    func fetch(_ ref: AccountRef) async throws(UsageError) -> AccountUsage {
        let token = try CredentialStore.readCodexToken(for: ref)
        return try await fetchCodex(
            accessToken: token.accessToken,
            accountId: token.accountId,
            displayName: token.displayName
        )
    }

    /// Optional Claude fallback modeled after CodexBar's file-first OAuth path. The
    /// credential reader never accesses Keychain and never refreshes or rewrites tokens.
    func fetchClaudeFromCredentialsFile(_ ref: AccountRef) async throws(UsageError) -> AccountUsage {
        let credentials = try ClaudeOAuthFileCredentials.load(for: ref)
        return try await fetchClaude(credentials: credentials)
    }

    /// Fetches with an already-authorized credential. The value is consumed inside this
    /// method and never enters the UI model, diagnostics, history, or persistent storage.
    func fetchClaude(
        credentials: ClaudeOAuthFileCredentials.Value
    ) async throws(UsageError) -> AccountUsage {
        let request = Self.claudeOAuthRequest(accessToken: credentials.accessToken)
        let response: ClaudeOAuthUsageResponse = try await getJSON(request)
        return try Self.normalizeClaudeOAuthUsage(
            response,
            planLabel: credentials.planLabel,
            now: Date()
        )
    }

    static func claudeOAuthRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func normalizeClaudeOAuthUsage(
        _ response: ClaudeOAuthUsageResponse,
        planLabel: String?,
        now: Date
    ) throws(UsageError) -> AccountUsage {
        var windows: [UsageWindow] = []
        if let window = response.fiveHour {
            windows.append(claudeOAuthWindow(
                id: "5h",
                label: "5-hour",
                length: 5 * 60 * 60,
                wire: window,
                now: now
            ))
        }
        if let window = response.sevenDay {
            windows.append(claudeOAuthWindow(
                id: "7d",
                label: "7-day",
                length: 7 * 24 * 60 * 60,
                wire: window,
                now: now
            ))
        }
        guard !windows.isEmpty else {
            throw .decoding("Claude returned no supported usage windows.")
        }
        return AccountUsage(
            planLabel: planLabel,
            displayName: nil,
            accountUUID: nil,
            windows: windows,
            extraWindows: [],
            resetCredits: [],
            resetCreditCount: nil
        )
    }

    private static func claudeOAuthWindow(
        id: String,
        label: String,
        length: TimeInterval,
        wire: ClaudeOAuthUsageWindow,
        now: Date
    ) -> UsageWindow {
        let fraction = max(0, min(1, (wire.utilization ?? 0) / 100))
        let resetsAt = parseISO(wire.resetsAt)
        return UsageWindow(
            id: id,
            label: label,
            fraction: fraction,
            resetsAt: resetsAt,
            windowLength: length,
            scope: nil,
            severity: .from(fraction: fraction),
            isExpired: resetsAt.map { $0 <= now } ?? false
        )
    }

    // MARK: Codex

    private func fetchCodex(accessToken: String, accountId: String, displayName: String?) async throws(UsageError) -> AccountUsage {
        let headers = [
            "Authorization": "Bearer \(accessToken)",
            "ChatGPT-Account-ID": accountId,
            "originator": "Codex Desktop",
            "User-Agent": Self.userAgent(
                bundleVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String
            ),
        ]
        let usage: CodexWire.Usage = try await getJSON(
            "https://chatgpt.com/backend-api/wham/usage", headers: headers
        )
        let resets: CodexWire.ResetCredits? = try? await getJSON(
            "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", headers: headers
        )

        var windows: [UsageWindow] = []
        if let w = usage.rateLimit?.primaryWindow {
            windows.append(codexWindow(
                id: "primary",
                label: Self.codexWindowLabel(
                    windowLength: w.limitWindowSeconds,
                    fallback: "Primary limit"
                ),
                w
            ))
        }
        if let w = usage.rateLimit?.secondaryWindow {
            windows.append(codexWindow(
                id: "secondary",
                label: Self.codexWindowLabel(
                    windowLength: w.limitWindowSeconds,
                    fallback: "Secondary limit"
                ),
                w
            ))
        }

        var extras: [UsageWindow] = []
        for (i, add) in (usage.additionalRateLimits ?? []).enumerated() {
            let name = add.limitName ?? "Additional \(i + 1)"
            if let w = add.rateLimit?.primaryWindow {
                let duration = Self.codexCompactWindowDuration(
                    windowLength: w.limitWindowSeconds
                )
                let label = duration.map { "\(name) · \($0)" } ?? name
                extras.append(codexWindow(
                    id: "a\(i)-primary", label: label, w, scope: name
                ))
            }
            if let w = add.rateLimit?.secondaryWindow {
                let duration = Self.codexCompactWindowDuration(
                    windowLength: w.limitWindowSeconds
                )
                let label = duration.map { "\(name) · \($0)" } ?? name
                extras.append(codexWindow(
                    id: "a\(i)-secondary", label: label, w, scope: name
                ))
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
            accountUUID: accountId,
            windows: windows,
            extraWindows: extras,
            resetCredits: credits,
            resetCreditCount: count
        )
    }

    static func userAgent(bundleVersion: String?) -> String {
        guard let bundleVersion,
              !bundleVersion.isEmpty,
              bundleVersion.count <= 32,
              bundleVersion.unicodeScalars.allSatisfy({
                  $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-".unicodeScalars.contains($0))
              })
        else { return "claudex/development" }
        return "claudex/\(bundleVersion)"
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

    /// Codex's `primary_window` and `secondary_window` are positions, not fixed
    /// timeframes. During limit experiments a primary window can be seven days rather
    /// than five hours, so derive user-facing names from the duration in the payload.
    static func codexWindowLabel(
        windowLength: TimeInterval?, fallback: String
    ) -> String {
        guard let components = codexDurationComponents(windowLength: windowLength) else {
            return fallback
        }
        return "\(components.value)-\(components.longUnit)"
    }

    static func codexCompactWindowDuration(
        windowLength: TimeInterval?
    ) -> String? {
        guard let components = codexDurationComponents(windowLength: windowLength) else {
            return nil
        }
        return "\(components.value)\(components.shortUnit)"
    }

    private static func codexDurationComponents(
        windowLength: TimeInterval?
    ) -> (value: Int, longUnit: String, shortUnit: String)? {
        guard let windowLength,
              windowLength.isFinite,
              windowLength > 0,
              windowLength <= Double(Int.max)
        else { return nil }

        let seconds = Int(windowLength.rounded())
        let units = [
            (seconds: 86_400, long: "day", short: "d"),
            (seconds: 3_600, long: "hour", short: "h"),
            (seconds: 60, long: "minute", short: "m"),
        ]
        for unit in units where seconds.isMultiple(of: unit.seconds) {
            return (seconds / unit.seconds, unit.long, unit.short)
        }
        return (seconds, "second", "s")
    }

    // MARK: Shared helpers

    /// GET a URL and decode JSON, translating every failure into a typed `UsageError`.
    private func getJSON<T: Decodable>(_ urlString: String, headers: [String: String]) async throws(UsageError) -> T {
        guard let url = URL(string: urlString) else {
            throw .network("Bad URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        return try await getJSON(request)
    }

    private func getJSON<T: Decodable>(_ request: URLRequest) async throws(UsageError) -> T {

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
            let retryAfter = Self.retryAfterSeconds(
                http.value(forHTTPHeaderField: "Retry-After")
            )
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

    /// Retry-After can be either delta-seconds or an HTTP date. Keep the parser pure so
    /// server backoff behavior is deterministic and testable.
    static func retryAfterSeconds(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           trimmed.allSatisfy(\.isNumber),
           let seconds = TimeInterval(trimmed), seconds.isFinite {
            return min(seconds, maxRetryAfter)
        }

        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz", // RFC 1123
            "EEEE',' dd-MMM-yy HH':'mm':'ss zzz", // RFC 850
            "EEE MMM d HH':'mm':'ss yyyy",         // ANSI C asctime
        ]
        for (index, format) in formats.enumerated() {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if index == 1 {
                // RFC 850 has a two-digit year. HTTP uses a rolling window: values that
                // would be more than 50 years ahead belong to the previous century.
                formatter.twoDigitStartDate = Calendar(identifier: .gregorian)
                    .date(byAdding: .year, value: -49, to: now)
            }
            if let date = formatter.date(from: trimmed) {
                let seconds = date.timeIntervalSince(now)
                guard seconds.isFinite else { return nil }
                return min(max(0, seconds), maxRetryAfter)
            }
        }
        return nil
    }

    /// Protect both scheduling and UI duration formatting from absurd/malicious values.
    private static let maxRetryAfter: TimeInterval = 7 * 24 * 60 * 60

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

struct ClaudeOAuthUsageResponse: Decodable, Sendable {
    let fiveHour: ClaudeOAuthUsageWindow?
    let sevenDay: ClaudeOAuthUsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

struct ClaudeOAuthUsageWindow: Decodable, Sendable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
