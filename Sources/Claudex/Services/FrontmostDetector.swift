import Foundation
import AppKit

/// Figures out which account (if any) is running in the frontmost window, so the menu
/// bar can show *that* account's usage instead of the global peak.
///
/// Two detection paths, both local and read-only:
///
///   Terminal sessions (`claude`/`codex` run in a shell):
///     1. `NSWorkspace` → the frontmost application.
///     2. If it's a supported terminal, AppleScript → the tty of its frontmost tab.
///     3. Find the `claude`/`codex` process attached to that tty.
///     4. Read `CLAUDE_CONFIG_DIR` / `CODEX_HOME` from that process's environment.
///     5. Map that config dir to one of the known accounts.
///
///   Desktop apps (Codex.app / Claude.app — no tty to inspect):
///     1. Recognise the app by bundle id.
///     2. Read the app's *active* account identity from its on-disk state
///        (Codex: `~/.codex/auth.json` account_id; Claude: the app's
///        `config.json` lastKnownAccountUuid).
///     3. Match that identity to a loaded account via `accountsByUUID`.
///
/// Returns `nil` whenever any link can't be resolved — the caller falls back to the
/// global peak.
struct FrontmostDetector: Sendable {

    /// Resolve the frontmost account id (matching `AccountRef.id`), or nil.
    /// - `known`: maps a discovered config dir back to the exact account handle (terminals).
    /// - `accountsByUUID`: maps a loaded account's stable identity (Claude profile uuid /
    ///   Codex account_id) to its `AccountRef.id`, for the desktop-app path.
    func detect(known: [AccountRef], accountsByUUID: [String: String] = [:]) -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }

        // Desktop-app path first: these apps aren't terminals but do host a session.
        if let desktop = DesktopApp(bundleID: bundleID) {
            guard let uuid = desktop.activeAccountIdentity() else { return nil }
            return accountsByUUID[uuid]
        }

        guard let terminal = SupportedTerminal(bundleID: bundleID) else { return nil }
        guard let tty = terminal.frontmostTTY() else { return nil }
        guard let session = ProcessInspector.sessionOnTTY(tty) else { return nil }

        return match(session: session, known: known)
    }

    /// Map a detected session (provider + optional config path) to a known account id.
    private func match(session: ProcessInspector.Session, known: [AccountRef]) -> String? {
        let candidates = known.filter { $0.provider == session.provider }
        guard !candidates.isEmpty else { return nil }

        // Resolve the session's config dir; nil path means the default home.
        let sessionDir = session.configDir.map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        for ref in candidates {
            let refDir = configDir(of: ref)
            if let sessionDir {
                if refDir == sessionDir { return ref.id }
            } else {
                // Default account: the one whose dir is the provider's default home.
                if ref.handle == "default" { return ref.id }
            }
        }
        // If the session runs a config dir we don't have an account for, no match.
        return nil
    }

    /// The standardized config directory backing an account ref.
    private func configDir(of ref: AccountRef) -> String {
        switch ref.source {
        case let .claudeKeychain(_, configDir):
            return URL(fileURLWithPath: configDir).standardizedFileURL.path
        case let .codexAuthFile(path):
            // auth.json lives inside the codex home; the home is its parent dir.
            return URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        }
    }
}

// MARK: - Supported terminals

/// Terminals whose frontmost-tab tty we can read via AppleScript.
enum SupportedTerminal: Sendable {
    case appleTerminal
    case iterm2

    init?(bundleID: String) {
        switch bundleID {
        case "com.apple.Terminal": self = .appleTerminal
        case "com.googlecode.iterm2": self = .iterm2
        default: return nil
        }
    }

    /// The tty path (e.g. "/dev/ttys014") of the frontmost tab, or nil.
    func frontmostTTY() -> String? {
        let script: String
        switch self {
        case .appleTerminal:
            script = #"tell application "Terminal" to get tty of selected tab of front window"#
        case .iterm2:
            script = #"tell application "iTerm2" to get tty of current session of current window"#
        }
        return AppleScriptRunner.runString(script)
    }
}

// MARK: - Desktop apps

/// Native desktop apps that host a Claude/Codex session but expose no tty. Each pins
/// itself to one login on disk, so we read that login's identity directly instead of
/// inspecting a process.
enum DesktopApp: Sendable {
    case codex
    case claude

    init?(bundleID: String) {
        switch bundleID {
        case "com.openai.codex": self = .codex
        case "com.anthropic.claudefordesktop": self = .claude
        default: return nil
        }
    }

