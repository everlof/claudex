import CryptoKit
import Foundation

/// Reversibly adds Claudex's content-free Activity Map hook to each discovered provider
/// configuration. Existing hook groups and handlers are preserved; removal filters only
/// the exact stable Claudex command recorded in the owner-only manifest.
struct ActivityHookInstaller {
    struct Installation: Codable, Sendable, Equatable {
        let accountKey: String
        let provider: Provider
        let handle: String
        let configurationPath: String
        let command: String
        let createdConfiguration: Bool

        enum CodingKeys: String, CodingKey {
            case accountKey = "account_key"
            case provider, handle
            case configurationPath = "configuration_path"
            case command
            case createdConfiguration = "created_configuration"
        }
    }

    struct Report: Sendable, Equatable {
        let connected: Int
        let removed: Int
        let issues: [String]

        static let empty = Report(connected: 0, removed: 0, issues: [])
    }

    enum InstallError: Error, LocalizedError, Equatable {
        case unsafeConfiguration
        case configurationTooLarge
        case invalidJSON
        case inlineCodexHooks
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsafeConfiguration:
                return "the hook configuration is not a regular local file"
            case .configurationTooLarge:
                return "the hook configuration is unexpectedly large"
            case .invalidJSON:
                return "the hook configuration is not valid JSON"
            case .inlineCodexHooks:
                return "config.toml already contains inline hooks; Claudex left it unchanged to avoid a duplicate hook source"
            case let .writeFailed(message):
                return "the hook configuration could not be updated: \(message)"
            }
        }
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        var installations: [Installation]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case installations
        }
    }

    private static let maximumConfigurationBytes = 1_048_576
    private let fileManager: FileManager
    private let applicationSupportDirectory: URL
    private let helperURL: URL

    init(
        helperURL: URL? = nil,
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let support = applicationSupportDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appending(path: "Claudex", directoryHint: .isDirectory)
            ?? fileManager.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Claudex", directoryHint: .isDirectory)
        self.applicationSupportDirectory = support
        self.helperURL = helperURL ?? support
            .appending(path: "bin", directoryHint: .isDirectory)
            .appending(path: "ClaudexStatusBridge", directoryHint: .notDirectory)
    }

    var activityDirectory: URL {
        applicationSupportDirectory.appending(path: "Activity", directoryHint: .isDirectory)
    }

    var eventDirectory: URL { activityDirectory }

    var manifestURL: URL {
        activityDirectory.appending(path: "installations.json", directoryHint: .notDirectory)
    }

    func installations() -> [Installation] {
        (try? loadManifest().installations) ?? []
    }

    func install(accounts: [AccountRef]) -> Report {
        var manifest = (try? loadManifest()) ?? Manifest(schemaVersion: 1, installations: [])
        var connected = 0
        var issues: [String] = []

        for account in accounts {
            do {
                let target = try target(for: account)
                let key = accountKey(for: account)
                let command = hookCommand(provider: account.provider, accountKey: key)
                let prior = manifest.installations.first { $0.configurationPath == target.path }
                let createdConfiguration = prior?.createdConfiguration
                    ?? !fileManager.fileExists(atPath: target.path)
                try addHooks(to: target, provider: account.provider, command: command)
                let installation = Installation(
                    accountKey: key,
                    provider: account.provider,
                    handle: account.handle,
                    configurationPath: target.path,
                    command: command,
                    createdConfiguration: createdConfiguration
                )
                manifest.installations.removeAll { $0.configurationPath == target.path }
                manifest.installations.append(installation)
                do {
                    try saveManifest(manifest)
                } catch {
                    // Never leave an unrecorded hook that the user cannot later remove
                    // through Claudex. Roll back only our exact handler.
                    try? removeHooks(
                        from: target,
                        provider: account.provider,
                        command: command,
                        removeFileWhenEmpty: createdConfiguration
                    )
                    manifest.installations.removeAll { $0.configurationPath == target.path }
                    throw error
                }
                connected += 1
            } catch {
                issues.append("\(account.provider.displayName) · \(account.handle): \(error.localizedDescription)")
            }
        }

        if accounts.isEmpty {
            try? saveManifest(manifest)
        }
        return Report(connected: connected, removed: 0, issues: issues)
    }

    func removeAll() -> Report {
        var manifest = (try? loadManifest()) ?? Manifest(schemaVersion: 1, installations: [])
        var retained: [Installation] = []
        var removed = 0
        var issues: [String] = []

        for installation in manifest.installations {
            do {
                try removeHooks(
                    from: URL(fileURLWithPath: installation.configurationPath),
                    provider: installation.provider,
                    command: installation.command,
                    removeFileWhenEmpty: installation.createdConfiguration
                )
                removed += 1
            } catch {
                retained.append(installation)
                issues.append("\(installation.provider.displayName) · \(installation.handle): \(error.localizedDescription)")
            }
        }
        manifest.installations = retained
        do {
            if retained.isEmpty {
                try? fileManager.removeItem(at: manifestURL)
            } else {
                try saveManifest(manifest)
            }
        } catch {
            issues.append("Claudex metadata: \(error.localizedDescription)")
        }
        return Report(connected: 0, removed: removed, issues: issues)
    }

    func deleteEventFiles() throws {
        guard let files = try? fileManager.contentsOfDirectory(
            at: eventDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("events-")
            && file.pathExtension == "jsonl" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try fileManager.removeItem(at: file)
        }
    }

    func removeExpiredEventFiles(now: Date = Date(), retentionDays: Int = 7) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: eventDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return }
        let formatter = Self.dayFormatter
        let calendar = Calendar(identifier: .gregorian)
        let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: now) ?? .distantPast
        for file in files where file.lastPathComponent.hasPrefix("events-")
            && file.pathExtension == "jsonl" {
            let name = file.deletingPathExtension().lastPathComponent
            guard let date = formatter.date(from: String(name.dropFirst("events-".count))), date < cutoff
            else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    private func target(for account: AccountRef) throws -> URL {
        switch account.source {
        case let .claudeConfigDir(path):
            return URL(fileURLWithPath: path, isDirectory: true)
                .appending(path: "settings.json", directoryHint: .notDirectory)
        case let .codexAuthFile(path):
            let home = URL(fileURLWithPath: path, isDirectory: false).deletingLastPathComponent()
            let config = home.appending(path: "config.toml", directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: config.path), try codexConfigContainsInlineHooks(config) {
                throw InstallError.inlineCodexHooks
            }
            return home.appending(path: "hooks.json", directoryHint: .notDirectory)
        }
    }

    private func codexConfigContainsInlineHooks(_ url: URL) throws -> Bool {
        let data = try readRegularFile(url, allowMissing: false)
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            return value == "[hooks]" || value.hasPrefix("[[hooks.") || value.hasPrefix("[hooks.")
        }
    }

    private func addHooks(to url: URL, provider: Provider, command: String) throws {
        var root = try readJSONObject(url, allowMissing: true)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events(for: provider) {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let alreadyPresent = groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String) == command
                } == true
            }
            if !alreadyPresent {
                groups.append([
                    "hooks": [[
                        "type": "command",
                        "command": command,
                        "timeout": 5,
                    ]],
                ])
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func removeHooks(
        from url: URL,
        provider: Provider,
        command: String,
        removeFileWhenEmpty: Bool = false
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        var root = try readJSONObject(url, allowMissing: false)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for event in events(for: provider) {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let filteredGroups: [[String: Any]] = groups.compactMap { group in
                guard var handlers = group["hooks"] as? [[String: Any]] else { return group }
                handlers.removeAll { ($0["command"] as? String) == command }
                guard !handlers.isEmpty else { return nil }
                var copy = group
                copy["hooks"] = handlers
                return copy
            }
            if filteredGroups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = filteredGroups
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        if removeFileWhenEmpty, root.isEmpty {
            try fileManager.removeItem(at: url)
            return
        }
        try writeJSONObject(root, to: url)
    }

    private func events(for provider: Provider) -> [String] {
        switch provider {
        case .claude:
            return ["SessionStart", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "SessionEnd"]
        case .codex:
            return ["SessionStart", "PostToolUse", "PermissionRequest", "SubagentStart", "SubagentStop", "Stop"]
        }
    }

    private func hookCommand(provider: Provider, accountKey: String) -> String {
        "\(shellQuote(helperURL.path)) activity --provider \(provider.rawValue) --account \(accountKey)"
    }

    private func accountKey(for account: AccountRef) -> String {
        let source: String
        switch account.source {
        case let .claudeConfigDir(path): source = path
        case let .codexAuthFile(path): source = path
        }
        return SHA256.hash(data: Data("\(account.provider.rawValue):\(source)".utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func readJSONObject(_ url: URL, allowMissing: Bool) throws -> [String: Any] {
        let data = try readRegularFile(url, allowMissing: allowMissing)
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { throw InstallError.invalidJSON }
        return root
    }

    private func readRegularFile(_ url: URL, allowMissing: Bool) throws -> Data {
        guard fileManager.fileExists(atPath: url.path) else {
            if allowMissing { return Data() }
            throw InstallError.unsafeConfiguration
        }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { throw InstallError.unsafeConfiguration }
        guard (values.fileSize ?? Self.maximumConfigurationBytes + 1) <= Self.maximumConfigurationBytes
        else { throw InstallError.configurationTooLarge }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= Self.maximumConfigurationBytes else {
                throw InstallError.configurationTooLarge
            }
            return data
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }

    private func writeJSONObject(_ root: [String: Any], to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(root) else { throw InstallError.invalidJSON }
        do {
            let existingPermissions = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0A)
            guard data.count <= Self.maximumConfigurationBytes else {
                throw InstallError.configurationTooLarge
            }
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: existingPermissions ?? 0o600],
                ofItemAtPath: url.path
            )
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }

    private func loadManifest() throws -> Manifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return Manifest(schemaVersion: 1, installations: [])
        }
        let data = try readRegularFile(manifestURL, allowMissing: false)
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schemaVersion == 1
        else { throw InstallError.invalidJSON }
        return manifest
    }

    private func saveManifest(_ manifest: Manifest) throws {
        do {
            try ensurePrivateActivityDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(manifest)
            data.append(0x0A)
            try data.write(to: manifestURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }

    private func ensurePrivateActivityDirectory() throws {
        do {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: activityDirectory.path, isDirectory: &isDirectory) {
                let values = try activityDirectory.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey,
                ])
                guard isDirectory.boolValue,
                      values.isDirectory == true,
                      values.isSymbolicLink != true
                else { throw InstallError.unsafeConfiguration }
            } else {
                try fileManager.createDirectory(
                    at: activityDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: activityDirectory.path)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
