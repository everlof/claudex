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

    @Test func snapshotReadsOnlyNewestWindowAndSkipsUnchangedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for fileIndex in 0..<3 {
            let lines = try (0..<1_200).map { lineIndex in
                let index = fileIndex * 1_200 + lineIndex
                return String(decoding: try encoder.encode(snapshotEvent(index: index, now: now)), as: UTF8.self)
            }
            let file = directory.appending(path: "events-2026-07-\(20 + fileIndex).jsonl")
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        }

        let snapshot = ActivityStore.loadEventSnapshot(
            eventDirectory: directory,
            now: now,
            previousSignature: nil
        )
        let events = try #require(snapshot.events)
        #expect(events.count == 2_500)
        #expect(events.first?.id == "event-1100")
        #expect(events.last?.id == "event-3599")

        let unchanged = ActivityStore.loadEventSnapshot(
            eventDirectory: directory,
            now: now,
            previousSignature: snapshot.signature
        )
        #expect(unchanged.events == nil)
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

    private func snapshotEvent(index: Int, now: Date) -> ActivityEvent {
        ActivityEvent(
            schemaVersion: 1,
            id: "event-\(index)",
            observedAt: now.addingTimeInterval(TimeInterval(index - 4_000)),
            provider: .codex,
            accountKey: "account",
            sessionKey: "session-\(index / 10)",
            turnKey: nil,
            agentKey: nil,
            projectKey: "project",
            projectLabel: "Claudex",
            kind: .toolCompleted,
            toolName: "Read",
            toolCategory: .read,
            outcome: .succeeded,
            resources: [.init(path: "Sources/File\(index).swift", action: .read)]
        )
    }
}
