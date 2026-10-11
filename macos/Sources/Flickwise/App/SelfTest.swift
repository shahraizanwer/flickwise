// SelfTest — headless checks run from the terminal (no UI, no permissions needed).
// Run them against a sandbox folder so your real history and settings are untouched:
//   FLICKWISE_SUPPORT_DIR=$(mktemp -d) build/Flickwise.app/Contents/MacOS/Flickwise --selftest
import AppKit
import SwiftUI

enum SelfTest {
    static func run(_ args: [String]) -> Int32 {
        switch args[1] {
        case "--selftest": return selftest()
        case "--transcribe" where args.count > 2: return transcribe(args[2])
        case "--model-info": return modelInfo(args.count > 2 ? args[2] : WhisperModel.defaultID)
        case "--coreml-info": return coreMLInfo(args.count > 2 ? args[2] : WhisperModel.defaultID)
        case "--benchmark" where args.count > 2: return Benchmark.run(Array(args.dropFirst(2)))
        case "--render" where args.count > 3: return render(args[2], to: args[3])
        case "--load-test" where args.count > 2: return loadTest(args[2])
        case "--gate" where args.count > 2: return gate(Array(args.dropFirst(2)))
        case "--diff" where args.count > 2: return diffJSON(args[2])
        case "--import-preview": return importPreview()
        default:
            print("""
            usage: Flickwise --selftest
                   Flickwise --transcribe <file.wav>            (current settings)
                   Flickwise --benchmark [--models a,b] [--gemini] <file.wav>…
                   Flickwise --model-info [id]                  (prints: file url sha256 bytes path)
                   Flickwise --coreml-info [id]                 (same, for the Neural Engine encoder zip)
                   Flickwise --render main|history|progress|modes|dictation|features|ai|general|setup out.png
                   Flickwise --load-test <file.wav>             (on-demand cost: load → transcribe → unload, ×3)
            """)
            return 2
        }
    }

    // ── --render: a window's view to PNG, without showing it (works on any Space) ──

