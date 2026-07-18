import CryptoKit
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
                // Claude Science owns ~/.claude-science as an application data root.
                // It can contain Claude-shaped state, but it is not a Claude Code login
                // slot and shares its signed-in member's ordinary weekly quota.
                guard !isClaudeScienceDataDirectory(entry) else { continue }
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

    /// Claude Science's documented default data root plus custom `--data-dir` roots
    /// that use a ~/.claude-* name and carry its strong local runtime markers. This only
    /// inspects entry names/types; it never reads Science credentials or project data.
    static func claudeScienceDataDirs(
        home: URL? = nil,
        fileManager: FileManager = .default
    ) -> [URL] {
        let home = home ?? fileManager.homeDirectoryForCurrentUser
        guard let entries = try? fileManager.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return [] }
        return entries
            .filter { $0.lastPathComponent.hasPrefix(".claude-") }
            .filter { isClaudeScienceDataDirectory($0, fileManager: fileManager) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func isClaudeScienceDataDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let values = try? directory.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ]),
            values.isDirectory == true,
            values.isSymbolicLink != true
        else { return false }

        // This is the product's documented and reserved default data directory.
        if directory.lastPathComponent == ".claude-science" { return true }

        // A custom Science --data-dir may have another name. Require multiple
        // product-specific structural markers so a normal Claude Code config containing
        // projects/sessions is never excluded merely for having common Claude files.
        return isRegularFile(directory.appending(path: "install-id"), fileManager: fileManager)
            && isDirectory(directory.appending(path: "runtime"), fileManager: fileManager)
            && isDirectory(directory.appending(path: "orgs"), fileManager: fileManager)
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

    /// Validate a config directory observed on a live frontmost CLI process and turn it
    /// into an account ref. This lets non-conventional paths appear without crawling the
    /// filesystem or persisting the path beyond the current app process.
    static func discoverObserved(
        provider: Provider,
        configDir: String,
        existing: [AccountRef]
    ) -> AccountRef? {
        let expanded = (configDir as NSString).expandingTildeInPath
        let directory = URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true
        else { return nil }

        let source: CredentialSource
        switch provider {
        case .claude:
            guard !isClaudeScienceDataDirectory(directory) else { return nil }
            let hasState = FileManager.default.fileExists(
                atPath: directory.appending(path: ".claude.json").path
            ) || FileManager.default.fileExists(
                atPath: directory.appending(path: "settings.json").path
            )
            guard hasState else { return nil }
            source = .claudeConfigDir(path: directory.path)

        case .codex:
            let auth = directory.appending(path: "auth.json", directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: auth.path) else { return nil }
            source = .codexAuthFile(path: auth.path)
        }

        if let known = existing.first(where: {
            $0.provider == provider && canonicalConfigDirectory(for: $0) == directory.path
        }) {
            return known
        }

        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: provider == .claude ? ".claude" : ".codex", directoryHint: .isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var handle: String
        if directory.path == defaultDirectory.path {
            handle = "default"
        } else {
            handle = directory.lastPathComponent
            while handle.hasPrefix(".") { handle.removeFirst() }
            if handle.isEmpty { handle = "custom" }
        }

        if existing.contains(where: { $0.id == "\(provider.rawValue):\(handle)" }) {
            let suffix = SHA256.hash(data: Data(directory.path.utf8))
                .prefix(4)
                .map { String(format: "%02x", $0) }
                .joined()
            handle += "-\(suffix)"
        }
        return AccountRef(provider: provider, handle: handle, source: source)
    }

    private static func canonicalConfigDirectory(for ref: AccountRef) -> String {
        let url: URL
        switch ref.source {
        case let .claudeConfigDir(path):
            url = URL(fileURLWithPath: path, isDirectory: true)
        case let .codexAuthFile(path):
            url = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [
                  .isRegularFileKey, .isSymbolicLinkKey,
              ])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [
                  .isDirectoryKey, .isSymbolicLinkKey,
              ])
        else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
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
