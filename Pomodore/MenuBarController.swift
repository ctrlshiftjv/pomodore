import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    static let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    private let engine: TimerEngine

    /// Last title actually pushed to the button, so a tick inside the same second does no
    /// layout work. Starts as a value no render can produce.
    private var rendered = ""

    /// No defaults for `store` or `openSettings`: a defaulted store would quietly open the
    /// real session log, which is the last thing a check wants, and a defaulted closure
    /// would make Settings… a silent no-op.
    init(engine: TimerEngine, store: SessionStore, openSettings: @escaping () -> Void) {
        self.engine = engine
        super.init()

        popover.behavior = .transient
        // Measured: the open animation puts the popover on screen ~330ms after the click,
        // against ~5ms without it. Every NSMenu-backed item in the bar appears instantly,
        // so the animation reads as this app being slow rather than as polish.
        popover.animates = false

        let hosting = NSHostingController(
            rootView: PopoverView(
                engine: engine,
                store: store,
                openSettings: { [weak self] in
                    // .transient only dismisses on clicks outside, so the popover would
                    // otherwise stay up behind the settings window.
                    self?.popover.performClose(nil)
                    openSettings()
                },
                quit: { NSApp.terminate(nil) }
            )
        )
        // Required. Without it the hosting controller reports no content size, so the
        // popover positions itself for a guessed one and then keeps its bottom-left
        // origin when SwiftUI's real layout arrives, leaving it hanging ~110pt below the
        // menu bar and off centre.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        // Build the SwiftUI tree now rather than on the first click. The popover cannot
        // position itself until that layout arrives, so leaving it lazy puts the whole
        // cost in front of the first open.
        hosting.view.layoutSubtreeIfNeeded()

        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        pinWidth()

        engine.onRender = { [weak self] in self?.renderTitle() }
        renderTitle()
    }

    /// Size the item once for the widest title it will ever hold and never let it resize.
    ///
    /// `variableLength` is the obvious choice and the wrong one. The item is narrow while
    /// idle (an SF Symbol) and wide while running (`24:55`), so every transition between
    /// the two moves the button, nudges its neighbours, and drags an open popover
    /// sideways with it. Monospaced digits stop the width changing second to second;
    /// this stops it changing state to state.
    ///
    /// The cost is a permanently wider idle item than the symbol needs. Worth it: a menu
    /// bar item that moves while you are looking at it is worse than one that is 25pt
    /// wider than strictly necessary.
    private func pinWidth() {
        guard let button = statusItem.button else { return }
        let previous = button.attributedTitle
        button.attributedTitle = NSAttributedString(
            string: "88:88",
            attributes: [.font: Self.digitFont]
        )
        button.sizeToFit()
        statusItem.length = button.frame.width + Self.statusBarPadding
        button.attributedTitle = previous
    }

    /// The status bar adds horizontal padding of its own on top of the button's fitting
    /// size. Measured at 16pt: `sizeToFit` gives 41pt for `88:88`, where the same title
    /// under `variableLength` settles at 57pt. Pinning to the fitting size alone leaves
    /// the digits cramped against the neighbouring items.
    private static let statusBarPadding: CGFloat = 16

    // MARK: - Title

    private func renderTitle() {
        guard let button = statusItem.button else { return }

        if engine.isIdle {
            guard rendered != "idle" else { return }
            rendered = "idle"
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Pomodore")
            return
        }

        // Dimming alone separates break from focus. Colour would fight every wallpaper.
        let opacity: CGFloat = engine.isPaused ? 0.4 : (engine.phase.isBreak ? 0.6 : 1.0)
        let digits = engine.remaining.mmss
        let key = "\(digits)@\(opacity)"
        guard rendered != key else { return }
        rendered = key

        button.image = nil
        button.attributedTitle = NSAttributedString(
            string: digits,
            attributes: [
                .font: Self.digitFont,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(opacity),
            ]
        )
    }

    // MARK: - Interaction

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // An accessory app is never frontmost, so without this the popover's text fields
        // silently swallow keystrokes. It comes after the show: activation is
        // asynchronous, and ordering it first makes the popover wait on the window server
        // taking focus off the frontmost app before it can appear.
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Reset is deliberate enough to live behind a right-click rather than take popover room.
    private func showContextMenu() {
        guard let button = statusItem.button else { return }

        let menu = NSMenu()
        let reset = NSMenuItem(title: "Reset timer", action: #selector(resetTimer), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Pomodore", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func resetTimer() {
        engine.reset()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
