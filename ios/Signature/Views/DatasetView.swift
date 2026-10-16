import SwiftUI
import UniformTypeIdentifiers

struct DatasetView: View {
    @EnvironmentObject var hub: HubStore
    @Environment(\.dismiss) private var dismiss
    let name: String

    @State private var detail: DatasetDetail?
    @State private var styleText = ""
    @State private var importKind: String?
    @State private var uploadStatus: String?
    @State private var editing: DatasetSong?
    @State private var showTrain = false
    @State private var epochs = 800
    @State private var rank = 32
    @State private var confirmDelete = false

    private var training: TrainJob? {
        guard let t = hub.status?.training, t.dataset == name else { return nil }
        return t
    }
    private var busy: Bool { hub.status?.training?.isRunning == true }

    var body: some View {
        List {
            if let t = training { TrainingCard(job: t) }

            Section {
                TextField("e.g. melodic trap, 808s, airy pads, auto-tuned male vocal", text: $styleText, axis: .vertical)
                    .lineLimit(2...4)
                    .onSubmit(saveStyle)
                if styleText != (detail?.style ?? "") {
                    Button("Save", action: saveStyle)
                }
            } header: {
                Text("Sound description")
            } footer: {
                Text("Used as the caption for songs that don't have their own. Trigger word: \(name)")
            }

            Section {
                Button { importKind = "vocals" } label: { Label("Add songs with vocals", systemImage: "music.mic") }
                Button { importKind = "instrumentals" } label: { Label("Add instrumentals / beats", systemImage: "pianokeys") }
                if let u = uploadStatus {
                    HStack { ProgressView(); Text(u).font(.callout) }
                }
            } footer: {
                Text("Pick audio from Files (iCloud Drive, On My iPhone, USB). Only use music you own or have permission to train on.")
            }

            if let d = detail {
                Section {
                    Button {
                        Task { await hub.startTraining(dataset: name, kind: "label", epochs: epochs, rank: rank); await reload() }
                    } label: {
                        Label("Transcribe lyrics on the PC", systemImage: "text.quote")
                    }
                    .disabled(busy || d.songs == 0 || d.labeled == d.songs)
                    Button {
                        showTrain = true
                    } label: {
                        Label(d.trained ? "Retrain style" : "Train style", systemImage: "wand.and.stars")
                            .font(.headline)
                    }
                    .disabled(busy || d.songs < 3)
                } footer: {
                    Text(d.labeled < d.songs
                         ? "\(d.songs - d.labeled) songs have no lyrics yet. Transcribe first so you can fix mistakes, or just train (it transcribes automatically)."
                         : "All songs have lyrics. Tap a song to review them.")
                }

                Section("\(d.songs) songs") {
                    ForEach(d.items) { s in
                        Button { editing = s } label: { SongRow(song: s) }
                            .foregroundStyle(.primary)
                    }
                    .onDelete { idx in
                        let doomed = idx.map { d.items[$0] }
                        Task {
                            for s in doomed {
                                let path = s.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s.id
                                try? await hub.client?.callIgnoring("DELETE", "/api/datasets/\(name)/songs/\(path)")
                            }
                            await reload()
                        }
                    }
                }
            } else {
                Section { ProgressView() }
            }
        }
        .screen()
        .navigationTitle(name)
        .toolbar {
            Menu {
                Button("Delete training set", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .confirmationDialog("Delete \(name) and its uploaded songs from the PC?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await hub.client?.callIgnoring("DELETE", "/api/datasets/\(name)")
                    await hub.refresh()
                    dismiss()
                }
            }
        }
        .fileImporter(isPresented: Binding(get: { importKind != nil }, set: { if !$0 { importKind = nil } }),
                      allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio], allowsMultipleSelection: true) { result in
            let kind = importKind ?? "vocals"
            if case .success(let urls) = result { Task { await upload(urls, kind: kind) } }
        }
        .sheet(item: $editing) { s in
            SongEditor(dataset: name, song: s) { await reload() }
        }
        .sheet(isPresented: $showTrain) { trainSheet }
        .refreshable { await reload() }
        .task { await reload() }
        .onChange(of: training?.status) { _ in Task { await reload() } }
    }

