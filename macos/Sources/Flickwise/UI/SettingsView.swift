// Settings pages shown in the main window's sidebar: Dictation, Features, AI, General.
// Every option maps to settings.json (SettingsStore) and applies immediately.
import AppKit
import SwiftUI

struct DictationPane: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var microphones = AudioDevices.inputs()

    var body: some View {
        Form {
            SpeechSection()
            Section("Dictation") {
                Toggle("Hold to dictate", isOn: $store.settings.dictation.enabled)
                Picker("Hold this key", selection: $store.settings.dictation.trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                Picker("Style", selection: $store.settings.dictation.style) {
                    ForEach(DictationStyle.allCases) { Text($0.title).tag($0) }
                }
                Text(store.settings.dictation.style.detail).font(.caption).foregroundColor(.secondary)
                Picker("Microphone", selection: $store.settings.dictation.microphone) {
                    Text("System default").tag("")
                    ForEach(microphones) { Text($0.name).tag($0.id) }
                    if !store.settings.dictation.microphone.isEmpty,
                       !microphones.contains(where: { $0.id == store.settings.dictation.microphone }) {
                        Text("Not connected").tag(store.settings.dictation.microphone)
                    }
                }
                Stepper("Hold before it counts: \(store.settings.dictation.holdMs) ms",
                        value: $store.settings.dictation.holdMs, in: 50...1000, step: 50)
                Toggle("Start the microphone instantly on key-down", isOn: $store.settings.dictation.instantStart)
                Text("Your first word is never cut off. A quick tap or a shortcut throws the audio away.")
                    .font(.caption).foregroundColor(.secondary)
                Stepper("Stop after \(store.settings.dictation.maxSeconds / 60) min \(store.settings.dictation.maxSeconds % 60) s",
                        value: $store.settings.dictation.maxSeconds, in: 30...600, step: 30)
                Picker("Indicator", selection: $store.settings.dictation.indicator) {
                    ForEach(AppSettings.Indicator.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Sounds", isOn: $store.settings.dictation.sounds)
            }
        }
        .formStyle(.grouped)
        .onAppear { microphones = AudioDevices.inputs() }
    }
}

struct FeaturesPane: View {
    @ObservedObject private var store = SettingsStore.shared
    private let sounds = ["", "Tink", "Pop", "Glass", "Ping", "Purr", "Bottle", "Frog", "Funk", "Hero", "Morse", "Submarine", "Blow", "Basso", "Sosumi"]

    var body: some View {
        Form {
            Section("Text fixes") {
                Toggle("Replace without the clipboard (Accessibility)", isOn: $store.settings.fixes.directReplace)
                Picker("Web pages & Electron apps", selection: $store.settings.fixes.webContent) {
                    Text("Paste (safe)").tag(AppSettings.WebContent.paste)
                    Text("Write directly").tag(AppSettings.WebContent.direct)
                }
                .disabled(!store.settings.fixes.directReplace)
                ListField(title: "Always use copy/paste in", items: $store.settings.fixes.excludeApps, placeholder: "App name, e.g. Terminal")
                Picker("Sound when done", selection: $store.settings.fixes.sound) {
                    ForEach(sounds, id: \.self) { Text($0.isEmpty ? "None" : $0).tag($0) }
                }
                .onChange(of: store.settings.fixes.sound) { if !$0.isEmpty { Sounds.play($0, volume: 0.6) } }
            }
            Section("“What changed” card") {
                Toggle("Show what changed after each fix, with Undo", isOn: $store.settings.diffCard.enabled)
                Stepper("Stays for \(store.settings.diffCard.durationSeconds) s (paused while hovered)",
                        value: $store.settings.diffCard.durationSeconds, in: 2...60)
                LabeledContent("Undo shortcut (while visible)") {
                    HotkeyRecorder(combo: Binding(get: { store.settings.diffCard.undoHotkey },
                                                  set: { if let c = $0 { store.settings.diffCard.undoHotkey = c } }),
                                   modeID: "undo")
                }
                Picker("Undo by", selection: $store.settings.diffCard.undoMethod) {
                    ForEach(AppSettings.UndoMethod.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Context: \(store.settings.diffCard.contextWords) words around each change",
                        value: $store.settings.diffCard.contextWords, in: 2...30)
            }
            Section("Answer and reply cards") {
                Toggle("Show answers in a card (otherwise copied)", isOn: $store.settings.resultCard.enabled)
                Stepper("Answer card stays \(store.settings.resultCard.durationSeconds) s",
                        value: $store.settings.resultCard.durationSeconds, in: 5...120, step: 5)
                Toggle("Reply Helper: pick a reply with 1–3", isOn: $store.settings.replyCard.enabled)
                Stepper("Reply card stays \(store.settings.replyCard.durationSeconds) s",
                        value: $store.settings.replyCard.durationSeconds, in: 10...300, step: 5)
            }
            Section("Mode picker") {
                Toggle("Command palette of all modes", isOn: $store.settings.picker.enabled)
                LabeledContent("Shortcut") {
                    HotkeyRecorder(combo: Binding(get: { store.settings.picker.hotkey },
                                                  set: { if let c = $0 { store.settings.picker.hotkey = c } }),
                                   modeID: "picker")
                }
            }
            Section("Radial menu") {
                Toggle("Hold a key, flick toward a mode, release", isOn: $store.settings.radialMenu.enabled)
                Picker("Hold this key", selection: $store.settings.radialMenu.trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Hold \(store.settings.radialMenu.holdMs) ms before it opens",
                        value: $store.settings.radialMenu.holdMs, in: 0...600, step: 25)
                Text(store.settings.radialMenu.trigger == store.settings.dictation.trigger && store.settings.dictation.enabled
                     ? "⚠️ This is also the dictation key: pick a different key for one of them."
                     : "Shows your first 8 enabled modes, clockwise from the top in the Modes order.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AIPane: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var gleanStatus: String?

    var body: some View {
        Form {
            Section {
                Picker("Text fixes use", selection: $store.settings.ai.backend) {
                    ForEach(AppSettings.Backend.allCases) { Text($0.title).tag($0) }
                }
                Text("Dictation is recognized on this Mac (see Dictation). This is for the modes: Fix Grammar, Reply Helper…")
                    .font(.caption).foregroundColor(.secondary)
                Stepper("Timeout: \(store.settings.ai.timeoutSeconds) s", value: $store.settings.ai.timeoutSeconds, in: 10...300, step: 10)
            } header: { Text("Backend") }

            if store.settings.ai.backend == .glean {
                Section("Glean CLI") {
                    TextField("Path (empty = auto-detect)", text: $store.settings.ai.gleanPath,
                              prompt: Text(TextBackend.gleanPath(store.settings)))
                    HStack {
                        Button("Test Glean") { testGlean() }
                        if let gleanStatus { Text(gleanStatus).font(.caption) }
                    }
                    Text("Install: brew install gleanwork/tap/glean-cli, then: glean auth login")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Section(store.settings.ai.backend == .gemini ? "Gemini" : "Gemini (optional)") {
                APIKeyField()
                TextField("Model", text: $store.settings.ai.model)
            }
        }
        .formStyle(.grouped)
    }

    private func testGlean() {
        gleanStatus = "Testing…"
        let mode = Mode(name: "Test", hotkey: nil, prompt: "Reply with the single word: OK")
        Task { @MainActor in
            var s = store.settings
            s.ai.backend = .glean
            do {
                let r = try await TextBackend.transform("ping", mode: mode, settings: s)
                gleanStatus = "✅ Works (\(r.prefix(20)))"
            } catch {
                gleanStatus = "❌ " + error.localizedDescription
            }
        }
    }
}

struct GeneralPane: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("History") {
                Toggle("Keep my dictations, fixes and answers", isOn: $store.settings.history.enabled)
                Picker("Keep entries for", selection: $store.settings.history.retentionDays) {
                    Text("Forever").tag(0)
                    Text("1 year").tag(365)
                    Text("90 days").tag(90)
                    Text("30 days").tag(30)
                }
                Toggle("Keep the audio of every recording", isOn: $store.settings.history.keepAudio)
                Text("Failed recordings are always kept until you retry or delete them.")
                    .font(.caption).foregroundColor(.secondary)
                ListField(title: "Never record fixes in", items: $store.settings.history.excludeApps, placeholder: "App name, e.g. 1Password")
                ListField(title: "Count mistakes for (My Progress)", items: $store.settings.history.mistakeModes, placeholder: "Mode name")
                Button("Delete All History…", role: .destructive) { confirmClear = true }
            }
            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LoginItem.set($0) }
                Toggle("Debug log (includes your text)", isOn: $store.settings.debug)
                HStack {
                    Button("Show Settings Files") { NSWorkspace.shared.activateFileViewerSelecting([Paths.settings]) }
                    Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([Paths.logs.appendingPathComponent("flickwise.log")]) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
        .alert("Delete all history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { HistoryStore.shared.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every dictation, fix, answer and saved recording on this Mac will be removed. This can't be undone.")
        }
    }
}

/// A short editable list of strings (app names, mode names).
struct ListField: View {
    let title: String
    @Binding var items: [String]
    let placeholder: String
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            if !items.isEmpty {
                FlowTags(items: items) { item in items.removeAll { $0 == item } }
            }
            HStack {
                TextField("", text: $draft, prompt: Text(placeholder)).onSubmit(add)
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let v = draft.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !items.contains(v) else { return }
        items.append(v)
        draft = ""
    }
}

private struct FlowTags: View {
    let items: [String]
    let remove: (String) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item).font(.caption)
                    Button { remove(item) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
    }
}

/// API key entry with Save & Test. The key is stored by Secrets (a private file), never in settings.json.
struct APIKeyField: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var key = ""
    @State private var status: String?
    @State private var ok = Secrets.hasAPIKey
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(Secrets.hasAPIKey ? "API key saved — paste a new one to replace it" : "Gemini API key",
                            text: $key)
                Button(testing ? "Testing…" : "Save") { save() }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || testing)
            }
            HStack(spacing: 6) {
                if let status {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundColor(ok ? .green : .red)
                    Text(status).font(.caption)
                } else if Secrets.hasAPIKey {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Key saved on this Mac").font(.caption)
                }
                Spacer()
                Link("Get a free key", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                    .font(.caption)
            }
        }
    }

    private func save() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        testing = true
        Task { @MainActor in
            let error = await GeminiClient.test(key: candidate, model: store.settings.ai.model)
            testing = false
            if let error {
                ok = false
                status = error
            } else {
                Secrets.setAPIKey(candidate)
                ok = true
                status = "Works — saved"
                key = ""
            }
        }
    }
}
