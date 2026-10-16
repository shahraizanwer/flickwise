// FixController — runs a mode on the selected text. Port of lib/text_replacer.lua.
//   run(mode)                 capture the selection (Accessibility first, else ⌘C), then process it
//   run(mode, with: ctx)      the picker/radial menu already captured it
//   insert(_:)                type text at the caret (Reply Helper)
// Flow: HUD working → backend (Gemini / Glean) → by the mode's output:
//   replace → write it back (direct + verified, or paste and restore the clipboard) → sound, HUD,
//             history (+ mistakes), "what changed" card with Undo
//   show    → answer card (or clipboard when the card is off); the text is never changed
//   replies → reply card from the JSON {meaning, replies:[{label,text}]}
// One run at a time.
import AppKit

@MainActor
final class FixController {
    static let shared = FixController()

    private(set) var inFlight = false
    private var settings: AppSettings { SettingsStore.shared.settings }

    func run(_ mode: Mode) {
        guard begin() else { return }
        Task {
            let ctx = await capture()
            guard let ctx else {
                HUD.shared.error("Select some text first")
                inFlight = false
                return
            }
            await process(ctx, mode: mode)
        }
    }

    func run(_ mode: Mode, with ctx: SelectionContext) {
        guard begin() else { return }
        Task { await process(ctx, mode: mode) }
    }

    /// Selection for the picker / radial menu: Accessibility first, else ⌘C.
    func capture() async -> SelectionContext? {
        let (direct, why) = Selection.readDirect(settings.fixes)
        if let direct {
            Log.info("Captured via Accessibility (\(direct.app ?? "?"), \(direct.web ? "web" : "native"), writable=\(direct.writable))")
            return direct
        }
        Log.debug("Direct capture unavailable: \(why) — using the clipboard")
        return await Selection.captureByCopy()
    }

    private func begin() -> Bool {
        if inFlight { HUD.shared.info("Still working on the last one…"); return false }
        inFlight = true
        ResultCard.shared.dismiss()
        return true
    }

    // ── processing ───────────────────────────────────────────────────────────

    private func process(_ captured: SelectionContext, mode: Mode) async {
        defer { inFlight = false }
        var ctx = captured
        let started = Date()
        let app = ctx.app ?? NSWorkspace.shared.frontmostApplication?.localizedName
        let targetApp = NSWorkspace.shared.frontmostApplication
        HUD.shared.working(mode.name)
        Log.info("Running '\(mode.name)' (\(settings.ai.backend.rawValue))")
        Log.debug("Selected: \(ctx.text.prefix(100))")

        let result: String
        do {
            result = try await TextBackend.transform(ctx.text, mode: mode, settings: settings)
        } catch {
            if let saved = ctx.savedClipboard { TextInserter.restoreClipboard(saved) }
            HUD.shared.error(error.localizedDescription)
            Log.error("'\(mode.name)' failed: \(error.localizedDescription)")
            return
        }
        let elapsed = String(format: "%.1f s", Date().timeIntervalSince(started))

        switch mode.output {
        case .replies:
            if let saved = ctx.savedClipboard { TextInserter.restoreClipboard(saved) }
            HUD.shared.done("Done", detail: elapsed)
            let parsed = ReplyData.parse(result)
            let summary = parsed?.summary ?? result
            if let parsed, settings.replyCard.enabled {
                ResultCard.shared.showReplies(parsed, mode: mode.name, target: targetApp)
            } else if settings.resultCard.enabled {
                ResultCard.shared.showText(summary, mode: mode.name)
            } else {
                TextInserter.copyToClipboard(summary)
                HUD.shared.info("Replies copied to clipboard", detail: mode.name)
            }
            record(kind: .answer, mode: mode, app: app, original: ctx.text, result: summary)

        case .show:
            if let saved = ctx.savedClipboard { TextInserter.restoreClipboard(saved) }
            HUD.shared.done("Done", detail: elapsed)
            if settings.resultCard.enabled {
                ResultCard.shared.showText(result, mode: mode.name)
            } else {
                TextInserter.copyToClipboard(result)
                HUD.shared.info("Answer copied to clipboard", detail: mode.name)
            }
            record(kind: .answer, mode: mode, app: app, original: ctx.text, result: result)

        case .replace:
            if result == ctx.text {
                if let saved = ctx.savedClipboard { TextInserter.restoreClipboard(saved) }
                HUD.shared.done("No changes needed", detail: elapsed)
                return
            }
            var direct = false
            let (can, why) = Selection.canWrite(ctx, settings.fixes)
            var reason = why
            if can { (direct, reason) = Selection.replace(&ctx, with: result) }
            if direct {
                Log.info("Replaced via Accessibility (clipboard untouched)")
            } else if reason == "selection changed while working" {
                TextInserter.copyToClipboard(result)
                HUD.shared.error("Text changed while working — result copied to clipboard")
                return
            } else {
                Log.debug("Paste fallback: \(reason)")
                TextInserter.paste(result, restoring: ctx.savedClipboard)
            }
            if !settings.fixes.sound.isEmpty { Sounds.play(settings.fixes.sound, volume: 0.6) }
            HUD.shared.done("Done", detail: elapsed)
            let id = record(kind: .fix, mode: mode, app: app, original: captured.text, result: result)
            if mode.showDiff && settings.diffCard.enabled {
                ResultCard.shared.showDiff(original: captured.text, result: result, mode: mode.name,
                                           target: targetApp, undo: { [ctx] in
                    self.undo(ctx: direct ? ctx : nil, original: captured.text, result: result, historyID: id)
                })
            }
        }
        Log.info("'\(mode.name)' done in \(elapsed)")
    }

