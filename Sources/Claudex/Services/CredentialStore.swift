import Foundation
import CryptoKit

/// Discovers which accounts exist on this machine and reads their tokens on demand.
///
/// Discovery (which accounts exist) is deliberately separated from token reading
/// (the secret material). The UI and store only ever see `AccountRef`s; the raw token
/// is fetched just-in-time inside `readToken` and never stored.
enum CredentialStore {

    // MARK: Claude

    /// Config directories to probe for Claude logins. The default `~/.claude` plus the
    /// plus any `~/.claude-*` directory that looks like a config dir (contains a
    /// `.claude.json`). Handles are derived from the directory name, so aliases like
    /// `CLAUDE_CONFIG_DIR="$HOME/.claude-work"` are discovered automatically.
    static func claudeConfigDirs() -> [(handle: String, dir: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var result: [(String, URL)] = []

        // Default account.
        result.append(("default", home.appending(path: ".claude")))
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
                let hasConfig = FileManager.default.fileExists(
                    atPath: entry.appending(path: ".claude.json").path
                )
                guard hasConfig else { continue }
                let handle = String(entry.lastPathComponent.dropFirst(1)) // strip leading dot
                result.append((handle, entry))
                seen.insert(path)
            }
        }
        return result
    }

    /// The keychain service name for a config dir. The default dir uses the bare service
    /// name; every other dir uses `Claude Code-credentials-<sha256(absPath)[:8]>`.
    static func claudeKeychainService(for configDir: URL, isDefault: Bool) -> String {
        let base = "Claude Code-credentials"
        if isDefault { return base }
        let path = configDir.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(base)-\(String(hex.prefix(8)))"
    }

    /// Build refs for every discovered Claude account that has a keychain entry.
    static func discoverClaude() -> [AccountRef] {
        let dirs = claudeConfigDirs()
        var refs: [AccountRef] = []
        for (index, (handle, dir)) in dirs.enumerated() {
            let isDefault = index == 0
            let service = claudeKeychainService(for: dir, isDefault: isDefault)
            guard Keychain.exists(service: service) else { continue }
            refs.append(
                AccountRef(
                    provider: .claude,
                    handle: handle,
                    source: .claudeKeychain(service: service, configDir: dir.path)
                )
            )
        }
        return refs
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

    // MARK: Token reading (secret material — stays local to fetch)

    /// A token bundle handed to a fetcher. Held only transiently.
    enum Token: Sendable {
        case claude(accessToken: String, planLabel: String?)
        case codex(accessToken: String, accountId: String, displayName: String?)
    }

    static func readToken(for ref: AccountRef) throws(UsageError) -> Token {
        switch ref.source {
        case let .claudeKeychain(service, _):
            guard let raw = Keychain.read(service: service) else {
                throw .noCredential
            }
            guard let data = raw.data(using: .utf8),
                  let cred = try? JSONDecoder().decode(ClaudeCredential.self, from: data),
                  let oauth = cred.claudeAiOauth
            else {
                throw .credentialUnreadable("Keychain entry is not valid Claude credentials.")
            }
            // Surface an expiry hint but let the server be the source of truth on 401.
            let plan = oauth.subscriptionType.map { $0.capitalized }
            return .claude(accessToken: oauth.accessToken, planLabel: plan)

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
            return .codex(accessToken: tokens.accessToken, accountId: tokens.accountId, displayName: name)
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

// MARK: - Keychain (generic-password, read-only)

/// Minimal read-only wrapper over the macOS keychain for generic passwords.
enum Keychain {
    static func exists(service: String) -> Bool {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func read(service: String) -> String? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }
}
