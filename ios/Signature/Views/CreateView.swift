import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct CreateView: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var library: Library
    @EnvironmentObject var adapters: AdapterStore
    @EnvironmentObject var gen: Generator
    @EnvironmentObject var player: Player
    @EnvironmentObject var hub: HubStore
    @State private var showModels = false
    @State private var showOptions = false
    @State private var importing = false
    @State private var pickingSource = false
    @State private var pickingFromLibrary = false
    @FocusState private var focused: Bool

    static let genres = ["pop", "hip hop", "trap", "r&b", "rock", "indie", "edm", "house", "lo-fi", "drill",
                         "jazz", "soul", "funk", "country", "latin", "k-pop", "metal", "acoustic", "cinematic", "ambient"]
    static let vibes = ["male vocal", "female vocal", "upbeat", "melancholic", "dreamy", "dark", "chill", "energetic",
                        "808s", "piano", "guitar", "synths", "strings"]
    private let languages: [(String, String)] = [
        ("", "Auto"), ("en", "English"), ("es", "Spanish"), ("it", "Italian"), ("fr", "French"),
        ("pt", "Portuguese"), ("de", "German"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
    ]

    private var onPC: Bool { gen.target == .pc }
    private var ready: Bool { onPC ? hub.canGenerate : models.isReady }
    private var limit: Double { onPC ? 480 : models.maxDuration }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    PillPicker(options: CreateMode.allCases, selection: $gen.mode) { $0.title }
                    if !onPC && !models.isReady { downloadCard }
                    if onPC { pcStatus }
                    switch gen.mode {
                    case .simple: simpleForm
                    case .custom: customForm
                    case .cover: coverForm
                    }
                    soundRow
                    optionsCard
                    if let e = gen.error {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Theme.bad)
                    }
                    recent
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .screen()
            .safeAreaInset(edge: .bottom) {
                CreateButton(title: onPC ? "Create on \(hub.pairing?.name ?? "PC")" : "Create",
                             running: gen.running, progress: gen.progress,
                             status: gen.etaText.map { "\(gen.statusText) · \($0)" } ?? gen.statusText,
                             enabled: ready, action: create, cancel: gen.cancel)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.bg.opacity(0.92))
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showModels) { ModelPickerSheet() }
            .sheet(isPresented: $pickingFromLibrary) { LibraryPicker() }
            .fileImporter(isPresented: $pickingSource, allowedContentTypes: [.audio]) { r in
                if case .success(let url) = r { importSource(url) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "safetensors") ?? .data, .data]) { r in
                if case .success(let url) = r, let added = adapters.importFile(url) { gen.adapter = added }
            }
            .alert("Style", isPresented: Binding(get: { adapters.importMessage != nil },
                                                 set: { if !$0 { adapters.importMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(adapters.importMessage ?? "") }
            .onChange(of: models.maxDuration) { m in if !onPC { gen.duration = min(gen.duration, m) } }
        }
    }

    private func create() {
        focused = false
        if onPC { gen.startRemote(hub: hub, library: library) } else { gen.start(models: models, library: library) }
    }

    // MARK: header + model chip

    private var header: some View {
        HStack(alignment: .center) {
            Text("Create").font(.largeTitle.bold()).foregroundStyle(Theme.text)
            Spacer()
            NavigationLink { TerminalView() } label: {
                Image(systemName: "terminal")
                    .font(.subheadline.weight(.semibold))
                    .padding(9)
                    .background(Circle().fill(Theme.card))
                    .overlay(Circle().stroke(Theme.stroke))
                    .foregroundStyle(gen.running ? Theme.accent : Theme.text)
            }
            .accessibilityLabel("Status terminal")
            Button { showModels = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: onPC ? "desktopcomputer" : "iphone")
                    Text(onPC ? (hub.pairing?.name ?? "PC") : models.music.name).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().stroke(Theme.stroke))
                .foregroundStyle(Theme.text)
            }
            .accessibilityLabel("Model and device")
        }
        .padding(.top, 8)
    }

    // MARK: download / status

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(models.isDownloadingRequired ? "Downloading \(models.music.name)" : "Get \(models.music.name) on this iPhone")
                        .font(.headline).foregroundStyle(Theme.text)
                    Text(models.isDownloadingRequired
                         ? "Keeps going if you leave the app."
                         : "\(ModelManager.format(models.missingBytes)) one-time download, then everything runs offline.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            if models.isDownloadingRequired {
                ProgressView(value: models.requiredProgress).tint(Theme.accent)
            } else {
                Button { models.downloadMissing() } label: {
                    Text("Download").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Capsule().fill(Color.white)).foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
            ForEach(models.missing.filter { models.errors[$0.id] != nil }) { f in
                Text("\(f.id): \(models.errors[f.id] ?? "")").font(.caption2).foregroundStyle(Theme.bad)
            }
        }
        .card()
    }

    @ViewBuilder private var pcStatus: some View {
        if let s = hub.status, hub.reachable {
            if s.training?.isRunning == true {
                Label("\(hub.pairing?.name ?? "PC") is training \(s.training!.dataset). Create on the iPhone meanwhile.", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(Theme.warn)
            }
        } else {
            Label("Can't reach \(hub.pairing?.name ?? "the PC"). Same Wi-Fi or Tailscale on?", systemImage: "wifi.exclamationmark")
                .font(.callout).foregroundStyle(Theme.bad)
        }
    }

    // MARK: Simple

    private var simpleForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $gen.songDescription)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .foregroundStyle(Theme.text)
                    .font(.body)
                if gen.songDescription.isEmpty {
                    Text("Describe your song, e.g. a late-night R&B song about city lights and missing someone")
                        .foregroundStyle(Theme.faint).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .card(padding: 10)
            tagRow(Self.genres + Self.vibes, into: $gen.songDescription)
            HStack {
                Chip(title: "Instrumental", icon: gen.instrumental ? "checkmark" : "pianokeys", selected: gen.instrumental) {
                    gen.instrumental.toggle()
                }
                Spacer()
            }
        }
    }

    // MARK: Custom

    private var customForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Lyrics", trailing: AnyView(
                    Chip(title: "Instrumental", icon: gen.instrumental ? "checkmark" : nil, selected: gen.instrumental) {
                        gen.instrumental.toggle()
                    }))
                if !gen.instrumental {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $gen.lyrics)
                            .focused($focused)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 200)
                            .font(.body.monospaced())
                            .foregroundStyle(Theme.text)
                        if gen.lyrics.isEmpty {
                            Text("[Verse]\nWrite your lines here\n\n[Chorus]\nThe hook\n\nLeave empty and the songwriter writes them.")
                                .font(.body.monospaced()).foregroundStyle(Theme.faint)
                                .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .card(padding: 10)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Style of music")
                TextField("", text: $gen.style, prompt: Text("melodic trap, 808s, airy pads, male vocal").foregroundColor(Theme.faint), axis: .vertical)
                    .focused($focused)
                    .lineLimit(1...4)
                    .foregroundStyle(Theme.text)
                    .card(padding: 12)
                tagRow(Self.genres + Self.vibes, into: $gen.style)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Title")
                TextField("", text: $gen.title, prompt: Text("Optional").foregroundColor(Theme.faint))
                    .focused($focused)
                    .foregroundStyle(Theme.text)
                    .card(padding: 12)
            }
        }
    }

    private func tagRow(_ tags: [String], into text: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    let on = text.wrappedValue.lowercased().contains(tag)
                    Chip(title: tag, selected: on) {
                        var t = text.wrappedValue
                        if on {
                            t = t.replacingOccurrences(of: ", \(tag)", with: "").replacingOccurrences(of: tag, with: "")
                            t = t.trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
                        } else {
                            t = t.trimmingCharacters(in: .whitespaces)
                            t = t.isEmpty ? tag : t + ", " + tag
                        }
                        text.wrappedValue = t
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Cover

    private var coverForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Source song")
                HStack(spacing: 12) {
                    SongArt(seed: gen.coverSourceName.isEmpty ? "none" : gen.coverSourceName, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gen.coverSource == nil ? "Pick a song to cover" : gen.coverSourceName)
                            .font(.body.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if gen.coverSource != nil {
                            Text(Self.time(gen.coverSourceDuration)).font(.caption).foregroundStyle(Theme.muted)
                        } else {
                            Text("From your Library or any audio file").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer()
                    Menu {
                        Button { pickingFromLibrary = true } label: { Label("From Library", systemImage: "music.note.list") }
                        Button { pickingSource = true } label: { Label("From Files", systemImage: "folder") }
                    } label: {
                        Text(gen.coverSource == nil ? "Choose" : "Change").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Color.white)).foregroundStyle(.black)
                    }
                }
                .card(padding: 12)
                Text("Only cover music you own or have permission to use.").font(.caption2).foregroundStyle(Theme.faint)
            }
            PillPicker(options: CoverTask.allCases, selection: $gen.coverTask) { $0.title }
            if gen.coverTask == .cover {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Keep from original").font(.subheadline).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("\(Int(gen.coverStrength * 100))%").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    Slider(value: $gen.coverStrength, in: 0.1...1.0, step: 0.05).tint(Theme.accent)
                    Text("Lower = freer remix, higher = same song in a new style.").font(.caption2).foregroundStyle(Theme.faint)
                }
                .card()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Section to redo").font(.subheadline).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("\(Self.time(gen.repaintStart)) – \(Self.time(gen.repaintEnd))")
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    let maxT = max(gen.coverSourceDuration, 10)
                    Slider(value: $gen.repaintStart, in: 0...maxT, step: 1).tint(Theme.accent)
                        .onChange(of: gen.repaintStart) { v in if gen.repaintEnd < v + 2 { gen.repaintEnd = min(maxT, v + 2) } }
                    Slider(value: $gen.repaintEnd, in: 0...maxT, step: 1).tint(Theme.accent)
                        .onChange(of: gen.repaintEnd) { v in if gen.repaintStart > v - 2 { gen.repaintStart = max(0, v - 2) } }
                    Text("Everything outside this range stays the same.").font(.caption2).foregroundStyle(Theme.faint)
                }
                .card()
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("New style")
                TextField("", text: $gen.style, prompt: Text("acoustic guitar, soft female vocal, lo-fi").foregroundColor(Theme.faint), axis: .vertical)
                    .focused($focused)
                    .lineLimit(1...4)
                    .foregroundStyle(Theme.text)
                    .card(padding: 12)
                tagRow(Self.genres + Self.vibes, into: $gen.style)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Lyrics", trailing: AnyView(
                    Chip(title: "Instrumental", icon: gen.instrumental ? "checkmark" : nil, selected: gen.instrumental) {
                        gen.instrumental.toggle()
                    }))
                if !gen.instrumental {
                    TextEditor(text: $gen.lyrics)
                        .focused($focused)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140)
                        .font(.body.monospaced())
                        .foregroundStyle(Theme.text)
                        .card(padding: 10)
                    Text("Keep the original lyrics for a cover, or change them for new words over the same music.")
                        .font(.caption2).foregroundStyle(Theme.faint)
                }
            }
        }
    }

    private func importSource(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = library.songsDir.deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            let secs = (try? AVAudioPlayer(contentsOf: dest).duration) ?? 0
            gen.prepareCover(source: dest, name: url.deletingPathExtension().lastPathComponent, duration: secs)
        } catch {
            gen.error = "Couldn't open that file: \(error.localizedDescription)"
        }
    }

    // MARK: Your sound (styles)

    private var styleNames: [String] {
        onPC ? hub.styles.filter(\.pc_ready).map(\.name) : adapters.adapters.map(AdapterStore.name)
    }

    private var soundRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Your sound")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    styleBubble(name: "Base", selected: gen.styleName == nil, seed: "base") { select(nil) }
                    ForEach(styleNames, id: \.self) { n in
                        styleBubble(name: n, selected: gen.styleName == n, seed: n) { select(n) }
                    }
                    Button {
                        if onPC { gen.target = .pc } else { importing = true }
                    } label: {
                        VStack(spacing: 6) {
                            Circle().fill(Theme.card).overlay(Circle().stroke(Theme.stroke))
                                .overlay(Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(Theme.muted))
                                .frame(width: 58, height: 58)
                            Text(onPC ? "Train on PC" : "Import").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if gen.styleName != nil {
                HStack {
                    Text("Strength").font(.subheadline).foregroundStyle(Theme.muted)
                    Slider(value: $gen.adapterScale, in: onPC ? 0.1...1.0 : 0.2...1.5, step: 0.05).tint(Theme.accent)
                    Text(String(format: "%.2f", gen.adapterScale)).font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func select(_ name: String?) {
        if onPC {
            gen.pcStyle = name
        } else {
            gen.adapter = name.flatMap { n in adapters.adapters.first { AdapterStore.name($0) == n } }
        }
    }

    private func styleBubble(name: String, selected: Bool, seed: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    SongArt(seed: seed, size: 58).clipShape(Circle())
                    Text(String(name.prefix(2)).uppercased()).font(.headline.weight(.heavy)).foregroundStyle(.white)
                }
                .overlay(Circle().stroke(selected ? Color.white : Color.clear, lineWidth: 2.5).padding(-3))
                Text(name).font(.caption).foregroundStyle(selected ? Theme.text : Theme.muted).lineLimit(1).frame(maxWidth: 72)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Options

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { showOptions.toggle() }
            } label: {
                HStack {
                    Text("More options").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(Self.time(min(gen.duration, limit))).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.muted)
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showOptions ? 180 : 0)).foregroundStyle(Theme.muted)
                }
            }
            .buttonStyle(.plain)
            if showOptions {
                if gen.mode != .cover { VStack(alignment: .leading, spacing: 4) {
                    Text("Length").font(.caption).foregroundStyle(Theme.muted)
                    Slider(value: $gen.duration, in: 10...max(limit, 20), step: 5).tint(Theme.accent)
                    if !onPC && models.liteActive {
                        Text("Lite mode: up to \(Self.time(limit)) on this iPhone.").font(.caption2).foregroundStyle(Theme.faint)
                    }
                } }
                Picker("Vocal language", selection: $gen.language) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                .tint(Theme.text)
                Toggle("Reuse seed", isOn: $gen.lockSeed).tint(Theme.accent)
                if gen.lockSeed {
                    TextField("Seed", text: $gen.seedText).keyboardType(.numberPad).foregroundStyle(Theme.text)
                }
            }
        }
        .foregroundStyle(Theme.text)
        .card()
    }

    // MARK: Recent

    @ViewBuilder private var recent: some View {
        if !library.songs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Recent")
                ForEach(library.songs.prefix(4)) { s in
                    SongRow(song: s, playing: player.current == s.id && player.isPlaying)
                        .onTapGesture { player.play(s, library: library) }
                }
            }
        }
    }

    static func time(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

/// Pick a Library song as the source of a cover.
struct LibraryPicker: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var gen: Generator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(library.songs) { s in
                Button {
                    gen.prepareCover(source: library.url(for: s), name: s.title, duration: s.duration,
                                     caption: s.caption, lyrics: s.lyrics)
                    dismiss()
                } label: { SongRow(song: s, playing: false) }
                .listRowBackground(Theme.bg)
            }
            .listStyle(.plain)
            .screen()
            .navigationTitle("Cover a song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }
}
