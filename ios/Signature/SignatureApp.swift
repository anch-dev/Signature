import AVFoundation
import SwiftUI

@main
struct SignatureApp: App {
    @StateObject private var models = ModelManager()
    @StateObject private var library = Library()
    @StateObject private var adapters = AdapterStore()
    @StateObject private var generator = Generator()
    @StateObject private var player = Player()
    @StateObject private var hub = HubStore()
    @Environment(\.scenePhase) private var phase
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
                PCView()
                    .tabItem { Label("PC", systemImage: "desktopcomputer") }
                    .tag(2)
                SetupView()
                    .tabItem { Label("Models", systemImage: "square.and.arrow.down") }
                    .tag(3)
            }
            .environmentObject(models)
            .environmentObject(library)
            .environmentObject(adapters)
            .environmentObject(generator)
            .environmentObject(player)
            .environmentObject(hub)
            .onAppear {
                if !models.isReady && !hub.isPaired { tab = 3 }
            }
            .onOpenURL { url in
                if url.scheme == "signature" {
                    // Pairing QR from the Hub dashboard, scanned with the Camera app.
                    if hub.handlePairLink(url) { tab = 2 }
                } else if let added = adapters.importFile(url) {
                    // A .safetensors shared via AirDrop / Files "Open in Signature".
                    generator.adapter = added
                    generator.target = .phone
                    tab = 0
                }
            }
            .onChange(of: phase) { p in
                if p == .active { hub.startPolling() } else if p == .background { hub.stopPolling() }
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
