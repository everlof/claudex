import Foundation

/// Discovers which account slots exist on this machine and reads Codex tokens on demand.
///
/// Claude is deliberately config-only: its usage arrives through Claude Code's local
/// status-line feed, so Claudex never needs to locate or read Claude's Keychain item.
enum CredentialStore {

    // MARK: Claude

    /// Config directories to probe for Claude logins. The default `~/.claude` plus the
    /// plus any `~/.claude-*` directory that looks like a config dir (contains a
    /// `.claude.json`). Handles are derived from the directory name, so aliases like
    /// `CLAUDE_CONFIG_DIR="$HOME/.claude-work"` are discovered automatically.
    static func claudeConfigDirs() -> [(handle: String, dir: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var result: [(String, URL)] = []

        // Default account. Do not invent a card on machines that have never used Claude.
        let defaultDir = home.appending(path: ".claude")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: defaultDir.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            result.append(("default", defaultDir))
        }
        var seen = Set(result.map { $0.1.standardizedFileURL.path })

        // Any additional ~/.claude-* dirs that carry a config file, sorted for a stable
        // order. The handle is the directory name minus its leading dot.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: nil
        ) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where entry.lastPathComponent.hasPrefix(".claude-") {
                let path = entry.standardizedFileURL.path
                guard !seen.contains(path) else { continue }
                let hasState = FileManager.default.fileExists(
                    atPath: entry.appending(path: ".claude.json").path
                ) || FileManager.default.fileExists(
                    atPath: entry.appending(path: "settings.json").path
                )
                guard hasState else { continue }
                let handle = String(entry.lastPathComponent.dropFirst(1)) // strip leading dot
                result.append((handle, entry))
                seen.insert(path)
            }
        }
        return result
    }

    /// Build refs from config directories only. No Keychain query is performed, including
    /// the seemingly-harmless existence query that used to run once per account.
    static func discoverClaude() -> [AccountRef] {
        claudeConfigDirs().map { handle, dir in
            AccountRef(
                provider: .claude,
                handle: handle,
                source: .claudeConfigDir(path: dir.standardizedFileURL.path)
            )
        }
    }

    // MARK: Codex

    /// Codex home directories to probe. Mirrors the Claude scheme so multiple Codex
    /// logins work the same way: the default `~/.codex` (or `$CODEX_HOME`), plus any
    /// additional `~/.codex-*` directory that contains an `auth.json`. To add a second
    /// login, run e.g. `CODEX_HOME="$HOME/.codex-work" codex login`.
    static func discoverCodex() -> [AccountRef] {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        var refs: [AccountRef] = []
        var seen = Set<String>()

        func add(handle: String, dir: URL) {
            let authPath = dir.appending(path: "auth.json")
            let path = authPath.standardizedFileURL.path
            guard !seen.contains(path),
                  FileManager.default.fileExists(atPath: path) else { return }
            seen.insert(path)
            refs.append(
                AccountRef(provider: .codex, handle: handle, source: .codexAuthFile(path: path))
            )
        }

        // Default / explicit CODEX_HOME first.
        if let override = env["CODEX_HOME"], !override.isEmpty {
            add(handle: "default", dir: URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        } else {
            add(handle: "default", dir: home.appending(path: ".codex"))
        }

        // Any additional ~/.codex-* homes (parallel to the ~/.claude-* aliases).
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: nil
        ) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where entry.lastPathComponent.hasPrefix(".codex-") {
                let handle = String(entry.lastPathComponent.dropFirst()) // strip leading dot
                add(handle: handle, dir: entry)
            }
        }
        return refs
    }

    /// All accounts across both providers, Claude first.
    static func discoverAll() -> [AccountRef] {
        discoverClaude() + discoverCodex()
    }

    // MARK: Codex token reading (secret material — stays local to fetch)

    /// A token bundle handed to a fetcher. Held only transiently.
    struct CodexToken: Sendable {
        let accessToken: String
        let accountId: String
        let displayName: String?
    }

    static func readCodexToken(for ref: AccountRef) throws(UsageError) -> CodexToken {
        switch ref.source {
        case .claudeConfigDir:
            throw .noCredential

        case let .codexAuthFile(path):
            guard let data = FileManager.default.contents(atPath: path) else {
                throw .noCredential
            }
            guard let cred = try? JSONDecoder().decode(CodexCredential.self, from: data),
                  let tokens = cred.tokens
            else {
                throw .credentialUnreadable("auth.json is missing tokens.")
            }
            // The id_token JWT carries the account email/name — decode it locally so we
            // can label each Codex login (useful once there are several).
            let claims = tokens.idToken.flatMap(decodeJWTClaims)
            let name = claims?.name ?? claims?.email
            return CodexToken(
                accessToken: tokens.accessToken,
                accountId: tokens.accountId,
                displayName: name
            )
        }
    }

    /// Decode the payload of a JWT (no signature verification — we only read claims to
    /// display a friendly account label; the server remains the source of truth).
    private static func decodeJWTClaims(_ jwt: String) -> CodexIDClaims? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONDecoder().decode(CodexIDClaims.self, from: data)
    }
}
