import CryptoKit
import Foundation

/// Installs the passive bridge into one Claude config directory without losing an existing
/// status line. Every mutation is explicit and reversible; uninstall refuses to touch a
/// statusLine that changed after Claudex installed it.
struct ClaudeStatusLineInstaller {
    enum State: Sendable, Equatable {
        case notInstalled
        case installed
        case needsRepair(String)
        case modified(String)
    }

    struct Inspection: Sendable, Equatable {
        let state: State
        let profileID: String
        let settingsURL: URL
        let cacheURL: URL
    }

    enum InstallResult: Sendable, Equatable {
        case installed
        case repaired
        case alreadyInstalled
    }

    enum UninstallResult: Sendable, Equatable {
        case uninstalled
        case notInstalled
        case modifiedNotRestored
    }

    enum InstallError: Error, Sendable, Equatable, LocalizedError {
        case helperMissing
        case configDirectoryMissing
        case unsafeSettingsFile
        case settingsTooLarge
        case invalidSettings
        case unsupportedExistingStatusLine
        case existingClaudexBridge
        case helperStillInstalled
        case missingBackup
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return "The Claudex status-line helper is missing. Reinstall or rebuild Claudex."
            case .configDirectoryMissing:
                return "This Claude configuration directory no longer exists."
            case .unsafeSettingsFile:
                return "Claude settings is not a regular local file, so Claudex left it unchanged."
            case .settingsTooLarge:
                return "Claude settings is unexpectedly large, so Claudex left it unchanged."
            case .invalidSettings:
                return "Claude settings is not valid JSON, so Claudex left it unchanged."
            case .unsupportedExistingStatusLine:
                return "The existing Claude status line is not a command and cannot be safely chained."
            case .existingClaudexBridge:
                return "This settings file already references a Claudex bridge from another config slot. Remove or repair it before connecting."
            case .helperStillInstalled:
                return "Claude settings still references the Claudex helper. Remove that command manually or repair the integration before forgetting its backup."
            case .missingBackup:
                return "The integration exists without its restore metadata. Claudex left it unchanged."
            case let .writeFailed(message):
                return "Could not update Claude settings: \(message)"
            }
        }
    }

    private static let maximumSettingsBytes = 1_048_576
    private static let maximumForwardCommandCharacters = 16_384
    private static let schemaVersion = 1
    private static let helperMarker = "ClaudexStatusBridge"

    private let applicationSupportDirectory: URL
    private let fileManager: FileManager

    init(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let applicationSupportDirectory {
            self.applicationSupportDirectory = applicationSupportDirectory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser
                    .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            self.applicationSupportDirectory = base
                .appending(path: "Claudex", directoryHint: .isDirectory)
        }
    }

    func profileID(for configDir: String) -> String {
        let canonical = canonicalPath(configDir)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func cacheURL(for configDir: String) -> URL {
        ClaudeStatusCache.fileURL(
            profileID: profileID(for: configDir),
            directory: statusDirectory
        )
    }

    func heartbeatURL(for configDir: String) -> URL {
        ClaudeStatusCache.heartbeatFileURL(
            profileID: profileID(for: configDir),
            directory: statusDirectory
        )
    }

    func hasManagedInstallation(configDir: String) -> Bool {
        fileManager.fileExists(
            atPath: metadataURL(profileID: profileID(for: configDir)).path
        )
    }

    func clearCachedStatus(configDir: String) {
        try? fileManager.removeItem(at: cacheURL(for: configDir))
        try? fileManager.removeItem(at: heartbeatURL(for: configDir))
    }

    func inspect(configDir: String, helperExecutable: URL) -> Inspection {
        let profile = profileID(for: configDir)
        let settingsURL = self.settingsURL(for: configDir)
        let inspection = Inspection(
            state: inspectState(
                configDir: configDir,
                helperExecutable: helperExecutable,
                profileID: profile
            ),
            profileID: profile,
            settingsURL: settingsURL,
            cacheURL: cacheURL(for: configDir)
        )
        return inspection
    }

    func install(
        configDir: String,
        helperExecutable: URL
    ) throws(InstallError) -> InstallResult {
        guard fileManager.isExecutableFile(atPath: helperExecutable.path) else {
            throw .helperMissing
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: configDir, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw .configDirectoryMissing }

        let profile = profileID(for: configDir)
        let settingsURL = settingsURL(for: configDir)
        var settings = try readSettings(at: settingsURL)
        let metadataURL = self.metadataURL(profileID: profile)
        let existingMetadata = try readMetadata(at: metadataURL)
        let currentStatusLine = settings["statusLine"]

        if let existingMetadata {
            guard existingMetadata.configDirectory == canonicalPath(configDir) else {
                throw .missingBackup
            }
            let currentMatchesInstalled = jsonEqual(
                currentStatusLine,
                existingMetadata.installedStatusLine
            )
            let currentMatchesOriginal = jsonEqual(
                currentStatusLine,
                originalValueForComparison(existingMetadata.originalStatusLine)
            )
            let currentIsOurBridge = command(from: currentStatusLine)
                .map { isOurCommand($0, profileID: profile) } ?? false
            guard currentMatchesInstalled || currentMatchesOriginal || currentIsOurBridge else {
                throw .missingBackup
            }
            let forwardURL: URL?
            if existingMetadata.hasForwardCommand {
                guard let previousCommand = try validatedExistingCommand(
                    from: existingMetadata.originalStatusLine
                ) else { throw .missingBackup }
                forwardURL = forwardConfigURL(profileID: profile)
                try writePrivateJSON(["command": previousCommand], to: forwardURL!)
            } else {
                forwardURL = nil
            }
            let desired = try installedStatusLine(
                basedOn: existingMetadata.originalStatusLine,
                helperExecutable: helperExecutable,
                profileID: profile,
                forwardConfigURL: forwardURL
            )
            if currentMatchesInstalled, jsonEqual(currentStatusLine, desired) {
                return .alreadyInstalled
            }

            let updatedMetadata = Metadata(
                configDirectory: canonicalPath(configDir),
                originalStatusLine: existingMetadata.originalStatusLine,
                installedStatusLine: desired,
                hasForwardCommand: existingMetadata.hasForwardCommand
            )
            let previousStatusLine = currentStatusLine
            do {
                settings["statusLine"] = desired
                try writeSettings(settings, to: settingsURL)
                try writeMetadata(updatedMetadata, profileID: profile)
            } catch let error {
                if let previousStatusLine {
                    settings["statusLine"] = previousStatusLine
                } else {
                    settings.removeValue(forKey: "statusLine")
                }
                try? writeSettings(settings, to: settingsURL)
                throw error
            }
            return .repaired
        }

        if let command = command(from: currentStatusLine), isAnyBridgeCommand(command) {
            throw isOurCommand(command, profileID: profile) ? .missingBackup : .existingClaudexBridge
        }

        let originalStatusLine = currentStatusLine ?? NSNull()
        let previousCommand = try validatedExistingCommand(from: currentStatusLine)
        let forwardURL: URL?
        if let previousCommand {
            forwardURL = forwardConfigURL(profileID: profile)
            try writePrivateJSON(["command": previousCommand], to: forwardURL!)
        } else {
            forwardURL = nil
        }

        let installed = try installedStatusLine(
            basedOn: originalStatusLine,
            helperExecutable: helperExecutable,
            profileID: profile,
            forwardConfigURL: forwardURL
        )
        let metadata = Metadata(
            configDirectory: canonicalPath(configDir),
            originalStatusLine: originalStatusLine,
            installedStatusLine: installed,
            hasForwardCommand: previousCommand != nil
        )

        do {
            try writeMetadata(metadata, profileID: profile)
            settings["statusLine"] = installed
            try writeSettings(settings, to: settingsURL)
            // A different login may now occupy the same config slot. Never surface an old
            // account's cache before the newly-connected session emits its first response.
            try? fileManager.removeItem(at: cacheURL(for: configDir))
            try? fileManager.removeItem(at: heartbeatURL(for: configDir))
        } catch let error {
            // `writeSettings` can fail after its atomic rename (for example while applying
            // permissions). Restore first; only discard the restore chain after rollback
            // is confirmed. If rollback also fails, metadata remains for idempotent repair.
            if originalStatusLine is NSNull {
                settings.removeValue(forKey: "statusLine")
            } else {
                settings["statusLine"] = originalStatusLine
            }
            var rolledBack = false
            do {
                try writeSettings(settings, to: settingsURL)
                rolledBack = true
            } catch {
                // Keep metadata/forward files so the next reviewed repair can recover.
            }
            if rolledBack {
                try? fileManager.removeItem(at: metadataURL)
                if let forwardURL { try? fileManager.removeItem(at: forwardURL) }
            }
            throw error
        }
        return .installed
    }

    func uninstall(configDir: String) throws(InstallError) -> UninstallResult {
        let profile = profileID(for: configDir)
        let metadataURL = self.metadataURL(profileID: profile)
        guard let metadata = try readMetadata(at: metadataURL) else {
            return .notInstalled
        }
        guard metadata.configDirectory == canonicalPath(configDir) else { throw .missingBackup }

        let settingsURL = settingsURL(for: configDir)
        var settings = try readSettings(at: settingsURL)
        if jsonEqual(
            settings["statusLine"],
            originalValueForComparison(metadata.originalStatusLine)
        ) {
            try? fileManager.removeItem(at: metadataURL)
            try? fileManager.removeItem(at: forwardConfigURL(profileID: profile))
            try? fileManager.removeItem(at: cacheURL(for: configDir))
            try? fileManager.removeItem(at: heartbeatURL(for: configDir))
            return .uninstalled
        }
        guard jsonEqual(settings["statusLine"], metadata.installedStatusLine) else {
            return .modifiedNotRestored
        }

        if metadata.originalStatusLine is NSNull {
            settings.removeValue(forKey: "statusLine")
        } else {
            settings["statusLine"] = metadata.originalStatusLine
        }
        try writeSettings(settings, to: settingsURL)

        try? fileManager.removeItem(at: metadataURL)
        try? fileManager.removeItem(at: forwardConfigURL(profileID: profile))
        try? fileManager.removeItem(at: cacheURL(for: configDir))
        try? fileManager.removeItem(at: heartbeatURL(for: configDir))
        return .uninstalled
    }

    /// Remove only Claudex-owned restore/cache files after the user replaced the status
    /// line themselves. Never changes Claude settings, and refuses while the helper is
    /// still referenced there.
    func forgetMetadata(configDir: String) throws(InstallError) {
        let profile = profileID(for: configDir)
        let settings = try readSettings(at: settingsURL(for: configDir))
        if let command = command(from: settings["statusLine"]), isAnyBridgeCommand(command) {
            throw .helperStillInstalled
        }
        try? fileManager.removeItem(at: metadataURL(profileID: profile))
        try? fileManager.removeItem(at: forwardConfigURL(profileID: profile))
        try? fileManager.removeItem(at: cacheURL(for: configDir))
        try? fileManager.removeItem(at: heartbeatURL(for: configDir))
    }

    // MARK: Inspection

    private func inspectState(
        configDir: String,
        helperExecutable: URL,
        profileID: String
    ) -> State {
        let settings: [String: Any]
        do {
            settings = try readSettings(at: settingsURL(for: configDir))
        } catch {
            return .needsRepair(error.localizedDescription)
        }
        let metadata: Metadata?
        do {
            metadata = try readMetadata(at: metadataURL(profileID: profileID))
        } catch {
            return .needsRepair(error.localizedDescription)
        }

        guard let metadata else {
            if let command = command(from: settings["statusLine"]),
               isAnyBridgeCommand(command) {
                let detail = isOurCommand(command, profileID: profileID)
                    ? "Claudex found its helper without restore metadata and will not overwrite it."
                    : "This copied settings file references another Claude slot’s Claudex helper."
                return .modified(detail)
            }
            return .notInstalled
        }
        guard metadata.configDirectory == canonicalPath(configDir) else {
            return .needsRepair("The restore metadata does not match this Claude config slot.")
        }
        if jsonEqual(
            settings["statusLine"],
            originalValueForComparison(metadata.originalStatusLine)
        ) {
            return .needsRepair("A previous setup or disconnect was interrupted. Review to finish safely.")
        }
        guard jsonEqual(settings["statusLine"], metadata.installedStatusLine) else {
            if let command = command(from: settings["statusLine"]),
               isOurCommand(command, profileID: profileID) {
                return .needsRepair("A Claudex repair was interrupted. Review to finish safely.")
            }
            return .modified("Claude settings changed after Claudex connected. Claudex will not overwrite those changes.")
        }
        guard fileManager.isExecutableFile(atPath: helperExecutable.path) else {
            return .needsRepair("The status-line helper is missing from this Claudex installation.")
        }
        guard let installedCommand = command(from: metadata.installedStatusLine),
              installedCommand.contains(shellQuote(helperExecutable.path))
        else {
            return .needsRepair("Claudex moved or was updated. Review and repair the local feed.")
        }
        if metadata.hasForwardCommand {
            let forward = forwardConfigURL(profileID: profileID)
            let expected = try? validatedExistingCommand(from: metadata.originalStatusLine)
            guard isSafeRegularFile(forward, maximumBytes: 65_536),
                  let expected,
                  readForwardCommand(at: forward) == expected
            else {
                return .needsRepair("The saved existing status-line command is missing. Review and repair the local feed.")
            }
        }
        return .installed
    }

    // MARK: JSON model

    private struct Metadata {
        let configDirectory: String
        let originalStatusLine: Any
        let installedStatusLine: Any
        let hasForwardCommand: Bool
    }

    private func readMetadata(at url: URL) throws(InstallError) -> Metadata? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? Self.maximumSettingsBytes + 1) <= Self.maximumSettingsBytes,
              let data = fileManager.contents(atPath: url.path),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              root["schema_version"] as? Int == Self.schemaVersion,
              let configDirectory = root["config_directory"] as? String,
              let original = root["original_status_line"],
              let installed = root["installed_status_line"]
        else { throw .missingBackup }
        return Metadata(
            configDirectory: configDirectory,
            originalStatusLine: original,
            installedStatusLine: installed,
            hasForwardCommand: root["has_forward_command"] as? Bool ?? false
        )
    }

    private func writeMetadata(_ metadata: Metadata, profileID: String) throws(InstallError) {
        let object: [String: Any] = [
            "schema_version": Self.schemaVersion,
            "config_directory": metadata.configDirectory,
            "original_status_line": metadata.originalStatusLine,
            "installed_status_line": metadata.installedStatusLine,
            "has_forward_command": metadata.hasForwardCommand,
        ]
        try writePrivateJSON(object, to: metadataURL(profileID: profileID))
    }

    private func readSettings(at url: URL) throws(InstallError) -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { throw .unsafeSettingsFile }
        guard (values.fileSize ?? Self.maximumSettingsBytes + 1) <= Self.maximumSettingsBytes else {
            throw .settingsTooLarge
        }
        guard let data = fileManager.contents(atPath: url.path),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { throw .invalidSettings }
        return root
    }

    private func validatedExistingCommand(from statusLine: Any?) throws(InstallError) -> String? {
        guard let statusLine else { return nil }
        guard let object = statusLine as? [String: Any] else {
            throw .unsupportedExistingStatusLine
        }
        if let type = object["type"] as? String, type != "command" {
            throw .unsupportedExistingStatusLine
        }
        guard let command = object["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.count <= Self.maximumForwardCommandCharacters
        else { throw .unsupportedExistingStatusLine }
        guard !isAnyBridgeCommand(command) else { throw .existingClaudexBridge }
        return command
    }

    private func installedStatusLine(
        basedOn original: Any,
        helperExecutable: URL,
        profileID: String,
        forwardConfigURL: URL?
    ) throws(InstallError) -> [String: Any] {
        var object: [String: Any]
        if original is NSNull {
            object = [:]
        } else if let original = original as? [String: Any] {
            object = original
        } else {
            throw .unsupportedExistingStatusLine
        }

        var pieces = [
            shellQuote(helperExecutable.path),
            "--profile",
            shellQuote(profileID),
        ]
        if let forwardConfigURL {
            pieces += ["--forward-config", shellQuote(forwardConfigURL.path)]
        }
        object["type"] = "command"
        object["command"] = pieces.joined(separator: " ")
        return object
    }

    private func command(from statusLine: Any?) -> String? {
        (statusLine as? [String: Any])?["command"] as? String
    }

    private func isOurCommand(_ command: String, profileID: String) -> Bool {
        command.contains(Self.helperMarker) && command.contains(profileID)
    }

    private func isAnyBridgeCommand(_ command: String) -> Bool {
        command.contains(Self.helperMarker)
    }

    private func originalValueForComparison(_ original: Any) -> Any? {
        original is NSNull ? nil : original
    }

    private func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return (lhs as AnyObject).isEqual(rhs)
        default: return false
        }
    }

    // MARK: Paths and atomic writes

    private var statusDirectory: URL {
        applicationSupportDirectory.appending(path: "ClaudeStatus", directoryHint: .isDirectory)
    }

    private var metadataDirectory: URL {
        statusDirectory.appending(path: "Metadata", directoryHint: .isDirectory)
    }

    private var forwardDirectory: URL {
        statusDirectory.appending(path: "Forward", directoryHint: .isDirectory)
    }

    private func settingsURL(for configDir: String) -> URL {
        URL(fileURLWithPath: configDir, isDirectory: true)
            .appending(path: "settings.json", directoryHint: .notDirectory)
    }

    private func metadataURL(profileID: String) -> URL {
        metadataDirectory.appending(path: "\(profileID).json", directoryHint: .notDirectory)
    }

    private func forwardConfigURL(profileID: String) -> URL {
        forwardDirectory.appending(path: "\(profileID).json", directoryHint: .notDirectory)
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func writeSettings(_ object: [String: Any], to url: URL) throws(InstallError) {
        let existingPermissions = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions])
            as? NSNumber
        do {
            let data = try encodedJSON(object)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: existingPermissions ?? NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    private func writePrivateJSON(_ object: [String: Any], to url: URL) throws(InstallError) {
        do {
            try ensurePrivateDirectory(applicationSupportDirectory)
            try ensurePrivateDirectory(statusDirectory)
            try ensurePrivateDirectory(url.deletingLastPathComponent())
            let data = try encodedJSON(object)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as InstallError {
            throw error
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    private func encodedJSON(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        return data
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else { throw InstallError.writeFailed("A required data directory is unsafe.") }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func isSafeRegularFile(_ url: URL, maximumBytes: Int) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]) else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? maximumBytes + 1) <= maximumBytes
    }

    private func readForwardCommand(at url: URL) -> String? {
        guard let data = fileManager.contents(atPath: url.path),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let command = root["command"] as? String,
              !command.isEmpty,
              command.count <= Self.maximumForwardCommandCharacters
        else { return nil }
        return command
    }
}
