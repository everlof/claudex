import Foundation
import Testing

@Suite struct ClaudeStatusBridgeBlackBoxTests {
    @Test func bridgeAllowlistsCacheAndDoesNotReplaceItWithEmptyOrOversizedInput() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profile = "blackbox_allowlist"
        let input = Data(#"""
        {
          "version":"2.1.207",
          "cwd":"/secret/project",
          "session_id":"secret-session",
          "transcript_path":"/secret/transcript.jsonl",
          "rate_limits":{
            "five_hour":{"used_percentage":12.5,"resets_at":1783890000},
            "seven_day":{"used_percentage":41,"resets_at":1784300000}
          }
        }
        """#.utf8)

        let first = try fixture.run(arguments: ["--profile", profile], input: input)
        #expect(first.status == 0)
        let cache = fixture.cacheURL(profile: profile)
        let cached = try String(contentsOf: cache, encoding: .utf8)
        #expect(cached.contains("\"schema_version\" : 1"))
        #expect(cached.contains("\"used_percentage\" : 12.5"))
        #expect(!cached.contains("secret"))
        #expect(!cached.contains("cwd"))
        let permissions = try #require(
            try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber
        )
        #expect(permissions.intValue & 0o777 == 0o600)

        _ = try fixture.run(arguments: ["--profile", profile], input: input)
        #expect(try String(contentsOf: cache, encoding: .utf8) == cached)

        let positiveHeartbeat = try fixture.heartbeat(profile: profile)
        #expect(positiveHeartbeat["schema_version"] as? Int == 2)
        #expect(positiveHeartbeat["rate_limits_present"] as? Bool == true)
        let lastLimitsSeenAt = try #require(positiveHeartbeat["last_limits_seen_at"] as? String)

        let empty = Data(#"{"version":"2.1.207","rate_limits":{}}"#.utf8)
        _ = try fixture.run(arguments: ["--profile", profile], input: empty)
        #expect(try String(contentsOf: cache, encoding: .utf8) == cached)
        let emptyHeartbeat = try fixture.heartbeat(profile: profile)
        #expect(emptyHeartbeat["rate_limits_present"] as? Bool == false)
        #expect(emptyHeartbeat["last_limits_seen_at"] as? String == lastLimitsSeenAt)

        _ = try fixture.run(
            arguments: ["--profile", profile],
            input: Data(repeating: 0x61, count: 1_048_577)
        )
        #expect(try String(contentsOf: cache, encoding: .utf8) == cached)
    }

    @Test func bridgeForwardsExactInputOutputErrorAndExitStatus() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let script = fixture.root.appending(path: "existing-status.sh")
        try Data("#!/bin/sh\ncat\nprintf 'existing-error' >&2\nexit 37\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let forward = fixture.root.appending(path: "forward.json")
        let forwardData = try JSONSerialization.data(
            withJSONObject: ["command": "'\(script.path.replacingOccurrences(of: "'", with: "'\"'\"'"))'"]
        )
        try forwardData.write(to: forward)
        let input = Data(#"{"version":"2.1.207","rate_limits":{}}"#.utf8)

        let result = try fixture.run(
            arguments: [
                "--profile", "blackbox_forward",
                "--forward-config", forward.path,
            ],
            input: input
        )

        #expect(result.status == 37)
        #expect(result.stdout == input)
        #expect(String(data: result.stderr, encoding: .utf8) == "existing-error")
    }

    private final class Fixture {
        struct Result {
            let status: Int32
            let stdout: Data
            let stderr: Data
        }

        let root: URL
        let home: URL
        let bridge: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "claudex-bridge-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            home = root.appending(path: "home", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let cwdCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: ".build/debug/ClaudexStatusBridge")
            bridge = try #require(
                FileManager.default.isExecutableFile(atPath: cwdCandidate.path) ? cwdCandidate : nil,
                "ClaudexStatusBridge must be built beside the test products"
            )
        }

        func cacheURL(profile: String) -> URL {
            home.appending(path: "Library/Application Support/Claudex/ClaudeStatus/\(profile).json")
        }

        func heartbeat(profile: String) throws -> [String: Any] {
            let url = home.appending(
                path: "Library/Application Support/Claudex/ClaudeStatus/\(profile).heartbeat.json"
            )
            let data = try Data(contentsOf: url)
            return try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
        }

        func run(arguments: [String], input: Data) throws -> Result {
            let process = Process()
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = bridge
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            environment["CFFIXED_USER_HOME"] = home.path
            process.environment = environment
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            return Result(
                status: process.terminationStatus,
                stdout: try stdout.fileHandleForReading.readToEnd() ?? Data(),
                stderr: try stderr.fileHandleForReading.readToEnd() ?? Data()
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
