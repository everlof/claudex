import Foundation

/// The deliberately small subset of Claude Code's status-line payload that Claudex keeps.
/// Claude Code sends substantially more session data (working directory, transcript path,
/// session id, and so on); the bridge drops all of that before writing this cache.
struct ClaudeStatusSnapshot: Sendable, Equatable {
    struct Window: Sendable, Equatable {
        let usedPercentage: Double
        let resetsAt: Date?
    }

    let observedAt: Date
    let claudeVersion: String?
    let fiveHour: Window?
    let sevenDay: Window?

    var accountUsage: AccountUsage {
        accountUsage(at: Date())
    }

    /// Reconcile passive values with the clock. Once a reported window has reset, its
    /// old percentage becomes unknown rather than zero: Claude may have been used from
    /// another device before the local status line reports again.
    func accountUsage(at now: Date) -> AccountUsage {
        var windows: [UsageWindow] = []
        if let fiveHour {
            windows.append(Self.usageWindow(
                id: "5h",
                label: "5-hour",
                value: fiveHour,
                length: 5 * 60 * 60,
                now: now
            ))
        }
        if let sevenDay {
            windows.append(Self.usageWindow(
                id: "7d",
                label: "Weekly",
                value: sevenDay,
                length: 7 * 24 * 60 * 60,
                now: now
            ))
        }
        return AccountUsage(
            planLabel: nil,
            displayName: nil,
            accountUUID: nil,
            windows: windows,
            extraWindows: [],
            resetCredits: [],
            resetCreditCount: nil
        )
    }

    private static func usageWindow(
        id: String,
        label: String,
        value: Window,
        length: TimeInterval,
        now: Date
    ) -> UsageWindow {
        let fraction = min(1, max(0, value.usedPercentage / 100))
        return UsageWindow(
            id: id,
            label: label,
            fraction: fraction,
            resetsAt: value.resetsAt,
            windowLength: length,
            scope: nil,
            severity: .from(fraction: fraction),
            isExpired: value.resetsAt.map { $0 <= now } ?? false
        )
    }
}

struct ClaudeStatusHeartbeat: Sendable, Equatable {
    let receivedAt: Date
    let claudeVersion: String?
    let rateLimitsPresent: Bool
    /// Most recent helper invocation whose payload actually contained subscription
    /// limits. Schema-1 heartbeats infer this from `receivedAt` when limits were present.
    let lastLimitsSeenAt: Date?
}

enum ClaudeStatusCacheError: Error, Sendable, Equatable, LocalizedError {
    case missing
    case unreadable
    case unsafeFile
    case tooLarge
    case invalidTimestamp
    case futureTimestamp
    case unsupportedSchema
    case noRateLimits

    var errorDescription: String? {
        switch self {
        case .missing: return "Claude Code has not sent usage yet."
        case .unreadable: return "The local Claude usage cache could not be read."
        case .unsafeFile: return "The local Claude usage cache is not a regular private file."
        case .tooLarge: return "The local Claude usage cache is unexpectedly large."
        case .invalidTimestamp: return "The local Claude usage cache has an invalid timestamp."
        case .futureTimestamp: return "The local Claude usage cache has a future timestamp."
        case .unsupportedSchema: return "The local Claude usage cache uses an unsupported format."
        case .noRateLimits: return "Claude Code did not include subscription rate limits."
        }
    }
}

enum ClaudeStatusCache {
    private static let maximumBytes = 64 * 1_024

    private struct WireSnapshot: Decodable {
        struct RateLimits: Decodable {
            struct Window: Decodable {
                let usedPercentage: Double?
                let resetsAt: Double?

                enum CodingKeys: String, CodingKey {
                    case usedPercentage = "used_percentage"
                    case resetsAt = "resets_at"
                }
            }

            let fiveHour: Window?
            let sevenDay: Window?

            enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"
                case sevenDay = "seven_day"
            }
        }

