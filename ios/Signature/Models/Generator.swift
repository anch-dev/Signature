import Foundation
import os
import UIKit

@MainActor
final class Generator: ObservableObject {
    @Published var style = ""
    @Published var lyrics = ""
    @Published var instrumental = false
    @Published var duration: Double = 90
    @Published var language = ""
    @Published var adapter: URL?
    @Published var adapterScale: Double = 1.0
    @Published var useSongwriter = true
    @Published var lockSeed = false
    @Published var seedText = ""

    @Published private(set) var running = false
    @Published private(set) var stage: GenStage = .songwriter
    @Published private(set) var progress: Double = 0
    @Published private(set) var startedAt: Date?
    @Published var error: String?
    @Published var lastSong: Song?

    private let cancelFlag = OSAllocatedUnfairLockBox()

    /// Longest song this device can render without being killed for memory.
    /// Only one network is loaded at a time, but the VAE decode and the
    /// songwriter's KV cache still grow with length.
    let maxDuration: Double = {
        let gb = Double(os_proc_available_memory()) / 1_073_741_824
        if gb >= 4.5 { return 240 }
        if gb >= 3.0 { return 150 }
        return 60
    }()

    var availableMemoryText: String {
        ByteCountFormatter.string(fromByteCount: Int64(os_proc_available_memory()), countStyle: .memory)
    }

    func start(models: ModelPaths, library: Library) {
        guard !running else { return }
        let caption = style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caption.isEmpty else {
            error = "Describe a style first, e.g. \"melodic trap, 808s, male vocal\"."
            return
        }
        let words = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = SongRequest(
            caption: caption,
            lyrics: instrumental || words.isEmpty ? "[Instrumental]" : words,
            language: language,
            duration: min(duration, maxDuration),
            bpm: 0,
            seed: lockSeed ? Int64(seedText) ?? -1 : -1,
            adapter: adapter,
            adapterScale: Float(adapterScale))
        var paths = models
        if !useSongwriter { paths.songwriter = nil }

        let title = String(caption.prefix(32))
        let (out, fileName) = library.newFileURL(title: title)

        error = nil
        running = true
        progress = 0
        stage = useSongwriter ? .songwriter : .diffusion
        startedAt = Date()
        cancelFlag.set(false)
        UIApplication.shared.isIdleTimerDisabled = true  // screen lock suspends Metal work

        let flag = cancelFlag
        Task {
            defer {
                running = false
                startedAt = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
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
                    id: UUID(), title: title, caption: caption, lyrics: request.lyrics,
                    adapter: adapter.map(AdapterStore.name), seed: result.seed, bpm: result.bpm,
                    key: result.key, duration: result.duration, created: Date(), fileName: fileName)
                library.add(song)
                lastSong = song
                seedText = String(result.seed)
            } catch {
                try? FileManager.default.removeItem(at: out)
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() { cancelFlag.set(true) }
}

/// Tiny thread-safe Bool the engine thread polls.
final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
