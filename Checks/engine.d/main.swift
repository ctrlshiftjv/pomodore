import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
var checks = 0

@MainActor
func expect(_ ok: Bool, _ what: String) {
    checks += 1
    if !ok {
        failures += 1
        print("FAIL  \(what)")
    }
}

@MainActor
func expect<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    checks += 1
    if got != want {
        failures += 1
        print("FAIL  \(what): got \(got), want \(want)")
    }
}

// A fake clock we can jump forward, standing in for real time and for sleep.
@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

let suite = "com.bisaya.Pomodore.harness"

@MainActor
func makeEngine(
    _ configure: (Settings) -> Void = { _ in }
) -> (TimerEngine, FakeClock, Settings) {
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let settings = Settings(defaults: defaults)
    configure(settings)
    let clock = FakeClock()
    let engine = TimerEngine(settings: settings, clock: { clock.now })
    return (engine, clock, settings)
}

// ---------------------------------------------------------------- mmss rounding

expect(TimeInterval(1500).mmss, "25:00", "mmss full focus")
expect(TimeInterval(0).mmss, "00:00", "mmss zero")
expect(TimeInterval(-5).mmss, "00:00", "mmss negative clamps")
expect(TimeInterval(59.2).mmss, "01:00", "mmss rounds up")
expect(TimeInterval(61).mmss, "01:01", "mmss minute boundary")

// ---------------------------------------------------------------- initial state

do {
    let (engine, _, _) = makeEngine()
    expect(engine.phase, .focus, "starts in focus")
    expect(engine.isIdle, true, "starts idle")
    expect(engine.remaining, 1500, "starts at 25 minutes")
    expect(engine.wakeLockHeld, false, "no assertion while idle")
    expect(engine.cycleLabel, "1 of 4", "cycle label at start")
}

// ---------------------------------------------------- deadline, not countdown

do {
    let (engine, clock, _) = makeEngine()
    engine.start()
    expect(engine.isRunning, true, "running after start")
    expect(engine.wakeLockHeld, true, "assertion held during focus")

    // No ticks delivered at all, as if App Nap throttled us or the Mac slept.
    clock.advance(600)
    engine.refresh()
    expect(engine.remaining, 900, "remaining derived from the deadline, not accumulated ticks")

    engine.pause()
    expect(engine.isPaused, true, "paused")
    expect(engine.remaining, 900, "pause captures the live remainder")
    expect(engine.wakeLockHeld, false, "assertion released on pause")

    clock.advance(10_000)
    engine.refresh()
    expect(engine.remaining, 900, "a paused timer does not drain")

    engine.start()
    expect(engine.remaining, 900, "resume rebuilds the deadline from the remainder")
    clock.advance(899)
    engine.refresh()
    expect(engine.remaining, 1, "ticking down after resume")
}

// ---------------------------------------------------------------- the cycle

do {
    let (engine, clock, _) = makeEngine()
    var transitions: [Transition] = []
    engine.onTransition = { transitions.append($0) }

    // focus -> short -> focus -> short -> focus -> short -> focus -> LONG
    var phases: [Phase] = []
    for _ in 0..<8 {
        phases.append(engine.phase)
        engine.start()
        clock.advance(engine.remaining)
        engine.refresh()
    }
    expect(
        phases,
        [.focus, .shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak],
        "four focus sessions then a long break"
    )
    expect(engine.phase, .focus, "a long break returns to focus")
    expect(engine.completedInCycle, 0, "long break resets the cycle")
    expect(transitions.count, 8, "one transition per completed phase")
    expect(transitions.allSatisfy(\.completedNaturally), true, "all natural completions")
}

// ---------------------------------------------------------------- auto-advance

do {
    let (engine, clock, _) = makeEngine()
    engine.start()
    clock.advance(1500)
    engine.refresh()
    expect(engine.phase, .shortBreak, "focus rolls into the break")
    expect(engine.isRunning, true, "breaks start themselves by default")
    expect(engine.wakeLockHeld, false, "no assertion during a break")

    clock.advance(300)
    engine.refresh()
    expect(engine.phase, .focus, "break rolls into focus")
    expect(engine.isPaused, true, "but focus waits to be started deliberately")
    expect(engine.remaining, 1500, "loaded at full duration")
    expect(engine.wakeLockHeld, false, "no assertion until focus actually runs")
}

// -------------------------------------------- several deadlines in one sleep