    @discardableResult
    private func record(kind: DictationRecord.Kind, mode: Mode, app: String?, original: String, result: String) -> Int64? {
        let h = settings.history
        guard h.enabled, !original.isEmpty else { return nil }
        if let app, h.excludeApps.contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) { return nil }
        var r = DictationRecord(createdAt: Date(), duration: 0, appName: app, appBundleID: nil, style: .verbatim,
                                rawText: original, text: result, status: .inserted)
        r.kind = kind
        r.mode = mode.name
        if kind == .fix, h.mistakeModes.contains(where: { $0.caseInsensitiveCompare(mode.name) == .orderedSame }) {
            r.mistakes = Mistakes.extract(original: original, result: result)
        }
        return HistoryStore.shared.add(r)
    }

    // ── undo ─────────────────────────────────────────────────────────────────

    /// ctx is set when the fix was written through Accessibility (then undo restores it directly).
    private func undo(ctx: SelectionContext?, original: String, result: String, historyID: Int64?) {
        defer { if let historyID { HistoryStore.shared.markUndone(id: historyID) } }
        if let ctx {
            let (ok, why) = Selection.restore(ctx)
            if ok { HUD.shared.info("Undone"); return }
            TextInserter.copyToClipboard(original)
            HUD.shared.error("Couldn't undo (\(why)) — the original is on the clipboard")
            return
        }
        switch settings.diffCard.undoMethod {
        case .app:
            TextInserter.sendKey(6, flags: .maskCommand)          // ⌘Z
            HUD.shared.info("Undone")
        case .reselect:
            let n = result.count
            guard n <= 2000 else { TextInserter.sendKey(6, flags: .maskCommand); return }
            for _ in 0..<n { TextInserter.sendKey(123, flags: .maskShift) }    // shift+← per character
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                TextInserter.paste(original)
                HUD.shared.info("Undone")
            }
        }
    }

    // ── Reply Helper ─────────────────────────────────────────────────────────

    /// Types `text` at the caret of `target` (refocusing it first).
    func insert(_ text: String, into target: NSRunningApplication?) {
        if let target, target != NSWorkspace.shared.frontmostApplication { target.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            _ = TextInserter.insert(text, alwaysPasteIn: self.settings.fixes.excludeApps)
            HUD.shared.done("Inserted", detail: String(text.prefix(60)))
        }
    }
}

/// The Reply Helper's JSON: {"meaning": "...", "replies": [{"label": "...", "text": "..."}]}.
struct ReplyData: Equatable {
    struct Reply: Equatable, Identifiable { let id: Int; let label: String; let text: String }
    let meaning: String
    let replies: [Reply]

    /// Finds the first balanced {...} (models sometimes add fences or text around it).
    static func parse(_ raw: String) -> ReplyData? {
        guard let start = raw.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var end: String.Index?
        for i in raw[start...].indices {
            let ch = raw[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true }
            else if ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1; if depth == 0 { end = i; break } }
        }
        guard let end, let data = String(raw[start...end]).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let list = (obj["replies"] as? [[String: Any]] ?? []).enumerated().compactMap { i, r -> Reply? in
            guard let text = r["text"] as? String, !text.isEmpty else { return nil }
            let label = (r["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Reply \(i + 1)"
            return Reply(id: i, label: label, text: text)
        }
        guard !list.isEmpty else { return nil }
        return ReplyData(meaning: obj["meaning"] as? String ?? "", replies: Array(list.prefix(9)))
    }

    var summary: String {
        (["Meaning: " + meaning] + replies.map { "\($0.label): \($0.text)" }).joined(separator: "\n")
    }
}
