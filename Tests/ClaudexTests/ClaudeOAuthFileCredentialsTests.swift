@testable import Claudex
import Foundation
import Testing

@Suite struct ClaudeOAuthFileCredentialsTests {
    @Test func readsOnlyCurrentFileCredentialMetadata() throws {
        let file = try credentialFile(#"""
        {
          "claudeAiOauth": {
            "accessToken": "test-access-token",
            "refreshToken": "must-not-be-used",
            "expiresAt": 1893456000000,
            "subscriptionType": "max_plan"
          }
        }
        """#)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let value = try ClaudeOAuthFileCredentials.load(
            from: file,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(value.accessToken == "test-access-token")
        #expect(value.planLabel == "Max Plan")
    }

    @Test func rejectsExpiredAndSymlinkedCredentialFiles() throws {
        let expired = try credentialFile(#"""
        {"claudeAiOauth":{"accessToken":"expired","expiresAt":1000}}
        """#)
        defer { try? FileManager.default.removeItem(at: expired.deletingLastPathComponent()) }
        #expect(throws: UsageError.tokenExpired) {
            try ClaudeOAuthFileCredentials.load(from: expired, now: Date())
        }

        let link = expired.deletingLastPathComponent().appending(path: "linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: expired)
        #expect(throws: UsageError.credentialUnreadable(
            "Claude credentials file is not a regular file."
        )) {
            try ClaudeOAuthFileCredentials.load(from: link, now: .distantPast)
        }
    }

    private func credentialFile(_ json: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: ".credentials.json")
        try Data(json.utf8).write(to: file)
        return file
    }
}
