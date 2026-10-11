// Log — append-only file log at ~/Library/Logs/Flickwise/flickwise.log.
// Never log transcripts unless `debug` is on, and never log the API key.
import Foundation

enum Log {
    static var debugEnabled = false

    private static let queue = DispatchQueue(label: "flickwise.log")
    private static let url = Paths.logs.appendingPathComponent("flickwise.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }
    static func debug(_ message: @autoclosure () -> String) {
        if debugEnabled { write("DEBUG", message()) }
    }

    private static func write(_ level: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
        #if DEBUG
        print(line, terminator: "")
        #endif
    }

    /// Keep the log from growing forever: trim to the last ~1 MB at launch.
    static func rotate() {
        queue.async {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int, size > 2_000_000,
                  let data = try? Data(contentsOf: url) else { return }
            try? data.suffix(1_000_000).write(to: url)
        }
    }
}
