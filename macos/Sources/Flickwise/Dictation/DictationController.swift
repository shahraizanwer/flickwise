// DictationController — hold-to-talk, end to end.
//
//   idle ─press─► pending ─hold_ms─► recording ─release─► processing ─► idle
//                   │                    │
//                   └─tap/chord─► idle   └─esc─► idle (cancelled)
//
// With `instant_start`, the microphone starts on key-down (while pending) so the
// first word is never clipped; a tap or a shortcut just throws that audio away.
// Processing: Gemini transcribes the audio verbatim, an optional text rewrite
// polishes it (style), and TextInserter types it at the caret. Every dictation is
// saved to HistoryStore; a failed one keeps its audio so it can be retried.
//
// Event-tap callbacks only enqueue work: nothing slow runs inside the tap, and the
// audio engine is started and stopped on its own serial queue.
import AppKit
import AVFoundation

final class DictationController {
    enum State { case idle, pending, recording, processing }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?

    private let store: SettingsStore
    private let history: HistoryStore
    private let monitor: HotkeyMonitor
    private let recorder = AudioRecorder()
    private let audioQueue = DispatchQueue(label: "flickwise.audio", qos: .userInteractive)

    private var holdTimer: DispatchWorkItem?
    private var maxTimer: DispatchWorkItem?
    private var recorderRunning = false
    private var recorderFailure: Error?
    private var session = 0
    private var targetApp: NSRunningApplication?

    private var settings: AppSettings.Dictation { store.settings.dictation }

    init(store: SettingsStore = .shared, history: HistoryStore = .shared) {
        self.store = store
        self.history = history
        monitor = HotkeyMonitor(trigger: store.settings.dictation.trigger)
        monitor.escapeIsOurs = { [weak self] in
            guard let s = self?.state else { return false }
            return s == .pending || s == .recording
        }
        monitor.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        recorder.onLevel = { HUD.shared.level($0) }
    }

    var isListening: Bool { monitor.isRunning }

    /// (Re)starts the key monitor for the current settings. False = Accessibility not granted yet.
    @discardableResult
    func apply() -> Bool {
        if monitor.trigger != settings.trigger || !settings.enabled {
            monitor.stop()
            monitor.trigger = settings.trigger
        }
        guard settings.enabled else { cancel(silently: true); return true }
        return monitor.start()
    }

    func shutdown() {
        cancel(silently: true)
        monitor.stop()
    }

    // ── key events ───────────────────────────────────────────────────────────

    private func handle(_ event: HotkeyMonitor.Event) {
        switch (event, state) {
        case (.pressed, .idle):
            begin()
        case (.pressed, .processing):
            HUD.shared.info("Still working on the last one…")
        case (.released, .pending), (.chord, .pending):
            cancel(silently: true)
        case (.released, .recording):
            finish()
        case (.escape, .pending), (.escape, .recording):
            cancel(silently: state == .pending)
        default:
            break
        }
    }

