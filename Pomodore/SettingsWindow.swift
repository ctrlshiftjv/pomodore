import AppKit
import SwiftUI

/// `LSUIElement` removes the app menu, which takes the SwiftUI `Settings` scene and its
/// Command-comma shortcut with it. Neither is reachable here, so the window is built by
/// hand and opened from the popover.
@MainActor
final class SettingsWindow {
    private let engine: TimerEngine
    private let hotKey: HotKeyController
    private var window: NSWindow?

    init(engine: TimerEngine, hotKey: HotKeyController) {
        self.engine = engine
        self.hotKey = hotKey
    }

    func show() {
        if window == nil {
            let fresh = make()
            fresh.center()
            window = fresh
        }

        // An accessory app is not frontmost, so the window would otherwise open behind
        // whatever the user is working in.
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func make() -> NSWindow {
        let hosting = NSHostingController(
            rootView: SettingsView(
                hotKey: hotKey,
                onDurationsChanged: { [engine] in engine.durationsChanged() },
                onWakeLockScopeChanged: { [engine] in engine.wakeLockScopeChanged() }
            )
        )
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = "Pomodore Settings"
        window.styleMask = [.titled, .closable]
        // Kept so repeated clicks focus this window rather than opening a second one, and
        // so closing it does not drop the position the user put it in.
        window.isReleasedWhenClosed = false
        return window
    }
}
