import SwiftUI

/// Sheet behind the model chip on Create: where to run and which model.
struct ModelPickerSheet: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var gen: Generator
    @EnvironmentObject var hub: HubStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if hub.isPaired {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Make songs on")
                            PillPicker(options: GenTarget.allCases, selection: $gen.target) {
                                $0 == .phone ? "This iPhone" : (hub.pairing?.name ?? "PC")
                            }
                        }
                    }
                    if gen.target == .phone {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Music model")
                            if models.installedMusic.isEmpty {
                                Text("No music model downloaded yet.").foregroundStyle(Theme.muted)
                            }
                            ForEach(models.installedMusic) { item in
                                let m = item.model, q = item.quant
                                Button {
                                    models.select(m, q)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(m.name).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                                            Text("\(q.label) · \(m.steps > 0 ? "\(m.steps) steps" : "auto steps")")
                                                .font(.caption).foregroundStyle(Theme.muted)
                                        }
                                        Spacer()
                                        if models.musicID == m.id && models.musicQuant == q {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                        }
                                    }
                                    .card(padding: 12)
                                }
                                .buttonStyle(.plain)
                            }
                            NavigationLink { ModelsView() } label: {
                                Label("Get more models", systemImage: "square.and.arrow.down").font(.subheadline.weight(.semibold))
                            }
                            .tint(Theme.accent)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Songwriter")
                            Toggle(isOn: $models.useSongwriter) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(models.songwriter.name).foregroundStyle(Theme.text)
                                    Text("Writes lyrics in Simple mode and plans song structure. Strongly recommended.")
                                        .font(.caption).foregroundStyle(Theme.muted)
                                }
                            }
                            .tint(Theme.accent)
                            .card(padding: 12)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("On \(hub.pairing?.name ?? "your PC")")
                            Text("ACE-Step 1.5 Turbo with your PC styles. Choose models and YuE2 in the PC tab.")
                                .font(.callout).foregroundStyle(Theme.muted).card()
                        }
                    }
                }
                .padding(16)
            }
            .screen()
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.tint(Theme.accent) }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

