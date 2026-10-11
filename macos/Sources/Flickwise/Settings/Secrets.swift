// Secrets — the Gemini API key, in ~/Library/Application Support/Flickwise/gemini_api_key
// (readable only by you: mode 0600). Not in the Keychain on purpose: this app is signed with
// a local certificate without an Apple Team ID, so the Keychain ties its items to the exact
// binary and would ask for your password after every update.
import Foundation

enum Secrets {
    private static var url: URL { Paths.support.appendingPathComponent("gemini_api_key") }
    private static var cached: String??

    static var apiKey: String? {
        if let cached { return cached }
        let key = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (key?.isEmpty ?? true) ? nil : key
        cached = .some(value)
        return value
    }

    static var hasAPIKey: Bool { apiKey != nil }

    @discardableResult
    static func setAPIKey(_ key: String?) -> Bool {
        cached = nil
        let trimmed = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        let fm = FileManager.default
        guard fm.createFile(atPath: url.path, contents: Data(trimmed.utf8), attributes: [.posixPermissions: 0o600]) else {
            Log.error("Couldn't save the API key")
            return false
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}
