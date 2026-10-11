// ProgressStats — My Progress numbers from tracked fixes (modes listed in history.mistake_modes).
// Port of stats() in lib/history.lua: this week vs last week, mistakes per category, the most
// repeated corrections (excluding Rewording), and an 8-week series. Undone fixes don't count.
import Foundation

struct ProgressStats: Equatable {
    struct Week: Equatable, Identifiable { var id: Int; var label: String; var fixes = 0; var mistakes = 0 }
    struct Category: Equatable, Identifiable { var id: String { name }; var name: String; var week = 0; var total = 0 }
    struct Repeat: Equatable, Identifiable { var id: String { from + "→" + to }; var from: String; var to: String; var cat: String; var count = 0 }

    var thisWeek = (fixes: 0, mistakes: 0)
    var lastWeek = (fixes: 0, mistakes: 0)
    var categories: [Category] = []
    var top: [Repeat] = []
    var weeks: [Week] = []

    static func == (a: ProgressStats, b: ProgressStats) -> Bool {
        a.thisWeek == b.thisWeek && a.lastWeek == b.lastWeek && a.categories == b.categories && a.top == b.top && a.weeks == b.weeks
    }

    static func compute(_ records: [DictationRecord], now: Date = Date()) -> ProgressStats {
        let day = 86_400.0, week = 7 * day
        var s = ProgressStats()
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        s.weeks = (0...7).reversed().map { w in
            Week(id: w, label: f.string(from: now.addingTimeInterval(-Double(w + 1) * week + day)))
        }
        var cats: [String: Category] = [:]
        var pairs: [String: Repeat] = [:]
        for r in records where !r.undone {
            guard let mistakes = r.mistakes else { continue }
            let age = now.timeIntervalSince(r.createdAt)
            let n = mistakes.count
            if age < week { s.thisWeek.fixes += 1; s.thisWeek.mistakes += n }
            else if age < 2 * week { s.lastWeek.fixes += 1; s.lastWeek.mistakes += n }
            let wk = Int(age / week)
            if wk <= 7 { s.weeks[7 - wk].fixes += 1; s.weeks[7 - wk].mistakes += n }
            for m in mistakes {
                var c = cats[m.cat] ?? Category(name: m.cat)
                c.total += 1
                if age < week { c.week += 1 }
                cats[m.cat] = c
                if m.cat != "Rewording" {
                    let key = m.from.lowercased() + "\u{0}" + m.to.lowercased()
                    var p = pairs[key] ?? Repeat(from: m.from, to: m.to, cat: m.cat)
                    p.count += 1
                    pairs[key] = p
                }
            }
        }
        s.categories = cats.values.sorted { $0.total > $1.total }
        s.top = Array(pairs.values.sorted { $0.count > $1.count }.prefix(12))
        return s
    }
}