/// The full catalog: every ACE-Step 1.5 file, with fit for this phone.
struct ModelsView: View {
    @EnvironmentObject var models: ModelManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summary
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Music models")
                    ForEach(Catalog.music) { m in musicRow(m) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Songwriter")
                    ForEach(Catalog.songwriters) { s in songwriterRow(s) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Always needed")
                    fileRow(title: "Text encoder", subtitle: "Reads your prompt", file: models.textEncoderFile)
                    fileRow(title: "Audio decoder", subtitle: "Turns the model output into sound", file: Catalog.vae)
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Other engines")
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("YuE2 3B").font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            Text("PC").font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(Theme.cardHi)).foregroundStyle(Theme.muted)
                        }
                        Text("Lyrics-to-song with melody and chord planning. Runs on a paired PC for now; its smallest build needs about 7.7 GB, more than any iPhone gives one app. On-device support is being worked on.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    .card()
                }
                Text("Models come from Hugging Face (Serveurperso/ACE-Step-1.5-GGUF). Downloads continue in the background. Long-press a size to delete it.")
                    .font(.caption2).foregroundStyle(Theme.faint)
            }
            .padding(16)
        }
        .screen()
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            stat("On this iPhone", ModelManager.format(models.usedBytes))
            stat("Memory for models", String(format: "%.1f GB", Device.budgetGB))
            stat("Mode", models.liteActive ? "Lite" : "Full")
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.headline).foregroundStyle(Theme.text)
            Text(k).font(.caption2).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 10)
    }

    private func musicRow(_ m: MusicModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(m.name).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                if m.xl { Text("XL").font(.caption2.weight(.heavy)).foregroundStyle(Theme.accent) }
                Spacer()
                if models.musicID == m.id {
                    Label("In use", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            Text(m.blurb).font(.caption).foregroundStyle(Theme.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(m.quants) { q in
                        if let f = m.file(q) {
                            quantChip(f, label: q.label, selected: models.musicID == m.id && models.musicQuant == q) {
                                models.select(m, q)
                            }
                        }
                    }
                }
            }
        }
        .card()
    }

    private func songwriterRow(_ s: SongwriterModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(s.name).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                Spacer()
                if models.songwriterID == s.id && models.useSongwriter {
                    Label("In use", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            Text(s.blurb).font(.caption).foregroundStyle(Theme.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(s.quants) { q in
                        if let f = s.file(q) {
                            quantChip(f, label: q.label, selected: models.songwriterID == s.id && models.songwriterQuant == q) {
                                models.songwriterID = s.id
                                models.songwriterQuant = q
                                models.useSongwriter = true
                            }
                        }
                    }
                }
            }
        }
        .card()
    }

    private func fileRow(title: String, subtitle: String, file: ModelFile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            quantChip(file, label: ModelManager.format(file.bytes), selected: models.isInstalled(file), showSize: false) {}
        }
        .card()
    }

    /// One downloadable file: tap to download / select, long-press to delete.
    private func quantChip(_ f: ModelFile, label: String, selected: Bool, showSize: Bool = true,
                           onSelect: @escaping () -> Void) -> some View {
        let installed = models.isInstalled(f)
        let p = models.progress[f.id]
        let fit = Device.fit(bytes: f.bytes)
        return Button {
            if installed { onSelect() } else if p != nil { models.cancel(f) } else { models.download(f) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: installed ? (selected ? "checkmark.circle.fill" : "checkmark.circle")
                          : (p != nil ? "stop.circle" : "arrow.down.circle"))
                    Text(label).font(.caption.weight(.semibold))
                }
                if let p {
                    ProgressView(value: p).tint(Theme.accent).frame(width: 90)
                } else {
                    HStack(spacing: 5) {
                        if showSize { Text(ModelManager.format(f.bytes)).font(.caption2) }
                        if !installed { FitBadge(fit: fit) }
                    }
                }
                if let e = models.errors[f.id] {
                    Text(e).font(.caption2).foregroundStyle(Theme.bad).lineLimit(2).frame(maxWidth: 160, alignment: .leading)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundStyle(selected ? Color.black : Theme.text)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.white : Theme.cardHi))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if installed {
                Button(role: .destructive) { models.delete(f) } label: { Label("Delete \(ModelManager.format(f.bytes))", systemImage: "trash") }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var adapters: AdapterStore
    @EnvironmentObject var gen: Generator
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { ModelsView() } label: {
                        LabeledContent("Models", value: models.music.name)
                    }
                } footer: {
                    Text("Every ACE-Step 1.5 model, in every size, with how well it fits this iPhone.")
                }

                Section {
                    Picker("Performance", selection: $models.performance) {
                        ForEach(PerformanceMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Run on", selection: $models.useCPU) {
                        Text("GPU (Metal)").tag(false)
                        Text("CPU").tag(true)
                    }
                    Toggle("Map models from storage", isOn: $models.zeroCopy)
                } header: {
                    Text("Performance")
                } footer: {
                    Text("Lite uses less memory (shorter songs, smaller working buffers) and turns on automatically when iOS gives Signature under 3 GB, as on 4 GB iPhones. GPU is fastest; CPU uses the same memory but is slower. Mapping reads model weights straight from storage instead of copying them into memory. Leave it on unless songs fail.")
                }

                Section {
                    LabeledContent("Memory for Signature", value: String(format: "%.1f GB", Device.budgetGB))
                    LabeledContent("Longest song", value: CreateView.time(models.maxDuration))
                    if models.lastPeaks.count == 4 {
                        ForEach(0..<4, id: \.self) { i in
                            LabeledContent("Peak: " + ["songwriter", "music", "rendering", "saving"][i], value: peak(models.lastPeaks[i]))
                        }
                    }
                    Button {
                        gen.runMemoryTest(models: models)
                    } label: {
                        if gen.testing {
                            HStack { ProgressView(); Text("Testing… \(gen.statusText)") }
                        } else {
                            Text("Run 20-second memory test")
                        }
                    }
                    .disabled(gen.running || gen.testing || !models.isReady)
                    if let r = gen.testResult {
                        Text(r).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("This device")
                } footer: {
                    Text("Peak memory per stage helps tune Lite mode. If a test fails, switch to Lite or a smaller model size.")
                }

                Section {
                    ForEach(adapters.adapters, id: \.self) { url in Text(AdapterStore.name(url)) }
                        .onDelete { idx in
                            idx.map { adapters.adapters[$0] }.forEach {
                                if gen.adapter == $0 { gen.adapter = nil }
                                adapters.delete($0)
                            }
                        }
                    Button("Import style file") { importing = true }
                } header: {
                    Text("Your styles on this iPhone")
                } footer: {
                    Text("Styles you train on a PC, downloaded from the PC tab or imported as .safetensors.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    Link("ACE-Step 1.5", destination: URL(string: "https://github.com/ace-step/ACE-Step-1.5")!)
                    Link("Source code", destination: URL(string: "https://github.com/anch-dev/Signature")!)
                }
            }
            .screen()
            .navigationTitle("Settings")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { r in
                if case .success(let url) = r, let added = adapters.importFile(url) { gen.adapter = added }
            }
        }
    }

    private func peak(_ b: UInt64) -> String {
        b == 0 ? "—" : ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }
}
