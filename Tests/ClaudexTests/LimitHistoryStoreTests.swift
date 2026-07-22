@testable import Claudex
import Foundation
import Testing

@Suite("Limit history")
struct LimitHistoryStoreTests {
    @Test func detectsAnEarlyRolloverAndQuantifiesTheGain() throws {
        let cycleStart = Date(timeIntervalSince1970: 1_800_000_000)
        let length = 7 * 24 * 60 * 60.0
        let scheduled = cycleStart.addingTimeInterval(length)
        let detected = cycleStart.addingTimeInterval(length * 0.61)
        let previous = Self.sample(
            at: detected.addingTimeInterval(-5 * 60),
            fraction: 0.72,
            resetsAt: scheduled,
            windowLength: length
        )
        let current = Self.sample(
            at: detected,
            fraction: 0.02,
            resetsAt: detected.addingTimeInterval(length),
            windowLength: length
        )

        let event = try #require(LimitHistoryStore.detectReset(previous: previous, current: current))
        #expect(event.capacityRestoredFraction == 0.72)
        #expect(abs(event.elapsedFraction - 0.61) < 0.000_001)
        #expect(abs(event.paceBonusFraction - 0.11) < 0.000_001)
        #expect(event.secondsEarly == scheduled.timeIntervalSince(detected))
        #expect(event.isEarly)
        #expect(event.windowLength == length)

        let message = ResetNotifier.earlyResetMessage(event)
        #expect(message.title.contains("Codex"))
        #expect(message.body.contains("72% used"))
        #expect(message.body.contains("11 points above linear pace"))
    }

    @Test func ignoresAUsageCorrectionWithoutAResetRollover() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(60 * 60)
        let previous = Self.sample(at: now, fraction: 0.72, resetsAt: reset)
        let current = Self.sample(at: now.addingTimeInterval(60), fraction: 0.02, resetsAt: reset)

        #expect(LimitHistoryStore.detectReset(previous: previous, current: current) == nil)
    }

    @Test func chartDownsamplingBoundsMarksAndPreservesEndpointsAndExtrema() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let spike = 1_234
        let trough = 1_235
        let samples = (0 ..< 3_600).map { index in
            let fraction: Double = switch index {
            case spike: 0.99
            case trough: 0.01
            default: 0.4
            }
            return Self.sample(
                at: start.addingTimeInterval(TimeInterval(index * 60)),
                fraction: fraction,
                resetsAt: reset
            )
        }

        let reduced = LimitHistoryViewStore.downsampleForChart(samples)

        #expect(reduced.count <= 600)
        #expect(reduced.first == samples.first)
        #expect(reduced.last == samples.last)
        #expect(reduced.contains(samples[spike]))
        #expect(reduced.contains(samples[trough]))
    }

    @Test func hidesLegacyClaudeSciencePseudoAccountSamples() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appending(path: "ClaudexLimitHistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: directory) }
        let now = Date()
        let store = LimitHistoryStore(directory: directory)
        let account = AccountRef(
            provider: .claude,
            handle: "claude-science",
            source: .claudeConfigDir(path: "/not-an-account")
        )
        _ = try await store.ingest(
            account: account,
            usage: Self.usage(
                fraction: 0.42,
                resetsAt: now.addingTimeInterval(5 * 60 * 60),
                windowLength: 5 * 60 * 60
            ),
            observedAt: now,
            source: .claudeStatusLine,
            now: now
        )

        let snapshot = try await store.snapshot(since: now.addingTimeInterval(-60), now: now)
        #expect(snapshot.samples.isEmpty)
        #expect(snapshot.series.isEmpty)
    }

    @Test func persistsOwnerOnlyJSONLAndReloadsIt() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appending(path: "ClaudexLimitHistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: directory) }
        let account = AccountRef(
            provider: .codex,
            handle: "test-account",
            source: .codexAuthFile(path: "/never-persist-this/auth.json")
        )
        let length = 5 * 60 * 60.0
        let cycleStart = Date().addingTimeInterval(-length * 0.7)
        let scheduled = cycleStart.addingTimeInterval(length)
        let firstAt = cycleStart.addingTimeInterval(length * 0.7)
        let first = Self.usage(fraction: 0.8, resetsAt: scheduled, windowLength: length)
        let secondAt = firstAt.addingTimeInterval(60)
        let second = Self.usage(
            fraction: 0,
            resetsAt: secondAt.addingTimeInterval(length),
            windowLength: length
        )

        let store = LimitHistoryStore(directory: directory)
        #expect(try await store.ingest(
            account: account,
            usage: first,
            observedAt: firstAt,
            source: .codexAPI,
            now: secondAt
        ).isEmpty)
        #expect(try await store.ingest(
            account: account,
            usage: second,
            observedAt: secondAt,
            source: .codexAPI,
            now: secondAt
        ).count == 1)

        let reloaded = LimitHistoryStore(directory: directory)
        let snapshot = try await reloaded.snapshot(
            since: cycleStart,
            now: secondAt.addingTimeInterval(60)
        )
        #expect(snapshot.samples.count == 2)
        #expect(snapshot.resets.count == 1)

        let directoryMode = try #require(
            fileManager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        )
        #expect(directoryMode.intValue & 0o777 == 0o700)
        let historyFile = try #require(
            fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        let fileMode = try #require(
            fileManager.attributesOfItem(atPath: historyFile.path)[.posixPermissions] as? NSNumber
        )
        #expect(fileMode.intValue & 0o777 == 0o600)
        let contents = try String(contentsOf: historyFile, encoding: .utf8)
        #expect(!contents.contains("never-persist-this"))

        try await reloaded.deleteHistory()
        #expect(try await reloaded.snapshot(since: cycleStart, now: secondAt).samples.isEmpty)
    }

    private static func sample(
        at observedAt: Date,
        fraction: Double,
        resetsAt: Date,
        windowLength: TimeInterval = 7 * 24 * 60 * 60
    ) -> LimitUsageSample {
        LimitUsageSample(
            schemaVersion: 1,
            observedAt: observedAt,
            provider: .codex,
            accountID: "codex:test-account",
            accountLabel: "test-account",
            windowID: "week",
            windowLabel: "Weekly",
            fraction: fraction,
            resetsAt: resetsAt,
            windowLength: windowLength,
            source: .codexAPI
        )
    }

    private static func usage(
        fraction: Double,
        resetsAt: Date,
        windowLength: TimeInterval
    ) -> AccountUsage {
        AccountUsage(
            planLabel: nil,
            displayName: nil,
            accountUUID: nil,
            windows: [UsageWindow(
                id: "5h",
                label: "5-hour",
                fraction: fraction,
                resetsAt: resetsAt,
                windowLength: windowLength,
                scope: nil,
                severity: .from(fraction: fraction)
            )],
            extraWindows: [],
            resetCredits: [],
            resetCreditCount: nil
        )
    }
}