    private var trainSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Epochs: \(epochs)", value: $epochs, in: 200...2000, step: 100)
                    Picker("Capacity (rank)", selection: $rank) {
                        Text("16 · light").tag(16)
                        Text("32 · balanced").tag(32)
                        Text("64 · detailed").tag(64)
                    }
                } footer: {
                    Text("Defaults fit a 12 GB card (RTX 3080 Ti). ~800 epochs for 10–20 songs, fewer for big sets. Expect a few hours; you can close the app and check back.")
                }
                Section {
                    Button {
                        showTrain = false
                        Task { await hub.startTraining(dataset: name, kind: "train", epochs: epochs, rank: rank) }
                    } label: {
                        Label("Start training", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } footer: {
                    Text("The PC pauses song generation and the Studio while it trains.")
                }
            }
            .navigationTitle("Train \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Close") { showTrain = false } }
        }
        .presentationDetents([.medium])
    }

    private func reload() async {
        guard let client = hub.client else { return }
        do {
            let d = try await client.get("/api/datasets/\(name)", as: DatasetDetail.self)
            if detail == nil || styleText == detail?.style { styleText = d.style }
            detail = d
        } catch {
            hub.lastError = error.localizedDescription
        }
    }

    private func saveStyle() {
        struct Body: Encodable { let style: String }
        let s = styleText
        Task {
            try? await hub.client?.callIgnoring("PUT", "/api/datasets/\(name)/style", body: Body(style: s))
            await reload()
        }
    }

    private func upload(_ urls: [URL], kind: String) async {
        guard let client = hub.client else { return }
        for (i, url) in urls.enumerated() {
            uploadStatus = "Uploading \(i + 1) of \(urls.count): \(url.lastPathComponent)"
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await client.upload(song: url, dataset: name, kind: kind)
            } catch {
                hub.lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
                break
            }
        }
        uploadStatus = nil
        await reload()
        await hub.refresh()
    }
}

private struct SongRow: View {
    let song: DatasetSong
    var body: some View {
        HStack {
            Image(systemName: song.kind == "instrumentals" ? "pianokeys" : "music.mic")
                .foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: song.labeled ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(song.labeled ? .green : .secondary)
        }
    }
    private var subtitle: String {
        if !song.labeled { return "No lyrics yet" }
        if song.is_instrumental { return "Instrumental" + (song.bpm.isEmpty ? "" : " · \(song.bpm) BPM") }
        let first = song.lyrics.split(separator: "\n").first { !$0.hasPrefix("[") }.map(String.init) ?? ""
        return first.isEmpty ? "Lyrics" : "“\(first)”"
    }
}

private struct SongEditor: View {
    @EnvironmentObject var hub: HubStore
    @Environment(\.dismiss) private var dismiss
    let dataset: String
    let song: DatasetSong
    let onSave: () async -> Void
    @State private var caption = ""
    @State private var lyrics = ""
    @State private var instrumental = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Caption") {
                    TextField("Leave empty to use the set's description", text: $caption, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section {
                    Toggle("Instrumental", isOn: $instrumental)
                    if !instrumental {
                        TextEditor(text: $lyrics)
                            .font(.body.monospaced())
                            .frame(minHeight: 280)
                    }
                } header: {
                    Text("Lyrics")
                } footer: {
                    Text("Fix misheard words and add [Verse] / [Chorus] tags. Accurate lyrics teach the style much better.")
                }
                if !song.bpm.isEmpty || !song.key.isEmpty {
                    Section("Detected") {
                        if !song.bpm.isEmpty { LabeledContent("BPM", value: song.bpm) }
                        if !song.key.isEmpty { LabeledContent("Key", value: song.key) }
                    }
                }
            }
            .navigationTitle(song.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                }
            }
            .onAppear {
                caption = song.caption
                lyrics = song.lyrics == "[Instrumental]" ? "" : song.lyrics
                instrumental = song.labeled ? song.is_instrumental : song.kind == "instrumentals"
            }
        }
    }

    private func save() async {
        struct Body: Encodable { let caption: String; let lyrics: String; let is_instrumental: Bool }
        saving = true
        defer { saving = false }
        let path = song.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? song.id
        do {
            try await hub.client?.callIgnoring("PUT", "/api/datasets/\(dataset)/songs/\(path)",
                                               body: Body(caption: caption, lyrics: lyrics, is_instrumental: instrumental))
            await onSave()
            dismiss()
        } catch {
            hub.lastError = error.localizedDescription
        }
    }
}
