import CoreFoundation
import CryptoKit
import Darwin
import Foundation

private let maximumInputBytes = 1_048_576
private let maximumForwardConfigBytes = 65_536
private let maximumCommandCharacters = 16_384
private let maximumProfileCharacters = 128
private let maximumVersionCharacters = 128
private let maximumActivityLogBytes = 1_048_576
private let maximumActivityStringCharacters = 240

private struct Options {
    let profile: String?
    let forwardConfigPath: String?
    let error: String?

    static func parse(_ arguments: [String]) -> Options {
        var profile: String?
        var forwardConfigPath: String?
        var error: String?
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--profile":
                guard index + 1 < arguments.count else {
                    error = "--profile requires a value"
                    break
                }
                profile = arguments[index + 1]
                index += 2
            case "--forward-config":
                guard index + 1 < arguments.count else {
                    error = "--forward-config requires a value"
                    break
                }
                forwardConfigPath = arguments[index + 1]
                index += 2
            case "--help", "-h":
                error = "help"
                index += 1
            default:
                error = "unknown argument: \(arguments[index])"
                index += 1
            }

            if error != nil { break }
        }

        return Options(profile: profile, forwardConfigPath: forwardConfigPath, error: error)
    }
}

private struct ActivityOptions {
    let provider: String?
    let account: String?
    let error: String?

    static func parse(_ arguments: [String]) -> ActivityOptions {
        var provider: String?
        var account: String?
        var error: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--provider":
                guard index + 1 < arguments.count else {
                    error = "--provider requires a value"
                    break
                }
                provider = arguments[index + 1]
                index += 2
            case "--account":
                guard index + 1 < arguments.count else {
                    error = "--account requires a value"
                    break
                }
                account = arguments[index + 1]
                index += 2
            case "--help", "-h":
                error = "help"
                index += 1
            default:
                error = "unknown activity argument: \(arguments[index])"
                index += 1
            }
            if error != nil { break }
        }
        return ActivityOptions(provider: provider, account: account, error: error)
    }
}

private struct LimitWindow: Encodable {
    let usedPercentage: Double?
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    var containsValue: Bool {
        usedPercentage != nil || resetsAt != nil
    }
}

private struct RateLimits: Encodable {
    let fiveHour: LimitWindow?
    let sevenDay: LimitWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    var containsValue: Bool {
        fiveHour != nil || sevenDay != nil
    }
}

private struct CacheSnapshot: Encodable {
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

private struct HeartbeatSnapshot: Encodable {
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

private struct ParsedStatus {
    let claudeVersion: String?
    let rateLimits: RateLimits?
}

private final class ForwardedCommand {
    private let process: Process
    private let input: FileHandle
    private var acceptsInput = true

    init?(command: String) {
        let process = Process()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            return nil
        }

        self.process = process
        self.input = inputPipe.fileHandleForWriting
    }

    func write(_ data: Data) {
        guard acceptsInput else { return }
        do {
            try input.write(contentsOf: data)
        } catch {
            acceptsInput = false
            try? input.close()
        }
    }

