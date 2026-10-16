import AVFoundation
import SwiftUI

@main
struct SignatureApp: App {
    @StateObject private var models = ModelManager()
    @StateObject private var library = Library()
    @StateObject private var adapters = AdapterStore()
    @StateObject private var generator = Generator()
    @StateObject private var player = Player()
    @State private var tab = 0

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                CreateView()
                    .tabItem { Label("Create", systemImage: "waveform") }
                    .tag(0)
                LibraryView()
                    .tabItem { Label("Library", systemImage: "music.note.list") }
                    .tag(1)
                SetupView()
                    .tabItem { Label("Models", systemImage: "square.and.arrow.down") }
                    .tag(2)
            }
            .environmentObject(models)
            .environmentObject(library)
            .environmentObject(adapters)
            .environmentObject(generator)
            .environmentObject(player)
            .onAppear { if !models.isReady { tab = 2 } }
            .onOpenURL { url in
                // A .safetensors shared via AirDrop / Files "Open in Signature".
                if let added = adapters.importFile(url) {
                    generator.adapter = added
                    tab = 0
                }
            }
        }
    }
}

@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var current: Song.ID?
    private var audio: AVAudioPlayer?

    func toggle(_ song: Song, url: URL) {
        if current == song.id {
            stop()
            return
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            audio = try AVAudioPlayer(contentsOf: url)
            audio?.delegate = self
            audio?.play()
            current = song.id
        } catch {
            current = nil
        }
    }

    func stop() {
        audio?.stop()
        audio = nil
        current = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.current = nil }
    }
}
