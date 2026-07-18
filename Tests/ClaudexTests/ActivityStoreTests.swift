import Foundation
import Testing
@testable import Claudex

@Suite struct ActivityStoreTests {
    @Test func aggregationKeepsConversationsSeparateAndCountsFilesToolsAndPermissions() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            event(now, provider: .codex, session: "one", kind: .sessionStart),
            event(now.addingTimeInterval(1), provider: .codex, session: "one", kind: .toolCompleted, category: .read, resource: .init(path: "Sources/App.swift", action: .read)),
            event(now.addingTimeInterval(2), provider: .codex, session: "one", kind: .toolCompleted, category: .edit, resource: .init(path: "Sources/App.swift", action: .write)),
            event(now.addingTimeInterval(3), provider: .codex, session: "one", kind: .permissionRequested, category: .shell),
            event(now.addingTimeInterval(4), provider: .claude, session: "two", kind: .toolCompleted, category: .search, resource: .init(path: "README.md", action: .search)),
        ]

        let conversations = ActivityStore.conversations(from: events)

        #expect(conversations.count == 2)
        let codex = try #require(conversations.first { $0.provider == .codex })
        #expect(codex.toolCallCount == 2)
        #expect(codex.permissionCount == 1)
        #expect(codex.resourceCount == 1)
        #expect(codex.resourceStats["Sources/App.swift"]?.reads == 1)
        #expect(codex.resourceStats["Sources/App.swift"]?.writes == 1)
    }

    private func event(
        _ date: Date,
        provider: Provider,
        session: String,
        kind: ActivityEventKind,
        category: ActivityToolCategory? = nil,
        resource: ActivityResource? = nil
    ) -> ActivityEvent {
        ActivityEvent(
            schemaVersion: 1,
            id: UUID().uuidString,
            observedAt: date,
            provider: provider,
            accountKey: "account",
            sessionKey: session,
            turnKey: nil,
            agentKey: nil,
            projectKey: "project",
            projectLabel: "Claudex",
            kind: kind,
            toolName: category?.displayName,
            toolCategory: category,
            outcome: kind == .permissionRequested ? .requested : .succeeded,
            resources: resource.map { [$0] } ?? []
        )
    }
}
