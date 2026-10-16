import SwiftUI

struct CreateView: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var library: Library
    @EnvironmentObject var adapters: AdapterStore
    @EnvironmentObject var gen: Generator
    @EnvironmentObject var player: Player

    private let languages: [(String, String)] = [
        ("", "Auto"), ("en", "English"), ("es", "Spanish"), ("it", "Italian"), ("fr", "French"),
        ("pt", "Portuguese"), ("de", "German"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                if !models.isReady {
                    Section {
                        Label("Download the models in the Models tab first.", systemImage: "arrow.down.circle")
                    }
                }

                Section {
                    Picker("Style adapter", selection: $gen.adapter) {
                        Text("None (base model)").tag(URL?.none)
                        ForEach(adapters.adapters, id: \.self) { url in
                            Text(AdapterStore.name(url)).tag(Optional(url))
                        }
                    }
                    if let a = gen.adapter {
                        VStack(alignment: .leading) {
                            Text("Strength \(gen.adapterScale, specifier: "%.2f")")
                            Slider(value: $gen.adapterScale, in: 0.2...1.5, step: 0.05)
                        }
                        Button("Insert trigger \"\(AdapterStore.name(a))\"") {
                            let t = AdapterStore.name(a)
                            if !gen.style.lowercased().contains(t.lowercased()) {
                                gen.style = gen.style.isEmpty ? t + ", " : t + ", " + gen.style
                            }
                        }
                    }
                } header: {
                    Text("Your sound")
                } footer: {
                    Text("Styles are the .safetensors files you train on your PC. AirDrop one to this phone and open it with Signature.")
                }

                Section("Style") {
                    TextField("e.g. melodic trap, 808s, airy pads, male vocal", text: $gen.style, axis: .vertical)
                        .lineLimit(2...5)
                }

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

                Section {
                    VStack(alignment: .leading) {
                        Text("Length \(Self.time(gen.duration))")
                        Slider(value: $gen.duration, in: 10...gen.maxDuration, step: 5)
                    }
                    DisclosureGroup("Advanced") {
                        Toggle("Songwriter planning", isOn: $gen.useSongwriter)
                        Toggle("Reuse seed", isOn: $gen.lockSeed)
                        if gen.lockSeed {
                            TextField("Seed", text: $gen.seedText).keyboardType(.numberPad)
                        }
                        LabeledContent("Memory available", value: gen.availableMemoryText)
                    }
                } footer: {
                    Text("Songwriter planning gives much better vocals and structure. Turn it off only for quick instrumental sketches.")
                }

                Section {
                    if gen.running {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(gen.stage.label)
                                Spacer()
                                if let start = gen.startedAt {
                                    Text(start, style: .timer).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            ProgressView(value: gen.progress)
                            Text("Keep Signature open. The screen won't lock while it works.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Cancel", role: .destructive) { gen.cancel() }
                    } else {
                        Button {
                            if let p = models.paths { gen.start(models: p, library: library) }
                        } label: {
                            Label("Generate song", systemImage: "sparkles").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!models.isReady)
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

    static func time(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
