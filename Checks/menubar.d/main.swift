// Guards the two placement bugs found by eye in Phase 1: a popover that hangs below the
// menu bar because the hosting controller reports no size, and a status item that
// changes width between idle and running and drags the open popover sideways.
//
// Needs a logged-in GUI session. It creates a real status item for a second or so.
import AppKit

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
var checks = 0

@MainActor
func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !ok {
        failures += 1
        let detail = detail()
        print("FAIL  \(what)\(detail.isEmpty ? "" : ": \(detail)")")
    }
}

@MainActor
final class Harness: NSObject, NSApplicationDelegate {
    var controller: MenuBarController!
    var engine: TimerEngine!
    let suite = "com.bisaya.Pomodore.menubarcheck"

    func applicationDidFinishLaunching(_ note: Notification) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        engine = TimerEngine(settings: Settings(defaults: defaults))
        // A throwaway store, so the real session log is never opened here.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pomodore-menubar-\(UUID().uuidString).json")
        controller = MenuBarController(
            engine: engine,
            store: SessionStore(url: scratch),
            openSettings: {}
        )

        NSApp.activate(ignoringOtherApps: true)

        // This check drives a real UI through timed stages, so a stage that never fires
        // would otherwise hang the whole run rather than fail it.
        after(60) {
            expect(false, "finished within 60 seconds", "a stage never completed")
            self.finish()
        }

        after(0.4) { self.run() }
    }

    func run() {
        controller.togglePopover()
        after(0.6) { self.stageIdle() }
    }

    func stageIdle() {
        let idle = geometry()
        expect(controller.popover.isShown, "popover opens")
        expect(abs(idle.gap) < 8, "popover sits against the menu bar", "gap \(idle.gap)pt")
        expect(abs(idle.buttonCentre - idle.popoverCentre) < 8,
               "popover is centred on the status item",
               "button \(idle.buttonCentre) vs popover \(idle.popoverCentre)")

        // Opening the popover to press Pause must not park a cursor in the tag field.
        // A live TextField takes first responder as soon as the window becomes key, which
        // is why the tag is click-to-edit.
        let responder = controller.popover.contentViewController?.view.window?.firstResponder
        expect(!(responder is NSTextView),
               "popover does not open with a text field focused",
               "first responder is \(responder.map { String(describing: type(of: $0)) } ?? "nil")")

        // Running swaps the SF Symbol for digits, the widest the item ever gets.
        engine.start()
        after(0.4) { self.stageRunning(idle) }
    }

    func stageRunning(_ idle: Geometry) {
        let running = geometry()
        expect(abs(running.buttonWidth - idle.buttonWidth) < 1,
               "status item width is unchanged by starting",
               "\(idle.buttonWidth) -> \(running.buttonWidth)")
        expect(running.popoverCentre == idle.popoverCentre,
               "open popover does not move when the timer starts",
               "\(idle.popoverCentre) -> \(running.popoverCentre)")

        // This is the sequence that moved it: running, then a segment tap back to idle.
        engine.select(.shortBreak)
        after(0.4) { self.stageSelected(idle) }
    }

    func stageSelected(_ idle: Geometry) {
        let selected = geometry()
        expect(abs(selected.buttonWidth - idle.buttonWidth) < 1,
               "status item width is unchanged by select",
               "\(idle.buttonWidth) -> \(selected.buttonWidth)")
        expect(selected.popoverCentre == idle.popoverCentre,
               "open popover does not move when a phase is selected",
               "\(idle.popoverCentre) -> \(selected.popoverCentre)")

        // The tag row only exists during focus.
        engine.select(.focus)
        after(0.4) { self.findTagRow() }
    }

    // MARK: - Tag focus

    /// Probed rather than hardcoded, so a layout change fails loudly instead of quietly
    /// testing nothing.
    private var candidates: [CGFloat] = []

    /// Swept rather than hardcoded so small layout drift does not quietly stop testing
    /// anything, but bounded to the band between the digits and the buttons. That band
    /// holds only inert SwiftUI views. Straying into the segmented control or a real
    /// NSButton wedges the run: those enter a nested tracking loop inside `mouseDown`
    /// that never sees the synthetic `mouseUp`, and the whole main queue stops, watchdog
    /// included. If the layout moves far enough, this fails loudly instead.
    static let tagRowSearch = stride(from: CGFloat(100), to: 158, by: 4)

    func findTagRow() {
        candidates = Array(Self.tagRowSearch)
        probeNext()
    }

    func probeNext() {
        guard let window = popoverWindow else {
            expect(false, "popover stayed open while probing")
            finish()
            return
        }
        guard let offset = candidates.first else {
            expect(false, "a click somewhere opens the tag editor",
                   "no point in the popover opened one")
            finish()
            return
        }
        candidates.removeFirst()

        click(window, atOffsetFromTop: offset)
        after(0.12) {
            if self.isEditing {
                expect(true, "clicking the tag row opens an editor")
                self.stageBlur(rowOffset: offset)
            } else {
                self.probeNext()
            }
        }
    }

    func stageBlur(rowOffset: CGFloat) {
        guard let window = popoverWindow else {
            expect(false, "popover stayed open while probing")
            finish()
            return
        }
        // The digits: inert, and well clear of any real control.
        click(window, atOffsetFromTop: 80)
        after(0.3) {
            expect(!self.isEditing,
                        "clicking elsewhere in the popover gives up focus",
                        "a field editor still holds it")
            self.finish()
        }
    }

    func finish() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    var popoverWindow: NSWindow? {
        controller.popover.contentViewController?.view.window
    }

    var isEditing: Bool {
        popoverWindow?.firstResponder is NSTextView
    }

    /// Synthesized inside our own process, so this needs no Accessibility grant.
    ///
    /// Posted to the queue rather than handed to `sendEvent`. AppKit controls run a
    /// nested tracking loop inside `mouseDown`, so a synchronously sent `mouseDown` never
    /// returns to deliver the matching `mouseUp` and the whole main queue wedges, taking
    /// the watchdog with it. Posting lets that tracking loop pull both events itself.
    /// It also keeps them going through `NSApp`, where local monitors can see them, which
    /// is what the click-away behaviour relies on.
    func click(_ window: NSWindow, atOffsetFromTop offset: CGFloat) {
        let point = NSPoint(x: window.frame.width / 2, y: window.frame.height - offset)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    struct Geometry {
        let buttonWidth: CGFloat
        let buttonCentre: CGFloat
        let popoverCentre: CGFloat
        /// Distance from the bottom of the status item to the top of the popover.
        let gap: CGFloat
    }

    func geometry() -> Geometry {
        guard let button = controller.statusItem.button, let window = button.window else {
            return Geometry(buttonWidth: 0, buttonCentre: 0, popoverCentre: 0, gap: .infinity)
        }
        let inScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        let popover = controller.popover.contentViewController?.view.window?.frame ?? .zero
        return Geometry(
            buttonWidth: inScreen.width,
            buttonCentre: inScreen.midX,
            popoverCentre: popover.midX,
            gap: inScreen.minY - popover.maxY
        )
    }

    func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let harness = Harness()
app.delegate = harness
app.run()
