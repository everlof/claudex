import Foundation

/// A deliberately narrow reader for Claude Code's optional credentials file.
///
/// It never queries Keychain, refreshes a token, or writes the file. Secret material is
/// returned only to `UsageService` and must not enter observable app state or diagnostics.
enum ClaudeOAuthFileCredentials {
    struct Value: Sendable, Equatable {
        let accessToken: String
        let planLabel: String?
    }

    private struct Root: Decodable {
        let claudeAiOauth: OAuth?
    }

    private struct OAuth: Decodable {
        let accessToken: String?
        let expiresAt: Double?
        let subscriptionType: String?
    }

    static func load(for ref: AccountRef, now: Date = Date()) throws(UsageError) -> Value {
        guard case let .claudeConfigDir(path) = ref.source else { throw .noCredential }
        return try load(
            from: URL(fileURLWithPath: path, isDirectory: true)
                .appending(path: ".credentials.json", directoryHint: .notDirectory),
            now: now
        )
    }

    static func load(from url: URL, now: Date = Date()) throws(UsageError) -> Value {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            throw .noCredential
        } catch {
            throw .credentialUnreadable("Claude credentials file could not be inspected.")
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw .credentialUnreadable("Claude credentials file is not a regular file.")
        }
        guard let size = values.fileSize, size > 0, size <= 64 * 1024 else {
            throw .credentialUnreadable("Claude credentials file has an unexpected size.")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw .credentialUnreadable("Claude credentials file could not be read.")
        }

        let root: Root
        do {
            root = try JSONDecoder().decode(Root.self, from: data)
        } catch {
            throw .credentialUnreadable("Claude credentials file has an unexpected format.")
        }
        guard let oauth = root.claudeAiOauth else { throw .noCredential }
        let accessToken = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accessToken.isEmpty, accessToken.count <= 16384 else {
            throw .credentialUnreadable("Claude OAuth access token is missing or malformed.")
        }
        guard let milliseconds = oauth.expiresAt, milliseconds.isFinite else {
            throw .tokenExpired
        }
        let expiresAt = Date(timeIntervalSince1970: milliseconds / 1000)
        guard expiresAt > now.addingTimeInterval(30) else { throw .tokenExpired }

        return Value(
            accessToken: accessToken,
            planLabel: normalizedPlanLabel(oauth.subscriptionType)
        )
    }

    private static func normalizedPlanLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        return trimmed.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