    func finish() -> Int32 {
        if acceptsInput {
            try? input.close()
            acceptsInput = false
        }
        process.waitUntilExit()

        switch process.terminationReason {
        case .exit:
            return process.terminationStatus
        case .uncaughtSignal:
            return min(255, 128 + process.terminationStatus)
        @unknown default:
            return 1
        }
    }
}

private struct CapturedInput {
    let data: Data?
}

private func captureStandardInput(forwardingTo command: ForwardedCommand?) -> CapturedInput {
    var captured = Data()
    var exceededLimit = false

    while true {
        let chunk: Data
        do {
            guard let next = try FileHandle.standardInput.read(upToCount: 65_536), !next.isEmpty else {
                break
            }
            chunk = next
        } catch {
            exceededLimit = true
            captured.removeAll(keepingCapacity: false)
            break
        }

        // The original bytes are streamed unchanged to the previous status-line command.
        // Only the bounded prefix is retained locally for parsing.
        command?.write(chunk)
        if !exceededLimit, captured.count <= maximumInputBytes - chunk.count {
            captured.append(chunk)
        } else if !exceededLimit {
            exceededLimit = true
            captured.removeAll(keepingCapacity: false)
        }
    }

    return CapturedInput(data: exceededLimit ? nil : captured)
}

private func validProfile(_ profile: String?) -> String? {
    guard let profile,
          !profile.isEmpty,
          profile.count <= maximumProfileCharacters
    else { return nil }

    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    guard profile.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
    return profile
}

private func forwardCommand(at path: String?) -> String? {
    guard let path, (path as NSString).isAbsolutePath else { return nil }
    let url = URL(fileURLWithPath: path, isDirectory: false)

    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true,
          values.isSymbolicLink != true,
          let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? NSNumber,
          size.intValue <= maximumForwardConfigBytes,
          let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
          data.count <= maximumForwardConfigBytes,
          let object = try? JSONSerialization.jsonObject(with: data),
          let root = object as? [String: Any]
    else { return nil }

    let direct = root["command"] as? String
    let nested = (root["statusLine"] as? [String: Any])?["command"] as? String
    guard let command = direct ?? nested,
          !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          command.count <= maximumCommandCharacters
    else { return nil }

    return command
}

private func parsedStatus(from data: Data?) -> ParsedStatus? {
    guard let data,
          !data.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: data),
          let root = object as? [String: Any]
    else { return nil }

    let version = sanitizedVersion(root["version"])
    let rateLimitsObject = root["rate_limits"] as? [String: Any]
    let fiveHour = parsedWindow(rateLimitsObject?["five_hour"])
    let sevenDay = parsedWindow(rateLimitsObject?["seven_day"])
    let rateLimits = RateLimits(fiveHour: fiveHour, sevenDay: sevenDay)

    return ParsedStatus(
        claudeVersion: version,
        rateLimits: rateLimits.containsValue ? rateLimits : nil
    )
}

private func parsedWindow(_ value: Any?) -> LimitWindow? {
    guard let object = value as? [String: Any] else { return nil }

    let usedPercentage = finiteNumber(object["used_percentage"]).flatMap {
        (0 ... 100).contains($0) ? $0 : nil
    }
    let resetsAt = finiteNumber(object["resets_at"]).flatMap {
        $0 >= 0 ? $0 : nil
    }
    let window = LimitWindow(usedPercentage: usedPercentage, resetsAt: resetsAt)
    return window.containsValue ? window : nil
}

private func finiteNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }

    let result = number.doubleValue
    return result.isFinite ? result : nil
}

private func sanitizedVersion(_ value: Any?) -> String? {
    let controlCharacters = CharacterSet.controlCharacters
    guard let version = value as? String,
          !version.isEmpty,
          version.count <= maximumVersionCharacters,
          version.unicodeScalars.allSatisfy({ $0.isASCII && !controlCharacters.contains($0) })
    else { return nil }
    return version
}

