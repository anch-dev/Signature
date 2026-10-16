import Foundation

/// Captures everything the native engine prints (stderr/stdout) into a ring
/// buffer for the in-app status terminal, while still passing it through to
/// the original stream (Xcode console / device logs).
final class LogCapture: ObservableObject, @unchecked Sendable {
    static let shared = LogCapture()

    @Published private(set) var lines: [String] = []
    /// Extra detail from the app and engine (requests, timings, memory, network).
    @Published var verbose: Bool = UserDefaults.standard.bool(forKey: "verboseLogging") {
        didSet { UserDefaults.standard.set(verbose, forKey: "verboseLogging") }
    }

    /// Logs are also written to Documents/Logs (visible in Files), one file per day, kept 7 days.
    let logsDir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private let fileQueue = DispatchQueue(label: "signature.logfile")
    private var fileHandle: FileHandle?
    private var fileDay = ""

    var todayLogURL: URL { logsDir.appendingPathComponent("signature-\(Self.day.string(from: Date())).log") }
    private let maxLines = 3000
    private var pipe = Pipe()
    private var originalErr: Int32 = -1
    private var originalOut: Int32 = -1
    private var partial = ""
    private let lock = NSLock()
    private var pending: [String] = []
    private var flushScheduled = false

    private init() {}

    func start() {
        guard originalErr < 0 else { return }
        setvbuf(stderr, nil, _IONBF, 0)
        setvbuf(stdout, nil, _IOLBF, 0)
        originalErr = dup(STDERR_FILENO)
        originalOut = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        let passthrough = originalErr
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            if passthrough >= 0 { data.withUnsafeBytes { _ = write(passthrough, $0.baseAddress, data.count) } }
            self?.ingest(String(decoding: data, as: UTF8.self))
        }
        pruneOldLogs()
        log("Signature status terminal ready")
    }

    /// Only recorded when verbose logging is on.
    func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        log("· " + message())
    }

    private func pruneOldLogs() {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()) < cutoff {
            try? FileManager.default.removeItem(at: f)
        }
    }

    private func writeToFile(_ batch: [String]) {
        fileQueue.async { [weak self] in
            guard let self else { return }
            let day = Self.day.string(from: Date())
            if day != self.fileDay || self.fileHandle == nil {
                try? self.fileHandle?.close()
                let url = self.todayLogURL
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                self.fileHandle = try? FileHandle(forWritingTo: url)
                _ = try? self.fileHandle?.seekToEnd()
                self.fileDay = day
            }
            let text = batch.joined(separator: "\n") + "\n"
            if let data = text.data(using: .utf8) { try? self.fileHandle?.write(contentsOf: data) }
        }
    }

    /// App-side messages go to the same terminal.
    func log(_ message: String) {
        let stamp = Self.time.string(from: Date())
        enqueue(["[\(stamp)] \(message)"])
    }

    func clear() {
        DispatchQueue.main.async { self.lines.removeAll() }
    }

    private func ingest(_ chunk: String) {
        lock.lock()
        var text = partial + chunk.replacingOccurrences(of: "\r", with: "\n")
        var out: [String] = []
        while let nl = text.firstIndex(of: "\n") {
            let line = String(text[..<nl])
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { out.append(line) }
            text = String(text[text.index(after: nl)...])
        }
        partial = text
        lock.unlock()
        if !out.isEmpty { enqueue(out) }
    }

    /// Batch UI updates (the engine can print hundreds of lines per second).
    private func enqueue(_ newLines: [String]) {
        lock.lock()
        pending.append(contentsOf: newLines)
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let batch = self.pending
            self.pending.removeAll()
            self.flushScheduled = false
            self.lock.unlock()
            self.writeToFile(batch)
            self.lines.append(contentsOf: batch)
            if self.lines.count > self.maxLines { self.lines.removeFirst(self.lines.count - self.maxLines) }
        }
    }

    var text: String { lines.joined(separator: "\n") }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
