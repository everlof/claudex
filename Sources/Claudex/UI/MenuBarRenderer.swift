import AppKit
import SwiftUI

/// Renders the status-item button content (image + attributed title) for every
/// `MenuBarStyle`. A pure function of the summary, so styles are cheap to add and the
/// AppKit delegate stays a thin shell.
@MainActor
enum MenuBarRenderer {

    struct Output {
        let image: NSImage?
        let title: NSAttributedString
    }

    static func render(_ summary: MenuBarSummary, style: MenuBarStyle) -> Output {
        switch style {
        case .dot:
            return Output(image: dotImage(summary), title: empty)
        case .iconOnly:
            return Output(image: gaugeGlyph(summary), title: empty)
        case .ring:
            return Output(image: ringImage(summary), title: empty)
        case .bars:
            return Output(image: barsImage(summary), title: empty)
        case .percent:
            return Output(image: gaugeGlyph(summary), title: text(singlePercent(summary)))
        case .dual:
            return Output(image: gaugeGlyph(summary), title: text(dualPercent(summary)))
        case .named:
            return Output(image: gaugeGlyph(summary), title: namedTitle(summary))
        case .allAccounts:
            return Output(image: nil, title: allAccountsTitle(summary))
        }
    }

    // MARK: Shared text bits

    private static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static var empty: NSAttributedString { NSAttributedString(string: "") }

    private static func text(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: percentFont])
    }

    private static func singlePercent(_ summary: MenuBarSummary) -> String {
        guard let p = summary.primaryPercent else { return "" }
        return " \(p)%"
    }

    private static func dualPercent(_ summary: MenuBarSummary) -> String {
        guard let p = summary.primaryPercent else { return "" }
        if let s = summary.secondaryPercent {
            return " \(p) / \(s)%"
        }
        return " \(p)%"
    }

    /// "work 35%" — handle in a muted secondary weight, percent in the usual digits.
    private static func namedTitle(_ summary: MenuBarSummary) -> NSAttributedString {
        guard let p = summary.primaryPercent else { return empty }
        guard summary.isFeatured, let handle = summary.handle else { return text(" \(p)%") }
        let shown = handle.count > 14 ? "\(handle.prefix(13))…" : handle
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: " \(shown) ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        title.append(NSAttributedString(string: "\(p)%", attributes: [.font: percentFont]))
        return title
    }

    /// One severity-coloured dot per account plus normalized portfolio pressure.
    private static func allAccountsTitle(_ summary: MenuBarSummary) -> NSAttributedString {
        guard !summary.badges.isEmpty else { return text("–") }
        let title = NSMutableAttributedString()
        for badge in summary.badges {
            title.append(NSAttributedString(string: "●", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: NSColor(badge.severity.color),
                .kern: 2,
                .baselineOffset: 1,
            ]))
        }
        if !summary.badges.isEmpty {
            let pressure = summary.badges.map(\.fraction).reduce(0, +) / Double(summary.badges.count)
            title.append(NSAttributedString(string: " \(Int((pressure * 100).rounded()))%",
                                            attributes: [.font: percentFont]))
        }
        return title
    }

    // MARK: Gauge glyph (SF Symbol)

    private static func gaugeGlyph(_ summary: MenuBarSummary) -> NSImage? {
        let name: String
        if summary.badges.isEmpty {
            name = "gauge.with.dots.needle.bottom.0percent"
        } else {
            switch summary.severity {
            case .normal: name = "gauge.with.dots.needle.33percent"
            case .warning: name = "gauge.with.dots.needle.67percent"
            case .critical: name = "gauge.with.dots.needle.100percent"
            }
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "usage")?
            .withSymbolConfiguration(config)
        if let provider = summary.provider, let base {
            let tinted = base.tinted(with: NSColor(provider.accentColor))
            tinted.isTemplate = false
            return tinted
        }
        base?.isTemplate = true
        return base
    }

    // MARK: Drawn styles

    /// Severity dot; a provider-tinted ring surrounds it when an account is featured.
    private static func dotImage(_ summary: MenuBarSummary) -> NSImage {
        let fill = summary.badges.isEmpty
            ? NSColor.tertiaryLabelColor
            : NSColor(summary.severity.color)
        let ring = summary.provider.map { NSColor($0.accentColor) }
        let image = NSImage(size: NSSize(width: 13, height: 13), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
            if let ring {
                ring.setStroke()
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                path.lineWidth = 1.5
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A ring that fills clockwise with the primary fraction, severity-coloured,
    /// with a provider dot in the centre when an account is featured.
    private static func ringImage(_ summary: MenuBarSummary) -> NSImage {
        // Featured account: its live primary window. Fallback: portfolio pressure.
        let fraction = summary.primaryFraction ?? 0
        let color = summary.badges.isEmpty
            ? NSColor.tertiaryLabelColor
            : NSColor(summary.severity.color)
        let providerColor = summary.provider.map { NSColor($0.accentColor) }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let lineWidth: CGFloat = 2.5
            let circleRect = rect.insetBy(dx: lineWidth / 2 + 0.5, dy: lineWidth / 2 + 0.5)
            let center = NSPoint(x: rect.midX, y: rect.midY)

            let track = NSBezierPath(ovalIn: circleRect)
            track.lineWidth = lineWidth
            NSColor.labelColor.withAlphaComponent(0.2).setStroke()
            track.stroke()

            if fraction > 0.01 {
                let progress = NSBezierPath()
                progress.appendArc(
                    withCenter: center,
                    radius: circleRect.width / 2,
                    startAngle: 90,
                    endAngle: 90 - min(1, fraction) * 360,
                    clockwise: true
                )
                progress.lineWidth = lineWidth
                progress.lineCapStyle = .round
                color.setStroke()
                progress.stroke()
            }

            if let providerColor {
                providerColor.setFill()
                let r: CGFloat = 2.25
                NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r,
                                            width: r * 2, height: r * 2)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Two stacked mini bars — primary on top, secondary below — each coloured by its own
    /// severity. A provider-tinted strip on the left marks a featured account.
    private static func barsImage(_ summary: MenuBarSummary) -> NSImage {
        let fractions = [summary.primaryFraction, summary.secondaryFraction].compactMap { $0 }
        let providerColor = summary.provider.map { NSColor($0.accentColor) }
        let size = NSSize(width: 19, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            let barHeight: CGFloat = 3.5
            let radius = barHeight / 2
            let barX: CGFloat = providerColor == nil ? 0 : 4
            let barWidth = rect.width - barX

            if let providerColor {
                providerColor.setFill()
                let strip = NSRect(x: 0, y: 2.5, width: 2, height: rect.height - 5)
                NSBezierPath(roundedRect: strip, xRadius: 1, yRadius: 1).fill()
            }

            // Top row is the primary window; single-window accounts get one
            // centred bar. No data at all draws hollow tracks.
            let rows: [(y: CGFloat, fraction: Double?)]
            switch fractions.count {
            case 0: rows = [(8.5, nil), (3.0, nil)]
            case 1: rows = [((rect.height - barHeight) / 2, fractions[0])]
            default: rows = [(8.5, fractions[0]), (3.0, fractions[1])]
            }

            for row in rows {
                let track = NSRect(x: barX, y: row.y, width: barWidth, height: barHeight)
                NSColor.labelColor.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
                guard let fraction = row.fraction, fraction > 0 else { continue }
                let fillWidth = max(barHeight, barWidth * min(1, fraction))
                NSColor(Severity.from(fraction: fraction).color).setFill()
                let fill = NSRect(x: barX, y: row.y, width: fillWidth, height: barHeight)
                NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
