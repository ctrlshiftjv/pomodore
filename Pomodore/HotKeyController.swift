import AppKit

/// Owns the one global chord and its registration state, so the settings view can show
/// whether it actually took. A hotkey that quietly does nothing is worse than no hotkey.
@MainActor
@Observable
final class HotKeyController {
    private(set) var isRegistered = false

    var chord: Chord {
        didSet {
            guard chord != oldValue else { return }
            settings.chord = chord
            apply()
        }
    }

    @ObservationIgnored private let hotKey = HotKey()
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let action: () -> Void

    init(settings: Settings, action: @escaping () -> Void) {
        self.settings = settings
        self.action = action
        self.chord = settings.chord
    }

    func apply() {
        isRegistered = hotKey.register(chord, action: action)
    }

    func stop() {
        hotKey.unregister()
    }
}
