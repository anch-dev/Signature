import AVFoundation
import SwiftUI

@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var song: Song?
    @Published private(set) var isPlaying = false
    @Published var time: Double = 0
    @Published private(set) var length: Double = 0
    private var audio: AVAudioPlayer?
    private var timer: Timer?

    var current: Song.ID? { song?.id }

    func play(_ s: Song, library: Library) {
        if song?.id == s.id {
            toggle()
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let a = try AVAudioPlayer(contentsOf: library.url(for: s))
            a.delegate = self
            a.prepareToPlay()
            a.play()
            audio = a
            song = s
            length = a.duration
            time = 0
            isPlaying = true
            startTimer()
        } catch {
            stop()
        }
    }

    func toggle() {
        guard let a = audio else { return }
        if a.isPlaying { a.pause() } else { a.play() }
        isPlaying = a.isPlaying
    }

    func seek(_ t: Double) {
        audio?.currentTime = t
        time = t
    }

    func stop() {
        audio?.stop()
        audio = nil
        song = nil
        isPlaying = false
        timer?.invalidate()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let a = self.audio else { return }
                self.time = a.currentTime
                self.isPlaying = a.isPlaying
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.time = 0
        }
    }
}

/// Compact bar above the tab bar, like Suno's.
struct MiniPlayer: View {
    @EnvironmentObject var player: Player
    @State private var expanded = false

    var body: some View {
        if let s = player.song {
            VStack(spacing: 0) {
                GeometryReader { g in
                    Rectangle().fill(Theme.gradient)
                        .frame(width: g.size.width * (player.length > 0 ? player.time / player.length : 0), height: 2)
                }
                .frame(height: 2)
                HStack(spacing: 12) {
                    SongArt(seed: s.id.uuidString, size: 40, playing: player.isPlaying)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(s.caption).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer()
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                            .frame(width: 40, height: 40)
                    }
                    Button { player.stop() } label: {
                        Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 32, height: 40)
                    }
                    .foregroundStyle(Theme.muted)
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(Theme.cardHi)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .onTapGesture { expanded = true }
            .sheet(isPresented: $expanded) { NowPlayingView() }
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var gen: Generator
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let s = player.song {
            ScrollView {
                VStack(spacing: 20) {
                    Capsule().fill(Theme.faint).frame(width: 40, height: 5).padding(.top, 8)
                    SongArt(seed: s.id.uuidString, size: 280, playing: player.isPlaying)
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
                    VStack(spacing: 4) {
                        Text(s.title).font(.title2.bold()).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                        Text(s.caption).font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineLimit(3)
                    }
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { player.time }, set: { player.seek($0) }),
                               in: 0...max(player.length, 1)).tint(Theme.text)
                        HStack {
                            Text(CreateView.time(player.time))
                            Spacer()
                            Text(CreateView.time(player.length))
                        }
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    HStack(spacing: 40) {
                        Button { player.seek(max(0, player.time - 10)) } label: { Image(systemName: "gobackward.10") }
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
                        }
                        Button { player.seek(min(player.length, player.time + 10)) } label: { Image(systemName: "goforward.10") }
                    }
                    .font(.title).foregroundStyle(Theme.text)
                    HStack(spacing: 10) {
                        ShareLink(item: library.url(for: s)) {
                            Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        Button {
                            gen.reuse(s)
                            dismiss()
                        } label: {
                            Label("Reuse", systemImage: "arrow.uturn.left").frame(maxWidth: .infinity)
                        }
                        Button {
                            FilesApp.reveal(library.url(for: s))
                        } label: {
                            Label("Files", systemImage: "folder").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered).tint(Theme.text)
                    Button {
                        gen.prepareCover(source: library.url(for: s), name: s.title, duration: s.duration,
                                         caption: s.caption, lyrics: s.lyrics)
                        dismiss()
                    } label: {
                        Label("Cover / Remix this song", systemImage: "wand.and.stars").font(.headline)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Capsule().fill(Theme.gradient)).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    promptCard(s)
                    details(s)
                    if s.lyrics != "[Instrumental]", !s.lyrics.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Lyrics")
                            Text(s.lyrics).font(.body).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .card()
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 30)
            }
            .screen()
            .presentationDragIndicator(.hidden)
        }
    }

