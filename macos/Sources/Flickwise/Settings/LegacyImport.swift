// LegacyImport — on first launch, carry over the Hammerspoon Flickwise setup from
// ~/.hammerspoon/flickwise/config.yaml: the Gemini key (into Secrets), the model,
// and the dictation trigger, style, hold time and length limit.
// A small line-based reader is enough: only a few known scalar keys are read.
import Foundation

enum LegacyImport {
    /// Any launch without a key: take the one from the Hammerspoon config, if there is one.
    static func importAPIKeyIfMissing() {
        guard !Secrets.hasAPIKey else { return }
        var scratch = AppSettings()
        apply(to: &scratch, keyOnly: true)
    }

    static func apply(to settings: inout AppSettings, keyOnly: Bool = false) {
        guard let text = try? String(contentsOf: Paths.legacyConfig, encoding: .utf8) else { return }
        var section: [String] = []          // path of parent keys by indentation level
        var imported: [String] = []

        for raw in text.components(separatedBy: .newlines) {
            let noComment = stripComment(raw)
            guard !noComment.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indent = noComment.prefix { $0 == " " }.count / 2
            let line = noComment.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("-") else { continue }
            let key = String(line[..<colon])
            let value = unquote(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            section = Array(section.prefix(indent))
            let path = (section + [key]).joined(separator: ".")
            if value.isEmpty { section.append(key); continue }
            if keyOnly && path != "gemini_api_key" { continue }

            switch path {
            case "gemini_api_key":
                if !Secrets.hasAPIKey, Secrets.setAPIKey(value) { imported.append("API key") }
            case "gemini_model":
                settings.ai.model = value; imported.append("model")
            case "features.dictation.trigger":
                if let t = TriggerKey(rawValue: value) { settings.dictation.trigger = t; imported.append("trigger") }
            case "features.dictation.style":
                if let s = DictationStyle(rawValue: value) { settings.dictation.style = s; imported.append("style") }
            case "features.dictation.hold_ms":
                if let n = Int(value) { settings.dictation.holdMs = n }
            case "features.dictation.max_seconds":
                if let n = Int(value) { settings.dictation.maxSeconds = max(n, settings.dictation.maxSeconds) }
            default:
                break
            }
        }
        if !imported.isEmpty { Log.info("Imported from the Hammerspoon config: \(imported.joined(separator: ", "))") }
    }

    private static func stripComment(_ line: String) -> String {
        var inQuote: Character?
        for (i, ch) in line.enumerated() {
            if ch == "\"" || ch == "'" { inQuote = (inQuote == ch) ? nil : (inQuote ?? ch) }
            if ch == "#", inQuote == nil { return String(line.prefix(i)) }
        }
        return line
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, let f = s.first, let l = s.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
