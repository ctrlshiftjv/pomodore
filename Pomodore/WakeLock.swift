import Foundation

/// Holds a `ProcessInfo` activity assertion. No entitlement, no prompt, and it dies with
/// the process, which is why this is not `caffeinate`.
final class WakeLock {
    private var token: NSObjectProtocol?
    private var heldIncludesDisplay = false

    var isHeld: Bool { token != nil }

    func acquire(includeDisplay: Bool) {
        if token != nil {
            guard includeDisplay != heldIncludesDisplay else { return }
            release()
        }

        // .userInitiated also disables App Nap, which keeps the 1s ticker on schedule
        // while the app sits in the background with its popover closed.
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        if includeDisplay { options.insert(.idleDisplaySleepDisabled) }

        token = ProcessInfo.processInfo.beginActivity(
            options: options,
            reason: "Pomodoro focus session running"
        )
        heldIncludesDisplay = includeDisplay
    }

    func release() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}
