// SettingsView — every option in settings.json, plus the API key (Secrets) and login item.
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var microphones = AudioDevices.inputs()
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var confirmClear = false

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

            Section("Gemini (optional)") {
                APIKeyField()
                TextField("Model", text: $store.settings.ai.model)
                Stepper("Timeout: \(store.settings.ai.timeoutSeconds) s",
                        value: $store.settings.ai.timeoutSeconds, in: 10...300, step: 10)
            }

            Section("Voice History") {
                Toggle("Keep everything I dictate", isOn: $store.settings.history.enabled)
                Picker("Keep entries for", selection: $store.settings.history.retentionDays) {
                    Text("Forever").tag(0)
                    Text("1 year").tag(365)
                    Text("90 days").tag(90)
                    Text("30 days").tag(30)
                }
                Toggle("Keep the audio of every recording", isOn: $store.settings.history.keepAudio)
                Text("Failed recordings are always kept until you retry or delete them.")
                    .font(.caption).foregroundColor(.secondary)
                Button("Delete All History…", role: .destructive) { confirmClear = true }
            }

            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LoginItem.set($0) }
                Toggle("Debug log (includes your text)", isOn: $store.settings.debug)
                HStack {
                    Button("Show Settings File") { NSWorkspace.shared.activateFileViewerSelecting([Paths.settings]) }
                    Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([Paths.logs.appendingPathComponent("flickwise.log")]) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 560)
        .onAppear { microphones = AudioDevices.inputs(); launchAtLogin = LoginItem.isEnabled }
        .alert("Delete all voice history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { HistoryStore.shared.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every dictation and saved recording on this Mac will be removed. This can't be undone.")
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
