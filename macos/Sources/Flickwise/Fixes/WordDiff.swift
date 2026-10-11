// WordDiff — word-level diff (LCS), no AI call. Port of lib/word_diff.lua.
//   tokenize(_:)  words (letters/digits/any non-ASCII, with inner ' and -), single punctuation, whitespace runs
//   diff(_:_:)    segments [.eq/.del/.ins] where each edit group is one del followed by one ins
import Foundation

enum WordDiff {
    enum Op: String, Codable { case eq, del, ins }

    struct Segment: Equatable, Codable {
        var op: Op
        var text: String
    }

    /// Above this many DP cells the middle is shown as one replacement (keeps huge rewrites fast).
    static let maxCells = 250_000

    private static func isSpace(_ c: Character) -> Bool { c.isWhitespace }
    private static func isWord(_ c: Character) -> Bool { !(c.isWhitespace || (c.isASCII && c.isPunctuation) || (c.isASCII && c.isSymbol)) }

    static func tokenize(_ s: String) -> [String] {
        let chars = Array(s)
        var tokens: [String] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            var j = i
            if isSpace(c) {
                while j + 1 < chars.count, isSpace(chars[j + 1]) { j += 1 }
            } else if isWord(c) {
                while j + 1 < chars.count {
                    let nx = chars[j + 1]
                    if isWord(nx) { j += 1 }
                    else if (nx == "'" || nx == "-"), j + 2 < chars.count, isWord(chars[j + 2]) { j += 2 }
                    else { break }
                }
            }
            tokens.append(String(chars[i...j]))
            i = j + 1
        }
        return tokens
    }

    static func diff(_ aText: String, _ bText: String) -> (segments: [Segment], changes: Int) {
        let a = tokenize(aText), b = tokenize(bText)
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }

        var ops: [(Op, String)] = a[0..<pre].map { (.eq, $0) }
        lcs(Array(a[pre..<(a.count - suf)]), Array(b[pre..<(b.count - suf)]), into: &ops)
        ops += a[(a.count - suf)...].map { (.eq, $0) }
        return group(ops)
    }

    private static func lcs(_ a: [String], _ b: [String], into ops: inout [(Op, String)]) {
        let n = a.count, m = b.count
        if n == 0 { ops += b.map { (.ins, $0) }; return }
        if m == 0 { ops += a.map { (.del, $0) }; return }
        if n * m > maxCells { ops += a.map { (.del, $0) }; ops += b.map { (.ins, $0) }; return }
        // dp[i][j] = LCS of a[i...] and b[j...]
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { ops.append((.eq, a[i])); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { ops.append((.del, a[i])); i += 1 }
            else { ops.append((.ins, b[j])); j += 1 }
        }
        while i < n { ops.append((.del, a[i])); i += 1 }
        while j < m { ops.append((.ins, b[j])); j += 1 }
    }

    /// Whitespace between two edits joins the edit; each edit group becomes one del + one ins.
    private static func group(_ ops: [(Op, String)]) -> ([Segment], Int) {
        var segs: [Segment] = []
        var groups = 0
        func push(_ op: Op, _ text: String) {
            guard !text.isEmpty else { return }
            if let last = segs.last, last.op == op { segs[segs.count - 1].text += text }
            else { segs.append(Segment(op: op, text: text)) }
        }
        var k = 0
        while k < ops.count {
            if ops[k].0 == .eq { push(.eq, ops[k].1); k += 1; continue }
            var del = "", ins = ""
            while k < ops.count {
                let (op, text) = ops[k]
                if op == .del { del += text; k += 1 }
                else if op == .ins { ins += text; k += 1 }
                else if text.allSatisfy(\.isWhitespace), k + 1 < ops.count, ops[k + 1].0 != .eq {
                    del += text; ins += text; k += 1
                } else { break }
            }
            groups += 1
            push(.del, del)
            push(.ins, ins)
        }
        return (segs, groups)
    }

    /// Shortens long unchanged stretches to `context` words around each change, with "…" for the rest:
    /// the first segment keeps its last words, the last keeps its first words, middle ones keep both ends.
    static func collapsed(_ segs: [Segment], context: Int) -> [Segment] {
        segs.enumerated().map { idx, s in
            guard s.op == .eq else { return s }
            let toks = tokenize(s.text)
            let wordIdx = toks.indices.filter { !toks[$0].allSatisfy(\.isWhitespace) }
            let first = idx == 0, last = idx == segs.count - 1
            if first && last { return s }                                  // nothing changed
            let limit = (first || last) ? context : context * 2
            guard wordIdx.count > limit + 2 else { return s }
            func joined(_ r: Range<Int>) -> String { toks[r].joined() }
            if first {                                                      // "… last words"
                return Segment(op: .eq, text: "… " + joined(wordIdx[wordIdx.count - context]..<toks.count))
            }
            if last {                                                       // "first words …"
                return Segment(op: .eq, text: joined(0..<(wordIdx[context - 1] + 1)) + " …")
            }
            return Segment(op: .eq, text: joined(0..<(wordIdx[context - 1] + 1)) + " … "
                           + joined(wordIdx[wordIdx.count - context]..<toks.count))
        }
    }
}

