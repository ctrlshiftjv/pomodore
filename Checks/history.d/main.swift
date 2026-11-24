// Session history, tag normalization, and the derived figures the popover shows.
// Writes only to a throwaway file in a temp directory.
import AppKit
import Carbon.HIToolbox

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
var checks = 0

@MainActor
func expect<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    checks += 1
    if got != want {
        failures += 1
        print("FAIL  \(what): got \(got), want \(want)")
    }
}

@MainActor
func expect(_ ok: Bool, _ what: String) {
    checks += 1
    if !ok {
        failures += 1
        print("FAIL  \(what)")
    }
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pomodore-checks-\(UUID().uuidString)", isDirectory: true)

@MainActor
func makeStore(at name: String = "sessions.json", now: Date = Date()) -> SessionStore {
    SessionStore(url: scratch.appendingPathComponent(name), clock: { now })
}

@MainActor
func transition(tag: String?, minutes: Int = 25, natural: Bool = true, phase: Phase = .focus)
    -> Transition
{
    Transition(
        ended: phase,
        next: .shortBreak,
        tag: tag,
        plannedDuration: TimeInterval(minutes) * 60,
        completedInCycle: 1,
        completedNaturally: natural
    )
}

let calendar = Calendar.current
let today = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

@MainActor
func daysAgo(_ count: Int) -> Date {
    calendar.date(byAdding: .day, value: -count, to: today)!
}

// ---------------------------------------------------------------- normalization

expect(Tag.normalized("  writing docs  "), "writing docs", "trims")
expect(Tag.normalized("writing    docs"), "writing docs", "collapses inner whitespace")
expect(Tag.normalized("writing\t\ndocs"), "writing docs", "collapses tabs and newlines")
expect(Tag.normalized(""), nil, "empty becomes nil")
expect(Tag.normalized("   "), nil, "whitespace-only becomes nil")
expect(Tag.normalized(nil), nil, "nil stays nil")
expect(Tag.key("Writing"), Tag.key("writing "), "grouping is case and space insensitive")
expect(Tag.key(nil), "", "untagged has its own key")
expect(Tag.key("") == Tag.key(nil), true, "a blank tag is untagged")

// ---------------------------------------------------------------- what is recorded

do {
    let store = makeStore()
    store.record(transition(tag: "Writing"))
    expect(store.sessions.count, 1, "a completed focus phase is recorded")

    store.record(transition(tag: "Writing", natural: false))
    expect(store.sessions.count, 1, "a skip is not")

    store.record(transition(tag: nil, phase: .shortBreak))
    store.record(transition(tag: nil, phase: .longBreak))
    expect(store.sessions.count, 1, "breaks are never recorded")

    expect(store.sessions.first?.tag, "Writing", "the tag is stored as typed")
    expect(store.sessions.first?.plannedDuration, 1500, "with the duration that was planned")
}

do {
    // the planned duration is what the phase was loaded with, not the setting now
    let store = makeStore(at: "planned.json")
    store.record(transition(tag: "Long one", minutes: 50))
    expect(store.sessions.first?.plannedDuration, 3000, "records the longer planned duration")
}

// ---------------------------------------------------------------- persistence

do {
    let store = makeStore(at: "persist.json")
    store.record(transition(tag: "  Writing   docs "))
    store.record(transition(tag: nil))

    let reloaded = makeStore(at: "persist.json")
    expect(reloaded.sessions.count, 2, "sessions survive a relaunch")
    expect(reloaded.sessions.first?.tag, "  Writing   docs ", "casing and spacing survive the round trip")
    expect(reloaded.sessions.last?.tag, nil, "a nil tag round trips")
}

do {
    let url = scratch.appendingPathComponent("corrupt.json")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    try? Data("{ this is not json".utf8).write(to: url)
    let store = SessionStore(url: url, clock: { today })
    expect(store.sessions.isEmpty, true, "a corrupt file degrades to empty rather than crashing")
}

do {
    let url = scratch.appendingPathComponent("legacy.json")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    // Written before tags existed.
    let legacy = """
        [{"endedAt":"2026-01-01T10:00:00Z","plannedDuration":1500}]
        """
    try? Data(legacy.utf8).write(to: url)
    let store = SessionStore(url: url, clock: { today })
    expect(store.sessions.count, 1, "a file written before tags existed still loads")
    expect(store.sessions.first?.tag, nil, "its missing tag decodes as nil")
}

do {
    // Well-formed JSON carrying an absurd duration. It decodes, where 1e400 would not, so
    // the tolerant decode does not catch it and the arithmetic downstream has to. An
    // unclamped `Int(Double)` traps past Int.max, which crashed the breakdown rather than
    // degrading the way the rest of this file's handling does.
    let url = scratch.appendingPathComponent("absurd.json")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: today)
    let absurd = """
        [{"endedAt":"\(stamp)","plannedDuration":1e300,"tag":"huge"}]
        """
    try? Data(absurd.utf8).write(to: url)
    let store = SessionStore(url: url, clock: { today })
    expect(store.sessions.count, 1, "a well-formed but absurd duration still loads")
    expect(store.todayByTag.count, 1, "and groups")
    // Reading .minutes at all is the check: it trapped before it could return anything.
    expect(store.todayByTag[0].minutes > 0, "its minutes clamp instead of trapping")
}

do {
    let store = makeStore(at: "missing-dir/nested/sessions.json")
    expect(store.sessions.isEmpty, true, "an absent file is not an error")
    store.record(transition(tag: "First"))
    let reloaded = makeStore(at: "missing-dir/nested/sessions.json")
    expect(reloaded.sessions.count, 1, "intermediate directories are created on first write")
}

// ---------------------------------------------------------------- today

