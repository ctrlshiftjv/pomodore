import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
var checks = 0

/// Our own assertions only. The installed app holds assertions with the same reason
/// string, so matching on the reason alone fails every check here whenever a real focus
/// session happens to be running.
let ours = "pid \(ProcessInfo.processInfo.processIdentifier)("
let reason = "Pomodoro focus session running"

func pmsetAssertions() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-g", "assertions"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

@MainActor
func report(_ label: String, expectHeld: Bool) {
    let lines = pmsetAssertions()
        .split(separator: "\n")
        .filter { $0.contains(reason) && $0.contains(ours) }
    let system = lines.contains { $0.contains("PreventUserIdleSystemSleep") }
    let display = lines.contains { $0.contains("PreventUserIdleDisplaySleep") }

    checks += 1
    if system != expectHeld || display != expectHeld {
        failures += 1
        print("FAIL  \(label): system=\(system) display=\(display) (want \(expectHeld))")
        for line in lines { print("       \(line.trimmingCharacters(in: .whitespaces))") }
    }
}

let defaults = UserDefaults(suiteName: "com.bisaya.Pomodore.verify")!
defaults.removePersistentDomain(forName: "com.bisaya.Pomodore.verify")
let settings = Settings(defaults: defaults)
settings.focusMinutes = 1
settings.shortBreakMinutes = 1

let engine = TimerEngine(settings: settings)

report("idle", expectHeld: false)

engine.start()
report("focus running", expectHeld: true)

engine.pause()
report("paused", expectHeld: false)

engine.start()
report("resumed", expectHeld: true)

engine.skip()
report("skipped into break", expectHeld: false)

engine.start()
report("break running", expectHeld: false)

engine.select(.focus)
engine.start()
report("focus again", expectHeld: true)

engine.stop()
report("after stop (terminate path)", expectHeld: false)

defaults.removePersistentDomain(forName: "com.bisaya.Pomodore.verify")

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