/// Mistake tracker for My Progress. Port of the classification in lib/history.lua.
enum Mistakes {
    struct Mistake: Codable, Equatable, Hashable {
        var from: String
        var to: String
        var cat: String
    }

    private static let articles: Set<String> = ["a", "an", "the"]
    private static let aux: Set<String> = ["is", "are", "was", "were", "am", "be", "been", "has", "have", "had",
                                           "do", "does", "did", "will", "would", "can", "could"]
    private static let preps: Set<String> = ["in", "on", "at", "to", "for", "of", "with", "by", "from", "about",
                                             "into", "onto", "over"]

    static func extract(original: String, result: String) -> [Mistake] {
        let segs = WordDiff.diff(original, result).segments
        var out: [Mistake] = []
        var i = 0
        while i < segs.count {
            let s = segs[i]
            if s.op == .eq { i += 1; continue }
            var from = "", to = ""
            if s.op == .del {
                from = s.text
                if i + 1 < segs.count, segs[i + 1].op == .ins { to = segs[i + 1].text; i += 1 }
            } else {
                to = s.text
            }
            i += 1
            from = from.trimmingCharacters(in: .whitespacesAndNewlines)
            to = to.trimmingCharacters(in: .whitespacesAndNewlines)
            if !from.isEmpty || !to.isEmpty { out.append(Mistake(from: from, to: to, cat: classify(from, to))) }
        }
        return out
    }

    private static func stripPunct(_ s: String) -> String { s.filter { !($0.isPunctuation || $0.isSymbol) } }
    private static func words(_ s: String) -> [String] { s.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > 3 { return 99 }
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Exactly one extra (or missing) word, and it's in `set`?
    private static func differsBy(_ set: Set<String>, _ fw: [String], _ tw: [String]) -> Bool {
        let (long, short) = tw.count > fw.count ? (tw, fw) : (fw, tw)
        guard long.count == short.count + 1 else { return false }
        var seen: [String: Int] = [:]
        for w in short { seen[w, default: 0] += 1 }
        var extra: String?
        for w in long {
            if let n = seen[w], n > 0 { seen[w] = n - 1 }
            else if extra != nil { return false }
            else { extra = w }
        }
        return extra.map(set.contains) ?? false
    }

    static func classify(_ from: String, _ to: String) -> String {
        let f = from.lowercased(), t = to.lowercased()
        if f == t { return "Capitalization" }
        if (from.contains("'") || to.contains("'")) && stripPunct(f) == stripPunct(t) { return "Apostrophes" }
        if stripPunct(f) == stripPunct(t) { return "Punctuation" }
        let fw = words(stripPunct(f)), tw = words(stripPunct(t))
        if differsBy(articles, fw, tw) { return "Articles (a / an / the)" }
        if fw.count == 1, tw.count == 1 {
            let a = fw[0], b = tw[0]
            if b == a + "s" || b == a + "es" || a == b + "s" || a == b + "es" { return "Singular / plural" }
            if aux.contains(a), aux.contains(b) { return "Verb form (is/are, has/have…)" }
            if preps.contains(a), preps.contains(b) { return "Prepositions (in/on/at…)" }
            if editDistance(a, b) <= 2 { return "Spelling" }
        }
        if differsBy(aux, fw, tw) { return "Verb form (is/are, has/have…)" }
        if differsBy(preps, fw, tw) { return "Prepositions (in/on/at…)" }
        if fw.count > 6 || tw.count > 6 { return "Rewording" }
        return "Word choice"
    }
}