private func writeCache(_ status: ParsedStatus, profile: String) {
    guard let rateLimits = status.rateLimits, rateLimits.containsValue else { return }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let snapshot = CacheSnapshot(
        schemaVersion: 1,
        observedAt: formatter.string(from: Date()),
        claudeVersion: status.claudeVersion,
        rateLimits: rateLimits
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard var data = try? encoder.encode(snapshot) else { return }
    data.append(0x0A)

    let fileManager = FileManager.default
    guard let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first else { return }

    let claudexDirectory = applicationSupport.appendingPathComponent("Claudex", isDirectory: true)
    let statusDirectory = claudexDirectory.appendingPathComponent("ClaudeStatus", isDirectory: true)
    let destination = statusDirectory.appendingPathComponent("\(profile).json", isDirectory: false)

    do {
        try ensureApplicationSupportDirectory(applicationSupport, fileManager: fileManager)
        try ensurePrivateDirectory(claudexDirectory, fileManager: fileManager)
        try ensurePrivateDirectory(statusDirectory, fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
        }
        // Status-line commands can rerun for timers, vim toggles, and permission changes
        // without a new Claude response. Do not renew usage freshness unless the actual
        // limit values changed; a separate heartbeat records that the helper ran.
        if cachedRateLimitsEqual(rateLimits, at: destination) { return }
        try data.write(to: destination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    } catch {
        // The status line must remain usable even when the optional cache cannot be written.
    }
}

private func writeHeartbeat(_ status: ParsedStatus, profile: String) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let now = formatter.string(from: Date())
    let fileManager = FileManager.default
    guard let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first else { return }
    let claudexDirectory = applicationSupport.appendingPathComponent("Claudex", isDirectory: true)
    let statusDirectory = claudexDirectory.appendingPathComponent("ClaudeStatus", isDirectory: true)
    let destination = statusDirectory.appendingPathComponent("\(profile).heartbeat.json", isDirectory: false)
    let hasRateLimits = status.rateLimits?.containsValue == true
    let heartbeat = HeartbeatSnapshot(
        schemaVersion: 2,
        receivedAt: now,
        claudeVersion: status.claudeVersion,
        rateLimitsPresent: hasRateLimits,
        lastLimitsSeenAt: hasRateLimits ? now : cachedLastLimitsSeenAt(at: destination)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard var data = try? encoder.encode(heartbeat) else { return }
    data.append(0x0A)

    do {
        try ensureApplicationSupportDirectory(applicationSupport, fileManager: fileManager)
        try ensurePrivateDirectory(claudexDirectory, fileManager: fileManager)
        try ensurePrivateDirectory(statusDirectory, fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
        }
        try data.write(to: destination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    } catch {
        // Diagnostics heartbeat is best-effort and must not affect status-line output.
    }
}

/// Preserve the last positive observation when a later status-line event is emitted before
/// the session's first API response. This reads only the bridge's own bounded heartbeat.
private func cachedLastLimitsSeenAt(at url: URL) -> String? {
    guard let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ]),
          values.isRegularFile == true,
          values.isSymbolicLink != true,
          (values.fileSize ?? maximumInputBytes + 1) <= maximumInputBytes,
          let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    if let value = root["last_limits_seen_at"] as? String, validISOTimestamp(value) {
        return value
    }
    if (root["rate_limits_present"] as? Bool) == true,
       let value = root["received_at"] as? String,
       validISOTimestamp(value) {
        return value
    }
    return nil
}

private func cachedRateLimitsEqual(_ rateLimits: RateLimits, at url: URL) -> Bool {
    guard let existing = try? Data(contentsOf: url),
          existing.count <= 65_536,
          let existingRoot = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
          (existingRoot["schema_version"] as? NSNumber)?.intValue == 1,
          let observedAt = existingRoot["observed_at"] as? String,
          validISOTimestamp(observedAt),
          let oldLimits = existingRoot["rate_limits"],
          let newData = try? JSONEncoder().encode(rateLimits),
          let newLimits = try? JSONSerialization.jsonObject(with: newData)
    else { return false }
    return (oldLimits as AnyObject).isEqual(newLimits)
}

private func validISOTimestamp(_ value: String) -> Bool {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) != nil || ISO8601DateFormatter().date(from: value) != nil
}

private func ensureApplicationSupportDirectory(_ url: URL, fileManager: FileManager) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard isDirectory.boolValue,
              values.isDirectory == true,
              values.isSymbolicLink != true
        else {
            throw CocoaError(.fileWriteFileExists)
        }
        return
    }

    // A normal macOS home already has Library/Application Support. Creating the
    // standard parent makes the helper robust in fresh or isolated home folders;
    // owner-only umask is already active and existing parent permissions are untouched.
    try fileManager.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
}

