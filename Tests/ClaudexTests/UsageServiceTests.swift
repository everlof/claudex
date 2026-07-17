import Foundation
import Testing
@testable import Claudex

@Suite struct UsageServiceTests {
    @Test func userAgentUsesSanitizedBundleVersion() {
        #expect(UsageService.userAgent(bundleVersion: "1.1.0") == "claudex/1.1.0")
        #expect(UsageService.userAgent(bundleVersion: "1.1.0\r\nInjected: true") == "claudex/development")
        #expect(UsageService.userAgent(bundleVersion: nil) == "claudex/development")
    }

    @Test func claudeOAuthRequestMatchesFileFirstCodexBarHeaders() {
        let request = UsageService.claudeOAuthRequest(accessToken: "secret-test-token")

        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-test-token")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1.0")
    }

    @Test func normalizesClaudeOAuthHeadlineWindows() throws {
        let response = ClaudeOAuthUsageResponse(
            fiveHour: .init(utilization: 37.5, resetsAt: "2030-01-01T05:00:00Z"),
            sevenDay: .init(utilization: 62, resetsAt: "2030-01-07T00:00:00.000Z")
        )

        let usage = try UsageService.normalizeClaudeOAuthUsage(
            response,
            planLabel: "Max",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(usage.planLabel == "Max")
        #expect(usage.windows.map(\.id) == ["5h", "7d"])
        #expect(usage.windows.map(\.percent) == [38, 62])
        #expect(usage.windows.map(\.windowLength) == [18_000, 604_800])
    }

    @Test func codexWindowLabelsUseReportedDuration() {
        #expect(UsageService.codexWindowLabel(
            windowLength: 5 * 60 * 60,
            fallback: "Primary limit"
        ) == "5-hour")
        #expect(UsageService.codexWindowLabel(
            windowLength: 7 * 24 * 60 * 60,
            fallback: "Primary limit"
        ) == "7-day")
        #expect(UsageService.codexCompactWindowDuration(
            windowLength: 7 * 24 * 60 * 60
        ) == "7d")
    }

    @Test func codexWindowLabelsFallBackWithoutUsableDuration() {
        #expect(UsageService.codexWindowLabel(
            windowLength: nil,
            fallback: "Primary limit"
        ) == "Primary limit")
        #expect(UsageService.codexWindowLabel(
            windowLength: .infinity,
            fallback: "Secondary limit"
        ) == "Secondary limit")
        #expect(UsageService.codexCompactWindowDuration(windowLength: 0) == nil)
    }

    @Test func retryAfterParsesDeltaSeconds() {
        #expect(UsageService.retryAfterSeconds("3600") == 3_600)
    }

    @Test func retryAfterParsesHTTPDate() {
        let now = Date(timeIntervalSince1970: 784_108_177)
        let value = "Sun, 06 Nov 1994 08:49:37 GMT"

        #expect(UsageService.retryAfterSeconds(value, now: now) == 3_600)
    }

    @Test func retryAfterParsesRFC850WithRollingYearWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2074, month: 12, day: 31, hour: 23
        )))
        let value = "Tuesday, 01-Jan-75 00:00:00 GMT"

        #expect(UsageService.retryAfterSeconds(value, now: now) == 3_600)
    }

    @Test func retryAfterParsesAsctimeDate() {
        let now = Date(timeIntervalSince1970: 784_108_177)
        let value = "Sun Nov 6 08:49:37 1994"

        #expect(UsageService.retryAfterSeconds(value, now: now) == 3_600)
    }

    @Test func retryAfterRejectsInvalidValues() {
        #expect(UsageService.retryAfterSeconds("later") == nil)
        #expect(UsageService.retryAfterSeconds("inf") == nil)
        #expect(UsageService.retryAfterSeconds("-1") == nil)
        #expect(UsageService.retryAfterSeconds(String(repeating: "9", count: 400)) == nil)
    }

    @Test func retryAfterCapsExtremeButFiniteDelays() {
        #expect(UsageService.retryAfterSeconds("999999") == TimeInterval(7 * 24 * 60 * 60))
    }
}
