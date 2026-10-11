// TextBackend — runs a mode's prompt on text with the configured backend:
//   Gemini (HTTPS, GeminiClient.rewrite)  or  the Glean CLI (`glean chat --json …`, Fast agent,
//   chat not saved), ported from lib/glean_client.lua.
import Foundation

enum TextBackendError: LocalizedError {
    case gleanMissing(String), gleanAuth, gleanFailed(String), timedOut(Int), empty
    var errorDescription: String? {
        switch self {
        case .gleanMissing(let path): return "Glean CLI not found at \(path) (Settings › AI)"
        case .gleanAuth: return "Glean sign-in expired — run: glean auth login"
        case .gleanFailed(let msg): return "Glean failed: \(msg)"
        case .timedOut(let s): return "Timed out after \(s) s"
        case .empty: return "Empty response"
        }
    }
}

enum TextBackend {
    static func transform(_ text: String, mode: Mode, settings: AppSettings) async throws -> String {
        let timeout = mode.timeoutSeconds ?? settings.ai.timeoutSeconds
        switch settings.ai.backend {
        case .gemini:
            let client = GeminiClient(apiKey: Secrets.apiKey, model: settings.ai.model, timeout: TimeInterval(timeout))
            return try await client.rewrite(text: text, instructions: mode.prompt, temperature: mode.temperature ?? 0.2)
        case .glean:
            return try await glean(text, prompt: mode.prompt, path: gleanPath(settings), timeout: timeout)
        }
    }

    static func gleanPath(_ s: AppSettings) -> String {
        if !s.ai.gleanPath.isEmpty { return (s.ai.gleanPath as NSString).expandingTildeInPath }
        return ["/opt/homebrew/bin/glean", "/usr/local/bin/glean"].first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/glean"
    }

    private static func glean(_ text: String, prompt: String, path: String, timeout: Int) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw TextBackendError.gleanMissing(path) }
        let combined = prompt + "\n\n---\nTEXT TO TRANSFORM (verbatim, do not echo this header):\n" + text
        // agent "FAST" + mode "DEFAULT" = the desktop app's Fast mode; saveChat false keeps it out of Glean's history.
        let body: [String: Any] = [
            "messages": [["author": "USER", "messageType": "CONTENT", "fragments": [["text": combined]]]],
            "saveChat": false,
            "agentConfig": ["agent": "FAST", "mode": "DEFAULT"],
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? "{}"

        return try await withCheckedThrowingContinuation { cont in
            let run = GleanRun(cont)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["chat", "--json", json]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            // Read as it arrives: a full pipe would block glean.
            out.fileHandleForReading.readabilityHandler = { run.append(out: $0.availableData) }
            err.fileHandleForReading.readabilityHandler = { run.append(err: $0.availableData) }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                run.append(out: out.fileHandleForReading.readDataToEndOfFile())
                run.append(err: err.fileHandleForReading.readDataToEndOfFile())
                let (stdout, stderr) = run.text
                if proc.terminationStatus != 0 {
                    let msg = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                    if msg.localizedCaseInsensitiveContains("auth") || msg.contains("token") || msg.contains("401") {
                        run.finish(.failure(TextBackendError.gleanAuth))
                    } else {
                        run.finish(.failure(TextBackendError.gleanFailed(String(msg.prefix(160)))))
                    }
                    return
                }
                let reply = GeminiClient.postprocess(stdout)
                run.finish(reply.isEmpty ? .failure(TextBackendError.empty) : .success(reply))
            }
            do { try p.run() } catch { run.finish(.failure(TextBackendError.gleanFailed(error.localizedDescription))); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                if p.isRunning { p.terminate(); run.finish(.failure(TextBackendError.timedOut(timeout))) }
            }
        }
    }
}

/// Output and completion of one glean run, shared by the pipe, exit and timeout handlers.
private final class GleanRun: @unchecked Sendable {
    private let lock = NSLock()
    private var outData = Data(), errData = Data()
    private var cont: CheckedContinuation<String, Error>?

    init(_ cont: CheckedContinuation<String, Error>) { self.cont = cont }

    func append(out d: Data) { lock.lock(); outData += d; lock.unlock() }
    func append(err d: Data) { lock.lock(); errData += d; lock.unlock() }

    var text: (String, String) {
        lock.lock(); defer { lock.unlock() }
        return (String(data: outData, encoding: .utf8) ?? "", String(data: errData, encoding: .utf8) ?? "")
    }

    /// Resumes once; later calls (exit after a timeout) are ignored.
    func finish(_ r: Result<String, Error>) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(with: r)
    }
}
