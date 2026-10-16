import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var gen: Generator

    var body: some View {
        NavigationStack {
            Group {
                if library.songs.isEmpty {
                    ContentUnavailableCompat(
                        title: "No songs yet",
                        systemImage: "music.note",
                        message: "Songs you generate show up here and in the Files app under Signature.")
                } else {
                    List {
                        ForEach(library.songs) { song in
                            row(song)
                        }
                        .onDelete { idx in
                            idx.map { library.songs[$0] }.forEach {
                                if player.current == $0.id { player.stop() }
                                library.delete($0)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
        }
    }

    private func row(_ song: Song) -> some View {
        HStack(spacing: 12) {
            Button {
                player.toggle(song, url: library.url(for: song))
            } label: {
                Image(systemName: player.current == song.id ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.headline).lineLimit(1)
                Text(details(song)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ShareLink(item: library.url(for: song)) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
        }
        .contextMenu {
            Button("Remix with same settings") {
                gen.style = song.caption
                gen.lyrics = song.lyrics == "[Instrumental]" ? "" : song.lyrics
                gen.instrumental = song.lyrics == "[Instrumental]"
                gen.duration = song.duration
            }
            Button("Reuse seed \(String(song.seed))") {
                gen.lockSeed = true
                gen.seedText = String(song.seed)
            }
        }
    }

    private func details(_ s: Song) -> String {
        var parts = [CreateView.time(s.duration)]
        if s.bpm > 0 { parts.append("\(s.bpm) BPM") }
        if !s.key.isEmpty { parts.append(s.key) }
        if let a = s.adapter { parts.append(a) }
        return parts.joined(separator: " · ")
    }
}

/// ContentUnavailableView is iOS 17+; this works on 16.
struct ContentUnavailableCompat: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
