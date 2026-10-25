import SwiftUI
import FoundationModels
import AFMKit

struct ModelView: View {
    @Environment(AppState.self) private var app

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
            }
            .padding(22)
        }
    }
}
