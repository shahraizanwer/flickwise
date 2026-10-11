// SetupView — first-run checklist: Accessibility, Microphone, API key, open at login,
// and a box to try dictation right away. Re-open any time from the menu.
import AVFoundation
import SwiftUI

struct SetupView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var axOK = Permissions.accessibility
    @State private var mic = Permissions.microphone
    @State private var hasKey = Secrets.hasAPIKey
    @ObservedObject private var models = ModelStore.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var tryText = ""
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var speechReady: Bool {
        let t = store.settings.transcription
        switch t.engine {
        case .local: return models.installed.contains(t.model)
        case .gemini: return hasKey
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Welcome to Flickwise").font(.title2.weight(.semibold))
                        Text("Hold \(store.settings.dictation.trigger.short), speak, let go. Your words appear wherever you're typing, and every one is saved in Voice History.")
                            .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                Step(done: axOK, title: "Accessibility",
                     detail: "Lets Flickwise notice the key you hold and type into other apps.",
                     action: axOK ? nil : ("Grant Access", Permissions.requestAccessibility))
                Step(done: mic == .authorized, title: "Microphone",
                     detail: mic == .denied ? "Turned off. Switch Flickwise on in Privacy & Security › Microphone."
                                            : "Only used while you hold the key.",
                     action: mic == .authorized ? nil : ("Allow", Permissions.requestMicrophone))
                VStack(alignment: .leading, spacing: 8) {
                    StepTitle(done: speechReady, title: "Speech recognition")
                    if store.settings.transcription.engine == .local {
                        Text("Runs on this Mac: private, offline, no limits. Download the model once:")
                            .font(.callout).foregroundColor(.secondary).padding(.leading, 30)
                        ModelRow(model: WhisperModel.find(store.settings.transcription.model) ?? .default)
                            .padding(.leading, 30)
                        Button("Use Gemini (cloud) instead") { store.settings.transcription.engine = .gemini }
                            .buttonStyle(.link).font(.caption).padding(.leading, 30)
                    } else {
                        APIKeyField().padding(.leading, 30)
                        Button("Use the on-device model instead") { store.settings.transcription.engine = .local }
                            .buttonStyle(.link).font(.caption).padding(.leading, 30)
                    }
                }
                Toggle("Open Flickwise when I log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LoginItem.set($0) }
                    .padding(.leading, 30)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Try it here").font(.headline)
                    Text("Click in the box, hold \(store.settings.dictation.trigger.short), say something, and let go.")
                        .font(.callout).foregroundColor(.secondary)
                    TextEditor(text: $tryText)
                        .font(.system(size: 14))
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                }
                .padding(.top, 4)

                HStack {
                    Spacer()
                    Button("Done") { WindowManager.shared.close("setup") }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 600)
        .onReceive(poll) { _ in
            let wasAX = axOK
            axOK = Permissions.accessibility
            mic = Permissions.microphone
            hasKey = Secrets.hasAPIKey
            if axOK && !wasAX { AppDelegate.shared?.permissionsChanged() }
        }
    }
}

private struct StepTitle: View {
    let done: Bool
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18)).foregroundColor(done ? .green : .secondary)
            Text(title).font(.headline)
        }
    }
}

private struct Step: View {
    let done: Bool
    let title: String
    let detail: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                StepTitle(done: done, title: title)
                Text(detail).font(.callout).foregroundColor(.secondary).padding(.leading, 30)
            }
            Spacer()
            if let action { Button(action.0, action: action.1) }
        }
    }
}
