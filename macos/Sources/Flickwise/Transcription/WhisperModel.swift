// WhisperModel — the local speech models Flickwise can use (whisper.cpp "ggml" files from
// huggingface.co/ggerganov/whisper.cpp), and ModelStore, which downloads, verifies and deletes them.
// Models live in ~/Library/Application Support/Flickwise/models/.
// The default is Whisper large-v3-turbo (the model Voicebox uses for dictation), 8-bit quantized.
// Measured on an M1 Pro (Metal): q8 1.76 s, full 1.67 s, q5 2.00 s per clip, identical text, so
// q8 gives near-full speed at half the size (q5 is smaller but slower on the GPU).
import CryptoKit
import Foundation

struct WhisperModel: Identifiable, Hashable {
    let id: String           // e.g. "large-v3-turbo-q5_0"
    let name: String
    let note: String
    let bytes: Int64
    let sha256: String
    let translates: Bool     // can turn other languages into English (turbo was trained without translation)
    var coreML: Asset? = nil // optional Neural Engine encoder (whisper.cpp loads it when it's next to the model)

    struct Asset: Hashable {
        let bytes: Int64
        let sha256: String
    }

    /// whisper.cpp looks for "<model without -qN_M>-encoder.mlmodelc" beside the .bin.
    var coreMLName: String {
        let base = id.replacingOccurrences(of: #"-q\d_\d$"#, with: "", options: .regularExpression)
        return "ggml-\(base)-encoder.mlmodelc"
    }
    var coreMLPath: URL { ModelStore.directory.appendingPathComponent(coreMLName) }
    var coreMLURL: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(coreMLName).zip")! }

    var fileName: String { "ggml-\(id).bin" }
    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")! }
    var path: URL { ModelStore.directory.appendingPathComponent(fileName) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static let defaultID = "large-v3-turbo-q8_0"

    static let catalog: [WhisperModel] = [
        WhisperModel(id: "large-v3-turbo-q8_0", name: "Large v3 Turbo",
                     note: "Recommended: Voicebox's model; accurate in English, Urdu and Hindi",
                     bytes: 874_188_075, sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
                     translates: false,
                     coreML: Asset(bytes: 1_173_393_014,
                                   sha256: "84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a")),
        WhisperModel(id: "large-v3-turbo-q5_0", name: "Large v3 Turbo (compressed)",
                     note: "Smaller download, same text, a little slower",
                     bytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
                     translates: false,
                     coreML: Asset(bytes: 1_173_393_014,
                                   sha256: "84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a")),
        WhisperModel(id: "large-v3-turbo", name: "Large v3 Turbo (full)",
                     note: "Uncompressed original; fastest, twice the memory",
                     bytes: 1_624_555_275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
                     translates: false,
                     coreML: Asset(bytes: 1_173_393_014,
                                   sha256: "84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a")),
        WhisperModel(id: "small", name: "Small",
                     note: "3–4× faster; fine for English, weaker for Urdu/Hindi; can translate to English",
                     bytes: 487_601_967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
                     translates: true),      // its Neural Engine encoder measured no faster than the GPU,
        WhisperModel(id: "base", name: "Base",
                     note: "Fastest, least accurate",
                     bytes: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
                     translates: true),
    ]

    static func find(_ id: String) -> WhisperModel? { catalog.first { $0.id == id } }
    static var `default`: WhisperModel { find(defaultID)! }
}

final class ModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelStore()
    static var directory: URL { Paths.ensure(Paths.support.appendingPathComponent("models", isDirectory: true)) }

    /// Download progress (0…1) for models being downloaded.
    @Published private(set) var progress: [String: Double] = [:]
    /// Models present on disk.
    @Published private(set) var installed: Set<String> = []
    /// Last download error per model.
    @Published private(set) var errors: [String: String] = [:]

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var lastPublished: [String: Double] = [:]

    override init() {
        super.init()
        refresh()
    }

    func isInstalled(_ m: WhisperModel) -> Bool { installed.contains(m.id) }
    func hasCoreML(_ m: WhisperModel) -> Bool { installed.contains("coreml:" + m.id) }

    func refresh() {
        let fm = FileManager.default
        var ids = Set(WhisperModel.catalog.filter { fm.fileExists(atPath: $0.path.path) }.map(\.id))
        for m in WhisperModel.catalog where m.coreML != nil && fm.fileExists(atPath: m.coreMLPath.path) {
            ids.insert("coreml:" + m.id)
        }
        installed = ids
    }

    /// Neural Engine encoder: ~25% faster recognition. The first load after downloading it
    /// compiles it for this Mac (about 2 minutes for turbo, once).
    func downloadCoreML(_ m: WhisperModel) {
        let key = "coreml:" + m.id
        guard m.coreML != nil, tasks[key] == nil, !hasCoreML(m) else { return }
        errors[key] = nil
        progress[key] = 0
        let task = session.downloadTask(with: m.coreMLURL)
        task.taskDescription = key
        tasks[key] = task
        task.resume()
        Log.info("Downloading the Neural Engine encoder for \(m.id)")
    }

    func deleteCoreML(_ m: WhisperModel) {
        // Shared by the turbo variants: unload whichever of them is using it.
        for other in WhisperModel.catalog where other.coreMLName == m.coreMLName { WhisperEngine.shared.unload(ifModel: other.id) }
        try? FileManager.default.removeItem(at: m.coreMLPath)
        refresh()
        NotificationCenter.default.post(name: ModelStore.didInstall, object: m.id)   // reload without it
    }

    func download(_ m: WhisperModel) {
        guard tasks[m.id] == nil, !isInstalled(m) else { return }
        errors[m.id] = nil
        progress[m.id] = 0
        let task = session.downloadTask(with: m.url)
        task.taskDescription = m.id
        tasks[m.id] = task
        task.resume()
        Log.info("Downloading Whisper model \(m.id) (\(m.sizeText))")
    }

    func cancel(_ m: WhisperModel, coreML: Bool = false) {
        let key = coreML ? "coreml:" + m.id : m.id
        tasks[key]?.cancel()
        tasks[key] = nil
        progress[key] = nil
    }

    func delete(_ m: WhisperModel) {
        WhisperEngine.shared.unload(ifModel: m.id)
        try? FileManager.default.removeItem(at: m.path)
        refresh()
    }

    // ── URLSessionDownloadDelegate (background queue) ────────────────────────

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        guard let id = downloadTask.taskDescription, let m = Self.model(for: id) else { return }
        let total = expected > 0 ? expected : (id.hasPrefix("coreml:") ? m.coreML?.bytes ?? 1 : m.bytes)
        let value = min(1, Double(written) / Double(total))
        DispatchQueue.main.async {
            // Publish in 0.5% steps so SwiftUI isn't flooded.
            guard value - (self.lastPublished[id] ?? -1) >= 0.005 || value >= 1 else { return }
            self.lastPublished[id] = value
            self.progress[id] = value
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, let m = Self.model(for: id) else { return }
        if id.hasPrefix("coreml:") { finishCoreML(m, key: id, location: location); return }
        // `location` is deleted when this method returns: move it first, verify afterwards.
        let staging = ModelStore.directory.appendingPathComponent(m.fileName + ".part")
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            finish(m, error: "Couldn't save the download: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.async { self.progress[m.id] = 1 }
        guard Self.sha256(of: staging) == m.sha256 else {
            try? FileManager.default.removeItem(at: staging)
            finish(m, error: "The download was corrupted (checksum mismatch). Try again.")
            return
        }
        try? FileManager.default.removeItem(at: m.path)
        do {
            try FileManager.default.moveItem(at: staging, to: m.path)
            finish(m, error: nil)
        } catch {
            finish(m, error: error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription, let m = Self.model(for: id) else { return }
        if (error as? URLError)?.code == .cancelled { return }
        finish(m, key: id, error: error.localizedDescription)
    }

    private static func model(for key: String) -> WhisperModel? {
        WhisperModel.find(key.replacingOccurrences(of: "coreml:", with: ""))
    }

    /// The encoder arrives as a zip of a .mlmodelc folder: verify, unpack beside the model.
    private func finishCoreML(_ m: WhisperModel, key: String, location: URL) {
        let zip = ModelStore.directory.appendingPathComponent(m.coreMLName + ".zip.part")
        let fm = FileManager.default
        try? fm.removeItem(at: zip)
        guard (try? fm.moveItem(at: location, to: zip)) != nil else {
            finish(m, key: key, error: "Couldn't save the download")
            return
        }
        defer { try? fm.removeItem(at: zip) }
        DispatchQueue.main.async { self.progress[key] = 1 }
        guard Self.sha256(of: zip) == m.coreML?.sha256 else {
            finish(m, key: key, error: "The download was corrupted (checksum mismatch). Try again.")
            return
        }
        let unpack = ModelStore.directory.appendingPathComponent("unpack-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: unpack) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpack.path]
        do { try ditto.run(); ditto.waitUntilExit() } catch {}
        let unpacked = unpack.appendingPathComponent(m.coreMLName)
        guard ditto.terminationStatus == 0, fm.fileExists(atPath: unpacked.path) else {
            finish(m, key: key, error: "Couldn't unpack the Neural Engine encoder")
            return
        }
        try? fm.removeItem(at: m.coreMLPath)
        do {
            try fm.moveItem(at: unpacked, to: m.coreMLPath)
            finish(m, key: key, error: nil)
        } catch {
            finish(m, key: key, error: error.localizedDescription)
        }
    }

    private func finish(_ m: WhisperModel, error: String?) { finish(m, key: m.id, error: error) }

    private func finish(_ m: WhisperModel, key: String, error: String?) {
        DispatchQueue.main.async {
            self.tasks[key] = nil
            self.progress[key] = nil
            self.lastPublished[key] = nil
            self.errors[key] = error
            self.refresh()
            if let error {
                Log.error("Download \(key): \(error)")
            } else {
                Log.info("\(key) downloaded and verified")
                if key.hasPrefix("coreml:") {
                    for other in WhisperModel.catalog where other.coreMLName == m.coreMLName {
                        WhisperEngine.shared.unload(ifModel: other.id)       // reload to pick up the encoder
                    }
                }
                NotificationCenter.default.post(name: ModelStore.didInstall, object: m.id)
            }
        }
    }

    static let didInstall = Notification.Name("FlickwiseModelInstalled")

    /// Streams the file through SHA-256 (models are up to 1.6 GB).
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
