// Mode — one AI action on selected text (Fix Grammar, Make Concise, Reply Helper…).
// KeyCombo — a keyboard shortcut, stored as names like ["cmd", "shift", "g"] (the same
// format the Hammerspoon config used, so modes import as-is).
import AppKit
import Carbon.HIToolbox

struct Mode: Codable, Identifiable, Equatable, Hashable {
    enum Output: String, Codable, CaseIterable, Identifiable {
        case replace, show, replies
        var id: String { rawValue }
        var title: String {
            switch self {
            case .replace: return "Replace the text"
            case .show: return "Show the answer"
            case .replies: return "Suggest replies"
            }
        }
        var detail: String {
            switch self {
            case .replace: return "The selection is replaced with the result (with a “what changed” card and Undo)."
            case .show: return "The answer appears in a card; the selected text is never changed."
            case .replies: return "Expects JSON {meaning, replies:[{label, text}]}; press 1–3 to insert a reply."
            }
        }
    }

    var id = UUID().uuidString
    var name: String
    var hotkey: KeyCombo?
    var output: Output = .replace
    var temperature: Double?           // nil = backend default (0.2); Gemini only
    var showDiff = true                // "what changed" card after a replace
    var enabled = true
    var timeoutSeconds: Int?           // nil = Settings › AI timeout
    var prompt: String

    init(name: String, hotkey: KeyCombo?, output: Output = .replace, temperature: Double? = nil,
         showDiff: Bool = true, prompt: String) {
        self.name = name
        self.hotkey = hotkey
        self.output = output
        self.temperature = temperature
        self.showDiff = showDiff
        self.prompt = prompt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        hotkey = try? c.decodeIfPresent(KeyCombo.self, forKey: .hotkey)
        output = (try? c.decode(Output.self, forKey: .output)) ?? .replace
        temperature = try? c.decodeIfPresent(Double.self, forKey: .temperature)
        showDiff = (try? c.decode(Bool.self, forKey: .showDiff)) ?? true
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        timeoutSeconds = try? c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
    }
}

struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: Int
    var command = false, shift = false, option = false, control = false

    init(keyCode: Int, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.keyCode = keyCode
        self.command = command; self.shift = shift; self.option = option; self.control = control
    }

    /// From names like ["cmd", "shift", "g"]; nil if the key isn't known.
    init?(names: [String]) {
        var key: Int?
        for raw in names {
            switch raw.lowercased() {
            case "cmd", "command", "⌘": command = true
            case "shift", "⇧": shift = true
            case "alt", "option", "opt", "⌥": option = true
            case "ctrl", "control", "⌃": control = true
            default: key = KeyCombo.code(for: raw.lowercased())
            }
        }
        guard let key else { return nil }
        keyCode = key
    }

    init?(event: NSEvent) {
        let f = event.modifierFlags
        guard KeyCombo.name(for: Int(event.keyCode)) != nil else { return nil }
        keyCode = Int(event.keyCode)
        command = f.contains(.command); shift = f.contains(.shift)
        option = f.contains(.option); control = f.contains(.control)
    }

    var names: [String] {
        var out: [String] = []
        if control { out.append("ctrl") }
        if option { out.append("alt") }
        if shift { out.append("shift") }
        if command { out.append("cmd") }
        out.append(KeyCombo.name(for: keyCode) ?? "?")
        return out
    }

    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + (KeyCombo.symbol(for: keyCode) ?? "?")
    }

    var hasModifier: Bool { command || option || control }

    var carbonModifiers: UInt32 {
        (command ? UInt32(cmdKey) : 0) | (shift ? UInt32(shiftKey) : 0)
            | (option ? UInt32(optionKey) : 0) | (control ? UInt32(controlKey) : 0)
    }

    func matches(_ event: CGEvent) -> Bool {
        let f = event.flags
        return Int(event.getIntegerValueField(.keyboardEventKeycode)) == keyCode
            && f.contains(.maskCommand) == command && f.contains(.maskShift) == shift
            && f.contains(.maskAlternate) == option && f.contains(.maskControl) == control
    }

    // Codable as names, e.g. ["cmd", "shift", "g"]
    init(from decoder: Decoder) throws {
        let names = try decoder.singleValueContainer().decode([String].self)
        guard let combo = KeyCombo(names: names) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown key"))
        }
        self = combo
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(names)
    }

    // ── key tables (ANSI virtual key codes) ──────────────────────────────────

    private static let table: [(name: String, code: Int, symbol: String)] = {
        var t: [(String, Int, String)] = [
            ("a", kVK_ANSI_A, "A"), ("b", kVK_ANSI_B, "B"), ("c", kVK_ANSI_C, "C"), ("d", kVK_ANSI_D, "D"),
            ("e", kVK_ANSI_E, "E"), ("f", kVK_ANSI_F, "F"), ("g", kVK_ANSI_G, "G"), ("h", kVK_ANSI_H, "H"),
            ("i", kVK_ANSI_I, "I"), ("j", kVK_ANSI_J, "J"), ("k", kVK_ANSI_K, "K"), ("l", kVK_ANSI_L, "L"),
            ("m", kVK_ANSI_M, "M"), ("n", kVK_ANSI_N, "N"), ("o", kVK_ANSI_O, "O"), ("p", kVK_ANSI_P, "P"),
            ("q", kVK_ANSI_Q, "Q"), ("r", kVK_ANSI_R, "R"), ("s", kVK_ANSI_S, "S"), ("t", kVK_ANSI_T, "T"),
            ("u", kVK_ANSI_U, "U"), ("v", kVK_ANSI_V, "V"), ("w", kVK_ANSI_W, "W"), ("x", kVK_ANSI_X, "X"),
            ("y", kVK_ANSI_Y, "Y"), ("z", kVK_ANSI_Z, "Z"),
            ("0", kVK_ANSI_0, "0"), ("1", kVK_ANSI_1, "1"), ("2", kVK_ANSI_2, "2"), ("3", kVK_ANSI_3, "3"),
            ("4", kVK_ANSI_4, "4"), ("5", kVK_ANSI_5, "5"), ("6", kVK_ANSI_6, "6"), ("7", kVK_ANSI_7, "7"),
            ("8", kVK_ANSI_8, "8"), ("9", kVK_ANSI_9, "9"),
            ("space", kVK_Space, "Space"), ("return", kVK_Return, "↩"), ("tab", kVK_Tab, "⇥"),
            ("escape", kVK_Escape, "⎋"), ("delete", kVK_Delete, "⌫"),
            ("-", kVK_ANSI_Minus, "-"), ("=", kVK_ANSI_Equal, "="), ("[", kVK_ANSI_LeftBracket, "["),
            ("]", kVK_ANSI_RightBracket, "]"), (";", kVK_ANSI_Semicolon, ";"), ("'", kVK_ANSI_Quote, "'"),
            (",", kVK_ANSI_Comma, ","), (".", kVK_ANSI_Period, "."), ("/", kVK_ANSI_Slash, "/"),
            ("\\", kVK_ANSI_Backslash, "\\"), ("`", kVK_ANSI_Grave, "`"),
            ("left", kVK_LeftArrow, "←"), ("right", kVK_RightArrow, "→"), ("up", kVK_UpArrow, "↑"),
            ("down", kVK_DownArrow, "↓"),
        ]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        for (i, code) in fkeys.enumerated() { t.append(("f\(i + 1)", code, "F\(i + 1)")) }
        return t
    }()

    static func code(for name: String) -> Int? { table.first { $0.name == name }?.code }
    static func name(for code: Int) -> String? { table.first { $0.code == code }?.name }
    static func symbol(for code: Int) -> String? { table.first { $0.code == code }?.symbol }
}