do {
    let (engine, clock, _) = makeEngine()
    var transitions: [Transition] = []
    engine.onTransition = { transitions.append($0) }

    engine.start()
    clock.advance(3600)  // an hour asleep: focus and the break both elapsed
    engine.refresh()

    expect(transitions.count, 1, "one completion fires, not one per elapsed deadline")
    expect(transitions.first?.ended, .focus, "the phase that was actually running completed")
    expect(engine.completedInCycle, 1, "exactly one session counted")
    expect(engine.phase, .shortBreak, "landed in the next phase")
    expect(engine.isPaused, true, "paused despite auto-advance, so no session is burned")
    expect(engine.remaining, 300, "at the next phase's full duration")
}

// ------------------------------------------------- the crossing fires once

do {
    let (engine, clock, _) = makeEngine()
    var count = 0
    engine.onTransition = { _ in count += 1 }

    engine.start()
    clock.advance(1500)
    engine.refresh()
    engine.refresh()
    engine.refresh()
    expect(count, 1, "extra ticks after the crossing cannot re-fire it")
}

// ---------------------------------------------------------------- skip

do {
    let (engine, clock, _) = makeEngine()
    var transitions: [Transition] = []
    engine.onTransition = { transitions.append($0) }

    engine.start()
    clock.advance(60)
    engine.refresh()
    engine.skip()

    expect(engine.phase, .shortBreak, "skip advances the cycle")
    expect(engine.completedInCycle, 0, "skipping is not finishing, so nothing is counted")
    expect(engine.isPaused, true, "skip never auto-starts the next phase")
    expect(transitions.count, 1, "skip still emits a transition")
    expect(transitions.first?.completedNaturally, false, "marked as not a natural completion")
    expect(transitions.first?.tag, nil, "a skip carries no tag")
    expect(engine.wakeLockHeld, false, "assertion released on skip")
}

// ---------------------------------------------------------------- select

do {
    let (engine, clock, _) = makeEngine()
    var discarded: Discard?
    engine.onDiscard = { discarded = $0 }

    engine.start()
    clock.advance(600)
    engine.refresh()
    engine.select(.longBreak)

    expect(engine.phase, .longBreak, "select overrides the phase")
    expect(engine.isIdle, true, "select lands idle, not paused")
    expect(engine.remaining, 900, "at the selected phase's full duration")
    expect(engine.completedInCycle, 0, "select leaves the cycle position alone")
    expect(discarded?.from, .focus, "reported which phase was discarded")
    expect(discarded?.to, .longBreak, "and what replaced it")
    expect(discarded?.elapsed, 600, "and how long it had run")
    expect(engine.wakeLockHeld, false, "assertion released by select")
}

do {
    // select on the phase already loaded is how you get back to a clean 25:00
    let (engine, clock, _) = makeEngine()
    engine.start()
    clock.advance(1200)
    engine.refresh()
    engine.select(.focus)
    expect(engine.remaining, 1500, "re-selecting the current phase re-derives its duration")
}

do {
    // a near-instant switch is not worth telling the user about
    let (engine, clock, _) = makeEngine()
    var fired = false
    engine.onDiscard = { _ in fired = true }
    engine.start()
    clock.advance(5)
    engine.refresh()
    engine.select(.shortBreak)
    expect(fired, false, "no discard notice for a handful of seconds")
}

// ---------------------------------------------------------------- alert copy

do {
    let (engine, clock, settings) = makeEngine()
    let alerts = Alerts(settings: settings)
    var transitions: [Transition] = []
    engine.onTransition = { transitions.append($0) }

    engine.start()
    clock.advance(1500)
    engine.refresh()
    let focusEnded = transitions.last!
    expect(alerts.title(for: focusEnded), "Focus complete", "focus banner title")
    expect(alerts.body(for: focusEnded), "Take a 5 minute break.", "focus banner names the break")

    clock.advance(300)
    engine.refresh()
    let breakEnded = transitions.last!
    expect(alerts.title(for: breakEnded), "Break over", "break banner title")
    expect(
        alerts.body(for: breakEnded),
        "Back to it. Session 2 of 4.",
        "break banner counts the session about to start"
    )

    expect(settings.sound(forEnding: .focus), "Glass", "focus-ended sound default")
    expect(settings.sound(forEnding: .shortBreak), "Ping", "break-ended sound default")
    expect(settings.sound(forEnding: .longBreak), "Ping", "long break uses the break sound")
}

do {
    // the long break names the next long break's duration, not the short one's
    let (engine, clock, settings) = makeEngine { $0.sessionsPerLongBreak = 2 }
    let alerts = Alerts(settings: settings)
    var transitions: [Transition] = []
    engine.onTransition = { transitions.append($0) }

    // focus -> short -> focus -> LONG -> focus, so four completions to finish the long one
    for _ in 0..<4 {
        engine.start()
        clock.advance(engine.remaining)
        engine.refresh()
    }
    let intoLong = transitions.first { $0.next == .longBreak }
    expect(intoLong != nil, "reached a long break")
    expect(alerts.body(for: intoLong!), "Take a 15 minute break.", "long break duration in the body")

    let afterLong = transitions.last!
    expect(afterLong.ended, .longBreak, "long break completed")
    expect(
        alerts.body(for: afterLong),
        "Back to it. Session 1 of 2.",
        "the cycle restarts at session 1 after a long break"
    )
}

