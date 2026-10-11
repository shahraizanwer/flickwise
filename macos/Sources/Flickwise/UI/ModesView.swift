// ModesView — create, edit, reorder and delete modes. Order = menu, picker numbers and radial
// slots (clockwise from the top). Changes save immediately (ModeStore → modes.json) and hotkeys
// re-register right away.
import AppKit
import SwiftUI

struct ModesView: View {
    @ObservedObject private var store = ModeStore.shared
    @State private var selection: String?
    @State private var confirmRestore = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(Array(store.modes.enumerated()), id: \.element.id) { i, mode in
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundColor(.secondary).frame(width: 16)
                            Image(systemName: icon(mode.output)).foregroundColor(Flicky.violet).frame(width: 16)
                            Text(mode.name).foregroundColor(mode.enabled ? .primary : .secondary)
                            Spacer()
                            if let hk = mode.hotkey { Text(hk.display).font(.caption).foregroundColor(.secondary) }
                        }
                        .tag(mode.id)
                        .padding(.vertical, 2)
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                Divider()
                HStack(spacing: 4) {
                    Button { selection = store.add().id } label: { Image(systemName: "plus") }.help("Add a mode")
                    Button {
                        if let m = selected { store.duplicate(m) }
                    } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate").disabled(selected == nil)
                    Button {
                        if let m = selected { store.delete(m); selection = store.modes.first?.id }
                    } label: { Image(systemName: "minus") }.help("Delete").disabled(selected == nil)
                    Spacer()
                    Menu {
                        Button("Restore the default modes…") { confirmRestore = true }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                }
                .buttonStyle(.borderless)
                .padding(8)
                Text("Drag to reorder: the order is used by the picker (1–9) and the radial menu.")
                    .font(.caption).foregroundColor(.secondary).padding([.horizontal, .bottom], 8)
            }
            .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)

            Group {
                if let mode = selected {
                    ModeEditor(mode: mode).id(mode.id)
                } else {
                    Text("Select a mode").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = store.modes.first?.id } }
        .alert("Restore the default modes?", isPresented: $confirmRestore) {
            Button("Restore", role: .destructive) { store.restoreDefaults(); selection = store.modes.first?.id }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your modes are replaced by the 7 built-in ones (Fix Grammar, Make Concise, …). Custom prompts are lost.")
        }
    }

    private var selected: Mode? { selection.flatMap(store.mode(id:)) }

    private func icon(_ o: Mode.Output) -> String {
        switch o {
        case .replace: return "text.cursor"
        case .show: return "text.bubble"
        case .replies: return "arrowshape.turn.up.left.2"
        }
    }
}

/// Edits one mode; every change is saved as you type.
private struct ModeEditor: View {
    @State var mode: Mode
    @ObservedObject private var store = ModeStore.shared
    @State private var sample = "i has went to the meeting yesterday and we discuss about the budget"
    @State private var output = ""
    @State private var running = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $mode.name)
                Toggle("Enabled", isOn: $mode.enabled)
                LabeledContent("Shortcut") { HotkeyRecorder(combo: $mode.hotkey, modeID: mode.id) }
                Picker("What it does", selection: $mode.output) {
                    ForEach(Mode.Output.allCases) { Text($0.title).tag($0) }
                }
                Text(mode.output.detail).font(.caption).foregroundColor(.secondary)
                if mode.output == .replace {
                    Toggle("Show “what changed” with Undo", isOn: $mode.showDiff)
                }
                Toggle("Custom temperature (Gemini)", isOn: Binding(
                    get: { mode.temperature != nil }, set: { mode.temperature = $0 ? 0.2 : nil }))
                if let t = mode.temperature {
                    Slider(value: Binding(get: { t }, set: { mode.temperature = ($0 * 10).rounded() / 10 }), in: 0...1) {
                        Text("Temperature \(String(format: "%.1f", t))")
                    } minimumValueLabel: { Text("exact") } maximumValueLabel: { Text("creative") }
                }
            }
            Section("Prompt") {
                TextEditor(text: $mode.prompt)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(minHeight: 220)
                Text("The selected text is added after the prompt. Ask for ONLY the result (no preamble or quotes).")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Try it") {
                TextEditor(text: $sample).font(.system(size: 12.5)).frame(minHeight: 60)
                HStack {
                    Button(running ? "Running…" : "Run on this text") { test() }.disabled(running || sample.isEmpty)
                    Text("uses \(SettingsStore.shared.settings.ai.backend.title)").font(.caption).foregroundColor(.secondary)
                }
                if !output.isEmpty {
                    Text(output).textSelection(.enabled).font(.system(size: 12.5))
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: mode) { store.update($0) }
    }

    private func test() {
        running = true
        output = ""
        let m = mode, text = sample
        Task { @MainActor in
            do { output = try await TextBackend.transform(text, mode: m, settings: SettingsStore.shared.settings) }
            catch { output = "⚠️ " + error.localizedDescription }
            running = false
        }
    }
}

/// Click, then press the new shortcut (it needs ⌘, ⌥ or ⌃). Esc cancels, × clears.
struct HotkeyRecorder: View {
    @Binding var combo: KeyCombo?
    var modeID: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var warning: String?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Press a shortcut…" : (combo?.display ?? "Record shortcut")) {
                recording ? stop() : start()
            }
            .foregroundColor(recording ? .accentColor : .primary)
            if combo != nil && !recording {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundColor(.secondary).help("Remove the shortcut")
            }
            if let warning { Text(warning).font(.caption).foregroundColor(.orange) }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        warning = nil
        recording = true
        GlobalHotkeys.shared.unregisterAll()        // so pressing an existing shortcut records it instead of running it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }                             // Esc
            guard let c = KeyCombo(event: e), c.hasModifier else {
                warning = "Use ⌘, ⌥ or ⌃ with a key"
                return nil
            }
            if let other = ModeStore.shared.conflict(for: c, excluding: modeID) {
                warning = "Already used by \(other)"
                return nil
            }
            combo = c
            stop()
            return nil
        }
    }

    private func stop() {
        let wasRecording = recording
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if wasRecording { AppDelegate.shared?.registerHotkeys() }
    }
}
