// SettingsStore — loads and saves settings.json, and publishes changes.
// Editing the file by hand works too: it's re-read when Flickwise starts
// (or via the menu's "Reload Settings").
import Combine
import Foundation

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet { if settings != oldValue { save() } }
    }

    private init() {
        if let loaded = Self.read() {
            settings = loaded
        } else {
            var fresh = AppSettings()
            LegacyImport.apply(to: &fresh)      // first launch: carry over the Hammerspoon setup
            settings = fresh
            save()
        }
        Log.debugEnabled = settings.debug
    }

    func reload() {
        if let loaded = Self.read() { settings = loaded }
        Log.debugEnabled = settings.debug
    }

    private static func read() -> AppSettings? {
        guard let data = try? Data(contentsOf: Paths.settings) else { return nil }
        do {
            return try decoder.decode(AppSettings.self, from: data)
        } catch {
            Log.error("settings.json is invalid (\(error.localizedDescription)) — using defaults for now")
            return AppSettings()
        }
    }

    private func save() {
        Log.debugEnabled = settings.debug
        do {
            try Self.encoder.encode(settings).write(to: Paths.settings, options: .atomic)
        } catch {
            Log.error("Couldn't save settings: \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
