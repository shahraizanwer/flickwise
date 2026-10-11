// SpeechViews — choosing and downloading the speech recognizer, shared by Settings and Setup.
import SwiftUI

/// One downloadable Whisper model: name, size, status, and Download / Use / Delete.
struct ModelRow: View {
    let model: WhisperModel
    @ObservedObject var store = ModelStore.shared
    @ObservedObject var settings = SettingsStore.shared

    private var selected: Bool { settings.settings.transcription.model == model.id }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: selected && store.isInstalled(model) ? "checkmark.circle.fill" : "circle")
                .foregroundColor(selected && store.isInstalled(model) ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name).fontWeight(selected ? .semibold : .regular)
                    Text(model.sizeText).font(.caption).foregroundColor(.secondary)
                }
                Text(model.note).font(.caption).foregroundColor(.secondary)
                if let p = store.progress[model.id] {
                    ProgressView(value: p).progressViewStyle(.linear).frame(maxWidth: 220)
                    Text(p >= 1 ? "Verifying…" : "\(Int(p * 100))% of \(model.sizeText)")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if let err = store.errors[model.id] {
                    Text(err).font(.caption).foregroundColor(.red)
                }
                if store.isInstalled(model), model.coreML != nil { boost }
            }
            Spacer()
            actions
        }
        .padding(.vertical, 2)
    }

    /// Optional Neural Engine encoder.
    @ViewBuilder private var boost: some View {
        let key = "coreml:" + model.id
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill").font(.caption2).foregroundColor(store.hasCoreML(model) ? .yellow : .secondary)
            if let p = store.progress[key] {
                Text(p >= 1 ? "Neural Engine boost: verifying…" : "Neural Engine boost: \(Int(p * 100))%")
                    .font(.caption).foregroundColor(.secondary)
                Button("Cancel") { store.cancel(model, coreML: true) }.controlSize(.mini)
            } else if store.hasCoreML(model) {
                Text("Neural Engine boost on (~25% faster)").font(.caption).foregroundColor(.secondary)
                Button("Remove") { store.deleteCoreML(model) }.controlSize(.mini)
            } else {
                Text("Neural Engine boost: ~25% faster, \(ByteCountFormatter.string(fromByteCount: model.coreML!.bytes, countStyle: .file)); first use takes ~2 min to set up")
                    .font(.caption).foregroundColor(.secondary)
                Button("Download") { store.downloadCoreML(model) }.controlSize(.mini)
            }
        }
        if let err = store.errors[key] { Text(err).font(.caption).foregroundColor(.red) }
    }

    @ViewBuilder private var actions: some View {
        if store.progress[model.id] != nil {
            Button("Cancel") { store.cancel(model) }.controlSize(.small)
        } else if store.isInstalled(model) {
            if !selected {
                Button("Use") { settings.settings.transcription.model = model.id }.controlSize(.small)
            }
            Button { store.delete(model) } label: { Image(systemName: "trash") }
                .controlSize(.small).help("Delete the downloaded model")
        } else {
            Button("Download") {
                settings.settings.transcription.model = model.id
                store.download(model)
            }.controlSize(.small)
        }
    }
}

/// The "Speech recognition" section of Settings.
struct SpeechSection: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var showAll = false

    static let languages: [(String, String)] = [
        ("auto", "Detect automatically"), ("en", "English"), ("ur", "Urdu"), ("hi", "Hindi"),
    ]

    var body: some View {
        Section {
            Picker("Recognize speech", selection: $store.settings.transcription.engine) {
                ForEach(TranscriptionEngine.allCases) { Text($0.title).tag($0) }
            }
            if store.settings.transcription.engine == .local {
                ForEach(showAll ? WhisperModel.catalog : [WhisperModel.default] + selectedIfOther) { ModelRow(model: $0) }
                Button(showAll ? "Fewer models" : "More models…") { showAll.toggle() }
                    .buttonStyle(.link).font(.caption)
                Picker("Spoken language", selection: $store.settings.transcription.language) {
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Keep the model in memory (~1 GB)", isOn: $store.settings.transcription.keepModelLoaded)
                Text(store.settings.transcription.keepModelLoaded
                     ? "Ready instantly; uses about 1 GB of memory all the time."
                     : "Loaded when you start speaking (~0.6 s, while you talk) and freed right after: ~65 MB when idle.")
                    .font(.caption).foregroundColor(.secondary)
                Toggle("Polish with Gemini (Clean up / Polished English)", isOn: $store.settings.transcription.polishWithGemini)
                    .disabled(!Secrets.hasAPIKey)
                Text(note).font(.caption).foregroundColor(.secondary)
            } else {
                Text("Audio is sent to Google Gemini. Needs the API key below.")
                    .font(.caption).foregroundColor(.secondary)
            }
        } header: {
            Text("Speech recognition")
        }
    }

    private var selectedIfOther: [WhisperModel] {
        let id = store.settings.transcription.model
        guard id != WhisperModel.defaultID, let m = WhisperModel.find(id) else { return [] }
        return [m]
    }

    private var note: String {
        let t = store.settings.transcription
        let model = WhisperModel.find(t.model) ?? .default
        if t.polishWithGemini && Secrets.hasAPIKey { return "Speech stays on this Mac; only the text is sent to Gemini to polish." }
        if store.settings.dictation.style == .english && !model.translates {
            return "Everything stays on this Mac. Turbo models transcribe but don't translate: for Polished English from Urdu/Hindi speech, use Small or turn on Gemini polish."
        }
        return "Everything stays on this Mac: no internet needed, no rate limits."
    }
}
