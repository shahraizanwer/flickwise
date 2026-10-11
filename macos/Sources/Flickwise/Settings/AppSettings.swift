// AppSettings — every user-facing option, stored as settings.json in Application Support.
// Each feature has an `enabled` flag plus its tunables. Missing keys fall back to
// the defaults below, so older settings files keep working when options are added.
// The Gemini API key is NOT here: it lives in its own private file (see Secrets.swift).
import Foundation

struct AppSettings: Codable, Equatable {
    var dictation = Dictation()
    var transcription = Transcription()
    var history = History()
    var ai = AI()
    var fixes = Fixes()
    var diffCard = DiffCard()
    var resultCard = Card(enabled: true, durationSeconds: 15)
    var replyCard = Card(enabled: true, durationSeconds: 45)
    var picker = Picker()
    var radialMenu = RadialMenu()
    var debug = false

    /// How text fixes read and write the selection.
    struct Fixes: Codable, Equatable {
        var directReplace = true      // read/replace through Accessibility (clipboard untouched); else ⌘C/⌘V
        var webContent: WebContent = .paste   // browsers/Electron: paste (safe) or direct
        var excludeApps: [String] = []        // apps that always use copy/paste
        var sound = "Tink"            // macOS sound after a fix; "" = none
    }

    enum WebContent: String, Codable, CaseIterable, Identifiable {
        case paste, direct
        var id: String { rawValue }
    }

    /// The "what changed" card after a replace, with Undo.
    struct DiffCard: Codable, Equatable {
        var enabled = true
        var durationSeconds = 6       // auto-dismiss (paused while the pointer is over it)
        var undoHotkey = KeyCombo(keyCode: 6, command: true)   // ⌘Z, only while the card is visible
        var undoMethod: UndoMethod = .app
        var contextWords = 8          // unchanged words kept around each change
    }

    enum UndoMethod: String, Codable, CaseIterable, Identifiable {
        case app, reselect
        var id: String { rawValue }
        var title: String { self == .app ? "The app's own undo (⌘Z)" : "Reselect and paste the original" }
    }

    /// Answer card (output "show") and reply card (output "replies").
    struct Card: Codable, Equatable {
        var enabled: Bool
        var durationSeconds: Int
    }

    struct Picker: Codable, Equatable {
        var enabled = true
        var hotkey = KeyCombo(keyCode: 35, command: true, shift: true)   // ⌘⇧P
    }

    struct RadialMenu: Codable, Equatable {
        var enabled = true
        var trigger: TriggerKey = .rightOption
        var holdMs = 150
        var modes: [String] = []      // mode ids clockwise from the top; empty = the first 8 modes
        var modeNames: [String] = []  // (import only) names from the Hammerspoon config, matched to ids later
    }

    struct Transcription: Codable, Equatable {
        var engine: TranscriptionEngine = .local
        var model = WhisperModel.defaultID          // local model id (see WhisperModel.catalog)
        var language = "auto"                       // "auto", "en", "ur", "hi", …
        var polishWithGemini = false                // run Clean up / Polished English through Gemini (needs a key)
        var keepModelLoaded = false                 // true: keep ~1 GB in memory; false: load on demand (~0.6 s, hidden while you talk)
    }

    struct Dictation: Codable, Equatable {
        var enabled = true
        var trigger: TriggerKey = .rightCommand
        var holdMs = 200              // hold this long before it counts as dictation (a tap does nothing)
        var instantStart = true       // start the mic on key-down so the first word is never cut off
        var style: DictationStyle = .clean
        var maxSeconds = 300          // recording stops by itself after this long
        var microphone = ""        // "" = the system default input
        var sounds = true             // soft sounds when listening starts and when text is inserted
        var indicator: Indicator = .notch   // notch: an island grows out of the notch | pill: capsule at the bottom
    }

    enum Indicator: String, Codable, CaseIterable, Identifiable {
        case notch, pill
        var id: String { rawValue }
        var title: String { self == .notch ? "From the notch" : "Pill at the bottom" }
    }

    struct History: Codable, Equatable {
        var enabled = true            // keep everything you dictate (searchable in Voice History)
        var retentionDays = 0         // 0 = keep forever
        var keepAudio = false         // keep every recording; failed ones are always kept so you can retry
        var excludeApps: [String] = []          // apps whose fixes are never recorded
        var mistakeModes = ["Fix Grammar", "Minimal Fix"]   // modes whose corrections count in My Progress
    }

    struct AI: Codable, Equatable {
        var backend: Backend = .gemini     // for text fixes (dictation is on-device unless transcription.engine = gemini)
        var model = "gemini-flash-lite-latest"
        var timeoutSeconds = 60
        var gleanPath = ""                 // Glean CLI, e.g. /opt/homebrew/bin/glean ("" = auto-detect)
    }

