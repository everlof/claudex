import Foundation
import Testing
@testable import Claudex

@Suite @MainActor struct HandoffLauncherTests {
    @Test func claudeCommandPreservesProjectAndRoutesConfig() {
        let account = AccountRef(
            provider: .claude,
            handle: "work",
            source: .claudeConfigDir(path: "/Users/test/Claude Work")
        )

        let command = HandoffLauncher.command(
            for: account,
            workingDirectory: "/Users/test/David's Project"
        )

        #expect(command == "cd -- '/Users/test/David'\"'\"'s Project' && env CLAUDE_CONFIG_DIR='/Users/test/Claude Work' claude")
    }

    @Test func codexCommandUsesAuthFileParentAsHome() {
        let account = AccountRef(
            provider: .codex,
            handle: "personal",
            source: .codexAuthFile(path: "/Users/test/.codex-personal/auth.json")
        )

        let command = HandoffLauncher.command(for: account, workingDirectory: "/tmp/repo")

        #expect(command == "cd -- '/tmp/repo' && env CODEX_HOME='/Users/test/.codex-personal' codex")
    }

    @Test func defaultClaudeAccountLeavesConfigEnvironmentUnset() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let account = AccountRef(
            provider: .claude,
            handle: "default",
            source: .claudeConfigDir(
                path: URL(fileURLWithPath: home).appending(path: ".claude").path
            )
        )

        let command = HandoffLauncher.command(for: account, workingDirectory: home)

        #expect(command == "cd -- '\(home)' && env -u CLAUDE_CONFIG_DIR claude")
    }
}
