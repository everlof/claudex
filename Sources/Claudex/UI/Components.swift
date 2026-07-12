import SwiftUI

// MARK: - Usage ring

/// A circular gauge showing one fraction, with the percent in the middle. The ring
/// colour tracks severity; at critical it gains a soft glow.
struct UsageRing: View {
    let fraction: Double
    let severity: Severity
    var size: CGFloat = 46
    var lineWidth: CGFloat = 5
    var label: String? = nil

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(
                    severity.color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(
                    color: severity == .critical ? severity.color.opacity(0.6) : .clear,
                    radius: severity == .critical ? 5 : 0
                )
                .animation(.smooth(duration: 0.5), value: fraction)

            VStack(spacing: 0) {
                Text("\(Int((fraction * 100).rounded()))")
                    .font(.system(size: size * 0.30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("%")
                    .font(.system(size: size * 0.16, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .offset(y: -1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(label ?? "usage")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

// MARK: - Window bar

/// A labelled horizontal usage bar with a percent and a reset countdown — the primary
/// row inside an account card.
struct WindowBar: View {
    let window: UsageWindow
    var now: Date
    /// When true (Option held), the reset shows an absolute local clock time instead of a
    /// countdown. Driven by the shared `OptionKeyMonitor` so every bar flips together.
    private var optionDown: Bool { OptionKeyMonitor.shared.isOptionDown }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                Spacer(minLength: 4)
                if let reset = resetText {
                    Label(reset, systemImage: optionDown ? "calendar" : "arrow.clockwise")
                        .font(.system(size: 10, weight: .regular))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .help(optionDown ? "Resets at this local time" : "Time until reset (hold ⌥ for the clock time)")
                }
                Text("\(window.percent)%")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(window.severity == .normal ? .primary : window.severity.color)
                    .frame(minWidth: 30, alignment: .trailing)
            }
            track
        }
    }

    /// The reset label: absolute local time while Option is held, otherwise a countdown.
    private var resetText: String? {
        optionDown
            ? Fmt.absoluteReset(window.resetsAt, now: now)
            : Fmt.relativeFuture(window.resetsAt, now: now)
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let elapsed = window.timeElapsedFraction(now: now)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [window.severity.color.opacity(0.85), window.severity.color],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(4, w * min(1, window.fraction)))
                    .animation(.smooth(duration: 0.5), value: window.fraction)

                // "Now" marker: how far through the reset window we are in time. Compare
                // its position to the fill edge to read your pace at a glance — fill left
                // of the tick means you're using slower than the clock.
                if let elapsed {
                    TimeMarker()
                        .position(x: w * elapsed, y: 3)
                }
            }
        }
        .frame(height: 6)
    }
}

/// A slim vertical "now" tick that overhangs the usage bar, with a soft halo so it reads
/// as a time reference rather than more usage.
private struct TimeMarker: View {
    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.9))
            .frame(width: 2, height: 11)
            .overlay(
                Capsule()
                    .stroke(Color(nsColor: .windowBackgroundColor).opacity(0.9), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0)
    }
}

// MARK: - Status dot

/// A small filled circle with a faint halo used next to titles.
struct StatusDot: View {
    let severity: Severity
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(severity.color)
            .frame(width: size, height: size)
            .overlay(
                Circle().stroke(severity.color.opacity(0.35), lineWidth: severity == .normal ? 0 : 3)
            )
    }
}

// MARK: - Pill

/// A compact rounded tag used for plan labels and counts.
struct Pill: View {
    let text: String
    var tint: Color = .secondary
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.4)
            .foregroundStyle(filled ? Color.black.opacity(0.8) : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(filled ? tint.opacity(0.9) : tint.opacity(0.14))
            )
    }
}
