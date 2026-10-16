import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var adapters: AdapterStore
    @EnvironmentObject var gen: Generator
    @State private var importing = false

    private var adapterType: UTType {
        UTType(filenameExtension: "safetensors") ?? .data
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Quality", selection: $models.quality) {
                        ForEach(Quality.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(models.downloading != nil)
                    ForEach(models.required) { f in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(f.role)
                                Text(f.id).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if models.installed.contains(f.id) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if models.downloading == f {
                                ProgressView(value: models.downloadProgress).frame(width: 70)
                            } else {
                                Text(ModelManager.format(f.bytes)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if models.downloading != nil {
                        Button("Cancel download", role: .destructive) { models.cancelDownload() }
                    } else if !models.isReady {
                        Button {
                            Task { await models.downloadMissing() }
                        } label: {
                            Label("Download \(ModelManager.format(models.missingBytes))", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    if let e = models.lastError {
                        Text(e).foregroundStyle(.red)
                    }
                } header: {
                    Text("Models (one-time download)")
                } footer: {
                    Text("ACE-Step 1.5 turbo from Hugging Face. Use Wi-Fi and keep the app open. After this, everything runs offline on your phone.")
                }

                Section {
                    ForEach(adapters.adapters, id: \.self) { url in
                        Text(AdapterStore.name(url))
                    }
                    .onDelete { idx in
                        idx.map { adapters.adapters[$0] }.forEach {
                            if gen.adapter == $0 { gen.adapter = nil }
                            adapters.delete($0)
                        }
                    }
                    Button {
                        importing = true
                    } label: {
                        Label("Import style file", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Your styles")
                } footer: {
                    Text("Train a style on your PC with the trainer kit, then import its .safetensors file here.")
                }

                Section("This device") {
                    LabeledContent("Memory for Signature", value: gen.availableMemoryText)
                    LabeledContent("Longest song", value: CreateView.time(gen.maxDuration))
                    if models.isReady {
                        Button("Remove unused model files") { models.deleteUnused() }
                    }
                }
            }
            .navigationTitle("Models")
            .fileImporter(isPresented: $importing, allowedContentTypes: [adapterType, .data]) { result in
                if case .success(let url) = result {
                    if let added = adapters.importFile(url) { gen.adapter = added }
                }
            }
        }
    }
}
