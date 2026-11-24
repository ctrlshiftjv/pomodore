import AppKit
import SwiftUI

/// Changes apply as they are made. There is no Save and no Cancel.
struct SettingsView: View {
    let hotKey: HotKeyController
    let onDurationsChanged: () -> Void
    let onWakeLockScopeChanged: () -> Void

    @AppStorage(Settings.Key.focusMinutes.rawValue)
    private var focusMinutes = Settings.Default.focusMinutes

    @AppStorage(Settings.Key.shortBreakMinutes.rawValue)
    private var shortBreakMinutes = Settings.Default.shortBreakMinutes

    @AppStorage(Settings.Key.longBreakMinutes.rawValue)
    private var longBreakMinutes = Settings.Default.longBreakMinutes

    @AppStorage(Settings.Key.sessionsPerLongBreak.rawValue)
    private var sessionsPerLongBreak = Settings.Default.sessionsPerLongBreak

    @AppStorage(Settings.Key.autoAdvanceIntoBreaks.rawValue)
    private var autoAdvanceIntoBreaks = Settings.Default.autoAdvanceIntoBreaks

    @AppStorage(Settings.Key.autoAdvanceIntoFocus.rawValue)
    private var autoAdvanceIntoFocus = Settings.Default.autoAdvanceIntoFocus

    @AppStorage(Settings.Key.wakeLockIncludesDisplay.rawValue)
    private var wakeLockIncludesDisplay = Settings.Default.wakeLockIncludesDisplay

    @AppStorage(Settings.Key.focusEndedSound.rawValue)
    private var focusEndedSound = Settings.Default.focusEndedSound

    @AppStorage(Settings.Key.breakEndedSound.rawValue)
    private var breakEndedSound = Settings.Default.breakEndedSound

    @State private var preview: NSSound?

    var body: some View {
        Form {
            Section("Durations") {
                minutes("Focus", $focusMinutes, in: Settings.focusRange)
                minutes("Short break", $shortBreakMinutes, in: Settings.breakRange)
                minutes("Long break", $longBreakMinutes, in: Settings.breakRange)
                Stepper(
                    "Sessions per long break: \(sessionsPerLongBreak)",
                    value: $sessionsPerLongBreak,
                    in: Settings.cycleRange
                )
            }

            Section("Behaviour") {
                Toggle("Start breaks automatically", isOn: $autoAdvanceIntoBreaks)
                Toggle("Start focus automatically", isOn: $autoAdvanceIntoFocus)

                Picker("Keep awake", selection: $wakeLockIncludesDisplay) {
                    Text("System only").tag(false)
                    Text("System and display").tag(true)
                }
                .onChange(of: wakeLockIncludesDisplay) { onWakeLockScopeChanged() }

                Text(
                    "Closing the lid, choosing Sleep from the Apple menu, or a critically "
                    + "low battery will still put the Mac to sleep. The timer keeps "
                    + "correct time through it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Sound") {
                sound("Focus ended", $focusEndedSound)
                sound("Break ended", $breakEndedSound)
            }

            Section("Shortcut") {
                LabeledContent("Start / pause") {
                    ChordRecorder(chord: Binding(
                        get: { hotKey.chord },
                        set: { hotKey.chord = $0 }
                    ))
                }

                if !hotKey.isRegistered {
                    Label(
                        "Shortcut unavailable, another app is using it.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Steppers rather than text fields, so there is nothing to validate and no way to
    /// type a duration of zero.
    private func minutes(
        _ label: String,
        _ value: Binding<Int>,
        in range: ClosedRange<Int>
    ) -> some View {
        Stepper("\(label): \(value.wrappedValue) min", value: value, in: range)
            .onChange(of: value.wrappedValue) { onDurationsChanged() }
    }

    private func sound(_ label: String, _ selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            ForEach(SystemSounds.options(including: selection.wrappedValue), id: \.self) {
                Text($0).tag($0)
            }
        }
        // Choosing an alert sound you cannot hear is a bad control.
        .onChange(of: selection.wrappedValue) {
            preview = NSSound(named: selection.wrappedValue)
            preview?.play()
        }
    }
}
