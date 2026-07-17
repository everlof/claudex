import Foundation
import Testing
@testable import Claudex

@Suite struct UsageStorePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func retryAfterBlocksAutomaticAndManualRefreshUntilDeadline() {
        let entry = claudeEntry(state: .failed(.rateLimited(retryAfter: 3_600), at: now))
        let retryAt = now.addingTimeInterval(3_600)

        #expect(!shouldRefresh(entry, only: nil, retryAt: retryAt))
        #expect(!shouldRefresh(entry, only: entry.ref.id, retryAt: retryAt))
        #expect(UsageStore.shouldRefresh(
            entry: entry,
            onlyAccountID: nil,
            retryAt: retryAt,
            now: retryAt
        ))
    }

    @Test func passiveClaudeSnapshotBecomesStaleByAgeOrPassedReset() {
        let fresh = ClaudeStatusSnapshot(
            observedAt: now.addingTimeInterval(-60),
            claudeVersion: "2.1.207",
            fiveHour: .init(usedPercentage: 20, resetsAt: now.addingTimeInterval(3_600)),
            sevenDay: .init(usedPercentage: 30, resetsAt: now.addingTimeInterval(86_400))
        )
        #expect(!UsageStore.isClaudeSnapshotStale(fresh, now: now))

        let old = ClaudeStatusSnapshot(
            observedAt: now.addingTimeInterval(-7 * 3_600),
            claudeVersion: nil,
            fiveHour: fresh.fiveHour,
            sevenDay: fresh.sevenDay
        )
        #expect(UsageStore.isClaudeSnapshotStale(old, now: now))

        let oneResetPassed = ClaudeStatusSnapshot(
            observedAt: now.addingTimeInterval(-60),
            claudeVersion: nil,
            fiveHour: .init(usedPercentage: 90, resetsAt: now.addingTimeInterval(-1)),
            sevenDay: fresh.sevenDay
        )
        #expect(!UsageStore.isClaudeSnapshotStale(oneResetPassed, now: now))

        let allResetPassed = ClaudeStatusSnapshot(
            observedAt: now.addingTimeInterval(-60),
            claudeVersion: nil,
            fiveHour: .init(usedPercentage: 90, resetsAt: now.addingTimeInterval(-1)),
            sevenDay: .init(usedPercentage: 40, resetsAt: now.addingTimeInterval(-1))
        )
        #expect(UsageStore.isClaudeSnapshotStale(allResetPassed, now: now))
    }

    @Test func positiveHeartbeatRenewsFreshnessWithoutChangingValues() {
        let snapshot = ClaudeStatusSnapshot(
            observedAt: now.addingTimeInterval(-7 * 3_600),
            claudeVersion: "2.1.207",
            fiveHour: .init(usedPercentage: 20, resetsAt: now.addingTimeInterval(3_600)),
            sevenDay: .init(usedPercentage: 30, resetsAt: now.addingTimeInterval(86_400))
        )

        #expect(!UsageStore.isClaudeSnapshotStale(
            snapshot,
            lastLimitsSeenAt: now.addingTimeInterval(-60),
            now: now
        ))
    }

    @Test func missingLimitsHeartbeatKeepsLastKnownGoodUsageButMarksItStale() {
        let snapshot = ClaudeStatusSnapshot(
            observedAt: now.addingTimeInterval(-120),
            claudeVersion: "2.1.207",
            fiveHour: .init(usedPercentage: 37, resetsAt: now.addingTimeInterval(3_600)),
            sevenDay: .init(usedPercentage: 48, resetsAt: now.addingTimeInterval(86_400))
        )
        let heartbeat = ClaudeStatusHeartbeat(
            receivedAt: now.addingTimeInterval(-30),
            claudeVersion: "2.1.212",
            rateLimitsPresent: false,
            lastLimitsSeenAt: now.addingTimeInterval(-60)
        )

        let resolution = UsageStore.resolveClaudeSnapshot(
            snapshot,
            heartbeat: heartbeat,
            now: now
        )

        #expect(resolution.usage.windows.map(\.percent) == [37, 48])
        #expect(resolution.lastLimitsSeenAt == now.addingTimeInterval(-60))
        #expect(resolution.claudeVersion == "2.1.212")
        #expect(resolution.stale)
    }

    private func shouldRefresh(
        _ entry: AccountEntry,
        only accountID: String?,
        retryAt: Date? = nil
    ) -> Bool {
        UsageStore.shouldRefresh(
            entry: entry,
            onlyAccountID: accountID,
            retryAt: retryAt,
            now: now
        )
    }

    private func claudeEntry(state: LoadState<AccountUsage>) -> AccountEntry {
        AccountEntry(
            ref: AccountRef(
                provider: .claude,
                handle: "work",
                source: .claudeConfigDir(path: "/tmp/.claude-work")
            ),
            state: state
        )
    }
}