do {
    let store = makeStore(at: "today.json", now: today)
    store.record(transition(tag: "A"))
    expect(store.today.count, 1, "a session recorded now counts for today")
    expect(store.sessions.count, 1, "and is in the log")
}

// ---------------------------------------------------------------- streak

@MainActor
func storeWithDays(_ offsets: [Int], file: String) -> SessionStore {
    let url = scratch.appendingPathComponent(file)
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let sessions = offsets.map {
        CompletedSession(endedAt: daysAgo($0), plannedDuration: 1500, tag: nil)
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try? encoder.encode(sessions).write(to: url)
    return SessionStore(url: url, clock: { today })
}

expect(storeWithDays([], file: "s0.json").streak, 0, "no history is no streak")
expect(storeWithDays([0], file: "s1.json").streak, 1, "today alone is a one day streak")
expect(storeWithDays([0, 1, 2], file: "s2.json").streak, 3, "three consecutive days")
expect(storeWithDays([1, 2, 3], file: "s3.json").streak, 3,
       "an empty today does not break the streak until the day is over")
expect(storeWithDays([0, 2, 3], file: "s4.json").streak, 1, "a gap ends the streak")
expect(storeWithDays([2, 3], file: "s5.json").streak, 0,
       "but an empty yesterday does end it")
expect(storeWithDays([0, 0, 0, 1], file: "s6.json").streak, 2,
       "several sessions in a day still count as one day")

// ---------------------------------------------------------------- today by tag

do {
    let url = scratch.appendingPathComponent("bytag.json")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let sessions = [
        CompletedSession(endedAt: today, plannedDuration: 1500, tag: "Writing docs"),
        CompletedSession(endedAt: today.addingTimeInterval(60), plannedDuration: 1500, tag: "code review"),
        CompletedSession(endedAt: today.addingTimeInterval(120), plannedDuration: 1500, tag: "writing   DOCS"),
        CompletedSession(endedAt: today.addingTimeInterval(180), plannedDuration: 3000, tag: nil),
        CompletedSession(endedAt: today.addingTimeInterval(240), plannedDuration: 1500, tag: "  "),
    ]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try? encoder.encode(sessions).write(to: url)
    let store = SessionStore(url: url, clock: { today })

    let rows = store.todayByTag
    expect(rows.count, 3, "three groups: writing, code review, untagged")
    expect(rows[0].label, "Writing docs", "first-seen casing wins the label")
    expect(rows[0].count, 2, "case and whitespace variants group together")
    expect(rows[0].minutes, 50, "minutes are summed")
    expect(rows[1].label, "code review", "then the next most frequent")
    expect(rows[2].label, nil, "untagged sorts last")
    expect(rows[2].count, 2, "a blank tag counts as untagged")
    expect(rows[2].displayLabel, "Untagged", "and renders as Untagged")
    expect(rows[2].minutes, 75, "even though it has the most minutes")
}

// ---------------------------------------------------------------- recents

do {
    let store = makeStore(at: "recents.json")
    for tag in ["Alpha", "Beta", "alpha ", "Gamma", nil] {
        store.record(transition(tag: tag))
    }
    let recents = store.recentTags()
    expect(recents, ["Gamma", "alpha", "Beta"], "distinct, newest first, untagged skipped")

    let many = makeStore(at: "recents-many.json")
    for index in 0..<20 { many.record(transition(tag: "tag \(index)")) }
    expect(many.recentTags().count, 8, "capped at eight")
    expect(many.recentTags().first, "tag 19", "newest first")
}

// ---------------------------------------------------------------- tag carry-over

do {
    let suite = "com.bisaya.Pomodore.historycheck"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let settings = Settings(defaults: defaults)

    let engine = TimerEngine(settings: settings)
    expect(engine.currentTag, nil, "no tag on a fresh install")
    engine.currentTag = "Writing docs"

    let relaunched = TimerEngine(settings: Settings(defaults: defaults))
    expect(relaunched.currentTag, "Writing docs", "the tag carries across a relaunch")

    relaunched.currentTag = nil
    let cleared = TimerEngine(settings: Settings(defaults: defaults))
    expect(cleared.currentTag, nil, "clearing it sticks too")

    defaults.removePersistentDomain(forName: suite)
}

// ---------------------------------------------------------------- chord

expect(Chord.default.display, "⌃⌥⌘P", "default chord renders in Apple's modifier order")
expect(Chord.default.hasNonShiftModifier, true, "the default is a real chord")
expect(
    Chord(keyCode: UInt16(kVK_ANSI_P), flags: [.shift]).hasNonShiftModifier,
    false,
    "shift alone is not a chord"
)
expect(
    Chord(keyCode: UInt16(kVK_ANSI_Q), flags: [.command]).isCommandOnly,
    true,
    "command-only is detected so command-Q can be rejected"
)
expect(
    Chord(keyCode: UInt16(kVK_Space), flags: [.control]).display,
    "⌃Space",
    "named keys render by name"
)
expect(
    Chord(keyCode: UInt16(kVK_ANSI_P), flags: [.command, .shift, .option, .control]).display,
    "⌃⌥⇧⌘P",
    "all four modifiers in order"
)
expect(
    Chord(keyCode: 999, modifiers: UInt32(cmdKey)).display.hasPrefix("⌘"),
    true,
    "an unknown key code still renders something"
)

do {
    let suite = "com.bisaya.Pomodore.chordcheck"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let settings = Settings(defaults: defaults)

    expect(settings.chord, .default, "falls back to the default chord")
    let custom = Chord(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .command])
    settings.chord = custom
    expect(Settings(defaults: defaults).chord, custom, "a custom chord persists")

    defaults.removePersistentDomain(forName: suite)
}

try? FileManager.default.removeItem(at: scratch)

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
