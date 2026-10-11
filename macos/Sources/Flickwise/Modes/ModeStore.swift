// ModeStore — the user's modes, in order, saved to ~/Library/Application Support/Flickwise/modes.json.
// Order matters: it's the order in the menu, the picker (1–9) and the radial menu (clockwise).
// A fresh install starts from the Hammerspoon config's modes when there is one, else DefaultModes.
import Combine
import Foundation

final class ModeStore: ObservableObject {
    static let shared = ModeStore()

    @Published var modes: [Mode] {
        didSet { if modes != oldValue { save() } }
    }

    private static var url: URL { Paths.support.appendingPathComponent("modes.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let loaded = try? JSONDecoder().decode([Mode].self, from: data) {
            modes = loaded
        } else {
            modes = LegacyImport.modes() ?? DefaultModes.all
            save()
            Log.info("Modes: started with \(modes.count) (\(LegacyImport.modes() != nil ? "imported from Hammerspoon" : "defaults"))")
        }
    }

    var enabledModes: [Mode] { modes.filter(\.enabled) }

    func mode(id: String) -> Mode? { modes.first { $0.id == id } }

    func add() -> Mode {
        let m = Mode(name: "New Mode", hotkey: nil,
                     prompt: "Rewrite the text … Return ONLY the result. No preamble, no explanation, no quotes.")
        modes.append(m)
        return m
    }

    func duplicate(_ m: Mode) {
        var copy = m
        copy.id = UUID().uuidString
        copy.name += " Copy"
        copy.hotkey = nil
        if let i = modes.firstIndex(of: m) { modes.insert(copy, at: i + 1) } else { modes.append(copy) }
    }

    func delete(_ m: Mode) { modes.removeAll { $0.id == m.id } }

    func move(from source: IndexSet, to destination: Int) {
        var copy = modes
        let moving = source.map { copy[$0] }
        for i in source.sorted(by: >) { copy.remove(at: i) }
        let target = destination - source.filter { $0 < destination }.count
        copy.insert(contentsOf: moving, at: min(max(0, target), copy.count))
        modes = copy
    }

    func update(_ m: Mode) {
        guard let i = modes.firstIndex(where: { $0.id == m.id }) else { return }
        modes[i] = m
    }

    /// Another mode (or a built-in shortcut) already uses this combo?
    func conflict(for combo: KeyCombo, excluding id: String) -> String? {
        if let other = modes.first(where: { $0.id != id && $0.hotkey == combo }) { return other.name }
        if SettingsStore.shared.settings.picker.enabled, SettingsStore.shared.settings.picker.hotkey == combo {
            return "the mode picker"
        }
        return nil
    }

    func restoreDefaults() { modes = DefaultModes.all }

    private func save() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try e.encode(modes).write(to: Self.url, options: .atomic) }
        catch { Log.error("Couldn't save modes: \(error.localizedDescription)") }
    }
}