    /// The stable identity of the account the app is currently signed into — matched
    /// against a loaded account's `accountUUID`. Nil if the file is absent/unreadable.
    func activeAccountIdentity() -> String? {
        switch self {
        case .codex:
            // The Codex app always uses ~/.codex; auth.json holds the active account_id,
            // the same value the usage layer reports for a Codex account.
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".codex/auth.json")
            guard let data = try? Data(contentsOf: url),
                  let cred = try? JSONDecoder().decode(CodexCredential.self, from: data)
            else { return nil }
            return cred.tokens?.accountId
        case .claude:
            // The Claude desktop app records the signed-in account UUID in its Electron
            // config; it equals the profile `account.uuid` the usage layer stores.
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Claude/config.json")
            guard let data = try? Data(contentsOf: url),
                  let cfg = try? JSONDecoder().decode(ClaudeAppConfig.self, from: data)
            else { return nil }
            return cfg.lastKnownAccountUuid
        }
    }
}

/// The slice of the Claude desktop app's `config.json` we read: the active login's UUID.
private struct ClaudeAppConfig: Decodable {
    let lastKnownAccountUuid: String?
}

// MARK: - AppleScript runner

/// Runs a one-line AppleScript and returns its string result. Errors (including a
/// missing Automation permission) resolve to nil so detection degrades gracefully.
enum AppleScriptRunner {
    static func runString(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        let value = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }
}

// MARK: - Process inspection

/// Reads process attributes (which claude/codex runs on a tty, and its account env).
enum ProcessInspector {

    struct Session: Sendable {
        let provider: Provider
        /// The value of CLAUDE_CONFIG_DIR / CODEX_HOME, or nil for the default home.
        let configDir: String?
    }

    /// Find the interactive claude/codex process on `ttyPath` and read its account env.
    static func sessionOnTTY(_ ttyPath: String) -> Session? {
        let short = ttyPath.replacingOccurrences(of: "/dev/", with: "")
        for pid in pids(onTTY: short) {
            guard let path = executablePath(pid), let provider = provider(forPath: path) else { continue }
            let env = environment(pid)
            // Skip the background daemon — only interactive sessions carry a real tty,
            // but guard anyway.
            if provider == .claude, let cmd = commandLine(pid), cmd.contains("daemon run") { continue }
            let dir = provider == .claude ? env["CLAUDE_CONFIG_DIR"] : env["CODEX_HOME"]
            return Session(provider: provider, configDir: dir)
        }
        return nil
    }

    private static func provider(forPath path: String) -> Provider? {
        let name = (path as NSString).lastPathComponent
        if name == "claude" || path.contains("/claude") { return .claude }
        if name == "codex" || path.contains("/codex") { return .codex }
        return nil
    }

    /// PIDs attached to a tty, newest first (so a nested claude wins over its shell).
    private static func pids(onTTY short: String) -> [Int32] {
        // `ps -t <tty> -o pid=` lists processes on that terminal.
        guard let out = shell("/bin/ps", ["-t", short, "-o", "pid="]) else { return [] }
        let ids = out.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        return ids.reversed() // children (claude) tend to appear after the shell
    }

    private static func executablePath(_ pid: Int32) -> String? {
        shell("/bin/ps", ["-o", "comm=", "-p", "\(pid)"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commandLine(_ pid: Int32) -> String? {
        shell("/bin/ps", ["-o", "command=", "-p", "\(pid)"])
    }

    /// Read a process's environment via `ps eww`. Works for the current user's own
    /// processes; returns empty on failure.
    private static func environment(_ pid: Int32) -> [String: String] {
        guard let out = shell("/bin/ps", ["eww", "-o", "command=", "-p", "\(pid)"]) else { return [:] }
        // `ps eww` prints "…command… KEY=VAL KEY=VAL". Extract KEY=VAL tokens.
        var env: [String: String] = [:]
        for token in out.split(separator: " ") {
            guard let eq = token.firstIndex(of: "="), token.first?.isLetter == true else { continue }
            let key = String(token[token.startIndex..<eq])
            // Only the two we care about, and only if they look like env keys.
            if key == "CLAUDE_CONFIG_DIR" || key == "CODEX_HOME" {
                env[key] = String(token[token.index(after: eq)...])
            }
        }
        return env
    }

    /// Minimal synchronous shell-out used only for local `ps` queries.
    private static func shell(_ launchPath: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
