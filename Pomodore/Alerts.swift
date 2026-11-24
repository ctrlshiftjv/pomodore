import AppKit
import UserNotifications

/// Phase transitions made noticeable when the popover is closed and something else is
/// frontmost, which is the only state that matters. Nobody watches the digits.
///
/// Sound and banners are deliberately independent. The banner can be denied or swallowed
/// by a Focus mode; the chime cannot. Never gate audio on notification permission.
@MainActor
final class Alerts {
    private let settings: Settings

    /// Resolved on use, never stored. `UNUserNotificationCenter.current()` needs a real
    /// bundle and throws `bundleProxyForCurrentProcess is nil` without one, so holding it
    /// as a stored property would make merely constructing this type unusable outside the
    /// app (the checks build these sources into a plain executable).
    private var center: UNUserNotificationCenter { .current() }

    /// NSSound stops if it is deallocated mid-playback, so the chime has to outlive the
    /// call that started it.
    private var playing: NSSound?

    /// Per launch, not persisted. The authorization answer itself is never cached: the
    /// user can change it in System Settings at any time.
    private var didRequestAuthorization = false

    init(settings: Settings) {
        self.settings = settings
    }

    func handle(_ transition: Transition) {
        // A skip is not a completion. The user just did it on purpose; say nothing.
        guard transition.completedNaturally else { return }

        play(settings.sound(forEnding: transition.ended))
        post(title: title(for: transition), body: body(for: transition))
    }

    func handle(_ discard: Discard) {
        post(
            title: "Switched to \(discard.to.name)",
            body: "\(discard.from.name) was discarded. "
                + "\(minutes(discard.elapsed)) elapsed were not recorded."
        )
    }

    // MARK: - Sound

    private func play(_ name: String) {
        guard let sound = NSSound(named: name) else { return }
        playing = sound
        sound.play()
    }

    // MARK: - Banners

    func title(for transition: Transition) -> String {
        transition.ended == .focus ? "Focus complete" : "Break over"
    }

    func body(for transition: Transition) -> String {
        switch transition.ended {
        case .focus:
            return "Take a \(settings.minutes(for: transition.next)) minute break."
        case .shortBreak, .longBreak:
            let session = transition.completedInCycle + 1
            return "Back to it. Session \(session) of \(settings.sessionsPerLongBreak)."
        }
    }

    /// Asking for notification permission before the user has started a single timer is
    /// the kind of prompt people deny on reflex, so the request rides along with the
    /// first alert that is actually worth showing.
    private func post(title: String, body: String) {
        guard didRequestAuthorization else {
            didRequestAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                guard granted else { return }
                Task { @MainActor in self?.deliver(title: title, body: body) }
            }
            return
        }
        deliver(title: title, body: body)
    }

    private func deliver(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // The user asked for this alert by starting the timer, so it may break through a
        // Focus mode. Not .critical, which needs an entitlement and means emergencies.
        content.interruptionLevel = .timeSensitive
        // The chime is ours. Leaving this set would double it.
        content.sound = nil

        center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    private func minutes(_ interval: TimeInterval) -> String {
        let count = max(1, Int((interval / 60).rounded()))
        return count == 1 ? "1 minute" : "\(count) minutes"
    }
}
