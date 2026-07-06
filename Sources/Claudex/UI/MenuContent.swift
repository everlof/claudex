import SwiftUI

/// The panel shown when the menubar icon is clicked. Header + account cards + footer.
struct MenuContent: View {
    @Bindable var store: UsageStore
    /// Ticks every second so relative countdowns stay live while the panel is open.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            if store.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.entries) { entry in
                            AccountCard(
                                entry: entry,
                                now: now,
                                isFrontmost: entry.ref.id == store.frontmostAccountID
                            )
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 520)
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 340)
        .background(panelBackground)
        .onReceive(tick) { now = $0 }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Provider.claude.accentColor, Provider.codex.accentColor],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 30, height: 30)
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Usage")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(
                        store.isRefreshing
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: store.isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .help("Refresh now")
            .disabled(store.isRefreshing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var subtitle: String {
        let n = store.entries.count
        let accounts = "\(n) account\(n == 1 ? "" : "s")"
        return accounts
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.overallSeverity.color)
                .frame(width: 7, height: 7)
            Text(store.hasAnyError ? "Some accounts need attention" : "Updated \(Fmt.relativePast(store.lastRefresh, now: now))")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No accounts found")
                .font(.system(size: 12, weight: .medium))
            Text("Sign in with the Claude or Codex CLI, then refresh.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }

    private var panelBackground: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            LinearGradient(
                colors: [
                    Provider.claude.accentColor.opacity(0.05),
                    .clear,
                    Provider.codex.accentColor.opacity(0.05),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}
