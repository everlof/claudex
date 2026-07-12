import Foundation

/// Human-friendly time formatting shared across the UI.
enum Fmt {
    /// "resets in 2h 14m" style — compact, at most two units.
    static func relativeFuture(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        return compactDuration(seconds)
    }

    /// "3d" / "5h" / "12m" — a single largest unit, for tight badges.
    static func shortUntil(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "now" }
        let days = Int(s / 86400)
        if days >= 1 { return "\(days)d" }
        let hours = Int(s / 3600)
        if hours >= 1 { return "\(hours)h" }
        let mins = max(1, Int(s / 60))
        return "\(mins)m"
    }

    /// "updated 2m ago" style for the footer.
    static func relativePast(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        return compactDuration(seconds) + " ago"
    }

    private static func compactDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let mins = (total % 3600) / 60

        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if mins > 0 && parts.count < 2 { parts.append("\(mins)m") }
        if parts.isEmpty { parts.append("<1m") }
        return parts.prefix(2).joined(separator: " ")
    }

    /// Absolute date for expiries, e.g. "Jul 18".
    static func shortDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return dayFormatter.string(from: date)
    }

    /// Absolute local reset time, shown when the user holds Option instead of the countdown.
    /// Names the day relatively when it's close ("3:45 PM", "tomorrow 9 AM", "Tue 9 AM") and
    /// falls back to a dated form for anything further out ("Jul 18, 3 PM").
    static func absoluteReset(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let cal = Calendar.current
        let time = timeFormatter.string(from: date)
        if cal.isDate(date, inSameDayAs: now) {
            return time
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        // Within the coming week: name the weekday. Beyond that: a dated form.
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                      to: cal.startOfDay(for: date)).day ?? 0
        if (2...6).contains(days) {
            return "\(weekdayFormatter.string(from: date)) \(time)"
        }
        return "\(dayFormatter.string(from: date)), \(time)"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    /// Short localized time-of-day ("3:45 PM" / "15:45"), respecting the user's locale.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
