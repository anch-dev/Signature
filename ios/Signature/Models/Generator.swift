import Foundation
import UIKit

enum GenTarget: String, CaseIterable, Identifiable {
    case phone, pc
    var id: String { rawValue }
}

enum CreateMode: String, CaseIterable, Identifiable {
    case simple, custom
    var id: String { rawValue }
    var title: String { self == .simple ? "Simple" : "Custom" }
}

@MainActor
final class Generator: ObservableObject {
    // Simple mode
    @Published var songDescription = ""
    // Custom mode
    @Published var style = ""
    @Published var lyrics = ""
    @Published var title = ""
    // Shared
    @Published var mode: CreateMode = CreateMode(rawValue: UserDefaults.standard.string(forKey: "createMode") ?? "") ?? .simple {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "createMode") }
    }
    @Published var instrumental = false
    @Published var duration: Double = 60
    @Published var language = ""
    @Published var adapter: URL?            // phone style (.safetensors on this iPhone)
    @Published var pcStyle: String?         // PC style (by name, lives on the Hub)
    @Published var adapterScale: Double = 1.0
    @Published var lockSeed = false
    @Published var seedText = ""
    @Published var target: GenTarget = GenTarget(rawValue: UserDefaults.standard.string(forKey: "target") ?? "") ?? .phone {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: "target") }
    }

    @Published private(set) var running = false
    @Published private(set) var stage: GenStage = .songwriter
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = ""
    @Published private(set) var startedAt: Date?
    @Published var error: String?
    @Published var lastSong: Song?

    private let cancelFlag = LockedFlag()
    private var remoteTask: Task<Void, Never>?

    var styleName: String? { target == .pc ? pcStyle : adapter.map(AdapterStore.name) }

    private struct Prepared {
        var caption: String
        var lyrics: String
        var title: String
    }

    private func prepare(songwriterAvailable: Bool) -> Prepared? {
        let trigger = styleName.map { $0 + ", " } ?? ""
        switch mode {
        case .simple:
            let d = songDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !d.isEmpty else {
                error = "Describe the song you want, e.g. \"a late-night R&B song about city lights\"."
                return nil
            }
            guard songwriterAvailable || instrumental else {
                error = "Simple mode needs the Songwriter model to write lyrics. Turn it on in Settings → Models, or use Custom."
                return nil
            }
            let t = title.isEmpty ? Self.autoTitle(d) : title
            return Prepared(caption: trigger + d, lyrics: instrumental ? "[Instrumental]" : "", title: t)
        case .custom:
            let s = style.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty || !words.isEmpty else {
                error = "Add some lyrics or a style of music."
                return nil
            }
            let caption = s.isEmpty ? "song" : s
            let fullCaption = caption.lowercased().contains(trigger.dropLast(2).lowercased()) || trigger.isEmpty
                ? caption : trigger + caption
            let lyr = instrumental ? "[Instrumental]" : (words.isEmpty && !songwriterAvailable ? "[Instrumental]" : words)
            let t = title.isEmpty ? Self.autoTitle(words.isEmpty ? caption : Self.firstLyricLine(words)) : title
            return Prepared(caption: fullCaption, lyrics: lyr, title: t)
        }
    }

    static func autoTitle(_ text: String) -> String {
        let words = text.replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ").prefix(5).joined(separator: " ")
        let cleaned = words.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return cleaned.isEmpty ? "Untitled" : cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }

    static func firstLyricLine(_ lyrics: String) -> String {
        lyrics.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("[") } ?? lyrics
    }

    private func begin(_ text: String) {
        error = nil
        running = true
        progress = 0
        statusText = text
        startedAt = Date()
        cancelFlag.set(false)
    }

    private func end() {
        running = false
        startedAt = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: on the iPhone

    func start(models: ModelManager, library: Library) {
        guard !running else { return }
        guard let paths = models.paths else {
            error = "Download the models first."
            return
        }
        guard let p = prepare(songwriterAvailable: paths.songwriter != nil) else { return }
        let request = SongRequest(
            caption: p.caption, lyrics: p.lyrics, language: language,
            duration: min(duration, models.maxDuration), bpm: 0,
            seed: lockSeed ? Int64(seedText) ?? -1 : -1,
            adapter: adapter, adapterScale: Float(adapterScale))
        let options = models.engineOptions
        let modelName = models.music.name

        let (out, fileName) = library.newFileURL(title: p.title)
        begin(paths.songwriter != nil ? GenStage.songwriter.label : GenStage.diffusion.label)
        stage = paths.songwriter != nil ? .songwriter : .diffusion
        UIApplication.shared.isIdleTimerDisabled = true  // screen lock suspends GPU work

        let flag = cancelFlag
        Task {
            defer { end() }
            do {
                let result = try await SongEngine.shared.generate(
                    request, models: paths, options: options, output: out,
                    onProgress: { [weak self] s, value in
                        Task { @MainActor in
                            guard let self else { return }
                            self.stage = s
                            self.statusText = s.label
                            self.progress = max(self.progress, value)
                        }
                    },
                    isCancelled: { flag.get() })
                guard let result else {
                    try? FileManager.default.removeItem(at: out)
                    return
                }
                models.recordPeaks(result.peakBytes)
                let song = Song(
                    id: UUID(), title: p.title, caption: result.caption.isEmpty ? p.caption : result.caption,
                    lyrics: result.lyrics.isEmpty ? request.lyrics : result.lyrics,
                    adapter: styleName, seed: result.seed, bpm: result.bpm,
                    key: result.key, duration: result.duration, created: Date(), fileName: fileName,
                    madeOn: "iPhone", model: modelName, prompt: mode == .simple ? songDescription : style)
                library.add(song)
                lastSong = song
                seedText = String(result.seed)
            } catch {
                try? FileManager.default.removeItem(at: out)
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: on the PC (Signature Hub)

    func startRemote(hub: HubStore, library: Library) {
        guard !running else { return }
        guard let client = hub.client, let pcName = hub.pairing?.name else {
            error = HubError.notPaired.localizedDescription
            return
        }
        guard let p = prepare(songwriterAvailable: true) else { return }
        struct Body: Encodable {
            let caption: String; let lyrics: String; let duration: Double; let language: String
            let style: String?; let style_scale: Double; let seed: Int64; let simple: Bool
        }
        let body = Body(caption: p.caption, lyrics: p.lyrics, duration: min(duration, 480), language: language,
                        style: pcStyle, style_scale: adapterScale, seed: lockSeed ? Int64(seedText) ?? -1 : -1,
                        simple: mode == .simple && !instrumental)
        begin("Sending to \(pcName)")

        remoteTask = Task {
            defer { end() }
            do {
                var job = try await client.call("POST", "/api/generate", body: body, as: RemoteJob.self)
                while job.status != "done" && job.status != "failed" {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if cancelFlag.get() { return }
                    job = try await client.get("/api/jobs/\(job.id)", as: RemoteJob.self)
                    statusText = job.message.isEmpty ? job.status.capitalized : job.message
                    // ACE-Step doesn't report fine progress; estimate from typical turbo speed on a 3080 Ti.
                    let expected = max(20, job.duration * 0.6)
                    progress = min(0.95, Double(job.elapsed) / expected)
                }
                if job.status == "failed" {
                    throw HubError.server(job.message.isEmpty ? "Generation failed on the PC" : job.message)
                }
                statusText = "Downloading"
                let (out, fileName) = library.newFileURL(title: p.title, ext: "mp3")
                try await client.download("/api/jobs/\(job.id)/audio", to: out)
                let m = job.meta
                let song = Song(
                    id: UUID(), title: p.title, caption: p.caption, lyrics: m?.lyrics ?? p.lyrics, adapter: pcStyle,
                    seed: m?.seed ?? -1, bpm: m?.bpm ?? 0, key: m?.key ?? "",
                    duration: m?.duration ?? job.duration, created: Date(), fileName: fileName, madeOn: pcName,
                    model: "ACE-Step 1.5 (PC)", prompt: mode == .simple ? songDescription : style)
                library.add(song)
                lastSong = song
                if let s = m?.seed { seedText = String(s) }
                progress = 1
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: memory test (Settings)

    @Published private(set) var testing = false
    @Published private(set) var testResult: String?

    /// Renders a 20-second instrumental with the current models and reports peak memory per stage.
    func runMemoryTest(models: ModelManager) {
        guard !running, !testing, let paths = models.paths else { return }
        testing = true
        testResult = nil
        statusText = "Starting"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("memory-test.wav")
        let request = SongRequest(caption: "calm piano and soft drums", lyrics: "[Instrumental]", language: "",
                                  duration: 20, bpm: 90, seed: 42, adapter: nil, adapterScale: 1)
        let options = models.engineOptions
        let started = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            defer {
                testing = false
                UIApplication.shared.isIdleTimerDisabled = false
                try? FileManager.default.removeItem(at: out)
            }
            do {
                let r = try await SongEngine.shared.generate(
                    request, models: paths, options: options, output: out,
                    onProgress: { [weak self] s, _ in Task { @MainActor in self?.statusText = s.label } },
                    isCancelled: { false })
                guard let r else { return }
                models.recordPeaks(r.peakBytes)
                let peak = r.peakBytes.max() ?? 0
                let secs = Int(Date().timeIntervalSince(started))
                testResult = String(format: "Passed in %lds. Peak %@ of %.1f GB available (%@, %@).",
                                    secs, ByteCountFormatter.string(fromByteCount: Int64(peak), countStyle: .memory),
                                    Device.budgetGB, options.lowMemory ? "Lite" : "Full", options.useCPU ? "CPU" : "GPU")
            } catch {
                testResult = "Failed: \(error.localizedDescription)"
            }
        }
    }

    /// Cancel stops the iPhone engine; for PC jobs it stops waiting (the PC finishes the song anyway).
    func cancel() {
        cancelFlag.set(true)
        remoteTask?.cancel()
    }

    /// Load a song's settings back into the form ("Reuse prompt").
    func reuse(_ song: Song) {
        if mode == .simple, let p = song.prompt, !p.isEmpty {
            songDescription = p
        } else {
            mode = .custom
            style = song.caption
            lyrics = song.lyrics == "[Instrumental]" ? "" : song.lyrics
        }
        instrumental = song.lyrics == "[Instrumental]"
        duration = song.duration
    }
}

/// Tiny thread-safe Bool the engine thread polls.
final class LockedFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
