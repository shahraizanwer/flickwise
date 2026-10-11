// HistoryStore — every dictation, kept in a local SQLite database with full-text search.
// Stored in ~/Library/Application Support/Flickwise/history.sqlite (this Mac only).
//   add(_:) / update(_:) / delete(id:) / deleteAll()
//   recent(limit:) / search(_:limit:)     newest first
//   stats()                               word counts, streak, time saved
// Failed dictations keep their audio (audio/<uuid>.wav) so they can be retried.
import Foundation
import SQLite3

struct DictationRecord: Identifiable, Equatable {
    enum Status: String { case inserted, pasted, copied, failed }

    var id: Int64 = 0
    var createdAt: Date
    var duration: Double            // seconds of audio
    var appName: String?
    var appBundleID: String?
    var style: DictationStyle
    var rawText: String             // verbatim transcript
    var text: String                // what was typed (after polish)
    var status: Status
    var error: String?
    var audioFile: String?          // file name inside Paths.audio
    var engine: String?             // which recognizer produced it, e.g. "whisper:large-v3-turbo-q5_0"

    var wordCount: Int { Self.words(in: text) }

    static func words(in s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.count
    }
}

struct HistoryStats: Equatable {
    var todayWords = 0
    var weekWords = 0
    var totalWords = 0
    var totalCount = 0
    var speakingSeconds = 0.0
    var streakDays = 0
    /// Typing at ~40 wpm versus the time actually spent speaking.
    var minutesSaved: Int { max(0, Int((Double(totalWords) / 40.0) - speakingSeconds / 60.0)) }
}

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    /// Bumped on every change so open windows can refresh.
    @Published private(set) var revision = 0

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "flickwise.history")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        queue.sync { open() }
    }

    // ── writes ──────────────────────────────────────────────────────────────

    @discardableResult
    func add(_ r: DictationRecord) -> Int64 {
        let id: Int64 = queue.sync {
            let sql = """
            INSERT INTO dictations (created_at, duration, app_name, app_bundle, style, raw_text, text, words, status, error, audio_file, engine)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """
            guard let st = prepare(sql) else { return 0 }
            defer { sqlite3_finalize(st) }
            bind(st, r)
            guard sqlite3_step(st) == SQLITE_DONE else { logError("insert"); return 0 }
            return sqlite3_last_insert_rowid(db)
        }
        changed()
        return id
    }

    func update(_ r: DictationRecord) {
        queue.sync {
            let sql = """
            UPDATE dictations SET created_at=?, duration=?, app_name=?, app_bundle=?, style=?, raw_text=?, text=?,
                   words=?, status=?, error=?, audio_file=?, engine=? WHERE id=?
            """
            guard let st = prepare(sql) else { return }
            defer { sqlite3_finalize(st) }
            bind(st, r)
            sqlite3_bind_int64(st, 13, r.id)
            if sqlite3_step(st) != SQLITE_DONE { logError("update") }
        }
        changed()
    }

    func delete(id: Int64) {
        let file = queue.sync { () -> String? in
            let file = audioFile(id: id)
            exec("DELETE FROM dictations WHERE id = \(id)")
            return file
        }
        if let file { try? FileManager.default.removeItem(at: Paths.audio.appendingPathComponent(file)) }
        changed()
    }

    func deleteAll() {
        queue.sync { exec("DELETE FROM dictations"); exec("VACUUM") }
        if let files = try? FileManager.default.contentsOfDirectory(at: Paths.audio, includingPropertiesForKeys: nil) {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        changed()
    }

    /// Drops entries older than `days` (0 = keep forever), with their audio.
    func prune(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        let (files, removed): ([String], Int32) = queue.sync {
            var files: [String] = []
            if let st = prepare("SELECT audio_file FROM dictations WHERE created_at < ? AND audio_file IS NOT NULL") {
                sqlite3_bind_double(st, 1, cutoff)
                while sqlite3_step(st) == SQLITE_ROW { if let s = text(st, 0) { files.append(s) } }
                sqlite3_finalize(st)
            }
            exec("DELETE FROM dictations WHERE created_at < \(cutoff)")
            return (files, sqlite3_changes(db))
        }
        files.forEach { try? FileManager.default.removeItem(at: Paths.audio.appendingPathComponent($0)) }
        if removed > 0 { Log.info("History: pruned \(removed) old entries"); changed() }
    }

    // ── reads ───────────────────────────────────────────────────────────────

    func recent(limit: Int = 500) -> [DictationRecord] {
        queue.sync { select("SELECT \(Self.columns) FROM dictations ORDER BY created_at DESC LIMIT \(limit)") }
    }

    func search(_ query: String, limit: Int = 500) -> [DictationRecord] {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty else { return recent(limit: limit) }
        return queue.sync {
            select("""
                SELECT \(Self.columns.split(separator: ",").map { "d." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
                FROM dictations_fts f JOIN dictations d ON d.id = f.rowid
                WHERE dictations_fts MATCH ? ORDER BY d.created_at DESC LIMIT \(limit)
                """, bind: match)
        }
    }

    func record(id: Int64) -> DictationRecord? {
        queue.sync { select("SELECT \(Self.columns) FROM dictations WHERE id = \(id)").first }
    }

    func stats() -> HistoryStats {
        queue.sync {
            var s = HistoryStats()
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date()).timeIntervalSince1970
            let week = cal.dateInterval(of: .weekOfYear, for: Date())?.start.timeIntervalSince1970 ?? today
            let ok = "status != 'failed'"
            s.todayWords = intQuery("SELECT COALESCE(SUM(words),0) FROM dictations WHERE \(ok) AND created_at >= \(today)")
            s.weekWords = intQuery("SELECT COALESCE(SUM(words),0) FROM dictations WHERE \(ok) AND created_at >= \(week)")
            s.totalWords = intQuery("SELECT COALESCE(SUM(words),0) FROM dictations WHERE \(ok)")
            s.totalCount = intQuery("SELECT COUNT(*) FROM dictations WHERE \(ok)")
            if let st = prepare("SELECT COALESCE(SUM(duration),0) FROM dictations WHERE \(ok)") {
                if sqlite3_step(st) == SQLITE_ROW { s.speakingSeconds = sqlite3_column_double(st, 0) }
                sqlite3_finalize(st)
            }
            // Streak: consecutive days (ending today or yesterday) with at least one dictation.
            var days = Set<Int>()
            if let st = prepare("SELECT DISTINCT CAST((created_at - ?) / 86400 AS INTEGER) FROM dictations WHERE \(ok)") {
                sqlite3_bind_double(st, 1, Double(TimeZone.current.secondsFromGMT()) * -1)
                while sqlite3_step(st) == SQLITE_ROW { days.insert(Int(sqlite3_column_int64(st, 0))) }
                sqlite3_finalize(st)
            }
            var day = Int((Date().timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT())) / 86_400)
            if !days.contains(day) { day -= 1 }
            while days.contains(day) { s.streakDays += 1; day -= 1 }
            return s
        }
    }

    // ── schema ──────────────────────────────────────────────────────────────

    private static let columns =
        "id, created_at, duration, app_name, app_bundle, style, raw_text, text, status, error, audio_file, engine"

    private func open() {
        guard sqlite3_open(Paths.history.path, &db) == SQLITE_OK else {
            Log.error("Couldn't open the history database")
            return
        }
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS dictations (
            id          INTEGER PRIMARY KEY,
            created_at  REAL NOT NULL,
            duration    REAL NOT NULL DEFAULT 0,
            app_name    TEXT,
            app_bundle  TEXT,
            style       TEXT NOT NULL,
            raw_text    TEXT NOT NULL DEFAULT '',
            text        TEXT NOT NULL DEFAULT '',
            words       INTEGER NOT NULL DEFAULT 0,
            status      TEXT NOT NULL,
            error       TEXT,
            audio_file  TEXT
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS dictations_created ON dictations(created_at)")
        addColumnIfMissing("engine", "TEXT")
        exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS dictations_fts USING fts5(
            text, raw_text, app_name, content='dictations', content_rowid='id', tokenize='unicode61 remove_diacritics 2')
        """)
        exec("""
        CREATE TRIGGER IF NOT EXISTS dictations_ai AFTER INSERT ON dictations BEGIN
            INSERT INTO dictations_fts(rowid, text, raw_text, app_name) VALUES (new.id, new.text, new.raw_text, new.app_name);
        END
        """)
        exec("""
        CREATE TRIGGER IF NOT EXISTS dictations_ad AFTER DELETE ON dictations BEGIN
            INSERT INTO dictations_fts(dictations_fts, rowid, text, raw_text, app_name)
            VALUES ('delete', old.id, old.text, old.raw_text, old.app_name);
        END
        """)
        exec("""
        CREATE TRIGGER IF NOT EXISTS dictations_au AFTER UPDATE ON dictations BEGIN
            INSERT INTO dictations_fts(dictations_fts, rowid, text, raw_text, app_name)
            VALUES ('delete', old.id, old.text, old.raw_text, old.app_name);
            INSERT INTO dictations_fts(rowid, text, raw_text, app_name) VALUES (new.id, new.text, new.raw_text, new.app_name);
        END
        """)
    }

    /// Turns what the user typed into a safe FTS5 query: every word must match, as a prefix.
    static func ftsQuery(_ input: String) -> String {
        input.split { $0.isWhitespace }
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"*" }
            .joined(separator: " ")
    }

    // ── sqlite helpers (call on `queue`) ────────────────────────────────────

    private func changed() {
        DispatchQueue.main.async { self.revision += 1 }
    }

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { logError(String(sql.prefix(40))) }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { logError("prepare"); return nil }
        return st
    }

    private func logError(_ what: String) {
        Log.error("History \(what): \(String(cString: sqlite3_errmsg(db)))")
    }

    private func bind(_ st: OpaquePointer, _ r: DictationRecord) {
        sqlite3_bind_double(st, 1, r.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(st, 2, r.duration)
        bindText(st, 3, r.appName)
        bindText(st, 4, r.appBundleID)
        bindText(st, 5, r.style.rawValue)
        bindText(st, 6, r.rawText)
        bindText(st, 7, r.text)
        sqlite3_bind_int64(st, 8, Int64(r.wordCount))
        bindText(st, 9, r.status.rawValue)
        bindText(st, 10, r.error)
        bindText(st, 11, r.audioFile)
        bindText(st, 12, r.engine)
    }

    private func bindText(_ st: OpaquePointer, _ i: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(st, i, s, -1, Self.transient) } else { sqlite3_bind_null(st, i) }
    }

    private func text(_ st: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(st, i) else { return nil }
        return String(cString: c)
    }

    /// Lightweight migrations for databases created by older versions.
    private func addColumnIfMissing(_ name: String, _ type: String) {
        var exists = false
        if let st = prepare("PRAGMA table_info(dictations)") {
            while sqlite3_step(st) == SQLITE_ROW { if text(st, 1) == name { exists = true } }
            sqlite3_finalize(st)
        }
        if !exists { exec("ALTER TABLE dictations ADD COLUMN \(name) \(type)") }
    }

    private func intQuery(_ sql: String) -> Int {
        guard let st = prepare(sql) else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }

    private func audioFile(id: Int64) -> String? {
        guard let st = prepare("SELECT audio_file FROM dictations WHERE id = \(id)") else { return nil }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? text(st, 0) : nil
    }

    private func select(_ sql: String, bind value: String? = nil) -> [DictationRecord] {
        guard let st = prepare(sql) else { return [] }
        defer { sqlite3_finalize(st) }
        if let value { bindText(st, 1, value) }
        var out: [DictationRecord] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(DictationRecord(
                id: sqlite3_column_int64(st, 0),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                duration: sqlite3_column_double(st, 2),
                appName: text(st, 3),
                appBundleID: text(st, 4),
                style: DictationStyle(rawValue: text(st, 5) ?? "") ?? .clean,
                rawText: text(st, 6) ?? "",
                text: text(st, 7) ?? "",
                status: DictationRecord.Status(rawValue: text(st, 8) ?? "") ?? .inserted,
                error: text(st, 9),
                audioFile: text(st, 10),
                engine: text(st, 11)))
        }
        return out
    }
}
