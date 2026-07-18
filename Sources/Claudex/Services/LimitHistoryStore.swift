import CryptoKit
import Darwin
import Foundation

/// Owner-only append-only history for rate-limit observations and inferred reset events.
/// Files are daily JSONL spools so a crash cannot corrupt the rest of the history.
actor LimitHistoryStore {
    enum StoreError: Error, LocalizedError, Sendable {
        case unavailable
        case unsafePath
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unavailable: "Limit history storage is unavailable."
            case .unsafePath: "Limit history refused an unsafe file path."
            case .writeFailed: "Limit history could not be written."
            }
        }
    }

    private struct Record: Codable {
        let schemaVersion: Int
        let kind: String
        let sample: LimitUsageSample?
        let reset: LimitResetEvent?

        static func sample(_ value: LimitUsageSample) -> Record {
            Record(schemaVersion: 1, kind: "sample", sample: value, reset: nil)
        }

        static func reset(_ value: LimitResetEvent) -> Record {
            Record(schemaVersion: 1, kind: "reset", sample: nil, reset: value)
        }
    }

    private let directory: URL
    private let retentionDays: Int
    private let fileManager: FileManager
    private var loaded = false
    private var samples: [LimitUsageSample] = []
    private var resets: [LimitResetEvent] = []
    private var lastSamples: [String: LimitUsageSample] = [:]
    private var resetIDs = Set<String>()

    private static let maximumDailyFileBytes = 8 * 1024 * 1024
    private static let maximumLoadedRecords = 250_000

    init(
        directory: URL? = nil,
        retentionDays: Int = 180,
        fileManager: FileManager = .default
    ) {
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        self.retentionDays = max(7, retentionDays)
        self.fileManager = fileManager
    }

    /// Persist one observation per active window and return any newly inferred resets.
    func ingest(
        account: AccountRef,
        usage: AccountUsage,
        observedAt: Date,
        source: LimitSampleSource,
        now: Date = Date()
    ) throws -> [LimitResetEvent] {
        try ensureLoaded(now: now)
        guard observedAt <= now.addingTimeInterval(5 * 60) else { return [] }

        var detected: [LimitResetEvent] = []
        for window in usage.windows + usage.extraWindows where !window.isExpired {
            guard window.fraction.isFinite else { continue }
            let sample = LimitUsageSample(
                schemaVersion: 1,
                observedAt: observedAt,
                provider: account.provider,
                accountID: account.id,
                accountLabel: account.handle,
                windowID: window.id,
                windowLabel: window.label,
                fraction: min(1, max(0, window.fraction)),
                resetsAt: window.resetsAt,
                windowLength: normalizedWindowLength(window.windowLength),
                source: source
            )
            if let previous = lastSamples[sample.seriesID], previous.observedAt >= sample.observedAt {
                continue
            }

            let event = lastSamples[sample.seriesID].flatMap {
                Self.detectReset(previous: $0, current: sample)
            }
            try append(.sample(sample), at: observedAt)
            samples.append(sample)
            lastSamples[sample.seriesID] = sample

            if let event, resetIDs.insert(event.id).inserted {
                try append(.reset(event), at: event.detectedAt)
                resets.append(event)
                detected.append(event)
            }
        }
        try removeExpiredFiles(now: now)
        trimMemory(now: now)
        return detected
    }

    func snapshot(since: Date, now: Date = Date()) throws -> LimitHistorySnapshot {
        try ensureLoaded(now: now)
        return LimitHistorySnapshot(
            samples: samples.filter { $0.observedAt >= since && $0.observedAt <= now.addingTimeInterval(5 * 60) },
            resets: resets.filter { $0.detectedAt >= since && $0.detectedAt <= now.addingTimeInterval(5 * 60) },
            loadedAt: now
        )
    }

    func deleteHistory() throws {
        if let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           values.isDirectory == true,
           values.isSymbolicLink != true
        {
            for file in try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) where Self.isHistoryFile(file) {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                try fileManager.removeItem(at: file)
            }
        }
        samples = []
        resets = []
        lastSamples = [:]
        resetIDs = []
        loaded = true
    }

    nonisolated static func detectReset(
        previous: LimitUsageSample,
        current: LimitUsageSample
    ) -> LimitResetEvent? {
        guard previous.seriesID == current.seriesID,
              current.observedAt > previous.observedAt,
              let scheduledResetAt = previous.resetsAt,
              let newScheduledResetAt = current.resetsAt,
              newScheduledResetAt.timeIntervalSince(scheduledResetAt) >= 5 * 60,
              previous.fraction - current.fraction >= 0.01,
              current.fraction <= max(0.05, previous.fraction * 0.25)
        else { return nil }

        let length = previous.windowLength
            ?? current.windowLength
            ?? newScheduledResetAt.timeIntervalSince(current.observedAt)
        guard length.isFinite, length > 0 else { return nil }
        let cycleStart = scheduledResetAt.addingTimeInterval(-length)
        let elapsed = min(1, max(0, current.observedAt.timeIntervalSince(cycleStart) / length))
        let capacity = min(1, max(0, previous.fraction))
        let early = max(0, scheduledResetAt.timeIntervalSince(current.observedAt))
        let idMaterial = [
            previous.provider.rawValue,
            previous.accountID,
            previous.windowID,
            String(Int(scheduledResetAt.timeIntervalSince1970)),
            String(Int(newScheduledResetAt.timeIntervalSince1970)),
        ].joined(separator: "\u{0}")
        let id = SHA256.hash(data: Data(idMaterial.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return LimitResetEvent(
            schemaVersion: 1,
            id: id,
            provider: previous.provider,
            accountID: previous.accountID,
            accountLabel: previous.accountLabel,
            windowID: previous.windowID,
            windowLabel: previous.windowLabel,
            previousObservedAt: previous.observedAt,
            detectedAt: current.observedAt,
            scheduledResetAt: scheduledResetAt,
            newScheduledResetAt: newScheduledResetAt,
            windowLength: length,
            capacityRestoredFraction: capacity,
            elapsedFraction: elapsed,
            paceBonusFraction: max(0, capacity - elapsed),
            secondsEarly: early
        )
    }

    private func ensureLoaded(now: Date) throws {
        guard !loaded else { return }
        try ensurePrivateDirectory()
        try removeExpiredFiles(now: now)
        let decoder = Self.decoder()
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) ?? .distantPast
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )) ?? []
        var recordCount = 0
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where Self.isHistoryFile(file)
        {
            guard recordCount < Self.maximumLoadedRecords,
                  let values = try? file.resourceValues(forKeys: [
                      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? Self.maximumDailyFileBytes + 1) <= Self.maximumDailyFileBytes,
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe)
            else { continue }
            for line in data.split(separator: 0x0A) {
                guard recordCount < Self.maximumLoadedRecords,
                      let record = try? decoder.decode(Record.self, from: Data(line)),
                      record.schemaVersion == 1
                else { continue }
                recordCount += 1
                if let sample = record.sample,
                   sample.schemaVersion == 1,
                   sample.observedAt >= cutoff,
                   sample.observedAt <= now.addingTimeInterval(5 * 60),
                   sample.fraction.isFinite,
                   (0 ... 1).contains(sample.fraction)
                {
                    samples.append(sample)
                    if let existing = lastSamples[sample.seriesID] {
                        if existing.observedAt < sample.observedAt {
                            lastSamples[sample.seriesID] = sample
                        }
                    } else {
                        lastSamples[sample.seriesID] = sample
                    }
                }
                if let reset = record.reset,
                   reset.schemaVersion == 1,
                   reset.detectedAt >= cutoff,
                   reset.detectedAt <= now.addingTimeInterval(5 * 60),
                   resetIDs.insert(reset.id).inserted
                {
                    resets.append(reset)
                }
            }
        }
        samples.sort { $0.observedAt < $1.observedAt }
        resets.sort { $0.detectedAt < $1.detectedAt }
        loaded = true
    }

    private func append(_ record: Record, at date: Date) throws {
        try ensurePrivateDirectory()
        let destination = directory.appending(
            path: "limits-\(Self.dayFormatter.string(from: date)).jsonl",
            directoryHint: .notDirectory
        )
        var data: Data
        do {
            data = try Self.encoder().encode(record)
            data.append(0x0A)
        } catch {
            throw StoreError.writeFailed
        }

        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw StoreError.unsafePath }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw StoreError.writeFailed }
        defer { flock(descriptor, LOCK_UN) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size + off_t(data.count) <= off_t(Self.maximumDailyFileBytes)
        else { throw StoreError.writeFailed }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll else { throw StoreError.writeFailed }
        _ = fchmod(descriptor, 0o600)
    }

    private func ensurePrivateDirectory() throws {
        let parent = directory.deletingLastPathComponent()
        if let values = try? parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           values.isSymbolicLink == true || values.isDirectory == false
        {
            throw StoreError.unsafePath
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw StoreError.unsafePath
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.unavailable
        }
    }

    private func removeExpiredFiles(now: Date) throws {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        ) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) ?? .distantPast
        for file in files where Self.isHistoryFile(file) {
            guard let values = try? file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
            ]),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let modified = values.contentModificationDate,
                modified < cutoff
            else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    private func trimMemory(now: Date) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) ?? .distantPast
        samples.removeAll { $0.observedAt < cutoff }
        resets.removeAll { $0.detectedAt < cutoff }
        resetIDs = Set(resets.map(\.id))
    }

    private func normalizedWindowLength(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0, value <= 365 * 24 * 60 * 60 else {
            return nil
        }
        return value
    }

    private nonisolated static func isHistoryFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("limits-") && url.pathExtension == "jsonl"
    }

    private nonisolated static func defaultDirectory(fileManager: FileManager) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "Claudex/LimitHistory", directoryHint: .isDirectory)
    }

    private nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private nonisolated static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
