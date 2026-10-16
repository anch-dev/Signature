import Foundation

/// Captures everything the native engine prints (stderr/stdout) into a ring
/// buffer for the in-app status terminal, while still passing it through to
/// the original stream (Xcode console / device logs).
final class LogCapture: ObservableObject, @unchecked Sendable {
    static let shared = LogCapture()

    @Published private(set) var lines: [String] = []
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
        log("Signature status terminal ready")
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
            self.lines.append(contentsOf: batch)
            if self.lines.count > self.maxLines { self.lines.removeFirst(self.lines.count - self.maxLines) }
        }
    }

    var text: String { lines.joined(separator: "\n") }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
