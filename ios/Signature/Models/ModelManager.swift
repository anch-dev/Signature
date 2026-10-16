import Foundation
import os

enum PerformanceMode: String, CaseIterable, Identifiable {
    case auto, lite, full
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .lite: return "Lite (4 GB phones)"
        case .full: return "Full"
        }
    }
}

/// Which models are selected, what's installed, downloads, and engine settings.
@MainActor
final class ModelManager: ObservableObject {
    // Selection (persisted)
    @Published var musicID: String { didSet { save() } }
    @Published var musicQuant: Quant { didSet { save() } }
    @Published var songwriterID: String { didSet { save() } }
    @Published var songwriterQuant: Quant { didSet { save() } }
    @Published var useSongwriter: Bool { didSet { save() } }
    @Published var performance: PerformanceMode { didSet { save() } }
    @Published var useCPU: Bool { didSet { save() } }
    @Published var zeroCopy: Bool { didSet { save() } }

    // State
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var progress: [String: Double] = [:]   // file name -> 0...1
    @Published var errors: [String: String] = [:]
    @Published private(set) var lastPeaks: [UInt64] = UserDefaults.standard.array(forKey: "lastPeaks") as? [UInt64] ?? []

    let directory: URL

    init() {
        let d = UserDefaults.standard
        musicID = d.string(forKey: "musicID") ?? "acestep-v15-turbo"
        musicQuant = Quant(rawValue: d.string(forKey: "musicQuant") ?? "") ?? .q4
        songwriterID = d.string(forKey: "songwriterID") ?? "acestep-5Hz-lm-0.6B"
        songwriterQuant = Quant(rawValue: d.string(forKey: "songwriterQuant") ?? "") ?? .q8
        useSongwriter = d.object(forKey: "useSongwriter") as? Bool ?? true
        performance = PerformanceMode(rawValue: d.string(forKey: "performance") ?? "") ?? .auto
        useCPU = d.bool(forKey: "useCPU")
        zeroCopy = d.object(forKey: "zeroCopy") as? Bool ?? true

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)

