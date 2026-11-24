import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click to arm, then press a chord. Capture uses a *local* `NSEvent` monitor, which
/// needs no permission because the settings window is focused at the time. Only the
/// global monitor variant is gated, and that is the one being avoided.
struct ChordRecorder: View {
    @Binding var chord: Chord

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(isRecording ? "Press a chord…" : chord.display) {
                    isRecording.toggle()
                }
                .frame(minWidth: 120)

                Button("Reset") { chord = .default }
                    .disabled(chord == .default)
            }

            if let rejection {
                Text(rejection)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: isRecording) { isRecording ? startCapture() : stopCapture() }
        .onDisappear(perform: stopCapture)
    }

    private func startCapture() {
        rejection = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            capture(event)
            return nil  // swallow it, or the key also reaches the window
        }
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func capture(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
            isRecording = false
            return
        }

        let candidate = Chord(keyCode: event.keyCode, flags: flags)

        guard candidate.hasNonShiftModifier else {
            rejection = "Needs at least one of Control, Option or Command."
            return
        }
        // Both would be traps: the chord is global, so it would shadow quit and close
        // everywhere.
        guard !(candidate.isCommandOnly
            && (event.keyCode == UInt16(kVK_ANSI_Q) || event.keyCode == UInt16(kVK_ANSI_W)))
        else {
            rejection = "Command-Q and Command-W are not available."
            return
        }

        chord = candidate
        rejection = nil
        isRecording = false
    }
}
