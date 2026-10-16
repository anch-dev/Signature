import Foundation

struct Song: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var caption: String
    var lyrics: String
    var adapter: String?
    var seed: Int64
    var bpm: Int
    var key: String
    var duration: Double
    var created: Date
    var fileName: String
    var madeOn: String?   // "iPhone" or the PC's name
    var model: String?    // model display name
    var prompt: String?   // the description / style typed in
}

/// Generated songs live in Documents/Songs (visible in the Files app) with a JSON index.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var songs: [Song] = []

    let songsDir: URL
    private let index: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        songsDir = docs.appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: songsDir, withIntermediateDirectories: true)
        index = songsDir.appendingPathComponent(".library.json")
        load()
    }

    func url(for song: Song) -> URL { songsDir.appendingPathComponent(song.fileName) }

    func newFileURL(title: String, ext: String = "wav") -> (URL, String) {
        let safe = title.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined().trimmingCharacters(in: .whitespaces)
        let base = (safe.isEmpty ? "Song" : String(safe.prefix(40)))
        var name = "\(base).\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: songsDir.appendingPathComponent(name).path) {
            name = "\(base) \(n).\(ext)"
            n += 1
        }
        return (songsDir.appendingPathComponent(name), name)
    }

    func add(_ song: Song) {
        songs.insert(song, at: 0)
        save()
    }

    func delete(_ song: Song) {
        try? FileManager.default.removeItem(at: url(for: song))
        songs.removeAll { $0.id == song.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: index),
              let list = try? JSONDecoder().decode([Song].self, from: data) else { return }
        songs = list.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(songs) {
            try? data.write(to: index, options: .atomic)
        }
    }
}

/// Style adapters (.safetensors from the PC trainer) imported via AirDrop, Files or the picker.
@MainActor
final class AdapterStore: ObservableObject {
    @Published private(set) var adapters: [URL] = []
    @Published var importMessage: String?

    let dir: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = support.appendingPathComponent("adapters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        adapters = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    func importFile(_ src: URL) -> URL? {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        guard src.pathExtension.lowercased() == "safetensors" else {
            importMessage = "That isn't a .safetensors style file."
            return nil
        }
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)
            refresh()
            importMessage = "Added style \"\(Self.name(dest))\"."
            return dest
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
            return nil
        }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }

    /// The trainer exports <trigger>.safetensors, so the file name is the trigger word.
    static func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
}