private func ensurePrivateDirectory(_ url: URL, fileManager: FileManager) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard isDirectory.boolValue,
              values.isDirectory == true,
              values.isSymbolicLink != true
        else {
            throw CocoaError(.fileWriteFileExists)
        }
    } else {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

// MARK: - Opt-in Activity Map hook bridge

private struct ActivityResourceRecord: Encodable, Hashable {
    let path: String
    let action: String
}

private struct ActivityRecord: Encodable {
    let schemaVersion: Int
    let id: String
    let observedAt: String
    let provider: String
    let accountKey: String
    let sessionKey: String
    let turnKey: String?
    let agentKey: String?
    let projectKey: String
    let projectLabel: String
    let kind: String
    let toolName: String?
    let toolCategory: String?
    let outcome: String
    let resources: [ActivityResourceRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case observedAt = "observed_at"
        case provider
        case accountKey = "account_key"
        case sessionKey = "session_key"
        case turnKey = "turn_key"
        case agentKey = "agent_key"
        case projectKey = "project_key"
        case projectLabel = "project_label"
        case kind
        case toolName = "tool_name"
        case toolCategory = "tool_category"
        case outcome
        case resources
    }
}

private func activityRecord(
    from data: Data?,
    provider: String,
    account: String
) -> ActivityRecord? {
    guard let data,
          !data.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: data),
          let root = object as? [String: Any],
          let rawSession = root["session_id"] as? String,
          !rawSession.isEmpty,
          let eventName = sanitizedActivityString(root["hook_event_name"] as? String, maximum: 80)
    else { return nil }

    let cwd = (root["cwd"] as? String).flatMap(validAbsoluteActivityPath)
    let projectLabel = cwd
        .map { URL(fileURLWithPath: $0, isDirectory: true).lastPathComponent }
        .flatMap { sanitizedActivityString($0, maximum: 80) }
        ?? "Unknown project"
    let projectKey = activityHash(cwd ?? "unknown-project")
    let toolName = sanitizedActivityString(root["tool_name"] as? String, maximum: 128)
    let category = activityToolCategory(toolName: toolName, eventName: eventName)
    let event = activityEvent(eventName)
    let resources = activityResources(
        toolName: toolName,
        toolInput: root["tool_input"] as? [String: Any],
        cwd: cwd
    )

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return ActivityRecord(
        schemaVersion: 1,
        id: UUID().uuidString.lowercased(),
        observedAt: formatter.string(from: Date()),
        provider: provider,
        accountKey: account,
        sessionKey: activityHash(rawSession),
        turnKey: (root["turn_id"] as? String).flatMap { $0.isEmpty ? nil : activityHash($0) },
        agentKey: (root["agent_id"] as? String).flatMap { $0.isEmpty ? nil : activityHash($0) },
        projectKey: projectKey,
        projectLabel: projectLabel,
        kind: event.kind,
        toolName: toolName ?? (category == "agent" ? "Subagent" : nil),
        toolCategory: category,
        outcome: event.outcome,
        resources: resources
    )
}

private func activityEvent(_ eventName: String) -> (kind: String, outcome: String) {
    switch eventName.lowercased() {
    case "sessionstart": return ("session_start", "started")
    case "sessionend", "stop": return ("session_end", "stopped")
    case "posttooluse": return ("tool_completed", "succeeded")
    case "posttoolusefailure": return ("tool_failed", "failed")
    case "permissionrequest", "permissiondenied": return ("permission_requested", "requested")
    case "subagentstart": return ("subagent_start", "started")
    case "subagentstop": return ("subagent_stop", "stopped")
    default: return ("other", "observed")
    }
}

private func activityToolCategory(toolName: String?, eventName: String) -> String? {
    if eventName.caseInsensitiveCompare("SubagentStart") == .orderedSame
        || eventName.caseInsensitiveCompare("SubagentStop") == .orderedSame {
        return "agent"
    }
    guard let toolName else { return nil }
    let value = toolName.lowercased()
    if value.hasPrefix("mcp__") { return "mcp" }
    if value.contains("read") || value == "view_image" { return "read" }
    if value.contains("edit") || value.contains("write") || value == "apply_patch" { return "edit" }
    if value.contains("grep") || value.contains("glob") || value.contains("search") || value == "find" { return "search" }
    if value.contains("bash") || value.contains("shell") || value.contains("exec") { return "shell" }
    if value.contains("web") || value.contains("browser") || value.contains("fetch") { return "web" }
    if value.contains("agent") || value.contains("task") { return "agent" }
    if value.contains("ask") || value.contains("permission") { return "interaction" }
    return "other"
}

