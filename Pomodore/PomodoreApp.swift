import AppKit

@main
enum Pomodore {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication holds its delegate weakly.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: TimerEngine?
    private var store: SessionStore?
    private var menuBar: MenuBarController?
    private var alerts: Alerts?
    private var hotKey: HotKeyController?
    private var settingsWindow: SettingsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let settings = Settings()
        let engine = TimerEngine(settings: settings)
        let alerts = Alerts(settings: settings)
        let store = SessionStore()

        engine.onTransition = { [alerts, store] transition in
            alerts.handle(transition)
            store.record(transition)
        }
        engine.onDiscard = { [alerts] in alerts.handle($0) }

        // Toggle only, and deliberately without opening the popover: the point is to
        // start a session without a visual interruption, and showing the popover would
        // steal focus from whatever the user is about to work in.
        let hotKey = HotKeyController(settings: settings) { [engine] in engine.toggle() }
        hotKey.apply()

        let settingsWindow = SettingsWindow(engine: engine, hotKey: hotKey)

        self.engine = engine
        self.store = store
        self.alerts = alerts
        self.hotKey = hotKey
        self.settingsWindow = settingsWindow
        menuBar = MenuBarController(
            engine: engine,
            store: store,
            openSettings: { settingsWindow.show() }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A leaked assertion leaves the display awake until the process is reaped, and a
        // leaked registration can hold the chord until login.
        engine?.stop()
        hotKey?.stop()
    }
}
