import Foundation
@preconcurrency import UserNotifications

/// What the user wants to be pinged about. Assembled by the store from its persisted
/// settings on every sync.
struct ResetNotificationSettings: Sendable {
    let enabled: Bool
    /// Only windows at or above this fraction are worth a ping when they reset.
    let threshold: Double
    let shortWindow: Bool
    let longWindow: Bool
}

/// Mirrors upcoming window resets into macOS's local-notification queue: one pending
/// notification per account+window over the threshold, firing at the window's reset
/// time. Re-synced after every refresh, so schedules follow drift in the reported
/// reset times; identifiers encode account, window, and reset minute, which makes the
/// sync idempotent.
@MainActor
final class ResetNotifier: NSObject, UNUserNotificationCenterDelegate {

    /// A notification we want pending, as plain data so it can hop off the main actor.
    private struct Planned: Sendable {
        let id: String
        let title: String
        let body: String
        let fireIn: TimeInterval
    }

    nonisolated private static let idPrefix = "reset-"

    /// UserNotifications requires a real bundle; a bare SwiftPM binary would crash on
    /// first use, so everything no-ops outside an .app.
    private let isAvailable = Bundle.main.bundleURL.pathExtension == "app"

    func activate() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        // Manual end-to-end check: CLAUDEX_NOTIFY_TEST=1 fires a sample banner ~5s in.
        if ProcessInfo.processInfo.environment["CLAUDEX_NOTIFY_TEST"] == "1" {
            let test = Planned(
                id: "\(Self.idPrefix)test",
                title: "Claude · default — Primary limit reset",
                body: "This window was at 91% — fresh budget available. (test)",
                fireIn: 5
            )
            Task.detached { await Self.reconcile(planned: [test], removeStale: false) }
        }
    }

    /// Reconcile the pending queue with the latest snapshots and settings.
    func sync(entries: [AccountEntry], settings: ResetNotificationSettings) {
        guard isAvailable else { return }
        guard settings.enabled else {
            Task.detached { await Self.reconcile(planned: [], removeStale: true) }
            return
        }

        var planned: [Planned] = []
        for entry in entries {
            guard let usage = entry.state.value else { continue }
            var windows: [UsageWindow] = []
            if settings.shortWindow, let w = usage.shortWindow { windows.append(w) }
            if settings.longWindow, let w = usage.longWindow { windows.append(w) }
            for window in windows {
                guard window.fraction >= settings.threshold,
                      let resetsAt = window.resetsAt else { continue }
                let fireIn = resetsAt.timeIntervalSinceNow
                guard fireIn > 5 else { continue }
                // Minute precision keeps ids stable across small jitter in the API's
                // reported reset times; a real shift reschedules automatically.
                let stamp = Int(resetsAt.timeIntervalSince1970 / 60)
                let handle = DemoMode.handle(entry.ref.handle, id: entry.ref.id)
                planned.append(Planned(
                    id: "\(Self.idPrefix)\(entry.ref.id)-\(window.id)-\(stamp)",
                    title: "\(entry.ref.provider.displayName) · \(handle) — \(window.label) limit reset",
                    body: "This window was at \(window.percent)% — fresh budget available.",
                    fireIn: fireIn
                ))
            }
        }
        Task.detached { [planned] in await Self.reconcile(planned: planned, removeStale: true) }
    }

    /// Make the pending queue exactly match `planned` (within our id prefix). Runs off
    /// the main actor; UserNotifications objects never cross an isolation boundary.
    nonisolated private static func reconcile(planned: [Planned], removeStale: Bool) async {
        let center = UNUserNotificationCenter.current()

        if !planned.isEmpty {
            let status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
        }

        let pending = Set(
            await center.pendingNotificationRequests()
                .map(\.identifier)
                .filter { $0.hasPrefix(idPrefix) }
        )
        if removeStale {
            let stale = pending.subtracting(planned.map(\.id))
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: Array(stale))
            }
        }
        for note in planned where !pending.contains(note.id) {
            let content = UNMutableNotificationContent()
            content.title = note.title
            content.body = note.body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: note.fireIn, repeats: false)
            try? await center.add(
                UNNotificationRequest(identifier: note.id, content: content, trigger: trigger)
            )
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners even while the app counts as active (it does whenever the popover
    /// is open), instead of silently dropping them.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
