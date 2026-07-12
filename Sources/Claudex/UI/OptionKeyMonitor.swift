import SwiftUI
import AppKit

/// Tracks whether the Option (⌥) key is currently held, so the panel can flip reset
/// countdowns to absolute clock times while it's down. A single shared monitor drives
/// every view at once, so they toggle in lockstep.
///
/// `NSEvent.addLocalMonitorForEvents(.flagsChanged)` only fires while our window has key
/// focus (which the popover does while open); we also seed from `NSEvent.modifierFlags`
/// on start so a key already held when the panel opens is reflected immediately.
@MainActor
@Observable
final class OptionKeyMonitor {
    static let shared = OptionKeyMonitor()

    private(set) var isOptionDown = false

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var refCount = 0

    private init() {}

    /// Begin observing while a view that cares is on screen. Balanced by `release()`.
    func retain() {
        refCount += 1
        guard monitor == nil else { return }
        isOptionDown = NSEvent.modifierFlags.contains(.option)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.isOptionDown = event.modifierFlags.contains(.option)
            }
            return event
        }
    }

    func release() {
        refCount = max(0, refCount - 1)
        guard refCount == 0, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        isOptionDown = false
    }
}

/// Attaches the shared Option-key monitor for the lifetime of the modified view.
private struct OptionKeyTracking: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { OptionKeyMonitor.shared.retain() }
            .onDisappear { OptionKeyMonitor.shared.release() }
    }
}

extension View {
    /// Keep the shared `OptionKeyMonitor` live while this view is on screen.
    func tracksOptionKey() -> some View { modifier(OptionKeyTracking()) }
}
