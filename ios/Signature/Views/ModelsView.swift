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
                                $0 == .phone ? "This device" : (hub.pairing?.name ?? "PC")
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
                                        if let f = m.file(q) {
                                            let fit = models.fit(f, music: true)
                                            if fit != .good { FitBadge(fit: fit) }
                                        }
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
                            SectionLabel("Also used with every music model")
                            VStack(spacing: 8) {
                                supportRow("Text encoder", "Qwen3-Embedding 0.6B · reads your prompt", models.textEncoderFile)
                                supportRow("Audio decoder", "VAE · turns the output into sound", Catalog.vae)
                                if models.useSongwriter, let f = models.songwriterFile {
                                    supportRow("Songwriter", "\(models.songwriter.name) · lyrics and structure", f)
                                }
                            }
                            .card(padding: 12)
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
    }
}

extension ModelPickerSheet {
    func supportRow(_ title: String, _ detail: String, _ f: ModelFile) -> some View {
        HStack {
            Image(systemName: models.isInstalled(f) ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(models.isInstalled(f) ? Theme.good : Theme.warn)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text(detail).font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            if !models.isInstalled(f) {
                Button("Get") { models.download(f) }.font(.caption.weight(.semibold)).tint(Theme.accent)
            }
        }
    }
}

/// Settings: everything downloaded, grouped by what it does.
struct DownloadedModelsSection: View {
    @EnvironmentObject var models: ModelManager

    private struct Group: Identifiable {
        let id: String
        let title: String
        let detail: String
        let files: [(ModelFile, String)]   // file, display name
    }

    private var groups: [Group] {
        let installed = models.installed
        let music = Catalog.music.flatMap { m in
            m.quants.compactMap { q in m.file(q).flatMap { installed.contains($0.id) ? ($0, "\(m.name) · \(q.label)") : nil } }
        }
        let writers = Catalog.songwriters.flatMap { w in
            w.quants.compactMap { q in w.file(q).flatMap { installed.contains($0.id) ? ($0, "\(w.name) · \(q.label)") : nil } }
        }
        let enc = Catalog.textEncoders.sorted { $0.key.rawValue < $1.key.rawValue }.compactMap { q, f in
            installed.contains(f.id) ? (f, "Qwen3-Embedding 0.6B · \(q.label)") : nil
        }
        let vae = installed.contains(Catalog.vae.id) ? [(Catalog.vae, "ACE-Step VAE")] : []
        return [
            Group(id: "music", title: "Music models", detail: "Generate the audio (DiT)", files: music),
            Group(id: "writer", title: "Songwriter", detail: "Writes lyrics, plans structure (5Hz LM)", files: writers),
            Group(id: "enc", title: "Text encoder", detail: "Reads your prompt (Qwen3)", files: enc),
            Group(id: "vae", title: "Audio decoder", detail: "Turns model output into sound (VAE)", files: vae),
        ]
    }

    private func inUse(_ f: ModelFile) -> Bool { models.required.contains(f) }

