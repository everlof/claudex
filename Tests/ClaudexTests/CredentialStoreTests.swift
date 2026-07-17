import Foundation
import Testing
@testable import Claudex

@Suite struct CredentialStoreTests {
    @Test func discoversValidatedClaudeDirectoryOutsideNamingConvention() throws {
        let root = try makeDirectory(named: "work-account")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appending(path: "settings.json"))

        let ref = try #require(CredentialStore.discoverObserved(
            provider: .claude,
            configDir: root.path,
            existing: []
        ))

        #expect(ref.handle == "work-account")
        #expect(ref.source == .claudeConfigDir(path: root.path))
    }

    @Test func discoversValidatedCodexDirectoryAndDisambiguatesHandle() throws {
        let root = try makeDirectory(named: "work-account")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appending(path: "auth.json"))
        let collision = AccountRef(
            provider: .codex,
            handle: "work-account",
            source: .codexAuthFile(path: "/different/auth.json")
        )

        let ref = try #require(CredentialStore.discoverObserved(
            provider: .codex,
            configDir: root.path,
            existing: [collision]
        ))

        #expect(ref.handle.hasPrefix("work-account-"))
        #expect(ref.id != collision.id)
        #expect(ref.source == .codexAuthFile(path: root.appending(path: "auth.json").path))
    }

    @Test func rejectsDirectoryWithoutProviderState() throws {
        let root = try makeDirectory(named: "empty-account")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(CredentialStore.discoverObserved(
            provider: .claude,
            configDir: root.path,
            existing: []
        ) == nil)
        #expect(CredentialStore.discoverObserved(
            provider: .codex,
            configDir: root.path,
            existing: []
        ) == nil)
    }

    private func makeDirectory(named name: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let directory = parent.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
