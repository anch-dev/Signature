import SwiftUI

/// Live status terminal: the iPhone engine's own output, or the PC's engine and training logs.
struct TerminalView: View {
    @EnvironmentObject var hub: HubStore
    @EnvironmentObject var gen: Generator
    @ObservedObject private var log = LogCapture.shared
    @State private var source: Source = .phone
    @State private var remote: [String] = []
    @State private var follow = true

    enum Source: String, CaseIterable, Identifiable {
        case phone, pcEngine, pcTraining
        var id: String { rawValue }
        var title: String {
            switch self {
            case .phone: return "Device"
            case .pcEngine: return "PC engine"
            case .pcTraining: return "PC training"
            }
        }
    }

    private var lines: [String] { source == .phone ? log.lines : remote }

    var body: some View {
        VStack(spacing: 0) {
            if hub.isPaired {
                PillPicker(options: Source.allCases, selection: $source) { $0.title }
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            statusBar
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.suffix(1500).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(10)
                }
                .background(Color.black)
                .onChange(of: lines.count) { _ in if follow { proxy.scrollTo("end") } }
                .onAppear { proxy.scrollTo("end") }
            }
        }
        .background(Theme.background)
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { follow.toggle() } label: {
                    Image(systemName: follow ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line.circle")
                }
                .accessibilityLabel(follow ? "Stop following" : "Follow output")
                ShareLink(item: lines.joined(separator: "\n")) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share log")
                if source == .phone {
                    Button { log.clear() } label: { Image(systemName: "trash") }.accessibilityLabel("Clear")
                }
            }
        }
        .task(id: source) {
            guard source != .phone else { return }
            struct Logs: Decodable { let lines: [String] }
            let src = source == .pcTraining ? "training" : "engine"
            while !Task.isCancelled {
                if let l = try? await hub.client?.get("/api/logs?source=\(src)&tail=800", as: Logs.self) {
                    remote = l.lines
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            Text(statusText).font(.caption.monospaced()).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer()
            Text("mem \(ByteCountFormatter.string(fromByteCount: Int64(SongEngine.footprint), countStyle: .memory))")
                .font(.caption.monospaced()).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.card)
    }

    private var statusText: String {
        switch source {
        case .phone:
            return gen.running || gen.testing ? "\(gen.statusText) · \(Int(gen.progress * 100))%" : "idle"
        case .pcEngine:
            guard let s = hub.status else { return "not connected" }
            return "\(s.engine.mode) · \(s.engine.state)" + (s.gpu.map { " · \($0.name) \($0.util)%" } ?? "")
        case .pcTraining:
            guard let t = hub.status?.training else { return "no training job" }
            return "\(t.dataset) · \(t.step_name) \(t.epoch)/\(t.epochs_total) · \(t.status)"
        }
    }

    private var dotColor: Color {
        switch source {
        case .phone: return gen.running || gen.testing ? Theme.warn : Theme.good
        case .pcEngine: return hub.reachable ? (hub.status?.engine.state == "ready" ? Theme.good : Theme.warn) : Theme.bad
        case .pcTraining: return hub.status?.training?.isRunning == true ? Theme.warn : Theme.muted
        }
    }

    private func color(_ line: String) -> Color {
        let l = line.lowercased()
        if l.contains("fatal") || l.contains("error") || l.contains("failed") { return Theme.bad }
        if l.contains("warning") { return Theme.warn }
        if line.hasPrefix("[") && line.contains("] ") && line.count < 12 { return Theme.faint }
        return Color(red: 0.75, green: 0.95, blue: 0.80)
    }
}
