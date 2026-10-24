import SwiftUI
import AFMKit

/// The menu bar panel: ask a question, or run a recipe on whatever is on the clipboard.
struct QuickAskView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var prompt = ""
    @State private var output = ""
    @State private var running = false
    @State private var label: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    let actions: [(String, String, String, [String: String])] = [
        ("Summarize", "text.append", "summarize", ["style": "bullet points"]),
        ("Proofread", "checkmark.seal", "proofread", [:]),
        ("Friendlier", "face.smiling", "rewrite", ["tone": "friendly"]),
        ("Translate", "character.bubble", "translate", [:]),
        ("Action items", "checklist", "action-items", [:]),
        ("Explain", "graduationcap", "eli5", [:]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("AFM Studio").font(.headline)
                Spacer()
                Circle().fill(app.status.available ? .green : .orange).frame(width: 7, height: 7)
            }
            TextField("Ask the on-device model…", text: $prompt, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { ask() }
            Text("On the clipboard").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(actions, id: \.0) { a in
                    Button { runRecipe(a.2, params: a.3, label: a.0) } label: {
                        Label(a.0, systemImage: a.1).font(.caption).frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .disabled(running)
                }
            }
            if running || !output.isEmpty {
                Divider()
                HStack {
                    Text(label ?? "Answer").font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    if running { ProgressView().controlSize(.mini); Button("Stop") { task?.cancel() }.controlSize(.small) }
                    else { CopyButton(text: output, compact: true) }
                }
                ScrollView {
                    MarkdownText(text: output).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
            Divider()
            HStack {
                Button("Open AFM Studio") { openWindow(id: "main"); NSApp.activate() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    func ask() {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !running else { return }
        start("Answer") {
            try await AFM.run(GenerationRequest(prompt: p, tools: ToolKind.safeDefaults), onPartial: { s in Task { @MainActor in output = s } })
        }
    }

    func runRecipe(_ id: String, params: [String: String], label: String) {
        let clip = Pasteboard.string
        guard !clip.isEmpty, let r = RecipeBook.shared.find(id) else { output = "The clipboard is empty."; return }
        start(label) {
            try await RecipeRunner.run(r, input: clip, params: params, onPartial: { s in Task { @MainActor in output = s } })
        }
    }

    func start(_ title: String, _ op: @escaping () async throws -> GenerationResult) {
        running = true
        output = ""
        label = title
        task = Task {
            do {
                let r = try await op()
                output = r.text
                History.append(HistoryEntry(source: "studio", kind: "quick", title: title, input: prompt, output: r.text, seconds: r.seconds, outputTokens: r.outputTokens))
            } catch {
                if !Task.isCancelled { output = AFMError.from(error).fullDescription }
            }
            running = false
        }
    }
}
