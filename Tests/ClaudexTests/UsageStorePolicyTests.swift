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

        let resetPassed = ClaudeStatusSnapshot(
            observedAt: now.addingTimeInterval(-60),
            claudeVersion: nil,
            fiveHour: .init(usedPercentage: 90, resetsAt: now.addingTimeInterval(-1)),
            sevenDay: fresh.sevenDay
        )
        #expect(UsageStore.isClaudeSnapshotStale(resetPassed, now: now))
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
