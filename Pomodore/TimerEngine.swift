import AppKit

struct Transition: Sendable {
    let ended: Phase
    let next: Phase
    let tag: String?
    /// The full duration the phase was loaded with, which is not necessarily the current
    /// setting: a running phase keeps the duration it started with.
    let plannedDuration: TimeInterval
    /// Cycle position after the transition, so subscribers need not read engine state.
    let completedInCycle: Int
    /// False for a skip. Only natural completions reach history (06).
    let completedNaturally: Bool
}

/// A running session thrown away by `select`. Never silent, never a dialog.
struct Discard: Sendable {
    let from: Phase
    let to: Phase
    let elapsed: TimeInterval
}

@MainActor
@Observable
final class TimerEngine {
    enum RunState: Equatable {
        case idle
        case running(deadline: Date)
        case paused(remaining: TimeInterval)
    }

    private(set) var phase: Phase = .focus
    private(set) var runState: RunState = .idle
    private(set) var completedInCycle = 0

    /// Refreshed on every tick and state change; the views read this, not the clock.
    private(set) var remaining: TimeInterval = 0

    /// The full length of the current phase as loaded. Held separately from the setting
    /// so history records what was actually planned, not what the setting says now.
    private(set) var plannedDuration: TimeInterval = 0

    /// Survives pause and resume, carries into the next focus phase, ignored on breaks.
    var currentTag: String? {
        didSet { settings.lastTag = currentTag }
    }

    var onTransition: ((Transition) -> Void)?
    var onDiscard: ((Discard) -> Void)?
    /// Drives the status item title, which is set imperatively rather than observed.
    var onRender: (() -> Void)?

    private let settings: Settings
    private let clock: () -> Date
    private let wakeLock = WakeLock()
    private var ticker: Timer?
    private var wakeObserver: NSObjectProtocol?

    /// Whether the current phase has ever been running. Guards the duration re-derive in
    /// `durationsChanged()` so an in-flight session is never disturbed.
    private var phaseStarted = false

    init(settings: Settings, clock: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.clock = clock
        self.remaining = settings.duration(for: .focus)
        self.plannedDuration = settings.duration(for: .focus)
        // The first session of the morning is usually a continuation of yesterday
        // afternoon, so carry-over survives a relaunch.
        self.currentTag = settings.lastTag

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: - Derived

    var isRunning: Bool {
        if case .running = runState { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = runState { return true }
        return false
    }

    var isIdle: Bool {
        if case .idle = runState { return true }
        return false
    }

    var wakeLockHeld: Bool { wakeLock.isHeld }

    /// "2 of 4" during focus, "after 1 of 4" during a break.
    var cycleLabel: String {
        let perLong = settings.sessionsPerLongBreak
        return phase == .focus
            ? "\(min(completedInCycle + 1, perLong)) of \(perLong)"
            : "after \(completedInCycle) of \(perLong)"
    }

    // MARK: - Operations

    func start() {
        guard !isRunning else { return }
        // Starting a fresh phase fixes its planned length; resuming keeps the old one.
        if isIdle { plannedDuration = settings.duration(for: phase) }
        runState = .running(deadline: clock().addingTimeInterval(liveRemaining()))
        phaseStarted = true
        settle()
    }

    func pause() {
        guard isRunning else { return }
        runState = .paused(remaining: liveRemaining())
        settle()
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    /// Advances the cycle without completing anything. Skipping is not finishing, so it
    /// records nothing and leaves `completedInCycle` alone.
    func skip() {
        let ended = phase
        let endedDuration = plannedDuration
        let next = nextPhase()
        if ended == .longBreak { completedInCycle = 0 }
        load(next, running: false)
        onTransition?(Transition(
            ended: ended,
            next: next,
            tag: nil,
            plannedDuration: endedDuration,
            completedInCycle: completedInCycle,
            completedNaturally: false
        ))
    }

    func reset() {
        runState = .idle
        phaseStarted = false
        plannedDuration = settings.duration(for: phase)
        settle()
    }

    /// Manual override from the popover's segmented control: loads `phase` at its full
    /// duration, idle, cycle position untouched.
    func select(_ phase: Phase) {
        let discarded = isRunning ? plannedDuration - liveRemaining() : 0
        let from = self.phase

        self.phase = phase
        runState = .idle
        phaseStarted = false
        plannedDuration = settings.duration(for: phase)
        settle()

        // Worth telling the user about, but a handful of seconds is not.
        if discarded > 30 {
            onDiscard?(Discard(from: from, to: phase, elapsed: discarded))
        }
    }

    /// A running phase keeps its absolute deadline. Only an untouched one re-derives, so
    /// editing the focus duration at a fresh 25:00 shows 30:00 immediately.
    func durationsChanged() {
        guard !phaseStarted else { return }
        plannedDuration = settings.duration(for: phase)
        if case .paused = runState {
            runState = .paused(remaining: plannedDuration)
        }
        settle()
    }

    func wakeLockScopeChanged() {
        syncWakeLock()
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        wakeLock.release()
    }

    // MARK: - Clock

    /// Re-render against the current clock, completing the phase if its deadline passed.
    /// Called by the ticker and on wake, so the digits are right the moment the screen
    /// comes back rather than up to a second later.
    func refresh() {
        guard case .running(let deadline) = runState else { return }

        if clock() >= deadline {
            complete(deadline: deadline)
        } else {
            remaining = liveRemaining()
            onRender?()
        }
    }

    private func complete(deadline: Date) {
        let ended = phase
        let endedDuration = plannedDuration
        let next = nextPhase()
        let tag = ended == .focus ? currentTag : nil

        if ended == .focus {
            completedInCycle += 1
        } else if ended == .longBreak {
            completedInCycle = 0
        }

        // Several deadlines can elapse during one sleep. Fire the completion for the phase
        // that was running, then land paused rather than burning sessions nobody worked.
        let overslept = clock().timeIntervalSince(deadline) >= settings.duration(for: next)
        load(next, running: !overslept && settings.autoAdvances(into: next))

        onTransition?(Transition(
            ended: ended,
            next: next,
            tag: tag,
            plannedDuration: endedDuration,
            completedInCycle: completedInCycle,
            completedNaturally: true
        ))
    }

    private func nextPhase() -> Phase {
        guard phase == .focus else { return .focus }
        return (completedInCycle + 1) % settings.sessionsPerLongBreak == 0 ? .longBreak : .shortBreak
    }

    private func load(_ phase: Phase, running: Bool) {
        self.phase = phase
        let duration = settings.duration(for: phase)
        plannedDuration = duration
        runState = running
            ? .running(deadline: clock().addingTimeInterval(duration))
            : .paused(remaining: duration)
        phaseStarted = running
        settle()
    }

    private func liveRemaining() -> TimeInterval {
        switch runState {
        case .idle: settings.duration(for: phase)
        case .running(let deadline): max(0, deadline.timeIntervalSince(clock()))
        case .paused(let remaining): max(0, remaining)
        }
    }

    /// The single place state changes are published from, so the ticker and the wake lock
    /// cannot drift out of step with `runState`.
    private func settle() {
        remaining = liveRemaining()
        syncTicker()
        syncWakeLock()
        onRender?()
    }

    private func syncTicker() {
        guard isRunning else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else { return }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.2
        // .common is required: the default mode stops firing while the popover tracks
        // events, which is exactly when the digits are being looked at.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func syncWakeLock() {
        if isRunning && phase == .focus {
            wakeLock.acquire(includeDisplay: settings.wakeLockIncludesDisplay)
        } else {
            wakeLock.release()
        }
    }
}
