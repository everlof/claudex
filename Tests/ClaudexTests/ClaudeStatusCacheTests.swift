import Foundation
import Testing
@testable import Claudex

@Suite struct ClaudeStatusCacheTests {
    @Test func decodesOnlyHeadlineWindowsAndNormalizesThem() throws {
        let data = Data(#"""
        {
          "schema_version":1,
          "observed_at":"2026-07-12T18:30:00Z",
          "claude_version":"2.1.207",
          "rate_limits":{
            "five_hour":{"used_percentage":23.5,"resets_at":1783890000},
            "seven_day":{"used_percentage":141,"resets_at":1784300000}
          },
          "cwd":"/private/project-that-must-not-be-kept",
          "session_id":"secret-session"
        }
        """#.utf8)

        let snapshot = try ClaudeStatusCache.decode(data)

        #expect(snapshot.claudeVersion == "2.1.207")
        #expect(snapshot.fiveHour?.usedPercentage == 23.5)
        #expect(snapshot.sevenDay?.usedPercentage == 100)
        #expect(snapshot.accountUsage.windows.map(\.id) == ["5h", "7d"])
        #expect(snapshot.accountUsage.extraWindows.isEmpty)
        #expect(snapshot.accountUsage.displayName == nil)
        #expect(snapshot.accountUsage.accountUUID == nil)
    }

    @Test func acceptsAnIndependentlyMissingWindow() throws {
        let data = Data(#"""
        {
          "schema_version":1,
          "observed_at":"2026-07-12T18:30:00.123Z",
          "rate_limits":{"five_hour":{"used_percentage":9,"resets_at":null}}
        }
        """#.utf8)

        let snapshot = try ClaudeStatusCache.decode(data)

        #expect(snapshot.fiveHour?.usedPercentage == 9)
        #expect(snapshot.sevenDay == nil)
        #expect(snapshot.accountUsage.windows.map(\.id) == ["5h"])
    }

    @Test func resetPassedWindowsRemainVisibleButAreNoLongerPresentedAsCurrent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = ClaudeStatusSnapshot(
            observedAt: now.addingTimeInterval(-60),
            claudeVersion: "2.1.207",
            fiveHour: .init(usedPercentage: 100, resetsAt: now.addingTimeInterval(-1)),
            sevenDay: .init(usedPercentage: 52, resetsAt: now.addingTimeInterval(86_400))
        )

        let usage = snapshot.accountUsage(at: now)

        #expect(usage.windows.map(\.id) == ["5h", "7d"])
        #expect(usage.windows.first?.isExpired == true)
        #expect(usage.windows.last?.isExpired == false)
        #expect(usage.currentHeadlineFraction == 0.52)
        #expect(usage.shortWindow?.id == "7d")
    }

    @Test func allResetPassedWindowsProduceAnUnknownHeadline() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = ClaudeStatusSnapshot(
            observedAt: now.addingTimeInterval(-60),
            claudeVersion: nil,
            fiveHour: .init(usedPercentage: 95, resetsAt: now.addingTimeInterval(-1)),
            sevenDay: nil
        )

        let usage = snapshot.accountUsage(at: now)

        #expect(usage.currentHeadlineFraction == nil)
        #expect(usage.shortWindow == nil)
        #expect(usage.severity == .normal)
    }

    @Test func rejectsCachesWithoutSubscriptionLimits() {
        let data = Data(#"""
        {
          "schema_version":1,
          "observed_at":"2026-07-12T18:30:00Z",
          "rate_limits":{}
        }
        """#.utf8)

        #expect(throws: ClaudeStatusCacheError.noRateLimits) {
            try ClaudeStatusCache.decode(data)
        }
    }

    @Test func rejectsMalformedOrMissingCache() throws {
        #expect(throws: ClaudeStatusCacheError.unreadable) {
            try ClaudeStatusCache.decode(Data("not-json".utf8))
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(throws: ClaudeStatusCacheError.missing) {
            try ClaudeStatusCache.load(profileID: "missing", directory: root)
        }
    }

    @Test func rejectsUnsupportedOversizedAndSymlinkCaches() throws {
        let unsupported = Data(#"""
        {
          "schema_version":99,
          "observed_at":"2026-07-12T18:30:00Z",
          "rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1783890000}}
        }
        """#.utf8)
        #expect(throws: ClaudeStatusCacheError.unsupportedSchema) {
            try ClaudeStatusCache.decode(
                unsupported,
                now: Date(timeIntervalSince1970: 1_783_900_100)
            )
        }
        #expect(throws: ClaudeStatusCacheError.tooLarge) {
            try ClaudeStatusCache.decode(Data(repeating: 0, count: 64 * 1_024 + 1))
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target.json")
        try unsupported.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "linked.json"),
            withDestinationURL: target
        )
        #expect(throws: ClaudeStatusCacheError.unsafeFile) {
            try ClaudeStatusCache.load(profileID: "linked", directory: root)
        }
    }

    @Test func heartbeatCarriesOnlyHealthMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data(#"""
        {
          "schema_version":1,
          "received_at":"2026-07-12T18:30:00.123Z",
          "claude_version":"2.1.207",
          "rate_limits_present":false
        }
        """#.utf8)
        try data.write(to: ClaudeStatusCache.heartbeatFileURL(
            profileID: "health",
            directory: root
        ))

        let heartbeat = try ClaudeStatusCache.loadHeartbeat(
            profileID: "health",
            directory: root,
            now: Date(timeIntervalSince1970: 1_783_900_100)
        )

        #expect(heartbeat.claudeVersion == "2.1.207")
        #expect(!heartbeat.rateLimitsPresent)
        #expect(heartbeat.lastLimitsSeenAt == nil)
    }

    @Test func schemaTwoHeartbeatCarriesForwardLastPositiveLimitsObservation() throws {
        let data = Data(#"""
        {
          "schema_version":2,
          "received_at":"2026-07-12T18:35:00.000Z",
          "claude_version":"2.1.212",
          "rate_limits_present":false,
          "last_limits_seen_at":"2026-07-12T18:30:00.000Z"
        }
        """#.utf8)

        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: ClaudeStatusCache.heartbeatFileURL(
            profileID: "health-v2",
            directory: root
        ))

        let heartbeat = try ClaudeStatusCache.loadHeartbeat(
            profileID: "health-v2",
            directory: root,
            now: Date(timeIntervalSince1970: 1_783_900_100)
        )

        #expect(!heartbeat.rateLimitsPresent)
        #expect(heartbeat.lastLimitsSeenAt == ISO8601DateFormatter().date(
            from: "2026-07-12T18:30:00Z"
        ))
    }
}
