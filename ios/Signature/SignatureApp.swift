import AVFoundation
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iOS relaunches the app in the background when model downloads finish.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == BackgroundDownloader.identifier {
            BackgroundDownloader.shared.backgroundCompletion = completionHandler
        } else {
            completionHandler()
        }
    }
}

@main
struct SignatureApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
        let bar = UITabBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = UIColor(Theme.bg)
        UITabBar.appearance().standardAppearance = bar
        UITabBar.appearance().scrollEdgeAppearance = bar
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Theme.bg)
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                CreateView().withMiniPlayer()
                    .tabItem { Label("Create", systemImage: "sparkles") }
                    .tag(0)
                LibraryView().withMiniPlayer()
                    .tabItem { Label("Library", systemImage: "music.note.list") }
                    .tag(1)
                PCView().withMiniPlayer()
                    .tabItem { Label("PC", systemImage: "desktopcomputer") }
                    .tag(2)
                SettingsView().withMiniPlayer()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(3)
            }
            .tint(.white)
            .preferredColorScheme(.dark)
            .environmentObject(models)
            .environmentObject(library)
            .environmentObject(adapters)
            .environmentObject(generator)
            .environmentObject(player)
            .environmentObject(hub)
            .onChange(of: generator.lastSong?.id) { _ in
                // New song: start playing it right away, like Suno.
                if let s = generator.lastSong { player.play(s, library: library) }
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
                if p == .active {
                    hub.startPolling()
                    models.refresh()
                } else if p == .background {
                    hub.stopPolling()
                }
            }
        }
    }
}

private struct MiniPlayerInset: ViewModifier {
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayer().padding(.bottom, 4)
        }
    }
}

extension View {
    func withMiniPlayer() -> some View { modifier(MiniPlayerInset()) }
}
