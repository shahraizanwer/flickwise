// Paths — where Flickwise keeps its files (all local to this Mac).
//   ~/Library/Application Support/Flickwise/settings.json   settings (no secrets)
//   ~/Library/Application Support/Flickwise/history.sqlite  voice history
//   ~/Library/Application Support/Flickwise/audio/           recordings kept for retry
//   ~/Library/Logs/Flickwise/flickwise.log                   log
// FLICKWISE_SUPPORT_DIR overrides the Application Support folder (used by --selftest).
import Foundation

enum Paths {
    static let support: URL = {
        if let dir = ProcessInfo.processInfo.environment["FLICKWISE_SUPPORT_DIR"], !dir.isEmpty {
            return ensure(URL(fileURLWithPath: dir, isDirectory: true))     // tests: a sandbox folder
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Flickwise", isDirectory: true))
    }()

    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var history: URL { support.appendingPathComponent("history.sqlite") }
    static var audio: URL { ensure(support.appendingPathComponent("audio", isDirectory: true)) }

    static let logs: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Logs/Flickwise", isDirectory: true))
    }()

    /// The Hammerspoon-based Flickwise config, imported once on first launch.
    static var legacyConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hammerspoon/flickwise/config.yaml")
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
