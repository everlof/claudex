import Foundation

/// How the menu-bar button renders usage, roughly ordered most → least compact.
/// Persisted by raw value, so every case's raw string must stay stable.
enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    /// A bare status dot: severity colour inside, provider-tinted ring when a specific
    /// account is featured. The most compact option.
    case dot
    /// Just the severity gauge glyph, no text.
    case iconOnly
    /// A drawn ring that fills with the featured account's usage — data-true icon.
    case ring
    /// Two mini horizontal bars (primary on top, secondary below), no text.
    case bars
    /// Gauge glyph plus a single percentage.
    case percent
    /// Gauge glyph plus primary / secondary percentages for the featured account.
    case dual
    /// Account handle plus percentage, e.g. "work 35%".
    case named
    /// One severity dot per account plus the peak percentage, e.g. "··· 62%".
    case allAccounts

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dot: return "Status dot"
        case .iconOnly: return "Icon only"
        case .ring: return "Usage ring"
        case .bars: return "Mini bars"
        case .percent: return "Percent"
        case .dual: return "Two limits"
        case .named: return "Account name"
        case .allAccounts: return "All accounts"
        }
    }
}

/// Which account the menu bar features when several are signed in.
enum MenuBarSubject: String, CaseIterable, Identifiable, Sendable {
    /// The account running in the frontmost terminal window, falling back to normalized
    /// capacity across all accounts when none can be mapped.
    case frontmost
    /// Always the account with the highest usage, regardless of what's frontmost.
    case peak

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .frontmost: return "Frontmost session"
        case .peak: return "Busiest account"
        }
    }
}
