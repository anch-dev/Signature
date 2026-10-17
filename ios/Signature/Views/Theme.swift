import SwiftUI
import UIKit

// MARK: - Themes

/// One colour scheme for the whole app. Picked in Settings → Appearance.
struct Palette: Equatable {
    let id: String
    let name: String
    let dark: Bool
    let bgTop: Color
    let bgBottom: Color
    let glow: Color            // soft light behind the top of each screen
    let card: Color
    let cardHi: Color
    let stroke: Color
    let text: Color
    let muted: Color
    let faint: Color
    let accent: Color
    let inverse: Color         // selected pill / primary button fill
    let onInverse: Color
    let gradient: [Color]
}

private func rgb(_ hex: UInt32, _ a: Double = 1) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
          blue: Double(hex & 0xFF) / 255, opacity: a)
}

extension Palette {
    static let dusk = Palette(
        id: "dusk", name: "Dusk", dark: true,
        bgTop: rgb(0x2A1F55), bgBottom: rgb(0x130F2B), glow: rgb(0xF0386B, 0.28),
        card: .white.opacity(0.075), cardHi: .white.opacity(0.13), stroke: .white.opacity(0.10),
        text: .white, muted: .white.opacity(0.64), faint: .white.opacity(0.40),
        accent: rgb(0xFF7A59), inverse: .white, onInverse: rgb(0x1E1640),
        gradient: [rgb(0xFF8A4C), rgb(0xF0386B), rgb(0x7B3FF2)])

    static let ocean = Palette(
        id: "ocean", name: "Ocean", dark: true,
        bgTop: rgb(0x0E3A4F), bgBottom: rgb(0x08192A), glow: rgb(0x3FD0C9, 0.24),
        card: .white.opacity(0.075), cardHi: .white.opacity(0.13), stroke: .white.opacity(0.10),
        text: .white, muted: .white.opacity(0.64), faint: .white.opacity(0.40),
        accent: rgb(0x46D9C6), inverse: .white, onInverse: rgb(0x0B2233),
        gradient: [rgb(0x3FD0C9), rgb(0x3B82F6), rgb(0x8B5CF6)])

    static let daylight = Palette(
        id: "daylight", name: "Daylight", dark: false,
        bgTop: rgb(0xFFF4EC), bgBottom: rgb(0xF1EAF8), glow: rgb(0xFF8A4C, 0.20),
        card: .white.opacity(0.88), cardHi: rgb(0xF3ECF6), stroke: .black.opacity(0.07),
        text: rgb(0x1E1A26), muted: rgb(0x1E1A26, 0.58), faint: rgb(0x1E1A26, 0.38),
        accent: rgb(0xE5533A), inverse: rgb(0x1E1A26), onInverse: .white,
        gradient: [rgb(0xFF8A4C), rgb(0xF0386B), rgb(0x7B3FF2)])

    static let midnight = Palette(
        id: "midnight", name: "Midnight", dark: true,
        bgTop: rgb(0x0B0B10), bgBottom: rgb(0x0B0B10), glow: .clear,
        card: rgb(0x17171F), cardHi: rgb(0x21212B), stroke: .white.opacity(0.08),
        text: .white, muted: .white.opacity(0.55), faint: .white.opacity(0.32),
        accent: rgb(0xFF6B3D), inverse: .white, onInverse: .black,
        gradient: [rgb(0xFF7A1A), rgb(0xFF2E78), rgb(0x7A2EF7)])

    static let rose = Palette(
        id: "rose", name: "Rose", dark: true,
        bgTop: rgb(0x3A1A2E), bgBottom: rgb(0x1A0C17), glow: rgb(0xFF6F91, 0.26),
        card: .white.opacity(0.075), cardHi: .white.opacity(0.13), stroke: .white.opacity(0.10),
        text: .white, muted: .white.opacity(0.64), faint: .white.opacity(0.40),
        accent: rgb(0xFF8FA8), inverse: .white, onInverse: rgb(0x2A1222),
        gradient: [rgb(0xFFB37A), rgb(0xFF6F91), rgb(0xC155E8)])

    static let forest = Palette(
        id: "forest", name: "Forest", dark: true,
        bgTop: rgb(0x16352C), bgBottom: rgb(0x0A1A15), glow: rgb(0x7BE0A8, 0.20),
        card: .white.opacity(0.075), cardHi: .white.opacity(0.13), stroke: .white.opacity(0.10),
        text: .white, muted: .white.opacity(0.64), faint: .white.opacity(0.40),
        accent: rgb(0x7BE0A8), inverse: .white, onInverse: rgb(0x0E241D),
        gradient: [rgb(0xD4E86F), rgb(0x5FD3A0), rgb(0x2F9FC4)])