    private static func render(_ which: String, to path: String) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // With a sandbox data folder, FLICKWISE_RENDER_IMPORT=1 fills it with the Hammerspoon fix history.
        if ProcessInfo.processInfo.environment["FLICKWISE_RENDER_IMPORT"] == "1",
           ProcessInfo.processInfo.environment["FLICKWISE_SUPPORT_DIR"] != nil,
           HistoryStore.shared.recent(limit: 1).isEmpty {
            LegacyImport.importFixHistory()
        }
        let (view, size): (AnyView, NSSize) = {
            switch which {
            case "setup": return (AnyView(SetupView()), NSSize(width: 560, height: 680))
            case "history": return (AnyView(HistoryView()), NSSize(width: 760, height: 640))
            case "progress": return (AnyView(MyProgressView()), NSSize(width: 760, height: 760))
            case "modes": return (AnyView(ModesView()), NSSize(width: 900, height: 900))
            case "dictation": return (AnyView(DictationPane()), NSSize(width: 620, height: 1100))
            case "features": return (AnyView(FeaturesPane()), NSSize(width: 620, height: 1500))
            case "ai": return (AnyView(AIPane()), NSSize(width: 620, height: 520))
            case "general": return (AnyView(GeneralPane()), NSSize(width: 620, height: 760))
            default: return (AnyView(MainWindowView()), NSSize(width: 980, height: 680))
            }
        }()
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        // Let SwiftUI lay out (a few run-loop turns), then capture.
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return 1 }
        window.close()
        print("wrote \(path)")
        return 0
    }

    // ── --diff: word diff + mistake categories as JSON (compared against the Lua version) ──

    private static func diffJSON(_ path: String) -> Int32 {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let cases = try? JSONDecoder().decode([[String]].self, from: data) else { return 1 }
        let out: [[String: Any]] = cases.map { c in
            let (segs, changes) = WordDiff.diff(c[0], c[1])
            return ["segs": segs.map { ["op": $0.op.rawValue, "text": $0.text] }, "changes": changes,
                    "cats": Mistakes.extract(original: c[0], result: c[1]).map(\.cat)]
        }
        let json = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        print(String(data: json, encoding: .utf8)!)
        return 0
    }

    // ── --import-preview: what would be imported from the Hammerspoon config (read-only) ──

    private static func importPreview() -> Int32 {
        var s = AppSettings()
        LegacyImport.applyPreview(to: &s)
        print("backend: \(s.ai.backend.rawValue)  glean: \(s.ai.gleanPath.isEmpty ? "-" : s.ai.gleanPath)  model: \(s.ai.model)")
        print("picker: \(s.picker.hotkey.display)  sound: \(s.fixes.sound)  diff card: \(s.diffCard.enabled) \(s.diffCard.durationSeconds)s undo \(s.diffCard.undoHotkey.display) \(s.diffCard.undoMethod.rawValue)")
        print("radial: \(s.radialMenu.enabled) \(s.radialMenu.trigger.rawValue) \(s.radialMenu.holdMs)ms  direct replace: \(s.fixes.directReplace) web \(s.fixes.webContent.rawValue)")
        print("answer card: \(s.resultCard.enabled) \(s.resultCard.durationSeconds)s  reply card: \(s.replyCard.enabled) \(s.replyCard.durationSeconds)s  mistake modes: \(s.history.mistakeModes)")
        for m in LegacyImport.modes() ?? [] {
            print("mode: \(m.name) [\(m.hotkey?.display ?? "-")] \(m.output.rawValue) temp=\(m.temperature.map { String($0) } ?? "-") diff=\(m.showDiff) prompt=\(m.prompt.count) chars")
        }
        return 0
    }

    // ── --gate: what the speech check sees, at several mic levels ────────────

    private static func gate(_ files: [String]) -> Int32 {
        for f in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: f)) else { continue }
            let pcm = Speech.floats(fromWAV: Benchmark.normalized(data))
            for gain: Float in [1, 0.3, 0.1, 0.05] {
                let scaled = pcm.map { $0 * gain }
                let st = Speech.stats(scaled)
                let kept = Speech.trimmedToSpeech(scaled)
                print(String(format: "%@ ×%.2f  %.1f s  floor %.4f  peak %.4f  threshold %.4f  voiced %d/%d → %@",
                             (f as NSString).lastPathComponent, gain, Double(pcm.count) / 16_000, st.floor, st.peak,
                             st.threshold, st.voiced, st.frames, kept == nil ? "NO SPEECH" : String(format: "%.1f s", Double(kept!.count) / 16_000)))
            }
        }
        return 0
    }

    // ── --load-test: what "don't keep the model loaded" costs ──────────────────

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    private static func loadTest(_ path: String) -> Int32 {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return 1 }
        let s = SettingsStore.shared.settings
        let model = WhisperModel.find(s.transcription.model) ?? .default
        let pcm = Speech.trimmedToSpeech(Speech.floats(fromWAV: Benchmark.normalized(data))) ?? []
        print(String(format: "model %@, clip %.1f s, idle memory %.0f MB", model.id, Double(pcm.count) / 16_000, residentMB()))
        let done = DispatchSemaphore(value: 0)
        Task {
            let runs = Int(ProcessInfo.processInfo.environment["RUNS"] ?? "") ?? 3
            for i in 1...runs {
                let t0 = Date()
                WhisperEngine.shared.preload(model)
                while !WhisperEngine.shared.isReady(model) { try? await Task.sleep(nanoseconds: 5_000_000) }
                let load = Date().timeIntervalSince(t0)
                let loadedMB = residentMB()
                let t1 = Date()
                _ = try? await WhisperEngine.shared.transcribe(pcm: pcm, model: model, language: "auto", translate: false)
                let rec = Date().timeIntervalSince(t1)
                let peakMB = residentMB()
                WhisperEngine.shared.shutdown()
                try? await Task.sleep(nanoseconds: 300_000_000)
                print(String(format: "run %d: load %.2f s, recognize %.2f s → %.2f s total | memory loaded %.0f MB, after use %.0f MB, after unload %.0f MB",
                             i, load, rec, load + rec, loadedMB, peakMB, residentMB()))
            }
            done.signal()
        }
        done.wait()
        return 0
    }

    // ── --model-info (used by install.sh, so the catalog lives in one place) ──

    private static func modelInfo(_ id: String) -> Int32 {
        guard let m = WhisperModel.find(id) else { print("unknown model \(id)"); return 1 }
        print("\(m.fileName) \(m.url.absoluteString) \(m.sha256) \(m.bytes) \(m.path.path)")
        return 0
    }

    private static func coreMLInfo(_ id: String) -> Int32 {
        guard let m = WhisperModel.find(id), let a = m.coreML else { print("no Neural Engine encoder for \(id)"); return 1 }
        print("\(m.coreMLName) \(m.coreMLURL.absoluteString) \(a.sha256) \(a.bytes) \(m.coreMLPath.path)")
        return 0
    }

    // ── --transcribe ─────────────────────────────────────────────────────────

    private static func transcribe(_ path: String) -> Int32 {
        guard let wav = try? Data(contentsOf: URL(fileURLWithPath: path)) else { print("can't read \(path)"); return 1 }
        let s = SettingsStore.shared.settings
        let done = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task {
            do {
                let t0 = Date()
                let t = try await Transcriber.run(wav: Benchmark.normalized(wav), style: s.dictation.style, settings: s)
                print(String(format: "%@ · %@ · %.2f s", t.engine, s.dictation.style.rawValue, Date().timeIntervalSince(t0)))
                print("raw:  \(t.raw)")
                print("text: \(t.text)")
            } catch {
                print("error: \(error.localizedDescription)")
                status = 1
            }
            done.signal()
        }
        done.wait()
        return status
    }

    // ── --selftest ───────────────────────────────────────────────────────────

    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    private static func selftest() -> Int32 {
        guard ProcessInfo.processInfo.environment["FLICKWISE_SUPPORT_DIR"] != nil else {
            print("Set FLICKWISE_SUPPORT_DIR to a temporary folder first (keeps your real data untouched).")
            return 2
        }
        print("data folder: \(Paths.support.path)")

        // Text helpers
        check(GeminiClient.postprocess("  \"Hello there.\"  ") == "Hello there.", "postprocess strips quotes")
        check(GeminiClient.postprocess("Fixed text\n---\nI changed x") == "Fixed text", "postprocess drops --- commentary")
        check(HistoryStore.ftsQuery("meeting \"tomorrow") == "\"meeting\"* \"tomorrow\"*", "FTS query is quoted prefix terms")
        check(DictationRecord.words(in: "one  two\nthree") == 3, "word count")
        check(Speech.cleanFillers("um so I think, uh, we should go") == "So I think, we should go", "fillers removed")
        check(Speech.cleanFillers("Hmm. The umbrella is here.") == "The umbrella is here.", "fillers: words containing 'um' are kept")
        check(Speech.dropHallucination("Thank you.", speechSeconds: 0.8) == "", "hallucination dropped on short audio")
        check(Speech.dropHallucination("Thank you.", speechSeconds: 4) == "Thank you.", "real 'thank you' kept")
        check(Speech.dropHallucination("[BLANK_AUDIO]", speechSeconds: 3) == "", "blank audio marker dropped")
        let silence = [Float](repeating: 0.0005, count: 16_000)
        check(Speech.trimmedToSpeech(silence) == nil, "speech gate: silence has no speech")
        var tone = silence
        for i in 6_000..<14_000 { tone[i] = 0.2 * sin(Float(i) * 0.1) }
        if let trimmed = Speech.trimmedToSpeech(tone) {
            check(trimmed.count < tone.count && trimmed.count >= 8_000, "speech gate: trims silence, keeps speech")
        } else {
            check(false, "speech gate: detects speech")
        }
        var allSpeech = [Float](repeating: 0, count: 11_200)       // 0.7 s of speech-like audio, no pauses
        for i in allSpeech.indices { allSpeech[i] = (0.08 + 0.06 * sin(Float(i) / 900)) * sin(Float(i) * 0.12) }
        check(Speech.trimmedToSpeech(allSpeech) != nil, "speech gate: a short clip with no pauses is speech")
        var quiet = allSpeech.map { $0 * 0.08 }                    // a quiet mic (peak ≈ 0.01)
        check(Speech.trimmedToSpeech(quiet) != nil, "speech gate: quiet mic still counts")
        quiet = (0..<32_000).map { i in Float(i % 7) * 0.0004 - 0.0012 }   // room hiss ≈ 0.001
        quiet[16_000] = 0.3                                         // one click
        check(Speech.trimmedToSpeech(quiet) == nil, "speech gate: hiss and a click are not speech")
        check(Speech.floats(fromWAV: WAV.encode(pcm16Mono: Data([0x00, 0x40, 0x00, 0xC0]), sampleRate: 16_000)) == [0.5, -0.5],
              "WAV → floats")
        // Modes, shortcuts, YAML import, replies, progress
        check(KeyCombo(names: ["cmd", "shift", "g"])?.display == "⇧⌘G", "shortcut from names")
        check(KeyCombo(names: ["ctrl", "cmd", "m"])?.names == ["ctrl", "cmd", "m"], "shortcut names round-trip")
        check(KeyCombo(names: ["cmd", "nope"]) == nil, "unknown key is rejected")
        let modeJSON = try? JSONEncoder().encode(DefaultModes.all)
        let back = modeJSON.flatMap { try? JSONDecoder().decode([Mode].self, from: $0) }
        check(back == DefaultModes.all && DefaultModes.all.count == 7, "modes save and load (7 defaults)")
        check(DefaultModes.all.first { $0.name == "Reply Helper" }?.output == .replies
              && DefaultModes.all.first { $0.name == "Minimal Fix" }?.temperature == 0, "default modes keep output and temperature")
        let yaml = """
        glean_binary_path: "/opt/homebrew/bin/glean"   # comment
        picker_hotkey: ["cmd", "shift", "p"]
        features:
          diff_bubble:
            enabled: false            # off
            undo_hotkey: ["cmd", "z"]
          history:
            mistake_modes: ["Fix Grammar", "Minimal Fix"]
        modes:
          - name: "Fix Grammar"
            hotkey: ["cmd", "shift", "g"]
            system_prompt: |
              Line one: keep "quotes" # not a comment
              Line two.

          - name: 'Explain'
            output: "show"
            temperature: 0
            diff_bubble: false
            system_prompt: |
              Explain.
        """
        let y = MiniYAML.parse(yaml)
        let f = y["features"] as? [String: Any]
        check((y["glean_binary_path"] as? String) == "/opt/homebrew/bin/glean", "yaml: quoted scalar with a comment")
        check((y["picker_hotkey"] as? [String]) == ["cmd", "shift", "p"], "yaml: flow list")
        check(((f?["diff_bubble"] as? [String: Any])?["enabled"] as? String) == "false", "yaml: nested map")
        let ym = y["modes"] as? [[String: Any]]
        check(ym?.count == 2 && (ym?[1]["name"] as? String) == "Explain", "yaml: list of modes")
        check((ym?[0]["system_prompt"] as? String) == "Line one: keep \"quotes\" # not a comment\nLine two.\n", "yaml: block scalar kept verbatim")
        check((ym?[1]["output"] as? String) == "show" && (ym?[1]["diff_bubble"] as? String) == "false", "yaml: mode options")
        let reply = ReplyData.parse("Sure! ```json\n{\"meaning\": \"They ask {x}\", \"replies\": [{\"label\": \"Short\", \"text\": \"Yes.\"}, {\"text\": \"Sure, see you then.\"}]}\n```")
        check(reply?.meaning == "They ask {x}" && reply?.replies.count == 2 && reply?.replies[1].label == "Reply 2",
              "reply JSON found inside extra text")
        check(ReplyData.parse("not json") == nil, "reply JSON: plain text is rejected")
        var fixes: [DictationRecord] = []
        for (daysAgo, ms) in [(1, 2), (2, 1), (9, 3)] {
            var r = DictationRecord(createdAt: Date().addingTimeInterval(-Double(daysAgo) * 86_400), duration: 0, appName: nil,
                                    appBundleID: nil, style: .verbatim, rawText: "", text: "", status: .inserted)
            r.kind = .fix
            r.mistakes = (0..<ms).map { _ in Mistakes.Mistake(from: "has", to: "have", cat: "Verb form (is/are, has/have…)") }
            fixes.append(r)
        }
        let ps = ProgressStats.compute(fixes)
        check(ps.thisWeek.fixes == 2 && ps.thisWeek.mistakes == 3 && ps.lastWeek.mistakes == 3, "progress: weekly buckets")
        check(ps.top.first?.count == 6 && ps.categories.first?.week == 3, "progress: repeats and categories")
        check(Mistakes.classify("in", "on") == "Prepositions (in/on/at…)" && Mistakes.classify("teh", "the") == "Spelling",
              "mistake categories")
        check(CardView.rows("Meaning: hello\nmore\nRoman Urdu: salam").map(\.label) == ["Meaning", "Roman Urdu"],
              "answer card rows")

        check(WhisperModel.find("large-v3-turbo-q8_0")?.coreMLName == "ggml-large-v3-turbo-encoder.mlmodelc"
              && WhisperModel.find("small")?.coreMLName == "ggml-small-encoder.mlmodelc", "Core ML encoder names")
        check(WhisperModel.find(WhisperModel.defaultID) != nil && WhisperModel.catalog.allSatisfy { $0.sha256.count == 64 },
              "model catalog")

        // WAV
        let pcm = Data(count: 32_000)        // 1 s of silence
        let wav = WAV.encode(pcm16Mono: pcm, sampleRate: 16_000)
        check(wav.count == 32_044 && wav.prefix(4) == Data("RIFF".utf8), "WAV header")
        check(abs(WAV.duration(of: wav) - 1.0) < 0.001, "WAV duration")

        // Settings: defaults for missing keys, unknown values tolerated
        let partial = #"{"dictation": {"trigger": "right_option", "hold_ms": 300}, "history": {"retention_days": -5}}"#
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        if let s = try? d.decode(AppSettings.self, from: Data(partial.utf8)) {
            check(s.dictation.trigger == .rightOption && s.dictation.holdMs == 300, "settings: given keys are read")
            check(s.dictation.style == .clean && s.ai.model == "gemini-flash-lite-latest", "settings: missing keys default")
            check(s.dictation.indicator == .notch, "settings: the notch indicator is the default")
            check(s.transcription.engine == .local && s.transcription.model == WhisperModel.defaultID,
                  "settings: on-device Whisper is the default")
            check(s.history.retentionDays == 0, "settings: bad values are clamped")
        } else {
            check(false, "settings decode")
        }

        // History store
        let h = HistoryStore.shared
        h.deleteAll()
        let now = Date()
        let a = h.add(DictationRecord(createdAt: now, duration: 4, appName: "Notes", appBundleID: "com.apple.Notes",
                                      style: .clean, rawText: "um so the meeting is tomorrow",
                                      text: "The meeting is tomorrow.", status: .inserted, engine: "whisper:base"))
        let b = h.add(DictationRecord(createdAt: now.addingTimeInterval(-86_400), duration: 6, appName: "Slack",
                                      appBundleID: nil, style: .english, rawText: "kal call karte hain",
                                      text: "Let's have a call tomorrow.", status: .pasted))
        _ = h.add(DictationRecord(createdAt: now.addingTimeInterval(-3 * 86_400), duration: 9, appName: nil, appBundleID: nil,
                                  style: .clean, rawText: "", text: "", status: .failed, error: "No internet connection",
                                  audioFile: nil))
        check(a > 0 && b > 0, "history: insert")
        check(h.recent().count == 3, "history: recent lists all")
        check(h.recent().first?.id == a, "history: newest first")
        check(h.recent().first?.engine == "whisper:base", "history: engine is stored")
        check(h.search("meet").map(\.id) == [a], "history: prefix search")
        check(h.search("tomorrow").count == 2, "history: search matches polished text")
        check(h.search("karte").map(\.id) == [b], "history: search matches the raw transcript")
        check(h.search("slack").map(\.id) == [b], "history: search matches the app name")
        let st = h.stats()
        check(st.todayWords == 4 && st.totalWords == 9 && st.totalCount == 2, "history: stats skip failed entries")
        check(st.streakDays == 2, "history: streak counts today and yesterday")
        var edited = h.record(id: b)!
        edited.text = "Let's talk on a call tomorrow."
        h.update(edited)
        check(h.search("talk").map(\.id) == [b], "history: search index follows updates")
        h.delete(id: a)
        check(h.search("meeting").isEmpty && h.recent().count == 2, "history: delete removes from search")
        h.prune(olderThanDays: 2)
        check(h.recent().count == 1, "history: prune drops old entries")
        h.deleteAll()
        check(h.recent().isEmpty, "history: delete all")

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
