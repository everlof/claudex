import Foundation
import Testing
@testable import Claudex

@Suite struct ActivityHookInstallerTests {
    @Test func installAndRemovePreserveExistingClaudeHooks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let config = fixture.claude.appending(path: "settings.json")
        let existingCommand = "/usr/local/bin/existing-hook"
        try fixture.writeJSON([
            "theme": "dark",
            "hooks": [
                "PostToolUse": [[
                    "matcher": "Write",
                    "hooks": [["type": "command", "command": existingCommand]],
                ]],
            ],
        ], to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: config.path)

        let report = fixture.installer.install(accounts: [fixture.claudeAccount])
        #expect(report.connected == 1)
        #expect(report.issues.isEmpty)
        let installed = try fixture.readJSON(config)
        let serialized = String(data: try JSONSerialization.data(withJSONObject: installed), encoding: .utf8) ?? ""
        #expect(fixture.commands(in: installed).contains(existingCommand))
        #expect(serialized.contains("ClaudexStatusBridge"))
        #expect(serialized.contains("SessionStart"))
        #expect(serialized.contains("PermissionRequest"))
        let permissions = try #require(
            try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber
        )
        #expect(permissions.intValue & 0o777 == 0o640)

        let removal = fixture.installer.removeAll()
        #expect(removal.removed == 1)
        #expect(removal.issues.isEmpty)
        let restored = try fixture.readJSON(config)
        let restoredSerialized = String(data: try JSONSerialization.data(withJSONObject: restored), encoding: .utf8) ?? ""
        #expect(fixture.commands(in: restored).contains(existingCommand))
        #expect(!restoredSerialized.contains("ClaudexStatusBridge"))
        #expect(restored["theme"] as? String == "dark")
    }

    @Test func repeatedInstallDoesNotDuplicateHandlers() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeJSON([:], to: fixture.claude.appending(path: "settings.json"))

        _ = fixture.installer.install(accounts: [fixture.claudeAccount])
        _ = fixture.installer.install(accounts: [fixture.claudeAccount])

        let root = try fixture.readJSON(fixture.claude.appending(path: "settings.json"))
        let hooks = try #require(root["hooks"] as? [String: Any])
        let starts = try #require(hooks["SessionStart"] as? [[String: Any]])
        let commands = starts.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
            .filter { $0.contains("ClaudexStatusBridge") }
        #expect(commands.count == 1)
    }

    @Test func removalDeletesAConfigurationCreatedOnlyForClaudex() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let config = fixture.claude.appending(path: "settings.json")
        #expect(!FileManager.default.fileExists(atPath: config.path))

        _ = fixture.installer.install(accounts: [fixture.claudeAccount])
        #expect(FileManager.default.fileExists(atPath: config.path))
        _ = fixture.installer.removeAll()

        #expect(!FileManager.default.fileExists(atPath: config.path))
    }

    @Test func codexInlineHooksAreLeftUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("[[hooks.PostToolUse]]\nmatcher = \"Bash\"\n".utf8)
            .write(to: fixture.codex.appending(path: "config.toml"))

        let report = fixture.installer.install(accounts: [fixture.codexAccount])

        #expect(report.connected == 0)
        #expect(report.issues.count == 1)
        #expect(report.issues[0].contains("inline hooks"))
        #expect(!FileManager.default.fileExists(atPath: fixture.codex.appending(path: "hooks.json").path))
    }

    private final class Fixture {
        let root: URL
        let claude: URL
        let codex: URL
        let support: URL
        let helper: URL
        let installer: ActivityHookInstaller

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "claudex-activity-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
            claude = root.appending(path: ".claude", directoryHint: .isDirectory)
            codex = root.appending(path: ".codex", directoryHint: .isDirectory)
            support = root.appending(path: "support", directoryHint: .isDirectory)
            helper = support.appending(path: "bin/ClaudexStatusBridge")
            try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: codex.appending(path: "auth.json"))
            installer = ActivityHookInstaller(
                helperURL: helper,
                applicationSupportDirectory: support
            )
        }

        var claudeAccount: AccountRef {
            AccountRef(provider: .claude, handle: "default", source: .claudeConfigDir(path: claude.path))
        }

        var codexAccount: AccountRef {
            AccountRef(
                provider: .codex,
                handle: "default",
                source: .codexAuthFile(path: codex.appending(path: "auth.json").path)
            )
        }

        func writeJSON(_ value: [String: Any], to url: URL) throws {
            var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0A)
            try data.write(to: url)
        }

        func readJSON(_ url: URL) throws -> [String: Any] {
            let data = try Data(contentsOf: url)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func commands(in root: [String: Any]) -> [String] {
            guard let hooks = root["hooks"] as? [String: Any] else { return [] }
            return hooks.values.flatMap { value -> [String] in
                guard let groups = value as? [[String: Any]] else { return [] }
                return groups.flatMap { group in
                    ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
                }
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
