import AppKit
import Foundation

/// Opens a fresh CLI session under a selected account. The project directory is preserved
/// when frontmost process inspection found one; conversation state is intentionally not
/// claimed to transfer across account-specific config directories.
@MainActor
enum HandoffLauncher {
    /// Returns nil on success or a short user-facing error on failure.
    static func launch(
        account: AccountRef,
        workingDirectory: String?,
        preferredTerminal: SupportedTerminal?
    ) -> String? {
        let command = command(for: account, workingDirectory: workingDirectory)
        let terminal = preferredTerminal ?? .appleTerminal
        let script = appleScript(command: command, terminal: terminal)

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return "Could not prepare the terminal handoff."
        }
        appleScript.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String
            return message ?? "Terminal did not accept the handoff."
        }
        return nil
    }

    /// Pure command construction, kept internal so quoting and account routing are testable.
    static func command(for account: AccountRef, workingDirectory: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directory = workingDirectory ?? home
        let launch: String
        switch account.source {
        case let .claudeConfigDir(configDir):
            // The default account must use Claude Code's unset/default route; only
            // alternate homes get an explicit environment override.
            let defaultConfig = URL(fileURLWithPath: home)
                .appending(path: ".claude")
                .standardizedFileURL.path
            if URL(fileURLWithPath: configDir).standardizedFileURL.path == defaultConfig {
                // Explicitly clear an inherited override; a bare `claude` would still
                // route to the wrong account when the parent terminal exports it.
                launch = "env -u CLAUDE_CONFIG_DIR claude"
            } else {
                launch = "env CLAUDE_CONFIG_DIR=\(shellQuote(configDir)) claude"
            }
        case let .codexAuthFile(path):
            let codexHome = (path as NSString).deletingLastPathComponent
            launch = "env CODEX_HOME=\(shellQuote(codexHome)) codex"
        }
        return "cd -- \(shellQuote(directory)) && \(launch)"
    }

    private static func appleScript(command: String, terminal: SupportedTerminal) -> String {
        let command = appleScriptQuote(command)
        switch terminal {
        case .appleTerminal:
            return """
            tell application "Terminal"
                activate
                do script "\(command)"
            end tell
            """
        case .iterm2:
            return """
            tell application "iTerm2"
                activate
                create window with default profile
                tell current session of current window to write text "\(command)"
            end tell
            """
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