do {
    // a skip is deliberate, so it stays silent
    let (engine, clock, _) = makeEngine()
    var transitions: [Transition] = []
    engine.onTransition = { transitions.append($0) }
    engine.start()
    clock.advance(60)
    engine.refresh()
    engine.skip()
    expect(transitions.last?.completedNaturally, false, "a skip is marked unnatural so alerts drop it")
}

// ---------------------------------------------------------------- system sounds

do {
    expect(SystemSounds.names.isEmpty, false, "found system sounds")
    expect(SystemSounds.names.contains("Glass"), true, "Glass is available")
    expect(SystemSounds.names.contains("Ping"), true, "Ping is available")
    expect(
        SystemSounds.options(including: "Vanished").contains("Vanished"),
        true,
        "a stored sound stays selectable even if the system drops it"
    )
}

// ---------------------------------------------------------------- reset

do {
    let (engine, clock, _) = makeEngine()
    engine.start()
    clock.advance(1500)
    engine.refresh()  // now in shortBreak, running
    clock.advance(100)
    engine.refresh()
    engine.reset()

    expect(engine.phase, .shortBreak, "reset stays in the current phase")
    expect(engine.isIdle, true, "reset lands idle")
    expect(engine.remaining, 300, "back at the start of the phase")
    expect(engine.completedInCycle, 1, "reset leaves the cycle position alone")
}

// ------------------------------------------------- settings applied mid-flight

do {
    let (engine, clock, settings) = makeEngine()
    engine.start()
    clock.advance(60)
    engine.refresh()

    settings.focusMinutes = 50
    engine.durationsChanged()
    expect(engine.remaining, 1440, "a running session keeps its absolute deadline")

    engine.select(.focus)
    expect(engine.remaining, 3000, "the new duration applies to the next session")
}

do {
    let (engine, clock, settings) = makeEngine()
    engine.start()
    clock.advance(1500)
    engine.refresh()
    clock.advance(300)
    engine.refresh()  // focus loaded and paused, nothing elapsed

    expect(engine.isPaused, true, "sitting at an unstarted focus phase")
    settings.focusMinutes = 30
    engine.durationsChanged()
    expect(engine.remaining, 1800, "an untouched phase re-derives from the new setting")
}

// ------------------------------------------------- wake lock scope and clamping

do {
    let (engine, _, settings) = makeEngine { $0.wakeLockIncludesDisplay = false }
    engine.start()
    expect(engine.wakeLockHeld, true, "assertion held with the display lock off")
    settings.wakeLockIncludesDisplay = true
    engine.wakeLockScopeChanged()
    expect(engine.wakeLockHeld, true, "still held after a scope change")
    engine.stop()
    expect(engine.wakeLockHeld, false, "released on terminate")
}

do {
    let (_, _, settings) = makeEngine()
    settings.focusMinutes = 0
    expect(settings.focusMinutes, 1, "focus duration clamps to at least a minute")
    settings.focusMinutes = 9999
    expect(settings.focusMinutes, 120, "focus duration clamps at two hours")
    settings.sessionsPerLongBreak = 1
    expect(settings.sessionsPerLongBreak, 2, "at least two sessions per long break")
}

// ------------------------------------------------- cycle length is configurable

do {
    let (engine, clock, _) = makeEngine { $0.sessionsPerLongBreak = 2 }
    engine.start()
    clock.advance(1500)
    engine.refresh()
    expect(engine.phase, .shortBreak, "first break is short")
    expect(engine.cycleLabel, "after 1 of 2", "break cycle label")
    clock.advance(300)
    engine.refresh()
    engine.start()
    clock.advance(1500)
    engine.refresh()
    expect(engine.phase, .longBreak, "second focus earns the long break")
}

// ---------------------------------------------------------------- tag handling

do {
    let (engine, clock, _) = makeEngine()
    var transitions: [Transition] = []
    engine.onTransition = { transitions.append($0) }

    engine.currentTag = "Writing docs"
    engine.start()
    clock.advance(1500)
    engine.refresh()
    expect(transitions.last?.tag, "Writing docs", "focus completion carries the tag")

    clock.advance(300)
    engine.refresh()
    expect(transitions.last?.ended, .shortBreak, "break completed")
    expect(transitions.last?.tag, nil, "breaks never carry a tag")
    expect(engine.currentTag, "Writing docs", "the tag carries into the next focus phase")
}

UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
