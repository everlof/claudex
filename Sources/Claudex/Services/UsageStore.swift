import CryptoKit
import Foundation
import Observation

enum ClaudeDirectRefreshSource: String, Sendable {
    case credentialsFile = "credentials_file"
    case keychain = "keychain"
}

/// The single source of truth for the UI. Owns the list of accounts and their load
/// states, ingests Claude's local feed, drives Codex's 5-minute auto-refresh, and exposes
/// a throttled manual refresh.
@MainActor
@Observable
final class UsageStore {
    /// One entry per discovered account, order stable (Claude accounts first).
    private(set) var entries: [AccountEntry] = []
    /// When the last full refresh completed.
    private(set) var lastRefresh: Date?
    /// True while a refresh cycle is in flight (drives the spinner in the header).
    private(set) var isRefreshing = false
    /// Per-Claude-slot setup/provenance state for the passive local feed.
    private(set) var claudeIntegrations: [String: ClaudeIntegrationState] = [:]

    /// The account currently running in the frontmost window, or nil when none can be
    /// mapped. The richer fields distinguish an unknown AI session from no AI session and
    /// retain its project directory for account handoff.
    private(set) var frontmostAccountID: String?
    private(set) var frontmostSessionDetected = false
    private(set) var frontmostProvider: Provider?
    private(set) var frontmostWorkingDirectory: String?
    private(set) var frontmostTerminal: SupportedTerminal?

