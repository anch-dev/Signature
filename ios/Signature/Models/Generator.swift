import Foundation
import UIKit

enum GenTarget: String, CaseIterable, Identifiable {
    case phone, pc
    var id: String { rawValue }
}

enum CreateMode: String, CaseIterable, Identifiable {
    case simple, custom, cover
    var id: String { rawValue }
    var title: String {
        switch self {
        case .simple: return "Simple"
        case .custom: return "Custom"
        case .cover: return "Cover"
        }
    }
}

enum CoverTask: String, CaseIterable, Identifiable {
    case cover, repaint
    var id: String { rawValue }
    var title: String { self == .cover ? "Cover / Remix" : "Repaint section" }
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
    // Cover / remix / repaint
    @Published var coverSource: URL?
    @Published var coverSourceName = ""
    @Published var coverSourceDuration: Double = 0
    @Published var coverTask: CoverTask = .cover
    @Published var coverStrength: Double = 0.7     // how much of the original's structure to keep
    @Published var repaintStart: Double = 0
    @Published var repaintEnd: Double = 30
    /// Set when another screen wants the Create tab shown (e.g. "Cover" from the player).
    @Published var showCreate = false

    /// Songwriter adds detail to the style prompt (your words stay first; off-topic additions are dropped).
    @Published var enhancePrompt: Bool = UserDefaults.standard.object(forKey: "enhancePrompt") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enhancePrompt, forKey: "enhancePrompt") }
    }

    @Published var target: GenTarget = GenTarget(rawValue: UserDefaults.standard.string(forKey: "target") ?? "") ?? .phone {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: "target") }
    }

    @Published private(set) var running = false
    @Published private(set) var stage: GenStage = .songwriter
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = ""
    @Published private(set) var startedAt: Date?
    /// Estimated seconds remaining (nil until there's enough signal).
    @Published private(set) var eta: Double?
    private var etaKey = ""
    private var etaGuess: Double?
    @Published var error: String?
    @Published var lastSong: Song?

    /// Set at launch if the previous song never finished (iOS killed the app, usually for memory).
    @Published var crashNotice: String?
    private static let inFlightKey = "inFlightGeneration"

    init() {
        if let last = UserDefaults.standard.string(forKey: Self.inFlightKey) {
            crashNotice = "Signature closed while making a song (\(last)). That usually means it ran out of memory. Try the Compact size of this model, turn on Lite in Settings, or make a shorter song. The log in Files → Signature → Logs has the details."
            LogCapture.shared.log("Previous run ended unexpectedly during: \(last)")
            UserDefaults.standard.removeObject(forKey: Self.inFlightKey)
        }
    }

    private func markInFlight(_ text: String?) {
        if let text { UserDefaults.standard.set(text, forKey: Self.inFlightKey) } else { UserDefaults.standard.removeObject(forKey: Self.inFlightKey) }
    }

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
        case .cover:
            guard coverSource != nil else {
                error = "Pick a song to cover first."
                return nil
            }
            let s = style.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else {
                error = "Describe the new style, e.g. \"acoustic guitar, soft female vocal\"."
                return nil
            }
            let words = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = coverSourceName.isEmpty ? "Song" : coverSourceName
            let t = title.isEmpty ? "\(base) (\(coverTask == .cover ? "Cover" : "Repaint"))" : title
            return Prepared(caption: trigger.isEmpty || s.lowercased().contains(trigger.dropLast(2).lowercased()) ? s : trigger + s,
                            lyrics: instrumental || words.isEmpty ? "[Instrumental]" : words, title: t)
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

    /// Seconds of work per second of audio from the last run with this setup.
    private func historyRate(_ key: String) -> Double? {
        let v = UserDefaults.standard.double(forKey: "rate." + key)
        return v > 0 ? v : nil
    }

    private func saveRate(_ key: String, audioSeconds: Double) {
        guard let start = startedAt, audioSeconds > 0 else { return }
        let rate = Date().timeIntervalSince(start) / audioSeconds
        let old = historyRate(key)
        UserDefaults.standard.set(old.map { $0 * 0.4 + rate * 0.6 } ?? rate, forKey: "rate." + key)
    }

    /// Blend the history-based guess with the live rate as progress accumulates.
    private func updateETA() {
        guard let start = startedAt else { eta = nil; return }
        let elapsed = Date().timeIntervalSince(start)
        var live: Double?
        if progress > 0.04 { live = max(0, elapsed / progress - elapsed) }
        let guess = etaGuess.map { max(0, $0 - elapsed) }
        let next: Double?
        switch (live, guess) {
        case let (l?, g?):
            let w = min(1, progress / 0.5)          // trust the live rate more as we go
            next = l * w + g * (1 - w)
        case let (l?, nil): next = l
        case let (nil, g?): next = g
        default: next = nil
        }
        if let n = next, let old = eta { eta = old * 0.7 + n * 0.3 } else { eta = next }
    }

    var etaText: String? {
        guard let e = eta, running else { return nil }
        if e < 5 { return "almost done" }
        let s = Int(e.rounded())
        return s >= 60 ? "~\(s / 60):\(String(format: "%02d", s % 60)) left" : "~\(s)s left"
    }

    private func begin(_ text: String) {
        error = nil
        running = true
        eta = nil
        progress = 0
        statusText = text
        startedAt = Date()
        cancelFlag.set(false)
    }

    private func end() {
        markInFlight(nil)
        running = false
        startedAt = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: on the iPhone

    func start(models: ModelManager, library: Library) {
        guard !running else { return }
        guard let paths = models.paths(forceSongwriter: mode == .simple) else {
            error = "Download the models first."
            return
        }
        guard let p = prepare(songwriterAvailable: paths.songwriter != nil) else { return }
        let request = SongRequest(
            caption: p.caption, lyrics: p.lyrics, language: language,
            duration: min(duration, models.maxDuration), bpm: 0,
            seed: lockSeed ? Int64(seedText) ?? -1 : -1,
            adapter: adapter, adapterScale: Float(adapterScale),
            source: mode == .cover ? coverSource : nil,
            task: mode == .cover ? (coverTask == .cover ? 1 : 2) : 0,
            coverStrength: Float(coverStrength), coverNoise: 0,
            repaintStart: Float(repaintStart), repaintEnd: Float(repaintEnd))
        var req = request
        req.enhancePrompt = enhancePrompt && mode != .cover
        let options = models.engineOptions
        let modelName = models.music.name

        let (out, fileName) = library.newFileURL(title: p.title)
        let usesWriter = paths.songwriter != nil && mode != .cover
        etaKey = "\(models.musicID).\(models.musicQuant.rawValue).\(usesWriter).\(options.lowMemory).\(options.useCPU)"
        begin(usesWriter ? GenStage.songwriter.label : GenStage.diffusion.label)
        stage = usesWriter ? .songwriter : .diffusion
        etaGuess = historyRate(etaKey).map { $0 * request.duration }
        let inFlightBase = "\(modelName) \(models.musicQuant.label), \(Int(request.duration))s"
        markInFlight("\(inFlightBase), \(stage.label.lowercased())")
        LogCapture.shared.debug("Request: caption=\"\(request.caption)\" lyrics=\(request.lyrics.isEmpty ? "(songwriter writes)" : "\(request.lyrics.count) chars") language=\(request.language.isEmpty ? "auto" : request.language) seed=\(request.seed) style=\(styleName ?? "base") scale=\(request.adapterScale) task=\(request.task)")
        LogCapture.shared.debug("Device: memory budget \(String(format: "%.2f", Device.budgetGB)) GB, max length \(Int(models.maxDuration))s, ETA guess \(etaGuess.map { "\(Int($0))s" } ?? "none")")
        updateETA()
        LogCapture.shared.log("Start: \(modelName), \(mode.title), \(Int(request.duration))s, \(options.useCPU ? "CPU" : "GPU")\(options.lowMemory ? ", Lite" : "")")
        UIApplication.shared.isIdleTimerDisabled = true  // screen lock suspends GPU work

        let flag = cancelFlag
        Task {
            defer { end() }
            do {
                let result = try await SongEngine.shared.generate(
                    req, models: paths, options: options, output: out,
                    onProgress: { [weak self] s, value in
                        Task { @MainActor in
                            guard let self else { return }
                            self.stage = s
                            self.statusText = s.label
                            if s != self.stage {
                                LogCapture.shared.debug("Stage: \(s.label) at \(Int(value * 100))%")
                                self.markInFlight("\(inFlightBase), \(s.label.lowercased())")
                            }
                            self.progress = max(self.progress, value)
                            self.updateETA()
                        }
                    },
                    isCancelled: { flag.get() })
                guard let result else {
                    try? FileManager.default.removeItem(at: out)
                    return
                }
                models.recordPeaks(result.peakBytes)
                saveRate(etaKey, audioSeconds: request.duration)
                let song = Song(
                    id: UUID(), title: p.title, caption: result.caption.isEmpty ? p.caption : result.caption,
                    lyrics: result.lyrics.isEmpty ? request.lyrics : result.lyrics,
                    adapter: styleName, seed: result.seed, bpm: result.bpm,
                    key: result.key, duration: result.duration, created: Date(), fileName: fileName,
                    madeOn: "iPhone", model: modelName, prompt: mode == .simple ? songDescription : style)
                LogCapture.shared.log("Done: \(p.title), peak \(ByteCountFormatter.string(fromByteCount: Int64(result.peakBytes.max() ?? 0), countStyle: .memory))")
                library.add(song)
                lastSong = song
                seedText = String(result.seed)
            } catch {
                try? FileManager.default.removeItem(at: out)
                self.error = error.localizedDescription
                LogCapture.shared.log("Failed: \(error.localizedDescription)")
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
            let style: String?; let style_scale: Double; let seed: Int64; let simple: Bool; let enhance: Bool
            var source: String?; let task: String; let cover_strength: Double
            let repaint_start: Double; let repaint_end: Double
        }
        let body = Body(caption: p.caption, lyrics: p.lyrics, duration: min(duration, 480), language: language,
                        style: pcStyle, style_scale: adapterScale, seed: lockSeed ? Int64(seedText) ?? -1 : -1,
                        simple: mode == .simple && !instrumental, enhance: enhancePrompt && mode != .cover, source: nil,
                        task: mode == .cover ? coverTask.rawValue : "new", cover_strength: coverStrength,
                        repaint_start: repaintStart, repaint_end: repaintEnd)
        let source = mode == .cover ? coverSource : nil
        begin("Sending to \(pcName)")

        remoteTask = Task {
            defer { end() }
            do {
                var request = body
                if let source {
                    statusText = "Uploading source"
                    struct Uploaded: Decodable { let id: String }
                    request.source = try await client.upload(source: source, as: Uploaded.self).id
                }
                var job = try await client.call("POST", "/api/generate", body: request, as: RemoteJob.self)
                while job.status != "done" && job.status != "failed" {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if cancelFlag.get() { return }
                    job = try await client.get("/api/jobs/\(job.id)", as: RemoteJob.self)
                    statusText = job.message.isEmpty ? job.status.capitalized : job.message
                    // ACE-Step doesn't report fine progress; estimate from typical turbo speed on a 3080 Ti.
                    let expected = max(20, job.duration * 0.6)
                    progress = min(0.95, Double(job.elapsed) / expected)
                    eta = max(3, expected - Double(job.elapsed))
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

    /// Start a cover / remix of a Library song or an audio file.
    func prepareCover(source: URL, name: String, duration: Double, caption: String? = nil, lyrics songLyrics: String? = nil) {
        mode = .cover
        coverSource = source
        coverSourceName = name
        coverSourceDuration = duration
        repaintStart = 0
        repaintEnd = min(duration, 30)
        if let l = songLyrics, l != "[Instrumental]" { lyrics = l; instrumental = false }
        if songLyrics == "[Instrumental]" { instrumental = true }
        if style.isEmpty, let c = caption { style = c }
        title = ""
        showCreate = true
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