    private func begin() {
        session += 1
        state = .pending
        targetApp = NSWorkspace.shared.frontmostApplication
        recorderFailure = nil
        monitor.startKeyTap()
        if store.settings.transcription.engine == .gemini { GeminiClient.warmUp() }   // TLS while you speak
        if settings.instantStart && micAuthorized { startRecorder() }
        let id = session
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session == id, self.state == .pending else { return }
            self.becomeRecording()
        }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(settings.holdMs), execute: work)
    }

    private func becomeRecording() {
        guard ensureMicrophone() else { reset(); return }
        if let failure = recorderFailure {
            reset()
            HUD.shared.error("Can't open the microphone: \(failure.localizedDescription)")
            return
        }
        state = .recording
        if !recorderRunning { startRecorder() }
        prepareEngine()                // load the model while you speak (not on key-down: shortcuts don't count)
        HUD.shared.listening(hint: "esc to cancel")
        if settings.sounds { Sounds.play("Pop", volume: 0.25) }
        Log.info("Dictation: recording")
        let id = session
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session == id, self.state == .recording else { return }
            Log.info("Dictation: reached max_seconds")
            self.finish()
        }
        maxTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(settings.maxSeconds), execute: work)
    }

    private func startRecorder() {
        recorderRunning = true
        let uid = settings.microphone
        let id = session
        audioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.recorder.start(deviceUID: uid)
            } catch {
                Log.error("Recorder failed to start: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    guard self.session == id else { return }
                    self.recorderRunning = false
                    self.recorderFailure = error
                    if self.state == .recording {
                        self.reset()
                        HUD.shared.error("Can't open the microphone: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func finish() {
        let style = settings.style
        let app = targetApp
        stopTimers()
        monitor.stopKeyTap()
        state = .processing
        HUD.shared.working("Transcribing…")
        audioQueue.async { [weak self] in
            guard let self else { return }
            let wav = self.recorder.stop()
            DispatchQueue.main.async {
                self.recorderRunning = false
                Task { @MainActor in await self.process(wav: wav, style: style, app: app) }
            }
        }
    }

    /// Esc, a tap, or a shortcut: throw the audio away.
    private func cancel(silently: Bool) {
        guard state == .pending || state == .recording else { return }
        let wasRecording = state == .recording
        reset()
        if wasRecording && !silently { HUD.shared.info("Cancelled") }
        else if wasRecording { HUD.shared.hide() }
        releaseModelIfIdle()
    }

    private func reset() {
        stopTimers()
        monitor.stopKeyTap()
        if recorderRunning {
            recorderRunning = false
            audioQueue.async { [recorder] in recorder.discard() }
        }
        session += 1
        state = .idle
    }

    private func stopTimers() {
        holdTimer?.cancel(); holdTimer = nil
        maxTimer?.cancel(); maxTimer = nil
    }

    // ── processing ───────────────────────────────────────────────────────────

    @MainActor
    private func process(wav: Data, style: DictationStyle, app: NSRunningApplication?) async {
        defer {
            state = .idle
            releaseModelIfIdle()
        }
        let duration = WAV.duration(of: wav)
        Log.info(String(format: "Dictation: %.1f s of audio", duration))
        guard duration >= 0.5 else {
            HUD.shared.info("Too short — hold the key while you speak")
            return
        }

        var record = DictationRecord(createdAt: Date(), duration: duration, appName: app?.localizedName,
                                     appBundleID: app?.bundleIdentifier, style: style, rawText: "", text: "",
                                     status: .inserted)
        do {
            let t = try await Transcriber.run(wav: wav, style: style, settings: store.settings,
                                              status: { HUD.shared.working($0) })
            let text = t.text
            guard !text.isEmpty else {
                HUD.shared.info("Didn't catch any speech")
                return
            }
            record.rawText = t.raw
            record.text = text
            record.engine = t.engine
            switch TextInserter.insert(text, alwaysPasteIn: store.settings.fixes.excludeApps) {
            case .direct:
                record.status = .inserted
                HUD.shared.done("Inserted", detail: Self.preview(text))
            case .pasted:
                record.status = .pasted
                HUD.shared.done("Inserted", detail: Self.preview(text))
            case .copied:
                record.status = .copied
                HUD.shared.done("Copied", detail: "No text field was focused — press ⌘V to paste")
            }
            if settings.sounds { Sounds.play("Tink", volume: 0.35) }
            Log.info("Dictation: \(record.wordCount) words → \(app?.localizedName ?? "?") (\(record.status.rawValue))")
            Log.debug("Dictation text: \(text)")
            if store.settings.history.enabled {
                if store.settings.history.keepAudio { record.audioFile = Self.saveAudio(wav) }
                history.add(record)
            }
        } catch {
            Log.error("Dictation failed: \(error.localizedDescription)")
            if store.settings.history.enabled {
                record.status = .failed
                record.error = error.localizedDescription
                record.audioFile = Self.saveAudio(wav)
                history.add(record)
                HUD.shared.error("\(error.localizedDescription) — saved to History, retry from there")
            } else {
                HUD.shared.error(error.localizedDescription)
            }
        }
    }

    /// Re-runs a failed (or any saved) recording and copies the result.
    @MainActor
    func retry(_ original: DictationRecord) async -> Bool {
        defer { releaseModelIfIdle() }
        guard let file = original.audioFile,
              let wav = try? Data(contentsOf: Paths.audio.appendingPathComponent(file)) else {
            HUD.shared.error("The recording for this entry is gone")
            return false
        }
        HUD.shared.working("Transcribing again…")
        do {
            let t = try await Transcriber.run(wav: wav, style: original.style, settings: store.settings,
                                              status: { HUD.shared.working($0) })
            guard !t.text.isEmpty else {
                HUD.shared.info("Didn't catch any speech in that recording")
                return false
            }
            let text = t.text
            var r = original
            r.rawText = t.raw
            r.text = text
            r.engine = t.engine
            r.status = .copied
            r.error = nil
            if !store.settings.history.keepAudio {
                try? FileManager.default.removeItem(at: Paths.audio.appendingPathComponent(file))
                r.audioFile = nil
            }
            history.update(r)
            TextInserter.copyToClipboard(text)
            HUD.shared.done("Copied", detail: Self.preview(text))
            return true
        } catch {
            var r = original
            r.error = error.localizedDescription
            history.update(r)
            HUD.shared.error(error.localizedDescription)
            return false
        }
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// Gets the recognizer ready while the user is still talking.
    private func prepareEngine() {
        let t = store.settings.transcription
        switch t.engine {
        case .local:
            if let model = WhisperModel.find(t.model), ModelStore.shared.isInstalled(model) {
                WhisperEngine.shared.preload(model)
            }
            if t.polishWithGemini && Secrets.hasAPIKey && settings.style != .verbatim { GeminiClient.warmUp() }
        case .gemini:
            break                       // warmed up on key-down
        }
    }

    /// With keep_model_loaded off, free the model (~1 GB) as soon as it isn't needed.
    private func releaseModelIfIdle() {
        guard !store.settings.transcription.keepModelLoaded, state != .processing else { return }
        WhisperEngine.shared.unload()
    }

    private static func saveAudio(_ wav: Data) -> String? {
        let name = UUID().uuidString + ".wav"
        do {
            try wav.write(to: Paths.audio.appendingPathComponent(name))
            return name
        } catch {
            Log.error("Couldn't save the recording: \(error.localizedDescription)")
            return nil
        }
    }

    private static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 70 ? String(flat.prefix(70)) + "…" : flat
    }

    private var micAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// True when recording can go ahead; otherwise asks for (or explains) microphone access.
    private func ensureMicrophone() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            HUD.shared.info("Allow microphone access, then hold the key again")
            return false
        default:
            HUD.shared.error("Microphone access is off — System Settings › Privacy › Microphone")
            Permissions.openMicrophoneSettings()
            return false
        }
    }
}

enum Sounds {
    private static var cache: [String: NSSound] = [:]

    static func play(_ name: String, volume: Float) {
        let sound = cache[name] ?? NSSound(named: NSSound.Name(name))
        cache[name] = sound
        sound?.stop()
        sound?.volume = volume
        sound?.play()
    }
}
