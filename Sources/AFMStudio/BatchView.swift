import SwiftUI
import UniformTypeIdentifiers
import AFMKit

struct BatchItem: Identifiable, Hashable {
    enum State: Hashable { case queued, running, done, failed }
    let id = UUID()
    let url: URL
    var state: State = .queued
    var output = ""
    var seconds: Double = 0
    var chunks = 1
}

struct BatchView: View {
    @Environment(AppState.self) private var app
    @State private var items: [BatchItem] = []
    @State private var recipeID = "summarize"
    @State private var params: [String: String] = [:]
    @State private var running = false
    @State private var task: Task<Void, Never>?
    @State private var selection: BatchItem.ID?
    @State private var dropping = false

    var recipe: Recipe? { app.recipes.first { $0.id == recipeID } }
    var doneCount: Int { items.filter { $0.state == .done || $0.state == .failed }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Batch", subtitle: "Run one recipe over many files. Everything stays on this Mac.", symbol: "square.stack.3d.up")
            HStack(spacing: 12) {
                Picker("Recipe", selection: $recipeID) {
                    ForEach(app.recipes) { Label($0.title, systemImage: $0.symbol).tag($0.id) }
                }
                .frame(maxWidth: 280)
                .onChange(of: recipeID) { params = recipe?.defaults() ?? [:] }
                if let recipe {
                    ForEach(recipe.params) { p in
                        if let choices = p.choices {
                            Picker(p.label, selection: Binding(get: { params[p.key] ?? p.defaultValue }, set: { params[p.key] = $0 })) {
                                ForEach(choices, id: \.self) { Text($0).tag($0) }
                            }.frame(maxWidth: 240)
                        } else {
                            TextField(p.label, text: Binding(get: { params[p.key] ?? p.defaultValue }, set: { params[p.key] = $0 })).frame(maxWidth: 240)
                        }
                    }
                }
                Spacer()
            }
            HStack {
                Button("Add Files…", systemImage: "plus") { add(FileLoader.pickMany()) }
                Button("Clear", systemImage: "trash") { items.removeAll() }.disabled(running || items.isEmpty)
                Spacer()
                if running {
                    ProgressView(value: Double(doneCount), total: Double(max(items.count, 1))).frame(width: 160)
                    Text("\(doneCount) of \(items.count)").font(.callout.monospacedDigit())
                    Button("Stop", systemImage: "stop.fill") { task?.cancel() }
                } else {
                    Menu("Export", systemImage: "square.and.arrow.up") {
                        Button("JSON Lines…") { FileLoader.save(jsonl, name: "batch-\(recipeID).jsonl", type: .json) }
                        Button("CSV…") { FileLoader.save(csv, name: "batch-\(recipeID).csv", type: .commaSeparatedText) }
                        Button("Markdown…") { FileLoader.save(markdown, name: "batch-\(recipeID).md", type: .plainText) }
                    }
                    .fixedSize()
                    .disabled(doneCount == 0)
                    Button("Run All", systemImage: "play.fill") { run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(items.isEmpty || recipe == nil)
                }
            }
            VSplitView {
                Table(items, selection: $selection) {
                    TableColumn("File") { i in Label(i.url.lastPathComponent, systemImage: "doc.text") }
                    TableColumn("Status") { i in status(i) }.width(110)
                    TableColumn("Time") { i in Text(i.seconds > 0 ? String(format: "%.1fs", i.seconds) : "").monospacedDigit() }.width(60)
                    TableColumn("Result") { i in Text(i.output.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).foregroundStyle(.secondary) }
                }
                .frame(minHeight: 180)
                .overlay {
                    if items.isEmpty {
                        ContentUnavailableView("Drop text files or folders here", systemImage: "tray.and.arrow.down",
                                               description: Text("Markdown, logs, transcripts, code, CSV and other text files."))
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { dropping = $0 }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: dropping ? 2 : 0))

                ScrollView {
                    if let sel = items.first(where: { $0.id == selection }) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(sel.url.lastPathComponent).font(.headline); Spacer(); CopyButton(text: sel.output) }
                            if recipe?.isStructured == true {
                                Text(sel.output).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            } else {
                                MarkdownText(text: sel.output)
                            }
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Select a row to see its full result.").foregroundStyle(.secondary).padding()
                    }
                }
                .frame(minHeight: 140)
            }
        }
        .padding(22)
        .onAppear { if params.isEmpty { params = recipe?.defaults() ?? [:] } }
    }

    @ViewBuilder func status(_ i: BatchItem) -> some View {
        switch i.state {
        case .queued: Label("Queued", systemImage: "clock").foregroundStyle(.secondary)
        case .running: HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Running") }
        case .done: Label(i.chunks > 1 ? "Done (\(i.chunks))" : "Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    func add(_ urls: [URL]) {
        let fm = FileManager.default
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let e = fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if let t = UTType(filenameExtension: f.pathExtension), t.conforms(to: .text) || t.conforms(to: .sourceCode) { out.append(f) }
                }
            } else { out.append(u) }
        }
        let existing = Set(items.map(\.url))
        items += out.filter { !existing.contains($0) }.prefix(500).map { BatchItem(url: $0) }
    }

    func run() {
        guard let recipe else { return }
        running = true
        for i in items.indices where items[i].state != .done { items[i].state = .queued }
        let ps = params
        task = Task {
            for idx in items.indices where items[idx].state == .queued {
                if Task.isCancelled { break }
                items[idx].state = .running
                let url = items[idx].url
                guard let text = FileLoader.text(at: url) else {
                    items[idx].state = .failed; items[idx].output = "Couldn't read this file as text."; continue
                }
                do {
                    let r = try await RecipeRunner.run(recipe, input: text, params: ps)
                    items[idx].output = r.text
                    items[idx].seconds = r.seconds
                    items[idx].chunks = r.chunks
                    items[idx].state = .done
                    History.append(HistoryEntry(source: "studio", kind: "batch", title: "\(recipe.title): \(url.lastPathComponent)", input: String(text.prefix(2000)), output: r.text, seconds: r.seconds, outputTokens: r.outputTokens))
                } catch {
                    if Task.isCancelled { items[idx].state = .queued; break }
                    items[idx].state = .failed
                    items[idx].output = AFMError.from(error).fullDescription
                }
            }
            running = false
        }
    }

    var finished: [BatchItem] { items.filter { $0.state == .done || $0.state == .failed } }

    var jsonl: String {
        finished.map { i in
            var o: [String: Any] = ["file": i.url.path, "recipe": recipeID, "ok": i.state == .done, "seconds": i.seconds]
            if recipe?.isStructured == true, let d = i.output.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) { o["result"] = j } else { o["result"] = i.output }
            return String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
    }

    var csv: String {
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return "file,status,seconds,result\n" + finished.map { "\(esc($0.url.lastPathComponent)),\($0.state == .done ? "ok" : "failed"),\(String(format: "%.2f", $0.seconds)),\(esc($0.output))" }.joined(separator: "\n") + "\n"
    }

    var markdown: String {
        "# \(recipe?.title ?? recipeID)\n\n" + finished.map { "## \($0.url.lastPathComponent)\n\n\($0.output)\n" }.joined(separator: "\n")
    }
}