        refresh()
        BackgroundDownloader.shared.attach(self)
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(musicID, forKey: "musicID")
        d.set(musicQuant.rawValue, forKey: "musicQuant")
        d.set(songwriterID, forKey: "songwriterID")
        d.set(songwriterQuant.rawValue, forKey: "songwriterQuant")
        d.set(useSongwriter, forKey: "useSongwriter")
        d.set(performance.rawValue, forKey: "performance")
        d.set(useCPU, forKey: "useCPU")
        d.set(zeroCopy, forKey: "zeroCopy")
    }

    // MARK: selection

    var music: MusicModel { Catalog.music(musicID) ?? Catalog.music[0] }
    var songwriter: SongwriterModel { Catalog.songwriter(songwriterID) ?? Catalog.songwriters[0] }

    var musicFile: ModelFile? { music.file(musicQuant) ?? music.file(music.smallest) }
    var songwriterFile: ModelFile? { songwriter.file(songwriterQuant) ?? songwriter.quants.first.flatMap(songwriter.file) }
    var textEncoderFile: ModelFile { Catalog.textEncoders[.q8]! }

    var required: [ModelFile] {
        var files = [musicFile, textEncoderFile, Catalog.vae].compactMap { $0 }
        if useSongwriter, let s = songwriterFile { files.insert(s, at: 0) }
        return files
    }

    var missing: [ModelFile] { required.filter { !installed.contains($0.id) } }
    var isReady: Bool { missing.isEmpty }
    var missingBytes: Int64 { missing.reduce(0) { $0 + $1.bytes } }
    var isDownloadingRequired: Bool { missing.contains { progress[$0.id] != nil } }

    /// Combined progress for everything still missing (for the Create screen).
    var requiredProgress: Double {
        let total = required.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return 1 }
        let done = required.reduce(0.0) { acc, f in
            acc + Double(f.bytes) * (installed.contains(f.id) ? 1 : (progress[f.id] ?? 0))
        }
        return done / Double(total)
    }

    func path(_ f: ModelFile) -> URL { directory.appendingPathComponent(f.id) }
    func isInstalled(_ f: ModelFile) -> Bool { installed.contains(f.id) }

    var paths: ModelPaths? {
        guard isReady, let m = musicFile else { return nil }
        return ModelPaths(
            songwriter: useSongwriter ? songwriterFile.map(path) : nil,
            textEncoder: path(textEncoderFile),
            diffusion: path(m),
            vae: path(Catalog.vae))
    }

    /// Lite when chosen, or automatically on phones with < 3 GB for the app.
    var liteActive: Bool { performance == .lite || (performance == .auto && Device.isLowMemory) }

    var engineOptions: EngineOptions {
        EngineOptions(zeroCopy: zeroCopy, lowMemory: liteActive, useCPU: useCPU)
    }

    /// Longest song this phone can render without being killed for memory.
    var maxDuration: Double {
        if liteActive { return 60 }
        let gb = Device.budgetGB
        if gb >= 5 { return 240 }
        if gb >= 3.5 { return 150 }
        return 90
    }

    struct InstalledMusic: Identifiable {
        let model: MusicModel
        let quant: Quant
        var id: String { model.id + quant.rawValue }
    }

    var installedMusic: [InstalledMusic] {
        Catalog.music.flatMap { m in
            m.quants.compactMap { q -> InstalledMusic? in
                guard let f = m.file(q), installed.contains(f.id) else { return nil }
                return InstalledMusic(model: m, quant: q)
            }
        }
    }

    func select(_ m: MusicModel, _ q: Quant) {
        musicID = m.id
        musicQuant = q
    }

    // MARK: files

    func refresh() {
        let fm = FileManager.default
        installed = Set(Catalog.allFiles.filter { f in
            let size = (try? fm.attributesOfItem(atPath: path(f).path)[.size] as? NSNumber)?.int64Value ?? -1
            return size == f.bytes
        }.map(\.id))
    }

    func download(_ f: ModelFile) {
        guard !installed.contains(f.id), progress[f.id] == nil else { return }
        let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? Int64.max
        if free < f.bytes + 300_000_000 {
            errors[f.id] = "Not enough space: needs \(Self.format(f.bytes)), \(Self.format(free)) free."
            return
        }
        errors[f.id] = nil
        progress[f.id] = 0
        BackgroundDownloader.shared.start(f)
    }

    func downloadMissing() { missing.forEach(download) }

    func cancel(_ f: ModelFile) {
        BackgroundDownloader.shared.cancel(f.id)
        progress[f.id] = nil
    }

    func delete(_ f: ModelFile) {
        cancel(f)
        try? FileManager.default.removeItem(at: path(f))
        refresh()
    }

    var usedBytes: Int64 {
        Catalog.allFiles.filter { installed.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    func recordPeaks(_ p: [UInt64]) {
        lastPeaks = p
        UserDefaults.standard.set(p.map { NSNumber(value: $0) }, forKey: "lastPeaks")
    }

    // MARK: downloader callbacks

    fileprivate func didProgress(_ name: String, _ p: Double) {
        if progress[name] != nil || p < 1 { progress[name] = p }
    }

    fileprivate func didFinish(_ name: String, error: String?) {
        progress[name] = nil
        if let error { errors[name] = error } else { errors[name] = nil }
        refresh()
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Background downloads

/// Model files are 0.3-10 GB, so downloads run in a background URLSession:
/// they keep going when the app is closed or the phone locks, and resume
/// after network drops.
final class BackgroundDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloader()
    static let identifier = "com.anchdev.signature.models"

    /// Set by the app delegate when iOS wakes the app for finished downloads.
    var backgroundCompletion: (() -> Void)?

    private weak var manager: ModelManager?
    private let lock = NSLock()
    private var lastReport: [String: Date] = [:]

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.allowsCellularAccess = true
        c.timeoutIntervalForResource = 60 * 60 * 12
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    private var resumeDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models/.resume", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @MainActor func attach(_ m: ModelManager) {
        manager = m
        // Re-attach to downloads that kept running while the app was closed.
        session.getAllTasks { tasks in
            for t in tasks {
                guard let name = t.taskDescription else { continue }
                let p = t.countOfBytesExpectedToReceive > 0
                    ? Double(t.countOfBytesReceived) / Double(t.countOfBytesExpectedToReceive) : 0
                Task { @MainActor in m.didProgress(name, p) }
            }
        }
    }

    func start(_ f: ModelFile) {
        session.getAllTasks { [self] tasks in
            if tasks.contains(where: { $0.taskDescription == f.id && $0.state == .running }) { return }
            let resume = resumeDir.appendingPathComponent(f.id)
            let task: URLSessionDownloadTask
            if let data = try? Data(contentsOf: resume) {
                try? FileManager.default.removeItem(at: resume)
                task = session.downloadTask(withResumeData: data)
            } else {
                task = session.downloadTask(with: f.url)
            }
            task.taskDescription = f.id
            task.countOfBytesClientExpectsToReceive = f.bytes
            task.resume()
        }
    }

    func cancel(_ name: String) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == name }.forEach { $0.cancel() }
        }
        try? FileManager.default.removeItem(at: resumeDir.appendingPathComponent(name))
    }

    private func notify(_ body: @escaping @MainActor (ModelManager) -> Void) {
        Task { @MainActor [weak self] in
            if let m = self?.manager { body(m) }
        }
    }

    // MARK: delegate

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        guard let name = downloadTask.taskDescription else { return }
        lock.lock()
        let now = Date()
        let due = now.timeIntervalSince(lastReport[name] ?? .distantPast) > 0.25
        if due { lastReport[name] = now }
        lock.unlock()
        guard due else { return }
        let expected = total > 0 ? total : downloadTask.countOfBytesClientExpectsToReceive
        let p = expected > 0 ? min(0.999, Double(written) / Double(expected)) : 0
        notify { $0.didProgress(name, p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = downloadTask.taskDescription else { return }
        // Must move before returning: iOS deletes the temp file afterwards.
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
        let dest = dir.appendingPathComponent(name)
        var error: String?
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            error = "Server returned \(http.statusCode)"
        } else {
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
                if let expected = Catalog.allFiles.first(where: { $0.id == name })?.bytes, size != expected {
                    try? FileManager.default.removeItem(at: dest)
                    error = "Download was incomplete. Tap to retry."
                }
            } catch {
                error = "Couldn't save the file: \(error.localizedDescription)"
            }
        }
        notify { $0.didFinish(name, error: error) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let name = task.taskDescription else { return }
        let ns = error as NSError
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeDir.appendingPathComponent(name))
        }
        let cancelled = ns.code == NSURLErrorCancelled && ns.userInfo[NSURLSessionDownloadTaskResumeData] == nil
        notify { $0.didFinish(name, error: cancelled ? nil : "Paused: \(error.localizedDescription). Tap to resume.") }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletion?()
            self?.backgroundCompletion = nil
        }
    }
}
