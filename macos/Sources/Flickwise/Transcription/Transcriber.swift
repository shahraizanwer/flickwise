// Transcriber — turns a recording into the text to type, with the configured engine:
//   local  → WhisperEngine (offline). Style "english" uses Whisper's translate task when the
//            model supports it; "clean" removes fillers with simple rules (no AI needed).
//   gemini → Gemini transcription (cloud).
// Either way, "clean"/"english" can additionally be polished by Gemini when
// `transcription.polish_with_gemini` is on and a key is saved.
// The audio is checked for speech first (and trimmed for Whisper): both Whisper and Gemini
// invent text ("Thank you.", "Acha to main chalte hun.") when fed silence.
import Foundation

struct Transcript {
    var raw: String          // what the recognizer heard
    var text: String         // what gets typed
    var engine: String       // e.g. "whisper:large-v3-turbo-q5_0" or "gemini:gemini-flash-lite-latest"
}

enum Transcriber {
    static func run(wav: Data, style: DictationStyle, settings: AppSettings,
                    status: @escaping (String) -> Void = { _ in }) async throws -> Transcript {
        let t = settings.transcription
        let started = Date()
        var result: Transcript

        switch t.engine {
        case .local:
            let model = WhisperModel.find(t.model) ?? .default
            var pcm = Speech.floats(fromWAV: wav)
            guard let trimmed = Speech.trimmedToSpeech(pcm) else {
                return Transcript(raw: "", text: "", engine: "whisper:\(model.id)")
            }
            pcm = trimmed
            let translate = style == .english && model.translates
            if !WhisperEngine.shared.isReady(model) {
                await MainActor.run { status("Loading speech model…") }
            }
            var raw = try await WhisperEngine.shared.transcribe(pcm: pcm, model: model, language: t.language,
                                                                translate: translate)
            raw = Speech.dropHallucination(raw, speechSeconds: Double(pcm.count) / AudioRecorder.sampleRate)
            let text = style == .verbatim ? raw : Speech.cleanFillers(raw)
            result = Transcript(raw: raw, text: text, engine: "whisper:\(model.id)")

        case .gemini:
            // Same speech gate: on silence, Gemini invents sentences too (seen in the benchmark).
            guard Speech.trimmedToSpeech(Speech.floats(fromWAV: wav)) != nil else {
                return Transcript(raw: "", text: "", engine: "gemini:\(settings.ai.model)")
            }
            let client = GeminiClient(apiKey: Secrets.apiKey, model: settings.ai.model,
                                      timeout: TimeInterval(settings.ai.timeoutSeconds))
            var raw = try await client.transcribe(wav: wav, prompt: Prompts.transcribe)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.contains("[NO_SPEECH]") { raw = "" }
            result = Transcript(raw: raw, text: raw, engine: "gemini:\(settings.ai.model)")
        }
        Log.info(String(format: "Transcribed with %@ in %.2f s (%d chars)", result.engine,
                        Date().timeIntervalSince(started), result.raw.count))
        guard !result.raw.isEmpty else { return result }

        // Optional AI polish (always used for the Gemini engine, opt-in for local).
        let wantsGemini = t.engine == .gemini || (t.polishWithGemini && Secrets.hasAPIKey)
        if wantsGemini, let instructions = Prompts.polish(style) {
            await MainActor.run { status("Polishing…") }
            let client = GeminiClient(apiKey: Secrets.apiKey, model: settings.ai.model,
                                      timeout: TimeInterval(settings.ai.timeoutSeconds))
            do {
                result.text = try await client.rewrite(text: result.raw, instructions: instructions)
                Log.info(String(format: "Polished in %.2f s total", Date().timeIntervalSince(started)))
            } catch {
                Log.info("Polish failed (\(error.localizedDescription)) — using the transcript as is")
            }
        }
        return result
    }
}

/// Audio and text helpers for local recognition (pure functions, covered by --selftest).
enum Speech {
    /// 16-bit WAV (as made by WAV.encode) → floats in -1…1.
    static func floats(fromWAV wav: Data) -> [Float] {
        guard wav.count > 44 else { return [] }
        return wav.withUnsafeBytes { raw -> [Float] in
            let samples = raw.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            let n = (wav.count - 44) / 2
            return (0..<n).map { Float(Int16(littleEndian: samples[$0])) / 32768 }
        }
    }

