@testable import Claudex
import Foundation
import LocalAuthentication
import Security
import Testing

@Suite struct ClaudeOAuthKeychainCredentialsTests {
    @Test func requestsOnlyTheExpectedItemAndExtractsCurrentAccessMetadata() throws {
        let payload = Data(#"""
        {
          "claudeAiOauth": {
            "accessToken": "keychain-access-token",
            "refreshToken": "must-not-be-extracted",
            "expiresAt": 1893456000000,
            "subscriptionType": "pro_plan"
          }
        }
        """#.utf8)
        let olderReference = Data([0x01])
        let newerReference = Data([0x02])
        var observedQueries: [[String: Any]] = []

        let value = try ClaudeOAuthKeychainCredentials.load(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ) { query in
            observedQueries.append(query)
            if query[kSecReturnAttributes as String] as? Bool == true {
                return (errSecSuccess, [
                    [
                        kSecValuePersistentRef as String: olderReference,
                        kSecAttrModificationDate as String: Date(timeIntervalSince1970: 100),
                    ],
                    [
                        kSecValuePersistentRef as String: newerReference,
                        kSecAttrModificationDate as String: Date(timeIntervalSince1970: 200),
                    ],
                ])
            }
            return (errSecSuccess, payload)
        }

        #expect(observedQueries.count == 2)
        #expect(observedQueries[0][kSecAttrService as String] as? String == "Claude Code-credentials")
        let metadataContext = observedQueries[0][kSecUseAuthenticationContext as String] as? LAContext
        #expect(metadataContext?.interactionNotAllowed == true)
        #expect(observedQueries[1][kSecValuePersistentRef as String] as? Data == newerReference)
        #expect(observedQueries[1][kSecReturnData as String] as? Bool == true)
        let context = observedQueries[1][kSecUseAuthenticationContext as String] as? LAContext
        #expect(context?.interactionNotAllowed == false)
        #expect(context?.localizedReason.contains("read-only usage limits") == true)
        #expect(value.accessToken == "keychain-access-token")
        #expect(value.planLabel == "Pro Plan")
    }

    @Test func canceledAuthorizationHasAnExplicitError() {
        var callCount = 0
        #expect(throws: UsageError.credentialUnreadable("Keychain authorization was canceled.")) {
            try ClaudeOAuthKeychainCredentials.load(now: .distantPast) { _ in
                defer { callCount += 1 }
                return callCount == 0
                    ? (errSecSuccess, [[kSecValuePersistentRef as String: Data([0x01])]])
                    : (errSecUserCanceled, nil)
            }
        }
    }

    @Test func explainsMCPOnlyKeychainPayloads() {
        let payload = Data(#"{"mcpOAuth":{"example":{"accessToken":"unrelated"}}}"#.utf8)
        var callCount = 0

        #expect(throws: UsageError.credentialUnreadable(
            "Claude stored MCP credentials, but no Claude usage credential. Re-authenticate with Claude Code."
        )) {
            try ClaudeOAuthKeychainCredentials.load(now: .distantPast) { _ in
                defer { callCount += 1 }
                return callCount == 0
                    ? (errSecSuccess, [[kSecValuePersistentRef as String: Data([0x01])]])
                    : (errSecSuccess, payload)
            }
        }
    }
}