private func activityResources(
    toolName: String?,
    toolInput: [String: Any]?,
    cwd: String?
) -> [ActivityResourceRecord] {
    guard let toolName, let toolInput, let cwd else { return [] }
    let category = activityToolCategory(toolName: toolName, eventName: "")
    let action: String
    switch category {
    case "read": action = "read"
    case "edit": action = "write"
    case "search": action = "search"
    default: return [] // In particular, never retain shell or MCP arguments.
    }

    var candidates: [String] = []
    for key in ["file_path", "path", "notebook_path"] {
        if let value = toolInput[key] as? String { candidates.append(value) }
    }
    if let values = toolInput["paths"] as? [String] { candidates.append(contentsOf: values) }

    // Codex file edits arrive as an apply_patch command. Keep only its explicit file
    // headers; patch bodies and every other command string are discarded.
    if toolName == "apply_patch", let patch = toolInput["command"] as? String {
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: "]
            where line.hasPrefix(prefix) {
                candidates.append(String(line.dropFirst(prefix.count)))
            }
        }
    }

    var seen = Set<String>()
    return candidates.compactMap { candidate in
        guard let relative = safeRelativeActivityPath(candidate, cwd: cwd),
              seen.insert(relative).inserted
        else { return nil }
        return ActivityResourceRecord(path: relative, action: action)
    }
}

private func safeRelativeActivityPath(_ candidate: String, cwd: String) -> String? {
    guard !candidate.isEmpty,
          candidate.count <= 4_096,
          !candidate.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }

    let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
    let candidateURL: URL
    if (candidate as NSString).isAbsolutePath {
        candidateURL = URL(fileURLWithPath: candidate).standardizedFileURL
    } else {
        candidateURL = cwdURL.appending(path: candidate).standardizedFileURL
    }
    let root = cwdURL.path.hasSuffix("/") ? cwdURL.path : cwdURL.path + "/"
    guard candidateURL.path.hasPrefix(root) else { return nil }
    let relative = String(candidateURL.path.dropFirst(root.count))
    guard !relative.isEmpty,
          relative.count <= maximumActivityStringCharacters,
          !relative.split(separator: "/").contains("..")
    else { return nil }
    return relative
}

private func validAbsoluteActivityPath(_ value: String) -> String? {
    guard (value as NSString).isAbsolutePath,
          value.count <= 4_096,
          !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
}

private func sanitizedActivityString(_ value: String?, maximum: Int) -> String? {
    guard let value,
          !value.isEmpty,
          value.count <= maximum,
          !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    return value
}

private func activityHash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
}

private func writeActivityRecord(_ record: ActivityRecord) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard var data = try? encoder.encode(record) else { return }
    data.append(0x0A)

    let fileManager = FileManager.default
    guard let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first else { return }
    let claudexDirectory = applicationSupport.appendingPathComponent("Claudex", isDirectory: true)
    let activityDirectory = claudexDirectory.appendingPathComponent("Activity", isDirectory: true)
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.calendar = Calendar(identifier: .gregorian)
    day.timeZone = TimeZone(secondsFromGMT: 0)
    day.dateFormat = "yyyy-MM-dd"
    let destination = activityDirectory.appendingPathComponent(
        "events-\(day.string(from: Date())).jsonl",
        isDirectory: false
    )

    do {
        try ensureApplicationSupportDirectory(applicationSupport, fileManager: fileManager)
        try ensurePrivateDirectory(claudexDirectory, fileManager: fileManager)
        try ensurePrivateDirectory(activityDirectory, fileManager: fileManager)
    } catch { return }
    removeExpiredActivityLogs(in: activityDirectory, fileManager: fileManager)

    let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { return }
    defer { flock(descriptor, LOCK_UN) }

    var info = stat()
    guard fstat(descriptor, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFREG,
          info.st_size >= 0,
          info.st_size + off_t(data.count) <= off_t(maximumActivityLogBytes)
    else { return }
    _ = data.withUnsafeBytes { bytes -> Bool in
        guard let base = bytes.baseAddress else { return false }
        var written = 0
        while written < bytes.count {
            let result = Darwin.write(
                descriptor,
                base.advanced(by: written),
                bytes.count - written
            )
            guard result > 0 else { return false }
            written += result
        }
        return true
    }
    _ = fchmod(descriptor, 0o600)
}