    // Speech gate. Two mistakes to avoid:
    //  • calling all-speech audio silent: a short clip ("Hello there.") has no pauses, so a noise
    //    floor taken from its quietest frames is really speech. The threshold is therefore capped
    //    at 30% of the loudest frame, so speech always clears it.
    //  • calling near-silence speech: an absolute minimum (≈ -46 dBFS) and at least 6 voiced
    //    frames (180 ms) keep room noise and single clicks out.
    // It leans toward speech: losing words is worse than an occasional check that Whisper
    // answers with nothing (its "Thank you." on silence is filtered later anyway).
    static let minLevel: Float = 0.005
    static let minVoicedFrames = 6

    struct GateStats { var floor: Float = 0, peak: Float = 0, threshold: Float = 0, voiced = 0, frames = 0 }

    static func stats(_ pcm: [Float], sampleRate: Int = 16_000) -> GateStats {
        let rms = frameRMS(pcm, sampleRate: sampleRate)
        guard let peak = rms.max() else { return GateStats() }
        let floor = rms.sorted()[rms.count / 10]            // 10th percentile ≈ background noise
        let threshold = max(minLevel, min(floor * 3, peak * 0.3))
        return GateStats(floor: floor, peak: peak, threshold: threshold,
                         voiced: rms.filter { $0 > threshold }.count, frames: rms.count)
    }

    private static func frameRMS(_ pcm: [Float], sampleRate: Int) -> [Float] {
        let frame = sampleRate / 100 * 3                    // 30 ms
        guard pcm.count >= frame else { return [] }
        return stride(from: 0, to: pcm.count - frame + 1, by: frame).map { start in
            var sum: Float = 0
            for i in start..<start + frame { sum += pcm[i] * pcm[i] }
            return (sum / Float(frame)).squareRoot()
        }
    }

    /// Cuts leading/trailing silence (keeping 300 ms of padding). nil = no speech at all.
    static func trimmedToSpeech(_ pcm: [Float], sampleRate: Int = 16_000) -> [Float]? {
        let frame = sampleRate / 100 * 3
        let rms = frameRMS(pcm, sampleRate: sampleRate)
        let st = stats(pcm, sampleRate: sampleRate)
        let voiced = rms.indices.filter { rms[$0] > st.threshold }
        guard voiced.count >= minVoicedFrames, let first = voiced.first, let last = voiced.last else {
            Log.info(String(format: "Speech check: no speech (floor %.4f, peak %.4f, threshold %.4f, voiced %d/%d)",
                            st.floor, st.peak, st.threshold, st.voiced, st.frames))
            return nil
        }
        let pad = 10
        let start = max(0, first - pad) * frame
        let end = min(pcm.count, (last + 1 + pad) * frame)
        return Array(pcm[start..<end])
    }

    /// Whisper's classic inventions on near-silent audio.
    private static let hallucinations: Set<String> = [
        "thank you", "thanks for watching", "thank you for watching", "thank you very much", "you", "bye",
        "please subscribe", "subtitles by the amaraorg community", "blank_audio", "silence", "music",
    ]

    static func dropHallucination(_ text: String, speechSeconds: Double) -> String {
        var t = text.replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
        t = t.replacingOccurrences(of: #"^\s*[\(\[][^\)\]]*[\)\]]\s*$"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = t.lowercased().filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
        if hallucinations.contains(key) && speechSeconds < 2.5 { return "" }
        return t
    }

    /// Offline "Clean up": drop filler words and tidy spacing/capitalization.
    static func cleanFillers(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"(?i)(^|[\s,.!?])(?:um+|uh+|erm+|uhm+|hmm+|mm+|ah+|er)(?=[\s,.!?]|$)[,.]?"#,
                                   with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([,.!?])\1+"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^[\s,.]+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = t.first, first.isLowercase { t = first.uppercased() + t.dropFirst() }
        return t
    }
}
