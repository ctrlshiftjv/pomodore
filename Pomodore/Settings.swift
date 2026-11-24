import Foundation

/// A typed facade over `UserDefaults`. Deliberately holds no state: the Phase 2 settings
/// view binds straight to the same keys via `@AppStorage`, and a cached copy here would
/// be a second source of truth to keep in step.
///
/// Do not give these properties `didSet` observers. Under `@Observable` a stored property
/// becomes a computed one, so clamping by assigning to itself in `didSet` recurses until
/// the stack gives out.
@MainActor
final class Settings {
    enum Key: String {
        case focusMinutes
        case shortBreakMinutes
        case longBreakMinutes
        case sessionsPerLongBreak
        case wakeLockIncludesDisplay
        case autoAdvanceIntoBreaks
        case autoAdvanceIntoFocus
        case focusEndedSound
        case breakEndedSound
        case lastTag
        case hotKeyKeyCode
        case hotKeyModifiers
    }

    /// Shared with the settings view's `@AppStorage` defaults, which must agree with these
    /// or the window would show one value while the engine used another.
    enum Default {
        static let focusMinutes = 25
        static let shortBreakMinutes = 5
        static let longBreakMinutes = 15
        static let sessionsPerLongBreak = 4
        static let wakeLockIncludesDisplay = true
        static let autoAdvanceIntoBreaks = true
        /// Dropping into a break automatically is welcome, being dropped into focus work
        /// is not.
        static let autoAdvanceIntoFocus = false
        static let focusEndedSound = "Glass"
        static let breakEndedSound = "Ping"
    }

    static let focusRange = 1...120
    static let breakRange = 1...60
    static let cycleRange = 2...12

    var focusMinutes: Int {
        get { read(.focusMinutes, default: Default.focusMinutes, in: Self.focusRange) }
        set { write(newValue, .focusMinutes, in: Self.focusRange) }
    }

    var shortBreakMinutes: Int {
        get { read(.shortBreakMinutes, default: Default.shortBreakMinutes, in: Self.breakRange) }
        set { write(newValue, .shortBreakMinutes, in: Self.breakRange) }
    }

    var longBreakMinutes: Int {
        get { read(.longBreakMinutes, default: Default.longBreakMinutes, in: Self.breakRange) }
        set { write(newValue, .longBreakMinutes, in: Self.breakRange) }
    }

    var sessionsPerLongBreak: Int {
        get {
            read(.sessionsPerLongBreak, default: Default.sessionsPerLongBreak, in: Self.cycleRange)
        }
        set { write(newValue, .sessionsPerLongBreak, in: Self.cycleRange) }
    }

    var wakeLockIncludesDisplay: Bool {
        get { read(.wakeLockIncludesDisplay, default: Default.wakeLockIncludesDisplay) }
        set { defaults.set(newValue, forKey: Key.wakeLockIncludesDisplay.rawValue) }
    }

    var autoAdvanceIntoBreaks: Bool {
        get { read(.autoAdvanceIntoBreaks, default: Default.autoAdvanceIntoBreaks) }
        set { defaults.set(newValue, forKey: Key.autoAdvanceIntoBreaks.rawValue) }
    }

    var autoAdvanceIntoFocus: Bool {
        get { read(.autoAdvanceIntoFocus, default: Default.autoAdvanceIntoFocus) }
        set { defaults.set(newValue, forKey: Key.autoAdvanceIntoFocus.rawValue) }
    }

    var focusEndedSound: String {
        get { defaults.string(forKey: Key.focusEndedSound.rawValue) ?? Default.focusEndedSound }
        set { defaults.set(newValue, forKey: Key.focusEndedSound.rawValue) }
    }

    var breakEndedSound: String {
        get { defaults.string(forKey: Key.breakEndedSound.rawValue) ?? Default.breakEndedSound }
        set { defaults.set(newValue, forKey: Key.breakEndedSound.rawValue) }
    }

    func sound(forEnding phase: Phase) -> String {
        phase == .focus ? focusEndedSound : breakEndedSound
    }

    /// Carried into the next focus phase so the common path, several sessions in a row on
    /// the same thing, needs no typing at all.
    var lastTag: String? {
        get { defaults.string(forKey: Key.lastTag.rawValue) }
        set { defaults.set(newValue, forKey: Key.lastTag.rawValue) }
    }

    var chord: Chord {
        get {
            guard let code = defaults.object(forKey: Key.hotKeyKeyCode.rawValue) as? Int,
                  let modifiers = defaults.object(forKey: Key.hotKeyModifiers.rawValue) as? Int
            else { return .default }
            return Chord(keyCode: UInt32(code), modifiers: UInt32(modifiers))
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.hotKeyKeyCode.rawValue)
            defaults.set(Int(newValue.modifiers), forKey: Key.hotKeyModifiers.rawValue)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func minutes(for phase: Phase) -> Int {
        switch phase {
        case .focus: focusMinutes
        case .shortBreak: shortBreakMinutes
        case .longBreak: longBreakMinutes
        }
    }

    func duration(for phase: Phase) -> TimeInterval {
        TimeInterval(minutes(for: phase)) * 60
    }

    func autoAdvances(into phase: Phase) -> Bool {
        phase == .focus ? autoAdvanceIntoFocus : autoAdvanceIntoBreaks
    }

    // MARK: - Storage

    private func read(_ key: Key, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        guard let stored = defaults.object(forKey: key.rawValue) as? Int else { return fallback }
        return stored.clamped(to: range)
    }

    private func read(_ key: Key, default fallback: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    private func write(_ value: Int, _ key: Key, in range: ClosedRange<Int>) {
        defaults.set(value.clamped(to: range), forKey: key.rawValue)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