    var body: some View {
        Section {
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(g.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(g.files.isEmpty ? "none" : "\(g.files.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(g.detail).font(.caption).foregroundStyle(.secondary)
                    if g.files.isEmpty {
                        Text("Nothing downloaded").font(.caption).foregroundStyle(Theme.warn)
                    }
                    ForEach(g.files, id: \.0.id) { f, name in
                        HStack {
                            Image(systemName: inUse(f) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(inUse(f) ? Theme.accent : .secondary)
                            Text(name).font(.callout)
                            Spacer()
                            Text(ModelManager.format(f.bytes)).font(.caption).foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button(role: .destructive) { models.delete(f) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            LabeledContent("Total", value: ModelManager.format(models.usedBytes))
        } header: {
            Text("Downloaded")
        } footer: {
            Text("A filled circle means the file is used by your current setup. Long-press any file to delete it.")
        }
        .themedRow()
    }
}

/// The full catalog: every ACE-Step 1.5 file, with fit for this phone.
struct ModelsView: View {
    @EnvironmentObject var models: ModelManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summary
                RecommendedCard()
                ReadinessCard()
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Music models")
                    ForEach(Catalog.music.filter { !visible($0.quants.compactMap($0.file), music: true).isEmpty }) { m in
                        musicRow(m)
                    }
                    slowToggle
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Songwriter")
                    ForEach(Catalog.songwriters.filter { !visible($0.quants.compactMap($0.file), music: false).isEmpty }) { s in
                        songwriterRow(s)
                    }
                }
                if hiddenCount > 0 {
                    Text("\(hiddenCount) sizes are hidden because they need more memory than iOS gives Signature on this device (about \(String(format: "%.1f", Device.budgetGB)) GB). They can run on your PC.")
                        .font(.caption).foregroundStyle(Theme.faint)
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
                        Text("Lyrics-to-song with melody and chord planning. Runs on a paired PC for now; its smallest build needs about 7.7 GB, more than a phone gives one app. On-device support is being worked on.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    .card()
                }
                NavigationLink { FilesOnDiskView() } label: {
                    Label("Files on this device", systemImage: "folder").font(.subheadline)
                }
                .tint(Theme.accent)
                Text("Models come from Hugging Face (Serveurperso/ACE-Step-1.5-GGUF). Downloads continue in the background. Long-press a size to delete it.")
                    .font(.caption2).foregroundStyle(Theme.faint)
            }
            .padding(16)
        }
        .screen()
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Files worth showing: those that fit, slow-mode ones if asked, and anything already downloaded.
    private func visible(_ files: [ModelFile], music: Bool) -> [ModelFile] {
        files.filter { f in
            if models.isInstalled(f) || models.progress[f.id] != nil { return true }
            let fit = models.fit(f, music: music)
            return fit.fitsNormally || (fit == .streamed && models.showSlowModels)
        }
    }

    private var allCatalogFiles: [(ModelFile, Bool)] {
        Catalog.music.flatMap { m in m.quants.compactMap(m.file).map { ($0, true) } }
            + Catalog.songwriters.flatMap { s in s.quants.compactMap(s.file).map { ($0, false) } }
    }

    private var hiddenCount: Int {
        allCatalogFiles.filter { f, music in
            !models.isInstalled(f) && models.fit(f, music: music) == .tooBig
        }.count
    }

    private var slowCount: Int {
        allCatalogFiles.filter { f, music in music && !models.isInstalled(f) && models.fit(f, music: true) == .streamed }.count
    }

    @ViewBuilder private var slowToggle: some View {
        if slowCount > 0 {
            Toggle(isOn: $models.showSlowModels) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show bigger models (\(slowCount))").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text("Too big to load whole here, but they run in Low memory mode: one layer at a time, read from storage. Expect songs to take several times longer.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .tint(Theme.accent)
            .card(padding: 12)
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            stat("On this device", ModelManager.format(models.usedBytes))
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
                        if let f = m.file(q), visible([f], music: true).count == 1 {
                            quantChip(f, label: q.label, music: true, selected: models.musicID == m.id && models.musicQuant == q) {
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
                        if let f = s.file(q), visible([f], music: false).count == 1 {
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
    private func quantChip(_ f: ModelFile, label: String, music: Bool = false, selected: Bool, showSize: Bool = true,
                           onSelect: @escaping () -> Void) -> some View {
        let installed = models.isInstalled(f)
        let p = models.progress[f.id]
        let fit = models.fit(f, music: music)
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
                        if !installed || fit == .streamed || fit == .tooBig { FitBadge(fit: fit) }
                    }
                }
                if let e = models.errors[f.id] {
                    Text(e).font(.caption2).foregroundStyle(Theme.bad).lineLimit(2).frame(maxWidth: 160, alignment: .leading)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundStyle(selected ? Theme.onInverse : Theme.text)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.inverse : Theme.cardHi))
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
    @ObservedObject private var log = LogCapture.shared
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var adapters: AdapterStore
    @EnvironmentObject var gen: Generator
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                AppearanceSection()
                DownloadedModelsSection()

                Section {
                    NavigationLink { ModelsView() } label: {
                        LabeledContent("Get more models", value: models.music.name)
                    }
                    if !models.isReady {
                        ReadinessCard().listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                } footer: {
                    Text("Every ACE-Step 1.5 model, in every size, with how well it fits this device.")
                }
                .themedRow()

                Section {
                    Picker("Performance", selection: $models.performance) {
                        ForEach(PerformanceMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Run on", selection: $models.useCPU) {
                        Text("GPU (Metal)").tag(false)
                        Text("CPU").tag(true)
                    }
                    Toggle("Map models from storage (CPU)", isOn: $models.zeroCopy)
                    Picker("Low memory (slow)", selection: $models.streamMode) {
                        ForEach(StreamMode.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Performance")
                } footer: {
                    Text("Lite uses less memory (shorter songs, smaller working buffers) and turns on automatically when iOS gives Signature under 3 GB, as on 4 GB phones. GPU is fastest; CPU uses the same memory but is slower. Mapping reads model weights straight from storage instead of copying them (CPU only; on the GPU weights are always copied).\n\nLow memory streams the music model from storage one layer at a time, like ComfyUI's low-VRAM offload: models bigger than this device's memory can still run, several times slower. “When needed” only does it for models that don't fit.")
                }
                .themedRow()

                Section {
                    LabeledContent("Memory for Signature", value: String(format: "%.1f GB", Device.budgetGB))
                    Text(Device.platformNote).font(.footnote).foregroundStyle(.secondary)
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
                    if !models.isReady {
                        Text("Needs every model file above first (\(models.missing.count) missing).")
                            .font(.footnote).foregroundStyle(Theme.warn)
                    }
                    if let r = gen.testResult {
                        Text(r).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("This device")
                } footer: {
                    Text("Peak memory per stage helps tune Lite mode. If a test fails, switch to Lite or a smaller model size.")
                }
                .themedRow()

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
                    Text("Your styles on this device")
                } footer: {
                    Text("Styles you train on a PC, downloaded from the PC tab or imported as .safetensors.")
                }
                .themedRow()

                Section {
                    Toggle("Verbose logging", isOn: $log.verbose)
                    NavigationLink { TerminalView() } label: { Label("Status terminal", systemImage: "terminal") }
                    ShareLink(item: LogCapture.shared.todayLogURL) { Label("Share today's log", systemImage: "square.and.arrow.up") }
                    Button { FilesApp.reveal(LogCapture.shared.todayLogURL) } label: { Label("Open logs in Files", systemImage: "folder") }
                } header: {
                    Text("Logging")
                } footer: {
                    Text("Verbose adds every request, stage timing, memory use, download progress and PC call to the log. Logs are saved in Files → Signature → Logs for 7 days. Send them when something goes wrong.")
                }
                .themedRow()

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    Link("ACE-Step 1.5", destination: URL(string: "https://github.com/ace-step/ACE-Step-1.5")!)
                    Link("Source code", destination: URL(string: "https://github.com/anch-dev/Signature")!)
                }
                .themedRow()
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

/// What the current setup needs, with one button to get all of it.
struct ReadinessCard: View {
    @EnvironmentObject var models: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: models.isReady ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(models.isReady ? Theme.good : Theme.warn)
                Text(models.isReady ? "Ready to create on this device" : "Missing files for \(models.music.name)")
                    .font(.headline).foregroundStyle(Theme.text)
                Spacer()
            }
            ForEach(models.required) { f in
                HStack {
                    Image(systemName: models.isInstalled(f) ? "checkmark.circle.fill"
                          : (models.progress[f.id] != nil ? "arrow.down.circle" : "circle"))
                        .foregroundStyle(models.isInstalled(f) ? Theme.good : Theme.muted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(models.role(f)).font(.subheadline).foregroundStyle(Theme.text)
                        Text(f.id).font(.caption2).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                    Spacer()
                    if let p = models.progress[f.id] {
                        ProgressView(value: p).tint(Theme.accent).frame(width: 70)
                    } else if !models.isInstalled(f) {
                        Text(ModelManager.format(f.bytes)).font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                if let e = models.errors[f.id] {
                    Text(e).font(.caption2).foregroundStyle(Theme.bad)
                }
            }
            if !models.isReady && !models.isDownloadingRequired {
                Button { models.downloadMissing() } label: {
                    Text("Download missing (\(ModelManager.format(models.missingBytes)))")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Capsule().fill(Theme.inverse)).foregroundStyle(Theme.onInverse)
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }
}

/// Raw view of the models folder, to confirm what's really on the phone.
struct FilesOnDiskView: View {
    @EnvironmentObject var models: ModelManager
    @State private var files: [ModelManager.DiskFile] = []

    var body: some View {
        List {
            Section {
                if files.isEmpty {
                    Text("No model files found. If you deleted and reinstalled Signature, iOS removed its downloads too.")
                        .foregroundStyle(.secondary)
                }
                ForEach(files) { f in
                    HStack {
                        Image(systemName: f.complete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(f.complete ? Theme.good : Theme.warn)
                        VStack(alignment: .leading) {
                            Text(f.name).font(.caption.monospaced())
                            Text(f.complete ? ModelManager.format(f.bytes) : "\(ModelManager.format(f.bytes)) (incomplete)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text(models.directory.path).font(.caption2.monospaced())
            }
            .themedRow()
        }
        .screen()
        .navigationTitle("Files on this device")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            models.refresh()
            files = models.filesOnDisk()
        }
    }
}

/// The setup picked for this phone's memory, one tap to use it.
struct RecommendedCard: View {
    @EnvironmentObject var models: ModelManager

    var body: some View {
        let r = Device.recommendation
        let files = models.recommendedFiles
        let missing = files.filter { !models.isInstalled($0) }
        let bytes = missing.reduce(Int64(0)) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text("Recommended for this device").font(.headline).foregroundStyle(Theme.text)
                Spacer()
                if models.isRecommendedSelected {
                    Text("In use").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(r.music.name) · \(r.musicQuant.label)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text("\(r.songwriter.name) · \(r.songwriterQuant.label)\(r.lite ? " · Lite" : "")")
                    .font(.subheadline).foregroundStyle(Theme.text)
                Text(r.why).font(.caption).foregroundStyle(Theme.muted)
            }
            if !models.isRecommendedSelected || !missing.isEmpty {
                Button {
                    models.applyRecommendation()
                    missing.forEach(models.download)
                } label: {
                    Text(missing.isEmpty ? "Use this setup" : "Use this setup · download \(ModelManager.format(bytes))")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Capsule().fill(Theme.inverse)).foregroundStyle(Theme.onInverse)
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }
}


/// Settings → Appearance: theme swatches.
struct AppearanceSection: View {
    @AppStorage("appTheme") private var themeID = "dusk"

    var body: some View {
        Section {
            HStack(spacing: 12) {
                ForEach(Palette.all, id: \.id) { p in
                    Button { withAnimation { themeID = p.id } } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom))
                                Capsule().fill(LinearGradient(colors: p.gradient, startPoint: .leading, endPoint: .trailing))
                                    .frame(width: 34, height: 8)
                            }
                            .frame(height: 56)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(themeID == p.id ? Theme.text : Theme.stroke, lineWidth: themeID == p.id ? 2 : 1))
                            Text(p.name).font(.caption.weight(themeID == p.id ? .semibold : .regular))
                                .foregroundStyle(themeID == p.id ? Theme.text : Theme.muted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Appearance")
        }
        .themedRow()
    }
}
