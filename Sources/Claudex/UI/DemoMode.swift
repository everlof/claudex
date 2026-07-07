import Foundation

/// View-only anonymisation for screenshots. When the `CLAUDEX_DEMO` environment variable
/// is set, real account display names and handles are replaced with neutral placeholders
/// so the panel can be shown publicly without leaking personal names. Usage numbers are
/// left untouched — only the labels change.
enum DemoMode {
    static let isEnabled = ProcessInfo.processInfo.environment["CLAUDEX_DEMO"] == "1"

    private static let names = ["Ada", "Grace", "Alan", "Linus", "Margaret", "Dennis"]
    private static let handles = ["personal", "work", "team", "side-project", "oss", "client"]

    /// Assign a distinct placeholder per account, ordered by account id so the mapping is
    /// stable across launches and never collides.
    private static func slot(for id: String) -> Int {
        allIDs.firstIndex(of: id) ?? 0
    }

    /// The set of account ids seen this session, registered by the view as it renders.
    nonisolated(unsafe) private static var allIDs: [String] = []
    private static let lock = NSLock()

    static func register(_ id: String) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        if !allIDs.contains(id) { allIDs.append(id) }
    }

    /// A stable, collision-free placeholder display name for an account id.
    static func name(for id: String) -> String {
        register(id)
        return names[slot(for: id) % names.count]
    }

    /// A stable placeholder handle, keeping "default" as-is (it isn't personal).
    static func handle(_ original: String, id: String) -> String {
        guard isEnabled else { return original }
        if original == "default" { return original }
        register(id)
        return handles[slot(for: id) % handles.count]
    }

    /// Anonymise a real display name if demo mode is on.
    static func displayName(_ original: String?, id: String) -> String? {
        guard isEnabled else { return original }
        guard original != nil else { return nil }
        return name(for: id)
    }
}
