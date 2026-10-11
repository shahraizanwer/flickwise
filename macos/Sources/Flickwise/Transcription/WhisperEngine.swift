// WhisperEngine — local speech recognition with whisper.cpp (Metal-accelerated), in process.
// The model is loaded once and kept in memory, so a dictation pays only for the actual
// recognition. All whisper.cpp calls run on one serial queue (a context isn't thread-safe).
//   preload(_:)                       load in the background (no-op if already loaded)
//   warmUp(_:)                        load + free (one-time setup costs at launch, no memory kept)
//   transcribe(pcm:model:language:translate:) async throws -> String
//   unload() / unload(ifModel:) / shutdown() (synchronous, before quitting)
import Foundation
import whisper

final class WhisperEngine: @unchecked Sendable {   // all state is confined to `queue`
    static let shared = WhisperEngine()

    enum EngineError: LocalizedError {
        case modelMissing(String)
        case loadFailed(String)
        case failed(Int32)
        var errorDescription: String? {
            switch self {
            case .modelMissing(let name): return "The \(name) model isn't downloaded yet (Settings › Speech)"
            case .loadFailed(let id): return "Couldn't load the \(id) model"
            case .failed(let code): return "Speech recognition failed (\(code))"
            }
        }
    }

    private let queue = DispatchQueue(label: "flickwise.whisper", qos: .userInitiated)
    private var ctx: OpaquePointer?
    private var loadedID: String? {
        didSet { lock.lock(); readyID = loadedID; lock.unlock() }
    }
    private let lock = NSLock()
    private var readyID: String?

    private init() {
        // whisper.cpp logs a lot to stderr; keep only errors, in our log.
        whisper_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("failed to load Core ML model") { return }   // optional: none downloaded
            Log.error("whisper.cpp: \(message)")
        }, nil)
    }

    /// Safe to call from the main thread: never waits for a load in progress.
    func isReady(_ model: WhisperModel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return readyID == model.id
    }

    func preload(_ model: WhisperModel) {
        queue.async { [weak self] in try? self?.load(model) }
    }

    /// Load once and free again: pays one-time costs (GPU shader / Neural Engine compile after an
    /// install or update) at launch instead of on the first dictation, without keeping the memory.
    func warmUp(_ model: WhisperModel) {
        queue.async { [weak self] in
            guard let self, self.loadedID == nil else { return }
            try? self.load(model)
            self.free()
        }
    }

    func unload() {
        queue.async { [weak self] in self?.free() }
    }

    /// Frees the model right away. Call before the process exits: ggml's Metal backend asserts
    /// if its device is torn down by exit() while a context still holds GPU buffers.
    func shutdown() {
        queue.sync { free() }
    }

    func unload(ifModel id: String) {
        queue.sync { if loadedID == id { free() } }
    }

    /// `pcm`: 16 kHz mono float samples. `language`: "auto" or a code like "en".
    func transcribe(pcm: [Float], model: WhisperModel, language: String, translate: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.load(model)
                    cont.resume(returning: try self.run(pcm: pcm, language: language, translate: translate))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // ── on `queue` ───────────────────────────────────────────────────────────

    private func load(_ model: WhisperModel) throws {
        if loadedID == model.id, ctx != nil { return }
        free()
        guard FileManager.default.fileExists(atPath: model.path.path) else { throw EngineError.modelMissing(model.name) }
        let started = Date()
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true          // measured: ~25% faster on Apple Silicon
        guard let c = whisper_init_from_file_with_params(model.path.path, params) else {
            throw EngineError.loadFailed(model.id)
        }
        ctx = c
        loadedID = model.id
        let coreML = FileManager.default.fileExists(atPath: model.coreMLPath.path)
        Log.info(String(format: "Whisper %@ loaded in %.2f s (%@)", model.id, Date().timeIntervalSince(started),
                        coreML ? "Neural Engine encoder" : "GPU"))
    }

    private func free() {
        if let ctx { whisper_free(ctx) }
        ctx = nil
        loadedID = nil
    }

    private func run(pcm: [Float], language: String, translate: Bool) throws -> String {
        guard let ctx else { throw EngineError.failed(-1) }
        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        p.translate = translate
        p.no_context = true
        p.no_timestamps = true
        p.single_segment = false
        p.print_special = false
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.suppress_blank = true
        p.suppress_nst = true            // no "[Music]", "(laughs)" and similar tokens
        let lang = language.isEmpty ? "auto" : language
        let status: Int32 = lang.withCString { langPtr in
            p.language = langPtr
            p.detect_language = false
            return pcm.withUnsafeBufferPointer { buf in
                whisper_full(ctx, p, buf.baseAddress, Int32(buf.count))
            }
        }
        guard status == 0 else { throw EngineError.failed(status) }
        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let seg = whisper_full_get_segment_text(ctx, i) { text += String(cString: seg) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