    static let graphite = Palette(
        id: "graphite", name: "Graphite", dark: true,
        bgTop: rgb(0x2B2D33), bgBottom: rgb(0x18191D), glow: rgb(0xFFFFFF, 0.06),
        card: .white.opacity(0.07), cardHi: .white.opacity(0.12), stroke: .white.opacity(0.09),
        text: .white, muted: .white.opacity(0.62), faint: .white.opacity(0.38),
        accent: rgb(0xFFB547), inverse: .white, onInverse: rgb(0x1B1C20),
        gradient: [rgb(0xFFC857), rgb(0xFF8A4C), rgb(0xF0386B)])

    static let sand = Palette(
        id: "sand", name: "Sand", dark: false,
        bgTop: rgb(0xFBF4E8), bgBottom: rgb(0xF2E6D3), glow: rgb(0xE9A86B, 0.22),
        card: .white.opacity(0.82), cardHi: rgb(0xF1E6D6), stroke: .black.opacity(0.07),
        text: rgb(0x2A2118), muted: rgb(0x2A2118, 0.58), faint: rgb(0x2A2118, 0.38),
        accent: rgb(0xC8682D), inverse: rgb(0x2A2118), onInverse: .white,
        gradient: [rgb(0xE9A86B), rgb(0xD9603B), rgb(0x9B3D6E)])

    static let all: [Palette] = [.dusk, .ocean, .rose, .forest, .graphite, .midnight, .daylight, .sand]
    static func named(_ id: String) -> Palette { all.first { $0.id == id } ?? .dusk }
}

enum Theme {
    /// Set by the app root from Settings; the root rebuilds when it changes.
    static var palette: Palette = .named(UserDefaults.standard.string(forKey: "appTheme") ?? "dusk")

    static var bg: Color { palette.bgTop }
    static var card: Color { palette.card }
    static var cardHi: Color { palette.cardHi }
    static var stroke: Color { palette.stroke }
    static var text: Color { palette.text }
    static var muted: Color { palette.muted }
    static var faint: Color { palette.faint }
    static var accent: Color { palette.accent }
    static var inverse: Color { palette.inverse }
    static var onInverse: Color { palette.onInverse }
    static let good = Color(red: 0.25, green: 0.80, blue: 0.52)
    static let warn = Color(red: 0.98, green: 0.70, blue: 0.20)
    static let bad = Color(red: 0.98, green: 0.34, blue: 0.40)

    static var gradient: LinearGradient {
        LinearGradient(colors: palette.gradient, startPoint: .leading, endPoint: .trailing)
    }

    /// Full-screen backdrop: vertical gradient with a soft coloured glow up top.
    static var background: some View {
        ZStack {
            LinearGradient(colors: [palette.bgTop, palette.bgBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [palette.glow, .clear], center: UnitPoint(x: 0.85, y: -0.05),
                           startRadius: 10, endRadius: 420)
        }
        .ignoresSafeArea()
    }

    /// Navigation and tab bars: translucent so the backdrop shows through.
    static func applyBarAppearance() {
        let text = UIColor(palette.text)
        let bar = UITabBarAppearance()
        bar.configureWithDefaultBackground()
        bar.backgroundEffect = UIBlurEffect(style: palette.dark ? .systemChromeMaterialDark : .systemChromeMaterialLight)
        bar.backgroundColor = UIColor(palette.bgBottom).withAlphaComponent(0.55)
        UITabBar.appearance().standardAppearance = bar
        UITabBar.appearance().scrollEdgeAppearance = bar
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.titleTextAttributes = [.foregroundColor: text]
        nav.largeTitleTextAttributes = [.foregroundColor: text]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        let compact = UINavigationBarAppearance()
        compact.configureWithDefaultBackground()
        compact.backgroundEffect = UIBlurEffect(style: palette.dark ? .systemChromeMaterialDark : .systemChromeMaterialLight)
        compact.titleTextAttributes = [.foregroundColor: text]
        UINavigationBar.appearance().compactAppearance = compact
    }
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke))
            .shadow(color: .black.opacity(Theme.palette.dark ? 0.18 : 0.06), radius: 12, y: 4)
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardStyle(padding: padding)) }

    func screen() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.background)
    }

    /// Keeps content at a comfortable reading width on iPad / landscape, centred.
    func readableWidth(_ max: CGFloat = 720) -> some View {
        frame(maxWidth: max).frame(maxWidth: .infinity)
    }

    /// Row background for Forms / Lists so they sit on the theme, not system grey.
    func themedRow() -> some View { listRowBackground(Theme.card) }
}

