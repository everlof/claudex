@testable import Claudex
import Foundation
import Testing

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
        #expect(!CredentialStore.isClaudeScienceDataDirectory(root))
    }

    @Test func excludesClaudeScienceDefaultAndCustomDataRoots() throws {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        let science = parent.appending(path: ".claude-science", directoryHint: .isDirectory)
        let custom = parent.appending(path: ".claude-research-runtime", directoryHint: .isDirectory)
        let codeAccount = parent.appending(path: ".claude-work", directoryHint: .isDirectory)
        for directory in [science, custom, codeAccount] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: directory.appending(path: "settings.json"))
        }
        try Data("science-install".utf8).write(to: custom.appending(path: "install-id"))
        try FileManager.default.createDirectory(
            at: custom.appending(path: "runtime", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: custom.appending(path: "orgs", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        #expect(CredentialStore.isClaudeScienceDataDirectory(science))
        #expect(CredentialStore.isClaudeScienceDataDirectory(custom))
        #expect(!CredentialStore.isClaudeScienceDataDirectory(codeAccount))
        #expect(
            CredentialStore.claudeScienceDataDirs(home: parent).map(\.lastPathComponent)
                == [custom, science].map(\.lastPathComponent)
        )
        #expect(CredentialStore.discoverObserved(
            provider: .claude,
            configDir: science.path,
            existing: []
        ) == nil)
        #expect(CredentialStore.discoverObserved(
            provider: .claude,
            configDir: custom.path,
            existing: []
        ) == nil)
        #expect(CredentialStore.discoverObserved(
            provider: .claude,
            configDir: codeAccount.path,
            existing: []
        )?.handle == "claude-work")
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
