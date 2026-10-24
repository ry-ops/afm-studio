import SwiftUI
import FoundationModels
import AFMKit

struct ModelView: View {
    @Environment(AppState.self) private var app
    @State private var adapterPath = ""
    @State private var adapterResult: String?

    var body: some View {
        let s = app.status
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(title: "Model", subtitle: "Apple Foundation Models: the roughly 3-billion-parameter model built into Apple Intelligence.", symbol: "cpu")
                Card {
                    HStack(spacing: 16) {
                        Image(systemName: s.available ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 40)).foregroundStyle(s.available ? .green : .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.available ? "Ready on this Mac" : "Unavailable").font(.title2.bold())
                            Text(s.guidance ?? "Runs on device: free, offline and private. No account or API key.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !s.available {
                            Button("Open Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!) }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    Card(title: "Capabilities", symbol: "list.bullet.rectangle") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow { Text("Context window").foregroundStyle(.secondary); Text("\(s.contextSize) tokens") }
                            GridRow { Text("Content tagging").foregroundStyle(.secondary); Text(s.taggingAvailable ? "Available" : "Unavailable") }
                            GridRow { Text("Guided JSON").foregroundStyle(.secondary); Text("Yes, constrained decoding") }
                            GridRow { Text("Tool calling").foregroundStyle(.secondary); Text("Yes") }
                            GridRow { Text("Custom adapters").foregroundStyle(.secondary); Text(".fmadapter files") }
                            GridRow { Text("macOS").foregroundStyle(.secondary); Text(s.osVersion) }
                        }
                    }
                    Card(title: "Good at / not good at", symbol: "scalemass") {
                        Label("Summaries, extraction, classification, tagging, rewriting, short drafts, translation", systemImage: "checkmark.circle").foregroundStyle(.green)
                        Label("World knowledge, multi-step math, long reasoning, writing code. Verify its facts.", systemImage: "xmark.circle").foregroundStyle(.orange)
                    }
                }
                Card(title: "Languages (\(s.languages.count))", symbol: "globe") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(s.languages, id: \.self) { l in Text(ModelStatus.languageName(l)).font(.callout) }
                    }
                }
                Card(title: "Custom adapter", symbol: "puzzlepiece.extension") {
                    Text("Adapters trained with Apple's Foundation Models adapter toolkit specialize the model for one task. Load an .fmadapter to use it everywhere in AFM Studio.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("Path to .fmadapter", text: $adapterPath).textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true
                            p.canChooseFiles = true
                            if p.runModal() == .OK, let u = p.url { adapterPath = u.path }
                        }
                        Button("Test") { test() }.disabled(adapterPath.isEmpty)
                    }
                    if let adapterResult { Text(adapterResult).font(.callout) }
                    HStack {
                        Button("Use as Default") {
                            app.settings.defaultConfig.adapterPath = adapterPath.isEmpty ? nil : adapterPath
                            app.saveSettings()
                            adapterResult = "Saved. New chats and the CLI will use this adapter."
                        }
                        .disabled(adapterPath.isEmpty)
                        if app.settings.defaultConfig.adapterPath != nil {
                            Button("Remove Default Adapter") {
                                app.settings.defaultConfig.adapterPath = nil
                                app.saveSettings()
                                adapterResult = "Using the base model."
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
        .onAppear { adapterPath = app.settings.defaultConfig.adapterPath ?? "" }
    }

    func test() {
        do {
            let m = try ModelConfig(adapterPath: adapterPath).makeModel()
            adapterResult = m.isAvailable ? "✓ Adapter loaded and the model is available." : "Adapter loaded, but the model isn't available."
        } catch {
            adapterResult = "✗ " + AFMError.from(error).fullDescription
        }
    }
}