struct SectionLabel: View {
    let text: String
    var trailing: AnyView? = nil
    init(_ text: String, trailing: AnyView? = nil) { self.text = text; self.trailing = trailing }
    var body: some View {
        HStack {
            Text(text).font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            Spacer()
            trailing
        }
    }
}

/// Pill used for tags, toggles and quick choices.
struct Chip: View {
    let title: String
    var icon: String? = nil
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.caption.weight(.semibold)) }
                Text(title).font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(selected ? Theme.onInverse : Theme.text)
            .background {
                if selected { Capsule().fill(Theme.inverse) } else { Capsule().fill(Theme.cardHi) }
            }
            .overlay(Capsule().stroke(selected ? Color.clear : Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}

/// Simple custom segmented control (Simple | Custom).
struct PillPicker<T: Hashable & Identifiable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { o in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = o }
                } label: {
                    Text(title(o))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(selection == o ? Theme.onInverse : Theme.muted)
                        .background(selection == o ? Capsule().fill(Theme.inverse) : Capsule().fill(Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().stroke(Theme.stroke))
    }
}

/// Generated cover art: a gradient seeded by the song, with a waveform glyph.
struct SongArt: View {
    let seed: String
    var size: CGFloat = 56
    var playing = false

    private var colors: [Color] {
        var h = UInt64(5381)
        for b in seed.utf8 { h = (h &* 33) ^ UInt64(b) }
        let a = Double(h % 360) / 360
        let b = Double((h / 360) % 360) / 360
        return [Color(hue: a, saturation: 0.75, brightness: 0.95),
                Color(hue: (a + 0.12 + b * 0.2).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.55)]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: playing ? "waveform" : "music.note")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .symbolEffectIfAvailable(playing)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

private extension View {
    @ViewBuilder func symbolEffectIfAvailable(_ on: Bool) -> some View {
        if #available(iOS 17.0, *), on {
            self.symbolEffect(.variableColor.iterative)
        } else {
            self
        }
    }
}

struct SongRow: View {
    let song: Song
    var playing: Bool
    var body: some View {
        HStack(spacing: 12) {
            SongArt(seed: song.id.uuidString, size: 54, playing: playing)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(.body.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(song.caption).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                HStack(spacing: 6) {
                    Text(CreateView.time(song.duration))
                    if let a = song.adapter { Text("· \(a)") }
                    if let m = song.madeOn, m != "iPhone" { Image(systemName: "desktopcomputer") }
                }
                .font(.caption2.weight(.medium)).foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Big gradient call to action that turns into a progress bar while working.
struct CreateButton: View {
    let title: String
    let running: Bool
    let progress: Double
    let status: String
    let enabled: Bool
    let action: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(running ? AnyShapeStyle(Theme.cardHi) : AnyShapeStyle(Theme.gradient))
                .opacity(enabled || running ? 1 : 0.35)
            if running {
                GeometryReader { g in
                    Capsule().fill(Theme.gradient)
                        .frame(width: max(44, g.size.width * progress))
                        .animation(.easeOut(duration: 0.4), value: progress)
                }
            }
            HStack {
                if running {
                    ProgressView().tint(.white).padding(.leading, 18)
                    Text(status).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button(action: cancel) {
                        Image(systemName: "xmark").font(.subheadline.weight(.bold))
                            .padding(10).background(Circle().fill(.black.opacity(0.35)))
                    }
                    .padding(.trailing, 6)
                } else {
                    Spacer()
                    Image(systemName: "music.note").font(.headline)
                    Text(title).font(.headline)
                    Spacer()
                }
            }
            .foregroundStyle(.white)
        }
        .frame(height: 54)
        .contentShape(Capsule())
        .onTapGesture { if !running && enabled { action() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(running ? status : title)
    }
}

struct FitBadge: View {
    let fit: Fit
    var body: some View {
        Text(fit.label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }
    private var color: Color {
        switch fit {
        case .good: return Theme.good
        case .tight: return Theme.warn
        case .streamed: return Theme.accent
        case .tooBig: return Theme.bad
        }
    }
}
