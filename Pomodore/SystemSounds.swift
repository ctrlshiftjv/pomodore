import AppKit

/// The system alert sounds, by name. No bundled audio: these are already tuned to the
/// user's output device and alert volume.
enum SystemSounds {
    static let names: [String] = {
        let directory = URL(fileURLWithPath: "/System/Library/Sounds")
        let found = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?
            .filter { $0.pathExtension == "aiff" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted() ?? []

        // A picker with nothing in it would strand whatever is already stored.
        return found.isEmpty
            ? [Settings.Default.focusEndedSound, Settings.Default.breakEndedSound]
            : found
    }()

    /// Keeps a stored name selectable even if the system stops shipping that sound.
    static func options(including current: String) -> [String] {
        names.contains(current) ? names : ([current] + names)
    }
}
