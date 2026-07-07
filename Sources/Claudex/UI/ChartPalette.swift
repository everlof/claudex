import SwiftUI

/// Colours for the usage-history chart, validated against the app's dark chart surface
/// (`#1a1e1b`) with the data-viz palette validator.
///
/// - **By provider** (2 series): terracotta / teal, darkened into the dark lightness band
///   (worst adjacent CVD ΔE ≈ 37 — well clear of the ≥12 target).
/// - **By model / account** (>2 series): the validated reference categorical order, warm
///   hues assigned to Claude series and cool to Codex so provider identity survives. Worst
///   adjacent ΔE ≈ 10 (the floor band), so the chart always ships a legend + direct labels
///   as the required secondary encoding.
enum ChartPalette {

    /// Provider hero colours — on-brand terracotta/teal, band-corrected for the dark surface.
    static func provider(_ p: Provider) -> Color {
        switch p {
        case .claude: return Color(hex: 0xd9752f)
        case .codex:  return Color(hex: 0x3ea986)
        }
    }

    /// Ordered categorical slots (validated) for the model/account breakdowns. Warm slots
    /// first (Claude), cool after (Codex), so the two provider families stay visually apart.
    private static let claudeRamp: [Color] = [
        Color(hex: 0xd9752f), // terracotta  (matches provider Claude)
        Color(hex: 0xc98500), // amber
        Color(hex: 0xe66767), // red
        Color(hex: 0xd55181), // magenta
    ]
    private static let codexRamp: [Color] = [
        Color(hex: 0x3ea986), // teal  (matches provider Codex)
        Color(hex: 0x3987e5), // blue
        Color(hex: 0x199e70), // green-teal
        Color(hex: 0x9085e9), // violet
    ]

    /// Assign stable colours to a set of series names grouped by provider. Each provider's
    /// series get consecutive slots from that provider's ramp, so colour follows the entity
    /// (never its rank) and a filter that drops a series never repaints the survivors.
    static func assign(series: [(name: String, provider: Provider)]) -> [String: Color] {
        var claudeIdx = 0, codexIdx = 0
        var map: [String: Color] = [:]
        for s in series where map[s.name] == nil {
            switch s.provider {
            case .claude:
                map[s.name] = claudeRamp[claudeIdx % claudeRamp.count]
                claudeIdx += 1
            case .codex:
                map[s.name] = codexRamp[codexIdx % codexRamp.count]
                codexIdx += 1
            }
        }
        return map
    }
}

extension Color {
    /// Build a Color from a 0xRRGGBB literal (sRGB), for the validated palette hexes.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}
