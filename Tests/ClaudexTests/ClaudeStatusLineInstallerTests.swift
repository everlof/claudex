import Foundation
import Testing
@testable import Claudex

@Suite struct ClaudeStatusLineInstallerTests {
    @Test func installAndUninstallWithoutPriorStatusLinePreservesUnknownSettings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeSettings([
            "theme": "dark",
            "permissions": ["allow": ["Read"]],
        ])

        #expect(try fixture.installer.install(
            configDir: fixture.config.path,
            helperExecutable: fixture.helper
        ) == .installed)

        let installed = try fixture.readSettings()
        #expect(installed["theme"] as? String == "dark")
        #expect((installed["statusLine"] as? [String: Any])?["type"] as? String == "command")
        #expect(fixture.installer.inspect(
            configDir: fixture.config.path,
            helperExecutable: fixture.helper
        ).state == .installed)

        #expect(try fixture.installer.uninstall(configDir: fixture.config.path) == .uninstalled)
        let restored = try fixture.readSettings()
        #expect(restored["theme"] as? String == "dark")
        #expect(restored["statusLine"] == nil)
    }

    @Test func existingCommandIsChainedAndRestoredExactly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original: [String: Any] = [
            "type": "command",
            "command": "~/.claude/my-status.sh --color",
            "padding": 2,
            "refreshInterval": 30,
        ]
        try fixture.writeSettings(["statusLine": original, "model": "sonnet"])

        _ = try fixture.installer.install(
            configDir: fixture.config.path,
            helperExecutable: fixture.helper
        )

        let profile = fixture.installer.profileID(for: fixture.config.path)
        let installed = try fixture.readSettings()["statusLine"] as? [String: Any]
        #expect(installed?["padding"] as? Int == 2)
        #expect(installed?["refreshInterval"] as? Int == 30)
        #expect((installed?["command"] as? String)?.contains("--forward-config") == true)

        let forwardURL = fixture.support
            .appending(path: "ClaudeStatus/Forward/\(profile).json")
        let forward = try fixture.readJSON(at: forwardURL)
        #expect(forward["command"] as? String == "~/.claude/my-status.sh --color")

        try Data("not-json".utf8).write(to: forwardURL, options: .atomic)
        if case .needsRepair = fixture.installer.inspect(
            configDir: fixture.config.path,
            helperExecutable: fixture.helper
        ).state {
            // Expected.
        } else {
            Issue.record("Expected corrupt forwarding metadata to require repair")
        }
        #expect(try fixture.installer.install(
            configDir: fixture.config.path,
            helperExecutable: fixture.helper
        ) == .alreadyInstalled)
        #expect((try fixture.readJSON(at: forwardURL))["command"] as? String == "~/.claude/my-status.sh --color")

        #expect(try fixture.installer.uninstall(configDir: fixture.config.path) == .uninstalled)
        let restored = try fixture.readSettings()["statusLine"] as? [String: Any]
        #expect((restored as NSDictionary?)?.isEqual(to: original) == true)
    }

    @Test func uninstallNeverClobbersAStatusLineChangedAfterInstall() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeSettings([:])
        _ = try fixture.installer.install(
            configDir: fixture.config.path,
            helperExecutable: fixture.helper
        )

        var changed = try fixture.readSettings()
        changed["statusLine"] = ["type": "command", "command": "my-new-statusline"]
        try fixture.writeSettings(changed)

        #expect(try fixture.installer.uninstall(configDir: fixture.config.path) == .modifiedNotRestored)
        let current = try fixture.readSettings()["statusLine"] as? [String: Any]
        #expect(current?["command"] as? String == "my-new-statusline")
    }

    @Test func movedHelperCanBeRepairedWithoutLosingOriginal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeSettings([
            "statusLine": ["type": "command", "command": "original-status"],
        ])
        _ = try fixture.installer.install(
            configDir: fixture.config.path,
            helperExecutable: fixture.helper
        )

        let replacement = fixture.root.appending(path: "Other Bridge")
        try fixture.makeExecutable(at: replacement)
        if case .needsRepair = fixture.installer.inspect(
            configDir: fixture.config.path,
            helperExecutable: replacement
        ).state {
            // Expected.
        } else {
            Issue.record("Expected a moved helper to require repair")
        }

        #expect(try fixture.installer.install(
            configDir: fixture.config.path,
            helperExecutable: replacement
        ) == .repaired)
        #expect(try fixture.installer.uninstall(configDir: fixture.config.path) == .uninstalled)
        let restored = try fixture.readSettings()["statusLine"] as? [String: Any]
        #expect(restored?["command"] as? String == "original-status")
    }

    @Test func unsupportedStatusLineIsLeftUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeSettings(["statusLine": ["type": "http", "url": "https://example.test"]])

        #expect(throws: ClaudeStatusLineInstaller.InstallError.unsupportedExistingStatusLine) {
            try fixture.installer.install(
                configDir: fixture.config.path,
                helperExecutable: fixture.helper
            )
        }
        #expect((try fixture.readSettings()["statusLine"] as? [String: Any])?["type"] as? String == "http")
    }

    @Test func copiedSettingsNeverChainsAnotherClaudexBridge() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeSettings([:])
        _ = try fixture.installer.install(
            configDir: fixture.config.path,
            helperExecutable: fixture.helper
        )
        let copiedStatusLine = try #require(fixture.readSettings()["statusLine"])
        let second = fixture.root.appending(path: "Second Config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        var copiedData = try JSONSerialization.data(
            withJSONObject: ["statusLine": copiedStatusLine],
            options: [.prettyPrinted]
        )
        copiedData.append(0x0A)
        try copiedData.write(to: second.appending(path: "settings.json"))

        #expect(throws: ClaudeStatusLineInstaller.InstallError.existingClaudexBridge) {
            try fixture.installer.install(
                configDir: second.path,
                helperExecutable: fixture.helper
            )
        }
    }

    @Test func interruptedFirstInstallCanResumeIdempotently() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original: [String: Any] = ["type": "command", "command": "original-status"]
        try fixture.writeSettings(["statusLine": original])
        _ = try fixture.installer.install(
            configDir: fixture.config.path,
            helperExecutable: fixture.helper
        )

        // Simulate a termination after metadata was prepared but before settings committed.
        try fixture.writeSettings(["statusLine": original])
        if case .needsRepair = fixture.installer.inspect(
            configDir: fixture.config.path,
            helperExecutable: fixture.helper
        ).state {
            // Expected.
        } else {
            Issue.record("Expected interrupted install to be recoverable")
        }
        #expect(try fixture.installer.install(
            configDir: fixture.config.path,
            helperExecutable: fixture.helper
        ) == .repaired)
        #expect(try fixture.installer.uninstall(configDir: fixture.config.path) == .uninstalled)
    }

    @Test func forgetRemovesOwnedDataWithoutChangingUserSettings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeSettings([:])
        _ = try fixture.installer.install(
            configDir: fixture.config.path,
            helperExecutable: fixture.helper
        )
        var settings = try fixture.readSettings()
        settings["statusLine"] = ["type": "command", "command": "user-replacement"]
        try fixture.writeSettings(settings)
        try FileManager.default.createDirectory(
            at: fixture.installer.cacheURL(for: fixture.config.path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("cache".utf8).write(to: fixture.installer.cacheURL(for: fixture.config.path))
        try Data("heartbeat".utf8).write(to: fixture.installer.heartbeatURL(for: fixture.config.path))

        try fixture.installer.forgetMetadata(configDir: fixture.config.path)

        let current = try fixture.readSettings()["statusLine"] as? [String: Any]
        #expect(current?["command"] as? String == "user-replacement")
        #expect(!FileManager.default.fileExists(atPath: fixture.installer.cacheURL(for: fixture.config.path).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.installer.heartbeatURL(for: fixture.config.path).path))
        #expect(!fixture.installer.hasManagedInstallation(configDir: fixture.config.path))
    }

    private final class Fixture {
        let root: URL
        let config: URL
        let support: URL
        let helper: URL
        let installer: ClaudeStatusLineInstaller

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "claudex-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
            config = root.appending(path: "Claude Config", directoryHint: .isDirectory)
            support = root.appending(path: "Support", directoryHint: .isDirectory)
            helper = root.appending(path: "ClaudexStatusBridge", directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            installer = ClaudeStatusLineInstaller(applicationSupportDirectory: support)
            try makeExecutable(at: helper)
        }

        func makeExecutable(at url: URL) throws {
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        func writeSettings(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0A)
            try data.write(to: config.appending(path: "settings.json"), options: .atomic)
        }

        func readSettings() throws -> [String: Any] {
            try readJSON(at: config.appending(path: "settings.json"))
        }

        func readJSON(at url: URL) throws -> [String: Any] {
            let data = try Data(contentsOf: url)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
