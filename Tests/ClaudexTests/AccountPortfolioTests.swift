import Foundation
import Testing
@testable import Claudex

@Suite struct AccountPortfolioTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aggregatePressureIsEqualWeightAndBestChoiceStaysPerProvider() {
        let entries = [
            entry(.claude, "work", fraction: 0.80),
            entry(.claude, "personal", fraction: 0.20),
            entry(.codex, "default", fraction: 0.50),
        ]
        let portfolio = AccountPortfolio(entries: entries)

        #expect(portfolio.averageHeadlineFraction == 0.50)
        #expect(portfolio.providerPools.count == 2)
        #expect(portfolio.providerPools.first(where: { $0.provider == .claude })?.best?.ref.handle == "personal")
        #expect(portfolio.readyCount == 3)
    }

    @Test func warningAccountOffersMeaningfullyHealthierSameProviderTarget() {
        let entries = [
            entry(.claude, "work", fraction: 0.84),
            entry(.claude, "personal", fraction: 0.31),
            entry(.codex, "default", fraction: 0.05),
        ]
        let portfolio = AccountPortfolio(entries: entries)
        let recommendation = portfolio.handoffRecommendation(for: "claude:work")

        #expect(recommendation?.target.ref.id == "claude:personal")
        #expect(recommendation?.improvement == 0.53)
    }

    @Test func handoffDoesNotCrossProvidersOrFireBeforeWarning() {
        let entries = [
            entry(.claude, "work", fraction: 0.70),
            entry(.codex, "default", fraction: 0.02),
        ]
        let portfolio = AccountPortfolio(entries: entries)

        #expect(portfolio.handoffRecommendation(for: "claude:work") == nil)
    }

    @Test func rateLimitedAccountCanHandoffWithoutUsageSnapshot() {
        let source = AccountEntry(
            ref: ref(.codex, "work"),
            state: .failed(.rateLimited(retryAfter: 120), at: now)
        )
        let portfolio = AccountPortfolio(entries: [source, entry(.codex, "personal", fraction: 0.25)])
        let recommendation = portfolio.handoffRecommendation(for: source.ref.id)

        #expect(recommendation?.target.ref.handle == "personal")
        #expect(recommendation?.improvement == nil)
        #expect(portfolio.constrainedCount == 1)
    }

    @Test func usefulResetIgnoresLowPressureWindows() {
        let early = now.addingTimeInterval(60)
        let useful = now.addingTimeInterval(300)
        let entries = [
            entry(.claude, "quiet", fraction: 0.20, resetsAt: early),
            entry(.claude, "busy", fraction: 0.80, resetsAt: useful),
        ]

        #expect(AccountPortfolio(entries: entries).nextUsefulReset(after: now) == useful)
    }

    private func entry(
        _ provider: Provider,
        _ handle: String,
        fraction: Double,
        resetsAt: Date? = nil
    ) -> AccountEntry {
        let usage = AccountUsage(
            planLabel: nil,
            displayName: nil,
            accountUUID: nil,
            windows: [
                UsageWindow(
                    id: "5h",
                    label: "5 hours",
                    fraction: fraction,
                    resetsAt: resetsAt,
                    windowLength: 18_000,
                    scope: nil,
                    severity: .from(fraction: fraction)
                )
            ],
            extraWindows: [],
            resetCredits: [],
            resetCreditCount: nil
        )
        return AccountEntry(ref: ref(provider, handle), state: .loaded(usage, fetchedAt: now))
    }

    private func ref(_ provider: Provider, _ handle: String) -> AccountRef {
        switch provider {
        case .claude:
            return AccountRef(
                provider: provider,
                handle: handle,
                source: .claudeConfigDir(path: "/tmp/.claude-\(handle)")
            )
        case .codex:
            return AccountRef(
                provider: provider,
                handle: handle,
                source: .codexAuthFile(path: "/tmp/.codex-\(handle)/auth.json")
            )
        }
    }
}
