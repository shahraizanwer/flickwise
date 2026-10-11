// LegacyImport — carries an existing Hammerspoon Flickwise setup over to the app:
//   apply(to:)            first launch (no settings.json): dictation, AI backend (Gemini model / Glean path),
//                          fixes, cards, picker, radial menu, history settings. The Gemini key goes to Secrets.
//   modes()               the config's modes (prompts, hotkeys, output, temperature, diff opt-out)
//   migrateIfNeeded()     once per Mac, for installs that predate the text fixes: imports the fix settings
//                          and the fix history (data/history.jsonl) without touching dictation settings.
// Reads ~/.hammerspoon/flickwise/config.yaml with MiniYAML. Nothing is written back to it.
import Foundation

enum LegacyImport {
    private static var config: [String: Any]? {
        guard let text = try? String(contentsOf: Paths.legacyConfig, encoding: .utf8) else { return nil }
        return MiniYAML.parse(text)
    }

    private static var marker: URL { Paths.support.appendingPathComponent(".imported-hammerspoon-v2") }

    /// Any launch without a key: take the one from the Hammerspoon config, if there is one.
    static func importAPIKeyIfMissing() {
        guard !Secrets.hasAPIKey, let key = config?["gemini_api_key"] as? String, !key.isEmpty else { return }
        if Secrets.setAPIKey(key) { Log.info("Imported the Gemini key from the Hammerspoon config") }
    }

    /// First launch: everything.
    static func apply(to settings: inout AppSettings) {
        guard let cfg = config else { return }
        importDictation(cfg, into: &settings)
        importFixSettings(cfg, into: &settings)
        importAPIKeyIfMissing()
        try? Data().write(to: marker)
        Log.info("Imported the Hammerspoon setup (settings)")
    }

    /// What apply(to:) would import, without writing anything (for --import-preview).
    static func applyPreview(to settings: inout AppSettings) {
        guard let cfg = config else { return }
        importDictation(cfg, into: &settings)
        importFixSettings(cfg, into: &settings)
    }

    /// Existing installs from before text fixes moved into the app: fix settings + fix history, once.
    static func migrateIfNeeded(_ store: SettingsStore) {
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        defer { try? Data().write(to: marker) }
        guard let cfg = config else { return }
        importFixSettings(cfg, into: &store.settings)
        importFixHistory()
        Log.info("Imported the Hammerspoon fix settings and history")
    }

    static func modes() -> [Mode]? {
        guard let list = config?["modes"] as? [[String: Any]], !list.isEmpty else { return nil }
        let modes: [Mode] = list.compactMap { m in
            guard let name = m["name"] as? String, let prompt = m["system_prompt"] as? String else { return nil }
            var mode = Mode(name: name, hotkey: (m["hotkey"] as? [String]).flatMap(KeyCombo.init(names:)),
                            output: Mode.Output(rawValue: m["output"] as? String ?? "") ?? .replace,
                            temperature: (m["temperature"] as? String).flatMap(Double.init),
                            showDiff: (m["diff_bubble"] as? String) != "false",
                            prompt: prompt.trimmingCharacters(in: .newlines))
            if let t = (m["timeout_seconds"] as? String).flatMap(Int.init) { mode.timeoutSeconds = t }
            return mode
        }
        return modes.isEmpty ? nil : modes
    }

    // ── pieces ───────────────────────────────────────────────────────────────

    private static func importDictation(_ cfg: [String: Any], into s: inout AppSettings) {
        if let model = cfg["gemini_model"] as? String, !model.isEmpty { s.ai.model = model }
        guard let d = (cfg["features"] as? [String: Any])?["dictation"] as? [String: Any] else { return }
        if let t = (d["trigger"] as? String).flatMap(TriggerKey.init(rawValue:)) { s.dictation.trigger = t }
        if let st = (d["style"] as? String).flatMap(DictationStyle.init(rawValue:)) { s.dictation.style = st }
        if let n = int(d["hold_ms"]) { s.dictation.holdMs = n }
        if let n = int(d["max_seconds"]) { s.dictation.maxSeconds = max(n, s.dictation.maxSeconds) }
    }

