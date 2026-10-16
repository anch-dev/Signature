import Foundation

/// One GGUF file from Serveurperso/ACE-Step-1.5-GGUF.
struct ModelFile: Identifiable, Hashable {
    let id: String          // file name
    let role: String
    let bytes: Int64

    var url: URL { URL(string: "https://huggingface.co/Serveurperso/ACE-Step-1.5-GGUF/resolve/main/\(id)")! }
}

enum Quality: String, CaseIterable, Identifiable {
    case standard, high
    var id: String { rawValue }
    var title: String { self == .standard ? "Standard (Q4, 3.3 GB)" : "High quality (Q8, 4.4 GB)" }
}

@MainActor
final class ModelManager: ObservableObject {
    static let songwriter = ModelFile(id: "acestep-5Hz-lm-0.6B-Q8_0.gguf", role: "Songwriter", bytes: 709_846_656)
    static let textEncoder = ModelFile(id: "Qwen3-Embedding-0.6B-Q8_0.gguf", role: "Text encoder", bytes: 784_144_960)
    static let vae = ModelFile(id: "vae-BF16.gguf", role: "Audio decoder", bytes: 337_420_928)
    static let ditStandard = ModelFile(id: "acestep-v15-turbo-Q4_K_M.gguf", role: "Music model", bytes: 1_445_710_272)
    static let ditHigh = ModelFile(id: "acestep-v15-turbo-Q8_0.gguf", role: "Music model (HQ)", bytes: 2_549_528_000)

    @Published var quality: Quality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var downloading: ModelFile?
    @Published private(set) var downloadProgress: Double = 0
    @Published var lastError: String?

    let directory: URL
    private var downloader: Downloader?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
        quality = Quality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .standard
        refresh()
    }

    var required: [ModelFile] {
        [Self.songwriter, Self.textEncoder, quality == .high ? Self.ditHigh : Self.ditStandard, Self.vae]
    }

    var missing: [ModelFile] { required.filter { !installed.contains($0.id) } }
    var isReady: Bool { missing.isEmpty }
    var missingBytes: Int64 { missing.reduce(0) { $0 + $1.bytes } }

    func path(_ f: ModelFile) -> URL { directory.appendingPathComponent(f.id) }

    var paths: ModelPaths? {
        guard isReady else { return nil }
        return ModelPaths(
            songwriter: path(Self.songwriter),
            textEncoder: path(Self.textEncoder),
            diffusion: path(quality == .high ? Self.ditHigh : Self.ditStandard),
            vae: path(Self.vae))
    }

    func refresh() {
        let all = [Self.songwriter, Self.textEncoder, Self.vae, Self.ditStandard, Self.ditHigh]
        installed = Set(all.filter { f in
            let size = (try? FileManager.default.attributesOfItem(atPath: path(f).path)[.size] as? Int64) ?? 0
            return size == f.bytes
        }.map(\.id))
    }

    func downloadMissing() async {
        lastError = nil
        let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? Int64.max
        if free < missingBytes + 500_000_000 {
            lastError = "Not enough free space. Need \(Self.format(missingBytes + 500_000_000)), have \(Self.format(free))."
            return
        }
        for file in missing {
            downloading = file
            downloadProgress = 0
            let d = Downloader()
            downloader = d
            do {
                try await d.download(file.url, to: path(file)) { [weak self] p in
                    Task { @MainActor in self?.downloadProgress = p }
                }
            } catch {
                if (error as? URLError)?.code != .cancelled {
                    lastError = "\(file.role) download failed: \(error.localizedDescription)"
                }
                break
            }
            refresh()
        }
        downloading = nil
        downloader = nil
        refresh()
    }

    func cancelDownload() { downloader?.cancel() }

    func deleteUnused() {
        let keep = Set(required.map(\.id))
        for f in [Self.ditStandard, Self.ditHigh] where !keep.contains(f.id) {
            try? FileManager.default.removeItem(at: path(f))
        }
        refresh()
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// URLSession download with progress, moved into place atomically.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession!
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL!
    private var onProgress: ((Double) -> Void)?
    private var task: URLSessionDownloadTask?

    func download(_ url: URL, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        destination = dest
        onProgress = progress
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 60 * 60 * 3
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            task = session.downloadTask(with: url)
            task?.resume()
        }
        session.finishTasksAndInvalidate()
    }

    func cancel() { task?.cancel() }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        if total > 0 { onProgress?(Double(written) / Double(total)) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Must move before returning: the temp file is deleted afterwards.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }

    private func finish(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
