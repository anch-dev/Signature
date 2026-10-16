import SwiftUI

// Dark, music-app look (Suno / Riffusion style): near-black canvas, soft
// raised cards, one warm gradient for primary actions and artwork.
enum Theme {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.06)
    static let card = Color(red: 0.09, green: 0.09, blue: 0.12)
    static let cardHi = Color(red: 0.13, green: 0.13, blue: 0.17)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color.white
    static let muted = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.32)
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.24)
    static let good = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.75, blue: 0.25)
    static let bad = Color(red: 1.0, green: 0.36, blue: 0.40)

    static let gradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.48, blue: 0.10), Color(red: 1.0, green: 0.18, blue: 0.47), Color(red: 0.48, green: 0.18, blue: 0.97)],
        startPoint: .leading, endPoint: .trailing)
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke))
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardStyle(padding: padding)) }

    func screen() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: AnyView? = nil
    init(_ text: String, trailing: AnyView? = nil) { self.text = text; self.trailing = trailing }
    var body: some View {
        HStack {
            Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(Theme.muted)
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
                Text(title).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(selected ? Color.black : Theme.text)
            .background {
                if selected { Capsule().fill(Color.white) } else { Capsule().fill(Theme.cardHi) }
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
                        .foregroundStyle(selection == o ? Color.black : Theme.muted)
                        .background(selection == o ? Capsule().fill(Color.white) : Capsule().fill(Color.clear))
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
        case .tooBig: return Theme.bad
        }
    }
}
