// Benchmark — compares recognizers on the same recordings (run from the terminal):
//   Flickwise --benchmark [--models large-v3-turbo-q5_0,small] [--gemini] [--language ur] a.wav b.wav …
// For each downloaded model: load time, then per file the time to text (warm) and the text.
// --gemini adds Gemini transcription (needs the key) for comparison.
import AVFoundation
import Foundation

enum Benchmark {
    static func run(_ args: [String]) -> Int32 {
        var models = WhisperModel.catalog.filter { ModelStore.shared.isInstalled($0) }
        var files: [String] = []
        var gemini = false
        var language = "auto"
        var translate = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--models":
                i += 1
                let ids = args[i].split(separator: ",").map(String.init)
                models = ids.compactMap(WhisperModel.find)
            case "--gemini": gemini = true
            case "--translate": translate = true
            case "--language": i += 1; language = args[i]
            default: files.append(args[i])
            }
            i += 1
        }
        let clips: [(String, Data)] = files.compactMap { path in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { print("skip \(path): unreadable"); return nil }
            return ((path as NSString).lastPathComponent, normalized(data))
        }
        guard !clips.isEmpty else { print("no audio files"); return 1 }
        for (name, wav) in clips { print(String(format: "• %@: %.1f s of audio", name, WAV.duration(of: wav))) }

        let done = DispatchSemaphore(value: 0)
        Task {
            for m in models {
                guard ModelStore.shared.isInstalled(m) else { print("\n\(m.id): not downloaded"); continue }
                print("\n── whisper \(m.id) (\(m.sizeText))")
                WhisperEngine.shared.unload(ifModel: m.id)
                let t0 = Date()
                // First run includes the load; report it separately using a tiny clip.
                _ = try? await WhisperEngine.shared.transcribe(pcm: [Float](repeating: 0, count: 16_000), model: m,
                                                               language: language, translate: false)
                print(String(format: "   load + warm-up: %.2f s", Date().timeIntervalSince(t0)))
                for (name, wav) in clips {
                    guard let pcm = Speech.trimmedToSpeech(Speech.floats(fromWAV: wav)) else {
                        print("   \(name)  (no speech detected — nothing typed)")
                        continue
                    }
                    let t1 = Date()
                    do {
                        let text = try await WhisperEngine.shared.transcribe(pcm: pcm, model: m, language: language,
                                                                             translate: translate && m.translates)
                        print(String(format: "   %@  %.2f s  %@", name, Date().timeIntervalSince(t1), text))
                    } catch {
                        print("   \(name)  error: \(error.localizedDescription)")
                    }
                }
                WhisperEngine.shared.unload(ifModel: m.id)
            }
            if gemini {
                let s = SettingsStore.shared.settings
                print("\n── gemini \(s.ai.model) (cloud)")
                let client = GeminiClient(apiKey: Secrets.apiKey, model: s.ai.model, timeout: 60)
                for (name, wav) in clips {
                    let t1 = Date()
                    do {
                        let text = try await client.transcribe(wav: wav, prompt: Prompts.transcribe)
                        print(String(format: "   %@  %.2f s  %@", name, Date().timeIntervalSince(t1), text))
                    } catch {
                        print("   \(name)  error: \(error.localizedDescription)")
                    }
                }
            }
            done.signal()
        }
        done.wait()
        return 0
    }

    /// Any audio file → the 16 kHz mono 16-bit WAV the app records.
    static func normalized(_ data: Data) -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".audio")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? data.write(to: tmp)) != nil, let file = try? AVAudioFile(forReading: tmp),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: outFormat),
              let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: inBuf)) != nil else { return data }
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / file.processingFormat.sampleRate + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return data }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        guard let ch = out.int16ChannelData else { return data }
        return WAV.encode(pcm16Mono: Data(bytes: ch[0], count: Int(out.frameLength) * 2), sampleRate: 16_000)
    }
}
