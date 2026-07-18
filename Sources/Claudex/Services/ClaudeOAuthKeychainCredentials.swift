import Foundation
import LocalAuthentication
import Security

/// Reads Claude Code's ambient OAuth credential only after a dedicated user action.
///
/// The access token is returned to `UsageStore` for in-memory use. This reader never
/// stores it, extracts the refresh token into a model, refreshes credentials, or runs from
/// background refresh paths.
enum ClaudeOAuthKeychainCredentials {
    static let service = "Claude Code-credentials"

    private struct Candidate {
        let persistentReference: Data
        let modifiedAt: Date?
        let createdAt: Date?

        var sortDate: Date { modifiedAt ?? createdAt ?? .distantPast }
    }

    static func load(now: Date = Date()) throws(UsageError) -> ClaudeOAuthFileCredentials.Value {
        try load(now: now) { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        }
    }

    /// Injection seam keeps tests away from the user's real Keychain.
    static func load(
        now: Date,
        copyMatching: ([String: Any]) -> (OSStatus, Any?)
    ) throws(UsageError) -> ClaudeOAuthFileCredentials.Value {
        let noInteractionContext = LAContext()
        noInteractionContext.interactionNotAllowed = true
        let candidateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecUseAuthenticationContext as String: noInteractionContext,
        ]
        let (candidateStatus, candidateResult) = copyMatching(candidateQuery)

        let candidate: Candidate?
        if candidateStatus == errSecSuccess {
            candidate = candidates(from: candidateResult).max { $0.sortDate < $1.sortDate }
        } else {
            candidate = nil
        }

        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = false
        authenticationContext.localizedReason =
            "Claudex needs Claude's current access token to fetch read-only usage limits."
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: authenticationContext,
        ]
        if let candidate {
            query[kSecValuePersistentRef as String] = candidate.persistentReference
        } else {
            // Older Keychain layouts or unavailable metadata probes still get one
            // explicitly interactive, service-scoped attempt after the user's click.
            query[kSecAttrService as String] = service
        }
        let (status, data) = copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data = data as? Data else {
                throw .credentialUnreadable("Claude's Keychain item returned no data.")
            }
            return try ClaudeOAuthFileCredentials.load(data: data, now: now)
        case errSecItemNotFound:
            throw .noCredential
        case errSecUserCanceled:
            throw .credentialUnreadable("Keychain authorization was canceled.")
        case errSecAuthFailed, errSecNoAccessForItem, errSecInteractionNotAllowed:
            throw .credentialUnreadable("Keychain access was denied.")
        default:
            throw .credentialUnreadable("Keychain could not read Claude's credential (OSStatus \(status)).")
        }
    }

    private static func candidates(from result: Any?) -> [Candidate] {
        let rows: [[String: Any]]
        if let many = result as? [[String: Any]] {
            rows = many
        } else if let one = result as? [String: Any] {
            rows = [one]
        } else {
            rows = []
        }
        return rows.compactMap { row in
            guard let persistentReference = row[kSecValuePersistentRef as String] as? Data else {
                return nil
            }
            return Candidate(
                persistentReference: persistentReference,
                modifiedAt: row[kSecAttrModificationDate as String] as? Date,
                createdAt: row[kSecAttrCreationDate as String] as? Date
            )
        }
    }
}
