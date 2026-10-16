import SwiftUI

struct PCView: View {
    @EnvironmentObject var hub: HubStore
    @EnvironmentObject var adapters: AdapterStore
    @EnvironmentObject var gen: Generator
    @State private var address = ""
    @State private var token = ""
    @State private var pairing = false
    @State private var newSet = false
    @State private var newName = ""
    @State private var newStyle = ""

    var body: some View {
        NavigationStack {
            Group {
                if hub.isPaired { paired } else { unpaired }
            }
            .navigationTitle(hub.pairing?.name ?? "PC")
            .refreshable { await hub.refresh() }
            .task { if hub.isPaired { await hub.refresh(); hub.startPolling() } }
            .alert("PC", isPresented: Binding(get: { hub.lastError != nil }, set: { if !$0 { hub.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(hub.lastError ?? "") }
        }
    }

    // MARK: not paired

    private var unpaired: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Use your PC for training and faster songs", systemImage: "desktopcomputer").font(.headline)
                    Text("1. On your PC, run **start.bat** from the Signature `pc` folder.\n2. The Hub opens in your browser with a QR code.\n3. Scan it with the iPhone **Camera** app.")
                        .font(.callout)
                    Text("Works on the same Wi-Fi, or anywhere with Tailscale on both devices.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("Or enter it manually") {
                TextField("Address, e.g. 192.168.1.20:8790", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Token (Show token on the Hub)", text: $token)
                Button {
                    pairing = true
                    Task { await hub.pairManually(address: address, token: token); pairing = false }
                } label: {
                    HStack { Text("Connect"); if pairing { Spacer(); ProgressView() } }
                }
                .disabled(address.isEmpty || token.isEmpty || pairing)
            }
        }
    }

    // MARK: paired

    private var paired: some View {
        List {
            statusSection
            if let t = hub.status?.training { TrainingCard(job: t) }
            datasetsSection
            stylesSection
            Section {
                Button("Unpair this PC", role: .destructive) {
                    if gen.target == .pc { gen.target = .phone }
                    hub.unpair()
                }
            }
        }
        .alert("New training set", isPresented: $newSet) {
            TextField("trigger word, e.g. anchstyle", text: $newName)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Describe the sound (optional)", text: $newStyle)
            Button("Create") {
                let name = newName.lowercased().trimmingCharacters(in: .whitespaces)
                let style = newStyle
                Task {
                    struct Body: Encodable { let name: String; let style: String }
                    do {
                        try await hub.client?.callIgnoring("POST", "/api/datasets", body: Body(name: name, style: style))
                        await hub.refresh()
                    } catch { hub.lastError = error.localizedDescription }
                }
                newName = ""; newStyle = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The name becomes your style's trigger word: lowercase, no spaces, not a real word.")
        }
    }

    private var statusSection: some View {
        Section {
            if let s = hub.status, hub.reachable {
                LabeledContent("Status") {
                    Text(stateText(s)).foregroundStyle(stateColor(s))
                }
                if let g = s.gpu {
                    LabeledContent(g.name, value: String(format: "%.1f / %.0f GB · %d%%",
                                                         Double(g.mem_used_mb) / 1024, Double(g.mem_total_mb) / 1024, g.util))
                }
                Picker("Engine", selection: Binding(
                    get: { s.engine.mode == "training" ? "api" : s.engine.mode },
                    set: { m in Task { await hub.setMode(m) } })) {
                    Text("Phone server").tag("api")
                    Text("Studio GUI").tag("studio")
                    Text("Off").tag("idle")
                }
                .disabled(s.training?.isRunning == true)
                if s.engine.mode == "studio", s.engine.state == "ready", let url = hub.studioURL() {
                    Link(destination: url) {
                        Label("Open ACE-Step Studio", systemImage: "safari")
                    }
                    Text("Log in with **signature** and your pairing token.").font(.footnote).foregroundStyle(.secondary)
                }
                if let e = s.engine.error {
                    Text(e).font(.footnote).foregroundStyle(.red)
                }
                if !s.installed.acestep || !s.installed.sidestep {
                    Text("Something is missing on the PC. Run install.bat again.").foregroundStyle(.red)
                }
            } else {
                Label("Can't reach \(hub.pairing?.name ?? "PC")", systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                Text("Check that start.bat is running and the phone is on the same Wi-Fi or Tailscale.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Retry") { Task { await hub.refresh() } }
            }
        } header: {
            Text("Hub")
        } footer: {
            Text("Only one thing uses the GPU at a time: generating for the phone, the Studio GUI, or training.")
        }
    }

    private var datasetsSection: some View {
        Section {
            ForEach(hub.datasets) { d in
                NavigationLink {
                    DatasetView(name: d.name)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(d.name).font(.headline)
                            if d.trained { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                        }
                        Text("\(d.songs) songs · \(d.labeled) with lyrics · \(ModelManager.format(d.bytes))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button { newSet = true } label: { Label("New training set", systemImage: "plus") }
                .disabled(!hub.reachable)
        } header: {
            Text("Training sets")
        } footer: {
            Text("Upload 10–20+ of your own songs. Each set trains one style.")
        }
    }

    private var stylesSection: some View {
        Section("Styles on the PC") {
            if hub.styles.isEmpty {
                Text("None yet. Train one above.").foregroundStyle(.secondary)
            }
            ForEach(hub.styles) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name)
                        Text([s.songs.map { "\($0) songs" }, s.epochs.map { "\($0) epochs" }, ModelManager.format(s.bytes)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if hub.downloadingStyle == s.name {
                        ProgressView()
                    } else if adapters.adapters.contains(where: { AdapterStore.name($0) == s.name }) {
                        Label("On iPhone", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                        Button("Update") { Task { await download(s) } }.buttonStyle(.borderless).font(.caption)
                    } else {
                        Button { Task { await download(s) } } label: {
                            Label("Get", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func download(_ s: RemoteStyle) async {
        if let url = await hub.downloadStyle(s, into: adapters) {
            adapters.importMessage = "\"\(s.name)\" is on your iPhone now. It works offline."
            if gen.adapter == nil { gen.adapter = url }
        }
    }

    private func stateText(_ s: HubStatus) -> String {
        switch (s.engine.mode, s.engine.state) {
        case ("training", _): return "Training"
        case ("idle", _): return "Off (GPU free)"
        case (_, "starting"): return "Starting \(s.engine.mode == "studio" ? "Studio" : "engine")…"
        case (_, "ready"): return s.engine.mode == "studio" ? "Studio open" : "Ready"
        case (_, "error"): return "Error"
        default: return s.engine.state.capitalized
        }
    }

    private func stateColor(_ s: HubStatus) -> Color {
        switch s.engine.state {
        case "ready": return .green
        case "starting": return .orange
        case "error": return .red
        default: return .secondary
        }
    }
}

struct TrainingCard: View {
    @EnvironmentObject var hub: HubStore
    let job: TrainJob

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(job.dataset).font(.headline)
                    Spacer()
                    Text(job.status.capitalized)
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(color.opacity(0.15), in: Capsule())
                        .foregroundStyle(color)
                }
                ProgressView(value: job.overall)
                Text("Step \(job.step + 1)/\(job.steps.count): \(job.message)")
                    .font(.callout)
                if job.step_name == "Train" {
                    HStack {
                        Text("Epoch \(job.epoch)/\(job.epochs_total > 0 ? job.epochs_total : job.epochs)")
                        Spacer()
                        if let l = job.loss { Text(String(format: "loss %.4f", l)).monospacedDigit() }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if job.losses.count > 2 {
                    Sparkline(values: job.losses).frame(height: 44)
                }
                Text("Running for \(CreateView.time(Double(job.elapsed)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            NavigationLink("Training log") { LogView(source: "training") }
            if job.isRunning {
                Button("Cancel training", role: .destructive) { Task { await hub.cancelTraining() } }
            }
        } header: {
            Text(job.kind == "label" ? "Transcribing lyrics" : "Training")
        }
    }

    private var color: Color {
        switch job.status {
        case "running": return .orange
        case "done": return .green
        case "failed": return .red
        default: return .secondary
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let lo = values.min() ?? 0, hi = values.max() ?? 1, span = max(hi - lo, 1e-9)
            Path { p in
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                                     y: g.size.height * (1 - CGFloat((v - lo) / span)))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
        .accessibilityLabel("Loss going from \(values.first ?? 0) to \(values.last ?? 0)")
    }
}

struct LogView: View {
    @EnvironmentObject var hub: HubStore
    let source: String
    @State private var lines: [String] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: lines.count) { _ in proxy.scrollTo("end") }
        }
        .navigationTitle(source == "training" ? "Training log" : "Engine log")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            struct Logs: Decodable { let lines: [String] }
            while !Task.isCancelled {
                if let l = try? await hub.client?.get("/api/logs?source=\(source)&tail=400", as: Logs.self) {
                    lines = l.lines
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
