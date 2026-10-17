import AVFoundation
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Never let the iPhone auto-lock while Signature is open: a locked
        // screen suspends GPU work mid-song.
        application.isIdleTimerDisabled = true
        return true
    }

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
    @AppStorage("appTheme") private var themeID = "dusk"

    init() {
        LogCapture.shared.start()
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        LogCapture.shared.log("Signature \(v) on \(machine), iOS \(UIDevice.current.systemVersion), RAM \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB, app budget \(String(format: "%.2f", Device.budgetGB)) GB")
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        Theme.applyBarAppearance()
    }

    var body: some Scene {
        WindowGroup {
            let _ = applyTheme(themeID)
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
            .tint(Theme.accent)
            .preferredColorScheme(Theme.palette.dark ? .dark : .light)
            .id(themeID)   // rebuild every screen when the theme changes

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
            .onChange(of: generator.showCreate) { show in
                if show {
                    tab = 0
                    generator.showCreate = false
                }
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
                    UIApplication.shared.isIdleTimerDisabled = true  // never auto-lock while open
                    hub.startPolling()
                    models.refresh()
                } else if p == .background {
                    hub.stopPolling()
                }
            }
        }
    }
}

private func applyTheme(_ id: String) {
    let p = Palette.named(id)
    if Theme.palette != p {
        Theme.palette = p
        Theme.applyBarAppearance()
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
