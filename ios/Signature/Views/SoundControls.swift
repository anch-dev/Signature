import SwiftUI

/// Suno / Riffusion-style sliders. Collapsed it shows a one-line summary;
/// 50% everywhere is the model's official default.
struct SoundControls: View {
    @Binding var sound: SoundSettings
    let engine: MusicEngine
    var turbo: Bool = true
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sound").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Text(summary).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(Theme.muted)
                }
            }
            .buttonStyle(.plain)

            if open {
                slider("Weirdness", value: $sound.weirdness,
                       low: "Safe", high: "Wild",
                       help: "How adventurous the song plan is: melodies, structure, word choices.")
                slider("Style influence", value: $sound.styleInfluence,
                       low: "Loose", high: "Strict",
                       help: "How closely the music sticks to your style prompt.")
                if engine == .acestep {
                    slider("Clarity", value: $sound.clarity,
                           low: "Raw", high: "Polished",
                           help: turbo ? "Detail correction on the final mix. Higher sounds cleaner and less synthetic."
                                       : "Only used by Turbo models.")
                        .disabled(!turbo).opacity(turbo ? 1 : 0.5)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Texture").font(.caption).foregroundStyle(Theme.muted)
                        PillPicker(options: SoundSettings.Sampler.allCases, selection: $sound.sampler) { $0.title }
                        Text(sound.sampler == .smooth ? "Smooth: clean and consistent (default)."
                             : sound.sampler == .organic ? "Organic: adds fresh noise each step. Looser, more human, less repeatable."
                             : "Crisp: higher-order sampler. Sharper transients and detail.")
                            .font(.caption2).foregroundStyle(Theme.faint)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quality").font(.caption).foregroundStyle(Theme.muted)
                    PillPicker(options: SoundSettings.Quality.allCases, selection: $sound.quality) { $0.title }
                    Text(sound.quality == .high ? "More refinement steps: a little better, about 50% slower."
                         : sound.quality == .fast ? "Fewer steps: quicker drafts."
                         : "The model's tuned step count.")
                        .font(.caption2).foregroundStyle(Theme.faint)
                }
                if sound != .defaults {
                    Button("Reset to defaults") { withAnimation { sound = .defaults } }
                        .font(.caption.weight(.semibold)).tint(Theme.accent)
                }
            }
        }
        .card()
    }

    private var summary: String {
        if sound == .defaults { return "Defaults" }
        var parts = ["Weirdness \(pct(sound.weirdness))", "Style \(pct(sound.styleInfluence))"]
        if engine == .acestep { parts.append("Clarity \(pct(sound.clarity))") }
        if sound.sampler != .smooth && engine == .acestep { parts.append(sound.sampler.title) }
        if sound.quality != .standard { parts.append(sound.quality.title) }
        return parts.joined(separator: " · ")
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func slider(_ title: String, value: Binding<Double>, low: String, high: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.text)
                Spacer()
                Text(pct(value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
            }
            Slider(value: value, in: 0...1, step: 0.05).tint(Theme.accent)
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.caption2).foregroundStyle(Theme.faint)
            Text(help).font(.caption2).foregroundStyle(Theme.faint)
        }
    }
}
