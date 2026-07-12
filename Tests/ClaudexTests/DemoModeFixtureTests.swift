import Testing
@testable import Claudex

@Suite struct DemoModeFixtureTests {
    @Test func overviewProvidesMultipleProvidersAndHistory() {
        let fixture = DemoMode.makeFixture(.overview)
        let providers = Set(fixture.entries.map(\.ref.provider))

        #expect(fixture.entries.count == 4)
        #expect(providers == Set([.claude, .codex]))
        #expect(!fixture.history.points.isEmpty)
        #expect(fixture.frontmostAccountID == "claude:work")
        #expect(AccountPortfolio(entries: fixture.entries).handoffRecommendation(for: "claude:personal") == nil)
    }

    @Test func handoffScenarioActuallyOffersAHandoff() {
        let fixture = DemoMode.makeFixture(.handoff)
        let portfolio = AccountPortfolio(entries: fixture.entries)

        #expect(portfolio.handoffRecommendation(for: "claude:work")?.target.ref.id == "claude:personal")
    }

    @Test func singleScenarioHasExactlyOneAccount() {
        let fixture = DemoMode.makeFixture(.single)

        #expect(fixture.entries.count == 1)
        #expect(fixture.entries[0].ref.provider == .codex)
        #expect(Set(fixture.history.points.map(\.provider)) == Set([.codex]))
    }
}