        let schemaVersion: Int
        let observedAt: String
        let claudeVersion: String?
        let rateLimits: RateLimits

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case observedAt = "observed_at"
            case claudeVersion = "claude_version"
            case rateLimits = "rate_limits"
        }
    }

    private struct WireHeartbeat: Decodable {
        let schemaVersion: Int
        let receivedAt: String
        let claudeVersion: String?
        let rateLimitsPresent: Bool
        let lastLimitsSeenAt: String?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case receivedAt = "received_at"
            case claudeVersion = "claude_version"
            case rateLimitsPresent = "rate_limits_present"
            case lastLimitsSeenAt = "last_limits_seen_at"
        }
    }

    static func directory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return base
            .appending(path: "Claudex", directoryHint: .isDirectory)
            .appending(path: "ClaudeStatus", directoryHint: .isDirectory)
    }

    static func fileURL(
        profileID: String,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        (directory ?? self.directory(fileManager: fileManager))
            .appending(path: "\(profileID).json", directoryHint: .notDirectory)
    }

    static func heartbeatFileURL(
        profileID: String,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        (directory ?? self.directory(fileManager: fileManager))
            .appending(path: "\(profileID).heartbeat.json", directoryHint: .notDirectory)
    }

    static func load(
        profileID: String,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws(ClaudeStatusCacheError) -> ClaudeStatusSnapshot {
        let url = fileURL(profileID: profileID, directory: directory, fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else { throw .missing }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { throw .unsafeFile }
        guard (values.fileSize ?? Self.maximumBytes + 1) <= Self.maximumBytes else {
            throw .tooLarge
        }
        guard let data = fileManager.contents(atPath: url.path) else { throw .unreadable }
        return try decode(data)
    }

    static func decode(
        _ data: Data,
        now: Date = Date()
    ) throws(ClaudeStatusCacheError) -> ClaudeStatusSnapshot {
        guard data.count <= Self.maximumBytes else { throw .tooLarge }
        let wire: WireSnapshot
        do {
            wire = try JSONDecoder().decode(WireSnapshot.self, from: data)
        } catch {
            throw .unreadable
        }

        guard wire.schemaVersion == 1 else { throw .unsupportedSchema }
        guard let observedAt = parseISO8601(wire.observedAt) else { throw .invalidTimestamp }
        guard observedAt <= now.addingTimeInterval(5 * 60) else { throw .futureTimestamp }
        let fiveHour = makeWindow(wire.rateLimits.fiveHour)
        let sevenDay = makeWindow(wire.rateLimits.sevenDay)
        guard fiveHour != nil || sevenDay != nil else { throw .noRateLimits }

        return ClaudeStatusSnapshot(
            observedAt: observedAt,
            claudeVersion: sanitizedVersion(wire.claudeVersion),
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )
    }

    static func loadHeartbeat(
        profileID: String,
        directory: URL? = nil,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws(ClaudeStatusCacheError) -> ClaudeStatusHeartbeat {
        let url = heartbeatFileURL(
            profileID: profileID,
            directory: directory,
            fileManager: fileManager
        )
        let data = try readSafeData(at: url, fileManager: fileManager)
        let wire: WireHeartbeat
        do {
            wire = try JSONDecoder().decode(WireHeartbeat.self, from: data)
        } catch {
            throw .unreadable
        }
        guard wire.schemaVersion == 1 || wire.schemaVersion == 2 else { throw .unsupportedSchema }
        guard let receivedAt = parseISO8601(wire.receivedAt) else { throw .invalidTimestamp }
        guard receivedAt <= now.addingTimeInterval(5 * 60) else { throw .futureTimestamp }
        let explicitLastLimitsSeenAt: Date?
        if let value = wire.lastLimitsSeenAt {
            guard let parsed = parseISO8601(value) else { throw .invalidTimestamp }
            guard parsed <= now.addingTimeInterval(5 * 60), parsed <= receivedAt else {
                throw .futureTimestamp
            }
            explicitLastLimitsSeenAt = parsed
        } else {
            explicitLastLimitsSeenAt = nil
        }
        return ClaudeStatusHeartbeat(
            receivedAt: receivedAt,
            claudeVersion: sanitizedVersion(wire.claudeVersion),
            rateLimitsPresent: wire.rateLimitsPresent,
            lastLimitsSeenAt: explicitLastLimitsSeenAt
                ?? (wire.rateLimitsPresent ? receivedAt : nil)
        )
    }

    private static func makeWindow(_ wire: WireSnapshot.RateLimits.Window?) -> ClaudeStatusSnapshot.Window? {
        guard let wire,
              let usedPercentage = wire.usedPercentage,
              usedPercentage.isFinite
        else { return nil }
        let reset = wire.resetsAt.flatMap { value in
            value.isFinite && value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        return ClaudeStatusSnapshot.Window(
            usedPercentage: min(100, max(0, usedPercentage)),
            resetsAt: reset
        )
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func sanitizedVersion(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.count <= 128,
              value.unicodeScalars.allSatisfy({
                  $0.isASCII && !CharacterSet.controlCharacters.contains($0)
              })
        else { return nil }
        return value
    }

    private static func readSafeData(
        at url: URL,
        fileManager: FileManager
    ) throws(ClaudeStatusCacheError) -> Data {
        guard fileManager.fileExists(atPath: url.path) else { throw .missing }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { throw .unsafeFile }
        guard (values.fileSize ?? Self.maximumBytes + 1) <= Self.maximumBytes else {
            throw .tooLarge
        }
        guard let data = fileManager.contents(atPath: url.path) else { throw .unreadable }
        return data
    }
}