    @ViewBuilder private func promptCard(_ s: Song) -> some View {
        let typed = (s.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Your prompt")
                Text(typed).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                let added = Self.addition(typed: typed, used: s.caption)
                if !added.isEmpty {
                    SectionLabel("Songwriter added")
                    Text(added).font(.callout).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .card()
        }
    }

    /// The part of the final caption that came from the songwriter.
    static func addition(typed: String, used: String) -> String {
        let u = used.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, u.lowercased() != typed.lowercased() else { return "" }
        if let r = u.range(of: typed, options: [.caseInsensitive, .anchored]) {
            return u[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ".,; ").union(.whitespaces))
        }
        return u
    }

    private func details(_ s: Song) -> some View {
        let items: [(String, String)] = [
            ("Model", s.model ?? "ACE-Step 1.5"),
            ("Made on", s.madeOn ?? "iPhone"),
            ("Style", s.adapter ?? "Base"),
            ("BPM", s.bpm > 0 ? "\(s.bpm)" : "—"),
            ("Key", s.key.isEmpty ? "—" : s.key),
            ("Seed", s.seed >= 0 ? "\(s.seed)" : "—"),
        ]
        return VStack(spacing: 8) {
            ForEach(items, id: \.0) { k, v in
                HStack { Text(k).foregroundStyle(Theme.muted); Spacer(); Text(v).foregroundStyle(Theme.text) }
                    .font(.subheadline)
            }
        }
        .card()
    }
}

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var gen: Generator
    @State private var query = ""

    private var filtered: [Song] {
        guard !query.isEmpty else { return library.songs }
        let q = query.lowercased()
        return library.songs.filter { $0.title.lowercased().contains(q) || $0.caption.lowercased().contains(q) || $0.lyrics.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.songs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list").font(.system(size: 44)).foregroundStyle(Theme.faint)
                        Text("No songs yet").font(.title3.bold()).foregroundStyle(Theme.text)
                        Text("Songs you create show up here and in Files → Signature.")
                            .multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered) { s in
                            SongRow(song: s, playing: player.current == s.id && player.isPlaying)
                                .onTapGesture { player.play(s, library: library) }
                                .listRowBackground(Color.clear)
                                .listRowSeparatorTint(Theme.stroke)
                                .contextMenu {
                                    ShareLink(item: library.url(for: s)) { Label("Share", systemImage: "square.and.arrow.up") }
                                    Button { FilesApp.reveal(library.url(for: s)) } label: { Label("Show in Files", systemImage: "folder") }
                                    Button { gen.reuse(s) } label: { Label("Reuse prompt", systemImage: "arrow.uturn.left") }
                                    Button {
                                        gen.prepareCover(source: library.url(for: s), name: s.title, duration: s.duration,
                                                         caption: s.caption, lyrics: s.lyrics)
                                    } label: { Label("Cover / Remix", systemImage: "wand.and.stars") }
                                    Button {
                                        gen.lockSeed = true
                                        gen.seedText = String(s.seed)
                                    } label: { Label("Reuse seed", systemImage: "dice") }
                                    Button(role: .destructive) { delete(s) } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                        .onDelete { idx in idx.map { filtered[$0] }.forEach(delete) }
                    }
                    .listStyle(.plain)
                    .searchable(text: $query, prompt: "Search songs and lyrics")
                    .toolbar {
                        Button { FilesApp.reveal(library.songsDir.appendingPathComponent("x")) } label: {
                            Image(systemName: "folder")
                        }
                        .accessibilityLabel("Open Songs folder in Files")
                    }
                }
            }
            .screen()
            .navigationTitle("Library")
        }
    }

    private func delete(_ s: Song) {
        if player.current == s.id { player.stop() }
        library.delete(s)
    }
}