    private static func importFixSettings(_ cfg: [String: Any], into s: inout AppSettings) {
        if let glean = cfg["glean_binary_path"] as? String, !glean.isEmpty {
            s.ai.backend = .glean
            s.ai.gleanPath = glean
        }
        if let model = cfg["gemini_model"] as? String, !model.isEmpty { s.ai.model = model }
        if let defaults = cfg["defaults"] as? [String: Any] {
            if let sound = defaults["sound"] as? String { s.fixes.sound = sound == "false" ? "" : sound }
            if let t = int(defaults["timeout_seconds"]) { s.ai.timeoutSeconds = max(t, 10) }
        }
        if let hk = (cfg["picker_hotkey"] as? [String]).flatMap(KeyCombo.init(names:)) { s.picker.hotkey = hk }
        guard let f = cfg["features"] as? [String: Any] else { return }
        if let d = f["diff_bubble"] as? [String: Any] {
            if let b = bool(d["enabled"]) { s.diffCard.enabled = b }
            if let n = int(d["duration_seconds"]) { s.diffCard.durationSeconds = n }
            if let hk = (d["undo_hotkey"] as? [String]).flatMap(KeyCombo.init(names:)) { s.diffCard.undoHotkey = hk }
            if let m = (d["undo_method"] as? String).flatMap(AppSettings.UndoMethod.init(rawValue:)) { s.diffCard.undoMethod = m }
            if let n = int(d["context_words"]) { s.diffCard.contextWords = n }
        }
        if let r = f["radial_menu"] as? [String: Any] {
            if let b = bool(r["enabled"]) { s.radialMenu.enabled = b }
            if let t = (r["trigger"] as? String).flatMap(TriggerKey.init(rawValue:)) { s.radialMenu.trigger = t }
            if let n = int(r["hold_ms"]) { s.radialMenu.holdMs = n }
            if let names = r["modes"] as? [String], !names.isEmpty {
                s.radialMenu.modeNames = names              // matched to mode ids once modes are loaded
            }
        }
        if let d = f["direct_replace"] as? [String: Any] {
            if let b = bool(d["enabled"]) { s.fixes.directReplace = b }
            if let w = (d["web_content"] as? String).flatMap(AppSettings.WebContent.init(rawValue:)) { s.fixes.webContent = w }
            if let apps = d["exclude_apps"] as? [String] { s.fixes.excludeApps = apps }
        }
        if let c = f["result_card"] as? [String: Any] {
            if let b = bool(c["enabled"]) { s.resultCard.enabled = b }
            if let n = int(c["duration_seconds"]) { s.resultCard.durationSeconds = n }
        }
        if let c = f["reply_helper"] as? [String: Any] {
            if let b = bool(c["enabled"]) { s.replyCard.enabled = b }
            if let n = int(c["duration_seconds"]) { s.replyCard.durationSeconds = n }
        }
        if let h = f["history"] as? [String: Any] {
            if let apps = h["exclude_apps"] as? [String] { s.history.excludeApps = apps }
            if let modes = h["mistake_modes"] as? [String] { s.history.mistakeModes = modes }
        }
    }

    /// data/history.jsonl → the history database (kind "fix" / "answer"), oldest first.
    static func importFixHistory() {
        let url = Paths.legacyConfig.deletingLastPathComponent().appendingPathComponent("data/history.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var count = 0
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let e = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let original = e["original"] as? String, let result = e["result"] as? String else { continue }
            let ts = (e["ts"] as? Double) ?? Double(e["ts"] as? Int ?? 0)
            var r = DictationRecord(createdAt: Date(timeIntervalSince1970: ts), duration: 0,
                                    appName: e["app"] as? String, appBundleID: nil, style: .verbatim,
                                    rawText: original, text: result, status: .inserted)
            r.kind = (e["output"] as? String) == "show" ? .answer : .fix
            r.mode = e["mode"] as? String
            r.undone = (e["undone"] as? Bool) ?? false
            if let ms = e["mistakes"] as? [[String: Any]], e["tracked"] as? Bool == true {
                r.mistakes = ms.compactMap { m in
                    guard let f = m["from"] as? String, let t = m["to"] as? String, let c = m["cat"] as? String else { return nil }
                    return Mistakes.Mistake(from: f, to: t, cat: c)
                }
            }
            HistoryStore.shared.add(r)
            count += 1
        }
        Log.info("Imported \(count) fix history entries from Hammerspoon")
    }

    private static func int(_ v: Any?) -> Int? { (v as? String).flatMap { Int($0) } }
    private static func bool(_ v: Any?) -> Bool? {
        switch (v as? String)?.lowercased() { case "true": return true; case "false": return false; default: return nil }
    }
}