    enum Backend: String, Codable, CaseIterable, Identifiable {
        case gemini, glean
        var id: String { rawValue }
        var title: String { self == .gemini ? "Google Gemini" : "Glean CLI" }
    }
}

enum TranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    case local, gemini
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return "On this Mac (Whisper)"
        case .gemini: return "Gemini (cloud)"
        }
    }
}

enum DictationStyle: String, Codable, CaseIterable, Identifiable {
    case verbatim, clean, english
    var id: String { rawValue }
    var title: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .clean: return "Clean up"
        case .english: return "Polished English"
        }
    }
    var detail: String {
        switch self {
        case .verbatim: return "Exactly what you said, word for word."
        case .clean: return "Removes um/uh, false starts and repeats; fixes grammar. Same language."
        case .english: return "Translates Urdu, Hindi or a mix into natural English and polishes it."
        }
    }
}

// ── tolerant decoding: any missing key keeps its default ──────────────────────

extension KeyedDecodingContainer {
    fileprivate func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

extension AppSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        dictation = c.value(.dictation, d.dictation)
        transcription = c.value(.transcription, d.transcription)
        history = c.value(.history, d.history)
        ai = c.value(.ai, d.ai)
        fixes = c.value(.fixes, d.fixes)
        diffCard = c.value(.diffCard, d.diffCard)
        resultCard = c.value(.resultCard, d.resultCard)
        replyCard = c.value(.replyCard, d.replyCard)
        picker = c.value(.picker, d.picker)
        radialMenu = c.value(.radialMenu, d.radialMenu)
        debug = c.value(.debug, d.debug)
    }
}

extension AppSettings.Dictation {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.value(.enabled, d.enabled)
        trigger = c.value(.trigger, d.trigger)
        holdMs = max(0, c.value(.holdMs, d.holdMs))
        instantStart = c.value(.instantStart, d.instantStart)
        style = c.value(.style, d.style)
        maxSeconds = min(600, max(5, c.value(.maxSeconds, d.maxSeconds)))
        microphone = c.value(.microphone, d.microphone)
        sounds = c.value(.sounds, d.sounds)
        indicator = c.value(.indicator, d.indicator)
    }
}

extension AppSettings.Transcription {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        engine = c.value(.engine, d.engine)
        model = c.value(.model, d.model)
        if WhisperModel.find(model) == nil { model = d.model }
        language = c.value(.language, d.language)
        polishWithGemini = c.value(.polishWithGemini, d.polishWithGemini)
        keepModelLoaded = c.value(.keepModelLoaded, d.keepModelLoaded)
    }
}

extension AppSettings.History {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.value(.enabled, d.enabled)
        retentionDays = max(0, c.value(.retentionDays, d.retentionDays))
        keepAudio = c.value(.keepAudio, d.keepAudio)
        excludeApps = c.value(.excludeApps, d.excludeApps)
        mistakeModes = c.value(.mistakeModes, d.mistakeModes)
    }
}

extension AppSettings.AI {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        backend = c.value(.backend, d.backend)
        model = c.value(.model, d.model)
        timeoutSeconds = min(300, max(5, c.value(.timeoutSeconds, d.timeoutSeconds)))
        gleanPath = c.value(.gleanPath, d.gleanPath)
    }
}

extension AppSettings.Fixes {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        directReplace = c.value(.directReplace, d.directReplace)
        webContent = c.value(.webContent, d.webContent)
        excludeApps = c.value(.excludeApps, d.excludeApps)
        sound = c.value(.sound, d.sound)
    }
}

extension AppSettings.DiffCard {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.value(.enabled, d.enabled)
        durationSeconds = min(120, max(2, c.value(.durationSeconds, d.durationSeconds)))
        undoHotkey = c.value(.undoHotkey, d.undoHotkey)
        undoMethod = c.value(.undoMethod, d.undoMethod)
        contextWords = min(50, max(1, c.value(.contextWords, d.contextWords)))
    }
}

extension AppSettings.Card {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, true)
        durationSeconds = min(600, max(3, c.value(.durationSeconds, 15)))
    }
}

extension AppSettings.Picker {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.value(.enabled, d.enabled)
        hotkey = c.value(.hotkey, d.hotkey)
    }
}

extension AppSettings.RadialMenu {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.value(.enabled, d.enabled)
        trigger = c.value(.trigger, d.trigger)
        holdMs = max(0, c.value(.holdMs, d.holdMs))
        modes = c.value(.modes, d.modes)
        modeNames = c.value(.modeNames, d.modeNames)
    }
}
