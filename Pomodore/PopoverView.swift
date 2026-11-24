import SwiftUI

struct PopoverView: View {
    let engine: TimerEngine
    let store: SessionStore
    let openSettings: () -> Void
    let quit: () -> Void

    @State private var showingBreakdown = false
    @State private var isEditingTag = false
    @State private var isHoveringTag = false
    @State private var clickMonitor: Any?
    @FocusState private var tagFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            phasePicker

            VStack(spacing: 2) {
                Text(engine.remaining.mmss)
                    .font(.system(size: 42, weight: .light).monospacedDigit())
                    .foregroundStyle(engine.isPaused ? Color.secondary : Color.primary)

                statusLine
            }

            // Breaks are not tagged, and a dead field is worse than no field.
            if !engine.phase.isBreak {
                tagField
            }

            HStack(spacing: 8) {
                Button(primaryLabel) { engine.toggle() }
                    .buttonStyle(.borderedProminent)
                    .tint(engine.phase.accent)

                Button("Skip") { engine.skip() }
            }
            .controlSize(.large)

            Divider()

            summary

            Divider()

            HStack {
                Button("Settings…", action: openSettings)
                Spacer()
                Button("Quit", action: quit)
                    .keyboardShortcut("q")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 240)
        .onChange(of: isEditingTag) {
            isEditingTag ? watchForClickAway() : stopWatchingForClickAway()
        }
        .onDisappear(perform: stopWatchingForClickAway)
    }

    /// Clicking a non-focusable area does not resign first responder on its own, so
    /// without this the cursor sits in the tag until the popover closes.
    ///
    /// Done with an event monitor rather than a background tap gesture because SwiftUI
    /// never delivers one inside a popover, and not with `hitTest` because the whole
    /// popover flattens to a single `NSHostingView` that cannot tell the field from the
    /// digits. The field editor does know its own frame, so that is what gets asked.
    /// A *local* monitor, so no permission is involved.
    private func watchForClickAway() {
        stopWatchingForClickAway()
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            guard let editor = event.window?.firstResponder as? NSTextView else { return event }
            let editorFrame = editor.convert(editor.bounds, to: nil)
            if !editorFrame.contains(event.locationInWindow) {
                // Deferred so the click still reaches whatever it landed on.
                DispatchQueue.main.async { endTagEditing() }
            }
            return event
        }
    }

    private func stopWatchingForClickAway() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func endTagEditing() {
        tagFocused = false
        isEditingTag = false
    }

    private var phasePicker: some View {
        Picker("Phase", selection: Binding(get: { engine.phase }, set: { engine.select($0) })) {
            ForEach(Phase.allCases, id: \.self) { phase in
                Text(phase.shortName).tag(phase)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(engine.phase.accent)
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            Text(engine.phase.name).bold()
            Text("·").foregroundStyle(.tertiary)
            Text(engine.cycleLabel)
            if engine.isPaused {
                Text("·").foregroundStyle(.tertiary)
                Text("paused")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Stored exactly as typed, and editable right up until the session completes: the
    /// honest workflow is often "start the timer, then work out what you are doing".
    ///
    /// Click to edit, rather than a live text field. A `TextField` sitting in the popover
    /// takes first responder the moment the window becomes key, so opening the popover to
    /// press Pause would park a blinking cursor in the tag. Nothing here is focusable
    /// until it is asked for.
    private var tagField: some View {
        HStack(spacing: 4) {
            Group {
                if isEditingTag {
                    TextField(
                        "What is this for?",
                        text: Binding(
                            get: { engine.currentTag ?? "" },
                            // Committed on every keystroke, so a session completing
                            // mid-edit still records what has been typed.
                            set: { engine.currentTag = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($tagFocused)
                    .onSubmit { isEditingTag = false }
                    .onExitCommand { isEditingTag = false }
                    .onAppear {
                        // A hop: the field is not in the responder chain yet this pass.
                        DispatchQueue.main.async { tagFocused = true }
                    }
                } else {
                    tagDisplay
                }
            }
            .frame(height: 22)

            recentsMenu
        }
        // Closing the popover drops focus, which also leaves edit mode.
        .onChange(of: tagFocused) { if !tagFocused { isEditingTag = false } }
        .onDisappear { isEditingTag = false }
    }

    private var tagDisplay: some View {
        Button {
            isEditingTag = true
        } label: {
            HStack(spacing: 0) {
                Text(engine.currentTag ?? "What is this for?")
                    .foregroundStyle(engine.currentTag == nil ? AnyShapeStyle(.tertiary)
                                                              : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHoveringTag ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringTag = $0 }
    }

    @ViewBuilder
    private var recentsMenu: some View {
        let recents = store.recentTags()
        if !recents.isEmpty {
            // A menu, not inline autocomplete: no fighting the field editor over
            // selection ranges, and it never guesses wrong.
            Menu {
                ForEach(recents, id: \.self) { tag in
                    Button(tag) { engine.currentTag = tag }
                }
            } label: {
                EmptyView()
            }
            .menuStyle(.borderlessButton)
            .frame(width: 12)
        }
    }

    @ViewBuilder
    private var summary: some View {
        let rows = store.todayByTag

        VStack(alignment: .leading, spacing: 4) {
            if rows.isEmpty {
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    showingBreakdown.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showingBreakdown ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(summaryText)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)

                if showingBreakdown {
                    breakdown(rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func breakdown(_ rows: [TagTotal]) -> some View {
        let shown = rows.prefix(5)

        VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { row in
                HStack(spacing: 6) {
                    Text(row.displayLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(row.label == nil ? .tertiary : .secondary)
                    Spacer()
                    // Two 25 minute sessions and two 50 minute ones are not the same
                    // afternoon, so show the time alongside the count.
                    Text("\(row.count) · \(row.minutes)m")
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            if rows.count > shown.count {
                Text("+\(rows.count - shown.count) more")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption2)
        .padding(.leading, 12)
    }

    private var summaryText: String {
        let count = store.today.count
        guard count > 0 else { return "No sessions yet today" }
        let sessions = count == 1 ? "1 session today" : "\(count) sessions today"
        // "1 day streak" is not a streak.
        return store.streak > 1 ? "\(sessions) · \(store.streak) day streak" : sessions
    }

    private var primaryLabel: String {
        if engine.isRunning { return "Pause" }
        return engine.isIdle ? "Start" : "Resume"
    }
}