    /// Menu-bar presentation settings, persisted across launches. The status button
    /// re-renders via observation whenever either changes.
    var menuBarStyle: MenuBarStyle = .dual {
        didSet { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: Self.styleKey) }
    }
    var menuBarSubject: MenuBarSubject = .frontmost {
        didSet { UserDefaults.standard.set(menuBarSubject.rawValue, forKey: Self.subjectKey) }
    }
    /// Experimental, explicit opt-in. File credentials may be read automatically. A
    /// Keychain access token is read only after a dedicated user action, then held only
    /// in memory for the current app run. Refresh tokens are never retained or used.
    private(set) var claudeDirectRefreshEnabled = false
    private(set) var claudeDirectRefreshStatus: String?
    private(set) var claudeDirectRefreshDates: [String: Date] = [:]
    private(set) var claudeDirectRefreshSources: [String: ClaudeDirectRefreshSource] = [:]
    @ObservationIgnored private var claudeKeychainCredentials: [
        String: ClaudeOAuthFileCredentials.Value
    ] = [:]
    private static let styleKey = "menuBarStyle"
    private static let subjectKey = "menuBarSubject"
    private static let claudeDirectRefreshKey = "claudeDirectRefreshEnabled"

    /// Reset-notification settings, persisted. Default: ping when a 5-hour or weekly
    /// window that sat at ≥85% rolls over — that's when fresh budget actually matters.
    var notifyOnReset: Bool = true {
        didSet { UserDefaults.standard.set(notifyOnReset, forKey: "notifyOnReset"); resyncNotifications() }
    }
    var notifyThreshold: Double = 0.85 {
        didSet { UserDefaults.standard.set(notifyThreshold, forKey: "notifyThreshold"); resyncNotifications() }
    }
    var notifyShortWindow: Bool = true {
        didSet { UserDefaults.standard.set(notifyShortWindow, forKey: "notifyShortWindow"); resyncNotifications() }
    }
    var notifyLongWindow: Bool = true {
        didSet { UserDefaults.standard.set(notifyLongWindow, forKey: "notifyLongWindow"); resyncNotifications() }
    }

    /// Whether the app launches at login. The source of truth is the OS (`SMAppService`), not
    /// UserDefaults — a mirror bool drives the menu's checkmark and is re-synced from the real
    /// status after each toggle (so a failed/blocked change doesn't leave the UI lying). If the
    /// user disabled the item in System Settings, `launchAtLoginBlocked` is true and the toggle
    /// can't re-enable it; the menu then routes them to Settings instead.
    private(set) var launchAtLogin: Bool = LoginItem.isEnabled
    private(set) var launchAtLoginBlocked: Bool = LoginItem.requiresApproval

    /// Flip the login-item registration, then re-read the real status into the mirror.
    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
        launchAtLoginBlocked = LoginItem.requiresApproval
    }

    /// Usage-history store for the chart. Reads the same discovered accounts; built lazily on
    /// first access so its ccusage shell-out only happens once the chart is actually shown.
    var history: HistoryStore {
        if let historyStore { return historyStore }
        let store = HistoryStore(
            accounts: { [weak self] in self?.entries.map(\.ref) ?? [] },
            demoHistory: DemoMode.fixture?.history
        )
        historyStore = store
        return store
    }
    @ObservationIgnored private var historyStore: HistoryStore?

    /// Owner-only rate-limit samples used by the historical limit chart and early-reset
    /// detector. Unlike token/cost history, these observations begin when Claudex sees them.
    @ObservationIgnored let limitHistory = LimitHistoryStore()

    private let service = UsageService()
    private let claudeInstaller = ClaudeStatusLineInstaller()
    private let claudeHelperDeployment = ClaudeStatusBridgeDeployment()
    private let detector = FrontmostDetector()
    private let notifier = ResetNotifier()
    /// Validated config directories learned from live frontmost CLI processes. They stay
    /// in memory only; Claudex does not persist or broadly scan arbitrary paths.
    @ObservationIgnored private var observedAccountRefs: [AccountRef] = []
    private var timerTask: Task<Void, Never>?
    private var claudeFeedTask: Task<Void, Never>?
    private var frontmostTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    /// Absolute per-account server backoff deadlines from Retry-After. These are kept
    /// separately from LoadState so a stale successful snapshot can remain visible.
    @ObservationIgnored private var retryNotBefore: [String: Date] = [:]
    private let refreshInterval: Duration = .seconds(300) // 5 minutes
    private let claudeFeedInterval: Duration = .seconds(10) // local files only; no network
    private let frontmostInterval: Duration = .seconds(2)  // frontmost poll cadence

    /// The minimum spacing between actual network refreshes. Opening the popover more
    /// often than this reuses the cached data instead of hammering the APIs (which is
    /// what tripped Claude's 429 rate limit during development).
    private let minRefreshSpacing: TimeInterval = 60

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.styleKey), let style = MenuBarStyle(rawValue: raw) {
            menuBarStyle = style
        }
        if let raw = defaults.string(forKey: Self.subjectKey), let subject = MenuBarSubject(rawValue: raw) {
            menuBarSubject = subject
        }
        claudeDirectRefreshEnabled = defaults.bool(forKey: Self.claudeDirectRefreshKey)
        if defaults.object(forKey: "notifyOnReset") != nil {
            notifyOnReset = defaults.bool(forKey: "notifyOnReset")
        }
        if defaults.object(forKey: "notifyThreshold") != nil {
            notifyThreshold = defaults.double(forKey: "notifyThreshold")
        }
        if defaults.object(forKey: "notifyShortWindow") != nil {
            notifyShortWindow = defaults.bool(forKey: "notifyShortWindow")
        }
        if defaults.object(forKey: "notifyLongWindow") != nil {
            notifyLongWindow = defaults.bool(forKey: "notifyLongWindow")
        }
        if let fixture = DemoMode.fixture {
            entries = fixture.entries
            lastRefresh = Date()
            for entry in entries where entry.ref.provider == .claude {
                claudeIntegrations[entry.ref.id] = .connected(
                    valuesChangedAt: entry.state.stamp ?? Date(),
                    lastLimitsSeenAt: entry.state.stamp ?? Date(),
                    claudeVersion: "2.1.207",
                    stale: false
                )
            }
            frontmostAccountID = fixture.frontmostAccountID
            frontmostSessionDetected = fixture.frontmostAccountID != nil
            frontmostProvider = entries.first { $0.ref.id == fixture.frontmostAccountID }?.ref.provider
            return
        }
        restoreMistakenClaudeScienceIntegrations()
        rediscover()
        let hasConnectedClaude = entries.contains { entry in
            guard let configDir = claudeConfigDir(for: entry.ref) else { return false }
            return claudeInstaller.hasManagedInstallation(configDir: configDir)
        }
        if hasConnectedClaude {
            try? claudeHelperDeployment.deploy(from: bundledClaudeHelperExecutable)
        }
        refreshClaudeStatus()
        // Test hook: CLAUDEX_FORCE_FRONTMOST=<handle> pins a frontmost account so the panel's
        // auto-scroll-to-frontmost can be exercised without a live terminal session.
        if let handle = ProcessInfo.processInfo.environment["CLAUDEX_FORCE_FRONTMOST"],
           let match = entries.first(where: { $0.ref.handle == handle }) {
            frontmostAccountID = match.ref.id
            frontmostSessionDetected = true
            frontmostProvider = match.ref.provider
        }
    }

    /// Re-scan the machine for accounts, preserving any already-loaded state for
    /// accounts that still exist.
    func rediscover() {
        var refs = CredentialStore.discoverAll()
        for ref in observedAccountRefs where !refs.contains(where: {
            $0.provider == ref.provider && $0.source == ref.source
        }) {
            refs.append(ref)
        }
        let previous = Dictionary(uniqueKeysWithValues: entries.map { ($0.ref.id, $0.state) })
        entries = refs.map { ref in
            AccountEntry(ref: ref, state: previous[ref.id] ?? .idle)
        }
        let activeIDs = Set(refs.map(\.id))
        retryNotBefore = retryNotBefore.filter { activeIDs.contains($0.key) }
        claudeIntegrations = claudeIntegrations.filter { activeIDs.contains($0.key) }
        claudeDirectRefreshDates = claudeDirectRefreshDates.filter { activeIDs.contains($0.key) }
        claudeDirectRefreshSources = claudeDirectRefreshSources.filter { activeIDs.contains($0.key) }
        claudeKeychainCredentials = claudeKeychainCredentials.filter { activeIDs.contains($0.key) }
    }

    /// Older Claudex builds mistook Claude Science's ~/.claude-science application data
    /// root for a Claude Code account. Restore only our exact managed status-line change
    /// before discovery hides that pseudo-account. A conflicting user edit is never
    /// overwritten; the installer retains its recovery metadata in that rare case.
    private func restoreMistakenClaudeScienceIntegrations() {
        for directory in CredentialStore.claudeScienceDataDirs() {
            guard claudeInstaller.hasManagedInstallation(configDir: directory.path) else {
                continue
            }
            do {
                if try claudeInstaller.uninstall(configDir: directory.path) == .modifiedNotRestored {
                    NSLog("[claudex] Claude Science cleanup left modified settings unchanged")
                }
            } catch {
                NSLog("[claudex] Claude Science cleanup failed without changing settings")
            }
        }
    }

    func setClaudeDirectRefreshEnabled(_ enabled: Bool) {
        guard claudeDirectRefreshEnabled != enabled else { return }
        claudeDirectRefreshEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.claudeDirectRefreshKey)
        if enabled {
            claudeDirectRefreshStatus = "Checking credential files. Keychain access requires explicit authorization."
            inFlight?.cancel()
            inFlight = Task { [weak self] in
                guard let self else { return }
                await self.refreshAll(force: true)
            }
        } else {
            claudeKeychainCredentials.removeAll()
            claudeDirectRefreshDates.removeAll()
            claudeDirectRefreshSources.removeAll()
            claudeDirectRefreshStatus = nil
            refreshClaudeStatus()
        }
    }

    func claudeDirectRefreshDate(for accountID: String) -> Date? {
        claudeDirectRefreshDates[accountID]
    }

    func claudeDirectRefreshSource(for accountID: String) -> ClaudeDirectRefreshSource? {
        claudeDirectRefreshSources[accountID]
    }

    var claudeAccounts: [AccountRef] {
        entries.filter { $0.ref.provider == .claude }.map(\.ref)
    }

    /// The only path that may ask macOS for access to Claude Code's Keychain item.
    /// The user chooses the local account slot first, making the otherwise ambient
    /// Claude credential's association explicit rather than guessing across profiles.
    func authorizeClaudeKeychainRefresh(accountID: String) {
        guard let account = entries.first(where: {
            $0.ref.id == accountID && $0.ref.provider == .claude
        })?.ref else {
            claudeDirectRefreshStatus = "Choose a Claude account before authorizing Keychain access."
            return
        }

        if !claudeDirectRefreshEnabled {
            claudeDirectRefreshEnabled = true
            UserDefaults.standard.set(true, forKey: Self.claudeDirectRefreshKey)
        }
        claudeDirectRefreshStatus = "Waiting for macOS Keychain authorization for Claude · \(account.handle)…"
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            guard let self else { return }
            while self.isRefreshing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }

            let result: Result<ClaudeOAuthFileCredentials.Value, UsageError> = await Task.detached(
                priority: .userInitiated
            ) {
                do {
                    return .success(try ClaudeOAuthKeychainCredentials.load())
                } catch let error as UsageError {
                    return .failure(error)
                } catch {
                    return .failure(.credentialUnreadable("Keychain authorization failed."))
                }
            }.value

            guard !Task.isCancelled else { return }
            switch result {
            case let .success(credentials):
                // Claude Code's ambient Keychain service is not tied to a Claudex config
                // slot. Keep at most one explicit user association per app run.
                self.claudeKeychainCredentials.removeAll()
                self.claudeKeychainCredentials[accountID] = credentials
                self.claudeDirectRefreshStatus =
                    "Keychain authorized for Claude · \(account.handle) during this app run; refreshing usage…"
                await self.refreshAll(force: true, onlyAccountID: accountID)
            case let .failure(error):
                self.claudeKeychainCredentials.removeValue(forKey: accountID)
                self.claudeDirectRefreshStatus = error.detail ?? error.headline
                self.refreshClaudeStatus()
            }
        }
    }

    // MARK: Claude Code passive feed

    func claudeIntegration(for accountID: String) -> ClaudeIntegrationState? {
        claudeIntegrations[accountID]
    }

    func claudeSettingsPath(for accountID: String) -> String? {
        guard let ref = entries.first(where: { $0.ref.id == accountID })?.ref,
              let configDir = claudeConfigDir(for: ref)
        else { return nil }
        return URL(fileURLWithPath: configDir, isDirectory: true)
            .appending(path: "settings.json")
            .path
    }

    /// Installs or repairs the local bridge after the account card's explicit review step.
    /// Returns nil on success or a short user-facing error.
    func connectClaude(accountID: String) -> String? {
        guard let ref = entries.first(where: { $0.ref.id == accountID })?.ref,
              let configDir = claudeConfigDir(for: ref)
        else { return "Claude account not found." }
        do {
            let repairsCacheFailure: Bool
            if let state = claudeIntegrations[accountID], case .failed = state {
                repairsCacheFailure = true
            } else {
                repairsCacheFailure = false
            }
            try claudeHelperDeployment.deploy(from: bundledClaudeHelperExecutable)
            _ = try claudeInstaller.install(
                configDir: configDir,
                helperExecutable: claudeHelperExecutable
            )
            if repairsCacheFailure {
                claudeInstaller.clearCachedStatus(configDir: configDir)
            }
            refreshClaudeStatus()
            return nil
        } catch {
            refreshClaudeStatus()
            return error.localizedDescription
        }
    }

    /// Restores the exact pre-Claudex statusLine. If it changed meanwhile, the installer
    /// refuses to overwrite it and this method reports that conflict.
    func disconnectClaude(accountID: String) -> String? {
        guard let ref = entries.first(where: { $0.ref.id == accountID })?.ref,
              let configDir = claudeConfigDir(for: ref)
        else { return "Claude account not found." }
        do {
            let result = try claudeInstaller.uninstall(configDir: configDir)
            refreshClaudeStatus()
            switch result {
            case .uninstalled, .notInstalled: return nil
            case .modifiedNotRestored:
                return "Claude settings changed after Claudex connected, so nothing was overwritten."
            }
        } catch {
            refreshClaudeStatus()
            return error.localizedDescription
        }
    }

    /// Drops only Claudex-owned backup/cache files after the user has replaced the
    /// statusLine themselves. Claude settings is never changed by this action.
    func forgetClaudeMetadata(accountID: String) -> String? {
        guard let ref = entries.first(where: { $0.ref.id == accountID })?.ref,
              let configDir = claudeConfigDir(for: ref)
        else { return "Claude account not found." }
        do {
            try claudeInstaller.forgetMetadata(configDir: configDir)
            refreshClaudeStatus()
            return nil
        } catch {
            refreshClaudeStatus()
            return error.localizedDescription
        }
    }

    /// Re-read every small local cache. This performs no credential or network access.
    private func refreshClaudeStatus(now: Date = Date()) {
        guard DemoMode.fixture == nil else { return }
        var changed = false
        for index in entries.indices where entries[index].ref.provider == .claude {
            let ref = entries[index].ref
            guard let configDir = claudeConfigDir(for: ref) else { continue }
            let inspection = claudeInstaller.inspect(
                configDir: configDir,
                helperExecutable: claudeHelperExecutable
            )

            switch inspection.state {
            case .notInstalled:
                changed = commitClaudeState(
                    at: index,
                    integration: .disconnected,
                    usage: nil,
                    fetchedAt: nil
                ) || changed

            case .installed:
                changed = applyClaudeCache(
                    inspection: inspection,
                    to: index,
                    now: now,
                    configurationIssue: nil
                ) || changed

            case let .needsRepair(message):
                changed = applyClaudeCache(
                    inspection: inspection,
                    to: index,
                    now: now,
                    configurationIssue: .needsRepair(message)
                ) || changed

            case let .modified(message):
                changed = applyClaudeCache(
                    inspection: inspection,
                    to: index,
                    now: now,
                    configurationIssue: .modified(message)
                ) || changed
            }
        }
        if changed { resyncNotifications() }
    }

    private enum ClaudeConfigurationIssue {
        case needsRepair(String)
        case modified(String)
    }

    private func applyClaudeCache(
        inspection: ClaudeStatusLineInstaller.Inspection,
        to index: Int,
        now: Date,
        configurationIssue: ClaudeConfigurationIssue?
    ) -> Bool {
        do {
            let snapshot = try ClaudeStatusCache.load(profileID: inspection.profileID)
            let heartbeat = try? ClaudeStatusCache.loadHeartbeat(
                profileID: inspection.profileID,
                now: now
            )
            let resolution = Self.resolveClaudeSnapshot(
                snapshot,
                heartbeat: heartbeat,
                now: now
            )
            let integration: ClaudeIntegrationState
            switch configurationIssue {
            case nil:
                integration = .connected(
                    valuesChangedAt: snapshot.observedAt,
                    lastLimitsSeenAt: resolution.lastLimitsSeenAt,
                    claudeVersion: resolution.claudeVersion,
                    stale: resolution.stale
                )
            case let .needsRepair(message):
                integration = .needsRepair(
                    message: message,
                    observedAt: snapshot.observedAt
                )
            case let .modified(message):
                integration = .modified(
                    message: message,
                    observedAt: snapshot.observedAt
                )
            }
            return commitClaudeState(
                at: index,
                integration: integration,
                usage: resolution.usage,
                fetchedAt: snapshot.observedAt
            )
        } catch let error {
            let integration: ClaudeIntegrationState
            if let configurationIssue {
                switch configurationIssue {
                case let .needsRepair(message):
                    integration = .needsRepair(message: message, observedAt: nil)
                case let .modified(message):
                    integration = .modified(message: message, observedAt: nil)
                }
            } else if error == .missing || error == .noRateLimits {
                let heartbeat = try? ClaudeStatusCache.loadHeartbeat(
                    profileID: inspection.profileID,
                    now: now
                )
                integration = .waiting(
                    lastReceivedAt: heartbeat?.receivedAt,
                    claudeVersion: heartbeat?.claudeVersion,
                    rateLimitsPresent: heartbeat?.rateLimitsPresent
                )
            } else {
                integration = .failed(message: error.localizedDescription)
            }
            return commitClaudeState(
                at: index,
                integration: integration,
                usage: nil,
                fetchedAt: nil
            )
        }
    }

    private func commitClaudeState(
        at index: Int,
        integration: ClaudeIntegrationState,
        usage: AccountUsage?,
        fetchedAt: Date?
    ) -> Bool {
        let id = entries[index].ref.id
        var changed = false
        if claudeIntegrations[id] != integration {
            claudeIntegrations[id] = integration
            changed = true
        }

        // While direct refresh is active, the passive watcher continues to report its
        // health but must not overwrite or erase the newer network-backed snapshot.
        if claudeDirectRefreshEnabled, claudeDirectRefreshDates[id] != nil {
            return changed
        }

        if let usage, let fetchedAt {
            if entries[index].state.value != usage || entries[index].state.stamp != fetchedAt {
                entries[index].state = .loaded(usage, fetchedAt: fetchedAt)
                changed = true
            }
            recordLimitHistory(
                account: entries[index].ref,
                usage: usage,
                observedAt: fetchedAt,
                source: .claudeStatusLine
            )
        } else if entries[index].state.value != nil
                    || entries[index].state.stamp != nil
                    || entries[index].state.isLoading
                    || entries[index].state.error != nil {
            entries[index].state = .idle
            changed = true
        }
        return changed
    }

    nonisolated static func isClaudeSnapshotStale(
        _ snapshot: ClaudeStatusSnapshot,
        lastLimitsSeenAt: Date? = nil,
        now: Date
    ) -> Bool {
        if now.timeIntervalSince(lastLimitsSeenAt ?? snapshot.observedAt) > 6 * 60 * 60 {
            return true
        }
        // One expired window must not invalidate another still-current window.
        return snapshot.accountUsage(at: now).currentWindows.isEmpty
    }

    struct ClaudeSnapshotResolution: Sendable, Equatable {
        let usage: AccountUsage
        let lastLimitsSeenAt: Date
        let claudeVersion: String?
        let stale: Bool
    }

    /// Resolve a valid last-known-good snapshot independently from the newest health
    /// heartbeat. A missing-limits heartbeat affects freshness, never data retention.
    nonisolated static func resolveClaudeSnapshot(
        _ snapshot: ClaudeStatusSnapshot,
        heartbeat: ClaudeStatusHeartbeat?,
        now: Date
    ) -> ClaudeSnapshotResolution {
        let lastLimitsSeenAt = max(
            snapshot.observedAt,
            heartbeat?.lastLimitsSeenAt ?? snapshot.observedAt
        )
        let latestSampleOmittedLimits = heartbeat.map {
            $0.receivedAt > lastLimitsSeenAt && !$0.rateLimitsPresent
        } ?? false
        return ClaudeSnapshotResolution(
            usage: snapshot.accountUsage(at: now),
            lastLimitsSeenAt: lastLimitsSeenAt,
            claudeVersion: heartbeat?.claudeVersion ?? snapshot.claudeVersion,
            stale: latestSampleOmittedLimits || isClaudeSnapshotStale(
                snapshot,
                lastLimitsSeenAt: lastLimitsSeenAt,
                now: now
            )
        )
    }

    private func claudeConfigDir(for ref: AccountRef) -> String? {
        guard case let .claudeConfigDir(path) = ref.source else { return nil }
        return path
    }

    private var claudeHelperExecutable: URL {
        claudeHelperDeployment.executableURL
    }

    private var bundledClaudeHelperExecutable: URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL
                .appending(path: "Contents/Helpers/ClaudexStatusBridge")
        }
        // SwiftPM development builds place both executable targets in the same bin dir.
        if let executable = Bundle.main.executableURL {
            return executable.deletingLastPathComponent()
                .appending(path: "ClaudexStatusBridge")
        }
        return Bundle.main.bundleURL.appending(path: "ClaudexStatusBridge")
    }

    /// Start the local Claude feed watcher plus Codex's background refresh loop.
    func start() {
        guard DemoMode.fixture == nil else { return }
        guard timerTask == nil else { return }
        notifier.activate()
        timerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshAll(force: true)
                try? await Task.sleep(for: self.refreshInterval)
            }
        }
        claudeFeedTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.refreshClaudeStatus()
                try? await Task.sleep(for: self.claudeFeedInterval)
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        claudeFeedTask?.cancel()
        claudeFeedTask = nil
        frontmostTask?.cancel()
        frontmostTask = nil
    }

    /// Start polling which account is frontmost. The detector shells out to AppleScript
    /// and `ps`, so it runs off the main actor; results are hopped back on.
    func startFrontmostTracking() {
        guard DemoMode.fixture == nil else { return }
        guard frontmostTask == nil else { return }
        // When a frontmost account is pinned for testing, don't let the poll overwrite it.
        guard ProcessInfo.processInfo.environment["CLAUDEX_FORCE_FRONTMOST"] == nil else { return }
        frontmostTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let refs = self.entries.map(\.ref)
                // Map each loaded account's stable identity to its ref id, so a frontmost
                // desktop app (Codex.app / Claude.app) can be resolved to an account.
                let accountsByUUID = self.entries.reduce(into: [String: String]()) { map, entry in
                    if let uuid = entry.state.value?.accountUUID { map[uuid] = entry.ref.id }
                }
                let detector = self.detector
                // Run the (blocking) detection off the main actor.
                let detection = await Task.detached(priority: .utility) {
                    detector.inspect(known: refs, accountsByUUID: accountsByUUID)
                }.value
                if detection.preservesPreviousSession {
                    try? await Task.sleep(for: self.frontmostInterval)
                    continue
                }
                var id = detection.accountID
                if id == nil,
                   let provider = detection.provider,
                   let configDir = detection.configDir,
                   let observed = CredentialStore.discoverObserved(
                    provider: provider,
                    configDir: configDir,
                    existing: self.entries.map(\.ref) + self.observedAccountRefs
                   ) {
                    let isAlreadyKnown = self.entries.contains(where: {
                        $0.ref.provider == observed.provider && $0.ref.source == observed.source
                    })
                    if !isAlreadyKnown && !self.observedAccountRefs.contains(where: {
                        $0.provider == observed.provider && $0.source == observed.source
                    }) {
                        self.observedAccountRefs.append(observed)
                        self.rediscover()
                        if observed.provider == .claude {
                            self.refreshClaudeStatus()
                        } else {
                            await self.refreshAll(force: true, onlyAccountID: observed.id)
                        }
                    }
                    id = observed.id
                }
                if self.frontmostAccountID != id {
                    self.frontmostAccountID = id
                    // CLAUDEX_DEBUG_FRONTMOST=1 logs each change to Console/`log stream`,
                    // for diagnosing which account a frontmost window resolves to.
                    if ProcessInfo.processInfo.environment["CLAUDEX_DEBUG_FRONTMOST"] == "1" {
                        let handle = self.entries.first { $0.ref.id == id }?.ref.handle ?? "—"
                        NSLog("[claudex] frontmost account = %@ (%@)", id ?? "nil", handle)
                    }
                }
                self.frontmostSessionDetected = detection.hasAISession
                self.frontmostProvider = detection.provider
                self.frontmostWorkingDirectory = detection.workingDirectory
                self.frontmostTerminal = detection.terminal
                try? await Task.sleep(for: self.frontmostInterval)
            }
        }
    }

    /// Refresh every account concurrently. `force` bypasses the throttle (used by the
    /// timer and the explicit refresh button); non-forced Codex calls are skipped if the
    /// last refresh was very recent. Claude is always a small local cache read.
    func refreshAll(
        force: Bool,
        onlyAccountID: String? = nil
    ) async {
        if DemoMode.fixture != nil {
            lastRefresh = Date()
            return
        }
        // Coalesce network work before rediscovery. Claude discovery is config-only.
        if isRefreshing { return }
        rediscover()
        refreshClaudeStatus()
        guard !entries.isEmpty else {
            if claudeDirectRefreshEnabled {
                claudeDirectRefreshStatus = "No Claude accounts found; direct refresh is idle."
            }
            isRefreshing = false
            return
        }

        // Throttle: reuse cached data if we refreshed very recently and this isn't forced.
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < minRefreshSpacing {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        // Only show the spinner for network-backed Codex accounts that have nothing to
        // show yet; Claude has its own disconnected/waiting presentation.
        // with a prior value keep displaying it until fresh data (or a real error) lands.
        for i in entries.indices {
            if let onlyAccountID, entries[i].ref.id != onlyAccountID { continue }
            if entries[i].ref.provider == .codex,
               entries[i].state.value == nil,
               entries[i].state.error == nil {
                entries[i].state = .loading
            }
        }

        let selectionTime = Date()
        let refs = entries.filter { entry in
            guard entry.ref.provider == .codex || claudeDirectRefreshEnabled else {
                return false
            }
            return Self.shouldRefresh(
                entry: entry,
                onlyAccountID: onlyAccountID,
                retryAt: retryNotBefore[entry.ref.id],
                now: selectionTime
            )
        }.map(\.ref)
        // Stagger network-backed accounts so they don't burst provider hosts simultaneously.
        let staggered = refs.enumerated().map { (index, ref) in (ref, Double(index) * 0.25) }
        let authorizedClaudeCredentials = claudeKeychainCredentials
        let directClaudeAttemptCount = refs.count { $0.provider == .claude }
        var directClaudeSuccessCount = 0
        var directClaudeMissingCount = 0
        var directClaudeKeychainSuccessCount = 0
        var keychainAuthorizationInvalidated = false
        var needsPassiveClaudeRestore = false

        await withTaskGroup(
            of: (String, ClaudeDirectRefreshSource?, Result<AccountUsage, UsageError>).self
        ) { group in
            for (ref, delay) in staggered {
                let service = self.service
                let hasPrior = entries.first(where: { $0.ref.id == ref.id })?.state.value != nil
                let authorizedCredential = authorizedClaudeCredentials[ref.id]
                group.addTask {
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    // On a cold start (no prior value) a transient error like a 429 would
                    // otherwise show a hard error card, so retry a bounded number of times
                    // honouring Retry-After. When we already have data, don't retry — the
                    // stale value is shown and the next cycle refreshes.
                    let maxAttempts = hasPrior ? 1 : 3
                    var lastError: UsageError = .network("unknown")
                    for attempt in 0..<maxAttempts {
                        do {
                            let usage: AccountUsage
                            let directSource: ClaudeDirectRefreshSource?
                            if ref.provider == .claude {
                                if let authorizedCredential {
                                    usage = try await service.fetchClaude(credentials: authorizedCredential)
                                    directSource = .keychain
                                } else {
                                    usage = try await service.fetchClaudeFromCredentialsFile(ref)
                                    directSource = .credentialsFile
                                }
                            } else {
                                usage = try await service.fetch(ref)
                                directSource = nil
                            }
                            return (
                                ref.id,
                                directSource,
                                .success(usage)
                            )
                        } catch let error as UsageError {
                            lastError = error
                            guard error.isTransient, attempt < maxAttempts - 1,
                                  let backoff = Self.retryDelay(for: error, attempt: attempt)
                            else { break }
                            try? await Task.sleep(for: .seconds(backoff))
                        } catch {
                            lastError = .network(error.localizedDescription)
                            break
                        }
                    }
                    let attemptedSource: ClaudeDirectRefreshSource? = ref.provider == .claude
                        ? (authorizedCredential == nil ? .credentialsFile : .keychain)
                        : nil
                    return (ref.id, attemptedSource, .failure(lastError))
                }
            }
            for await (id, directSource, result) in group {
                guard let idx = entries.firstIndex(where: { $0.ref.id == id }) else { continue }
                let now = Date()
                switch result {
                case let .success(usage):
                    retryNotBefore[id] = nil
                    entries[idx].state = .loaded(usage, fetchedAt: now)
                    recordLimitHistory(
                        account: entries[idx].ref,
                        usage: usage,
                        observedAt: now,
                        source: directSource == .keychain
                            ? .claudeOAuthKeychain
                            : (directSource == .credentialsFile ? .claudeOAuthFile : .codexAPI)
                    )
                    if entries[idx].ref.provider == .claude {
                        claudeDirectRefreshDates[id] = now
                        if let directSource { claudeDirectRefreshSources[id] = directSource }
                        directClaudeSuccessCount += 1
                        if directSource == .keychain { directClaudeKeychainSuccessCount += 1 }
                    }
                case let .failure(error):
                    if case let .rateLimited(retryAfter) = error,
                       let retryAfter, retryAfter > 0 {
                        retryNotBefore[id] = now.addingTimeInterval(retryAfter)
                    } else {
                        retryNotBefore[id] = nil
                    }
                    if entries[idx].ref.provider == .claude {
                        if directSource == .keychain,
                           (error == .noCredential || error == .tokenExpired || error == .http(status: 401)) {
                            claudeKeychainCredentials.removeValue(forKey: id)
                            claudeDirectRefreshSources.removeValue(forKey: id)
                            if claudeDirectRefreshDates.removeValue(forKey: id) != nil {
                                needsPassiveClaudeRestore = true
                            }
                            keychainAuthorizationInvalidated = true
                        }
                        if error == .noCredential || error == .tokenExpired {
                            directClaudeMissingCount += 1
                        }
                        switch error {
                        case .noCredential, .credentialUnreadable, .tokenExpired:
                            if claudeDirectRefreshDates.removeValue(forKey: id) != nil {
                                needsPassiveClaudeRestore = true
                            }
                            claudeDirectRefreshSources.removeValue(forKey: id)
                        case .rateLimited, .http, .network, .decoding:
                            break
                        }
                        // Direct Claude refresh is only a fallback. Its failure must not
                        // replace the passive feed with an error card.
                        continue
                    }
                    // A transient error must not erase good data we already have — keep
                    // showing the last snapshot rather than flashing an error card.
                    if error.isTransient, let prev = entries[idx].state.value {
                        entries[idx].state = .loaded(prev, fetchedAt: entries[idx].state.stamp ?? now)
                    } else {
                        entries[idx].state = .failed(error, at: now)
                    }
                }
            }
        }

        if needsPassiveClaudeRestore {
            refreshClaudeStatus()
        }

        if claudeDirectRefreshEnabled {
            if directClaudeSuccessCount > 0 {
                if directClaudeKeychainSuccessCount > 0 {
                    claudeDirectRefreshStatus =
                        "Active from Keychain for this app run. Background refresh reuses only the in-memory access token."
                } else {
                    let suffix = directClaudeSuccessCount == 1 ? "account" : "accounts"
                    claudeDirectRefreshStatus =
                        "Active from credential files for \(directClaudeSuccessCount) \(suffix); Keychain was not accessed."
                }
            } else if keychainAuthorizationInvalidated {
                claudeDirectRefreshStatus =
                    "The Keychain access token is expired or was rejected. Authorize again after refreshing the Claude Code login, or use the local feed."
            } else if !claudeDirectRefreshDates.isEmpty {
                claudeDirectRefreshStatus = "Refresh delayed; showing the last direct snapshot."
            } else if directClaudeAttemptCount > 0, directClaudeMissingCount == directClaudeAttemptCount {
                claudeDirectRefreshStatus =
                    "No current credential files found. Authorize Keychain for one account, or keep using the local feed."
            } else if directClaudeAttemptCount > 0 {
                claudeDirectRefreshStatus = "Direct refresh unavailable; using the local feed."
            } else {
                claudeDirectRefreshStatus = "No Claude accounts found; direct refresh is idle."
            }
        }

        lastRefresh = Date()
        resyncNotifications()
    }

    /// Pure refresh policy used by the scheduler and unit tests.
    nonisolated static func shouldRefresh(
        entry: AccountEntry,
        onlyAccountID: String?,
        retryAt: Date?,
        now: Date
    ) -> Bool {
        if let onlyAccountID, entry.ref.id != onlyAccountID { return false }
        if let retryAt, retryAt > now { return false }
        return true
    }

    /// Keep pending reset notifications in step with the latest data and settings.
    private func resyncNotifications() {
        notifier.sync(
            entries: usableEntries,
            settings: ResetNotificationSettings(
                enabled: notifyOnReset,
                threshold: notifyThreshold,
                shortWindow: notifyShortWindow,
                longWindow: notifyLongWindow
            )
        )
    }

    /// Persist a provider observation without delaying the refresh UI. The actor
    /// serializes passive and direct samples, ignores duplicates, and returns only newly
    /// inferred resets, so notifications remain idempotent across repeated cache reads.
    private func recordLimitHistory(
        account: AccountRef,
        usage: AccountUsage,
        observedAt: Date,
        source: LimitSampleSource
    ) {
        guard DemoMode.fixture == nil else { return }
        let history = limitHistory
        Task { [weak self] in
            do {
                let events = try await history.ingest(
                    account: account,
                    usage: usage,
                    observedAt: observedAt,
                    source: source
                )
                self?.notifyEarlyResets(events)
            } catch {
                if ProcessInfo.processInfo.environment["CLAUDEX_DEBUG_LIMIT_HISTORY"] == "1" {
                    NSLog("[claudex] limit history write failed: %@", error.localizedDescription)
                }
            }
        }
    }

    private func notifyEarlyResets(_ events: [LimitResetEvent]) {
        guard notifyOnReset else { return }
        let qualifying = events.filter { event in
            guard event.isEarly,
                  event.capacityRestoredFraction >= notifyThreshold
            else { return false }
            if let length = event.windowLength {
                return length <= 24 * 60 * 60 ? notifyShortWindow : notifyLongWindow
            }
            return notifyShortWindow || notifyLongWindow
        }
        notifier.notifyEarlyResets(qualifying)
    }

    /// Backoff before a retry, or `nil` to give up (let the next 5-min tick heal it).
    /// Honours a 429's Retry-After; if that wait exceeds our cap we don't retry now, so
    /// a cold start never blocks the cycle for long.
    nonisolated private static func retryDelay(for error: UsageError, attempt: Int) -> Double? {
        let cap = 8.0
        if case let .rateLimited(retryAfter) = error, let s = retryAfter {
            return s <= cap ? max(1, s) : nil
        }
        return min(cap, pow(2, Double(attempt))) // 1s, 2s, 4s…
    }

    /// User-triggered refresh: re-read local Claude caches and refresh Codex.
    func refreshNow() {
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            guard let self else { return }
            while self.isRefreshing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            await self.refreshAll(force: true)
        }
    }

    /// Called when the popover opens. Refreshes only if data is stale, so rapidly
    /// reopening the panel doesn't spam the APIs.
    func refreshIfStale() {
        Task { await refreshAll(force: false) }
    }

    // MARK: Derived summaries for the menubar glyph & header

    /// Stale or misconfigured Claude snapshots stay visible on their account card but do
    /// not influence portfolio recommendations, menu-bar pressure, or reset notifications.
    private var usableEntries: [AccountEntry] {
        guard DemoMode.fixture == nil else { return entries }
        return entries.map { entry in
            guard entry.ref.provider == .claude else { return entry }
            if claudeDirectRefreshDates[entry.ref.id] != nil { return entry }
            guard let integration = claudeIntegrations[entry.ref.id],
            case let .connected(_, _, _, stale) = integration,
                  !stale
            else {
                return AccountEntry(ref: entry.ref, state: .idle)
            }
            return entry
        }
    }

    /// The worst severity across all loaded accounts — drives the menubar icon tint.
    var overallSeverity: Severity {
        usableEntries.compactMap { $0.state.value?.severity }.max() ?? .normal
    }

    /// Highest fill fraction across all accounts, for a compact headline number.
    var peakFraction: Double {
        usableEntries.compactMap { $0.state.value?.headlineFraction }.max() ?? 0
    }

    /// True only when an account is showing a *hard* error with no data to fall back on.
    var hasAnyError: Bool {
        if entries.contains(where: { $0.state.value == nil && $0.state.error != nil }) {
            return true
        }
        return claudeIntegrations.contains { id, state in
            if claudeDirectRefreshDates[id] != nil { return false }
            switch state {
            case .needsRepair, .modified, .failed: return true
            case .disconnected, .waiting, .connected: return false
            }
        }
    }

    var loadedCount: Int {
        usableEntries.filter { $0.state.value != nil }.count
    }

    /// Latest real provider observation, not merely the time a cache rescan completed.
    var latestDataUpdate: Date? {
        entries.compactMap { entry -> Date? in
            guard entry.state.value != nil else { return nil }
            return entry.state.stamp
        }.max()
    }

    /// A deliberately allowlisted report for user-reviewed support sharing. It contains no
    /// account handles, names/emails, paths, credentials, session data, or prompt content.
    func safeDiagnosticsReport(now: Date = Date()) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let appFingerprint = bundle.executableURL.flatMap(Self.sha256OfRegularFile) ?? "unavailable"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var lines = [
            "Claudex diagnostics (preview)",
            "generated_at: \(formatter.string(from: now))",
            "app_version: \(version) (\(build))",
            "app_binary_sha256: \(appFingerprint)",
            "macos_version: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "diagnostics_schema: 1",
            "usage_cache_schema: 1",
            "heartbeat_schema: 2",
            "limit_history: enabled=true schema=1 retention_days=180",
            "claude_data_sources: local_status_line,optional_direct_credentials_file,optional_user_authorized_keychain",
            "claude_direct_refresh: enabled=\(claudeDirectRefreshEnabled) active_accounts=\(claudeDirectRefreshDates.count) keychain_authorized_accounts=\(claudeKeychainCredentials.count) background_keychain_access=false token_refresh=false",
            "claude_helper_present: \(FileManager.default.isExecutableFile(atPath: claudeHelperExecutable.path))",
            "account_counts: claude=\(entries.filter { $0.ref.provider == .claude }.count) codex=\(entries.filter { $0.ref.provider == .codex }.count)",
        ]

        var claudeIndex = 0
        var codexIndex = 0
        for entry in entries {
            switch entry.ref.provider {
            case .claude:
                claudeIndex += 1
                let windows = entry.state.value?.windows.map(\.id).joined(separator: ",") ?? "none"
                let state = diagnosticClaudeState(claudeIntegrations[entry.ref.id], now: now)
                let source: String
                switch claudeDirectRefreshSources[entry.ref.id] {
                case .credentialsFile: source = "direct_file"
                case .keychain: source = "direct_keychain"
                case nil: source = "local_feed"
                }
                lines.append("claude[\(claudeIndex)] state=\(state) source=\(source) windows=\(windows)")

            case .codex:
                codexIndex += 1
                let windows = entry.state.value?.windows.map(\.id).joined(separator: ",") ?? "none"
                let backoff = retryNotBefore[entry.ref.id].flatMap { deadline -> Int? in
                    guard deadline > now else { return nil }
                    return Int(deadline.timeIntervalSince(now).rounded(.up))
                }
                let backoffText = backoff.map { " backoff_seconds_remaining=\($0)" } ?? ""
                lines.append("codex[\(codexIndex)] state=\(diagnosticLoadState(entry.state)) windows=\(windows)\(backoffText)")
            }
        }

        lines += [
            "excluded: credentials,tokens,names,emails,config_paths,cwd,session_ids,transcripts,prompts,responses,raw_status_payload,activity_events,activity_file_paths,activity_tool_names",
            "sharing: nothing is uploaded; Copy is an explicit user action",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func sha256OfRegularFile(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 67_108_865) <= 67_108_864,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func diagnosticClaudeState(_ state: ClaudeIntegrationState?, now: Date) -> String {
        guard let state else { return "unknown" }
        switch state {
        case .disconnected: return "disconnected"
        case let .waiting(lastReceivedAt, version, rateLimitsPresent):
            let seen = lastReceivedAt.map { max(0, Int(now.timeIntervalSince($0))) }
            return "waiting helper_seen=\(seen == nil ? "false" : "true") age_seconds=\(seen ?? -1) cli=\(version ?? "unknown") limits_present=\(rateLimitsPresent.map(String.init) ?? "unknown")"
        case let .connected(valuesChangedAt, lastLimitsSeenAt, version, stale):
            let changedAge = max(0, Int(now.timeIntervalSince(valuesChangedAt)))
            let seenAge = max(0, Int(now.timeIntervalSince(lastLimitsSeenAt)))
            return "connected stale=\(stale) limits_seen_age_seconds=\(seenAge) values_changed_age_seconds=\(changedAge) cli=\(version ?? "unknown")"
        case let .needsRepair(_, observedAt):
            return "needs_repair cache=\(observedAt == nil ? "missing" : "present")"
        case let .modified(_, observedAt):
            return "settings_modified cache=\(observedAt == nil ? "missing" : "present")"
        case .failed: return "cache_error"
        }
    }

    private func diagnosticLoadState(_ state: LoadState<AccountUsage>) -> String {
        switch state {
        case .idle: return "idle"
        case .loading: return "loading"
        case .loaded: return "loaded"
        case let .failed(error, _):
            if case let .rateLimited(retryAfter) = error {
                return "rate_limited retry_after_seconds=\(retryAfter.map { Int($0) } ?? -1)"
            }
            return "error=\(error.headline.replacingOccurrences(of: " ", with: "_"))"
        }
    }

    /// Aggregate normalized capacity plus provider-specific best-account choices.
    var portfolio: AccountPortfolio { AccountPortfolio(entries: usableEntries) }

    func handoffRecommendation(for accountID: String) -> AccountPortfolio.HandoffRecommendation? {
        portfolio.handoffRecommendation(for: accountID)
    }

    /// Launch the target account in a fresh terminal session, preserving the detected
    /// project's working directory when available. Returns nil on success.
    func launch(account: AccountRef) -> String? {
        HandoffLauncher.launch(
            account: account,
            workingDirectory: frontmostWorkingDirectory,
            preferredTerminal: frontmostTerminal
        )
    }

    /// The frontmost account entry, if one is detected and loaded.
    var frontmostEntry: AccountEntry? {
        guard let id = frontmostAccountID else { return nil }
        return usableEntries.first { $0.ref.id == id && $0.state.value != nil }
    }

    /// The loaded account with the highest headline usage.
    var peakEntry: AccountEntry? {
        usableEntries
            .filter { $0.state.value != nil }
            .max { ($0.state.value?.headlineFraction ?? 0) < ($1.state.value?.headlineFraction ?? 0) }
    }

    /// The account the menu bar features, per the subject setting. Nil falls back to the
    /// untinted global peak.
    var featuredEntry: AccountEntry? {
        switch menuBarSubject {
        case .frontmost: return frontmostEntry
        case .peak: return peakEntry
        }
    }

    /// What the menu bar should display: either the featured account's windows, or an
    /// equal-weight aggregate when the frontmost account cannot be mapped.
    var menuBar: MenuBarSummary {
        // Per-account compact state (panel order) for the all-accounts style.
        let badges = usableEntries.compactMap { entry in
            entry.state.value.map {
                MenuBarSummary.Badge(
                    provider: entry.ref.provider,
                    fraction: $0.headlineFraction,
                    severity: $0.severity
                )
            }
        }

        if let entry = featuredEntry, let usage = entry.state.value {
            let (short, long) = (usage.shortWindow, usage.longWindow)
            return MenuBarSummary(
                provider: entry.ref.provider,
                handle: DemoMode.handle(entry.ref.handle, id: entry.ref.id),
                primaryPercent: short?.percent,
                secondaryPercent: long?.percent,
                primaryFraction: short?.fraction,
                secondaryFraction: long?.fraction,
                severity: usage.severity,
                isFeatured: true,
                badges: badges
            )
        }
        // Fallback: normalized portfolio pressure across all accounts, no provider tint.
        guard loadedCount > 0 else {
            return MenuBarSummary(provider: nil, handle: nil,
                                  primaryPercent: nil, secondaryPercent: nil,
                                  primaryFraction: nil, secondaryFraction: nil,
                                  severity: .normal, isFeatured: false, badges: badges)
        }
        let aggregate = portfolio
        let headline = aggregate.averageHeadlineFraction ?? 0
        let primary = aggregate.averageShortFraction ?? headline
        return MenuBarSummary(
            provider: nil,
            handle: nil,
            primaryPercent: Int((primary * 100).rounded()),
            secondaryPercent: aggregate.averageLongFraction.map { Int(($0 * 100).rounded()) },
            primaryFraction: primary,
            secondaryFraction: aggregate.averageLongFraction,
            severity: aggregate.severity,
            isFeatured: false,
            badges: badges
        )
    }

}

/// A value type describing exactly what the menu-bar button should render, so the
/// AppKit status item stays a thin projection of typed store state. Carries enough for
/// every `MenuBarStyle`; each style picks what it needs.
struct MenuBarSummary: Equatable, Sendable {
    /// Compact per-account state for the all-accounts style, in panel order.
    struct Badge: Equatable, Sendable {
        let provider: Provider
        let fraction: Double
        let severity: Severity
    }

    let provider: Provider?        // tints glyph/ring when an account is featured
    let handle: String?            // featured account's handle (demo-mode aware)
    let primaryPercent: Int?       // primary limit % or normalized pressure (fallback)
    let secondaryPercent: Int?     // secondary limit % — only for a featured account
    let primaryFraction: Double?   // raw fractions for the drawn styles (ring / bars)
    let secondaryFraction: Double?
    let severity: Severity
    let isFeatured: Bool
    let badges: [Badge]
}