private func removeExpiredActivityLogs(in directory: URL, fileManager: FileManager) {
    guard let files = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    ) else { return }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    guard let cutoff = formatter.calendar.date(byAdding: .day, value: -7, to: Date()) else { return }
    for file in files where file.lastPathComponent.hasPrefix("events-")
        && file.pathExtension == "jsonl" {
        let name = file.deletingPathExtension().lastPathComponent
        guard let date = formatter.date(from: String(name.dropFirst("events-".count))),
              date < cutoff,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { continue }
        try? fileManager.removeItem(at: file)
    }
}

private func runActivity(arguments: [String]) -> Never {
    _ = umask(0o077)
    _ = signal(SIGPIPE, SIG_IGN)
    let options = ActivityOptions.parse(arguments)
    guard options.error == nil,
          let provider = options.provider,
          provider == "claude" || provider == "codex",
          let account = validProfile(options.account)
    else {
        printUsage(error: options.error ?? "activity requires --provider claude|codex and an opaque --account")
        exit(options.error == "help" ? 0 : 64)
    }
    let input = captureStandardInput(forwardingTo: nil)
    if let record = activityRecord(from: input.data, provider: provider, account: account) {
        writeActivityRecord(record)
    }
    // Collection is observational. Malformed or unsupported provider events must never
    // interrupt the agent that invoked the hook.
    exit(0)
}

private func printStatusLine(_ status: ParsedStatus?) {
    func percentage(_ window: LimitWindow?) -> String {
        guard let value = window?.usedPercentage else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    let fiveHour = percentage(status?.rateLimits?.fiveHour)
    let sevenDay = percentage(status?.rateLimits?.sevenDay)
    FileHandle.standardOutput.write(Data("Claude · 5h \(fiveHour) · 7d \(sevenDay)\n".utf8))
}

private func printUsage(error: String? = nil) {
    if let error, error != "help" {
        FileHandle.standardError.write(Data("ClaudexStatusBridge: \(error)\n".utf8))
    }
    let usage = """
    Usage: ClaudexStatusBridge --profile <opaque-id> [--forward-config <absolute-json>]
           ClaudexStatusBridge activity --provider <claude|codex> --account <opaque-id>
    """ + "\n"
    FileHandle.standardError.write(Data(usage.utf8))
}

private func runStatusLine(arguments: [String]) -> Never {
    let options = Options.parse(arguments)
    // Spawn the user's prior status line before changing process-wide umask/SIGPIPE
    // behavior, so the chained command inherits exactly the caller's original state.
    let command = forwardCommand(at: options.forwardConfigPath).flatMap(ForwardedCommand.init(command:))
    // Ensure every cache/temp file created by this process starts owner-only. The prior
    // command has already inherited the original umask and SIGPIPE disposition.
    _ = umask(0o077)
    _ = signal(SIGPIPE, SIG_IGN)
    let profile = validProfile(options.profile)

    if command == nil, options.error != nil || profile == nil {
        printUsage(error: options.error ?? "--profile must match [A-Za-z0-9_-] and be at most 128 characters")
        exit(options.error == "help" ? 0 : 64)
    }

    let captured = captureStandardInput(forwardingTo: command)
    let status = parsedStatus(from: captured.data)

    if let profile, options.error == nil {
        if let status {
            writeHeartbeat(status, profile: profile)
            writeCache(status, profile: profile)
        }
    }

    if let command {
        exit(command.finish())
    }

    printStatusLine(status)
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "activity" {
    runActivity(arguments: Array(arguments.dropFirst()))
} else {
    runStatusLine(arguments: arguments)
}
