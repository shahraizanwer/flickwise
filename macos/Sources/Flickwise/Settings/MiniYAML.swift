// MiniYAML — reads the YAML subset Flickwise's Hammerspoon config.yaml uses (same as lib/tinyyaml.lua):
// nested maps by indentation, lists of maps ("- name: …"), flow lists ["a", b], block scalars "|",
// quoted/unquoted scalars and # comments. Values come back as String, [Any] or [String: Any].
// Used only to import an existing Hammerspoon setup.
import Foundation

enum MiniYAML {
    static func parse(_ text: String) -> [String: Any] {
        var lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\t", with: "  ") }
        lines.append("")
        var i = 0
        return parseMap(&lines, &i, indent: 0)
    }

    private static func indentOf(_ s: String) -> Int { s.prefix { $0 == " " }.count }
    private static func isBlank(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.hasPrefix("#")
    }

    private static func skipBlank(_ lines: inout [String], _ i: inout Int) {
        while i < lines.count, isBlank(lines[i]) { i += 1 }
    }

    private static func parseMap(_ lines: inout [String], _ i: inout Int, indent: Int) -> [String: Any] {
        var map: [String: Any] = [:]
        while true {
            skipBlank(&lines, &i)
            guard i < lines.count, indentOf(lines[i]) == indent else { break }
            let line = String(lines[i].dropFirst(indent))
            if line.hasPrefix("- ") { break }
            guard let colon = keyColon(line) else { i += 1; continue }
            let key = unquote(String(line[..<colon]).trimmingCharacters(in: .whitespaces))
            let rest = stripComment(String(line[line.index(after: colon)...])).trimmingCharacters(in: .whitespaces)
            i += 1
            map[key] = value(rest, &lines, &i, parentIndent: indent)
        }
        return map
    }

    private static func parseList(_ lines: inout [String], _ i: inout Int, indent: Int) -> [Any] {
        var list: [Any] = []
        while true {
            skipBlank(&lines, &i)
            guard i < lines.count, indentOf(lines[i]) == indent,
                  lines[i].dropFirst(indent).hasPrefix("- ") else { break }
            // Treat "- key: v" as a map whose keys sit at indent + 2.
            let item = String(lines[i].dropFirst(indent + 2))
            if keyColon(item) != nil {
                lines[i] = String(repeating: " ", count: indent + 2) + item
                list.append(parseMap(&lines, &i, indent: indent + 2))
            } else {
                i += 1
                list.append(scalar(stripComment(item).trimmingCharacters(in: .whitespaces)))
            }
        }
        return list
    }

    private static func value(_ rest: String, _ lines: inout [String], _ i: inout Int, parentIndent: Int) -> Any {
        if rest == "|" || rest == "|-" || rest == ">" {
            var block: [String] = []
            var blockIndent: Int?
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty { block.append(""); i += 1; continue }
                let ind = indentOf(l)
                if ind <= parentIndent { break }
                if blockIndent == nil { blockIndent = ind }
                block.append(String(l.dropFirst(min(ind, blockIndent!))))
                i += 1
            }
            while block.last == "" { block.removeLast() }
            return block.joined(separator: "\n") + (rest == "|" ? "\n" : "")
        }
        if !rest.isEmpty { return scalar(rest) }
        skipBlank(&lines, &i)
        guard i < lines.count, indentOf(lines[i]) > parentIndent else { return "" }
        let child = indentOf(lines[i])
        if lines[i].dropFirst(child).hasPrefix("- ") { return parseList(&lines, &i, indent: child) }
        return parseMap(&lines, &i, indent: child)
    }

    private static func scalar(_ s: String) -> Any {
        if s.hasPrefix("[") && s.hasSuffix("]") {
            let inner = s.dropFirst().dropLast()
            return splitFlow(String(inner)).map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
        }
        return unquote(s)
    }

    private static func splitFlow(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        for ch in s {
            if ch == "\"" || ch == "'" { quote = (quote == ch) ? nil : (quote ?? ch) }
            if ch == ",", quote == nil { out.append(cur); cur = "" } else { cur.append(ch) }
        }
        out.append(cur)
        return out
    }

    /// The ':' that ends a key (not one inside quotes).
    private static func keyColon(_ line: String) -> String.Index? {
        var quote: Character?
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == "\"" || ch == "'" { quote = (quote == ch) ? nil : (quote ?? ch) }
            if ch == ":", quote == nil {
                let next = line.index(after: idx)
                if next == line.endIndex || line[next] == " " { return idx }
            }
            if ch == "#", quote == nil { return nil }
            idx = line.index(after: idx)
        }
        return nil
    }

    private static func stripComment(_ s: String) -> String {
        var quote: Character?
        var prev: Character = " "
        for (i, ch) in s.enumerated() {
            if ch == "\"" || ch == "'" { quote = (quote == ch) ? nil : (quote ?? ch) }
            if ch == "#", quote == nil, prev == " " { return String(s.prefix(i)) }
            prev = ch
        }
        return s
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, let l = s.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") else { return s }
        return String(s.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
    }
}
