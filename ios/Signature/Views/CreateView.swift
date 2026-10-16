import SwiftUI

struct CreateView: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var library: Library
    @EnvironmentObject var adapters: AdapterStore
    @EnvironmentObject var gen: Generator
    @EnvironmentObject var player: Player
    @EnvironmentObject var hub: HubStore

    private let languages: [(String, String)] = [
        ("", "Auto"), ("en", "English"), ("es", "Spanish"), ("it", "Italian"), ("fr", "French"),
        ("pt", "Portuguese"), ("de", "German"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
    ]

    private var onPC: Bool { gen.target == .pc }
    private var trigger: String? {
        onPC ? gen.pcStyle : gen.adapter.map(AdapterStore.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                if hub.isPaired {
                    Section {
                        Picker("Make on", selection: $gen.target) {
                            Text("This iPhone").tag(GenTarget.phone)
                            Text(hub.pairing?.name ?? "PC").tag(GenTarget.pc)
                        }
                        .pickerStyle(.segmented)
                        .disabled(gen.running)
                        if onPC { pcStatusLine }
                    } footer: {
                        Text(onPC ? "Your PC does the work; the song lands in your Library when it's done."
                                  : "Runs fully offline on this iPhone.")
                    }
                }

                if !onPC && !models.isReady {
                    Section {
                        Label("Download the models in the Models tab first.", systemImage: "arrow.down.circle")
                    }
                }

                styleSection

                Section("Style prompt") {
                    TextField("e.g. melodic trap, 808s, airy pads, male vocal", text: $gen.style, axis: .vertical)
                        .lineLimit(2...5)
                }

                lyricsSection

                Section {
                    VStack(alignment: .leading) {
                        Text("Length \(Self.time(min(gen.duration, gen.durationLimit)))")
                        Slider(value: $gen.duration, in: 10...gen.durationLimit, step: 5)
                    }
                    DisclosureGroup("Advanced") {
                        if !onPC {
                            Toggle("Songwriter planning", isOn: $gen.useSongwriter)
                        }
                        Toggle("Reuse seed", isOn: $gen.lockSeed)
                        if gen.lockSeed {
                            TextField("Seed", text: $gen.seedText).keyboardType(.numberPad)
                        }
                        if !onPC {
                            LabeledContent("Memory available", value: gen.availableMemoryText)
                        }
                    }
                } footer: {
                    if !onPC {
                        Text("Songwriter planning gives much better vocals and structure. Turn it off only for quick instrumental sketches.")
                    }
                }

                actionSection
            }
            .navigationTitle("Signature")
            .scrollDismissesKeyboard(.interactively)
            .alert("Style", isPresented: Binding(
                get: { adapters.importMessage != nil }, set: { if !$0 { adapters.importMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(adapters.importMessage ?? "")
            }
        }
    }

    // MARK: sections

    @ViewBuilder private var pcStatusLine: some View {
        if let s = hub.status, hub.reachable {
            if s.training?.isRunning == true {
                Label("PC is training \(s.training!.dataset). Generate on the iPhone meanwhile.", systemImage: "hourglass")
                    .foregroundStyle(.orange)
            } else if s.engine.mode == "studio" {
                Label("Studio GUI is open on the PC (styles unavailable there)", systemImage: "desktopcomputer")
                    .foregroundStyle(.secondary)
            } else {
                Label("\(s.gpu?.name ?? "PC") ready", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        } else {
            Label("Can't reach \(hub.pairing?.name ?? "the PC"). Same Wi-Fi or Tailscale on?", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder private var styleSection: some View {
        Section {
            if onPC {
                Picker("Style", selection: $gen.pcStyle) {
                    Text("None (base model)").tag(String?.none)
                    ForEach(hub.styles.filter(\.pc_ready)) { s in
                        Text(s.name).tag(Optional(s.name))
                    }
                }
            } else {
                Picker("Style", selection: $gen.adapter) {
                    Text("None (base model)").tag(URL?.none)
                    ForEach(adapters.adapters, id: \.self) { url in
                        Text(AdapterStore.name(url)).tag(Optional(url))
                    }
                }
            }
            if let t = trigger {
                VStack(alignment: .leading) {
                    Text("Strength \(gen.adapterScale, specifier: "%.2f")")
                    Slider(value: $gen.adapterScale, in: onPC ? 0.1...1.0 : 0.2...1.5, step: 0.05)
                }
                Button("Insert trigger \"\(t)\"") {
                    if !gen.style.lowercased().contains(t.lowercased()) {
                        gen.style = gen.style.isEmpty ? t + ", " : t + ", " + gen.style
                    }
                }
            }
        } header: {
            Text("Your sound")
        } footer: {
            Text(onPC ? "Styles trained on your PC. Download them in the PC tab to use them offline too."
                      : "Styles you've downloaded from your PC or imported as .safetensors files.")
        }
    }

    @ViewBuilder private var lyricsSection: some View {
        Section {
            Toggle("Instrumental", isOn: $gen.instrumental)
            if !gen.instrumental {
                TextEditor(text: $gen.lyrics)
                    .frame(minHeight: 160)
                    .font(.body.monospaced())
                    .overlay(alignment: .topLeading) {
                        if gen.lyrics.isEmpty {
                            Text("[Verse]\nYour lines here\n\n[Chorus]\nThe hook")
                                .foregroundStyle(.tertiary)
                                .font(.body.monospaced())
                                .padding(.top, 8).padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
                Picker("Vocal language", selection: $gen.language) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
        } header: {
            Text("Lyrics")
        } footer: {
            if !gen.instrumental {
                Text("Section tags like [Verse], [Chorus], [Bridge] shape the structure.")
            }
        }
    }

    @ViewBuilder private var actionSection: some View {
        Section {
            if gen.running {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(onPC ? gen.remoteMessage : gen.stage.label)
                        Spacer()
                        if let start = gen.startedAt {
                            Text(start, style: .timer).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: gen.progress)
                    Text(onPC ? "You can lock your phone; come back to collect the song."
                              : "Keep Signature open. The screen won't lock while it works.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(onPC ? "Stop waiting" : "Cancel", role: .destructive) { gen.cancel() }
            } else {
                Button {
                    if onPC {
                        gen.startRemote(hub: hub, library: library)
                    } else if let p = models.paths {
                        gen.start(models: p, library: library)
                    }
                } label: {
                    Label(onPC ? "Generate on \(hub.pairing?.name ?? "PC")" : "Generate song",
                          systemImage: onPC ? "desktopcomputer" : "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(onPC ? !hub.canGenerate : !models.isReady)
            }
            if let e = gen.error {
                Text(e).foregroundStyle(.red)
            }
            if let s = gen.lastSong, !gen.running {
                Button {
                    player.toggle(s, url: library.url(for: s))
                } label: {
                    Label(player.current == s.id ? "Stop" : "Play \"\(s.title)\"",
                          systemImage: player.current == s.id ? "stop.fill" : "play.fill")
                }
            }
        }
    }

    static func time(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
