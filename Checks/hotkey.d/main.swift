// Carbon hot key registration. Needs an NSApplication for GetApplicationEventTarget,
// so this runs as an accessory app for a moment. It never synthesizes a keystroke:
// that needs the very permission this feature exists to avoid.
import AppKit
import Carbon.HIToolbox

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
var checks = 0

@MainActor
func expect(_ got: Bool, _ want: Bool, _ what: String) {
    checks += 1
    if got != want {
        failures += 1
        print("FAIL  \(what): got \(got), want \(want)")
    }
}

@MainActor
final class Harness: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        let hotKey = HotKey()

        expect(hotKey.register(.default) {}, true, "the default chord registers")

        hotKey.unregister()
        expect(
            hotKey.register(.default) {},
            true,
            "and registers again after unregistering, so teardown is clean"
        )

        // Re-registering over a live registration must not leak the old one.
        expect(
            hotKey.register(Chord(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .option, .command])) {},
            true,
            "a different chord replaces the first"
        )

        hotKey.unregister()

        // The real failure mode the Settings warning exists for: the chord is already
        // claimed. Carbon returns eventHotKeyExistsErr (-9878) rather than failing
        // silently. Note it does NOT refuse chords the system owns, like command-Tab,
        // nor absurd key codes: those register happily and simply never fire.
        let holder = HotKey()
        expect(holder.register(.default) {}, true, "one holder claims the chord")
        let contender = HotKey()
        expect(
            contender.register(.default) {},
            false,
            "a second claim on the same chord is refused, so the warning can be shown"
        )
        contender.unregister()
        holder.unregister()

        // The handler is installed with a *retained* pointer to its HotKey, so that
        // dropping a registered one cannot leave the handler resolving freed memory.
        // `unregister()` has to balance that retain or every re-registration would leak an
        // instance, and the deallocation below is the only way to see that it does.
        weak var dropped: HotKey?
        do {
            let temporary = HotKey()
            dropped = temporary
            expect(temporary.register(.default) {}, true, "a temporary instance registers")
            temporary.unregister()
        }
        expect(dropped == nil, true, "unregister balances the retain, so the instance frees")

        let controller = HotKeyController(
            settings: Settings(defaults: UserDefaults(suiteName: "com.bisaya.Pomodore.hotkeycheck")!),
            action: {}
        )
        controller.apply()
        expect(controller.isRegistered, true, "the controller reports a successful registration")
        controller.stop()
        UserDefaults().removePersistentDomain(forName: "com.bisaya.Pomodore.hotkeycheck")

        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let harness = Harness()
app.delegate = harness
app.run()
