import Foundation
import os
import UIKit

enum GenTarget: String, CaseIterable, Identifiable {
    case phone, pc
    var id: String { rawValue }
}

@MainActor
final class Generator: ObservableObject {
    @Published var style = ""
    @Published var lyrics = ""
    @Published var instrumental = false
    @Published var duration: Double = 60
    @Published var language = ""
    @Published var adapter: URL?            // phone style (.safetensors on this iPhone)
    @Published var pcStyle: String?         // PC style (by name, lives on the Hub)
    @Published var adapterScale: Double = 1.0
    @Published var useSongwriter = true
    @Published var lockSeed = false
    @Published var seedText = ""
    @Published var target: GenTarget = GenTarget(rawValue: UserDefaults.standard.string(forKey: "target") ?? "") ?? .phone {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: "target") }
    }

    @Published private(set) var running = false
    @Published private(set) var stage: GenStage = .songwriter
    @Published private(set) var progress: Double = 0
    @Published private(set) var remoteMessage = ""
    @Published private(set) var startedAt: Date?
    @Published var error: String?
    @Published var lastSong: Song?

    private let cancelFlag = LockedFlag()
    private var remoteTask: Task<Void, Never>?

    /// Longest song this iPhone can render without being killed for memory.
    /// Only one network is loaded at a time, but the VAE decode and the
    /// songwriter's KV cache still grow with length.
    let maxDuration: Double = {
        let gb = Double(os_proc_available_memory()) / 1_073_741_824
        if gb >= 4.5 { return 240 }
        if gb >= 3.0 { return 150 }
        return 60
    }()

    /// The PC isn't memory-bound the same way; ACE-Step allows up to 10 minutes.
    var durationLimit: Double { target == .pc ? 480 : maxDuration }

    var availableMemoryText: String {
        ByteCountFormatter.string(fromByteCount: Int64(os_proc_available_memory()), countStyle: .memory)
    }

    private func validated() -> (caption: String, lyrics: String)? {
        let caption = style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caption.isEmpty else {
            error = "Describe a style first, e.g. \"melodic trap, 808s, male vocal\"."
            return nil
        }
        let words = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        return (caption, instrumental || words.isEmpty ? "[Instrumental]" : words)
    }

    private func begin() {
        error = nil
        running = true
        progress = 0
        remoteMessage = ""
        startedAt = Date()
        cancelFlag.set(false)
    }

    private func end() {
        running = false
        startedAt = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: on the iPhone

    func start(models: ModelPaths, library: Library) {
        guard !running, let v = validated() else { return }
        let request = SongRequest(
            caption: v.caption, lyrics: v.lyrics, language: language,
            duration: min(duration, maxDuration), bpm: 0,
            seed: lockSeed ? Int64(seedText) ?? -1 : -1,
            adapter: adapter, adapterScale: Float(adapterScale))
        var paths = models
        if !useSongwriter { paths.songwriter = nil }

        let title = String(v.caption.prefix(32))
        let (out, fileName) = library.newFileURL(title: title)
        begin()
        stage = useSongwriter ? .songwriter : .diffusion
        UIApplication.shared.isIdleTimerDisabled = true  // screen lock suspends Metal work

        let flag = cancelFlag
        Task {
            defer { end() }
            do {
                let result = try await SongEngine.shared.generate(
                    request, models: paths, output: out,
                    onProgress: { [weak self] s, p in
                        Task { @MainActor in
                            self?.stage = s
                            self?.progress = max(self?.progress ?? 0, p)
                        }
                    },
                    isCancelled: { flag.get() })
                guard let result else {
                    try? FileManager.default.removeItem(at: out)
                    return
                }
                let song = Song(
                    id: UUID(), title: title, caption: v.caption, lyrics: request.lyrics,
                    adapter: adapter.map(AdapterStore.name), seed: result.seed, bpm: result.bpm,
                    key: result.key, duration: result.duration, created: Date(), fileName: fileName,
                    madeOn: "iPhone")
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
        guard !running, let v = validated(), let client = hub.client, let pcName = hub.pairing?.name else {
            if hub.client == nil { error = HubError.notPaired.localizedDescription }
            return
        }
        struct Body: Encodable {
            let caption: String; let lyrics: String; let duration: Double; let language: String
            let style: String?; let style_scale: Double; let seed: Int64
        }
        let body = Body(caption: v.caption, lyrics: v.lyrics, duration: min(duration, 480), language: language,
                        style: pcStyle, style_scale: adapterScale, seed: lockSeed ? Int64(seedText) ?? -1 : -1)
        let title = String(v.caption.prefix(32))
        begin()
        remoteMessage = "Sending to \(pcName)"

        remoteTask = Task {
            defer { end() }
            do {
                var job = try await client.call("POST", "/api/generate", body: body, as: RemoteJob.self)
                while job.status != "done" && job.status != "failed" {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if cancelFlag.get() { return }
                    job = try await client.get("/api/jobs/\(job.id)", as: RemoteJob.self)
                    remoteMessage = job.message.isEmpty ? job.status.capitalized : job.message
                    // ACE-Step doesn't report fine progress; estimate from typical turbo speed on a 3080 Ti.
                    let expected = max(20, job.duration * 0.6)
                    progress = min(0.95, Double(job.elapsed) / expected)
                }
                if job.status == "failed" {
                    throw HubError.server(job.message.isEmpty ? "Generation failed on the PC" : job.message)
                }
                remoteMessage = "Downloading"
                let (out, fileName) = library.newFileURL(title: title, ext: "mp3")
                try await client.download("/api/jobs/\(job.id)/audio", to: out)
                let m = job.meta
                let song = Song(
                    id: UUID(), title: title, caption: v.caption, lyrics: v.lyrics, adapter: pcStyle,
                    seed: m?.seed ?? -1, bpm: m?.bpm ?? 0, key: m?.key ?? "",
                    duration: m?.duration ?? job.duration, created: Date(), fileName: fileName, madeOn: pcName)
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

    /// Cancel stops the iPhone engine; for PC jobs it stops waiting (the PC finishes the song anyway).
    func cancel() {
        cancelFlag.set(true)
        remoteTask?.cancel()
    }
}

/// Tiny thread-safe Bool the engine thread polls.
final class LockedFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
